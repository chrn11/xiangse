#import "LBInternal.h"
#import "LegadoBridge.h"

/// 顶栏「发现」：切 Tab → 推出原生 BookList/BookWorld 宿主 → Legado explore 灌入 arrBaseData。
/// 发现态禁止抢 push BookSearch（避免变成「搜索 explore」而不是发现页）。

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
    // 发现注入：优先 pin（现为 BookSearch 发现壳）；清掉会崩的 BookList pin
    if (sPinnedDiscoverHost) {
        NSString *pcn = NSStringFromClass([sPinnedDiscoverHost class]);
        if ([pcn containsString:@"BookList"]) {
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
    // 发现态也接受已呈现的 BookSearch（标题可能是「发现」）
    NSMutableArray *hosts = [NSMutableArray array];
    for (UIViewController *vc in out) {
        NSString *cn = NSStringFromClass([vc class]);
        if ([cn containsString:@"BookSearch"]) [hosts addObject:vc];
        else if ([cn containsString:@"BookList"]) [hosts addObject:vc];
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
        BOOL blankCover = [cn containsString:@"BookWorld"]
            || [cn containsString:@"BookStore"]
            || [cn containsString:@"Shudan"];
        // 不再 pop BookList（避免误伤）；只扔 World/Store
        if (blankCover) {
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
    if (!pin) return;
    UINavigationController *nav = pin.navigationController ?: LBDiscoverActiveNav();
    if (!nav) return;
    LBPopBlankDiscoverCovers(nav, pin);
    if ([nav.viewControllers containsObject:pin]) {
        if (nav.topViewController != pin) {
            [nav popToViewController:pin animated:NO];
            LBDiscoverAppendMarker(@"discoverHost bringFront popTo pin");
        }
        return;
    }
    @try {
        [nav pushViewController:pin animated:NO];
        LBDiscoverAppendMarker(@"discoverHost bringFront re-push pin");
    } @catch (__unused NSException *e) {}
}

static NSTimeInterval sLastRescueScheduleTs = 0;

static void LBScheduleDiscoverHostRescue(void) {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (sLastRescueScheduleTs > 0 && (now - sLastRescueScheduleTs) < 2.5) {
        return;
    }
    sLastRescueScheduleTs = now;
    // 只轻量补两次，避免与原生 World 抢栈死循环
    for (NSNumber *sec in @[ @0.35, @1.2 ]) {
        double d = sec.doubleValue;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!LBIsDiscoverTabActive()) return;
            LBEnsureNativeDiscoverHostPresented();
            LBBringPinnedDiscoverHostToFront();
        });
    }
}

static void LBSelectDiscoverSegmentOnly(void) {
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
                BOOL hasShelf = NO;
                NSInteger discoverIdx = -1;
                for (NSUInteger i = 0; i < sc.numberOfSegments; i++) {
                    NSString *t = [sc titleForSegmentAtIndex:i] ?: @"";
                    if ([t containsString:@"书架"]) hasShelf = YES;
                    if ([t containsString:@"发现"]) discoverIdx = (NSInteger)i;
                }
                if (hasShelf && discoverIdx >= 0 && sc.selectedSegmentIndex != discoverIdx) {
                    sc.selectedSegmentIndex = discoverIdx;
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
    }
}

/// 确保发现列表宿主在导航栈。
/// 注意：裸 push BookListCon 会在 viewDidLoad/布局期 SIGABRT（真机已证）；
/// 发现态改用原生 BookSearchController 作列表壳，标题显示「发现」。
BOOL LBEnsureNativeDiscoverHostPresented(void) {
    if (sPinnedDiscoverHost) {
        UIViewController *pin = sPinnedDiscoverHost;
        NSString *pcn = NSStringFromClass([pin class]);
        // 旧 pin 若是会崩的 BookListCon，丢掉
        if ([pcn containsString:@"BookList"]) {
            sPinnedDiscoverHost = nil;
        } else if (pin.navigationController || (pin.isViewLoaded && pin.view.window)) {
            LBBringPinnedDiscoverHostToFront();
            return YES;
        } else {
            sPinnedDiscoverHost = nil;
        }
    }
    UINavigationController *nav = LBDiscoverActiveNav();
    if (!nav) {
        LBDiscoverAppendMarker(@"discoverHost miss: no nav");
        return NO;
    }
    // 发现宿主就是 BookSearch：不要 LBPopBookSearchIfNeeded

    // 栈内已有搜索列表则复用并改标题
    for (UIViewController *vc in nav.viewControllers.reverseObjectEnumerator) {
        NSString *cn = NSStringFromClass([vc class]);
        if ([cn containsString:@"BookSearch"]) {
            [nav popToViewController:vc animated:NO];
            @try { vc.title = @"发现"; } @catch (__unused NSException *e) {}
            @try { [vc setValue:@"explore" forKey:@"searchTextOutSide"]; } @catch (__unused NSException *e) {}
            @try { [vc setValue:@"explore" forKey:@"searchText"]; } @catch (__unused NSException *e) {}
            sPinnedDiscoverHost = vc;
            LBInstallSearchUIAppearFlush();
            LBDiscoverAppendMarker(@"discoverHost reuse stacked BookSearch");
            return YES;
        }
    }

    Class cls = NSClassFromString(@"BookSearchController");
    if (!cls) cls = NSClassFromString(@"BookSearchVCBase1");
    if (!cls) {
        LBDiscoverAppendMarker(@"discoverHost miss: BookSearch class absent");
        return NO;
    }
    LBInstallSearchUIAppearFlush();
    UIViewController *host = nil;
    @try { host = [[cls alloc] init]; } @catch (__unused NSException *e) { host = nil; }
    if (!host) {
        @try {
            host = [[cls alloc] initWithNibName:nil bundle:nil];
        } @catch (__unused NSException *e) { host = nil; }
    }
    if (!host) {
        LBDiscoverAppendMarker(@"discoverHost miss: BookSearch alloc failed");
        return NO;
    }
    @try { host.title = @"发现"; } @catch (__unused NSException *e) {}
    @try { [host setValue:@"发现" forKey:@"title"]; } @catch (__unused NSException *e) {}
    @try { [host setValue:@"explore" forKey:@"searchTextOutSide"]; } @catch (__unused NSException *e) {}
    @try { [host setValue:@"explore" forKey:@"searchText"]; } @catch (__unused NSException *e) {}
    @try {
        [nav pushViewController:host animated:YES];
    } @catch (NSException *ex) {
        LBDiscoverAppendMarker([NSString stringWithFormat:@"discoverHost push EX %@", ex.reason ?: @""]);
        return NO;
    }
    sPinnedDiscoverHost = host;
    LBDiscoverAppendMarker([NSString stringWithFormat:@"discoverHost push %@", NSStringFromClass(cls)]);
    return YES;
}

static void LBTriggerLegadoExploreForDiscoverTab(void) {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (sLastDiscoverTriggerTs > 0 && (now - sLastDiscoverTriggerTs) < 1.2) {
        return;
    }
    sLastDiscoverTriggerTs = now;
    sPreferDiscoverInjectUntil = now + 25.0;
    sDiscoverTabActive = YES;

    BOOL hostOk = LBEnsureNativeDiscoverHostPresented();
    id core = LBLegadoManagerCore();
    if (!core || ![core respondsToSelector:@selector(handleExploreRequestWithSourceUrl:exploreUrl:page:)]) {
        LBDiscoverAppendMarker(@"discoverTab explore skip: core/API missing");
        return;
    }
    LBDiscoverAppendMarker([NSString stringWithFormat:@"discoverTab explore trigger hostOk=%d", hostOk ? 1 : 0]);
    ((void (*)(id, SEL, NSString *, NSString *, NSInteger))objc_msgSend)(
        core,
        @selector(handleExploreRequestWithSourceUrl:exploreUrl:page:),
        nil,
        nil,
        1
    );
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
    if (!square) {
        if (sOrig_setSquare) {
            sOrig_setSquare(self, _cmd, NO);
        }
        sDiscoverTabActive = NO;
        LBDiscoverAppendMarker(@"discoverTab setSquare=0");
        return;
    }
    // square=YES：禁止走原生（会反复推空白 BookWorld 并与发现壳抢栈 SIGABRT）
    LBSetDiscoverTabActive(YES);
    @try { [self setValue:@YES forKey:@"square"]; } @catch (__unused NSException *e) {}
    LBSelectDiscoverSegmentOnly();
    LBDiscoverAppendMarker(@"discoverTab setSquare=1 skip native World → Legado host");
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!LBIsDiscoverTabActive()) return;
        LBEnsureNativeDiscoverHostPresented();
        LBTriggerLegadoExploreForDiscoverTab();
        LBBringPinnedDiscoverHostToFront();
    });
    LBScheduleDiscoverHostRescue();
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
    if (LBSegmentControlShowsDiscover(self)) {
        LBSetDiscoverTabActive(YES);
        @try { [self setValue:@YES forKey:@"square"]; } @catch (__unused NSException *e) {}
        LBDiscoverAppendMarker(@"discoverTab onSegmentChanged discover → Legado host (skip native)");
        // 不调原生 onSegmentChanged，避免内部 setSquare 推 World
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!LBIsDiscoverTabActive()) return;
            LBEnsureNativeDiscoverHostPresented();
            LBTriggerLegadoExploreForDiscoverTab();
            LBBringPinnedDiscoverHostToFront();
        });
        LBScheduleDiscoverHostRescue();
        return;
    }

    if (sOrig_onSegmentChanged) {
        sOrig_onSegmentChanged(self, _cmd);
    }
    sDiscoverTabActive = NO;
}

static void LBDiscover_onSegmentChange(id self, SEL _cmd, id sender) {
    if (LBSegmentControlShowsDiscover(self)) {
        LBDiscover_onSegmentChanged(self, @selector(onSegmentChanged));
        return;
    }
    if (sOrig_onSegmentChange) {
        sOrig_onSegmentChange(self, _cmd, sender);
    }
    sDiscoverTabActive = NO;
}

static void LBDiscover_worldAppear(id self, SEL _cmd, BOOL animated) {
    if (sOrig_worldAppear) {
        ((void (*)(id, SEL, BOOL))sOrig_worldAppear)(self, _cmd, animated);
    } else {
        struct objc_super sup = { self, class_getSuperclass(object_getClass(self)) };
        ((void (*)(struct objc_super *, SEL, BOOL))objc_msgSendSuper)(&sup, _cmd, animated);
    }
    NSString *cn = NSStringFromClass([self class]);
    // BookListCon 裸 push 会崩；不再 pin。BookSearch 发现壳可 pin。
    if ([cn containsString:@"BookSearch"]) {
        sPinnedDiscoverHost = (UIViewController *)self;
    }
    if (!LBIsDiscoverTabActive()) return;
    // 发现态下 World 仍 appear：只弹掉并置顶，不再二次 explore（避免抢栈）
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([cn containsString:@"BookSearch"]) {
            sPinnedDiscoverHost = (UIViewController *)self;
            return;
        }
        LBEnsureNativeDiscoverHostPresented();
        LBBringPinnedDiscoverHostToFront();
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
                if (LBSegmentControlShowsDiscover(selfObj)) {
                    LBDiscover_onSegmentChanged(selfObj, @selector(onSegmentChanged));
                    return;
                }
                ((void (*)(id, SEL, id))orig)(selfObj, sel2, sender);
                sDiscoverTabActive = NO;
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
