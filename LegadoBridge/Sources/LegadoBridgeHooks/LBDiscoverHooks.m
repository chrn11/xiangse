#import "LBInternal.h"
#import "LegadoBridge.h"

/// 顶栏「发现」：切 Tab → 原生 BookWorld/Store → Legado explore 灌 arrBaseData（安全 cell）。
/// 禁止把 BookSearch 当发现页（用户反馈：点发现进了搜索）。

static BOOL sDiscoverTabActive = NO;
static NSTimeInterval sPreferDiscoverInjectUntil = 0;
static NSTimeInterval sLastDiscoverTriggerTs = 0;
static void (*sOrig_setSquare)(id, SEL, BOOL) = NULL;
static void (*sOrig_onSegmentChanged)(id, SEL) = NULL;
static void (*sOrig_onSegmentChange)(id, SEL, id) = NULL;
static IMP sOrig_worldAppear = NULL;
static void (*sOrig_setSelectedSegmentIndex)(id, SEL, NSInteger) = NULL;
static __weak UIViewController *sPinnedDiscoverHost;

static void LBDiscoverAppendMarker(NSString *line) {
    if (line.length == 0) return;
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_discover_hook.txt"];
    NSString *prev = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL] ?: @"";
    if (prev.length > 12000) {
        prev = [prev substringFromIndex:prev.length - 8000];
    }
    NSString *next = prev.length > 0
        ? [prev stringByAppendingFormat:@"\n%@", line]
        : line;
    [next writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

BOOL LBIsDiscoverTabActive(void) {
    if (sDiscoverTabActive) return YES;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    return (sPreferDiscoverInjectUntil > 0 && now < sPreferDiscoverInjectUntil);
}

void LBSetDiscoverTabActive(BOOL active) {
    sDiscoverTabActive = active;
    if (active) {
        // 人手点发现后需足够长窗口，避免 World 空白页盖住后 sticky 失效
        sPreferDiscoverInjectUntil = [[NSDate date] timeIntervalSince1970] + 120.0;
    }
    NSString *line = [NSString stringWithFormat:@"discoverTab active=%d stickyUntil=%.0f",
                      active ? 1 : 0, sPreferDiscoverInjectUntil];
    LBDiscoverAppendMarker(line);
}

static BOOL LBClassNameLooksDiscoverHost(NSString *cn) {
    if (cn.length == 0) return NO;
    if ([cn containsString:@"BookWorld"]) return YES;
    if ([cn containsString:@"BookStore"]) return YES;
    if ([cn containsString:@"Shudan"]) return YES;
    if ([cn containsString:@"BookListCon"]) return YES;
    if ([cn containsString:@"BookList"]) return YES;
    if ([cn containsString:@"BookSearch"]) return YES;
    if ([cn containsString:@"Square"]) return YES;
    return NO;
}

static void LBCollectDiscoverHostVCs(UIViewController *vc, NSMutableArray *out) {
    if (!vc) return;
    NSString *cn = NSStringFromClass([vc class]);
    if (LBClassNameLooksDiscoverHost(cn)) {
        [out addObject:vc];
    }
    for (UIViewController *child in vc.childViewControllers) {
        LBCollectDiscoverHostVCs(child, out);
    }
    if (vc.presentedViewController) {
        LBCollectDiscoverHostVCs(vc.presentedViewController, out);
    }
    if ([vc isKindOfClass:[UINavigationController class]]) {
        for (UIViewController *c in [(UINavigationController *)vc viewControllers]) {
            LBCollectDiscoverHostVCs(c, out);
        }
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        UIViewController *sel = [(UITabBarController *)vc selectedViewController];
        if (sel) LBCollectDiscoverHostVCs(sel, out);
    }
}

NSArray *LBFindDiscoverHostVCs(void) {
    // 发现注入：原生广场壳（World/Store/书单），禁止把 BookSearch 当发现页
    if (sPinnedDiscoverHost) {
        NSString *pcn = NSStringFromClass([sPinnedDiscoverHost class]);
        if ([pcn containsString:@"BookSearch"]) {
            sPinnedDiscoverHost = nil;
        }
    }
    if (sPinnedDiscoverHost) {
        return @[sPinnedDiscoverHost];
    }
    NSMutableArray *out = [NSMutableArray array];
    UIWindow *win = LBLegadoKeyWindow();
    if (win.rootViewController) {
        LBCollectDiscoverHostVCs(win.rootViewController, out);
    }
    NSMutableArray *hosts = [NSMutableArray array];
    for (UIViewController *vc in out) {
        NSString *cn = NSStringFromClass([vc class]);
        if ([cn containsString:@"BookSearch"]) continue;
        if ([cn containsString:@"BookWorld"] || [cn containsString:@"BookStore"] ||
            [cn containsString:@"Shudan"] || [cn containsString:@"BookList"]) {
            [hosts addObject:vc];
        }
    }
    return hosts;
}

static id LBLegadoManagerCore(void) {
    Class coreClass = NSClassFromString(@"LegadoBridge.LegadoBridgeCore");
    if (!coreClass) return nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    if ([coreClass respondsToSelector:@selector(shared)]) {
        return [coreClass performSelector:@selector(shared)];
    }
#pragma clang diagnostic pop
    return LBLegadoCoreIfReady();
}

static UINavigationController *LBDiscoverActiveNav(void) {
    UIWindow *win = LBLegadoKeyWindow();
    UIViewController *root = win.rootViewController;
    while (root.presentedViewController) root = root.presentedViewController;
    if ([root isKindOfClass:[UINavigationController class]]) {
        return (UINavigationController *)root;
    }
    if ([root isKindOfClass:[UITabBarController class]]) {
        UIViewController *sel = [(UITabBarController *)root selectedViewController];
        if ([sel isKindOfClass:[UINavigationController class]]) return (UINavigationController *)sel;
        if (sel.navigationController) return sel.navigationController;
    }
    return root.navigationController;
}

/// 弹出栈顶 BookSearch，避免盖住发现宿主
static void LBPopBookSearchIfNeeded(UINavigationController *nav) {
    if (!nav) return;
    NSArray *stack = nav.viewControllers;
    if (stack.count == 0) return;
    UIViewController *top = stack.lastObject;
    NSString *cn = NSStringFromClass([top class]);
    if ([cn containsString:@"BookSearch"]) {
        NSMutableArray *m = [stack mutableCopy];
        [m removeLastObject];
        [nav setViewControllers:m animated:NO];
    }
}

static void LBPopBlankDiscoverCovers(UINavigationController *nav, UIViewController *keep) {
    if (!nav) return;
    NSArray *stack = nav.viewControllers;
    if (stack.count <= 1) return;
    NSMutableArray *kept = [NSMutableArray array];
    BOOL removed = NO;
    for (UIViewController *vc in stack) {
        if (keep && vc == keep) {
            [kept addObject:vc];
            continue;
        }
        NSString *cn = NSStringFromClass([vc class]);
        // 发现态禁止保留误推的搜索页（用户反馈：点发现进了搜索）
        if ([cn containsString:@"BookSearch"]) {
            removed = YES;
            LBDiscoverAppendMarker([NSString stringWithFormat:@"discoverHost pop cover %@", cn]);
            continue;
        }
        [kept addObject:vc];
    }
    if (keep && ![kept containsObject:keep]) {
        [kept addObject:keep];
    }
    if (!removed || kept.count == 0 || kept.count == stack.count) return;
    @try {
        [nav setViewControllers:kept animated:NO];
    } @catch (__unused NSException *e) {}
}

static void LBBringPinnedDiscoverHostToFront(void) {
    UIViewController *pin = sPinnedDiscoverHost;
    UINavigationController *nav = (pin.navigationController ?: LBDiscoverActiveNav());
    if (!nav) return;
    // 先清掉误推的 BookSearch
    LBPopBlankDiscoverCovers(nav, pin);
    if (!pin) return;
    if ([nav.viewControllers containsObject:pin]) {
        if (nav.topViewController != pin) {
            [nav popToViewController:pin animated:NO];
            LBDiscoverAppendMarker(@"discoverHost bringFront popTo pin");
        }
    }
}

static NSTimeInterval sLastRescueScheduleTs = 0;

static void LBScheduleDiscoverHostRescue(void) {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (sLastRescueScheduleTs > 0 && (now - sLastRescueScheduleTs) < 2.5) {
        return;
    }
    sLastRescueScheduleTs = now;
    for (NSNumber *sec in @[ @0.4, @1.2 ]) {
        double d = sec.doubleValue;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!LBIsDiscoverTabActive()) return;
            LBEnsureNativeDiscoverHostPresented();
            LBBringPinnedDiscoverHostToFront();
        });
    }
}

/// 确保发现宿主：只用原生广场（World/Store），绝不 push BookSearch。
BOOL LBEnsureNativeDiscoverHostPresented(void) {
    UINavigationController *nav = LBDiscoverActiveNav();
    if (nav) {
        LBPopBookSearchIfNeeded(nav);
        LBPopBlankDiscoverCovers(nav, sPinnedDiscoverHost);
    }

    if (sPinnedDiscoverHost) {
        NSString *pcn = NSStringFromClass([sPinnedDiscoverHost class]);
        if ([pcn containsString:@"BookSearch"]) {
            sPinnedDiscoverHost = nil;
        } else if (sPinnedDiscoverHost.navigationController ||
                   (sPinnedDiscoverHost.isViewLoaded && sPinnedDiscoverHost.view.window)) {
            // 限频：reuse 每 5s 写一次，避免刷屏拖慢主线程
            static NSTimeInterval sLastReuseLog = 0;
            NSTimeInterval t = [[NSDate date] timeIntervalSince1970];
            if (t - sLastReuseLog > 5.0) {
                sLastReuseLog = t;
                LBDiscoverAppendMarker([NSString stringWithFormat:@"discoverHost reuse pin %@", pcn]);
            }
            return YES;
        } else {
            sPinnedDiscoverHost = nil;
        }
    }

    if (!nav) {
        LBDiscoverAppendMarker(@"discoverHost miss: no nav");
        return NO;
    }

    // 栈内已有原生广场壳则 pin
    for (UIViewController *vc in nav.viewControllers.reverseObjectEnumerator) {
        NSString *cn = NSStringFromClass([vc class]);
        if ([cn containsString:@"BookWorld"] || [cn containsString:@"BookStore"] ||
            [cn containsString:@"Shudan"]) {
            sPinnedDiscoverHost = vc;
            LBInstallSearchUIAppearFlush();
            LBDiscoverAppendMarker([NSString stringWithFormat:@"discoverHost reuse stacked %@", cn]);
            return YES;
        }
    }

    // 树里找（可能是 child，尚未进 nav 栈顶）
    NSArray *found = LBFindDiscoverHostVCs();
    if (found.count > 0) {
        sPinnedDiscoverHost = found.firstObject;
        LBInstallSearchUIAppearFlush();
        LBDiscoverAppendMarker([NSString stringWithFormat:@"discoverHost found %@",
                                NSStringFromClass([sPinnedDiscoverHost class])]);
        return YES;
    }

    // 尚无广场壳：等原生 setSquare 推出来（本函数不 push 任何 VC）
    LBDiscoverAppendMarker(@"discoverHost wait native World");
    return NO;
}

static void LBTriggerLegadoExploreForDiscoverTab(void) {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (sLastDiscoverTriggerTs > 0 && (now - sLastDiscoverTriggerTs) < 1.2) {
        return;
    }
    sLastDiscoverTriggerTs = now;
    sPreferDiscoverInjectUntil = now + 120.0;
    sDiscoverTabActive = YES;

    BOOL hostOk = LBEnsureNativeDiscoverHostPresented();
    id core = LBLegadoManagerCore();
    if (!core || ![core respondsToSelector:@selector(handleExploreRequestWithSourceUrl:exploreUrl:page:)]) {
        LBDiscoverAppendMarker(@"discoverTab explore skip: core/API missing");
        return;
    }
    // 先画分类标签栏（Reader0：标签在上）
    LBRefreshDiscoverKindBar();
    // 取当前源第一分类 URL，再拉书（不再扫全部源摊平）
    NSString *src = nil;
    @try {
        if ([core respondsToSelector:@selector(selectedExploreSourceUrl)]) {
            src = [core valueForKey:@"selectedExploreSourceUrl"];
        }
    } @catch (__unused NSException *e) {}
    NSString *kindUrl = nil;
    if ([core respondsToSelector:@selector(exploreKindsJSONForSourceUrl:)]) {
        NSString *kj = ((NSString *(*)(id, SEL, NSString *))objc_msgSend)(
            core, @selector(exploreKindsJSONForSourceUrl:), src);
        NSData *data = [kj dataUsingEncoding:NSUTF8StringEncoding];
        id arr = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        if ([arr isKindOfClass:[NSArray class]] && [arr count] > 0) {
            id u = arr[0][@"url"];
            if ([u isKindOfClass:[NSString class]]) kindUrl = u;
        }
    }
    LBDiscoverAppendMarker([NSString stringWithFormat:
                            @"discoverTab explore trigger hostOk=%d src=%@ kind=%@",
                            hostOk ? 1 : 0, src ?: @"", kindUrl ?: @"(default)"]);
    ((void (*)(id, SEL, NSString *, NSString *, NSInteger))objc_msgSend)(
        core,
        @selector(handleExploreRequestWithSourceUrl:exploreUrl:page:),
        src,
        kindUrl,
        1
    );
    // 书列表灌入后再排一次布局
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        LBRefreshDiscoverKindBar();
    });
}

static void LBSelectDiscoverSegmentIfPresent(void) {
    UIWindow *win = LBLegadoKeyWindow();
    UIViewController *root = win.rootViewController;
    if (!root) return;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count > 0) {
        UIViewController *vc = stack.lastObject;
        [stack removeLastObject];
        NSMutableArray *views = [NSMutableArray array];
        if (vc.isViewLoaded && vc.view) [views addObject:vc.view];
        if (vc.navigationItem.titleView) [views addObject:vc.navigationItem.titleView];
        while (views.count > 0) {
            UIView *cur = views.lastObject;
            [views removeLastObject];
            if ([cur isKindOfClass:[UISegmentedControl class]]) {
                UISegmentedControl *sc = (UISegmentedControl *)cur;
                BOOL hasShelf = NO, hasDiscover = NO;
                NSInteger discoverIdx = -1;
                for (NSUInteger i = 0; i < sc.numberOfSegments; i++) {
                    NSString *t = [sc titleForSegmentAtIndex:i] ?: @"";
                    if ([t containsString:@"书架"]) hasShelf = YES;
                    if ([t containsString:@"发现"]) {
                        hasDiscover = YES;
                        discoverIdx = (NSInteger)i;
                    }
                }
                if (hasShelf && hasDiscover && discoverIdx >= 0 &&
                    sc.selectedSegmentIndex != discoverIdx) {
                    sc.selectedSegmentIndex = discoverIdx;
                    [sc sendActionsForControlEvents:UIControlEventValueChanged];
                }
            }
            for (UIView *sub in cur.subviews) [views addObject:sub];
        }
        for (UIViewController *c in vc.childViewControllers) [stack addObject:c];
        if (vc.presentedViewController) [stack addObject:vc.presentedViewController];
        if ([vc isKindOfClass:[UINavigationController class]]) {
            for (UIViewController *c in [(UINavigationController *)vc viewControllers]) {
                [stack addObject:c];
            }
        }
        if ([vc isKindOfClass:[UITabBarController class]]) {
            UIViewController *sel = [(UITabBarController *)vc selectedViewController];
            if (sel) [stack addObject:sel];
        }
    }
}

static void LBDiscover_setSquare(id self, SEL _cmd, BOOL square) {
    // 恢复原生广场：点「发现」必须走 setSquare，不能改推搜索页
    if (sOrig_setSquare) {
        sOrig_setSquare(self, _cmd, square);
    }
    LBSetDiscoverTabActive(square);
    if (square) {
        LBDiscoverAppendMarker(@"discoverTab setSquare=1 native World + Legado inject");
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!LBIsDiscoverTabActive()) return;
            UINavigationController *nav = LBDiscoverActiveNav();
            if (nav) LBPopBookSearchIfNeeded(nav);
            LBEnsureNativeDiscoverHostPresented();
            LBTriggerLegadoExploreForDiscoverTab();
        });
        LBScheduleDiscoverHostRescue();
    } else {
        LBDiscoverAppendMarker(@"discoverTab setSquare=0");
    }
}

static BOOL LBSegmentControlShowsDiscover(id shelfSelf) {
    @try {
        UIView *tv = nil;
        if ([shelfSelf isKindOfClass:[UIViewController class]]) {
            UIViewController *vc = (UIViewController *)shelfSelf;
            if (vc.navigationItem.titleView) tv = vc.navigationItem.titleView;
            else if (vc.isViewLoaded) tv = vc.view;
        }
        if (!tv) return NO;
        NSMutableArray *views = [NSMutableArray arrayWithObject:tv];
        while (views.count > 0) {
            UIView *cur = views.lastObject;
            [views removeLastObject];
            if ([cur isKindOfClass:[UISegmentedControl class]]) {
                UISegmentedControl *sc = (UISegmentedControl *)cur;
                NSInteger idx = sc.selectedSegmentIndex;
                if (idx >= 0 && idx < (NSInteger)sc.numberOfSegments) {
                    NSString *t = [sc titleForSegmentAtIndex:(NSUInteger)idx] ?: @"";
                    if ([t containsString:@"发现"]) return YES;
                }
            }
            for (UIView *sub in cur.subviews) [views addObject:sub];
        }
    } @catch (__unused NSException *e) {}
    return NO;
}

static void LBDiscover_onSegmentChanged(id self, SEL _cmd) {
    // 先走原生（内部会 setSquare 推广场），再灌 Legado；禁止改推 BookSearch
    if (sOrig_onSegmentChanged) {
        sOrig_onSegmentChanged(self, _cmd);
    }
    if (LBSegmentControlShowsDiscover(self)) {
        LBSetDiscoverTabActive(YES);
        LBDiscoverAppendMarker(@"discoverTab onSegmentChanged discover → native+inject");
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!LBIsDiscoverTabActive()) return;
            UINavigationController *nav = LBDiscoverActiveNav();
            if (nav) LBPopBookSearchIfNeeded(nav);
            LBEnsureNativeDiscoverHostPresented();
            LBTriggerLegadoExploreForDiscoverTab();
        });
        LBScheduleDiscoverHostRescue();
    } else {
        sDiscoverTabActive = NO;
    }
}

static void LBDiscover_onSegmentChange(id self, SEL _cmd, id sender) {
    if (sOrig_onSegmentChange) {
        sOrig_onSegmentChange(self, _cmd, sender);
    }
    LBDiscover_onSegmentChanged(self, @selector(onSegmentChanged));
}

static void LBDiscover_worldAppear(id self, SEL _cmd, BOOL animated) {
    if (sOrig_worldAppear) {
        ((void (*)(id, SEL, BOOL))sOrig_worldAppear)(self, _cmd, animated);
    } else {
        struct objc_super sup = { self, class_getSuperclass(object_getClass(self)) };
        ((void (*)(struct objc_super *, SEL, BOOL))objc_msgSendSuper)(&sup, _cmd, animated);
    }
    NSString *cn = NSStringFromClass([self class]);
    if ([cn containsString:@"BookWorld"] || [cn containsString:@"BookStore"] ||
        [cn containsString:@"Shudan"]) {
        sPinnedDiscoverHost = (UIViewController *)self;
        LBDiscoverAppendMarker([NSString stringWithFormat:@"discoverHost worldAppear %@", cn]);
    }
    if (!LBIsDiscoverTabActive()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UINavigationController *nav = LBDiscoverActiveNav();
        if (nav) LBPopBookSearchIfNeeded(nav);
        LBInstallSearchUIAppearFlush();
        if ([cn containsString:@"BookWorld"] || [cn containsString:@"BookStore"] ||
            [cn containsString:@"Shudan"]) {
            sPinnedDiscoverHost = (UIViewController *)self;
            LBTriggerLegadoExploreForDiscoverTab();
        }
    });
}

static void LBHookSetSquareOnClass(Class cls) {
    if (!cls) return;
    SEL sel = @selector(setSquare:);
    Class owner = LBClassOwningInstanceMethod(cls, sel) ?: cls;
    Method m = class_getInstanceMethod(owner, sel);
    if (!m) return;
    if (!sOrig_setSquare) {
        sOrig_setSquare = (void (*)(id, SEL, BOOL))method_getImplementation(m);
    }
    method_setImplementation(m, (IMP)LBDiscover_setSquare);
}

static void LBHookSegmentOnClass(Class cls) {
    if (!cls) return;
    SEL sel1 = @selector(onSegmentChanged);
    Class owner1 = LBClassOwningInstanceMethod(cls, sel1);
    if (owner1) {
        Method m = class_getInstanceMethod(owner1, sel1);
        if (m && !sOrig_onSegmentChanged) {
            sOrig_onSegmentChanged = (void (*)(id, SEL))method_getImplementation(m);
            method_setImplementation(m, (IMP)LBDiscover_onSegmentChanged);
        }
    }
    SEL sel2 = @selector(onSegmentChanged:);
    Class owner2 = LBClassOwningInstanceMethod(cls, sel2);
    if (owner2) {
        Method m = class_getInstanceMethod(owner2, sel2);
        if (m) {
            IMP orig = method_getImplementation(m);
            IMP hook = imp_implementationWithBlock(^void(id selfObj, id sender) {
                ((void (*)(id, SEL, id))orig)(selfObj, sel2, sender);
                LBDiscover_onSegmentChanged(selfObj, @selector(onSegmentChanged));
            });
            method_setImplementation(m, hook);
        }
    }
    SEL sel3 = @selector(onSegmentChange:);
    Class owner3 = LBClassOwningInstanceMethod(cls, sel3);
    if (owner3) {
        Method m = class_getInstanceMethod(owner3, sel3);
        if (m && !sOrig_onSegmentChange) {
            sOrig_onSegmentChange = (void (*)(id, SEL, id))method_getImplementation(m);
            method_setImplementation(m, (IMP)LBDiscover_onSegmentChange);
        }
    }
}

static void LBHookWorldAppear(Class cls) {
    if (!cls) return;
    SEL sel = @selector(viewDidAppear:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    if (!sOrig_worldAppear) {
        sOrig_worldAppear = method_getImplementation(m);
    }
    method_setImplementation(m, (IMP)LBDiscover_worldAppear);
}

static void LBDiscover_setSelectedSegmentIndex(id self, SEL _cmd, NSInteger idx) {
    if (sOrig_setSelectedSegmentIndex) {
        sOrig_setSelectedSegmentIndex(self, _cmd, idx);
    }
    if (![self isKindOfClass:[UISegmentedControl class]]) return;
    UISegmentedControl *sc = (UISegmentedControl *)self;
    if (idx < 0 || idx >= sc.numberOfSegments) return;
    NSString *title = [sc titleForSegmentAtIndex:(NSUInteger)idx] ?: @"";
    BOOL hasShelf = NO, hasDiscover = NO;
    for (NSUInteger i = 0; i < sc.numberOfSegments; i++) {
        NSString *t = [sc titleForSegmentAtIndex:i] ?: @"";
        if ([t containsString:@"书架"]) hasShelf = YES;
        if ([t containsString:@"发现"]) hasDiscover = YES;
    }
    if (!(hasShelf && hasDiscover)) return;
    BOOL discover = [title containsString:@"发现"];
    // 分段切回书架时不要清 sticky：deeplink/发现触发窗口内仍允许注入
    if (discover) {
        LBSetDiscoverTabActive(YES);
        LBDiscoverAppendMarker([NSString stringWithFormat:
                                @"discoverTab setSelectedSegmentIndex idx=%ld title=%@ discover=1 sticky=%d",
                                (long)idx, title, LBIsDiscoverTabActive() ? 1 : 0]);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!LBIsDiscoverTabActive()) return;
            LBEnsureNativeDiscoverHostPresented();
            LBTriggerLegadoExploreForDiscoverTab();
            LBBringPinnedDiscoverHostToFront();
        });
        LBScheduleDiscoverHostRescue();
    } else {
        sDiscoverTabActive = NO;
        LBDiscoverAppendMarker([NSString stringWithFormat:
                                @"discoverTab setSelectedSegmentIndex idx=%ld title=%@ discover=0 sticky=%d",
                                (long)idx, title, LBIsDiscoverTabActive() ? 1 : 0]);
    }
}

static void LBHookSegmentedControlSelectedIndex(void) {
    Class cls = [UISegmentedControl class];
    SEL sel = @selector(setSelectedSegmentIndex:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m || sOrig_setSelectedSegmentIndex) return;
    sOrig_setSelectedSegmentIndex =
        (void (*)(id, SEL, NSInteger))method_getImplementation(m);
    method_setImplementation(m, (IMP)LBDiscover_setSelectedSegmentIndex);
}

void LBInstallDiscoverTabHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        LBHookSegmentedControlSelectedIndex();
        for (NSString *cn in @[@"BookShelfController", @"BookShelfVCBase1", @"BookShelfVCBase2"]) {
            Class cls = NSClassFromString(cn);
            LBHookSetSquareOnClass(cls);
            LBHookSegmentOnClass(cls);
        }
        for (NSString *cn in @[@"BookWorldHomeCon", @"BookStoreBaseCon", @"ShudanHomeCon",
                               @"BookListCon", @"BookListController"]) {
            LBHookWorldAppear(NSClassFromString(cn));
        }
        [@"discoverTab hooks installed (native host)"
            writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_discover_hook.txt"]
            atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        NSLog(@"[LegadoBridge] discover tab hooks installed (native host)");
    });
}
