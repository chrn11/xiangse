#import "LBInternal.h"
#import "LegadoBridge.h"

/// 发现页：香色原生 SGPageTitleView + BookListCon 子页；禁止 Bridge overlay 标签栏/表（tag LBKB/LBPV）。

static const NSInteger kLBKindBarTag = 0x4C424B42; // 'LBKB' — 仅用于清除历史 overlay
static const NSInteger kLBOverlayTVTag = 0x4C425056; // 'LBPV' — 仅用于清除历史 overlay
static NSInteger sSelectedKindIndex = 0;
static NSArray *sCachedKinds = nil;
static NSString *sLastFeedSig = nil;
static CFAbsoluteTime sLastFeedAt = 0;
static BOOL sNativeChromeBuilt = NO;
static BOOL sNativeChromeBuildScheduled = NO;

static void (*sOrig_pageTitleSelected)(id, SEL, id, NSInteger) = NULL;
static void (*sOrig_onSwitchBtn)(id, SEL) = NULL;
static void (*sOrig_onSwitchBtnArg)(id, SEL, id) = NULL;
static NSString *(*sOrig_getUseSourceName)(id, SEL) = NULL;
static NSString *sDiscoverUseSourceName = nil;
static BOOL sFeedingDiscoverHeader = NO;

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

/// 从原生表挑一个带完整 bookWorld 的 donor（非 Legado）。outName 可空。
static NSDictionary *LBFindDonorBookWorld(id mgr, NSString **outName) {
    if (outName) *outName = nil;
    if (!mgr) return nil;
    id list = nil;
    @try { list = [mgr valueForKey:@"dicModelList"]; } @catch (__unused NSException *e) {}
    if (![list isKindOfClass:[NSDictionary class]]) return nil;
    __block NSDictionary *best = nil;
    __block NSUInteger bestN = 0;
    __block NSString *bestName = nil;
    [(NSDictionary *)list enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        if (![obj isKindOfClass:[NSDictionary class]]) return;
        NSDictionary *m = (NSDictionary *)obj;
        id marker = m[@"legadoBridge"];
        if ([marker isKindOfClass:[NSString class]] && [marker isEqualToString:@"1"]) return;
        if ([marker isKindOfClass:[NSNumber class]] && [marker boolValue]) return;
        NSString *name = [key isKindOfClass:[NSString class]] ? (NSString *)key : @"";
        // 听书/漫画 donor 易在文本发现页 viewDidLoad 崩
        if ([name containsString:@"喜马拉雅"] || [name containsString:@"FM"] ||
            [name containsString:@"漫画"] || [name containsString:@"听书"] ||
            [name containsString:@"有声"]) {
            return;
        }
        NSString *stype = @"";
        id st = m[@"sourceType"];
        if ([st isKindOfClass:[NSString class]]) stype = [(NSString *)st lowercaseString];
        if (stype.length && ![stype containsString:@"dom"] && ![stype containsString:@"text"] &&
            ![stype isEqualToString:@"0"]) {
            // 非文本类降权：仍可作候选但分数减半
        }
        id bw = m[@"bookWorld"];
        if (![bw isKindOfClass:[NSDictionary class]]) return;
        NSUInteger n = [(NSDictionary *)bw count];
        if (n < 3) return;
        NSUInteger score = n;
        if ([stype containsString:@"dom"] || [stype containsString:@"text"] || stype.length == 0) {
            score += 100;
        }
        // Reader0 对照源：优先番茄，分类数适中更稳
        if ([name containsString:@"番茄"]) score += 500;
        if ([name containsString:@"小说"]) score += 50;
        if (n >= 5 && n <= 40) score += 80;
        else if (n > 80) score = score > 40 ? score - 40 : 0;
        if (score > bestN) {
            bestN = score;
            best = (NSDictionary *)bw;
            bestName = name;
        }
    }];
    if (bestN >= 3 && best) {
        if (outName) *outName = bestName;
        LBAppendNativeMarker([NSString stringWithFormat:@"bwDonor name=%@ score=%lu keys=%lu",
                              bestName ?: @"?", (unsigned long)bestN,
                              (unsigned long)[(NSDictionary *)best count]]);
        return best;
    }
    return nil;
}

/// respondsToSelector 在部分宿主上对 openConfig 不可靠；沿继承链找 IMP
static BOOL LBInvokeOpenConfigByName(id host, NSString *cfgName) {
    if (!host || cfgName.length == 0) return NO;
    SEL openSel = @selector(openConfigByName:);
    Class cls = object_getClass(host);
    while (cls && cls != [NSObject class]) {
        Method m = class_getInstanceMethod(cls, openSel);
        if (m) {
            @try {
                ((void (*)(id, SEL, id))method_getImplementation(m))(host, openSel, cfgName);
                LBAppendNativeMarker([NSString stringWithFormat:@"openConfigByName %@ via %@",
                                      cfgName, NSStringFromClass(cls)]);
                return YES;
            } @catch (NSException *ex) {
                LBAppendNativeMarker([NSString stringWithFormat:@"openConfigByName EX %@",
                                      ex.reason ?: @""]);
                return NO;
            }
        }
        cls = class_getSuperclass(cls);
    }
    if ([host respondsToSelector:openSel]) {
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(host, openSel, cfgName);
            LBAppendNativeMarker([NSString stringWithFormat:@"openConfigByName %@ responds", cfgName]);
            return YES;
        } @catch (NSException *ex) {
            LBAppendNativeMarker([NSString stringWithFormat:@"openConfigByName EX %@",
                                  ex.reason ?: @""]);
            return NO;
        }
    }
    LBAppendNativeMarker(@"openConfigByName noSel");
    return NO;
}

/// 用真实 XBS donor 打开原生配置；成功后只改 titles，勿再 setDicModel 覆盖
static NSDictionary *LBPrepareDiscoverDicModel(UIViewController *host, NSString *srcName, NSArray *titles) {
    Class mgrCls = NSClassFromString(@"BookSourceModelManager");
    id mgr = nil;
    if (mgrCls && [mgrCls respondsToSelector:@selector(sharedInstance)]) {
        mgr = ((id (*)(id, SEL))objc_msgSend)(mgrCls, @selector(sharedInstance));
    }

    NSString *donorName = nil;
    NSDictionary *donorBW = LBFindDonorBookWorld(mgr, &donorName);

    if (donorName.length > 0) {
        sDiscoverUseSourceName = [donorName copy];
    }

    NSString *cfgName = donorName.length ? donorName : srcName;
    BOOL opened = NO;
    if (cfgName.length > 0) {
        opened = LBInvokeOpenConfigByName(host, cfgName);
        // 不调 onBookSourceSwitch: —— 参数语义不明，曾导致发现宿主推不出来
    }

    // openConfig 已装好完整 dicModel 时禁止再 setDicModel（会冲掉原生 bookWorld 配置）
    if (opened) {
        if (titles.count > 0) {
            @try { [host setValue:titles forKey:@"arrHeaderBtnTitle"]; } @catch (__unused NSException *e) {}
        }
        id cur = nil;
        @try { cur = [host valueForKey:@"dicModel"]; } @catch (__unused NSException *e) {}
        LBAppendNativeMarker([NSString stringWithFormat:@"keepOpenConfigModel hasDic=%d",
                              [cur isKindOfClass:[NSDictionary class]] ? 1 : 0]);
        return [cur isKindOfClass:[NSDictionary class]] ? cur : nil;
    }

    // 无 openConfig：退回手工灌模型
    NSMutableDictionary *model = nil;
    NSDictionary *base = srcName.length ? LBLegadoNativeModel(srcName) : nil;
    model = [base isKindOfClass:[NSDictionary class]] ? [base mutableCopy] : [NSMutableDictionary dictionary];
    if (donorBW) model[@"bookWorld"] = donorBW;
    if (titles.count > 0) model[@"arrHeaderBtnTitle"] = titles;
    if (srcName.length > 0) model[@"cf_title"] = srcName;
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
    return model;
}

/// 用 Legado 分类灌原生发现：donor bookWorld + 一次性 resetContent（禁手工 SGPage）
static void LBFeedNativeDiscoverHeader(UIViewController *host, NSArray *kinds, NSString *srcName) {
    if (!host) return;
    LBRemoveDiscoverOverlays(host);

    NSMutableArray *titles = [NSMutableArray array];
    for (id item in kinds) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        [titles addObject:item[@"title"] ?: @"分类"];
    }
    if (titles.count == 0) [titles addObject:@"全部"];

    // 已建成原生 chrome：只改导航标题，禁止再 reset
    if (sNativeChromeBuilt) {
        id existTitle = nil;
        id existScroll = nil;
        @try { existTitle = [host valueForKey:@"pageTitleView"]; } @catch (__unused NSException *e) {}
        @try { existScroll = [host valueForKey:@"pageContentScrollView"]; } @catch (__unused NSException *e) {}
        if (existTitle && existScroll) {
            if (srcName.length > 0) {
                @try { host.navigationItem.title = srcName; } @catch (__unused NSException *e) {}
                @try { host.title = srcName; } @catch (__unused NSException *e) {}
            }
            sCachedKinds = [kinds copy];
            return;
        }
        // chrome 丢失则允许再试一次
        sNativeChromeBuilt = NO;
    }

    NSString *sig = [NSString stringWithFormat:@"%@|%@", srcName ?: @"", [titles componentsJoinedByString:@","]];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (sLastFeedSig && [sLastFeedSig isEqualToString:sig] && (now - sLastFeedAt) < 2.0) {
        return;
    }

    // 窗口未就绪：延后一次再建，避免 frame=0 / 空 push 立刻 reset 崩
    if (!host.isViewLoaded || !host.view.window || CGRectIsEmpty(host.view.bounds)) {
        if (!sNativeChromeBuildScheduled) {
            sNativeChromeBuildScheduled = YES;
            LBAppendNativeMarker(@"deferFeed waitWindow");
            __weak UIViewController *weakHost = host;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                sNativeChromeBuildScheduled = NO;
                UIViewController *h = weakHost ?: LBPrimaryDiscoverHost();
                if (!h || !LBIsDiscoverTabActive()) return;
                LBFeedNativeDiscoverHeader(h, kinds, srcName);
            });
        }
        // 仍先保证顶栏源名可见
        if (srcName.length > 0) {
            @try { host.navigationItem.title = srcName; } @catch (__unused NSException *e) {}
            @try { host.title = srcName; } @catch (__unused NSException *e) {}
        }
        @try { [host setValue:titles forKey:@"arrHeaderBtnTitle"]; } @catch (__unused NSException *e) {}
        return;
    }

    sLastFeedSig = [sig copy];
    sLastFeedAt = now;

    if (srcName.length > 0) {
        sDiscoverUseSourceName = [srcName copy];
    }

    sFeedingDiscoverHeader = YES;
    @try {
        id existTitle = nil;
        id existScroll = nil;
        @try { existTitle = [host valueForKey:@"pageTitleView"]; } @catch (__unused NSException *e) {}
        @try { existScroll = [host valueForKey:@"pageContentScrollView"]; } @catch (__unused NSException *e) {}
        if (existTitle && existScroll) {
            sNativeChromeBuilt = YES;
            if (srcName.length > 0) {
                @try { host.navigationItem.title = srcName; } @catch (__unused NSException *e) {}
                @try { host.title = srcName; } @catch (__unused NSException *e) {}
            }
            sCachedKinds = [kinds copy];
            LBAppendNativeMarker(@"pageChrome exists skipReset");
            LBAppendNativeHostState(host, @"keepChrome");
            return;
        }

        LBPrepareDiscoverDicModel(host, srcName, titles);

        NSString *consName = sDiscoverUseSourceName.length ? sDiscoverUseSourceName : (srcName ?: @"");
        @try { [host setValue:titles forKey:@"arrHeaderBtnTitle"]; } @catch (__unused NSException *e) {}
        @try { [host setValue:consName forKey:@"useSourceName"]; } @catch (__unused NSException *e) {}
        @try { [host setValue:consName forKey:@"lastSourceName"]; } @catch (__unused NSException *e) {}
        @try { [host setValue:consName forKey:@"sourceName"]; } @catch (__unused NSException *e) {}

        [host.view setNeedsLayout];
        [host.view layoutIfNeeded];

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

        id titleView = nil;
        id scroll = nil;
        @try { titleView = [host valueForKey:@"pageTitleView"]; } @catch (__unused NSException *e) {}
        @try { scroll = [host valueForKey:@"pageContentScrollView"]; } @catch (__unused NSException *e) {}
        BOOL hasPageChrome = (titleView != nil && scroll != nil);

        // createCons 仅作诊断/兜底：有 cons 也不二次 reset（二次 rebuild 易杀进程）
        if (!hasPageChrome &&
            host.childViewControllers.count == 0 &&
            [host respondsToSelector:@selector(createCons:titles:sourceName:)]) {
            @try {
                NSMutableArray *cons = [NSMutableArray array];
                ((void (*)(id, SEL, id, id, id))objc_msgSend)(
                    host, @selector(createCons:titles:sourceName:), cons, titles, consName);
                LBAppendNativeMarker([NSString stringWithFormat:
                                      @"createCons fallback titles=%lu cons=%lu src=%@",
                                      (unsigned long)titles.count, (unsigned long)cons.count, consName]);
            } @catch (NSException *ex) {
                LBAppendNativeMarker([NSString stringWithFormat:@"createCons EX %@", ex.reason ?: @""]);
            }
        } else if (hasPageChrome) {
            sNativeChromeBuilt = YES;
            LBAppendNativeMarker(@"pageChrome ready skipCreateConsWire");
        }

        sCachedKinds = [kinds copy];
        if (sSelectedKindIndex >= (NSInteger)titles.count) sSelectedKindIndex = 0;

        // 顶栏仍显示 Legado 源名（donor 只用于建壳）
        if (srcName.length > 0) {
            @try { host.navigationItem.title = srcName; } @catch (__unused NSException *e) {}
            @try { host.title = srcName; } @catch (__unused NSException *e) {}
        }

        LBAppendNativeMarker([NSString stringWithFormat:@"nativeHeader host=%@ src=%@ kinds=%lu sel=%ld",
                              NSStringFromClass([host class]), srcName ?: @"",
                              (unsigned long)titles.count, (long)sSelectedKindIndex]);
        LBAppendNativeHostState(host, @"feedDone");
    } @finally {
        sFeedingDiscoverHeader = NO;
    }
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
    // 仅在主动灌发现头期间改写，避免干扰原生 setSquare 推 World
    if (sFeedingDiscoverHeader && sDiscoverUseSourceName.length > 0) {
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
