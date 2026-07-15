#import "LBDebugPanel.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <signal.h>
#import <execinfo.h>

static UITextView *g_panelTextView = nil;
static UIViewController *g_panelVC = nil;
static NSMutableString *g_panelBuffer = nil;
static NSMutableString *g_lastCrashText = nil;
static BOOL g_gestureInstalled = NO;
static BOOL (*LBDebugOrig_AppDelegate_openURL_options)(id, SEL, id, NSURL *, NSDictionary *) = NULL;

#pragma mark - Paths / IO

static NSString *LBDocumentsDirectory(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return paths.firstObject ?: NSTemporaryDirectory();
}

static void LBWriteDebugFile(NSString *name, NSString *content) {
    if (!name.length) return;
    NSString *path = [LBDocumentsDirectory() stringByAppendingPathComponent:name];
    NSString *body = content ?: @"";
    [body writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void LBAppendPanel(NSString *line) {
    if (!line) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_panelBuffer) g_panelBuffer = [NSMutableString string];
        [g_panelBuffer appendFormat:@"%@\n", line];
        if (g_panelTextView) {
            g_panelTextView.text = g_panelBuffer;
            NSRange bottom = NSMakeRange(g_panelTextView.text.length, 0);
            [g_panelTextView scrollRangeToVisible:bottom];
        }
    });
}

#pragma mark - VC / view discovery

static UIWindow *LBKeyWindow(void) {
    UIApplication *app = UIApplication.sharedApplication;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow) return w;
            }
        }
    }
    return app.keyWindow;
}

static BOOL LBShouldSkipDebugPanelVC(UIViewController *vc) {
    return g_panelVC && vc == g_panelVC;
}

static BOOL LBClassNameContains(id obj, NSArray<NSString *> *needles) {
    if (!obj) return NO;
    NSString *n = NSStringFromClass(object_getClass(obj));
    for (NSString *needle in needles) {
        if ([n containsString:needle]) return YES;
    }
    return NO;
}

/// 从 root 向下收集完整 VC 链（nav 全栈 + tab + child + presented），跳过 Debug 面板自身
static void LBCollectVCChain(UIViewController *vc, NSMutableArray<UIViewController *> *chain,
                             NSMutableSet<NSValue *> *seen) {
    if (!vc) return;
    NSValue *key = [NSValue valueWithNonretainedObject:vc];
    if ([seen containsObject:key]) return;
    [seen addObject:key];
    if (!LBShouldSkipDebugPanelVC(vc)) {
        [chain addObject:vc];
    }
    if ([vc isKindOfClass:[UINavigationController class]]) {
        for (UIViewController *n in ((UINavigationController *)vc).viewControllers) {
            LBCollectVCChain(n, chain, seen);
        }
    } else if ([vc isKindOfClass:[UITabBarController class]]) {
        UITabBarController *tab = (UITabBarController *)vc;
        for (UIViewController *t in tab.viewControllers) {
            LBCollectVCChain(t, chain, seen);
        }
    } else {
        for (UIViewController *ch in vc.childViewControllers) {
            LBCollectVCChain(ch, chain, seen);
        }
    }
    if (vc.presentedViewController) {
        LBCollectVCChain(vc.presentedViewController, chain, seen);
    }
}

static NSArray<UIViewController *> *LBVCStackFromRoot(UIViewController *root) {
    if (!root) return @[];
    NSMutableArray<UIViewController *> *chain = [NSMutableArray array];
    NSMutableSet<NSValue *> *seen = [NSMutableSet set];
    LBCollectVCChain(root, chain, seen);
    return chain;
}

/// 顶层活跃链（用于面板 present 锚点），遇 Debug 面板则停在 presenting
static UIViewController *LBTopViewController(UIViewController *root) {
    if (!root) return nil;
    UIViewController *cur = root;
    while (YES) {
        if (cur.presentedViewController) {
            if (LBShouldSkipDebugPanelVC(cur.presentedViewController)) {
                return cur;
            }
            cur = cur.presentedViewController;
            continue;
        }
        if ([cur isKindOfClass:[UINavigationController class]]) {
            UINavigationController *nav = (UINavigationController *)cur;
            if (nav.viewControllers.count > 0) {
                cur = nav.viewControllers.lastObject;
                continue;
            }
        }
        if ([cur isKindOfClass:[UITabBarController class]]) {
            UITabBarController *tab = (UITabBarController *)cur;
            if (tab.selectedViewController) {
                cur = tab.selectedViewController;
                continue;
            }
        }
        break;
    }
    return cur;
}

static UIViewController *LBFindReaderVC(NSArray<UIViewController *> *stack) {
    for (NSInteger i = (NSInteger)stack.count - 1; i >= 0; i--) {
        NSString *cn = NSStringFromClass(object_getClass(stack[(NSUInteger)i]));
        if ([cn hasPrefix:@"TextReadVC"]) return stack[(NSUInteger)i];
    }
    for (NSInteger i = (NSInteger)stack.count - 1; i >= 0; i--) {
        NSString *cn = NSStringFromClass(object_getClass(stack[(NSUInteger)i]));
        if ([cn containsString:@"ReadVCBase"]) return stack[(NSUInteger)i];
    }
    return nil;
}

static BOOL LBObjectHasTextViewL(id obj) {
    if (!obj) return NO;
    @try {
        id tv = [obj valueForKey:@"textViewL"];
        return tv != nil;
    } @catch (__unused NSException *e) {
        return NO;
    }
}

static UIView *LBFindContainerInView(UIView *root) {
    if (!root) return nil;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    NSMutableSet<NSValue *> *seen = [NSMutableSet set];
    NSArray *needles = @[@"TextRPageContainer", @"ReadPageContainer", @"PageContainer", @"TextReadTV"];
    while (queue.count > 0) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        NSValue *key = [NSValue valueWithNonretainedObject:v];
        if ([seen containsObject:key]) continue;
        [seen addObject:key];
        if (LBClassNameContains(v, needles)) return v;
        if (LBObjectHasTextViewL(v)) return v;
        for (UIView *sub in v.subviews) [queue addObject:sub];
    }
    return nil;
}

/// 全窗口视图树兜底：TextReadTV 或含 textViewL 的宿主
static id LBFindReaderHostInWindow(UIWindow *win) {
    if (!win) return nil;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:win];
    NSMutableSet<NSValue *> *seen = [NSMutableSet set];
    UIView *textReadTV = nil;
    id textViewLHost = nil;
    while (queue.count > 0) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        NSValue *key = [NSValue valueWithNonretainedObject:v];
        if ([seen containsObject:key]) continue;
        [seen addObject:key];
        NSString *cn = NSStringFromClass(object_getClass(v));
        if ([cn containsString:@"TextReadTV"]) {
            textReadTV = v;
            break;
        }
        if (!textViewLHost && LBObjectHasTextViewL(v)) textViewLHost = v;
        for (UIView *sub in v.subviews) [queue addObject:sub];
    }
    if (textReadTV) return textReadTV;
    if (textViewLHost) return textViewLHost;
    return nil;
}

/// 视图树中按类名片段查找首个匹配视图
static UIView *LBFindViewByClassNeedle(UIView *root, NSString *needle) {
    if (!root || needle.length == 0) return nil;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    NSMutableSet<NSValue *> *seen = [NSMutableSet set];
    while (queue.count > 0) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        NSValue *key = [NSValue valueWithNonretainedObject:v];
        if ([seen containsObject:key]) continue;
        [seen addObject:key];
        if ([NSStringFromClass(object_getClass(v)) containsString:needle]) return v;
        for (UIView *sub in v.subviews) [queue addObject:sub];
    }
    return nil;
}

static id LBResolveContainerFromReaderVC(UIViewController *readerVC) {
    if (!readerVC) return nil;
    for (NSString *k in @[@"container", @"pageContainer", @"rPageContainer",
                          @"readPageContainer", @"scrollContainer"]) {
        @try {
            id v = [readerVC valueForKey:k];
            if (v) return v;
        } @catch (__unused NSException *e) {}
    }
    if (readerVC.isViewLoaded && readerVC.view) {
        UIView *c = LBFindViewByClassNeedle(readerVC.view, @"TextRPageContainer");
        if (c) return c;
        return LBFindContainerInView(readerVC.view);
    }
    return nil;
}

static id LBResolveReaderHost(UIViewController *readerVC, UIWindow *win) {
    if (readerVC) {
        id container = LBResolveContainerFromReaderVC(readerVC);
        if (container) return container;
        if (LBObjectHasTextViewL(readerVC)) return readerVC;
        return readerVC;
    }
    return LBFindReaderHostInWindow(win);
}

static void LBDumpReadPageModelIvars(id model, NSMutableString *out);
static void LBDescribeTextView(id tv, NSString *key, NSMutableString *out);

static void LBDumpTextReadTVIvarNames(id tv, NSMutableString *out) {
    if (!out) return;
    [out appendString:@"TextReadTV ivars:\n"];
    Class cls = tv ? object_getClass(tv) : NSClassFromString(@"TextReadTV");
    if (!cls) {
        [out appendString:@"  (class TextReadTV not found)\n"];
        return;
    }
    NSUInteger parts = 0;
    while (cls && cls != [NSObject class] && parts < 32) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        if (ivars) {
            for (unsigned int i = 0; i < count && parts < 32; i++) {
                const char *iname = ivar_getName(ivars[i]);
                const char *itype = ivar_getTypeEncoding(ivars[i]);
                if (!iname) continue;
                [out appendFormat:@"  %s:%s\n", iname, itype ? itype : "?"];
                parts++;
            }
            free(ivars);
        }
        cls = class_getSuperclass(cls);
    }
}

static void LBDumpReaderScope(id obj, NSString *label, NSMutableString *out) {
    if (!out) return;
    if (!obj) {
        [out appendFormat:@"--- %@: nil ---\n", label];
        return;
    }
    [out appendFormat:@"--- %@ cls=%@ ---\n", label, NSStringFromClass(object_getClass(obj))];
    NSArray *keys = @[@"textViewL", @"textViewR", @"curPageTV", @"textView",
                      @"pageModel", @"curPageModel"];
    for (NSString *k in keys) {
        @try {
            id v = [obj valueForKey:k];
            if ([k containsString:@"textView"] || [k containsString:@"PageTV"] ||
                [k isEqualToString:@"textView"]) {
                LBDescribeTextView(v, k, out);
            } else if (v) {
                [out appendFormat:@"%@: %@\n", k, NSStringFromClass(object_getClass(v))];
                LBDumpReadPageModelIvars(v, out);
            } else {
                [out appendFormat:@"%@: nil\n", k];
            }
        } @catch (NSException *ex) {
            [out appendFormat:@"%@: KVC error %@\n", k, ex.reason ?: @""];
        }
    }
}

#pragma mark - ReadPageModel / TextView dump (只读，复刻 LBDumpReadPageModelIvars + LBForceTextReadTVRefresh)

static NSString *LBDescribeIvarValue(id model, Ivar iv) {
    @try {
        id val = object_getIvar(model, iv);
        if (!val) return @"null";
        if ([val isKindOfClass:[NSAttributedString class]]) {
            return [NSString stringWithFormat:@"Attr len=%lu", (unsigned long)[(NSAttributedString *)val length]];
        }
        if ([val isKindOfClass:[NSString class]]) {
            NSString *s = (NSString *)val;
            NSString *head = s.length > 40 ? [s substringToIndex:40] : s;
            return [NSString stringWithFormat:@"NSString len=%lu head=%@", (unsigned long)s.length, head];
        }
        if ([val isKindOfClass:[NSArray class]]) {
            return [NSString stringWithFormat:@"NSArray count=%lu", (unsigned long)[(NSArray *)val count]];
        }
        return NSStringFromClass(object_getClass(val));
    } @catch (NSException *ex) {
        return [NSString stringWithFormat:@"err:%@", ex.reason ?: @""];
    }
}

static void LBDumpReadPageModelIvars(id model, NSMutableString *out) {
    if (!model || !out) return;
    Class cls = object_getClass(model);
    NSUInteger parts = 0;
    [out appendFormat:@"ReadPageModel cls=%@\n", NSStringFromClass(cls)];
    while (cls && cls != [NSObject class] && parts < 24) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        if (ivars) {
            for (unsigned int i = 0; i < count && parts < 24; i++) {
                const char *iname = ivar_getName(ivars[i]);
                const char *itype = ivar_getTypeEncoding(ivars[i]);
                if (!iname) continue;
                NSString *val = LBDescribeIvarValue(model, ivars[i]);
                [out appendFormat:@"  %s:%s = %@\n", iname, itype ? itype : "?", val];
                parts++;
            }
            free(ivars);
        }
        cls = class_getSuperclass(cls);
    }
}

static void LBDescribeTextView(id tv, NSString *key, NSMutableString *out) {
    if (!out) return;
    if (!tv || ![tv isKindOfClass:[UIView class]]) {
        [out appendFormat:@"%@: nil\n", key];
        return;
    }
    UIView *view = (UIView *)tv;
    NSUInteger txtLen = 0;
    @try {
        if ([tv respondsToSelector:@selector(attributedText)]) {
            NSAttributedString *attr = [tv valueForKey:@"attributedText"];
            if ([attr isKindOfClass:[NSAttributedString class]]) txtLen = attr.length;
        }
    } @catch (__unused NSException *e) {}
    [out appendFormat:@"%@ cls=%@ txtLen=%lu frame=%@ hidden=%d alpha=%.2f super=%@ subviews=%lu\n",
     key,
     NSStringFromClass(object_getClass(tv)),
     (unsigned long)txtLen,
     NSStringFromCGRect(view.frame),
     view.isHidden,
     view.alpha,
     view.superview ? NSStringFromClass(object_getClass(view.superview)) : @"-",
     (unsigned long)view.subviews.count];
}

static NSString *LBBuildReaderDump(void) {
    NSMutableString *out = [NSMutableString string];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
    fmt.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    [out appendFormat:@"=== legado debug dump %@ ===\n", [fmt stringFromDate:[NSDate date]]];

    UIWindow *win = LBKeyWindow();
    if (!win) {
        [out appendString:@"error: no keyWindow\n"];
        return out;
    }
    UIViewController *root = win.rootViewController;
    NSArray<UIViewController *> *stack = LBVCStackFromRoot(root);
    [out appendString:@"vcStack:\n"];
    for (UIViewController *vc in stack) {
        [out appendFormat:@"  %@\n", NSStringFromClass(object_getClass(vc))];
    }

    UIViewController *readerVC = LBFindReaderVC(stack);
    [out appendFormat:@"readerVC=%@\n", readerVC ? NSStringFromClass(object_getClass(readerVC)) : @"-"];

    id container = readerVC ? LBResolveContainerFromReaderVC(readerVC) : nil;
    UIView *containerPage = nil;
    if (readerVC.isViewLoaded && readerVC.view) {
        containerPage = LBFindViewByClassNeedle(readerVC.view, @"TextRPageContainerPage");
    }
    UIView *textReadTVView = nil;
    if (readerVC.isViewLoaded && readerVC.view) {
        textReadTVView = LBFindViewByClassNeedle(readerVC.view, @"TextReadTV");
    }

    LBDumpReaderScope(readerVC, @"TextReadVC3", out);
    LBDumpReaderScope(container, @"TextRPageContainer", out);
    LBDumpReaderScope(containerPage, @"TextRPageContainerPage", out);

    id host = container ?: LBResolveReaderHost(readerVC, win);
    if (host) {
        [out appendFormat:@"readerHost=%@\n", NSStringFromClass(object_getClass(host))];
    } else {
        [out appendString:@"readerHost=-\n"];
    }

    LBDumpTextReadTVIvarNames(textReadTVView, out);
    if (textReadTVView) {
        [out appendFormat:@"TextReadTV instance cls=%@\n",
         NSStringFromClass(object_getClass(textReadTVView))];
        LBDescribeTextView(textReadTVView, @"textReadTV(inst)", out);
        id tvPm = nil;
        @try { tvPm = [textReadTVView valueForKey:@"pageModel"]; } @catch (__unused NSException *e) {}
        if (tvPm) {
            [out appendString:@"--- TextReadTV.pageModel ---\n"];
            LBDumpReadPageModelIvars(tvPm, out);
        }
    }
    return out;
}

static void LBForceTextReadTVRefresh(UIView *textReadTV) {
    if (!textReadTV) return;
    @try {
        textReadTV.hidden = NO;
        textReadTV.alpha = 1;
        [textReadTV.superview bringSubviewToFront:textReadTV];
        for (NSString *selName in @[@"reloadContent", @"reloadView", @"refreshView",
                                    @"setNeedsDisplay", @"layoutIfNeeded"]) {
            SEL s = NSSelectorFromString(selName);
            if ([textReadTV respondsToSelector:s]) {
                if ([selName isEqualToString:@"layoutIfNeeded"]) {
                    [textReadTV layoutIfNeeded];
                } else if ([selName isEqualToString:@"setNeedsDisplay"]) {
                    [textReadTV setNeedsDisplay];
                } else {
                    ((void (*)(id, SEL))objc_msgSend)(textReadTV, s);
                }
            }
        }
        SEL rcs = NSSelectorFromString(@"resetContentPosByScreenSize:");
        if ([textReadTV respondsToSelector:rcs]) {
            CGSize sz = UIScreen.mainScreen.bounds.size;
            ((void (*)(id, SEL, CGSize))objc_msgSend)(textReadTV, rcs, sz);
        }
        [textReadTV setNeedsLayout];
        [textReadTV setNeedsDisplay];
        [textReadTV layoutIfNeeded];
    } @catch (__unused NSException *e) {}
}

static NSString *LBRefreshReaderViews(void) {
    NSMutableString *out = [NSMutableString stringWithString:@"refresh:\n"];
    UIWindow *win = LBKeyWindow();
    if (!win) return @"refresh: no keyWindow\n";
    NSArray *stack = LBVCStackFromRoot(win.rootViewController);
    UIViewController *readerVC = LBFindReaderVC(stack);
    id host = LBResolveReaderHost(readerVC, win);
    if (!host) return @"refresh: no host\n";

    SEL rcs = NSSelectorFromString(@"resetContentPosByScreenSize:");
    if ([host respondsToSelector:rcs]) {
        CGSize sz = UIScreen.mainScreen.bounds.size;
        if (readerVC && readerVC.isViewLoaded && readerVC.view.bounds.size.width > 10) {
            sz = readerVC.view.bounds.size;
        } else if ([host isKindOfClass:[UIView class]]) {
            UIView *hv = (UIView *)host;
            if (hv.bounds.size.width > 10) sz = hv.bounds.size;
        }
        @try {
            ((void (*)(id, SEL, CGSize))objc_msgSend)(host, rcs, sz);
            [out appendString:@"  host.resetContentPosByScreenSize OK\n"];
        } @catch (NSException *ex) {
            [out appendFormat:@"  host.resetContentPosByScreenSize EX %@\n", ex.reason ?: @""];
        }
    }

    for (NSString *k in @[@"textViewL", @"textViewR", @"curPageTV", @"textView"]) {
        @try {
            id tv = [host valueForKey:k];
            if ([tv isKindOfClass:[UIView class]]) {
                LBForceTextReadTVRefresh((UIView *)tv);
                [out appendFormat:@"  %@ refreshed\n", k];
            }
        } @catch (__unused NSException *e) {}
    }
    return out;
}

#pragma mark - Crash handlers

static void LBRecordCrash(NSString *kind, NSString *detail, NSArray<NSString *> *symbols) {
    NSMutableString *blob = [NSMutableString string];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
    fmt.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    [blob appendFormat:@"=== %@ %@ ===\n", kind, [fmt stringFromDate:[NSDate date]]];
    [blob appendFormat:@"%@\n", detail ?: @""];
    if (symbols.count > 0) {
        [blob appendString:@"callStackSymbols:\n"];
        for (NSString *ln in symbols) [blob appendFormat:@"  %@\n", ln];
    }
    g_lastCrashText = blob;
    LBWriteDebugFile(@"legado_debug_crash.txt", blob);
    LBAppendPanel(blob);
}

static void LBUncaughtExceptionHandler(NSException *exception) {
    LBRecordCrash(@"NSException",
                  [NSString stringWithFormat:@"name=%@\nreason=%@",
                   exception.name, exception.reason],
                  exception.callStackSymbols);
}

static void LBSignalHandler(int sig, siginfo_t *info, void *uap) {
    (void)info;
    (void)uap;
    void *frames[32];
    int n = backtrace(frames, 32);
    char **syms = backtrace_symbols(frames, n);
    NSMutableArray *lines = [NSMutableArray array];
    if (syms) {
        for (int i = 0; i < n; i++) {
            if (syms[i]) [lines addObject:[NSString stringWithUTF8String:syms[i]]];
        }
        free(syms);
    }
    NSString *sigName = @"SIGNAL";
    if (sig == SIGABRT) sigName = @"SIGABRT";
    else if (sig == SIGSEGV) sigName = @"SIGSEGV";
    LBRecordCrash(sigName, [NSString stringWithFormat:@"sig=%d", sig], lines);

    signal(sig, SIG_DFL);
    raise(sig);
}

static void LBInstallSignalHandlers(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = LBSignalHandler;
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGABRT, &sa, NULL);
    sigaction(SIGSEGV, &sa, NULL);
}

#pragma mark - Panel UI

static void LBDismissPanel(void) {
    if (g_panelVC && g_panelVC.presentingViewController) {
        [g_panelVC dismissViewControllerAnimated:YES completion:nil];
    }
    g_panelVC = nil;
    g_panelTextView = nil;
}

static void LBPresentPanelFrom(UIViewController *anchor) {
    if (!anchor) return;
    if (g_panelVC && g_panelVC.presentingViewController) return;

    g_panelBuffer = [NSMutableString stringWithString:@"LegadoBridgeDebug 面板\n三指单击或 legado://debugPanel 关闭\n\n"];

    UIViewController *panel = [[UIViewController alloc] init];
    panel.modalPresentationStyle = UIModalPresentationPageSheet;
    panel.view.backgroundColor = [UIColor systemBackgroundColor];

    UITextView *tv = [[UITextView alloc] initWithFrame:CGRectZero];
    tv.editable = NO;
    tv.font = [UIFont fontWithName:@"Menlo" size:11] ?: [UIFont systemFontOfSize:11];
    tv.text = g_panelBuffer;
    tv.translatesAutoresizingMaskIntoConstraints = NO;
    [panel.view addSubview:tv];
    g_panelTextView = tv;

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.distribution = UIStackViewDistributionFillEqually;
    stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [panel.view addSubview:stack];

    UIButton *(^makeBtn)(NSString *, SEL) = ^UIButton *(NSString *title, SEL action) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:title forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        b.backgroundColor = [UIColor secondarySystemBackgroundColor];
        b.layer.cornerRadius = 6;
        [b addTarget:[LBDebugPanel class] action:action forControlEvents:UIControlEventTouchUpInside];
        return b;
    };

    [stack addArrangedSubview:makeBtn(@"Dump", @selector(lb_debugDumpAction))];
    [stack addArrangedSubview:makeBtn(@"重触发", @selector(lb_debugRefreshAction))];
    [stack addArrangedSubview:makeBtn(@"崩溃栈", @selector(lb_debugCrashAction))];
    [stack addArrangedSubview:makeBtn(@"关闭", @selector(lb_debugCloseAction))];

    UILayoutGuide *safe = panel.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
        [stack.leadingAnchor constraintEqualToAnchor:panel.view.leadingAnchor constant:12],
        [stack.trailingAnchor constraintEqualToAnchor:panel.view.trailingAnchor constant:-12],
        [stack.heightAnchor constraintEqualToConstant:40],
        [tv.topAnchor constraintEqualToAnchor:stack.bottomAnchor constant:8],
        [tv.leadingAnchor constraintEqualToAnchor:panel.view.leadingAnchor constant:8],
        [tv.trailingAnchor constraintEqualToAnchor:panel.view.trailingAnchor constant:-8],
        [tv.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8],
    ]];

    g_panelVC = panel;
    [anchor presentViewController:panel animated:YES completion:nil];
}

static void LBOnThreeFingerTap(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = LBKeyWindow();
        UIViewController *top = LBTopViewController(win.rootViewController);
        if (g_panelVC && g_panelVC.presentingViewController) {
            LBDismissPanel();
            return;
        }
        LBPresentPanelFrom(top);
    });
}

static void LBInstallThreeFingerGesture(void) {
    if (g_gestureInstalled) return;
    UIWindow *win = LBKeyWindow();
    if (!win) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            LBInstallThreeFingerGesture();
        });
        return;
    }
    // 三指单击：真机最稳的调试入口
    UITapGestureRecognizer *threeFinger = [[UITapGestureRecognizer alloc] initWithTarget:[LBDebugPanel class]
                                                                                  action:@selector(lb_threeFingerTap:)];
    threeFinger.numberOfTapsRequired = 1;
    threeFinger.numberOfTouchesRequired = 3;
    threeFinger.cancelsTouchesInView = NO;
    [win addGestureRecognizer:threeFinger];

    // 单指三击：备用（阅读页可能吞掉）
    UITapGestureRecognizer *tripleTap = [[UITapGestureRecognizer alloc] initWithTarget:[LBDebugPanel class]
                                                                                action:@selector(lb_threeFingerTap:)];
    tripleTap.numberOfTapsRequired = 3;
    tripleTap.numberOfTouchesRequired = 1;
    tripleTap.cancelsTouchesInView = NO;
    [win addGestureRecognizer:tripleTap];

    g_gestureInstalled = YES;
}

#pragma mark - Debug deep link (LegadoBridgeDebug only)

static BOOL LBDebugHandlesOpenURL(NSURL *url) {
    if (!url) return NO;
    NSString *abs = url.absoluteString ?: @"";
    NSString *host = url.host.lowercaseString ?: @"";
    if ([abs hasPrefix:@"legado://debugDump"] || [abs hasPrefix:@"yuedu://debugDump"] ||
        [host isEqualToString:@"debugdump"]) {
        [LBDebugPanel lb_debugDumpAction];
        return YES;
    }
    if ([abs hasPrefix:@"legado://debugPanel"] || [abs hasPrefix:@"yuedu://debugPanel"] ||
        [host isEqualToString:@"debugpanel"]) {
        LBOnThreeFingerTap();
        return YES;
    }
    return NO;
}

static BOOL LBDebug_AppDelegate_openURL_options_IMP(id self, SEL _cmd, id application, NSURL *url, NSDictionary *options) {
    if (LBDebugHandlesOpenURL(url)) return YES;
    if (LBDebugOrig_AppDelegate_openURL_options) {
        return LBDebugOrig_AppDelegate_openURL_options(self, _cmd, application, url, options);
    }
    return NO;
}

static void LBInstallDebugOpenURLHook(void) {
    Class appDelegateClass = objc_getClass("AppDelegate");
    if (!appDelegateClass) return;
    SEL sel = @selector(application:openURL:options:);
    Method m = class_getInstanceMethod(appDelegateClass, sel);
    if (!m) return;
    LBDebugOrig_AppDelegate_openURL_options =
        (BOOL (*)(id, SEL, id, NSURL *, NSDictionary *))method_getImplementation(m);
    method_setImplementation(m, (IMP)LBDebug_AppDelegate_openURL_options_IMP);
}

#pragma mark - LBDebugPanel

@implementation LBDebugPanel

+ (void)load {
    dispatch_async(dispatch_get_main_queue(), ^{
        LBInstallThreeFingerGesture();
        LBInstallDebugOpenURLHook();
    });
    NSSetUncaughtExceptionHandler(&LBUncaughtExceptionHandler);
    LBInstallSignalHandlers();
}

+ (void)lb_threeFingerTap:(UITapGestureRecognizer *)gr {
    if (gr.state == UIGestureRecognizerStateRecognized) LBOnThreeFingerTap();
}

+ (void)lb_debugDumpAction {
    NSString *dump = LBBuildReaderDump();
    LBWriteDebugFile(@"legado_debug_dump.txt", dump);
    LBAppendPanel(dump);
}

+ (void)lb_debugRefreshAction {
    NSString *msg = LBRefreshReaderViews();
    LBAppendPanel(msg);
    NSString *after = LBBuildReaderDump();
    LBAppendPanel(after);
    LBWriteDebugFile(@"legado_debug_dump.txt", [NSString stringWithFormat:@"%@\n%@", msg, after]);
}

+ (void)lb_debugCrashAction {
    if (g_lastCrashText.length > 0) {
        LBAppendPanel(g_lastCrashText);
        return;
    }
    NSString *path = [LBDocumentsDirectory() stringByAppendingPathComponent:@"legado_debug_crash.txt"];
    NSString *disk = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (disk.length > 0) {
        LBAppendPanel(disk);
    } else {
        LBAppendPanel(@"（尚无崩溃记录；NSArrayM length 等 uncaught 会自动落盘 legado_debug_crash.txt）");
    }
}

+ (void)lb_debugCloseAction {
    LBDismissPanel();
}

@end
