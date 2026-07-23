#import "LBDebugPanel.h"
#import "LBForensics.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <signal.h>
#import <execinfo.h>
#import <string.h>

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

/// 启动时将 Bundle 内 reader-build-manifest.json 复制到 Documents，供 ios-mcp 沙盒读取
static void LBCopyBuildManifestToDocuments(void) {
    NSBundle *bundle = [NSBundle mainBundle];
    NSString *src = [bundle pathForResource:@"reader-build-manifest" ofType:@"json"];
    if (!src.length) return;
    NSString *text = [NSString stringWithContentsOfFile:src encoding:NSUTF8StringEncoding error:nil];
    if (!text.length) return;
    LBWriteDebugFile(@"reader-build-manifest.json", text);
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
    // AK：非主线程禁止任何 windows API
    if (![NSThread isMainThread]) return nil;
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
    NSArray *needles = @[@"TextRead", @"ReadVC", @"PageContainer", @"TextRPage"];
    for (NSInteger i = (NSInteger)stack.count - 1; i >= 0; i--) {
        if (LBClassNameContains(stack[(NSUInteger)i], needles)) return stack[(NSUInteger)i];
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

static id LBResolveReaderHost(UIViewController *readerVC, UIWindow *win) {
    if (readerVC) {
        UIView *container = nil;
        if (readerVC.isViewLoaded && readerVC.view) {
            container = LBFindContainerInView(readerVC.view);
        }
        if (container) return container;
        for (NSString *k in @[@"container", @"pageContainer", @"rPageContainer",
                              @"readPageContainer", @"scrollContainer"]) {
            @try {
                id v = [readerVC valueForKey:k];
                if (v) return v;
            } @catch (__unused NSException *e) {}
        }
        if (LBObjectHasTextViewL(readerVC)) return readerVC;
        return readerVC;
    }
    return LBFindReaderHostInWindow(win);
}

#pragma mark - Refresh helpers（面板「重触发」；dump 本身只读）

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
    if (!host) host = LBFindReaderHostInWindow(win);
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

static NSString *LBDebugParseDumpPhase(NSURL *url) {
    if (!url) return nil;
    NSURLComponents *comp = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in comp.queryItems) {
        if ([item.name isEqualToString:@"phase"] && item.value.length > 0) {
            return item.value;
        }
    }
    return nil;
}

static BOOL LBDebugHandlesOpenURL(NSURL *url) {
    if (!url) return NO;
    NSString *abs = url.absoluteString ?: @"";
    NSString *host = url.host.lowercaseString ?: @"";
    if ([abs hasPrefix:@"legado://debugDump"] || [abs hasPrefix:@"yuedu://debugDump"] ||
        [host isEqualToString:@"debugdump"]) {
        NSString *phase = LBDebugParseDumpPhase(url);
        if (phase.length) LBForensicsSetPendingDumpPhase(phase);
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

static void (*LBOrig_UIApplication_openURL_options_completion)(id, SEL, NSURL *, NSDictionary *, void (^)(BOOL)) = NULL;

static void LBDebug_UIApplication_openURL_completion_IMP(id self, SEL _cmd, NSURL *url, NSDictionary *options,
                                                       void (^completion)(BOOL)) {
    if (LBDebugHandlesOpenURL(url)) {
        if (completion) completion(YES);
        return;
    }
    if (LBOrig_UIApplication_openURL_options_completion) {
        LBOrig_UIApplication_openURL_options_completion(self, _cmd, url, options, completion);
    } else if (completion) {
        completion(NO);
    }
}

static void LBInstallDebugOpenURLHook(void) {
    Class appDelegateClass = objc_getClass("AppDelegate");
    if (appDelegateClass) {
        SEL sel = @selector(application:openURL:options:);
        Method m = class_getInstanceMethod(appDelegateClass, sel);
        if (m && !LBDebugOrig_AppDelegate_openURL_options) {
            LBDebugOrig_AppDelegate_openURL_options =
                (BOOL (*)(id, SEL, id, NSURL *, NSDictionary *))method_getImplementation(m);
            method_setImplementation(m, (IMP)LBDebug_AppDelegate_openURL_options_IMP);
        }
    }
    Class appCls = [UIApplication class];
    Method m2 = class_getInstanceMethod(appCls, @selector(openURL:options:completionHandler:));
    if (m2 && !LBOrig_UIApplication_openURL_options_completion) {
        LBOrig_UIApplication_openURL_options_completion =
            (void (*)(id, SEL, NSURL *, NSDictionary *, void (^)(BOOL)))method_getImplementation(m2);
        method_setImplementation(m2, (IMP)LBDebug_UIApplication_openURL_completion_IMP);
    }
}

#pragma mark - LBDebugPanel

@implementation LBDebugPanel

+ (void)load {
    LBCopyBuildManifestToDocuments();
    LBForensicsInstallEarlyWrap();
    dispatch_async(dispatch_get_main_queue(), ^{
        LBForensicsInstallObservers();
        LBInstallThreeFingerGesture();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            LBInstallDebugOpenURLHook();
        });
    });
    NSSetUncaughtExceptionHandler(&LBUncaughtExceptionHandler);
    LBInstallSignalHandlers();
}

+ (void)lb_threeFingerTap:(UITapGestureRecognizer *)gr {
    if (gr.state == UIGestureRecognizerStateRecognized) LBOnThreeFingerTap();
}

+ (NSString *)lb_debugDumpSyncWithPhase:(NSString *)phase {
    __block NSString *jsonPath = nil;
    void (^work)(void) = ^{
        @try {
            LBForensicsInstallObservers();
            NSString *p = phase.length ? phase : @"manual";
            NSDictionary *dump = LBForensicsPerformDump(p);
            NSDictionary<NSString *, NSString *> *paths = LBForensicsWriteDumpFiles(dump);
            jsonPath = paths[@"json"] ?: @"";
            LBWriteDebugFile(@"legado_debug_dump_ready.txt", jsonPath);
            // 8.5：dump 时通知 Hooks 落盘页位（杀进程前必经）
            [[NSNotificationCenter defaultCenter]
                postNotificationName:@"LBForensicsDumpDidFinish" object:nil];
        } @catch (NSException *ex) {
            NSString *err = [NSString stringWithFormat:@"forensics dump EX: %@", ex.reason ?: @""];
            LBWriteDebugFile(@"legado_debug_dump.txt", err);
            LBWriteDebugFile(@"legado_debug_dump_ready.txt", @"");
        }
    };
    if ([NSThread isMainThread]) {
        work();
    } else {
        dispatch_sync(dispatch_get_main_queue(), work);
    }
    return jsonPath ?: @"";
}

+ (void)lb_debugDumpAction {
    NSString *phase = LBForensicsConsumePendingDumpPhase();
    NSString *jsonPath = [self lb_debugDumpSyncWithPhase:phase];
    if (!jsonPath.length) return;
    NSString *txtPath = [[jsonPath stringByDeletingPathExtension] stringByAppendingPathExtension:@"txt"];
    NSString *summary = [NSString stringWithContentsOfFile:txtPath encoding:NSUTF8StringEncoding error:nil];
    NSMutableString *panel = [NSMutableString stringWithString:summary ?: @""];
    [panel appendFormat:@"\n--- files ---\njson: %@\ntext: %@\n", jsonPath, txtPath];
    LBAppendPanel(panel);
}

const char *LBDebugForceDump(const char *phase) {
    static char s_buf[512];
    s_buf[0] = '\0';
    NSString *p = phase ? [NSString stringWithUTF8String:phase] : @"manual";
    NSString *path = [LBDebugPanel lb_debugDumpSyncWithPhase:p];
    if (!path.length) return s_buf;
    strncpy(s_buf, path.UTF8String, sizeof(s_buf) - 1);
    s_buf[sizeof(s_buf) - 1] = '\0';
    return s_buf;
}

+ (void)lb_debugRefreshAction {
    NSString *msg = LBRefreshReaderViews();
    LBAppendPanel(msg);
    NSDictionary *dump = LBForensicsPerformDump(@"after_refresh");
    LBForensicsWriteDumpFiles(dump);
    LBAppendPanel(dump[@"textSummary"] ?: @"");
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
