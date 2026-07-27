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
static BOOL sRestoreListMode = NO;
static BOOL sTitleOnlyStabilized = NO;

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
    __block NSMutableArray *topLog = [NSMutableArray array];
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
            [name containsString:@"有声"] || [name containsString:@"动漫"] ||
            [name containsString:@"语音"] || [name containsString:@"有毒"] ||
            [name hasPrefix:@"FZ-"] || [name containsString:@"FZ-"]) {
            return;
        }
        NSString *stype = @"";
        id st = m[@"sourceType"];
        if ([st isKindOfClass:[NSString class]]) stype = [(NSString *)st lowercaseString];
        id bw = m[@"bookWorld"];
        if (![bw isKindOfClass:[NSDictionary class]]) return;
        NSDictionary *bwd = (NSDictionary *)bw;
        NSUInteger topKeys = bwd.count;
        if (topKeys < 6) return; // 过薄（如仅 actionID/parserID）会建空 SGPage 后崩
        NSUInteger nested = 0;
        for (id v in bwd.allValues) {
            if ([v isKindOfClass:[NSArray class]]) nested += [(NSArray *)v count] * 5;
            else if ([v isKindOfClass:[NSDictionary class]]) nested += [(NSDictionary *)v count];
        }
        NSUInteger score = topKeys * 10 + nested;
        if ([stype containsString:@"dom"] || [stype containsString:@"text"] || stype.length == 0) {
            score += 100;
        }
        // Reader0 对照：番茄小说2025*；带 emoji 装饰名且结构薄的降权
        if ([name containsString:@"番茄小说2025"] || [name containsString:@"番茄小说20"]) {
            score += 400;
        } else if ([name containsString:@"番茄"] && topKeys >= 10) {
            score += 150;
        }
        if ([name containsString:@"笔趣"]) score += 40;
        if ([name containsString:@"起点"] || [name containsString:@"息壤"] ||
            [name containsString:@"长佩"]) {
            score += 120;
        }
        if (nested >= 20) score += 80;
        if (topLog.count < 8) {
            [topLog addObject:[NSString stringWithFormat:@"%@:k%lu+n%lu=%lu",
                               name, (unsigned long)topKeys, (unsigned long)nested,
                               (unsigned long)score]];
        }
        if (score > bestN) {
            bestN = score;
            best = bwd;
            bestName = name;
        }
    }];
    if (topLog.count > 0) {
        LBAppendNativeMarker([NSString stringWithFormat:@"bwDonorCand %@",
                              [topLog componentsJoinedByString:@"; "]]);
    }
    if (bestN >= 60 && best) {
        if (outName) *outName = bestName;
        LBAppendNativeMarker([NSString stringWithFormat:@"bwDonor name=%@ score=%lu keys=%lu",
                              bestName ?: @"?", (unsigned long)bestN,
                              (unsigned long)[(NSDictionary *)best count]]);
        return best;
    }
    LBAppendNativeMarker(@"bwDonor none (need keys>=6 weight>=60)");
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

static BOOL LBForceSetDicModel(UIViewController *host, NSDictionary *model) {
    if (!host || !model) return NO;
    SEL setSel = @selector(setDicModel:);
    Class cls = object_getClass(host);
    while (cls && cls != [NSObject class]) {
        Method m = class_getInstanceMethod(cls, setSel);
        if (m) {
            @try {
                ((void (*)(id, SEL, id))method_getImplementation(m))(host, setSel, model);
                return YES;
            } @catch (__unused NSException *ex) {
                return NO;
            }
        }
        cls = class_getSuperclass(cls);
    }
    if ([host respondsToSelector:setSel]) {
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(host, setSel, model);
            return YES;
        } @catch (__unused NSException *ex) {
            return NO;
        }
    }
    @try {
        [host setValue:model forKey:@"dicModel"];
        return YES;
    } @catch (__unused NSException *ex) {
        return NO;
    }
}

/// 用真实 XBS donor 打开原生配置；成功后只改 titles，勿再 setDicModel 覆盖
/// 返回含可用 bookWorld 的模型；无可用 donor 时返回 nil
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
    }

    if (opened) {
        if (titles.count > 0) {
            @try { [host setValue:titles forKey:@"arrHeaderBtnTitle"]; } @catch (__unused NSException *e) {}
        }
        id cur = nil;
        @try { cur = [host valueForKey:@"dicModel"]; } @catch (__unused NSException *e) {}
        NSUInteger bwKeys = 0;
        if ([cur isKindOfClass:[NSDictionary class]]) {
            id bw = cur[@"bookWorld"];
            if ([bw isKindOfClass:[NSDictionary class]]) bwKeys = [(NSDictionary *)bw count];
        }
        LBAppendNativeMarker([NSString stringWithFormat:@"keepOpenConfigModel hasDic=%d bwKeys=%lu",
                              [cur isKindOfClass:[NSDictionary class]] ? 1 : 0,
                              (unsigned long)bwKeys]);
        if (bwKeys >= 6 && [cur isKindOfClass:[NSDictionary class]]) {
            return (NSDictionary *)cur;
        }
        if (donorBW.count >= 6 && [cur isKindOfClass:[NSDictionary class]]) {
            NSMutableDictionary *fixed = [cur mutableCopy];
            fixed[@"bookWorld"] = donorBW;
            if (titles.count > 0) fixed[@"arrHeaderBtnTitle"] = titles;
            LBForceSetDicModel(host, fixed);
            return fixed;
        }
        if (donorBW.count >= 6) {
            NSMutableDictionary *model = [NSMutableDictionary dictionary];
            model[@"bookWorld"] = donorBW;
            if (titles.count > 0) model[@"arrHeaderBtnTitle"] = titles;
            if (donorName.length) model[@"cf_title"] = donorName;
            LBForceSetDicModel(host, model);
            return model;
        }
        return nil;
    }

    if (donorBW.count < 6) {
        LBAppendNativeMarker(@"prepare skip: no usable donorBW");
        return nil;
    }

    NSMutableDictionary *model = nil;
    NSDictionary *base = srcName.length ? LBLegadoNativeModel(srcName) : nil;
    model = [base isKindOfClass:[NSDictionary class]] ? [base mutableCopy] : [NSMutableDictionary dictionary];
    model[@"bookWorld"] = donorBW;
    if (titles.count > 0) model[@"arrHeaderBtnTitle"] = titles;
    if (donorName.length > 0) {
        model[@"cf_title"] = donorName;
    } else if (srcName.length > 0) {
        model[@"cf_title"] = srcName;
    }
    BOOL setOk = LBForceSetDicModel(host, model);
    LBAppendNativeMarker([NSString stringWithFormat:@"setDicModel %@ donorBW=%lu",
                          setOk ? @"ok" : @"fail", (unsigned long)donorBW.count]);
    // 以构造模型为准（KVC 读回可能丢 bookWorld）
    return model;
}

/// 毁掉 BookListCon 子页，只留分类条（避免 viewDidLoad/拉网杀进程）
static void LBDestroyDiscoverListConsKeepTitle(UIViewController *host, id scroll) {
    NSArray *kids = nil;
    @try {
        id cv = [scroll valueForKey:@"childViewControllers"];
        if ([cv isKindOfClass:[NSArray class]]) kids = [cv copy];
    } @catch (__unused NSException *e) {}
    if (kids.count == 0) {
        @try {
            id cv = [scroll valueForKey:@"childVCs"];
            if ([cv isKindOfClass:[NSArray class]]) kids = [cv copy];
        } @catch (__unused NSException *e) {}
    }
    NSUInteger killed = 0;
    for (id c in kids ?: @[]) {
        UIViewController *vc = nil;
        if ([c isKindOfClass:[UIViewController class]]) vc = c;
        if (!vc) continue;
        @try {
            [vc.view removeFromSuperview];
            if (vc.parentViewController) {
                [vc willMoveToParentViewController:nil];
                [vc removeFromParentViewController];
            }
            killed++;
        } @catch (__unused NSException *e) {}
    }
    @try { [scroll setValue:@[] forKey:@"childViewControllers"]; } @catch (__unused NSException *e) {}
    @try { [scroll setValue:@[] forKey:@"childVCs"]; } @catch (__unused NSException *e) {}
    @try {
        if ([scroll isKindOfClass:[UIView class]]) {
            [(UIView *)scroll removeFromSuperview];
        }
    } @catch (__unused NSException *e) {}
    @try { [host setValue:nil forKey:@"pageContentScrollView"]; } @catch (__unused NSException *e) {}
    // 保活分类条：销毁 scroll 后 titleView 可能被连带摘掉，强制挂回
    id titleView = nil;
    @try { titleView = [host valueForKey:@"pageTitleView"]; } @catch (__unused NSException *e) {}
    if ([titleView isKindOfClass:[UIView class]] && host.isViewLoaded && host.view) {
        UIView *tv = (UIView *)titleView;
        if (!tv.superview) {
            CGFloat w = host.view.bounds.size.width;
            if (w < 1) w = [UIScreen mainScreen].bounds.size.width;
            CGFloat top = 0;
            if (@available(iOS 11.0, *)) {
                top = host.view.safeAreaInsets.top;
            }
            // 导航栏下方
            if (top < 64) top = 64;
            tv.frame = CGRectMake(0, top, w, 44);
            [host.view addSubview:tv];
            LBAppendNativeMarker(@"titleView reattached");
        } else {
            LBAppendNativeMarker(@"titleView stillInHierarchy");
        }
    } else {
        LBAppendNativeMarker(@"titleView missing afterDestroy");
    }
    LBAppendNativeMarker([NSString stringWithFormat:@"destroyListCons killed=%lu keepTitle=1",
                          (unsigned long)killed]);
}

/// 清空原生子页数据，避免 BookListCon 带着 donor 原生请求/cell 崩
static void LBSanitizeDiscoverListCons(UIViewController *host, id scroll) {
    NSMutableArray *kids = [NSMutableArray array];
    @try {
        for (NSString *k in @[@"childVCs", @"childViewControllers", @"arrChildVCs", @"vcs"]) {
            id cv = nil;
            @try { cv = [scroll valueForKey:k]; } @catch (__unused NSException *e) { cv = nil; }
            if ([cv isKindOfClass:[NSArray class]] && [(NSArray *)cv count] > 0) {
                [kids addObjectsFromArray:cv];
                id first = [(NSArray *)cv firstObject];
                LBAppendNativeMarker([NSString stringWithFormat:@"scrollKidsKey=%@ n=%lu first=%@",
                                      k, (unsigned long)[(NSArray *)cv count],
                                      first ? NSStringFromClass([first class]) : @"nil"]);
                break;
            }
        }
    } @catch (__unused NSException *e) {}
    if (kids.count == 0) {
        [kids addObjectsFromArray:host.childViewControllers ?: @[]];
    }
    NSUInteger n = 0;
    for (id c in kids) {
        // 兼容非 UIViewController 包装
        id target = c;
        if (![target isKindOfClass:[UIViewController class]]) {
            @try {
                id v = [c valueForKey:@"viewController"];
                if ([v isKindOfClass:[UIViewController class]]) target = v;
            } @catch (__unused NSException *e) {}
        }
        if (![target isKindOfClass:[UIViewController class]]) continue;
        UIViewController *vc = (UIViewController *)target;
        for (NSString *k in @[@"arrBaseData", @"itemList", @"arrData", @"dataArray", @"books"]) {
            @try { [vc setValue:@[] forKey:k]; } @catch (__unused NSException *e) {}
        }
        @try {
            UITableView *tv = nil;
            id v = [vc valueForKey:@"tableView"];
            if ([v isKindOfClass:[UITableView class]]) tv = v;
            if (tv) [tv reloadData];
        } @catch (__unused NSException *e) {}
        n++;
    }
    LBAppendNativeMarker([NSString stringWithFormat:@"sanitizeListCons n=%lu raw=%lu",
                          (unsigned long)n, (unsigned long)kids.count]);
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

        NSDictionary *prepared = LBPrepareDiscoverDicModel(host, srcName, titles);
        id bwObj = prepared[@"bookWorld"];
        NSUInteger bwKeys = [bwObj isKindOfClass:[NSDictionary class]] ? [(NSDictionary *)bwObj count] : 0;
        if (!prepared || bwKeys < 6) {
            if (srcName.length > 0) {
                @try { host.navigationItem.title = srcName; } @catch (__unused NSException *e) {}
                @try { host.title = srcName; } @catch (__unused NSException *e) {}
            }
            @try { [host setValue:titles forKey:@"arrHeaderBtnTitle"]; } @catch (__unused NSException *e) {}
            sCachedKinds = [kinds copy];
            LBAppendNativeMarker([NSString stringWithFormat:
                                  @"shellFallback noDonorBW keys=%lu",
                                  (unsigned long)bwKeys]);
            LBAppendNativeHostState(host, @"shellFallback");
            return;
        }
        LBAppendNativeMarker([NSString stringWithFormat:@"preparedBW keys=%lu useReset=1",
                              (unsigned long)bwKeys]);

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
        NSUInteger childN = host.childViewControllers.count;
        NSUInteger scrollKids = 0;
        @try {
            for (NSString *k in @[@"childVCs", @"childViewControllers", @"arrChildVCs", @"vcs"]) {
                id cv = nil;
                @try { cv = [scroll valueForKey:k]; } @catch (__unused NSException *e) { cv = nil; }
                if ([cv isKindOfClass:[NSArray class]] && [(NSArray *)cv count] > 0) {
                    scrollKids = [(NSArray *)cv count];
                    break;
                }
            }
        } @catch (__unused NSException *e) {}
        LBAppendNativeMarker([NSString stringWithFormat:
                              @"chromeCheck hostChild=%lu scrollKids=%lu",
                              (unsigned long)childN, (unsigned long)scrollKids]);

        // 仅当宿主与 scroll 都无子页时才拆空 chrome（scroll 内可能有 BookListCon）
        if (hasPageChrome && childN == 0 && scrollKids == 0) {
            @try {
                if ([titleView isKindOfClass:[UIView class]]) {
                    [(UIView *)titleView removeFromSuperview];
                }
                if ([scroll isKindOfClass:[UIView class]]) {
                    [(UIView *)scroll removeFromSuperview];
                }
                [host setValue:nil forKey:@"pageTitleView"];
                [host setValue:nil forKey:@"pageContentScrollView"];
            } @catch (__unused NSException *e) {}
            hasPageChrome = NO;
            LBAppendNativeMarker(@"teardownEmptyChrome child=0 scrollKids=0");
            LBAppendNativeHostState(host, @"afterTeardown");
        } else if (hasPageChrome && (childN > 0 || scrollKids > 0)) {
            sNativeChromeBuilt = YES;
            LBSanitizeDiscoverListCons(host, scroll);
            if (sRestoreListMode) {
                // 只保留空列表，不触发 explore（explore 会杀进程）
                sRestoreListMode = NO;
                LBAppendNativeMarker([NSString stringWithFormat:
                                      @"restoreList emptyScroll hostChild=%lu scrollKids=%lu noExplore=1",
                                      (unsigned long)childN, (unsigned long)scrollKids]);
                __weak UIViewController *weakHost = host;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    UIViewController *h = weakHost;
                    if (!h) return;
                    id sc = nil;
                    @try { sc = [h valueForKey:@"pageContentScrollView"]; } @catch (__unused NSException *e) {}
                    LBAppendNativeMarker([NSString stringWithFormat:
                                          @"stillAlive2 host=%@ scroll=%@",
                                          NSStringFromClass([h class]),
                                          sc ? NSStringFromClass([sc class]) : @"nil"]);
                });
            } else {
                LBDestroyDiscoverListConsKeepTitle(host, scroll);
                LBAppendNativeMarker([NSString stringWithFormat:
                                      @"pageChrome keep hostChild=%lu scrollKids=%lu titleOnly=1",
                                      (unsigned long)childN, (unsigned long)scrollKids]);
                __weak UIViewController *weakHost = host;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    UIViewController *h = weakHost;
                    if (!h) return;
                    id tv = nil;
                    @try { tv = [h valueForKey:@"pageTitleView"]; } @catch (__unused NSException *e) {}
                    LBAppendNativeMarker([NSString stringWithFormat:
                                          @"stillAlive host=%@ titleView=%@",
                                          NSStringFromClass([h class]),
                                          tv ? NSStringFromClass([tv class]) : @"nil"]);
                    if (!LBIsDiscoverTabActive() || !tv || sTitleOnlyStabilized) return;
                    sTitleOnlyStabilized = YES;
                    sRestoreListMode = YES;
                    sNativeChromeBuilt = NO;
                    sLastFeedSig = nil;
                    sLastFeedAt = 0;
                    LBAppendNativeMarker(@"restoreList empty schedule");
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        if (!LBIsDiscoverTabActive()) {
                            sRestoreListMode = NO;
                            return;
                        }
                        UIViewController *hh = weakHost ?: LBPrimaryDiscoverHost();
                        if (!hh) {
                            sRestoreListMode = NO;
                            return;
                        }
                        NSString *src2 = nil;
                        @try { src2 = hh.navigationItem.title; } @catch (__unused NSException *e) {}
                        LBFeedNativeDiscoverHeader(hh, sCachedKinds ?: @[], src2);
                    });
                });
            }
        }

        // createCons：reset 未挂子页时先造 cons，再交给原生 resetContent 挂页（禁手工 SGPage）
        if (!sNativeChromeBuilt &&
            host.childViewControllers.count == 0 &&
            [host respondsToSelector:@selector(createCons:titles:sourceName:)]) {
            @try {
                NSMutableArray *cons = [NSMutableArray array];
                ((void (*)(id, SEL, id, id, id))objc_msgSend)(
                    host, @selector(createCons:titles:sourceName:), cons, titles, consName);
                LBAppendNativeMarker([NSString stringWithFormat:
                                      @"createCons fallback titles=%lu cons=%lu src=%@",
                                      (unsigned long)titles.count, (unsigned long)cons.count, consName]);
                if (cons.count > 0 && [host respondsToSelector:@selector(resetContent)]) {
                    // titles 与 cons 数量对齐，避免 reset 用 32 标题挂 19 子页失败
                    NSMutableArray *aligned = [NSMutableArray array];
                    for (NSUInteger i = 0; i < cons.count; i++) {
                        NSString *tn = nil;
                        id cvc = cons[i];
                        for (NSString *k in @[@"title", @"navTitle", @"kindTitle", @"strTitle"]) {
                            @try {
                                id v = [cvc valueForKey:k];
                                if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) {
                                    tn = v; break;
                                }
                            } @catch (__unused NSException *e) {}
                        }
                        if (tn.length == 0 && i < titles.count) tn = titles[i];
                        if (tn.length == 0) tn = [NSString stringWithFormat:@"分类%lu", (unsigned long)(i + 1)];
                        [aligned addObject:tn];
                    }
                    @try { [host setValue:aligned forKey:@"arrHeaderBtnTitle"]; } @catch (__unused NSException *e) {}
                    LBAppendNativeMarker([NSString stringWithFormat:@"alignTitles n=%lu",
                                          (unsigned long)aligned.count]);
                    @try {
                        ((void (*)(id, SEL))objc_msgSend)(host, @selector(resetContent));
                        LBAppendNativeMarker(@"resetContent afterCons");
                    } @catch (NSException *ex) {
                        LBAppendNativeMarker([NSString stringWithFormat:@"resetContent afterCons EX %@",
                                              ex.reason ?: @""]);
                    }
                    LBAppendNativeHostState(host, @"afterConsReset");
                    id tv2 = nil; id sc2 = nil;
                    @try { tv2 = [host valueForKey:@"pageTitleView"]; } @catch (__unused NSException *e) {}
                    @try { sc2 = [host valueForKey:@"pageContentScrollView"]; } @catch (__unused NSException *e) {}
                    NSUInteger sk2 = 0;
                    @try {
                        id cv = [sc2 valueForKey:@"childVCs"];
                        if ([cv isKindOfClass:[NSArray class]]) sk2 = [(NSArray *)cv count];
                    } @catch (__unused NSException *e) {}
                    if ((tv2 && sc2) && (host.childViewControllers.count > 0 || sk2 > 0)) {
                        sNativeChromeBuilt = YES;
                        LBAppendNativeMarker([NSString stringWithFormat:
                                              @"pageChrome afterConsReset hostChild=%lu scrollKids=%lu",
                                              (unsigned long)host.childViewControllers.count,
                                              (unsigned long)sk2]);
                    } else if (tv2 && sc2 && host.childViewControllers.count == 0 && sk2 == 0) {
                        // 仍空则拆掉，避免杀进程
                        @try {
                            if ([tv2 isKindOfClass:[UIView class]]) [(UIView *)tv2 removeFromSuperview];
                            if ([sc2 isKindOfClass:[UIView class]]) [(UIView *)sc2 removeFromSuperview];
                            [host setValue:nil forKey:@"pageTitleView"];
                            [host setValue:nil forKey:@"pageContentScrollView"];
                        } @catch (__unused NSException *e) {}
                        LBAppendNativeMarker(@"teardownEmptyChrome afterConsReset");
                    }
                }
            } @catch (NSException *ex) {
                LBAppendNativeMarker([NSString stringWithFormat:@"createCons EX %@", ex.reason ?: @""]);
            }
        } else if (hasPageChrome && sNativeChromeBuilt) {
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
