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

BOOL LBIsDiscoverTabActive(void) {
    if (sDiscoverTabActive) return YES;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    return (sPreferDiscoverInjectUntil > 0 && now < sPreferDiscoverInjectUntil);
}

void LBSetDiscoverTabActive(BOOL active) {
    sDiscoverTabActive = active;
    if (active) {
        sPreferDiscoverInjectUntil = [[NSDate date] timeIntervalSince1970] + 25.0;
    }
    NSString *line = [NSString stringWithFormat:@"discoverTab active=%d stickyUntil=%.0f",
                      active ? 1 : 0, sPreferDiscoverInjectUntil];
    [line writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_discover_hook.txt"]
            atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

static BOOL LBClassNameLooksDiscoverHost(NSString *cn) {
    if (cn.length == 0) return NO;
    if ([cn containsString:@"BookWorld"]) return YES;
    if ([cn containsString:@"BookStore"]) return YES;
    if ([cn containsString:@"Shudan"]) return YES;
    if ([cn containsString:@"BookListCon"]) return YES;
    if ([cn containsString:@"BookList"]) return YES;
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
    NSMutableArray *out = [NSMutableArray array];
    if (sPinnedDiscoverHost) {
        [out addObject:sPinnedDiscoverHost];
    }
    UIWindow *win = LBLegadoKeyWindow();
    if (win.rootViewController) {
        LBCollectDiscoverHostVCs(win.rootViewController, out);
    }
    return out;
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

/// 确保原生发现列表宿主在导航栈（BookListCon / BookWorldHomeCon）
BOOL LBEnsureNativeDiscoverHostPresented(void) {
    NSArray *existing = LBFindDiscoverHostVCs();
    for (UIViewController *vc in existing) {
        if (vc.isViewLoaded && vc.view.window) {
            sPinnedDiscoverHost = vc;
            return YES;
        }
    }
    UINavigationController *nav = LBDiscoverActiveNav();
    if (!nav) {
        [@"discoverHost miss: no nav"
            writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_discover_hook.txt"]
            atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return NO;
    }
    LBPopBookSearchIfNeeded(nav);

    // 栈内已有宿主则 pop 到它
    for (UIViewController *vc in nav.viewControllers.reverseObjectEnumerator) {
        if (LBClassNameLooksDiscoverHost(NSStringFromClass([vc class]))) {
            [nav popToViewController:vc animated:NO];
            sPinnedDiscoverHost = vc;
            [@"discoverHost reuse stacked host"
                writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_discover_hook.txt"]
                atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            return YES;
        }
    }

    Class cls = NSClassFromString(@"BookListCon");
    if (!cls) cls = NSClassFromString(@"BookWorldHomeCon");
    if (!cls) cls = NSClassFromString(@"BookStoreBaseCon");
    if (!cls) cls = NSClassFromString(@"ShudanHomeCon");
    if (!cls) {
        [@"discoverHost miss: no BookList/World class"
            writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_discover_hook.txt"]
            atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return NO;
    }
    UIViewController *host = nil;
    @try { host = [[cls alloc] init]; } @catch (__unused NSException *e) { host = nil; }
    if (!host) {
        [@"discoverHost miss: alloc failed"
            writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_discover_hook.txt"]
            atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return NO;
    }
    @try { host.title = @"发现"; } @catch (__unused NSException *e) {}
    [nav pushViewController:host animated:YES];
    sPinnedDiscoverHost = host;
    NSString *line = [NSString stringWithFormat:@"discoverHost push %@", NSStringFromClass(cls)];
    [line writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_discover_hook.txt"]
            atomically:YES encoding:NSUTF8StringEncoding error:NULL];
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
        [@"discoverTab explore skip: core/API missing"
            writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_discover_hook.txt"]
            atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return;
    }
    NSString *mark = [NSString stringWithFormat:@"discoverTab explore trigger hostOk=%d", hostOk ? 1 : 0];
    [mark writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_discover_hook.txt"]
            atomically:YES encoding:NSUTF8StringEncoding error:NULL];
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
    if (sOrig_setSquare) {
        sOrig_setSquare(self, _cmd, square);
    }
    LBSetDiscoverTabActive(square);
    if (square) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!LBIsDiscoverTabActive()) return;
            LBTriggerLegadoExploreForDiscoverTab();
        });
    }
}

static void LBDiscover_onSegmentChanged(id self, SEL _cmd) {
    if (sOrig_onSegmentChanged) {
        sOrig_onSegmentChanged(self, _cmd);
    }
    // 委托给分段标题扫描（与 setSelectedSegmentIndex 一致）
    LBSelectDiscoverSegmentIfPresent();
    @try {
        id sq = [self valueForKey:@"square"];
        if ([sq respondsToSelector:@selector(boolValue)] && [sq boolValue]) {
            LBSetDiscoverTabActive(YES);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (!LBIsDiscoverTabActive()) return;
                LBTriggerLegadoExploreForDiscoverTab();
            });
        }
    } @catch (__unused NSException *e) {}
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
    sPinnedDiscoverHost = (UIViewController *)self;
    if (!LBIsDiscoverTabActive()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        LBInstallSearchUIAppearFlush();
        LBTriggerLegadoExploreForDiscoverTab();
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
    LBSetDiscoverTabActive(discover);
    NSString *line = [NSString stringWithFormat:
                      @"discoverTab setSelectedSegmentIndex idx=%ld title=%@ discover=%d",
                      (long)idx, title, discover ? 1 : 0];
    [line writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_discover_hook.txt"]
            atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    if (discover) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!LBIsDiscoverTabActive()) return;
            LBTriggerLegadoExploreForDiscoverTab();
        });
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
