#import "LBInternal.h"
#import "LegadoBridge.h"

/// 发现页：香色原生 SGPageTitleView + BookListCon 子页；禁止 Bridge overlay 标签栏/表（tag LBKB/LBPV）。

static const NSInteger kLBKindBarTag = 0x4C424B42; // 'LBKB' — 仅用于清除历史 overlay
static const NSInteger kLBOverlayTVTag = 0x4C425056; // 'LBPV' — 仅用于清除历史 overlay
static NSInteger sSelectedKindIndex = 0;
static NSArray *sCachedKinds = nil;

static void (*sOrig_pageTitleSelected)(id, SEL, id, NSInteger) = NULL;
static void (*sOrig_onSwitchBtn)(id, SEL) = NULL;
static void (*sOrig_onSwitchBtnArg)(id, SEL, id) = NULL;

static id LBKindCore(void) {
    return LBLegadoCoreIfReady();
}

static NSArray *LBParseJSONArray(NSString *json) {
    if (json.length == 0) return @[];
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return @[];
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [obj isKindOfClass:[NSArray class]] ? obj : @[];
}

static UIViewController *LBPrimaryDiscoverHost(void) {
    NSArray *hosts = LBFindDiscoverHostVCs();
    for (UIViewController *vc in hosts) {
        NSString *cn = NSStringFromClass([vc class]);
        if ([cn containsString:@"BookWorld"] || [cn containsString:@"BookStore"] ||
            [cn containsString:@"Shudan"]) {
            return vc;
        }
    }
    return hosts.firstObject;
}

static void LBAppendNativeMarker(NSString *line) {
    if (line.length == 0) return;
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_discover_native.txt"];
    NSString *prev = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL] ?: @"";
    if (prev.length > 8000) prev = [prev substringFromIndex:prev.length - 5000];
    NSString *next = prev.length > 0 ? [prev stringByAppendingFormat:@"\n%@", line] : line;
    [next writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

/// 清除历史 Bridge overlay（标签栏 / 表）
void LBRemoveDiscoverOverlays(UIViewController *host) {
    if (!host.isViewLoaded || !host.view) return;
    NSMutableArray *remove = [NSMutableArray array];
    for (UIView *sub in host.view.subviews) {
        if (sub.tag == kLBKindBarTag || sub.tag == kLBOverlayTVTag) {
            [remove addObject:sub];
        }
    }
    for (UIView *v in remove) [v removeFromSuperview];
}

/// 当前选中的 BookListCon 子页（createCons 生成）；无子页则回退宿主
UIViewController *LBActiveDiscoverListVC(UIViewController *host) {
    if (!host) return nil;
    NSInteger idx = sSelectedKindIndex;
    @try {
        id titleView = [host valueForKey:@"pageTitleView"];
        if (titleView && [titleView respondsToSelector:@selector(selectedIndex)]) {
            idx = [[titleView valueForKey:@"selectedIndex"] integerValue];
        }
    } @catch (__unused NSException *e) {}
    @try {
        id scroll = [host valueForKey:@"pageContentScrollView"];
        if (scroll && [scroll respondsToSelector:@selector(currentIndex)]) {
            idx = [[scroll valueForKey:@"currentIndex"] integerValue];
        }
    } @catch (__unused NSException *e) {}
    NSArray *children = host.childViewControllers;
    if (idx >= 0 && idx < (NSInteger)children.count) {
        return children[(NSUInteger)idx];
    }
    @try {
        id list = [host valueForKey:@"listCon"];
        if ([list isKindOfClass:[UIViewController class]]) return (UIViewController *)list;
    } @catch (__unused NSException *e) {}
    return host;
}

static NSString *LBCurrentExploreSourceUrl(id core) {
    NSString *src = nil;
    @try {
        if ([core respondsToSelector:@selector(selectedExploreSourceUrl)]) {
            src = [core valueForKey:@"selectedExploreSourceUrl"];
        }
    } @catch (__unused NSException *e) {}
    if (src.length > 0) return src;
    NSArray *cap = LBParseJSONArray(
        ([core respondsToSelector:@selector(exploreCapableSourcesJSON)]
         ? [core valueForKey:@"exploreCapableSourcesJSON"] : @"[]"));
    if (cap.count > 0) {
        src = cap[0][@"url"];
        @try { [core setValue:src forKey:@"selectedExploreSourceUrl"]; } @catch (__unused NSException *e) {}
    }
    return src;
}

static void LBTriggerExploreKind(NSString *sourceUrl, NSString *kindUrl) {
    id core = LBKindCore();
    if (!core || ![core respondsToSelector:@selector(handleExploreRequestWithSourceUrl:exploreUrl:page:)]) {
        return;
    }
    ((void (*)(id, SEL, NSString *, NSString *, NSInteger))objc_msgSend)(
        core,
        @selector(handleExploreRequestWithSourceUrl:exploreUrl:page:),
        sourceUrl,
        kindUrl.length ? kindUrl : nil,
        1);
}

static void LBPresentExploreSourcePicker(UIViewController *host) {
    id core = LBKindCore();
    if (!core || ![core respondsToSelector:@selector(exploreCapableSourcesJSON)]) return;
    NSString *json = nil;
    @try { json = [core valueForKey:@"exploreCapableSourcesJSON"]; } @catch (__unused NSException *e) {}
    NSArray *rows = LBParseJSONArray(json ?: @"[]");
    if (rows.count == 0) {
        LBLegadoShowResult(@"无可发现的 Legado 书源");
        return;
    }
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"切换发现源"
                                                               message:nil
                                                        preferredStyle:UIAlertControllerStyleActionSheet];
    for (id row in rows) {
        if (![row isKindOfClass:[NSDictionary class]]) continue;
        NSString *name = row[@"name"] ?: row[@"url"] ?: @"源";
        NSString *url = row[@"url"] ?: @"";
        [ac addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
            @try { [core setValue:url forKey:@"selectedExploreSourceUrl"]; } @catch (__unused NSException *e) {}
            sSelectedKindIndex = 0;
            LBRefreshDiscoverKindBar();
            NSString *kindsJSON = @"[]";
            if ([core respondsToSelector:@selector(exploreKindsJSONForSourceUrl:)]) {
                kindsJSON = ((NSString *(*)(id, SEL, NSString *))objc_msgSend)(
                    core, @selector(exploreKindsJSONForSourceUrl:), url);
            }
            NSArray *kinds = LBParseJSONArray(kindsJSON);
            NSString *kindUrl = nil;
            if (kinds.count > 0 && [kinds[0][@"url"] isKindOfClass:[NSString class]]) {
                kindUrl = kinds[0][@"url"];
            }
            LBTriggerExploreKind(url, kindUrl);
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    UIViewController *presenter = host.navigationController ?: host;
    if (ac.popoverPresentationController) {
        ac.popoverPresentationController.sourceView = host.view;
        ac.popoverPresentationController.sourceRect = CGRectMake(host.view.bounds.size.width - 60, 40, 1, 1);
    }
    [presenter presentViewController:ac animated:YES completion:nil];
}

/// 用 Legado 分类重建原生 SGPageTitleView（arrHeaderBtnTitle + createCons）
static void LBFeedNativeDiscoverHeader(UIViewController *host, NSArray *kinds, NSString *srcName) {
    if (!host) return;
    LBRemoveDiscoverOverlays(host);

    NSMutableArray *titles = [NSMutableArray array];
    for (id item in kinds) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        [titles addObject:item[@"title"] ?: @"分类"];
    }
    if (titles.count == 0) [titles addObject:@"全部"];

    @try { [host setValue:titles forKey:@"arrHeaderBtnTitle"]; } @catch (__unused NSException *e) {}
    @try { [host setValue:srcName forKey:@"useSourceName"]; } @catch (__unused NSException *e) {}
    @try { [host setValue:srcName forKey:@"lastSourceName"]; } @catch (__unused NSException *e) {}

    if ([host respondsToSelector:@selector(createCons:titles:sourceName:)]) {
        @try {
            NSMutableArray *cons = [NSMutableArray array];
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(
                host, @selector(createCons:titles:sourceName:), cons, titles, srcName ?: @"");
            LBAppendNativeMarker([NSString stringWithFormat:@"createCons ok titles=%lu cons=%lu",
                                  (unsigned long)titles.count, (unsigned long)cons.count]);
        } @catch (NSException *ex) {
            LBAppendNativeMarker([NSString stringWithFormat:@"createCons EX %@", ex.reason ?: @""]);
        }
    }

    sCachedKinds = [kinds copy];
    if (sSelectedKindIndex >= (NSInteger)titles.count) sSelectedKindIndex = 0;

    if (srcName.length > 0) {
        @try { host.navigationItem.title = srcName; } @catch (__unused NSException *e) {}
        @try { host.title = srcName; } @catch (__unused NSException *e) {}
    }

    LBAppendNativeMarker([NSString stringWithFormat:@"nativeHeader host=%@ src=%@ kinds=%lu sel=%ld",
                          NSStringFromClass([host class]), srcName ?: @"",
                          (unsigned long)titles.count, (long)sSelectedKindIndex]);
}

/// 书列表灌入后刷新原生子页（resetContent / showContent）
void LBReloadDiscoverNativeList(UIViewController *host) {
    if (!host) return;
    UIViewController *listVC = LBActiveDiscoverListVC(host);
    if (!listVC) listVC = host;
    SEL reset = @selector(resetContent);
    if ([listVC respondsToSelector:reset]) {
        @try { ((void (*)(id, SEL))objc_msgSend)(listVC, reset); } @catch (__unused NSException *e) {}
        return;
    }
    SEL show = @selector(showContent:title:);
    if ([listVC respondsToSelector:show]) {
        NSString *title = @"";
        @try { title = [listVC valueForKey:@"useSourceName"] ?: @""; } @catch (__unused NSException *e) {}
        @try { ((void (*)(id, SEL, id, id))objc_msgSend)(listVC, show, nil, title); } @catch (__unused NSException *e) {}
    }
}

static void LBDiscover_pageTitleSelected(id self, SEL _cmd, id pageTitleView, NSInteger index) {
    if (sOrig_pageTitleSelected) {
        sOrig_pageTitleSelected(self, _cmd, pageTitleView, index);
    }
    if (!LBIsDiscoverTabActive()) return;
    sSelectedKindIndex = MAX(0, index);
    id core = LBKindCore();
    if (!core) return;
    NSString *src = LBCurrentExploreSourceUrl(core);
    NSArray *kinds = sCachedKinds ?: @[];
    if (index < 0 || index >= (NSInteger)kinds.count) return;
    NSDictionary *k = kinds[(NSUInteger)index];
    NSString *url = [k[@"url"] isKindOfClass:[NSString class]] ? k[@"url"] : @"";
    LBAppendNativeMarker([NSString stringWithFormat:@"nativeTab idx=%ld kind=%@", (long)index, url ?: @""]);
    LBTriggerExploreKind(src, url);
}

static void LBDiscover_onSwitchBtn(id self, SEL _cmd) {
    // 发现态：用 Legado 可发现源选择器，不先弹原生 XBS 切换（避免双弹窗）
    if (LBIsDiscoverTabActive()) {
        UIViewController *host = [self isKindOfClass:[UIViewController class]]
            ? (UIViewController *)self : LBPrimaryDiscoverHost();
        if (host) {
            LBPresentExploreSourcePicker(host);
            return;
        }
    }
    if (sOrig_onSwitchBtn) sOrig_onSwitchBtn(self, _cmd);
}

static void LBDiscover_onSwitchBtnArg(id self, SEL _cmd, id sender) {
    if (LBIsDiscoverTabActive()) {
        LBDiscover_onSwitchBtn(self, @selector(onSwitchBtnEvent));
        return;
    }
    if (sOrig_onSwitchBtnArg) sOrig_onSwitchBtnArg(self, _cmd, sender);
}

static void LBHookDiscoverNativeUIOnClass(Class cls) {
    if (!cls) return;
    SEL selTab = @selector(pageTitleView:selectedIndex:);
    Class ownerTab = LBClassOwningInstanceMethod(cls, selTab);
    if (ownerTab) {
        Method m = class_getInstanceMethod(ownerTab, selTab);
        if (m && !sOrig_pageTitleSelected) {
            sOrig_pageTitleSelected = (void (*)(id, SEL, id, NSInteger))method_getImplementation(m);
            method_setImplementation(m, (IMP)LBDiscover_pageTitleSelected);
        }
    }
    SEL selSw = @selector(onSwitchBtnEvent);
    Class ownerSw = LBClassOwningInstanceMethod(cls, selSw);
    if (ownerSw) {
        Method m = class_getInstanceMethod(ownerSw, selSw);
        if (m && !sOrig_onSwitchBtn) {
            sOrig_onSwitchBtn = (void (*)(id, SEL))method_getImplementation(m);
            method_setImplementation(m, (IMP)LBDiscover_onSwitchBtn);
        }
    }
    SEL selSw2 = @selector(onSwitchBtnEvent:);
    Class ownerSw2 = LBClassOwningInstanceMethod(cls, selSw2);
    if (ownerSw2) {
        Method m = class_getInstanceMethod(ownerSw2, selSw2);
        if (m && !sOrig_onSwitchBtnArg) {
            sOrig_onSwitchBtnArg = (void (*)(id, SEL, id))method_getImplementation(m);
            method_setImplementation(m, (IMP)LBDiscover_onSwitchBtnArg);
        }
    }
}

void LBInstallDiscoverNativeUIHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (NSString *cn in @[@"BookWorldHomeCon", @"BookStoreBaseCon", @"ShudanHomeCon", @"BookListCon"]) {
            LBHookDiscoverNativeUIOnClass(NSClassFromString(cn));
        }
        [@"discover native UI hooks installed"
            writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_discover_native.txt"]
            atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    });
}

/// 刷新原生分类标签（原 LBRefreshDiscoverKindBar，已去掉 overlay）
void LBRefreshDiscoverKindBar(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ LBRefreshDiscoverKindBar(); });
        return;
    }
    if (!LBIsDiscoverTabActive()) return;
    LBInstallDiscoverNativeUIHooks();

    UIViewController *host = LBPrimaryDiscoverHost();
    if (!host || !host.isViewLoaded || !host.view) return;

    id core = LBKindCore();
    if (!core) return;

    NSString *src = LBCurrentExploreSourceUrl(core);
    NSString *srcName = nil;
    for (id row in LBParseJSONArray(
             ([core respondsToSelector:@selector(exploreCapableSourcesJSON)]
              ? [core valueForKey:@"exploreCapableSourcesJSON"] : @"[]"))) {
        if ([row isKindOfClass:[NSDictionary class]] && [row[@"url"] isEqual:src]) {
            srcName = row[@"name"];
            break;
        }
    }

    NSString *kindsJSON = @"[]";
    if ([core respondsToSelector:@selector(exploreKindsJSONForSourceUrl:)]) {
        kindsJSON = ((NSString *(*)(id, SEL, NSString *))objc_msgSend)(
            core, @selector(exploreKindsJSONForSourceUrl:), src);
    }
    NSArray *kinds = LBParseJSONArray(kindsJSON);
    LBFeedNativeDiscoverHeader(host, kinds, srcName);
}
