#import "LBInternal.h"
#import "LegadoBridge.h"

/// 顶栏「书架|发现」切到发现时：触发 Legado explore，结果优先灌发现宿主，避免只走搜索页。

static BOOL sDiscoverTabActive = NO;
static NSTimeInterval sLastDiscoverTriggerTs = 0;
static void (*sOrig_setSquare)(id, SEL, BOOL) = NULL;
static void (*sOrig_onSegmentChanged)(id, SEL) = NULL;
static void (*sOrig_onSegmentChange)(id, SEL, id) = NULL;
static IMP sOrig_worldAppear = NULL;

BOOL LBIsDiscoverTabActive(void) {
    return sDiscoverTabActive;
}

void LBSetDiscoverTabActive(BOOL active) {
    sDiscoverTabActive = active;
    NSString *line = [NSString stringWithFormat:@"discoverTab active=%d ts=%.0f",
                      active ? 1 : 0, [[NSDate date] timeIntervalSince1970]];
    [line writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_discover_hook.txt"]
            atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

static BOOL LBClassNameLooksDiscoverHost(NSString *cn) {
    if (cn.length == 0) return NO;
    if ([cn containsString:@"BookWorld"]) return YES;
    if ([cn containsString:@"BookStore"]) return YES;
    if ([cn containsString:@"Shudan"]) return YES;
    if ([cn containsString:@"BookListCon"]) return YES;
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

static void LBTriggerLegadoExploreForDiscoverTab(void) {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (sLastDiscoverTriggerTs > 0 && (now - sLastDiscoverTriggerTs) < 1.2) {
        return;
    }
    sLastDiscoverTriggerTs = now;
    id core = LBLegadoManagerCore();
    if (!core || ![core respondsToSelector:@selector(handleExploreRequestWithSourceUrl:exploreUrl:page:)]) {
        [@"discoverTab explore skip: core/API missing"
            writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_discover_hook.txt"]
            atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return;
    }
    [@"discoverTab explore trigger all-capable"
        writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_discover_hook.txt"]
        atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    ((void (*)(id, SEL, NSString *, NSString *, NSInteger))objc_msgSend)(
        core,
        @selector(handleExploreRequestWithSourceUrl:exploreUrl:page:),
        nil,
        nil,
        1
    );
}

static void LBDiscover_setSquare(id self, SEL _cmd, BOOL square) {
    if (sOrig_setSquare) {
        sOrig_setSquare(self, _cmd, square);
    }
    LBSetDiscoverTabActive(square);
    if (square) {
        // 等原生切完子页再拉书
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
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
    NSInteger idx = -1;
    NSString *title = nil;
    id seg = nil;
    @try { seg = [self valueForKey:@"segment"]; } @catch (__unused NSException *e) {}
    if (!seg) {
        @try { seg = [self valueForKey:@"segmentedControl"]; } @catch (__unused NSException *e) {}
    }
    if (!seg) {
        @try { seg = [self valueForKey:@"titleSegment"]; } @catch (__unused NSException *e) {}
    }
    if ([seg isKindOfClass:[UISegmentedControl class]]) {
        UISegmentedControl *sc = (UISegmentedControl *)seg;
        idx = sc.selectedSegmentIndex;
        if (idx >= 0 && idx < sc.numberOfSegments) {
            title = [sc titleForSegmentAtIndex:(NSUInteger)idx];
        }
    } else if (seg) {
        @try {
            if ([seg respondsToSelector:@selector(selectedSegmentIndex)]) {
                idx = ((NSInteger (*)(id, SEL))objc_msgSend)(seg, @selector(selectedSegmentIndex));
            }
        } @catch (__unused NSException *e) {}
        @try {
            if (idx >= 0 && [seg respondsToSelector:@selector(titleForSegmentAtIndex:)]) {
                title = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(
                    seg, @selector(titleForSegmentAtIndex:), (NSUInteger)idx);
            }
        } @catch (__unused NSException *e) {}
    }
    if (idx < 0) {
        @try {
            id v = [self valueForKey:@"selectedSegmentIndex"];
            if ([v respondsToSelector:@selector(integerValue)]) idx = [v integerValue];
        } @catch (__unused NSException *e) {}
    }
    BOOL discover = NO;
    if ([title isKindOfClass:[NSString class]] &&
        ([title containsString:@"发现"] || [title.lowercaseString containsString:@"discover"])) {
        discover = YES;
    }
    if (!discover && idx == 1) {
        discover = YES; // 书架|发现 常规布局
    }
    @try {
        id sq = [self valueForKey:@"square"];
        if ([sq respondsToSelector:@selector(boolValue)] && [sq boolValue]) {
            discover = YES;
        }
    } @catch (__unused NSException *e) {}
    // 扫导航栏上可见的 UISegmentedControl（KVC 取不到 segment 时）
    if (!discover && idx < 0) {
        @try {
            UIView *v = [self isKindOfClass:[UIViewController class]] ? [(UIViewController *)self view] : nil;
            UINavigationItem *item = [self respondsToSelector:@selector(navigationItem)]
                ? [(UIViewController *)self navigationItem] : nil;
            NSMutableArray *cands = [NSMutableArray array];
            if (item.titleView) [cands addObject:item.titleView];
            if (v) [cands addObject:v];
            for (UIView *root in cands) {
                NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
                while (stack.count > 0) {
                    UIView *cur = stack.lastObject;
                    [stack removeLastObject];
                    if ([cur isKindOfClass:[UISegmentedControl class]]) {
                        UISegmentedControl *sc = (UISegmentedControl *)cur;
                        NSInteger si = sc.selectedSegmentIndex;
                        if (si >= 0 && si < sc.numberOfSegments) {
                            NSString *t = [sc titleForSegmentAtIndex:(NSUInteger)si];
                            if ([t containsString:@"发现"]) {
                                discover = YES;
                                idx = si;
                                title = t;
                                break;
                            }
                            if (si == 1 && sc.numberOfSegments == 2) {
                                // 双段且选中右侧：大概率是发现
                                NSString *t0 = [sc titleForSegmentAtIndex:0];
                                NSString *t1 = [sc titleForSegmentAtIndex:1];
                                if ([t0 containsString:@"书架"] && [t1 containsString:@"发现"]) {
                                    discover = YES;
                                    idx = si;
                                    title = t1;
                                    break;
                                }
                            }
                        }
                    }
                    for (UIView *sub in cur.subviews) [stack addObject:sub];
                }
                if (discover) break;
            }
        } @catch (__unused NSException *e) {}
    }
    LBSetDiscoverTabActive(discover);
    if (discover) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!LBIsDiscoverTabActive()) return;
            LBTriggerLegadoExploreForDiscoverTab();
        });
    }
    NSString *line = [NSString stringWithFormat:
                      @"discoverTab onSegmentChanged idx=%ld title=%@ discover=%d",
                      (long)idx, title ?: @"-", discover ? 1 : 0];
    [line writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_discover_hook.txt"]
            atomically:YES encoding:NSUTF8StringEncoding error:NULL];
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
    if (!LBIsDiscoverTabActive()) return;
    // 宿主已出现：若已有 pending 搜索结果，再灌一次
    dispatch_async(dispatch_get_main_queue(), ^{
        LBInstallSearchUIAppearFlush();
        // 通过空数组+关键词不会灌；触发一次「再应用」靠 Apply 内部 pending。
        // 这里直接再拉一次 explore，避免首次时宿主尚未入树。
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
        if (m && !sOrig_onSegmentChanged) {
            // 与无参版共用逻辑包装
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

void LBInstallDiscoverTabHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (NSString *cn in @[@"BookShelfController", @"BookShelfVCBase1", @"BookShelfVCBase2"]) {
            Class cls = NSClassFromString(cn);
            LBHookSetSquareOnClass(cls);
            LBHookSegmentOnClass(cls);
        }
        for (NSString *cn in @[@"BookWorldHomeCon", @"BookStoreBaseCon", @"ShudanHomeCon", @"BookListCon"]) {
            LBHookWorldAppear(NSClassFromString(cn));
        }
        [@"discoverTab hooks installed"
            writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_discover_hook.txt"]
            atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        NSLog(@"[LegadoBridge] discover tab hooks installed");
    });
}
