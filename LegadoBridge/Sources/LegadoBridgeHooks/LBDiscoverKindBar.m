#import "LBInternal.h"
#import "LegadoBridge.h"

/// 发现页：香色原生 SGPageTitleView + BookListCon 子页；禁止 Bridge overlay 标签栏/表（tag LBKB/LBPV）。

static const NSInteger kLBKindBarTag = 0x4C424B42; // 'LBKB' — 仅用于清除历史 overlay
static const NSInteger kLBOverlayTVTag = 0x4C425056; // 'LBPV' — 仅用于清除历史 overlay
static NSInteger sSelectedKindIndex = 0;
static NSArray *sCachedKinds = nil;
static NSString *sLastFeedSig = nil;
static CFAbsoluteTime sLastFeedAt = 0;

static void (*sOrig_pageTitleSelected)(id, SEL, id, NSInteger) = NULL;
static void (*sOrig_onSwitchBtn)(id, SEL) = NULL;
static void (*sOrig_onSwitchBtnArg)(id, SEL, id) = NULL;
static NSString *(*sOrig_getUseSourceName)(id, SEL) = NULL;
static NSString *sDiscoverUseSourceName = nil;

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

/// 验收：子页 / SGPageTitle / SGPageContent 是否挂上
static void LBAppendNativeHostState(UIViewController *host, NSString *tag) {
    if (!host) return;
    NSUInteger childN = host.childViewControllers.count;
    id titleView = nil;
    id scroll = nil;
    id list = nil;
    @try { titleView = [host valueForKey:@"pageTitleView"]; } @catch (__unused NSException *e) {}
    @try { scroll = [host valueForKey:@"pageContentScrollView"]; } @catch (__unused NSException *e) {}
    @try { list = [host valueForKey:@"listCon"]; } @catch (__unused NSException *e) {}
    NSMutableArray *childNames = [NSMutableArray array];
    for (UIViewController *c in host.childViewControllers) {
        [childNames addObject:NSStringFromClass([c class])];
        if (childNames.count >= 8) break;
    }
    LBAppendNativeMarker([NSString stringWithFormat:
                          @"%@ host=%@ child=%lu titleView=%@ scroll=%@ listCon=%@ kids=%@",
                          tag ?: @"state",
                          NSStringFromClass([host class]),
                          (unsigned long)childN,
                          titleView ? NSStringFromClass([titleView class]) : @"nil",
                          scroll ? NSStringFromClass([scroll class]) : @"nil",
                          list ? NSStringFromClass([list class]) : @"nil",
                          childNames.count ? [childNames componentsJoinedByString:@","] : @"-"]);
}

/// 把 Legado 源模型灌进宿主（含 bookWorld 模板），供 createCons 建子页
static NSDictionary *LBPrepareDiscoverDicModel(UIViewController *host, NSString *srcName, NSArray *titles) {
    NSMutableDictionary *model = nil;
    NSDictionary *base = nil;
    if (srcName.length > 0) {
        base = LBLegadoNativeModel(srcName);
    }
    if ([base isKindOfClass:[NSDictionary class]]) {
        model = [base mutableCopy];
    } else {
        model = [NSMutableDictionary dictionary];
        if (srcName.length > 0) {
            model[@"sourceName"] = srcName;
            model[@"title"] = srcName;
        }
        model[@"sourceType"] = @"DOM";
        model[@"enable"] = @"1";
        model[@"enabled"] = @YES;
    }

    // Manager 的 dicBookWorldTemplateDom 比 base.bookWorld 骨架更完整
    Class mgrCls = NSClassFromString(@"BookSourceModelManager");
    id mgr = nil;
    if (mgrCls && [mgrCls respondsToSelector:@selector(sharedInstance)]) {
        mgr = ((id (*)(id, SEL))objc_msgSend)(mgrCls, @selector(sharedInstance));
    }
    id bwDom = nil;
    @try { bwDom = [mgr valueForKey:@"dicBookWorldTemplateDom"]; } @catch (__unused NSException *e) {}
    if ([bwDom isKindOfClass:[NSDictionary class]] && [(NSDictionary *)bwDom count] > 0) {
        model[@"bookWorld"] = bwDom;
        LBAppendNativeMarker([NSString stringWithFormat:@"bwTemplate keys=%lu",
                              (unsigned long)[(NSDictionary *)bwDom count]]);
    } else if (!model[@"bookWorld"]) {
        model[@"bookWorld"] = @{
            @"actionID": @"bookWorld",
            @"parserID": @"DOM"
        };
        LBAppendNativeMarker(@"bwTemplate missing → minimal bookWorld");
    }

    if (titles.count > 0) {
        model[@"arrHeaderBtnTitle"] = titles;
    }
    if (srcName.length > 0) {
        model[@"sourceName"] = srcName;
        model[@"cf_title"] = srcName;
    }

    @try {
        if ([host respondsToSelector:@selector(setDicModel:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(host, @selector(setDicModel:), model);
            LBAppendNativeMarker(@"setDicModel ok");
        } else {
            [host setValue:model forKey:@"dicModel"];
            LBAppendNativeMarker(@"setValue dicModel ok");
        }
    } @catch (NSException *ex) {
        LBAppendNativeMarker([NSString stringWithFormat:@"setDicModel EX %@", ex.reason ?: @""]);
    }

    // openConfigByName：若表内有该源则走完整装载；失败忽略（已直灌 dicModel）
    if (srcName.length > 0 && [host respondsToSelector:@selector(openConfigByName:)]) {
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(host, @selector(openConfigByName:), srcName);
            LBAppendNativeMarker([NSString stringWithFormat:@"openConfigByName %@", srcName]);
        } @catch (NSException *ex) {
            LBAppendNativeMarker([NSString stringWithFormat:@"openConfigByName EX %@", ex.reason ?: @""]);
        }
    }
    return model;
}

/// 用 Legado 分类灌原生发现：先灌 dicModel/bookWorld，再 resetContent
static void LBFeedNativeDiscoverHeader(UIViewController *host, NSArray *kinds, NSString *srcName) {
    if (!host) return;
    LBRemoveDiscoverOverlays(host);

    NSMutableArray *titles = [NSMutableArray array];
    for (id item in kinds) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        [titles addObject:item[@"title"] ?: @"分类"];
    }
    if (titles.count == 0) [titles addObject:@"全部"];

    NSString *sig = [NSString stringWithFormat:@"%@|%@", srcName ?: @"", [titles componentsJoinedByString:@","]];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (sLastFeedSig && [sLastFeedSig isEqualToString:sig] && (now - sLastFeedAt) < 1.2) {
        return;
    }
    sLastFeedSig = [sig copy];
    sLastFeedAt = now;

    if (srcName.length > 0) {
        sDiscoverUseSourceName = [srcName copy];
    }

    LBPrepareDiscoverDicModel(host, srcName, titles);

    @try { [host setValue:titles forKey:@"arrHeaderBtnTitle"]; } @catch (__unused NSException *e) {}
    @try { [host setValue:srcName forKey:@"useSourceName"]; } @catch (__unused NSException *e) {}
    @try { [host setValue:srcName forKey:@"lastSourceName"]; } @catch (__unused NSException *e) {}
    @try { [host setValue:srcName forKey:@"sourceName"]; } @catch (__unused NSException *e) {}

    // 视图未进窗 / bounds=0 时 SGPage 会建了看不见；尽量等有尺寸
    if (host.isViewLoaded && CGRectIsEmpty(host.view.bounds)) {
        [host.view setNeedsLayout];
        [host.view layoutIfNeeded];
    }

    BOOL didReset = NO;
    if ([host respondsToSelector:@selector(resetContent)]) {
        @try {
            ((void (*)(id, SEL))objc_msgSend)(host, @selector(resetContent));
            didReset = YES;
            LBAppendNativeMarker(@"resetContent ok");
        } @catch (NSException *ex) {
            LBAppendNativeMarker([NSString stringWithFormat:@"resetContent EX %@", ex.reason ?: @""]);
        }
    }
    LBAppendNativeHostState(host, didReset ? @"afterReset" : @"noReset");

    // reset 后仍无子页时，再显式 createCons（仍禁止裸 alloc BookListCon）
    if (host.childViewControllers.count == 0 &&
        [host respondsToSelector:@selector(createCons:titles:sourceName:)]) {
        @try {
            NSMutableArray *cons = [NSMutableArray array];
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(
                host, @selector(createCons:titles:sourceName:), cons, titles, srcName ?: @"");
            LBAppendNativeMarker([NSString stringWithFormat:@"createCons fallback titles=%lu cons=%lu",
                                  (unsigned long)titles.count, (unsigned long)cons.count]);
            if (cons.count > 0) {
                Class titleCls = NSClassFromString(@"SGPageTitleView");
                Class scrollCls = NSClassFromString(@"SGPageContentScrollView");
                Class confCls = NSClassFromString(@"SGPageTitleViewConfigure");
                id configure = nil;
                if (confCls && [confCls respondsToSelector:@selector(pageTitleViewConfigure)]) {
                    configure = ((id (*)(id, SEL))objc_msgSend)(confCls, @selector(pageTitleViewConfigure));
                }
                CGFloat w = host.view.bounds.size.width;
                CGFloat h = host.view.bounds.size.height;
                CGFloat titleH = 44.0;
                if (titleCls && [titleCls respondsToSelector:@selector(pageTitleViewWithFrame:delegate:titleNames:configure:)]) {
                    CGRect tf = CGRectMake(0, 0, w, titleH);
                    id tv = ((id (*)(id, SEL, CGRect, id, id, id))objc_msgSend)(
                        titleCls,
                        @selector(pageTitleViewWithFrame:delegate:titleNames:configure:),
                        tf, host, titles, configure);
                    if (tv) {
                        @try { [host setValue:tv forKey:@"pageTitleView"]; } @catch (__unused NSException *e) {}
                        if ([tv isKindOfClass:[UIView class]] && ![(UIView *)tv superview]) {
                            [host.view addSubview:(UIView *)tv];
                        }
                    }
                }
                if (scrollCls) {
                    SEL initSel = @selector(initWithFrame:parentVC:childVCs:);
                    if ([scrollCls instancesRespondToSelector:initSel]) {
                        CGRect cf = CGRectMake(0, titleH, w, MAX(0, h - titleH));
                        id sc = ((id (*)(id, SEL, CGRect, id, id))objc_msgSend)(
                            [scrollCls alloc], initSel, cf, host, cons);
                        if (sc) {
                            @try { [host setValue:sc forKey:@"pageContentScrollView"]; } @catch (__unused NSException *e) {}
                            if ([sc isKindOfClass:[UIView class]] && ![(UIView *)sc superview]) {
                                [host.view addSubview:(UIView *)sc];
                            }
                        }
                    }
                }
                LBAppendNativeHostState(host, @"afterCreateConsWire");
            }
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

/// 书列表灌入后刷新原生子页（禁止再 resetContent，避免拆掉刚建好的 SGPage）
void LBReloadDiscoverNativeList(UIViewController *host) {
    if (!host) return;
    UIViewController *listVC = LBActiveDiscoverListVC(host);
    if (!listVC) listVC = host;

    UITableView *tv = nil;
    for (NSString *k in @[@"tableView", @"tv", @"listTableView", @"mainTableView", @"myTableView"]) {
        @try {
            id v = [listVC valueForKey:k];
            if ([v isKindOfClass:[UITableView class]]) { tv = (UITableView *)v; break; }
        } @catch (__unused NSException *e) {}
    }
    if (!tv && listVC.isViewLoaded && listVC.view) {
        NSMutableArray *q = [NSMutableArray arrayWithObject:listVC.view];
        NSInteger budget = 60;
        while (q.count > 0 && budget-- > 0) {
            UIView *cur = q.firstObject;
            [q removeObjectAtIndex:0];
            if ([cur isKindOfClass:[UITableView class]]) { tv = (UITableView *)cur; break; }
            for (UIView *sub in cur.subviews) [q addObject:sub];
        }
    }
    if (tv) {
        @try { [tv reloadData]; } @catch (__unused NSException *e) {}
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

static NSString *LBDiscover_getUseSourceName(id self, SEL _cmd) {
    if (LBIsDiscoverTabActive() && sDiscoverUseSourceName.length > 0) {
        return sDiscoverUseSourceName;
    }
    if (sOrig_getUseSourceName) return sOrig_getUseSourceName(self, _cmd);
    @try {
        id v = [self valueForKey:@"useSourceName"];
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) return v;
    } @catch (__unused NSException *e) {}
    return nil;
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
    SEL selName = @selector(getUseSourceName);
    Class ownerName = LBClassOwningInstanceMethod(cls, selName);
    if (ownerName) {
        Method m = class_getInstanceMethod(ownerName, selName);
        if (m && !sOrig_getUseSourceName) {
            sOrig_getUseSourceName = (NSString *(*)(id, SEL))method_getImplementation(m);
            method_setImplementation(m, (IMP)LBDiscover_getUseSourceName);
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
