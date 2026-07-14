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

static UIViewController *LBTopViewController(UIViewController *root) {
    if (!root) return nil;
    UIViewController *cur = root;
    while (YES) {
        if (cur.presentedViewController) {
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

static NSArray<UIViewController *> *LBVCStackFromRoot(UIViewController *root) {
    NSMutableArray *stack = [NSMutableArray array];
    UIViewController *cur = root;
    while (cur) {
        [stack addObject:cur];
        if (cur.presentedViewController) {
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
    return stack;
}

static BOOL LBClassNameContains(id obj, NSArray<NSString *> *needles) {
    if (!obj) return NO;
    NSString *n = NSStringFromClass(object_getClass(obj));
    for (NSString *needle in needles) {
        if ([n containsString:needle]) return YES;
    }
    return NO;
}

static UIViewController *LBFindReaderVC(NSArray<UIViewController *> *stack) {
    NSArray *needles = @[@"TextRead", @"ReadVC", @"TextRPage"];
    for (NSInteger i = (NSInteger)stack.count - 1; i >= 0; i--) {
        if (LBClassNameContains(stack[(NSUInteger)i], needles)) return stack[(NSUInteger)i];
    }
    return nil;
}

static UIView *LBFindContainerInView(UIView *root) {
    if (!root) return nil;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    NSMutableSet<NSValue *> *seen = [NSMutableSet set];
    NSArray *needles = @[@"TextRPageContainer", @"TextReadTV"];
    while (queue.count > 0) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        NSValue *key = [NSValue valueWithNonretainedObject:v];
        if ([seen containsObject:key]) continue;
        [seen addObject:key];
        if (LBClassNameContains(v, needles)) return v;
        for (UIView *sub in v.subviews) [queue addObject:sub];
    }
    return nil;
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
    UIView *container = readerVC ? (LBFindContainerInView(readerVC.view) ?: readerVC.view) : nil;
    id host = container ?: readerVC;
    if (!host) {
        [out appendString:@"error: no reader host\n"];
        return out;
    }

    NSArray *tvKeys = @[@"textViewL", @"textViewR", @"curPageTV", @"textView"];
    for (NSString *k in tvKeys) {
        @try {
            id tv = [host valueForKey:k];
            LBDescribeTextView(tv, k, out);
        } @catch (__unused NSException *e) {
            [out appendFormat:@"%@: KVC error\n", k];
        }
    }

    id pageModel = nil;
    @try { pageModel = [host valueForKey:@"pageModel"]; } @catch (__unused NSException *e) {}
    if (!pageModel) {
        @try { pageModel = [host valueForKey:@"curPageModel"]; } @catch (__unused NSException *e) {}
    }
    if (pageModel) {
        [out appendString:@"--- pageModel ---\n"];
        LBDumpReadPageModelIvars(pageModel, out);
    } else {
        [out appendString:@"pageModel: nil\n"];
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
    id host = readerVC ? (LBFindContainerInView(readerVC.view) ?: readerVC) : nil;
    if (!host) return @"refresh: no host\n";

    SEL rcs = NSSelectorFromString(@"resetContentPosByScreenSize:");
    if ([host respondsToSelector:rcs]) {
        CGSize sz = UIScreen.mainScreen.bounds.size;
        if (readerVC.isViewLoaded && readerVC.view.bounds.size.width > 10) {
            sz = readerVC.view.bounds.size;
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

    g_panelBuffer = [NSMutableString stringWithString:@"LegadoBridgeDebug 面板\n三指再次关闭\n\n"];

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
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:[LBDebugPanel class]
                                                                          action:@selector(lb_threeFingerTap:)];
    tap.numberOfTapsRequired = 3;
    tap.numberOfTouchesRequired = 1;
    [win addGestureRecognizer:tap];
    g_gestureInstalled = YES;
}

#pragma mark - LBDebugPanel

@implementation LBDebugPanel

+ (void)load {
    dispatch_async(dispatch_get_main_queue(), ^{
        LBInstallThreeFingerGesture();
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
