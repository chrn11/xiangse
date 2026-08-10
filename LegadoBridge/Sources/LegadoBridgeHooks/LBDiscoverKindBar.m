#import "LBInternal.h"
#import "LegadoBridge.h"
#import "LBNativeExploreModelBuilder.h"
#import "LBXBSModelHandoff.h"
#import <objc/runtime.h>

/// 发现页：香色原生 SGPageTitleView + BookListCon 子页；禁止 Bridge overlay 标签栏/表（tag LBKB/LBPV）。

static const NSInteger kLBKindBarTag = 0x4C424B42; // 'LBKB' — 仅用于清除历史 overlay
static const NSInteger kLBOverlayTVTag = 0x4C425056; // 'LBPV' — 仅用于清除历史 overlay
static NSInteger sSelectedKindIndex = 0;
static NSArray *sCachedKinds = nil;
static NSString *sLastFeedSig = nil;
static CFAbsoluteTime sLastFeedAt = 0;
static CFAbsoluteTime sLastRevealAt = 0;
static NSString *sLastRevealSig = nil;
static NSInteger sLastRevealArrN = -1;
static BOOL sNativeChromeBuilt = NO;
static BOOL sNativeChromeBuildScheduled = NO;
static BOOL sRestoreListMode = NO;
static BOOL sTitleOnlyStabilized = NO;
static BOOL sBookListSafeVDLInstalled = NO;
/// T2：XBS 切源/donor 重建后允许补一次原生表软刷（禁止再叠 Legado overlay）
static BOOL sXBSPendingNativeRefresh = NO;
static void (*sOrig_bookListViewDidLoad)(id, SEL) = NULL;

static void (*sOrig_pageTitleSelected)(id, SEL, id, NSInteger) = NULL;
static void (*sOrig_onSwitchBtn)(id, SEL) = NULL;
static void (*sOrig_onSwitchBtnArg)(id, SEL, id) = NULL;
static void (*sOrig_onHeaderBtn)(id, SEL, id) = NULL;
static void (*sOrig_openConfigByName)(id, SEL, NSString *) = NULL;
static void (*sOrig_setDicModel)(id, SEL, id) = NULL;
static NSString *(*sOrig_getUseSourceName)(id, SEL) = NULL;
static NSString *sDiscoverUseSourceName = nil;
static NSString *sLastHandledSwitchName = nil;
static NSInteger sSwitchPollGeneration = 0;
static BOOL sFeedingDiscoverHeader = NO;
static BOOL sApplyingKinds = NO; // ForceTitles/ApplyKinds 期间禁 explore，防连环 clear
static BOOL sDiscoverNativeXBSMode = YES; // fail-open：默认纯原生，避免进发现先毁壳
static BOOL sHandlingDiscoverSwitch = NO; // 防止 openConfig ↔ Handle 重入
/// 分类栏收起状态：阅读书源 kinds≤1（单 URL exploreUrl）时对齐阅读——不显示分类栏
static BOOL sDiscoverTitleBarCollapsed = NO;
static CGFloat sDiscoverTitleBarOrigH = 0;

BOOL LBIsDiscoverNativeXBSMode(void) {
    return sDiscoverNativeXBSMode;
}

void LBSetDiscoverNativeXBSMode(BOOL on) {
    sDiscoverNativeXBSMode = on ? YES : NO;
}

/// 去掉切换列表里的「📄 」等装饰前缀，便于跟书源真名对齐
static NSString *LBNormalizeSourceDisplayName(NSString *name) {
    if (name.length == 0) return name;
    NSString *s = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while (s.length > 0) {
        unichar c = [s characterAtIndex:0];
        // 📄=0x1F4C4 在 UTF-16 是代理对；也剥普通装饰符
        if (c == 0xFE0F || c == 0x200D || c == '#' || c == '*' || c == ' ') {
            s = [s substringFromIndex:1];
            continue;
        }
        if ([[NSCharacterSet alphanumericCharacterSet] characterIsMember:c] ||
            (c >= 0x4E00 && c <= 0x9FFF) ||
            (c >= 0x3400 && c <= 0x4DBF)) {
            break;
        }
        // 其它符号/emoji 前缀（含高位代理）剥掉
        if (CFStringIsSurrogateHighCharacter(c) && s.length >= 2) {
            s = [s substringFromIndex:2];
            continue;
        }
        s = [s substringFromIndex:1];
    }
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static void LBPaintTitleLabels(id tv, NSInteger selectedIndex);
static void LBRestoreDiscoverTitleSelected(id pageTitleView, NSInteger index);
static void LBDiscoverHandleKindSelect(UIViewController *host, id pageTitleView, NSInteger index);
static void LBAttachDiscoverKindButtonActions(UIViewController *host, id titleView);
static void LBUnlinkDiscoverTitleContent(UIViewController *host);
static NSString *LBCurrentExploreSourceUrl(id core);
static void LBTriggerExploreKind(NSString *sourceUrl, NSString *kindUrl);
static BOOL LBBindLegadoSelection(id core, NSString *url, NSString *name,
                                  UIViewController *host, NSString *nodeUrl);
static void LBDiscoverFireExploreForIndex(NSInteger index, NSString *titleHint);
static NSArray *LBDonorTitlesFromHost(UIViewController *host, NSDictionary *prepared);
static void LBForceLegadoTitlesOnChrome(UIViewController *host, NSArray *titles);
static void LBApplyLegadoSourceKindsToChrome(UIViewController *host, NSArray *kinds, NSString *srcName);
static NSInteger LBPreferredExploreKindIndex(NSArray *kinds);
static void LBHandleDiscoverSourceSwitched(UIViewController *host, NSString *sourceName);
static NSString *LBReadHostSourceName(UIViewController *host);
static NSString *LBNameFromDicModel(id model);
static NSString *LBFindLegadoExploreUrlByName(NSString *name);
static BOOL LBInvokeOpenConfigByName(id host, NSString *cfgName);
static NSDictionary *LBBuildLegadoAdapterModelFromCore(NSString *srcName);
static NSDictionary *LBHostDicModelFromLegadoAdapter(NSDictionary *adapter);
static BOOL LBWriteLegadoAdapterToHost(UIViewController *host, NSDictionary *adapter);
static BOOL LBPerformSafeXBSHandoff(UIViewController *host, NSString *exactManagerKey);
static BOOL LBRestoreNativeXBSChrome(UIViewController *host, NSString *sourceName);
static void LBSetDiscoverTitleBarCollapsed(id titleView, BOOL collapsed);
static UITableView *LBFindBestDiscoverTable(UIViewController *host, UIViewController **outOwner);
static void LBRepairDiscoverTableFrame(UIViewController *host, UIViewController *listVC, UITableView *tv);
static void LBRevealDiscoverTitleAndList(UIViewController *host);
static void LBRevealDiscoverTitleAndListEx(UIViewController *host, BOOL force);
static void LBInstallTitleKindTap(UIViewController *host, UIView *titleRoot);
static void LBRefreshDiscoverKindBarEx(BOOL force);
static void LBRefreshDiscoverKindBarForced(void);

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

/// 清除历史 Bridge overlay（标签栏 / 表 / 分类 hit / feed 叠表）
void LBRemoveDiscoverOverlays(UIViewController *host) {
    if (!host.isViewLoaded || !host.view) return;
    static const NSInteger kLBKindHit = 0x4C424B48; // 'LBKH'
    static const NSInteger kLBFO = 0x4C42464F; // 'LBFO'
    NSMutableArray *remove = [NSMutableArray array];
    for (UIView *sub in host.view.subviews) {
        if (sub.tag == kLBKindBarTag || sub.tag == kLBOverlayTVTag ||
            sub.tag == kLBKindHit || sub.tag == kLBFO) {
            [remove addObject:sub];
        }
    }
    for (UIView *v in remove) [v removeFromSuperview];
    UIWindow *win = host.view.window;
    if (win) {
        NSMutableArray *winJunk = [NSMutableArray array];
        for (UIView *sub in win.subviews) {
            if (sub.tag == kLBKindHit) [winJunk addObject:sub];
        }
        for (UIView *v in winJunk) [v removeFromSuperview];
    }
    // 切回 XBS 时恢复原生翻页层交互（Legado 叠表期间曾关掉）
    id scroll = nil;
    @try { scroll = [host valueForKey:@"pageContentScrollView"]; } @catch (__unused NSException *e) {}
    if ([scroll isKindOfClass:[UIView class]]) {
        ((UIView *)scroll).userInteractionEnabled = YES;
    }
}

/// 发现态：Legado 分类只换数据，固定灌第一个 BookListCon；纯 XBS 必须多页原生翻页
static BOOL LBDiscoverSingleListFeed(void) {
    if (LBIsDiscoverNativeXBSMode()) return NO;
    return YES;
}

static BOOL LBSelfLooksDiscoverWorldHost(id self) {
    NSString *cn = NSStringFromClass([self class]);
    if (cn.length == 0) return NO;
    return [cn containsString:@"BookWorld"] || [cn containsString:@"BookStore"] ||
           [cn containsString:@"Shudan"];
}

/// 内容区钉在第一页，避免滑到空兄弟页；标题选中态另行恢复
void LBPinDiscoverContentToFirstPage(UIViewController *host) {
    if (!host) return;
    if (LBIsDiscoverNativeXBSMode()) return;
    id scroll = nil;
    @try { scroll = [host valueForKey:@"pageContentScrollView"]; } @catch (__unused NSException *e) {}
    if (!scroll) return;

    for (NSString *selName in @[@"setPageContentWithIndex:", @"setSelectedIndex:",
                                @"scrollToIndex:", @"setCurrentIndex:", @"changeToIndex:"]) {
        SEL s = NSSelectorFromString(selName);
        if (![scroll respondsToSelector:s]) continue;
        @try {
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(scroll, s, 0);
        } @catch (__unused NSException *e) {}
    }
    @try { [scroll setValue:@0 forKey:@"selectedIndex"]; } @catch (__unused NSException *e) {}
    @try { [scroll setValue:@0 forKey:@"currentIndex"]; } @catch (__unused NSException *e) {}

    NSArray *kids = nil;
    @try {
        id cv = [scroll valueForKey:@"childViewControllers"];
        if ([cv isKindOfClass:[NSArray class]]) kids = cv;
        if (kids.count == 0) {
            cv = [scroll valueForKey:@"childVCs"];
            if ([cv isKindOfClass:[NSArray class]]) kids = cv;
        }
    } @catch (__unused NSException *e) {}
    for (NSUInteger i = 0; i < kids.count; i++) {
        id c = kids[i];
        UIViewController *vc = [c isKindOfClass:[UIViewController class]] ? (UIViewController *)c : nil;
        if (!vc) continue;
        @try {
            if (vc.isViewLoaded && vc.view) {
                vc.view.hidden = (i != 0);
                vc.view.alpha = (i == 0) ? 1.0 : 0.0;
                if (i == 0 && vc.view.superview) {
                    [vc.view.superview bringSubviewToFront:vc.view];
                    // 只纠正原点到可见页，保留 SG 给出的尺寸，避免盖住分类条
                    CGRect sb = vc.view.superview.bounds;
                    if (sb.size.width > 2 && sb.size.height > 2) {
                        CGRect f = vc.view.frame;
                        f.origin = CGPointZero;
                        if (f.size.width < 2) f.size.width = sb.size.width;
                        if (f.size.height < 2) f.size.height = sb.size.height;
                        vc.view.frame = f;
                    }
                }
            }
        } @catch (__unused NSException *e) {}
    }

    // 只钉住横向翻页容器；禁止误伤内部 UITableView/UICollectionView（否则列表拖不动）
    void (^pinPageSV)(UIScrollView *) = ^(UIScrollView *sv) {
        if (!sv) return;
        if ([sv isKindOfClass:[UITableView class]] ||
            [sv isKindOfClass:[UICollectionView class]]) {
            return;
        }
        @try {
            sv.scrollEnabled = NO;
            sv.pagingEnabled = NO;
            [sv setContentOffset:CGPointMake(0, sv.contentOffset.y) animated:NO];
        } @catch (__unused NSException *e) {}
    };
    if ([scroll isKindOfClass:[UIScrollView class]]) {
        pinPageSV((UIScrollView *)scroll);
        UIScrollView *sv = (UIScrollView *)scroll;
        @try {
            CGSize cs = sv.contentSize;
            if (cs.width < sv.bounds.size.width) {
                cs.width = sv.bounds.size.width;
                sv.contentSize = cs;
            }
        } @catch (__unused NSException *e) {}
    } else if ([scroll isKindOfClass:[UIView class]]) {
        NSMutableArray *stack = [NSMutableArray arrayWithObject:(UIView *)scroll];
        NSInteger budget = 40;
        while (stack.count && budget-- > 0) {
            UIView *v = stack.lastObject;
            [stack removeLastObject];
            if ([v isKindOfClass:[UIScrollView class]]) pinPageSV((UIScrollView *)v);
            for (UIView *sub in v.subviews) [stack addObject:sub];
        }
    }
    // 首子页强制铺满 scroll，避免只看到宿主黑底
    if (kids.count > 0) {
        id c0 = kids[0];
        UIViewController *vc0 = [c0 isKindOfClass:[UIViewController class]] ? c0 : nil;
        if (vc0 && vc0.isViewLoaded && vc0.view && [scroll isKindOfClass:[UIView class]]) {
            UIView *sv = (UIView *)scroll;
            CGRect b = sv.bounds;
            if (b.size.width > 2 && b.size.height > 2) {
                vc0.view.frame = CGRectMake(0, 0, b.size.width, b.size.height);
                vc0.view.hidden = NO;
                vc0.view.alpha = 1;
                [sv bringSubviewToFront:vc0.view];
            }
        }
    }
}

static void LBRestoreDiscoverTitleSelected(id pageTitleView, NSInteger index) {
    if (!pageTitleView || index < 0) return;
    // 只改选中态/文字色，不调 setSelectedIndex:（会联动 content 翻到空页）
    @try { [pageTitleView setValue:@(index) forKey:@"selectedIndex"]; } @catch (__unused NSException *e) {}
    LBPaintTitleLabels(pageTitleView, index);
}

static const NSInteger kLBKindBtnTagBase = 0x4C424B00; // legacy；勿再写 btn.tag（SG 用 tag 当 index）
static char kLBKindBtnIndexKey;
static BOOL sHandlingKindSelect = NO;

/// 从 donor / dicModel 取顶栏大类标题（男生/女频/出版），禁止用 Legado kinds
static NSArray *LBDonorTitlesFromHost(UIViewController *host, NSDictionary *prepared) {
    NSArray *donorTitles = nil;
    NSDictionary *dm = prepared;
    if (![dm isKindOfClass:[NSDictionary class]] && host) {
        @try {
            id v = [host valueForKey:@"dicModel"];
            if ([v isKindOfClass:[NSDictionary class]]) dm = v;
        } @catch (__unused NSException *e) {}
    }
    if ([dm isKindOfClass:[NSDictionary class]]) {
        id hdr = dm[@"arrHeaderBtnTitle"];
        if ([hdr isKindOfClass:[NSArray class]] && [(NSArray *)hdr count] > 0) {
            donorTitles = hdr;
        } else {
            id bw = dm[@"bookWorld"];
            if ([bw isKindOfClass:[NSDictionary class]]) donorTitles = [(NSDictionary *)bw allKeys];
        }
    }
    if (donorTitles.count == 0 && host) {
        @try {
            id hdr = [host valueForKey:@"arrHeaderBtnTitle"];
            if ([hdr isKindOfClass:[NSArray class]] && [(NSArray *)hdr count] > 0 &&
                [(NSArray *)hdr count] <= 8) {
                // 仅在短列表时采用（避免误吃旧的 13 类 Legado 标题）
                donorTitles = hdr;
            }
        } @catch (__unused NSException *e) {}
    }
    return donorTitles ?: @[];
}

/// 按大类 index / 标签名匹配 Legado explore kind URL
static NSString *LBResolveExploreKindUrl(NSInteger index, NSString *titleHint) {
    NSArray *kinds = sCachedKinds ?: @[];
    if (kinds.count == 0) {
        id core = LBKindCore();
        NSString *src = core ? LBCurrentExploreSourceUrl(core) : nil;
        if (core && src.length > 0 &&
            [core respondsToSelector:@selector(exploreKindsJSONForSourceUrl:)]) {
            NSString *kindsJSON = ((NSString *(*)(id, SEL, NSString *))objc_msgSend)(
                core, @selector(exploreKindsJSONForSourceUrl:), src);
            kinds = LBParseJSONArray(kindsJSON);
            if (kinds.count > 0) sCachedKinds = [kinds copy];
        }
    }
    if (kinds.count == 0) return nil;

    if (titleHint.length > 0) {
        for (id item in kinds) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            NSString *t = item[@"title"];
            if (![t isKindOfClass:[NSString class]]) continue;
            if ([t isEqualToString:titleHint] ||
                [t containsString:titleHint] ||
                [titleHint containsString:t]) {
                id u = item[@"url"];
                if ([u isKindOfClass:[NSString class]] && [(NSString *)u length] > 0) return u;
            }
        }
    }
    NSInteger idx = index;
    if (idx < 0) idx = sSelectedKindIndex;
    if (idx < 0) idx = 0;
    if (idx >= (NSInteger)kinds.count) idx = idx % (NSInteger)kinds.count;
    // 跳过空 URL 项（部分源 JSON kinds 会有 title 无 url）
    for (NSInteger step = 0; step < (NSInteger)kinds.count; step++) {
        NSInteger i = (idx + step) % (NSInteger)kinds.count;
        id u = kinds[(NSUInteger)i][@"url"];
        if ([u isKindOfClass:[NSString class]] && [(NSString *)u length] > 0) return u;
    }
    return nil;
}

static void LBDiscoverFireExploreForIndex(NSInteger index, NSString *titleHint) {
    if (LBIsDiscoverNativeXBSMode()) {
        LBAppendNativeMarker(@"nativeExplore skip XBS");
        return;
    }
    if (sApplyingKinds || sFeedingDiscoverHeader) {
        LBAppendNativeMarker(@"nativeExplore skip: applyingKinds");
        return;
    }
    id core = LBKindCore();
    NSString *src = core ? LBCurrentExploreSourceUrl(core) : nil;
    NSString *url = LBResolveExploreKindUrl(index, titleHint) ?: @"";
    LBAppendNativeMarker([NSString stringWithFormat:
                          @"nativeExplore idx=%ld title=%@ kind=%@ src=%@",
                          (long)index, titleHint ?: @"-",
                          url.length ? url : @"-", src ?: @"-"]);
    if (src.length == 0) {
        LBAppendNativeMarker(@"nativeExplore skip: no src");
        return;
    }
    // kinds 未就绪或该项无 URL：禁止 explore(nil)（会再跑顶层 JS，失败就盖「JS 未产出分类」）
    if (url.length == 0) {
        LBAppendNativeMarker(@"nativeExplore skip: empty kindUrl → warmup");
        BOOL coolFail = NO;
        if (core && [core respondsToSelector:@selector(isExploreKindsWarmFailedRecentlyForSourceUrl:)]) {
            coolFail = ((BOOL (*)(id, SEL, NSString *))objc_msgSend)(
                core, @selector(isExploreKindsWarmFailedRecentlyForSourceUrl:), src);
        }
        if (coolFail) {
            LBAppendNativeMarker(@"nativeExplore skip: warmFail cooling keepFailHint");
            return;
        }
        if (core && [core respondsToSelector:@selector(warmupExploreKindsForSourceUrl:)]) {
            ((void (*)(id, SEL, NSString *))objc_msgSend)(
                core, @selector(warmupExploreKindsForSourceUrl:), src);
        }
        LBShowDiscoverExploreEmptyHint(@"分类加载中，请稍后…");
        return;
    }
    @try {
        LBTriggerExploreKind(src, url);
    } @catch (NSException *ex) {
        LBAppendNativeMarker([NSString stringWithFormat:@"nativeExplore EX %@",
                              ex.reason ?: @""]);
    }
}

/// 分类切换：原生多页翻页后，按 index 触发 explore（不再钉死第一页）
static void LBDiscoverHandleKindSelect(UIViewController *host, id pageTitleView, NSInteger index) {
    if (LBIsDiscoverNativeXBSMode()) {
        LBAppendNativeMarker([NSString stringWithFormat:@"nativeTab skip XBS idx=%ld", (long)index]);
        return;
    }
    if (sHandlingKindSelect) return;
    // SG 若仍用被污染的 btn.tag 回调，会传来 0x4C424Bxx；直接丢弃
    // 书山等源 kinds 可达数百；原 64 上限会丢弃合法点击
    if (index < 0 || index > 512) {
        LBAppendNativeMarker([NSString stringWithFormat:@"nativeTab drop badIdx=%ld", (long)index]);
        return;
    }
    sHandlingKindSelect = YES;
    @try {
        LBSetDiscoverTabActive(YES);
        sSelectedKindIndex = MAX(0, index);
        if (!host) host = LBPrimaryDiscoverHost();

        // 多页模式：交给原生 pageTitle 回调翻页；此处只 fire explore
        if (LBDiscoverSingleListFeed()) {
            LBPinDiscoverContentToFirstPage(host);
            id tv = pageTitleView;
            if (!tv && host) {
                @try { tv = [host valueForKey:@"pageTitleView"]; } @catch (__unused NSException *e) {}
            }
            LBRestoreDiscoverTitleSelected(tv, sSelectedKindIndex);
            LBPinDiscoverContentToFirstPage(host);
        }

        LBDiscoverFireExploreForIndex(index, nil);

        if (host) {
            __weak UIViewController *weakHost = host;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                UIViewController *h = weakHost;
                if (!h || !LBIsDiscoverTabActive()) return;
                if (LBDiscoverSingleListFeed()) LBPinDiscoverContentToFirstPage(h);
                LBReloadDiscoverNativeList(h);
            });
        }
    } @finally {
        sHandlingKindSelect = NO;
    }
}

static void LBDiscover_kindBtnTouch(id self, SEL _cmd, id sender) {
    (void)_cmd;
    NSInteger idx = 0;
    NSNumber *stored = nil;
    @try { stored = objc_getAssociatedObject(sender, &kLBKindBtnIndexKey); } @catch (__unused NSException *e) {}
    if ([stored isKindOfClass:[NSNumber class]]) {
        idx = [stored integerValue];
    } else if ([sender isKindOfClass:[UIView class]]) {
        // 兼容旧包：若仍写过 tag，把 base 映射回 index
        NSInteger tag = [(UIView *)sender tag];
        if (tag >= kLBKindBtnTagBase && tag < kLBKindBtnTagBase + 64) {
            idx = tag - kLBKindBtnTagBase;
        } else if (tag >= 0 && tag < 64) {
            idx = tag;
        }
    }
    UIViewController *host = [self isKindOfClass:[UIViewController class]]
        ? (UIViewController *)self : LBPrimaryDiscoverHost();
    LBAppendNativeMarker([NSString stringWithFormat:@"kindBtnTouch idx=%ld", (long)idx]);
    LBDiscoverHandleKindSelect(host, nil, idx);
}

static void LBEnsureDiscoverKindBtnMethod(Class cls) {
    if (!cls) return;
    SEL sel = @selector(lb_discoverKindBtn:);
    if (class_getInstanceMethod(cls, sel)) return;
    class_addMethod(cls, sel, (IMP)LBDiscover_kindBtnTouch, "v@:@");
}

/// 断开标题条与内容滚动联动，避免选分类时翻到不存在的空页（仅 Legado 单列表灌书）
static void LBUnlinkDiscoverTitleContent(UIViewController *host) {
    if (!host) return;
    if (LBIsDiscoverNativeXBSMode()) {
        LBAppendNativeMarker(@"unlink skip XBS");
        return;
    }
    id tv = nil;
    id scroll = nil;
    @try { tv = [host valueForKey:@"pageTitleView"]; } @catch (__unused NSException *e) {}
    @try { scroll = [host valueForKey:@"pageContentScrollView"]; } @catch (__unused NSException *e) {}
    if (tv) {
        for (NSString *k in @[@"pageContentScrollView", @"contentView", @"pageContentView",
                              @"delegatePageContentScrollView"]) {
            @try { [tv setValue:nil forKey:k]; } @catch (__unused NSException *e) {}
        }
    }
    if (scroll) {
        for (NSString *k in @[@"pageTitleView", @"delegatePageTitleView", @"titleView"]) {
            @try { [scroll setValue:nil forKey:k]; } @catch (__unused NSException *e) {}
        }
    }
    LBPinDiscoverContentToFirstPage(host);
    LBAppendNativeMarker(@"unlink title↔content for singleFeed");
}

static void LBAttachDiscoverKindButtonActions(UIViewController *host, id titleView) {
    if (!host || ![titleView isKindOfClass:[UIView class]]) return;
    // 纯 XBS：禁止改按钮 target / unlink / hit overlay，交给原生 SGPage
    if (LBIsDiscoverNativeXBSMode()) {
        LBAppendNativeMarker(@"kindBtnAttach skip XBS");
        return;
    }
    LBEnsureDiscoverKindBtnMethod([host class]);
    SEL sel = @selector(lb_discoverKindBtn:);
    UIView *root = (UIView *)titleView;
    static const NSInteger kLBKindSoftScroll = 0x4C424B53; // 'LBKS'
    UIScrollView *softScroll = nil;
    for (UIView *sub in root.subviews) {
        if (sub.tag == kLBKindSoftScroll && [sub isKindOfClass:[UIScrollView class]] && !sub.hidden) {
            softScroll = (UIScrollView *)sub;
            break;
        }
    }
    // softScroll 自建按钮已带正确 index；禁止 hit overlay 挡点击，也不要按 donor 按钮重编号
    if (softScroll) {
        static const NSInteger kLBKindHit = 0x4C424B48; // 'LBKH'
        UIWindow *win = host.view.window;
        UIView *container = win ?: host.view;
        NSMutableArray *junk = [NSMutableArray array];
        for (UIView *sub in container.subviews) {
            if (sub.tag == kLBKindHit) [junk addObject:sub];
        }
        for (UIView *sub in host.view.subviews) {
            if (sub.tag == kLBKindHit) [junk addObject:sub];
        }
        for (UIView *v in junk) [v removeFromSuperview];
        [root bringSubviewToFront:softScroll];
        if (!sApplyingKinds) {
            LBUnlinkDiscoverTitleContent(host);
        }
        LBAppendNativeMarker([NSString stringWithFormat:@"kindBtnAttach softScroll n=%lu",
                              (unsigned long)softScroll.subviews.count]);
        return;
    }
    NSMutableArray<UIButton *> *btns = [NSMutableArray array];
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if (v.tag == kLBKindSoftScroll) continue; // 勿把自建条算进 donor
        if ([v isKindOfClass:[UIButton class]]) [btns addObject:(UIButton *)v];
        for (UIView *sub in v.subviews) [stack addObject:sub];
    }
    NSArray<UIButton *> *sorted = [btns sortedArrayUsingComparator:^NSComparisonResult(UIButton *a, UIButton *b) {
        return a.frame.origin.x < b.frame.origin.x ? NSOrderedAscending : NSOrderedDescending;
    }];
    NSUInteger n = 0;
    for (UIButton *btn in sorted) {
        // 禁止改 btn.tag：SGPageTitleView 用 tag 当分类 index，改掉会回调出 0x4C424Bxx
        objc_setAssociatedObject(btn, &kLBKindBtnIndexKey, @(n), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (btn.tag >= kLBKindBtnTagBase) {
            // 清掉旧包残留的污染 tag
            btn.tag = (NSInteger)n;
        }
        [btn removeTarget:host action:sel forControlEvents:UIControlEventTouchUpInside];
        [btn addTarget:host action:sel forControlEvents:UIControlEventTouchUpInside];
        n++;
    }
    // ApplyKinds 时 unlink/pin 会让随后 FindBest 找不到 BookListCon
    if (!sApplyingKinds) {
        LBUnlinkDiscoverTitleContent(host);
    } else {
        LBAppendNativeMarker(@"kindBtnAttach skipUnlink during applyKinds");
    }
    LBAppendNativeMarker([NSString stringWithFormat:@"kindBtnAttach n=%lu host=%@",
                          (unsigned long)n, NSStringFromClass([host class])]);
    LBInstallTitleKindTap(host, root);
}

/// 当前用于灌书的 BookListCon；发现单页模式下永远用第一个子页
UIViewController *LBActiveDiscoverListVC(UIViewController *host) {
    if (!host) return nil;
    NSInteger idx = 0;
    if (!LBDiscoverSingleListFeed()) {
        idx = sSelectedKindIndex;
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
    }

    NSArray *children = nil;
    @try {
        id scroll = [host valueForKey:@"pageContentScrollView"];
        id cv = [scroll valueForKey:@"childViewControllers"];
        if (![cv isKindOfClass:[NSArray class]] || [(NSArray *)cv count] == 0) {
            cv = [scroll valueForKey:@"childVCs"];
        }
        if ([cv isKindOfClass:[NSArray class]] && [(NSArray *)cv count] > 0) {
            children = cv;
        }
    } @catch (__unused NSException *e) {}
    if (children.count == 0) children = host.childViewControllers;

    if (idx >= 0 && idx < (NSInteger)children.count) {
        id c = children[(NSUInteger)idx];
        if ([c isKindOfClass:[UIViewController class]]) return (UIViewController *)c;
    }
    // 单页模式：idx 越界时仍回退第一个子页
    if (children.count > 0) {
        id c0 = children.firstObject;
        if ([c0 isKindOfClass:[UIViewController class]]) return (UIViewController *)c0;
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
    UIViewController *host = LBPrimaryDiscoverHost();
    if (!LBBindLegadoSelection(core, sourceUrl, nil, host, kindUrl)) {
        LBAppendNativeMarker(@"nativeExplore reject missing exact context");
        LBShowDiscoverExploreEmptyHint(@"分类上下文尚未就绪，请稍后重试");
        return;
    }
    ((void (*)(id, SEL, NSString *, NSString *, NSInteger))objc_msgSend)(
        core,
        @selector(handleExploreRequestWithSourceUrl:exploreUrl:page:),
        sourceUrl,
        kindUrl.length ? kindUrl : nil,
        1);
}

static NSString *LBDiscoverOwnerIdentity(UIViewController *host) {
    UIViewController *list = host ? LBActiveDiscoverListVC(host) : nil;
    NSString *cls = list ? NSStringFromClass([list class]) : @"";
    if (![cls containsString:@"BookListCon"]) return nil;
    return [NSString stringWithFormat:@"%@:%p", cls, list];
}

static BOOL LBBindLegadoSelection(id core, NSString *url, NSString *name,
                                  UIViewController *host, NSString *nodeUrl) {
    NSString *owner = LBDiscoverOwnerIdentity(host);
    if (url.length == 0 || owner.length == 0 || nodeUrl.length == 0) return NO;
    NSDictionary *selected = LBSharedRouterApplySelection(2, url, name, owner, NO);
    if (![selected isKindOfClass:[NSDictionary class]]) return NO;
    SEL contextSel = @selector(exploreContextJSONForSourceUrl:nodeUrl:);
    if (!core || ![core respondsToSelector:contextSel]) return NO;
    NSString *contextJSON = ((NSString *(*)(id, SEL, NSString *, NSString *))objc_msgSend)(
        core, contextSel, url, nodeUrl);
    NSData *data = [contextJSON dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *context = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    if (![context isKindOfClass:[NSDictionary class]]) return NO;
    NSString *fp = [context[@"definitionFingerprint"] isKindOfClass:[NSString class]] ? context[@"definitionFingerprint"] : nil;
    NSString *sid = [context[@"snapshotID"] isKindOfClass:[NSString class]] ? context[@"snapshotID"] : nil;
    NSString *nid = [context[@"nodeID"] isKindOfClass:[NSString class]] ? context[@"nodeID"] : nil;
    NSNumber *epoch = [context[@"runtimeEpoch"] isKindOfClass:[NSNumber class]] ? context[@"runtimeEpoch"] : nil;
    if (fp.length == 0 || sid.length == 0 || nid.length == 0 || !epoch) return NO;
    Class routerClass = NSClassFromString(@"LBSharedSourceRouter");
    if (!routerClass) routerClass = NSClassFromString(@"LegadoBridge.LBSharedSourceRouter");
    id router = routerClass ? ((id (*)(id, SEL))objc_msgSend)(routerClass, @selector(shared)) : nil;
    SEL bindSel = @selector(bindActiveLegadoContextWithExactSourceUrl:ownerIdentity:definitionFingerprint:snapshotID:nodeID:runtimeEpoch:);
    if (!router || ![router respondsToSelector:bindSel]) return NO;
    NSDictionary *bound = ((NSDictionary *(*)(id, SEL, NSString *, NSString *, NSString *, NSString *, NSString *, unsigned long long))objc_msgSend)(
        router, bindSel, url, owner, fp, sid, nid, epoch.unsignedLongLongValue);
    return [bound[@"ok"] boolValue];
}

static void LBPresentExploreSourcePicker(UIViewController *host) {
    id core = LBKindCore();
    if (!core || ![core respondsToSelector:@selector(exploreCapableSourcesJSON)]) return;
    NSString *json = nil;
    @try { json = [core valueForKey:@"exploreCapableSourcesJSON"]; } @catch (__unused NSException *e) {}
    NSArray *rows = LBParseJSONArray(json ?: @"[]");
    if (rows.count == 0) {
        UIAlertController *empty = [UIAlertController alertControllerWithTitle:@"切换发现源"
                                                                     message:@"暂无可发现书源（需启用且含发现地址）"
                                                              preferredStyle:UIAlertControllerStyleAlert];
        [empty addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [host presentViewController:empty animated:YES completion:nil];
        return;
    }
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"切换发现源"
                                                               message:nil
                                                        preferredStyle:UIAlertControllerStyleActionSheet];
    for (id row in rows) {
        if (![row isKindOfClass:[NSDictionary class]]) continue;
        NSString *name = row[@"name"] ?: row[@"url"] ?: @"源";
        NSString *url = row[@"url"] ?: @"";
        NSNumber *typeNum = [row[@"type"] isKindOfClass:[NSNumber class]] ? row[@"type"] : nil;
        NSString *title = name;
        if (typeNum) {
            static NSString *typeNames[] = { @"文本", @"音频", @"图片", @"文件" };
            NSInteger t = typeNum.integerValue;
            if (t >= 0 && t <= 3) {
                title = [NSString stringWithFormat:@"%@（%@）", name, typeNames[t]];
            }
        }
        [ac addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
            @try { [core setValue:url forKey:@"selectedExploreSourceUrl"]; } @catch (__unused NSException *e) {}
            sSelectedKindIndex = 0;
            sLastFeedSig = nil;
            sCachedKinds = nil;
            // 保留原生壳，强制按新源 kinds 刷新分类条
            LBAppendNativeMarker([NSString stringWithFormat:@"switchSrc url=%@ name=%@", url, name]);
            LBRefreshDiscoverKindBar();
            NSString *kindsJSON = @"[]";
            if ([core respondsToSelector:@selector(exploreKindsJSONForSourceUrl:)]) {
                kindsJSON = ((NSString *(*)(id, SEL, NSString *))objc_msgSend)(
                    core, @selector(exploreKindsJSONForSourceUrl:), url);
            }
            NSArray *kinds = LBParseJSONArray(kindsJSON);
            UIViewController *h = host ?: LBPrimaryDiscoverHost();
            if (h) LBApplyLegadoSourceKindsToChrome(h, kinds, name);
            NSString *kindUrl = nil;
            if (kinds.count > 0) {
                NSInteger pref = LBPreferredExploreKindIndex(kinds);
                sSelectedKindIndex = pref;
                id u = (pref >= 0 && pref < (NSInteger)kinds.count) ? kinds[(NSUInteger)pref][@"url"] : nil;
                if ([u isKindOfClass:[NSString class]] && [(NSString *)u length] > 0) {
                    kindUrl = (NSString *)u;
                }
            }
            if (kindUrl.length > 0) {
                LBTriggerExploreKind(url, kindUrl);
            } else {
                LBAppendNativeMarker(@"switchSrc defer explore (kinds empty)");
                LBShowDiscoverExploreEmptyHint(@"分类加载中，请稍后…");
                if ([core respondsToSelector:@selector(warmupExploreKindsForSourceUrl:)]) {
                    ((void (*)(id, SEL, NSString *))objc_msgSend)(
                        core, @selector(warmupExploreKindsForSourceUrl:), url);
                }
            }
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

/// TC-08L W2：donor bookWorld 永久不可达（Release+Debug）；禁止借 XBS 污染 Legado。
/// 历史实现保留在 #if 0，仅供审计，不参与编译。

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

#if DEBUG
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
#endif

/// 仅从 BookSourceModelManager 灌回本源 dicModel（不 resetContent）。
/// 用于 sync 时 host.bookWorld 已空但 chrome 残留：点标签会「空列表」。
static BOOL LBEnsureXBSDicModelOnly(UIViewController *host, NSString *sourceName) {
#if !DEBUG
    return LBPerformSafeXBSHandoff(host, sourceName);
#else
    if (!host || sourceName.length == 0) return NO;
    NSString *want = LBNormalizeSourceDisplayName(sourceName) ?: sourceName;
    Class mgrCls = NSClassFromString(@"BookSourceModelManager");
    id mgr = nil;
    if (mgrCls && [mgrCls respondsToSelector:@selector(sharedInstance)]) {
        mgr = ((id (*)(id, SEL))objc_msgSend)(mgrCls, @selector(sharedInstance));
    }
    if (!mgr) return NO;
    id list = nil;
    @try { list = [mgr valueForKey:@"dicModelList"]; } @catch (__unused NSException *e) {}
    if (![list isKindOfClass:[NSDictionary class]]) return NO;

    __block NSDictionary *picked = nil;
    __block NSString *pickedName = nil;
    for (id key in [(NSDictionary *)list allKeys]) {
        if (![key isKindOfClass:[NSString class]]) continue;
        NSString *k = (NSString *)key;
        NSString *nk = LBNormalizeSourceDisplayName(k) ?: k;
        if ([k isEqualToString:sourceName] || [k isEqualToString:want] || [nk isEqualToString:want]) {
            id obj = ((NSDictionary *)list)[k];
            if ([obj isKindOfClass:[NSDictionary class]]) {
                picked = obj;
                pickedName = k;
                break;
            }
        }
    }
    if (!picked) {
        [(NSDictionary *)list enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
            if (![obj isKindOfClass:[NSDictionary class]]) return;
            NSDictionary *m = (NSDictionary *)obj;
            id v = m[@"cf_title"] ?: m[@"title"] ?: m[@"sourceName"];
            NSString *cf = [v isKindOfClass:[NSString class]] ? LBNormalizeSourceDisplayName(v) : nil;
            if (cf.length && ([cf isEqualToString:want] ||
                              [cf containsString:want] || [want containsString:cf])) {
                picked = m;
                pickedName = [key isKindOfClass:[NSString class]] ? (NSString *)key : want;
                *stop = YES;
            }
        }];
    }
    if (![picked isKindOfClass:[NSDictionary class]]) {
        LBAppendNativeMarker([NSString stringWithFormat:@"ensureDic miss name=%@", want]);
        return NO;
    }
    id bw = picked[@"bookWorld"];
    NSUInteger bwN = [bw isKindOfClass:[NSDictionary class]] ? [(NSDictionary *)bw count] : 0;
    if (bwN < 3) {
        LBAppendNativeMarker([NSString stringWithFormat:
                              @"ensureDic thinBW keys=%lu name=%@",
                              (unsigned long)bwN, pickedName ?: want]);
        return NO;
    }
    NSMutableDictionary *model = [picked mutableCopy];
    if (want.length > 0) model[@"cf_title"] = want;
    // 原生 setDicModel: 会丢 bookWorld（ensure 后 after=0）。优先写 ivar，避开 setter。
    BOOL prevHandling = sHandlingDiscoverSwitch;
    sHandlingDiscoverSwitch = YES;
    BOOL ok = NO;
    NSString *via = @"none";
    @try {
        Ivar iv = class_getInstanceVariable([host class], "_dicModel");
        if (!iv) iv = class_getInstanceVariable(object_getClass(host), "_dicModel");
        if (!iv) {
            unsigned int n = 0;
            Ivar *ivars = class_copyIvarList([host class], &n);
            for (unsigned int i = 0; i < n; i++) {
                const char *nm = ivar_getName(ivars[i]);
                if (nm && strstr(nm, "dicModel")) { iv = ivars[i]; break; }
            }
            if (ivars) free(ivars);
        }
        if (iv) {
            object_setIvar(host, iv, model);
            ok = YES;
            via = @"ivar";
        } else {
            @try {
                [host setValue:model forKey:@"dicModel"];
                ok = YES;
                via = @"kvc";
            } @catch (__unused NSException *e1) {
                ok = LBForceSetDicModel(host, model);
                via = @"setDic";
            }
        }
    } @finally {
        sHandlingDiscoverSwitch = prevHandling;
    }
    @try { [host setValue:(pickedName ?: want) forKey:@"useSourceName"]; } @catch (__unused NSException *e) {}
    @try { [host setValue:(pickedName ?: want) forKey:@"lastSourceName"]; } @catch (__unused NSException *e) {}
    // 回读确认 bookWorld 是否真挂上
    NSUInteger afterN = 0;
    NSUInteger afterNested = 0;
    @try {
        id dm = nil;
        @try { dm = [host valueForKey:@"dicModel"]; } @catch (__unused NSException *e) {}
        if (!dm) {
            Ivar iv2 = class_getInstanceVariable([host class], "_dicModel");
            if (iv2) dm = object_getIvar(host, iv2);
        }
        if ([dm isKindOfClass:[NSDictionary class]]) {
            id bw2 = ((NSDictionary *)dm)[@"bookWorld"];
            if ([bw2 isKindOfClass:[NSDictionary class]]) {
                afterN = [(NSDictionary *)bw2 count];
                for (id v in [(NSDictionary *)bw2 allValues]) {
                    if ([v isKindOfClass:[NSArray class]]) afterNested += [(NSArray *)v count];
                    else if ([v isKindOfClass:[NSDictionary class]]) afterNested += [(NSDictionary *)v count];
                }
            }
        }
    } @catch (__unused NSException *e) {}
    LBAppendNativeMarker([NSString stringWithFormat:
                          @"ensureDic setOnly=%d via=%@ bw=%lu after=%lu nested=%lu name=%@ noReset",
                          ok ? 1 : 0, via, (unsigned long)bwN, (unsigned long)afterN,
                          (unsigned long)afterNested, pickedName ?: want]);
    return ok && afterN >= 3;
#endif
}

/// 诊断探针:统计 bookWorld 的 key 数 + 嵌套书项数(array 元素数 / dict 项数)
static void LBProbeBookWorldNested(UIViewController *host, NSString *tag) {
    if (!host) return;
    NSUInteger bwN = 0, nestedN = 0;
    @try {
        id dm = nil;
        @try { dm = [host valueForKey:@"dicModel"]; } @catch (__unused NSException *e) {}
        if (![dm isKindOfClass:[NSDictionary class]]) return;
        id bw = ((NSDictionary *)dm)[@"bookWorld"];
        if (![bw isKindOfClass:[NSDictionary class]]) return;
        NSDictionary *bwd = (NSDictionary *)bw;
        bwN = bwd.count;
        for (id v in bwd.allValues) {
            if ([v isKindOfClass:[NSArray class]]) nestedN += [(NSArray *)v count];
            else if ([v isKindOfClass:[NSDictionary class]]) nestedN += [(NSDictionary *)v count];
        }
    } @catch (__unused NSException *e) {}
    LBAppendNativeMarker([NSString stringWithFormat:@"bwProbe %@ keys=%lu nested=%lu",
                          tag ?: @"-", (unsigned long)bwN, (unsigned long)nestedN]);
}

/// TC-07：Swift 24.6 sanitized metadata → 无状态 adapter model（禁 donor/raw target）。
static NSDictionary *LBBuildLegadoAdapterModelFromCore(NSString *srcName) {
    if (srcName.length == 0) return nil;
    id core = LBKindCore();
    if (!core) return nil;
    NSString *url = LBFindLegadoExploreUrlByName(srcName);
    if (url.length == 0) return nil;
    NSString *metaJSON = nil;
    if ([core respondsToSelector:@selector(exploreSnapshotMetadataJSONForSourceUrl:)]) {
        metaJSON = ((NSString *(*)(id, SEL, NSString *))objc_msgSend)(
            core, @selector(exploreSnapshotMetadataJSONForSourceUrl:), url);
    }
    if (metaJSON.length == 0) return nil;
    NSData *data = [metaJSON dataUsingEncoding:NSUTF8StringEncoding];
    NSError *err = nil;
    NSDictionary *model = [LBNativeExploreModelBuilder adapterModelFromMetadataJSON:data error:&err];
    if (err || model.count == 0) return nil;
    return model;
}

/// adapter DTO → 宿主最小 dicModel：bookWorld 仅结构常量（无 requestInfo/list）。
static NSDictionary *LBHostDicModelFromLegadoAdapter(NSDictionary *adapter) {
    if (![adapter isKindOfClass:[NSDictionary class]] || adapter.count == 0) return nil;
    if (![LBNativeExploreModelBuilder validateAdapterModel:adapter error:nil]) return nil;
    NSArray *channels = [adapter[@"channels"] isKindOfClass:[NSArray class]] ? adapter[@"channels"] : @[];
    NSMutableDictionary *bookWorld = [NSMutableDictionary dictionaryWithCapacity:channels.count];
    NSMutableArray *headerTitles = [NSMutableArray arrayWithCapacity:channels.count];
    for (id chObj in channels) {
        if (![chObj isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *ch = (NSDictionary *)chObj;
        NSString *title = [ch[@"title"] isKindOfClass:[NSString class]] ? ch[@"title"] : @"";
        if (title.length == 0) continue;
        [headerTitles addObject:title];
        bookWorld[title] = @{
            @"actionID": LBNativeExploreStructureActionID,
            @"parserID": LBNativeExploreStructureParserID,
            @"_lb_channelID": ([ch[@"channelID"] isKindOfClass:[NSString class]] ? ch[@"channelID"] : @""),
            @"_lb_tagTitles": ([ch[@"tagTitles"] isKindOfClass:[NSArray class]] ? ch[@"tagTitles"] : @[]),
            @"_lb_tagNodeIDs": ([ch[@"tagNodeIDs"] isKindOfClass:[NSArray class]] ? ch[@"tagNodeIDs"] : @[]),
        };
    }
    NSMutableDictionary *hostModel = [NSMutableDictionary dictionaryWithDictionary:adapter];
    hostModel[@"bookWorld"] = [bookWorld copy];
    hostModel[@"_lb_arrHeaderBtnTitle"] = [headerTitles copy];
    return [hostModel copy];
}

/// TC-07：仅 ivar 写入 adapter 宿主模型；禁止 setDicModel:/KVC（Release gate）。
static BOOL LBWriteLegadoAdapterToHost(UIViewController *host, NSDictionary *adapter) {
    if (!host || ![adapter isKindOfClass:[NSDictionary class]] || adapter.count == 0) return NO;
    NSDictionary *hostModel = LBHostDicModelFromLegadoAdapter(adapter);
    if (!hostModel) return NO;
    Class cls = object_getClass(host);
    Ivar iv = NULL;
    while (cls && cls != [NSObject class]) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *name = ivar_getName(ivars[i]);
            if (name && strcmp(name, "_dicModel") == 0) {
                iv = ivars[i];
                break;
            }
        }
        if (ivars) free(ivars);
        if (iv) break;
        cls = class_getSuperclass(cls);
    }
    if (!iv) {
        LBAppendNativeMarker(@"legadoAdapterWrite missIvar=_dicModel");
        return NO;
    }
    id previous = object_getIvar(host, iv);
    NSDictionary *copy = [[NSDictionary alloc] initWithDictionary:hostModel copyItems:YES];
    object_setIvar(host, iv, copy);
    id readBack = object_getIvar(host, iv);
    BOOL ok = [readBack isKindOfClass:[NSDictionary class]] &&
              [((NSDictionary *)readBack)[LBNativeExploreAdapterMarkerKey] respondsToSelector:@selector(boolValue)] &&
              [((NSDictionary *)readBack)[LBNativeExploreAdapterMarkerKey] boolValue] &&
              [((NSDictionary *)readBack)[@"bookWorld"] isKindOfClass:[NSDictionary class]];
    if (!ok) {
        object_setIvar(host, iv, previous);
        LBAppendNativeMarker(@"legadoAdapterWrite readbackFail restored");
        return NO;
    }
    NSArray *headers = hostModel[@"_lb_arrHeaderBtnTitle"];
    if ([headers isKindOfClass:[NSArray class]] && headers.count > 0) {
        @try { [host setValue:[headers copy] forKey:@"arrHeaderBtnTitle"]; } @catch (__unused NSException *e) {}
    }
    LBAppendNativeMarker([NSString stringWithFormat:@"legadoAdapterWrite ok bw=%lu",
                          (unsigned long)[((NSDictionary *)hostModel[@"bookWorld"]) count]]);
    return YES;
}

/// TC-08：manager 同源完整模型 → host `_dicModel` ivar；禁 donor/setter/KVC/reset/createCons。
static BOOL LBPerformSafeXBSHandoff(UIViewController *host, NSString *exactManagerKey) {
    return LBXBSHandoffEnsureFromExactManagerKey(host, exactManagerKey);
}

/// TC-08L：XBS chrome 恢复仅 exact-manager safe handoff；donor/setDic/persist 永久移除。
static BOOL LBRestoreNativeXBSChrome(UIViewController *host, NSString *sourceName) {
    return LBPerformSafeXBSHandoff(host, sourceName);
}


/// TC-08L：expand-donor 永久禁用；原样返回（调用方亦应不可达）。

/// TC-08L W2：禁止 donor 打开发现配置；永久返回 nil（Release+Debug）。

/// 发现态：优先走原生 viewDidLoad（才能出标签墙）；崩了再退回空表兜底
static void LBBookList_safeViewDidLoad(id self, SEL _cmd) {
    BOOL discover = LBIsDiscoverTabActive() || sFeedingDiscoverHeader || sBookListSafeVDLInstalled;
    if (!discover) {
        if (sOrig_bookListViewDidLoad) {
            sOrig_bookListViewDidLoad(self, _cmd);
        }
        return;
    }

    // 纯 XBS：只调原生 VDL，禁止 fallback 清空 arrBaseData（会变成永久空列表）
    // SyncMode 可能晚于子页 VDL：同时看 ShouldUseNativeXBS / 宿主源名
    BOOL xbsNow = LBIsDiscoverNativeXBSMode() || LBDiscoverShouldUseNativeXBS();
    if (!xbsNow) {
        UIViewController *host0 = LBPrimaryDiscoverHost();
        NSString *hn = LBReadHostSourceName(host0);
        NSString *hnN = LBNormalizeSourceDisplayName(hn) ?: hn;
        if (hnN.length > 0 && !LBLegadoIsSourceName(hnN)) xbsNow = YES;
    }
    if (xbsNow) {
        if (sOrig_bookListViewDidLoad) {
            @try {
                sOrig_bookListViewDidLoad(self, _cmd);
                static NSInteger sNativeVDLXBS = 0;
                if (sNativeVDLXBS < 3) {
                    LBAppendNativeMarker([NSString stringWithFormat:
                                          @"BookListCon nativeViewDidLoad XBS #%ld",
                                          (long)sNativeVDLXBS]);
                    sNativeVDLXBS++;
                }
            } @catch (NSException *ex) {
                LBAppendNativeMarker([NSString stringWithFormat:
                                      @"BookListCon nativeVDL XBS EX %@ (no clear)",
                                      ex.reason ?: @""]);
            }
        }
        return;
    }

    // 先试原生 VDL（donor bookWorld 完整时能出二级标签网格）
    if (sOrig_bookListViewDidLoad) {
        @try {
            sOrig_bookListViewDidLoad(self, _cmd);
            static NSInteger sNativeVDLCount = 0;
            if (sNativeVDLCount < 3) {
                LBAppendNativeMarker([NSString stringWithFormat:@"BookListCon nativeViewDidLoad #%ld",
                                      (long)sNativeVDLCount]);
                sNativeVDLCount++;
            }
            return;
        } @catch (NSException *ex) {
            LBAppendNativeMarker([NSString stringWithFormat:@"BookListCon nativeVDL EX %@",
                                  ex.reason ?: @""]);
        }
    }

    // 兜底：只调 UIViewController 的 viewDidLoad；禁止再造铺满 table（会盖住原生黑底）
    Method uiM = class_getInstanceMethod([UIViewController class], @selector(viewDidLoad));
    if (uiM) {
        ((void (*)(id, SEL))method_getImplementation(uiM))(self, _cmd);
    }

    UIViewController *vc = (UIViewController *)self;
    UIView *view = nil;
    @try { view = vc.view; } @catch (__unused NSException *e) {}
    if (view) {
        view.backgroundColor = [UIColor blackColor];
    }

    for (NSString *k in @[@"arrBaseData", @"itemList", @"arrData", @"dataArray", @"books"]) {
        @try { [vc setValue:@[] forKey:k]; } @catch (__unused NSException *e) {}
    }

    // 若原生已有 table 就只 reload；没有也不新建
    UITableView *tv = nil;
    @try {
        id v = [vc valueForKey:@"tableView"];
        if ([v isKindOfClass:[UITableView class]]) tv = (UITableView *)v;
    } @catch (__unused NSException *e) {}
    if (tv) {
        @try { [tv reloadData]; } @catch (__unused NSException *e) {}
    }

    static NSInteger sSafeVDLCount = 0;
    if (sSafeVDLCount < 3) {
        LBAppendNativeMarker([NSString stringWithFormat:@"BookListCon safeViewDidLoad fallback-noCreate #%ld",
                              (long)sSafeVDLCount]);
        sSafeVDLCount++;
    }
}

static void LBInstallBookListSafeViewDidLoad(void) {
    if (sBookListSafeVDLInstalled) return;
    Class cls = NSClassFromString(@"BookListCon");
    if (!cls) return;
    SEL sel = @selector(viewDidLoad);
    Class owner = LBClassOwningInstanceMethod(cls, sel) ?: cls;
    Method m = class_getInstanceMethod(owner, sel);
    if (!m) return;
    if (!sOrig_bookListViewDidLoad) {
        sOrig_bookListViewDidLoad = (void (*)(id, SEL))method_getImplementation(m);
    }
    method_setImplementation(m, (IMP)LBBookList_safeViewDidLoad);
    sBookListSafeVDLInstalled = YES;
    LBAppendNativeMarker(@"BookListCon safeViewDidLoad hooked");
}

/// donor configure 的 titleColor 多为白色（原生深色页），发现页白底会导致白字不可见。
/// 优先保留宿主 configure；仅当字色过亮时改深色，避免另起一套硬编码主题。
static BOOL LBColorLooksTooLight(UIColor *c) {
    if (!c) return YES;
    CGFloat r = 0, g = 0, b = 0, a = 1;
    if (![c getRed:&r green:&g blue:&b alpha:&a]) {
        CGFloat w = 0;
        if ([c getWhite:&w alpha:&a]) {
            return (w > 0.85 && a > 0.5);
        }
        return NO;
    }
    CGFloat luma = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    return (luma > 0.85 && a > 0.5);
}

/// 深色模式下标题色检测：过深（近黑）在深底上不可见
static BOOL LBColorLooksTooDark(UIColor *c) {
    if (!c) return YES;
    CGFloat r = 0, g = 0, b = 0, a = 1;
    if (![c getRed:&r green:&g blue:&b alpha:&a]) {
        CGFloat w = 1;
        if ([c getWhite:&w alpha:&a]) {
            return (w < 0.35 && a > 0.5);
        }
        return NO;
    }
    CGFloat luma = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    return (luma < 0.25 && a > 0.5);
}

static id LBDiscoverTitleConfigure(id donorConfigure) {
    // 标题色须与发现页底色对比：浅色模式禁过浅，深色模式禁过深
    BOOL dark = LBAppDarkModeEnabled();
    UIColor *fallbackNormal = dark ? [UIColor colorWithWhite:0.88 alpha:1]
                                   : [UIColor colorWithWhite:0.20 alpha:1];
    UIColor *fallbackSelected = [UIColor colorWithRed:0.90 green:0.35 blue:0.10 alpha:1];
    id cfg = donorConfigure;
    Class cfgCls = NSClassFromString(@"SGPageTitleViewConfigure");
    BOOL fresh = NO;
    if (!cfg) {
        SEL make = NSSelectorFromString(@"pageTitleViewConfigure");
        if (cfgCls && [cfgCls respondsToSelector:make]) {
            @try { cfg = ((id (*)(id, SEL))objc_msgSend)(cfgCls, make); fresh = YES; } @catch (__unused NSException *e) {}
        }
        if (!cfg && cfgCls) {
            @try { cfg = [[cfgCls alloc] init]; fresh = YES; } @catch (__unused NSException *e) {}
        }
    }
    if (!cfg) return nil;

    UIColor *titleColor = nil;
    UIColor *selectedColor = nil;
    @try { titleColor = [cfg valueForKey:@"titleColor"]; } @catch (__unused NSException *e) {}
    @try { selectedColor = [cfg valueForKey:@"titleSelectedColor"]; } @catch (__unused NSException *e) {}
    BOOL badNormal = dark ? LBColorLooksTooDark(titleColor) : LBColorLooksTooLight(titleColor);
    if (![titleColor isKindOfClass:[UIColor class]] || badNormal) {
        @try { [cfg setValue:fallbackNormal forKey:@"titleColor"]; } @catch (__unused NSException *e) {}
        titleColor = fallbackNormal;
    }
    BOOL badSel = dark ? LBColorLooksTooDark(selectedColor) : LBColorLooksTooLight(selectedColor);
    if (![selectedColor isKindOfClass:[UIColor class]] || badSel) {
        @try { [cfg setValue:fallbackSelected forKey:@"titleSelectedColor"]; } @catch (__unused NSException *e) {}
        @try { [cfg setValue:fallbackSelected forKey:@"indicatorColor"]; } @catch (__unused NSException *e) {}
        selectedColor = fallbackSelected;
    }
    LBAppendNativeMarker([NSString stringWithFormat:@"titleCfg cls=%@ fresh=%d dark=%d fix=%d",
                          NSStringFromClass([cfg class]),
                          fresh ? 1 : 0,
                          dark ? 1 : 0,
                          badNormal ? 1 : 0]);
    return cfg;
}

/// 兜底：不改动 SG 内部 layout（易崩），只叠可见 overlay UILabel
static char kLBKindWantCountKey;
static char kLBTitleTapHostKey;

/// 分类条在 host.view 内的 y：host 已在导航下则≈0，全屏铺满则≈safe+44
static CGFloat LBDiscoverTitleTopInHost(UIViewController *host) {
    if (!host.isViewLoaded || !host.view) return 0;
    UIView *hv = host.view;
    UIWindow *win = hv.window;
    CGFloat screenTop = 88;
    if (@available(iOS 11.0, *)) {
        UIEdgeInsets insets = win ? win.safeAreaInsets : hv.safeAreaInsets;
        screenTop = insets.top + 44;
    }
    if (!win) {
        // 无 window 时：safeArea 已含 nav 则贴顶，否则用 safe+44
        if (@available(iOS 11.0, *)) {
            if (hv.safeAreaInsets.top >= 44) return 0;
            return MAX(0, hv.safeAreaInsets.top + 44);
        }
        return 0;
    }
    CGRect hostInWin = [hv convertRect:hv.bounds toView:win];
    CGFloat y = screenTop - hostInWin.origin.y;
    if (y < 0) y = 0;
    if (y > 100) y = 0; // 异常大偏移时贴顶，避免双重下移
    return y;
}

void LBBringDiscoverKindHitFront(UIViewController *host) {
    if (!host || !host.isViewLoaded || !host.view) return;
    if (LBIsDiscoverNativeXBSMode()) return;
    static const NSInteger kLBKindHit = 0x4C424B48; // 'LBKH'
    UIWindow *win = host.view.window;
    UIView *container = win ?: host.view;
    for (UIView *sub in container.subviews) {
        if (sub.tag == kLBKindHit) {
            [container bringSubviewToFront:sub];
            break;
        }
    }
    // 兼容：旧包挂在 host.view 上
    if (win) {
        for (UIView *sub in host.view.subviews) {
            if (sub.tag == kLBKindHit) {
                [win addSubview:sub];
                [win bringSubviewToFront:sub];
                break;
            }
        }
    }
}

static void LBDiscover_titleKindTap(id self, SEL _cmd, id sender) {
    (void)_cmd;
    UIView *hit = nil;
    CGPoint p = CGPointZero;
    if ([sender isKindOfClass:[UITapGestureRecognizer class]]) {
        UITapGestureRecognizer *gr = (UITapGestureRecognizer *)sender;
        hit = gr.view;
        if (!hit) return;
        p = [gr locationInView:hit];
    } else if ([sender isKindOfClass:[UIView class]]) {
        hit = (UIView *)sender;
        while (hit && hit.tag != 0x4C424B48) hit = hit.superview;
        if (!hit) hit = (UIView *)sender;
        NSNumber *slot = objc_getAssociatedObject(sender, &kLBKindBtnIndexKey);
        if ([slot isKindOfClass:[NSNumber class]]) {
            UIViewController *host = [self isKindOfClass:[UIViewController class]]
                ? (UIViewController *)self : LBPrimaryDiscoverHost();
            UIView *root = objc_getAssociatedObject(hit, "lbKindTitleRoot");
            LBAppendNativeMarker([NSString stringWithFormat:@"kindTapGesture idx=%ld slot",
                                  (long)slot.integerValue]);
            LBDiscoverHandleKindSelect(host, root, slot.integerValue);
            return;
        }
        p = CGPointMake(CGRectGetMidX(hit.bounds), CGRectGetMidY(hit.bounds));
    } else {
        return;
    }
    UIView *root = objc_getAssociatedObject(hit, "lbKindTitleRoot");
    if (![root isKindOfClass:[UIView class]]) root = hit;
    CGPoint pInRoot = [hit convertPoint:p toView:root];

    NSMutableArray<UIButton *> *btns = [NSMutableArray array];
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if ([v isKindOfClass:[UIButton class]] && !v.hidden && v.alpha > 0.05) {
            [btns addObject:(UIButton *)v];
        }
        for (UIView *sub in v.subviews) [stack addObject:sub];
    }
    NSArray *sorted = [btns sortedArrayUsingComparator:^NSComparisonResult(UIButton *a, UIButton *b) {
        return a.frame.origin.x < b.frame.origin.x ? NSOrderedAscending : NSOrderedDescending;
    }];
    NSInteger idx = -1;
    for (NSUInteger i = 0; i < sorted.count; i++) {
        UIButton *b = sorted[i];
        CGRect fr = [b convertRect:b.bounds toView:root];
        if (CGRectContainsPoint(fr, pInRoot)) { idx = (NSInteger)i; break; }
    }
    if (idx < 0 && sorted.count > 0) {
        CGFloat best = CGFLOAT_MAX;
        for (NSUInteger i = 0; i < sorted.count; i++) {
            UIButton *b = sorted[i];
            CGRect fr = [b convertRect:b.bounds toView:root];
            CGFloat mid = CGRectGetMidX(fr);
            CGFloat d = fabs(mid - pInRoot.x);
            if (d < best) { best = d; idx = (NSInteger)i; }
        }
    }
    UIViewController *host = objc_getAssociatedObject(hit, &kLBTitleTapHostKey);
    if (![host isKindOfClass:[UIViewController class]]) {
        host = [self isKindOfClass:[UIViewController class]]
            ? (UIViewController *)self : LBPrimaryDiscoverHost();
    }
    LBAppendNativeMarker([NSString stringWithFormat:@"kindTapGesture idx=%ld x=%.0f",
                          (long)idx, pInRoot.x]);
    if (idx >= 0) LBDiscoverHandleKindSelect(host, root, idx);
}

static void LBInstallTitleKindTap(UIViewController *host, UIView *titleRoot) {
    if (!host || !titleRoot || !host.isViewLoaded || !host.view) return;
    if (LBIsDiscoverNativeXBSMode()) {
        // 清掉历史 hit overlay，避免挡原生分类点击
        static const NSInteger kLBKindHit = 0x4C424B48; // 'LBKH'
        UIWindow *win = host.view.window;
        UIView *container = win ?: host.view;
        NSMutableArray *junk = [NSMutableArray array];
        for (UIView *sub in container.subviews) {
            if (sub.tag == kLBKindHit) [junk addObject:sub];
        }
        for (UIView *sub in host.view.subviews) {
            if (sub.tag == kLBKindHit) [junk addObject:sub];
        }
        for (UIView *v in junk) [v removeFromSuperview];
        LBAppendNativeMarker(@"kindTap skip XBS (removed hit)");
        return;
    }
    static const NSInteger kLBKindHit = 0x4C424B48; // 'LBKH'
    UIWindow *win = host.view.window;
    UIView *container = win ?: host.view;
    UIView *hit = nil;
    for (UIView *sub in container.subviews) {
        if (sub.tag == kLBKindHit) { hit = sub; break; }
    }
    if (!hit) {
        for (UIView *sub in host.view.subviews) {
            if (sub.tag == kLBKindHit) { hit = sub; break; }
        }
    }
    // 挂到 keyWindow，避免宿主子树里其它层吃掉点击
    CGRect tf = [titleRoot convertRect:titleRoot.bounds toView:container];
    if (tf.size.width < 2 || tf.size.height < 2) {
        CGFloat top = LBDiscoverTitleTopInHost(host);
        CGRect hostInC = [host.view convertRect:CGRectMake(0, top, 2, 44) toView:container];
        tf = CGRectMake(0, hostInC.origin.y, container.bounds.size.width, 44);
    }
    tf = CGRectInset(tf, 0, -6);

    Class cls = [host class];
    SEL sel = @selector(lb_discoverTitleKindTap:);
    if (!class_getInstanceMethod(cls, sel)) {
        class_addMethod(cls, sel, (IMP)LBDiscover_titleKindTap, "v@:@");
    }

    if (!hit) {
        hit = [[UIView alloc] initWithFrame:tf];
        hit.tag = kLBKindHit;
        // 稳定：透明；点击由槽位按钮/手势吃
        hit.backgroundColor = [UIColor clearColor];
        hit.userInteractionEnabled = YES;
        hit.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        UITapGestureRecognizer *tap =
            [[UITapGestureRecognizer alloc] initWithTarget:host action:sel];
        tap.cancelsTouchesInView = YES;
        [hit addGestureRecognizer:tap];
        [container addSubview:hit];
        LBAppendNativeMarker([NSString stringWithFormat:
                              @"kindHitControl new win=%d frame=%.0f,%.0f,%.0fx%.0f",
                              win ? 1 : 0,
                              tf.origin.x, tf.origin.y, tf.size.width, tf.size.height]);
    } else {
        if (hit.superview != container) [container addSubview:hit];
        hit.frame = tf;
        hit.hidden = NO;
        hit.userInteractionEnabled = YES;
        hit.backgroundColor = [UIColor clearColor];
        LBAppendNativeMarker([NSString stringWithFormat:
                              @"kindHitControl reuse win=%d frame=%.0f,%.0f,%.0fx%.0f",
                              win ? 1 : 0,
                              tf.origin.x, tf.origin.y, tf.size.width, tf.size.height]);
    }

    for (UIView *old in [hit.subviews copy]) {
        if ([old isKindOfClass:[UIButton class]]) [old removeFromSuperview];
    }
    NSMutableArray<UIButton *> *btns = [NSMutableArray array];
    NSMutableArray *stack = [NSMutableArray arrayWithObject:titleRoot];
    while (stack.count) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if ([v isKindOfClass:[UIButton class]] && !v.hidden && v.alpha > 0.05) {
            [btns addObject:(UIButton *)v];
        }
        for (UIView *sub in v.subviews) [stack addObject:sub];
    }
    NSArray *sorted = [btns sortedArrayUsingComparator:^NSComparisonResult(UIButton *a, UIButton *b) {
        return a.frame.origin.x < b.frame.origin.x ? NSOrderedAscending : NSOrderedDescending;
    }];
    NSInteger slot = 0;
    for (UIButton *b in sorted) {
        CGRect fr = [b convertRect:b.bounds toView:hit];
        if (fr.size.width < 2) continue;
        UIButton *slotBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        slotBtn.frame = CGRectInset(fr, -2, -4);
        slotBtn.backgroundColor = [UIColor clearColor];
        slotBtn.userInteractionEnabled = YES;
        objc_setAssociatedObject(slotBtn, &kLBKindBtnIndexKey, @(slot),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [slotBtn addTarget:host action:sel forControlEvents:UIControlEventTouchUpInside];
        [hit addSubview:slotBtn];
        slot++;
    }

    objc_setAssociatedObject(hit, &kLBTitleTapHostKey, host, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(hit, "lbKindTitleRoot", titleRoot, OBJC_ASSOCIATION_ASSIGN);
    [container bringSubviewToFront:hit];
    LBAppendNativeMarker([NSString stringWithFormat:@"kindHitSlots n=%ld", (long)slot]);

    // 文件强制切类：Documents/legado_kind_force.txt 写索引数字
    @try {
        NSString *fp = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_kind_force.txt"];
        NSString *raw = [NSString stringWithContentsOfFile:fp encoding:NSUTF8StringEncoding error:NULL];
        if (raw.length > 0) {
            NSInteger forceIdx = raw.integerValue;
            [[NSFileManager defaultManager] removeItemAtPath:fp error:NULL];
            LBAppendNativeMarker([NSString stringWithFormat:@"kindForceFile idx=%ld", (long)forceIdx]);
            LBDiscoverHandleKindSelect(host, titleRoot, forceIdx);
        }
    } @catch (__unused NSException *e) {}
}

/// 收起/恢复分类栏：kinds≤1 时对齐阅读——不显示分类栏。
/// 收起 = 隐藏 + 高度归零（列表 top 由 title maxY 推导，自动上移到导航下）。
static void LBSetDiscoverTitleBarCollapsed(id titleView, BOOL collapsed) {
    if (![titleView isKindOfClass:[UIView class]]) return;
    UIView *tv = (UIView *)titleView;
    CGRect f = tv.frame;
    if (collapsed) {
        if (f.size.height > 1.0) sDiscoverTitleBarOrigH = f.size.height;
        if (f.size.height > 0.0) {
            f.size.height = 0;
            @try { tv.frame = f; } @catch (__unused NSException *e) {}
        }
        tv.hidden = YES;
    } else {
        CGFloat h = sDiscoverTitleBarOrigH > 1.0 ? sDiscoverTitleBarOrigH : 44.0;
        if (f.size.height < h - 1.0) {
            f.size.height = h;
            @try { tv.frame = f; } @catch (__unused NSException *e) {}
        }
        tv.hidden = NO;
        if (tv.alpha < 0.92) tv.alpha = 0.92;
    }
    BOOL stateChanged = (sDiscoverTitleBarCollapsed != collapsed);
    sDiscoverTitleBarCollapsed = collapsed;
    // 列表 top 由 title maxY 推导：收起/恢复后立刻重排一次，避免留下原栏高度的空档
    if (stateChanged) {
        @try {
            UIResponder *r = [tv nextResponder];
            while (r && ![r isKindOfClass:[UIViewController class]]) r = [r nextResponder];
            UIViewController *host = [r isKindOfClass:[UIViewController class]] ? (UIViewController *)r : nil;
            if (host && host.isViewLoaded && host.view) {
                UIViewController *owner = nil;
                UITableView *table = LBFindBestDiscoverTable(host, &owner);
                if (table) {
                    LBRepairDiscoverTableFrame(host, owner, table);
                }
            }
        } @catch (__unused NSException *e) {}
    }
}

static void LBPaintTitleLabels(id tv, NSInteger selectedIndex) {
    if (![tv isKindOfClass:[UIView class]]) return;
    if (LBIsDiscoverNativeXBSMode()) {
        // 纯原生：不改字色/不叠 overlay，交给宿主 configure
        return;
    }
    UIView *root = (UIView *)tv;
    // 分类栏底色跟随香色深色模式；收起状态保持隐藏
    @try {
        root.backgroundColor = LBDiscoverBarColor();
        root.opaque = YES;
        if (!sDiscoverTitleBarCollapsed) root.hidden = NO;
        root.alpha = 1;
        root.clipsToBounds = NO;
    } @catch (__unused NSException *e) {}
    UIColor *normal = LBDiscoverPrimaryTextColor();
    UIColor *selected = [UIColor colorWithRed:0.90 green:0.35 blue:0.10 alpha:1];

    NSMutableArray<UIButton *> *btns = [NSMutableArray array];
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        for (UIView *sub in v.subviews) {
            NSString *cn = NSStringFromClass([sub class]);
            if ([sub isKindOfClass:[UIButton class]] || [cn containsString:@"PageTitleButton"]) {
                if ([sub isKindOfClass:[UIButton class]]) [btns addObject:(UIButton *)sub];
            }
            [stack addObject:sub];
        }
    }
    NSArray *sorted = [btns sortedArrayUsingComparator:^NSComparisonResult(UIButton *a, UIButton *b) {
        return a.frame.origin.x < b.frame.origin.x ? NSOrderedAscending : NSOrderedDescending;
    }];
    NSNumber *wantObj = objc_getAssociatedObject(root, &kLBKindWantCountKey);
    NSInteger want = wantObj ? wantObj.integerValue : (NSInteger)sorted.count;

    NSMutableArray *dump = [NSMutableArray array];
    NSInteger idx = 0;
    NSInteger tag = 0x4C4254; // 'LBT'
    for (UIButton *btn in sorted) {
        BOOL keep = (want <= 0) || (idx < want);
        NSInteger otag = tag + (NSInteger)idx;
        if (!keep) {
            btn.hidden = YES;
            btn.alpha = 0;
            btn.userInteractionEnabled = NO;
            @try {
                UIView *ov = [root viewWithTag:otag];
                if (ov) { ov.hidden = YES; ov.alpha = 0; }
            } @catch (__unused NSException *e) {}
            idx++;
            continue;
        }
        UIColor *c = (idx == selectedIndex) ? selected : normal;
        @try {
            NSString *t = [btn titleForState:UIControlStateNormal];
            if (t.length == 0) @try { t = btn.currentTitle; } @catch (__unused NSException *e) {}
            if (t.length == 0) @try { t = btn.titleLabel.text; } @catch (__unused NSException *e) {}
            [btn setTitleColor:c forState:UIControlStateNormal];
            [btn setTitleColor:selected forState:UIControlStateSelected];
            @try { btn.backgroundColor = [UIColor clearColor]; } @catch (__unused NSException *e) {}
            @try { btn.titleLabel.alpha = 1; btn.alpha = 1; btn.hidden = NO; btn.userInteractionEnabled = YES; } @catch (__unused NSException *e) {}

            NSInteger otag = tag + (NSInteger)idx;
            UILabel *overlay = nil;
            @try { overlay = (UILabel *)[root viewWithTag:otag]; } @catch (__unused NSException *e) {}
            if (![overlay isKindOfClass:[UILabel class]]) {
                @try { overlay = (UILabel *)[btn viewWithTag:tag]; } @catch (__unused NSException *e) {}
            }
            if (![overlay isKindOfClass:[UILabel class]]) {
                overlay = [[UILabel alloc] initWithFrame:CGRectZero];
                overlay.tag = otag;
                overlay.textAlignment = NSTextAlignmentCenter;
                overlay.userInteractionEnabled = NO;
                overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            }
            // 一律挂到 titleView 根上，避免被按钮图层盖住
            CGRect b = [btn convertRect:btn.bounds toView:root];
            if (b.size.width < 1 || b.size.height < 1) {
                CGRect fr = btn.frame;
                if (fr.size.width >= 1 && fr.size.height >= 1) {
                    b = fr;
                } else {
                    CGSize need = [t sizeWithAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:15]}];
                    CGFloat slot = MAX(ceil(need.width) + 24, 72);
                    b = CGRectMake(idx * slot, 0, slot, MAX(root.bounds.size.height, 28));
                }
            }
            if (overlay.superview != root) {
                [overlay removeFromSuperview];
                @try { [root addSubview:overlay]; } @catch (__unused NSException *e) { overlay = nil; }
            }
            if (overlay) {
                overlay.tag = otag;
                overlay.frame = b;
                overlay.text = t ?: @"";
                overlay.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
                overlay.textColor = c;
                overlay.hidden = NO;
                overlay.alpha = 1;
                overlay.userInteractionEnabled = NO; // 必须穿透到按钮，否则分类点不动
                [root bringSubviewToFront:overlay];
            }
            if (dump.count < 6) {
                [dump addObject:[NSString stringWithFormat:@"%@ b=%.0f,%.0f,%.0fx%.0f ov=%@",
                                 t ?: @"-",
                                 b.origin.x, b.origin.y, b.size.width, b.size.height,
                                 overlay.text ?: @"-"]];
            }
        } @catch (NSException *ex) {
            LBAppendNativeMarker([NSString stringWithFormat:@"paintTitles EX %@", ex.reason ?: @""]);
        }
        idx++;
    }

    CGRect tf = root.frame;
    LBAppendNativeMarker([NSString stringWithFormat:
                          @"paintTitles btns=%lu tvFrame=%.0f,%.0f,%.0fx%.0f | %@",
                          (unsigned long)btns.count,
                          tf.origin.x, tf.origin.y, tf.size.width, tf.size.height,
                          [dump componentsJoinedByString:@" ; "]]);
}

/// SGPageTitleView 内部 UIScrollView：按文字宽度重排按钮，撑开可横滚
static void LBEnableTitleScroll(id tv) {
    if (![tv isKindOfClass:[UIView class]]) return;
    UIView *root = (UIView *)tv;
    NSMutableArray<UIScrollView *> *scrolls = [NSMutableArray array];
    NSMutableArray<UIButton *> *btns = [NSMutableArray array];
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if ([v isKindOfClass:[UIScrollView class]]) [scrolls addObject:(UIScrollView *)v];
        if ([v isKindOfClass:[UIButton class]]) [btns addObject:(UIButton *)v];
        for (UIView *sub in v.subviews) [stack addObject:sub];
    }

    // 按文字宽度顺序重排按钮
    NSArray<UIButton *> *sorted = [btns sortedArrayUsingComparator:^NSComparisonResult(UIButton *a, UIButton *b) {
        return a.frame.origin.x < b.frame.origin.x ? NSOrderedAscending : NSOrderedDescending;
    }];
    CGFloat x = 12;
    CGFloat h = MAX(root.bounds.size.height, 38);
    for (UIButton *b in sorted) {
        NSString *t = [b titleForState:UIControlStateNormal];
        if (t.length == 0) @try { t = b.titleLabel.text; } @catch (__unused NSException *e) {}
        CGSize need = [t sizeWithAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:15]}];
        CGFloat w = MAX(ceil(need.width) + 20, 66);
        UIView *host = b.superview;
        @try { b.frame = CGRectMake(x, 0, w, h); } @catch (__unused NSException *e) {}
        // 同步 overlay
        UIView *ov = [b viewWithTag:0x4C4254];
        if (ov) @try { ov.frame = b.bounds; } @catch (__unused NSException *e) {}
        UIView *rootOv = [root viewWithTag:0x4C4254 + [sorted indexOfObject:b]];
        if (rootOv && rootOv.superview == root) {
            @try { rootOv.frame = CGRectMake(x, 0, w, h); } @catch (__unused NSException *e) {}
        }
        x += w + 6;
        (void)host;
    }
    CGFloat totalW = x + 12;

    for (UIScrollView *sv in scrolls) {
        @try {
            sv.scrollEnabled = YES;
            sv.showsHorizontalScrollIndicator = NO;
            sv.alwaysBounceHorizontal = YES;
            sv.bounces = YES;
            sv.pagingEnabled = NO;
            sv.contentSize = CGSizeMake(totalW, sv.contentSize.height);
            sv.clipsToBounds = YES;
        } @catch (__unused NSException *e) {}
    }
    @try { root.clipsToBounds = NO; } @catch (__unused NSException *e) {}

    LBAppendNativeMarker([NSString stringWithFormat:@"kindScroll btns=%lu totalW=%.0f",
                          (unsigned long)btns.count, totalW]);
}

/// resetContent 后强制用 Legado 分类覆盖 SGPageTitleView（donor bookWorld 会盖掉 arrHeaderBtnTitle）
static void LBRevealDiscoverTitleAndListEx(UIViewController *host, BOOL force);
static void LBRevealDiscoverTitleAndList(UIViewController *host) {
    LBRevealDiscoverTitleAndListEx(host, NO);
}

static void LBRevealDiscoverTitleAndListEx(UIViewController *host, BOOL force) {
    if (!host || !host.isViewLoaded || !host.view) return;
    static const NSInteger kLBFO = 0x4C42464F; // 'LBFO' feed overlay
    // XBS（原生源）态：禁止创建/保留 feed overlay，否则盖住原生书列表（残留 Legado 数据触发 arrN>0 → 空 overlay 挡书）
    if (LBIsDiscoverNativeXBSMode()) {
        for (UIView *sub in host.view.subviews) {
            if ([sub isKindOfClass:[UITableView class]] && sub.tag == kLBFO) {
                [sub removeFromSuperview];
                LBAppendNativeMarker(@"reveal XBS remove feedOverlay");
                break;
            }
        }
        return;
    }

    id tv = nil;
    @try { tv = [host valueForKey:@"pageTitleView"]; } @catch (__unused NSException *e) {}
    UIView *title = [tv isKindOfClass:[UIView class]] ? (UIView *)tv : nil;

    UIViewController *list = nil;
    @try { list = LBActiveDiscoverListVC(host); } @catch (__unused NSException *e) {}
    NSUInteger arrN = 0;
    @try {
        id a = [list valueForKey:@"arrBaseData"];
        if ([a isKindOfClass:[NSArray class]]) arrN = [(NSArray *)a count];
    } @catch (__unused NSException *e) {}

    CGFloat titleBottom = title ? CGRectGetMaxY(title.frame) : 0;
    // 分类栏收起：内容从栏顶位置开始（maxY 已塌缩，直接用栏顶 y）
    if (sDiscoverTitleBarCollapsed) titleBottom = LBDiscoverTitleTopInHost(host);
    if (titleBottom < 2) titleBottom = LBDiscoverTitleTopInHost(host) + 44;
    if (titleBottom < 36) titleBottom = 44;

    NSString *sig = [NSString stringWithFormat:@"%.0f|%@", titleBottom,
                     title ? NSStringFromCGRect(title.frame) : @"-"];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!force && sLastRevealSig && [sLastRevealSig isEqualToString:sig] &&
        sLastRevealArrN == (NSInteger)arrN && (now - sLastRevealAt) < 0.5) {
        for (UIView *sub in host.view.subviews) {
            if ([sub isKindOfClass:[UITableView class]] && sub.tag == kLBFO) {
                @try { [(UITableView *)sub reloadData]; } @catch (__unused NSException *e) {}
                break;
            }
        }
        return;
    }
    sLastRevealSig = [sig copy];
    sLastRevealAt = now;
    sLastRevealArrN = (NSInteger)arrN;

    if (title) {
        if (!title.superview) [host.view addSubview:title];
        // 收起状态（kinds≤1）保持隐藏；否则显示并跟随深色模式底色
        if (!sDiscoverTitleBarCollapsed) {
            title.hidden = NO;
            title.alpha = 1;
        }
        title.backgroundColor = LBDiscoverBarColor();
    }

    LBPinDiscoverContentToFirstPage(host);

    if (!list && host.isViewLoaded) {
        NSMutableArray *q = [NSMutableArray arrayWithObject:host.view];
        NSInteger budget = 80;
        while (q.count && budget-- > 0) {
            UIView *cur = q.firstObject;
            [q removeObjectAtIndex:0];
            for (UIResponder *r = cur.nextResponder; r; r = r.nextResponder) {
                if ([r isKindOfClass:[UIViewController class]] &&
                    [NSStringFromClass([r class]) containsString:@"BookList"]) {
                    list = (UIViewController *)r;
                    break;
                }
            }
            if (list) break;
            for (UIView *sub in cur.subviews) [q addObject:sub];
        }
        @try {
            id a = [list valueForKey:@"arrBaseData"];
            if ([a isKindOfClass:[NSArray class]]) arrN = [(NSArray *)a count];
        } @catch (__unused NSException *e) {}
        sLastRevealArrN = (NSInteger)arrN;
    }

    LBAppendNativeMarker([NSString stringWithFormat:
                          @"reveal force=%d titleBottom=%.0f arr=%lu",
                          force ? 1 : 0, titleBottom, (unsigned long)arrN]);

    id scroll = nil;
    @try { scroll = [host valueForKey:@"pageContentScrollView"]; } @catch (__unused NSException *e) {}
    if ([scroll isKindOfClass:[UIView class]]) {
        UIView *sv = (UIView *)scroll;
        sv.hidden = NO;
        sv.alpha = 1;
        CGRect hb = host.view.bounds;
        if (hb.size.width > 2 && hb.size.height > titleBottom + 40) {
            CGRect want = CGRectMake(0, titleBottom, hb.size.width, hb.size.height - titleBottom);
            if (!CGRectEqualToRect(sv.frame, want)) sv.frame = want;
        }
    }

    if (list && list.isViewLoaded && list.view) {
        list.view.hidden = NO;
        list.view.alpha = 1;
    }

    if (list && arrN > 0) {
        LBEnsurePlazaListTableHooks([list class]);
        UITableView *overlay = nil;
        for (UIView *sub in host.view.subviews) {
            if ([sub isKindOfClass:[UITableView class]] && sub.tag == kLBFO) {
                overlay = (UITableView *)sub;
                break;
            }
        }
        CGRect hb = host.view.bounds;
        CGRect of = CGRectMake(0, titleBottom, hb.size.width, MAX(200, hb.size.height - titleBottom));
        if (!overlay) {
            overlay = [[UITableView alloc] initWithFrame:of style:UITableViewStylePlain];
            overlay.tag = kLBFO;
            overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            overlay.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
            overlay.rowHeight = 108;
            overlay.estimatedRowHeight = 108;
            overlay.allowsSelection = YES;
            [host.view addSubview:overlay];
            LBAppendNativeMarker([NSString stringWithFormat:
                                  @"reveal feedOverlay new arr=%lu", (unsigned long)arrN]);
        } else if (!CGRectEqualToRect(overlay.frame, of)) {
            overlay.frame = of;
        }
        // 每次 reveal 同步深色模式配色（含历史已建 overlay）
        overlay.backgroundColor = LBDiscoverPageColor();
        overlay.separatorColor = LBDiscoverSeparatorColor();
        overlay.hidden = NO;
        overlay.alpha = 1;
        overlay.scrollEnabled = YES;
        overlay.userInteractionEnabled = YES;
        overlay.bounces = YES;
        if (@available(iOS 11.0, *)) {
            overlay.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
        }
        overlay.contentInset = UIEdgeInsetsZero;
        overlay.tableHeaderView = nil;
        overlay.dataSource = (id<UITableViewDataSource>)list;
        overlay.delegate = (id<UITableViewDelegate>)list;
        @try { [overlay reloadData]; } @catch (__unused NSException *e) {}
        if ([scroll isKindOfClass:[UIView class]]) {
            ((UIView *)scroll).userInteractionEnabled = NO;
            [host.view sendSubviewToBack:(UIView *)scroll];
        }
        [host.view bringSubviewToFront:overlay];
    }

    if (title) [host.view bringSubviewToFront:title];
    LBBringDiscoverKindHitFront(host);
}

static void LBForceLegadoTitlesOnChrome(UIViewController *host, NSArray *titles) {
    if (!host || titles.count == 0) return;
    if (LBIsDiscoverNativeXBSMode()) {
        LBAppendNativeMarker(@"forceTitles skip XBS");
        return;
    }
    BOOL prev = sApplyingKinds;
    sApplyingKinds = YES;
    @try { [host setValue:titles forKey:@"arrHeaderBtnTitle"]; } @catch (__unused NSException *e) {}

    id tv = nil;
    @try { tv = [host valueForKey:@"pageTitleView"]; } @catch (__unused NSException *e) {}
    if (!tv) {
        LBAppendNativeMarker(@"forceTitles no pageTitleView (will create)");
    }

    // kinds≤1（单 URL exploreUrl）：对齐阅读——收起分类栏；否则确保展开
    BOOL wantCollapse = (titles.count <= 1);
    if ([tv isKindOfClass:[UIView class]]) {
        LBSetDiscoverTitleBarCollapsed((UIView *)tv, wantCollapse);
    } else {
        sDiscoverTitleBarCollapsed = wantCollapse;
    }

    BOOL applied = NO;
    if (tv) {
    for (NSString *selName in @[@"resetTitleNames:", @"setTitleNames:", @"resetTitles:",
                                @"setTitles:", @"reloadTitles:", @"updateTitleNames:"]) {
        SEL s = NSSelectorFromString(selName);
        if (![tv respondsToSelector:s]) continue;
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(tv, s, titles);
            LBAppendNativeMarker([NSString stringWithFormat:@"forceTitles via %@", selName]);
            applied = YES;
            break;
        } @catch (NSException *ex) {
            LBAppendNativeMarker([NSString stringWithFormat:@"forceTitles %@ EX %@",
                                  selName, ex.reason ?: @""]);
        }
    }
    if (!applied) {
        for (NSString *k in @[@"titleNames", @"titles", @"arrTitle", @"titleArr",
                              @"btnTitles", @"titleArray", @"_titleNames"]) {
            @try {
                [tv setValue:titles forKey:k];
                LBAppendNativeMarker([NSString stringWithFormat:@"forceTitles KVC %@", k]);
                applied = YES;
                break;
            } @catch (__unused NSException *e) {}
        }
    }
    } // if (tv)

    // 禁止工厂重建 SGPageTitleView：会拆掉 pageContent / BookListCon 层级 → 黑屏无表
    Class tvCls = NSClassFromString(@"SGPageTitleView");
    SEL factory = @selector(pageTitleViewWithFrame:delegate:titleNames:configure:);
    if ([tv isKindOfClass:[UIView class]]) {
        UIView *old = (UIView *)tv;
        CGFloat w = host.isViewLoaded ? host.view.bounds.size.width : 0;
        if (w < 1) w = [UIScreen mainScreen].bounds.size.width;
        CGFloat top = LBDiscoverTitleTopInHost(host);
        CGRect frame = old.frame;
        CGFloat winY = -1;
        @try {
            if (host.view.window) {
                winY = [old convertRect:old.bounds toView:host.view.window].origin.y;
            }
        } @catch (__unused NSException *e) {}
        BOOL tooLow = (winY > 0 && winY > 140); // 双重偏移：条跑到 nav 下很远
        // 收起状态跳过 frame 修正（高度归零是刻意的）
        if (!sDiscoverTitleBarCollapsed &&
            (CGRectIsEmpty(frame) || frame.size.width < 2 || frame.size.height < 2
             || fabs(frame.origin.y - top) > 2 || tooLow)) {
            frame = CGRectMake(0, top, w, MAX(38, frame.size.height > 2 ? frame.size.height : 44));
            old.frame = frame;
            LBAppendNativeMarker([NSString stringWithFormat:
                                  @"forceTitles fixFrameOnly y=%.0f h=%.0f winY=%.0f",
                                  frame.origin.y, frame.size.height, winY]);
        }
        id configure = nil;
        @try { configure = [old valueForKey:@"configure"]; } @catch (__unused NSException *e) {}
        if (!configure) {
            @try { configure = [host valueForKey:@"pageTitleViewConfigure"]; } @catch (__unused NSException *e) {}
        }
        configure = LBDiscoverTitleConfigure(configure) ?: configure;
        if (configure) {
            @try { [old setValue:configure forKey:@"configure"]; } @catch (__unused NSException *e) {}
        }
        applied = YES;
    }

    // 无旧 titleView 时才新建
    if ((!tv || ![tv isKindOfClass:[UIView class]]) && host.isViewLoaded &&
        tvCls && [tvCls respondsToSelector:factory]) {
        CGFloat w = host.view.bounds.size.width;
        if (w < 1) w = [UIScreen mainScreen].bounds.size.width;
        CGFloat top = LBDiscoverTitleTopInHost(host);
        CGRect frame = CGRectMake(0, top, w, 44);
        id configure = nil;
        @try { configure = [host valueForKey:@"pageTitleViewConfigure"]; } @catch (__unused NSException *e) {}
        configure = LBDiscoverTitleConfigure(configure) ?: configure;
        @try {
            id neu = ((id (*)(id, SEL, CGRect, id, id, id))objc_msgSend)(
                tvCls, factory, frame, host, titles, configure);
            if ([neu isKindOfClass:[UIView class]]) {
                [host.view addSubview:(UIView *)neu];
                @try { [host setValue:neu forKey:@"pageTitleView"]; } @catch (__unused NSException *e) {}
                tv = neu;
                applied = YES;
                LBAppendNativeMarker(@"forceTitles create titleView");
            }
        } @catch (NSException *ex) {
            LBAppendNativeMarker([NSString stringWithFormat:@"forceTitles create EX %@",
                                  ex.reason ?: @""]);
        }
    }

    for (NSString *selName in @[@"resetTitle", @"resetTitles", @"reload", @"layoutIfNeeded"]) {
        SEL s = NSSelectorFromString(selName);
        if ([tv respondsToSelector:s]) {
            @try { ((void (*)(id, SEL))objc_msgSend)(tv, s); } @catch (__unused NSException *e) {}
        }
    }
    if ([tv isKindOfClass:[UIView class]]) {
        @try { [(UIView *)tv setNeedsLayout]; [(UIView *)tv layoutIfNeeded]; } @catch (__unused NSException *e) {}
    }
    // 无重建时直接改按钮文案（否则一直停在 donor 男频…）
    // Legado kinds 远多于 donor 按钮时：自建横向滚动分类条（禁工厂重建 SGPageTitleView）
    if ([tv isKindOfClass:[UIView class]]) {
        UIView *titleRoot = (UIView *)tv;
        static const NSInteger kLBKindSoftScroll = 0x4C424B53; // 'LBKS'
        UIScrollView *softScroll = nil;
        for (UIView *sub in titleRoot.subviews) {
            if (sub.tag == kLBKindSoftScroll && [sub isKindOfClass:[UIScrollView class]]) {
                softScroll = (UIScrollView *)sub;
                break;
            }
        }
        NSMutableArray<UIButton *> *btns = [NSMutableArray array];
        NSMutableArray *stack = [NSMutableArray arrayWithObject:titleRoot];
        while (stack.count) {
            UIView *v = stack.lastObject;
            [stack removeLastObject];
            if (v.tag == kLBKindSoftScroll) continue; // 跳过自建条，勿把其按钮当 donor
            if ([v isKindOfClass:[UIButton class]]) [btns addObject:(UIButton *)v];
            for (UIView *sub in v.subviews) [stack addObject:sub];
        }
        NSArray *sorted = [btns sortedArrayUsingComparator:^NSComparisonResult(UIButton *a, UIButton *b) {
            return a.frame.origin.x < b.frame.origin.x ? NSOrderedAscending : NSOrderedDescending;
        }];
        BOOL needSoftScroll = (titles.count > 1 && sorted.count < titles.count);
        BOOL usedSoftScroll = NO;
        if (needSoftScroll) {
            for (UIButton *b in sorted) {
                b.hidden = YES;
                b.alpha = 0;
                b.userInteractionEnabled = NO;
            }
            CGFloat h = MAX(38, titleRoot.bounds.size.height > 2 ? titleRoot.bounds.size.height : 38);
            CGFloat w = titleRoot.bounds.size.width;
            if (w < 2) w = host.isViewLoaded ? host.view.bounds.size.width : [UIScreen mainScreen].bounds.size.width;
            if (!softScroll) {
                softScroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 0, w, h)];
                softScroll.tag = kLBKindSoftScroll;
                softScroll.showsHorizontalScrollIndicator = NO;
                softScroll.showsVerticalScrollIndicator = NO;
                softScroll.alwaysBounceHorizontal = YES;
                softScroll.backgroundColor = [UIColor clearColor];
                softScroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                [titleRoot addSubview:softScroll];
            } else {
                softScroll.frame = CGRectMake(0, 0, w, h);
                softScroll.hidden = NO;
            }
            for (UIView *old in [softScroll.subviews copy]) {
                [old removeFromSuperview];
            }
            LBEnsureDiscoverKindBtnMethod([host class]);
            SEL tapSel = @selector(lb_discoverKindBtn:);
            BOOL dark = LBAppDarkModeEnabled();
            UIColor *normalC = dark ? [UIColor colorWithWhite:0.88 alpha:1]
                                    : [UIColor colorWithWhite:0.20 alpha:1];
            UIColor *selC = [UIColor colorWithRed:0.90 green:0.35 blue:0.10 alpha:1];
            CGFloat x = 8;
            NSInteger pref = sSelectedKindIndex;
            if (pref < 0 || pref >= (NSInteger)titles.count) pref = 0;
            for (NSUInteger i = 0; i < titles.count; i++) {
                NSString *name = [titles[i] isKindOfClass:[NSString class]] ? titles[i] : @"分类";
                UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
                [b setTitle:name forState:UIControlStateNormal];
                b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
                BOOL on = ((NSInteger)i == pref);
                [b setTitleColor:on ? selC : normalC forState:UIControlStateNormal];
                CGSize sz = [name sizeWithAttributes:@{NSFontAttributeName: b.titleLabel.font}];
                CGFloat bw = MAX(44, sz.width + 16);
                b.frame = CGRectMake(x, 0, bw, h);
                objc_setAssociatedObject(b, &kLBKindBtnIndexKey, @((NSInteger)i),
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                [b addTarget:host action:tapSel forControlEvents:UIControlEventTouchUpInside];
                [softScroll addSubview:b];
                x += bw + 4;
            }
            softScroll.contentSize = CGSizeMake(MAX(w, x + 8), h);
            // 滚到默认选中附近
            CGFloat targetX = 0;
            for (UIView *sub in softScroll.subviews) {
                NSNumber *ix = objc_getAssociatedObject(sub, &kLBKindBtnIndexKey);
                if ([ix isKindOfClass:[NSNumber class]] && ix.integerValue == pref) {
                    targetX = MAX(0, sub.frame.origin.x - 40);
                    break;
                }
            }
            if (softScroll.contentSize.width > w) {
                [softScroll setContentOffset:CGPointMake(MIN(targetX, softScroll.contentSize.width - w), 0)
                                    animated:NO];
            }
            [titleRoot bringSubviewToFront:softScroll];
            usedSoftScroll = YES;
            LBAppendNativeMarker([NSString stringWithFormat:
                                  @"forceTitles softScroll n=%lu donorBtn=%lu pref=%ld",
                                  (unsigned long)titles.count, (unsigned long)sorted.count,
                                  (long)pref]);
        } else {
            if (softScroll) {
                softScroll.hidden = YES;
                for (UIView *old in [softScroll.subviews copy]) {
                    [old removeFromSuperview];
                }
            }
            for (NSUInteger i = 0; i < sorted.count; i++) {
                UIButton *b = sorted[i];
                if (i < titles.count) {
                    NSString *name = [titles[i] isKindOfClass:[NSString class]] ? titles[i] : @"分类";
                    @try {
                        [b setTitle:name forState:UIControlStateNormal];
                        [b setTitle:name forState:UIControlStateSelected];
                        b.titleLabel.text = name;
                    } @catch (__unused NSException *e) {}
                    b.hidden = NO;
                    b.alpha = 1;
                    b.userInteractionEnabled = YES;
                } else {
                    b.hidden = YES;
                    b.alpha = 0;
                    b.userInteractionEnabled = NO;
                }
            }
            LBAppendNativeMarker([NSString stringWithFormat:@"forceTitles softBtn n=%lu want=%lu hid=%lu",
                                  (unsigned long)sorted.count, (unsigned long)titles.count,
                                  (unsigned long)MAX((NSInteger)sorted.count - (NSInteger)titles.count, 0)]);
        }
        objc_setAssociatedObject(titleRoot, &kLBKindWantCountKey, @(titles.count),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // softScroll 已自绘选中色；LBPaint 会在隐藏 donor 钮上叠「我的书架」字
        if (!usedSoftScroll) {
            LBEnableTitleScroll(tv);
            LBAttachDiscoverKindButtonActions(host, tv);
            LBPaintTitleLabels(tv, sSelectedKindIndex);
        } else {
            LBAttachDiscoverKindButtonActions(host, tv);
        }
    } else {
        LBEnableTitleScroll(tv);
        LBAttachDiscoverKindButtonActions(host, tv);
        LBPaintTitleLabels(tv, sSelectedKindIndex);
    }
    if ([tv isKindOfClass:[UIView class]] && host.isViewLoaded && host.view) {
        UIView *title = (UIView *)tv;
        if (title.superview != host.view) {
            @try { [host.view addSubview:title]; } @catch (__unused NSException *e) {}
        }
        [host.view bringSubviewToFront:title];
        if (!sDiscoverTitleBarCollapsed) {
            title.hidden = NO;
            title.alpha = 1;
        }
        @try {
            host.view.backgroundColor = LBDiscoverPageColor();
        } @catch (__unused NSException *e) {}
    }

    LBAppendNativeMarker([NSString stringWithFormat:@"forceTitles n=%lu applied=%d",
                          (unsigned long)titles.count, applied ? 1 : 0]);
    // 只布局一次；禁止 0.2/0.7 连环 Reveal（灌书通知会再刷，叠在一起必闪）
    LBRevealDiscoverTitleAndListEx(host, YES);
    sApplyingKinds = prev;
    LBAttachDiscoverKindButtonActions(host, tv);
    LBUnlinkDiscoverTitleContent(host);
}

/// 默认分类：优先「个性推荐 / read_recommend」，其次带 session 的书山 API；
/// 禁止默认落到 fanqienovel.com/fqbookshelf（HTML 书架页 explore 常空，还会冲掉推荐请求）。
static NSInteger LBPreferredExploreKindIndex(NSArray *kinds) {
    if (![kinds isKindOfClass:[NSArray class]] || kinds.count == 0) return 0;
    NSInteger fallbackSession = -1;
    NSInteger fallbackNonShelf = -1;
    for (NSUInteger i = 0; i < kinds.count; i++) {
        id item = kinds[i];
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSString *url = item[@"url"];
        NSString *title = item[@"title"];
        if (![url isKindOfClass:[NSString class]] || url.length == 0) continue;
        NSString *ul = url.lowercaseString;
        NSString *tl = [title isKindOfClass:[NSString class]] ? title : @"";
        if ([ul containsString:@"fanqienovel.com/fqbookshelf"]) continue;
        if ([ul containsString:@"read_recommend"] || [tl containsString:@"个性推荐"]) {
            return (NSInteger)i;
        }
        if (fallbackSession < 0 && [ul containsString:@"session="] &&
            ([ul containsString:@"/read_"] || [ul containsString:@"vossc"] ||
             [ul containsString:@"gyks"])) {
            fallbackSession = (NSInteger)i;
        }
        if (fallbackNonShelf < 0) fallbackNonShelf = (NSInteger)i;
    }
    if (fallbackSession >= 0) return fallbackSession;
    if (fallbackNonShelf >= 0) return fallbackNonShelf;
    return 0;
}

/// 分类条跟当前 Legado 源 exploreUrl 解析结果走（换源即换分类），donor 只当壳
static NSArray *LBDedupExploreKinds(NSArray *kinds) {
    if (kinds.count == 0) return kinds;
    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (id item in kinds) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *dict = (NSDictionary *)item;
        NSString *title = dict[@"title"];
        if (![title isKindOfClass:[NSString class]] || title.length == 0) title = @"分类";
        NSString *url = dict[@"url"];
        if (![url isKindOfClass:[NSString class]]) url = @"";
        // B-03：按 (title, url) 去重，同名不同 URL 均保留（用 0x1F，勿写 \\u001F 字面量）
        NSString *key = [NSString stringWithFormat:@"%@%C%@", title, (unichar)0x1F, url];
        if ([seen containsObject:key]) continue;
        [seen addObject:key];
        [out addObject:dict];
    }
    return out.count > 0 ? out : kinds;
}

static void LBApplyLegadoSourceKindsToChrome(UIViewController *host, NSArray *kinds, NSString *srcName) {
    if (!host) return;
    if (LBIsDiscoverNativeXBSMode()) {
        LBAppendNativeMarker(@"applyKinds skip XBS");
        return;
    }
    kinds = LBDedupExploreKinds(kinds);
    NSMutableArray *titles = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (id item in kinds) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSString *t = item[@"title"];
        NSString *title = ([t isKindOfClass:[NSString class]] && t.length > 0) ? t : @"分类";
        NSString *u = item[@"url"];
        NSString *url = ([u isKindOfClass:[NSString class]]) ? u : @"";
        NSString *key = [NSString stringWithFormat:@"%@%C%@", title, (unichar)0x1F, url];
        if ([seen containsObject:key]) continue; // B-03：(title,url) 去重
        [seen addObject:key];
        [titles addObject:title];
    }
    if (titles.count == 0) [titles addObject:@"发现"];
    if (srcName.length > 0) {
        @try { host.navigationItem.title = srcName; } @catch (__unused NSException *e) {}
        @try { host.title = srcName; } @catch (__unused NSException *e) {}
    }
    // kinds≤1（单 URL exploreUrl）：对齐阅读——收起分类栏。即使下方跳过 ForceTitles 也要执行
    {
        id tvNow = nil;
        @try { tvNow = [host valueForKey:@"pageTitleView"]; } @catch (__unused NSException *e) {}
        if ([tvNow isKindOfClass:[UIView class]]) {
            LBSetDiscoverTitleBarCollapsed((UIView *)tvNow, titles.count <= 1);
        } else {
            sDiscoverTitleBarCollapsed = (titles.count <= 1);
        }
    }
    // 标题未变：跳过 ForceTitles（每次 Force 都会改层级 → 闪屏）。
    // 但要同时核对壳上当前标题：原生重建（createCons/resetContent）可能把标签刷回旧标题。
    NSArray *oldTitles = nil;
    if ([sCachedKinds isKindOfClass:[NSArray class]]) {
        NSMutableArray *ot = [NSMutableArray array];
        for (id item in sCachedKinds) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            NSString *t = item[@"title"];
            [ot addObject:([t isKindOfClass:[NSString class]] && t.length > 0) ? t : @"分类"];
        }
        oldTitles = ot;
    }
    BOOL sameTitles = (oldTitles.count == titles.count);
    if (sameTitles) {
        for (NSUInteger i = 0; i < titles.count; i++) {
            if (![oldTitles[i] isEqualToString:titles[i]]) { sameTitles = NO; break; }
        }
    }
    NSArray *shellTitles = nil;
    @try {
        id st = [host valueForKey:@"arrHeaderBtnTitle"];
        if ([st isKindOfClass:[NSArray class]]) shellTitles = (NSArray *)st;
    } @catch (__unused NSException *e) {}
    BOOL shellMatch = (shellTitles.count == titles.count);
    if (shellMatch) {
        for (NSUInteger i = 0; i < titles.count; i++) {
            id st = shellTitles[i];
            NSString *s = [st isKindOfClass:[NSString class]] ? (NSString *)st : @"";
            if (![s isEqualToString:titles[i]]) { shellMatch = NO; break; }
        }
    }
    if (!sameTitles || !shellMatch) {
        LBForceLegadoTitlesOnChrome(host, titles);
    } else {
        LBAppendNativeMarker(@"applySrcKinds skip same titles");
    }
    sCachedKinds = [kinds copy];
    // 换源/登录后重算默认选中：不要钉死 index0「我的书架」
    sSelectedKindIndex = LBPreferredExploreKindIndex(kinds);
    if (sSelectedKindIndex >= (NSInteger)titles.count) sSelectedKindIndex = 0;
    LBAppendNativeMarker([NSString stringWithFormat:@"applySrcKinds n=%lu src=%@ sel=%ld sample=%@",
                          (unsigned long)titles.count, srcName ?: @"", (long)sSelectedKindIndex,
                          [[titles subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)4, titles.count))]
                           componentsJoinedByString:@","]]);
}

/// 毁掉 BookListCon 子页，只留分类条（避免 viewDidLoad/拉网杀进程）
/// TC-07：Release 禁止 destroy；DEBUG 保留对照。
static void LBDestroyDiscoverListConsKeepTitle(UIViewController *host, id scroll) {
#if !DEBUG
    (void)host; (void)scroll;
    return;
#else
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
#endif
}

/// 清空原生子页书数据，但不动 UI/table（sanitize 后立刻 reload 会把标签墙撑乱）
/// TC-07：Release 禁止 sanitize-destroy 路径。
static void LBSanitizeDiscoverListCons(UIViewController *host, id scroll) {
#if !DEBUG
    (void)host; (void)scroll;
    return;
#else
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
        // 去掉误加的脏表；不 reload（避免白底空壳盖住原生黑底）
        if (vc.isViewLoaded && vc.view) {
            NSMutableArray *junk = [NSMutableArray array];
            for (UIView *sub in vc.view.subviews) {
                if ([sub isKindOfClass:[UITableView class]] && sub.tag == 0x4C424454) {
                    [junk addObject:sub];
                }
            }
            for (UIView *v in junk) [v removeFromSuperview];
        }
        n++;
    }
    LBAppendNativeMarker([NSString stringWithFormat:@"sanitizeListCons soft n=%lu raw=%lu",
                          (unsigned long)n, (unsigned long)kids.count]);
#endif
}

/// 用 Legado 分类灌原生发现：donor bookWorld + 一次性 resetContent（禁手工 SGPage）
static void LBFeedNativeDiscoverHeader(UIViewController *host, NSArray *kinds, NSString *srcName) {
    if (!host) return;
    if (LBIsDiscoverNativeXBSMode()) {
        LBAppendNativeMarker([NSString stringWithFormat:@"feedHeader skip XBS mode src=%@",
                              srcName ?: @"-"]);
        return;
    }
    LBRemoveDiscoverOverlays(host);

    NSMutableArray *titles = [NSMutableArray array];
    for (id item in kinds) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        [titles addObject:item[@"title"] ?: @"分类"];
    }
    if (titles.count == 0) [titles addObject:@"发现"];

    // 已建成原生 chrome：换源时仍刷新标题条为当前源 kinds
    if (sNativeChromeBuilt) {
        id existTitle = nil;
        id existScroll = nil;
        @try { existTitle = [host valueForKey:@"pageTitleView"]; } @catch (__unused NSException *e) {}
        @try { existScroll = [host valueForKey:@"pageContentScrollView"]; } @catch (__unused NSException *e) {}
        if (existTitle && existScroll) {
            LBApplyLegadoSourceKindsToChrome(host, kinds, srcName);
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
        // 仍先保证顶栏源名可见；分类标题等窗口就绪后随 kinds 建栏
        if (srcName.length > 0) {
            @try { host.navigationItem.title = srcName; } @catch (__unused NSException *e) {}
            @try { host.title = srcName; } @catch (__unused NSException *e) {}
        }
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
            LBApplyLegadoSourceKindsToChrome(host, kinds, srcName);
            LBAppendNativeMarker(@"pageChrome exists skipReset");
            LBAppendNativeHostState(host, @"keepChrome");
            return;
        }

        // TC-08L：Donor prepare 永久禁用（Release/Debug 均 nil）
        NSDictionary *prepared = nil;
        id bwObj = prepared[@"bookWorld"];
        NSUInteger bwKeys = [bwObj isKindOfClass:[NSDictionary class]] ? [(NSDictionary *)bwObj count] : 0;
#if DEBUG
        NSArray *donorTitles = LBDonorTitlesFromHost(host, prepared);
#else
        NSArray *donorTitles = @[];
#endif
        if (!prepared || bwKeys < 6) {
            // TC-07 Release：sanitized adapter → 宿主 `_dicModel` ivar（禁 donor/reset/createCons/setDicModel）
            NSDictionary *adapter = LBBuildLegadoAdapterModelFromCore(srcName);
            BOOL wrote = NO;
            if (adapter) {
                wrote = LBWriteLegadoAdapterToHost(host, adapter);
                LBAppendNativeMarker([NSString stringWithFormat:
                                      @"legadoAdapter snapshot=%@ state=%@ wrote=%d",
                                      adapter[@"snapshotID"] ?: @"-",
                                      adapter[@"state"] ?: @"-",
                                      wrote ? 1 : 0]);
            } else {
                LBAppendNativeMarker(@"legadoAdapter missing metadata");
            }
            if (srcName.length > 0) {
                @try { host.navigationItem.title = srcName; } @catch (__unused NSException *e) {}
                @try { host.title = srcName; } @catch (__unused NSException *e) {}
            }
            if (titles.count > 0) {
                @try { [host setValue:[titles copy] forKey:@"arrHeaderBtnTitle"]; } @catch (__unused NSException *e) {}
            }
            LBApplyLegadoSourceKindsToChrome(host, kinds, srcName);
            LBAppendNativeMarker([NSString stringWithFormat:
                                  @"shellFallback adapterPath keys=%lu wrote=%d",
                                  (unsigned long)bwKeys, wrote ? 1 : 0]);
            LBAppendNativeHostState(host, wrote ? @"adapterWired" : @"shellFallback");
            return;
        }
#if DEBUG
        LBAppendNativeMarker([NSString stringWithFormat:@"preparedBW keys=%lu useReset=1 donorTitles=%lu",
                              (unsigned long)bwKeys, (unsigned long)donorTitles.count]);

        // 必须在 resetContent 前装好：BookListCon viewDidLoad 会在挂页时立刻跑
        LBInstallBookListSafeViewDidLoad();

        NSString *consName = sDiscoverUseSourceName.length ? sDiscoverUseSourceName : (srcName ?: @"");
        if (titles.count > 0) {
            @try { [host setValue:[titles copy] forKey:@"arrHeaderBtnTitle"]; } @catch (__unused NSException *e) {}
        }
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
                              @"chromeCheck hostChild=%lu scrollKids=%lu safeVDL=%d",
                              (unsigned long)childN, (unsigned long)scrollKids,
                              sBookListSafeVDLInstalled ? 1 : 0]);

        // 顶栏 = 当前阅读书源 exploreUrl 分类（对齐阅读发现页），不再用 donor「男生/女频/出版」
        if (titles.count > 0) {
            @try { [host setValue:[titles copy] forKey:@"arrHeaderBtnTitle"]; } @catch (__unused NSException *e) {}
            LBAppendNativeMarker([NSString stringWithFormat:@"keepLegadoTitles n=%lu sample=%@",
                                  (unsigned long)titles.count,
                                  [[titles subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)4, titles.count))]
                                   componentsJoinedByString:@","]]);
        }
        // 缓存 Legado kinds 供点标签/切页时 explore
        sCachedKinds = [kinds copy];

        if (srcName.length > 0) {
            @try { host.navigationItem.title = srcName; } @catch (__unused NSException *e) {}
            @try { host.title = srcName; } @catch (__unused NSException *e) {}
        }

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
            // 保留原生 BookListCon 壳；分类条换成当前 Legado 源 kinds
            LBSanitizeDiscoverListCons(host, scroll);
            LBApplyLegadoSourceKindsToChrome(host, kinds, srcName);
            LBAppendNativeMarker([NSString stringWithFormat:
                                  @"keepNativeChrome hostChild=%lu scrollKids=%lu legadoKinds=%lu",
                                  (unsigned long)childN, (unsigned long)scrollKids,
                                  (unsigned long)kinds.count]);
            __weak UIViewController *weakHost = host;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (!LBIsDiscoverTabActive()) return;
                UIViewController *h = weakHost ?: LBPrimaryDiscoverHost();
                if (!h) return;
                id core = LBKindCore();
                NSString *src = LBCurrentExploreSourceUrl(core);
                NSString *kindUrl = nil;
                if (sCachedKinds.count > 0) {
                    NSInteger pref = LBPreferredExploreKindIndex(sCachedKinds);
                    sSelectedKindIndex = pref;
                    id u = (pref >= 0 && pref < (NSInteger)sCachedKinds.count)
                        ? sCachedKinds[(NSUInteger)pref][@"url"] : nil;
                    if ([u isKindOfClass:[NSString class]] && [(NSString *)u length] > 0) {
                        kindUrl = (NSString *)u;
                    }
                }
                LBAppendNativeMarker([NSString stringWithFormat:
                                      @"postChrome explore src=%@ kind=%@ pref=%ld",
                                      src ?: @"", kindUrl ?: @"", (long)sSelectedKindIndex]);
                if (src.length > 0) {
                    @try {
                        LBTriggerExploreKind(src, kindUrl);
                    } @catch (NSException *ex) {
                        LBAppendNativeMarker([NSString stringWithFormat:
                                              @"postChrome explore EX %@", ex.reason ?: @""]);
                    }
                }
                @try {
                    LBReloadDiscoverNativeList(h);
                } @catch (NSException *ex) {
                    LBAppendNativeMarker([NSString stringWithFormat:
                                          @"postChrome reload EX %@", ex.reason ?: @""]);
                }
                LBAppendNativeMarker(@"stillAlive keepNativeChrome");
            });
            sRestoreListMode = NO;
            sTitleOnlyStabilized = YES;
        }

        // createCons：reset 未挂子页时先造 cons，再交给原生 resetContent 挂页（禁手工 SGPage）
        // 标题 = 当前阅读书源 exploreUrl 分类（对齐阅读发现页）；createCons 会原地 addObject，必须给可变副本
        NSMutableArray *consTitles = [titles mutableCopy];
        if (consTitles.count == 0) consTitles = [NSMutableArray arrayWithObject:@"发现"];
        if (!sNativeChromeBuilt &&
            host.childViewControllers.count == 0 &&
            [host respondsToSelector:@selector(createCons:titles:sourceName:)]) {
            @try {
                NSMutableArray *cons = [NSMutableArray array];
                ((void (*)(id, SEL, id, id, id))objc_msgSend)(
                    host, @selector(createCons:titles:sourceName:), cons, consTitles, consName);
                LBAppendNativeMarker([NSString stringWithFormat:
                                      @"createCons fallback titles=%lu cons=%lu src=%@",
                                      (unsigned long)consTitles.count, (unsigned long)cons.count, consName]);
                if (cons.count > 0 && [host respondsToSelector:@selector(resetContent)]) {
                    // titles 与 cons 数量对齐
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
                        if (tn.length == 0 && i < consTitles.count) tn = consTitles[i];
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
        // 顶栏标题 = Legado kinds，选中索引按 kinds 数夹取
        NSUInteger kindCap = titles.count;
        if (sSelectedKindIndex >= (NSInteger)kindCap && kindCap > 0) sSelectedKindIndex = 0;

        // 顶栏仍显示 Legado 源名（donor 只用于建壳）
        if (srcName.length > 0) {
            @try { host.navigationItem.title = srcName; } @catch (__unused NSException *e) {}
            @try { host.title = srcName; } @catch (__unused NSException *e) {}
        }

        // 统一收口：收栏（kinds≤1）/重断言标题/选中态（幂等，标题未变时跳过 ForceTitles）
        LBApplyLegadoSourceKindsToChrome(host, kinds, srcName);

        LBAppendNativeMarker([NSString stringWithFormat:@"nativeHeader host=%@ src=%@ donor=%lu legadoKinds=%lu sel=%ld",
                              NSStringFromClass([host class]), srcName ?: @"",
                              (unsigned long)donorTitles.count, (unsigned long)kinds.count,
                              (long)sSelectedKindIndex]);
        LBAppendNativeHostState(host, @"feedDone");
#endif
    } @finally {
        sFeedingDiscoverHeader = NO;
    }
}

/// 在 host / scroll 子树里找最适合灌书的 UITableView（优先 BookListCon、非零 frame、非脏表）
static UITableView *LBFindBestDiscoverTable(UIViewController *host, UIViewController **outOwner) {
    static const NSInteger kLBDT = 0x4C424454;
    static const NSInteger kLBLT = 0x4C424C54;
    if (outOwner) *outOwner = nil;
    if (!host) return nil;

    NSMutableArray *owners = [NSMutableArray array];
    UIViewController *active = nil;
    @try { active = LBActiveDiscoverListVC(host); } @catch (__unused NSException *e) {}
    if (active) [owners addObject:active];

    id scroll = nil;
    @try { scroll = [host valueForKey:@"pageContentScrollView"]; } @catch (__unused NSException *e) {}
    for (NSString *k in @[@"childViewControllers", @"childVCs", @"arrChildVCs", @"vcs"]) {
        id cv = nil;
        @try { cv = [scroll valueForKey:k]; } @catch (__unused NSException *e) {}
        if (![cv isKindOfClass:[NSArray class]]) continue;
        for (id c in (NSArray *)cv) {
            UIViewController *vc = [c isKindOfClass:[UIViewController class]] ? c : nil;
            if (!vc) @try {
                id v = [c valueForKey:@"viewController"];
                if ([v isKindOfClass:[UIViewController class]]) vc = v;
            } @catch (__unused NSException *e) {}
            if (vc && ![owners containsObject:vc]) [owners addObject:vc];
        }
        if (owners.count > 1) break;
    }
    for (UIViewController *c in host.childViewControllers ?: @[]) {
        if (![owners containsObject:c]) [owners addObject:c];
    }
    if (![owners containsObject:host]) [owners addObject:host];

    // KVC childVCs 被掏空时，仍从可见视图树找回 BookListCon
    if (host.isViewLoaded && host.view) {
        NSMutableArray *q = [NSMutableArray arrayWithObject:host.view];
        NSInteger budget = 100;
        while (q.count > 0 && budget-- > 0) {
            UIView *cur = q.firstObject;
            [q removeObjectAtIndex:0];
            if ([cur isKindOfClass:[UITableView class]]) {
                UIViewController *owner = nil;
                for (UIResponder *r = cur; r; r = r.nextResponder) {
                    if ([r isKindOfClass:[UIViewController class]]) {
                        owner = (UIViewController *)r;
                        break;
                    }
                }
                if (owner && ![owners containsObject:owner]) [owners addObject:owner];
            }
            for (UIView *sub in cur.subviews) [q addObject:sub];
        }
    }

    UITableView *best = nil;
    UIViewController *bestOwner = nil;
    NSInteger bestScore = -1;
    for (UIViewController *vc in owners) {
        @try { (void)vc.view; } @catch (__unused NSException *e) {}
        NSMutableArray *cands = [NSMutableArray array];
        for (NSString *k in @[@"tableView", @"tv", @"listTableView", @"mainTableView", @"myTableView"]) {
            @try {
                id v = [vc valueForKey:k];
                if ([v isKindOfClass:[UITableView class]]) [cands addObject:v];
            } @catch (__unused NSException *e) {}
        }
        if (vc.isViewLoaded && vc.view) {
            NSMutableArray *q = [NSMutableArray arrayWithObject:vc.view];
            NSInteger budget = 60;
            while (q.count > 0 && budget-- > 0) {
                UIView *cur = q.firstObject;
                [q removeObjectAtIndex:0];
                if ([cur isKindOfClass:[UITableView class]]) [cands addObject:cur];
                for (UIView *sub in cur.subviews) [q addObject:sub];
            }
        }
        NSString *cn = NSStringFromClass([vc class]);
        BOOL isList = [cn containsString:@"BookList"];
        NSUInteger arrN = 0;
        @try {
            id a = [vc valueForKey:@"arrBaseData"];
            if ([a isKindOfClass:[NSArray class]]) arrN = [(NSArray *)a count];
        } @catch (__unused NSException *e) {}

        for (UITableView *tv in cands) {
            if (tv.tag == kLBDT) continue;
            NSInteger score = 0;
            if (tv.tag == kLBLT) score -= 20;
            if (isList) score += 50;
            if (arrN > 0) score += 30;
            if (tv.frame.size.width > 2 && tv.frame.size.height > 2) score += 20;
            else if (tv.bounds.size.width > 2 && tv.bounds.size.height > 2) score += 10;
            id ds = tv.dataSource;
            NSString *dsn = ds ? NSStringFromClass([ds class]) : @"";
            if ([dsn containsString:@"FilteredDataSource"]) score -= 5;
            if (ds == (id)vc) score += 5;
            if (score > bestScore) {
                bestScore = score;
                best = tv;
                bestOwner = vc;
            }
        }
    }
    if (outOwner) *outOwner = bestOwner;
    return best;
}

/// TC-08X：禁止 Bridge 改 table frame/hierarchy。仅允许摘掉错误挂在 host 上的空 LBLT overlay。
static void LBRepairDiscoverTableFrame(UIViewController *host, UIViewController *listVC, UITableView *tv) {
    (void)listVC;
    (void)tv;
    if (!host) return;
    static const NSInteger kLBLT = 0x4C424C54;
    if (host.isViewLoaded && host.view) {
        NSMutableArray *junk = [NSMutableArray array];
        for (UIView *sub in host.view.subviews) {
            if ([sub isKindOfClass:[UITableView class]] && sub.tag == kLBLT) {
                [junk addObject:sub];
            }
        }
        for (UIView *v in junk) {
            [v removeFromSuperview];
            LBAppendNativeMarker(@"ensureListSurface remove host LBLT");
        }
    }
    LBAppendNativeMarker(@"repairTableFrame skipped TC-08X no-frame-takeover");
}

/// 优先修复 BookListCon 原生表；仅无子页时才建 LBLT（禁止盖住分类条的全屏脏表）
UITableView *LBEnsureDiscoverListSurface(UIViewController *host) {
    if (LBIsDiscoverNativeXBSMode()) {
        // 纯 XBS：禁止自造/改写 table，交给原生 bookWorld 填表
        return nil;
    }
    if (!host) return nil;
    static const NSInteger kLBLT = 0x4C424C54; // 'LBLT'
    static const NSInteger kLBDT = 0x4C424454; // 'LBDT'

    UIViewController *listVC = nil;
    UITableView *tv = LBFindBestDiscoverTable(host, &listVC);
    if (!listVC) {
        @try { listVC = LBActiveDiscoverListVC(host); } @catch (__unused NSException *e) {}
    }
    if (!listVC) listVC = host;
    @try { (void)listVC.view; } @catch (__unused NSException *e) {}

    for (UIViewController *vc in @[listVC, host]) {
        if (!vc.isViewLoaded || !vc.view) continue;
        NSMutableArray *junk = [NSMutableArray array];
        for (UIView *sub in vc.view.subviews) {
            if ([sub isKindOfClass:[UITableView class]] && sub.tag == kLBDT) {
                [junk addObject:sub];
            }
        }
        for (UIView *v in junk) [v removeFromSuperview];
    }

    if (tv) {
        LBRepairDiscoverTableFrame(host, listVC, tv);
        @try {
            if (tv.backgroundColor == nil ||
                CGColorGetAlpha(tv.backgroundColor.CGColor) < 0.05 ||
                [tv.backgroundColor isEqual:[UIColor whiteColor]]) {
                tv.backgroundColor = LBDiscoverPageColor();
            }
        } @catch (__unused NSException *e) {}
        NSUInteger arrN = 0;
        @try {
            id a = [listVC valueForKey:@"arrBaseData"];
            if ([a isKindOfClass:[NSArray class]]) arrN = [(NSArray *)a count];
        } @catch (__unused NSException *e) {}
        id ds = tv.dataSource;
        NSString *dsn = ds ? NSStringFromClass([ds class]) : @"";
        BOOL isList = [NSStringFromClass([listVC class]) containsString:@"BookList"];
        BOOL brokenDS = (ds == nil) || [dsn containsString:@"FilteredDataSource"];
        // 有灌书时一律挂安全 DS/height（原生对字典常 0 高）
        if ((brokenDS || arrN > 0) && (isList || arrN > 0)) {
            LBEnsurePlazaListTableHooks([listVC class]);
            tv.dataSource = (id<UITableViewDataSource>)listVC;
            tv.delegate = (id<UITableViewDelegate>)listVC;
            tv.rowHeight = 108;
            tv.estimatedRowHeight = 108;
        LBAppendNativeMarker([NSString stringWithFormat:
                              @"ensureListSurface fixDS arr=%lu was=%@",
                              (unsigned long)arrN, dsn.length ? dsn : @"nil"]);
        }
        tv.scrollEnabled = YES;
        tv.userInteractionEnabled = YES;
        if (@available(iOS 11.0, *)) {
            tv.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
        }
        tv.contentInset = UIEdgeInsetsZero;
        LBAppendNativeMarker([NSString stringWithFormat:
                              @"ensureListSurface reuse tv=%.0fx%.0f@%.0f,%.0f tag=%ld owner=%@",
                              tv.frame.size.width, tv.frame.size.height,
                              tv.frame.origin.x, tv.frame.origin.y,
                              (long)tv.tag, NSStringFromClass([listVC class])]);
        return tv;
    }

    UIView *container = nil;
    CGRect frame = CGRectZero;
    NSString *lcn = NSStringFromClass([listVC class]);
    BOOL childList = (listVC != host) && [lcn containsString:@"BookList"];
    if (childList && listVC.isViewLoaded && listVC.view) {
        container = listVC.view;
        frame = container.bounds;
        if (frame.size.width < 2 || frame.size.height < 2) {
            id scroll = nil;
            @try { scroll = [host valueForKey:@"pageContentScrollView"]; } @catch (__unused NSException *e) {}
            if ([scroll isKindOfClass:[UIView class]]) {
                CGRect sf = [(UIView *)scroll bounds];
                if (sf.size.width > 2 && sf.size.height > 2) frame = sf;
            }
        }
    }
    if (!container || frame.size.width < 2 || frame.size.height < 2) {
        // 禁止在 BookWorld 宿主上建空 LBLT（会盖住已有 BookListCon 的书列表）
        UIViewController *bookList = nil;
        id scroll = nil;
        @try { scroll = [host valueForKey:@"pageContentScrollView"]; } @catch (__unused NSException *e) {}
        for (NSString *k in @[@"childViewControllers", @"childVCs"]) {
            id cv = nil;
            @try { cv = [scroll valueForKey:k]; } @catch (__unused NSException *e) {}
            if (![cv isKindOfClass:[NSArray class]]) continue;
            for (id c in (NSArray *)cv) {
                UIViewController *vc = [c isKindOfClass:[UIViewController class]] ? c : nil;
                if (!vc) continue;
                if ([NSStringFromClass([vc class]) containsString:@"BookList"]) {
                    bookList = vc;
                    break;
                }
            }
            if (bookList) break;
        }
        if (!bookList) {
            for (UIViewController *c in host.childViewControllers ?: @[]) {
                if ([NSStringFromClass([c class]) containsString:@"BookList"]) {
                    bookList = c;
                    break;
                }
            }
        }
        if (bookList) {
            @try { (void)bookList.view; } @catch (__unused NSException *e) {}
            listVC = bookList;
            container = bookList.view;
            frame = container.bounds;
            if (frame.size.width < 2 || frame.size.height < 2) {
                if ([scroll isKindOfClass:[UIView class]]) {
                    CGRect sf = [(UIView *)scroll bounds];
                    if (sf.size.width > 2 && sf.size.height > 2) frame = sf;
                }
            }
            if (frame.size.width < 2 || frame.size.height < 2) {
                frame = CGRectMake(0, 0, host.view.bounds.size.width,
                                   MAX(200, host.view.bounds.size.height - 132));
            }
            LBAppendNativeMarker(@"ensureListSurface LBLT inside BookListCon");
        } else {
            LBAppendNativeMarker(@"ensureListSurface skip host LBLT (no BookList)");
            return nil;
        }
    }

    UITableView *neu = [[UITableView alloc] initWithFrame:frame style:UITableViewStylePlain];
    neu.tag = kLBLT;
    neu.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    neu.backgroundColor = LBDiscoverPageColor();
    neu.separatorColor = LBDiscoverSeparatorColor();
    neu.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
    neu.rowHeight = 88;
    LBEnsurePlazaListTableHooks([listVC class]);
    neu.dataSource = (id<UITableViewDataSource>)listVC;
    neu.delegate = (id<UITableViewDelegate>)listVC;
    [container addSubview:neu];
    @try { [listVC setValue:neu forKey:@"tableView"]; } @catch (__unused NSException *e) {}
    @try {
        if (container.backgroundColor == nil ||
            [container.backgroundColor isEqual:[UIColor whiteColor]] ||
            [container.backgroundColor isEqual:[UIColor clearColor]]) {
            container.backgroundColor = LBDiscoverPageColor();
        }
    } @catch (__unused NSException *e) {}
    if (container == host.view) {
        id titleView = nil;
        @try { titleView = [host valueForKey:@"pageTitleView"]; } @catch (__unused NSException *e) {}
        if ([titleView isKindOfClass:[UIView class]]) {
            [container bringSubviewToFront:(UIView *)titleView];
        }
    }
    LBAppendNativeMarker([NSString stringWithFormat:
                          @"ensureListSurface LBLT %.0fx%.0f@%.0f,%.0f feed=%@",
                          frame.size.width, frame.size.height,
                          frame.origin.x, frame.origin.y,
                          NSStringFromClass([listVC class])]);
    return neu;
}

/// XBS：只软刷原生表/集合视图，禁止叠 Legado overlay / Reveal。
/// 禁止对 VC 调 refresh/loadData：会清空 arrBaseData 并重入网络，
/// 与 resetContent 后的原生刷新竞态 → 一直「正在刷新」且 arrN=0。
static void LBSoftReloadNativeDiscoverTables(UIViewController *root) {
    if (!root) return;
    NSMutableArray<UIViewController *> *stack = [NSMutableArray arrayWithObject:root];
    NSInteger tvN = 0;
    while (stack.count > 0) {
        UIViewController *vc = stack.firstObject;
        [stack removeObjectAtIndex:0];
        for (UIViewController *ch in vc.childViewControllers) {
            [stack addObject:ch];
        }
        if (vc.presentedViewController) [stack addObject:vc.presentedViewController];
        // 仅 UI 层 reloadData；不触达 refresh/loadData（原生拉书中）
        if (!vc.isViewLoaded) continue;
        NSMutableArray<UIView *> *views = [NSMutableArray arrayWithObject:vc.view];
        while (views.count > 0) {
            UIView *v = views.firstObject;
            [views removeObjectAtIndex:0];
            for (UIView *sub in v.subviews) [views addObject:sub];
            if ([v isKindOfClass:[UITableView class]]) {
                @try { [(UITableView *)v reloadData]; tvN += 1; } @catch (__unused NSException *e) {}
            } else if ([v isKindOfClass:[UICollectionView class]]) {
                @try { [(UICollectionView *)v reloadData]; tvN += 1; } @catch (__unused NSException *e) {}
            }
        }
    }
    LBAppendNativeMarker([NSString stringWithFormat:@"reload XBS soft tvOrCv=%ld pendingWas=%d noNet",
                          (long)tvN, sXBSPendingNativeRefresh ? 1 : 0]);
}

/// 书列表灌入后：软刷新；无表时建 LBLT（不建 LBDT 全屏脏表）
void LBReloadDiscoverNativeList(UIViewController *host) {
    if (!host) return;
    if (LBIsDiscoverNativeXBSMode()) {
        // 纯 XBS：只写探针，禁止任何 reloadData/refresh/fixDS。
        // 真机：软刷会与原生「正在刷新」竞态 → arrN 长期 0、分类墙空转。
        @try {
            UIViewController *list = LBActiveDiscoverListVC(host) ?: host;
            NSInteger n = -1;
            id a = [list valueForKey:@"arrBaseData"];
            if ([a isKindOfClass:[NSArray class]]) n = (NSInteger)[(NSArray *)a count];
            NSString *probe = [NSString stringWithFormat:
                               @"reloadXBS class=%@ arrN=%ld hostName=%@ noop",
                               NSStringFromClass([list class]), (long)n,
                               LBReadHostSourceName(host) ?: @"-"];
            [probe writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_clear_probe.txt"]
                   atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            if (n > 0 && [a isKindOfClass:[NSArray class]]) {
                id first = [(NSArray *)a firstObject];
                NSString *shape = @"?";
                if ([first isKindOfClass:[NSDictionary class]]) {
                    NSDictionary *d = (NSDictionary *)first;
                    NSArray *ks = d.allKeys ?: @[];
                    id bn = d[@"bookName"] ?: d[@"name"] ?: d[@"title"];
                    id bu = d[@"bookUrl"] ?: d[@"url"];
                    NSString *keyJoin = [ks componentsJoinedByString:@","];
                    if (keyJoin.length > 180) keyJoin = [keyJoin substringToIndex:180];
                    shape = [NSString stringWithFormat:@"dict keys=%lu bookName=%@ bookUrl=%@ sample=%@",
                             (unsigned long)ks.count,
                             [bn isKindOfClass:[NSString class]] ? bn : @"-",
                             [bu isKindOfClass:[NSString class]] ? bu : @"-",
                             keyJoin ?: @""];
                } else {
                    shape = [NSString stringWithFormat:@"%@ %@",
                             NSStringFromClass([first class]), first ?: @""];
                }
                [shape writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_xbs_arr_shape.txt"]
                        atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            }
            LBAppendNativeMarker([NSString stringWithFormat:
                                  @"reload XBS noop arrN=%ld pendingWas=%d",
                                  (long)n, sXBSPendingNativeRefresh ? 1 : 0]);
        } @catch (__unused NSException *e) {}
        sXBSPendingNativeRefresh = NO;
        return;
    }
    static const NSInteger kLBFO = 0x4C42464F;
    UITableView *overlay = nil;
    if (host.isViewLoaded) {
        for (UIView *sub in host.view.subviews) {
            if ([sub isKindOfClass:[UITableView class]] && sub.tag == kLBFO) {
                overlay = (UITableView *)sub;
                break;
            }
        }
    }
    // 叠表已在：只 reload，禁止再走全量 Reveal（注入回调高频 → 闪屏）
    if (overlay) {
        UIViewController *listVC = LBActiveDiscoverListVC(host) ?: host;
        overlay.dataSource = (id<UITableViewDataSource>)listVC;
        overlay.delegate = (id<UITableViewDelegate>)listVC;
        overlay.scrollEnabled = YES;
        @try { [overlay reloadData]; } @catch (__unused NSException *e) {}
        return;
    }
    LBRevealDiscoverTitleAndListEx(host, YES);
    UITableView *tv = LBEnsureDiscoverListSurface(host);
    if (!tv) {
        LBAppendNativeMarker(@"reload skip: no list surface");
        return;
    }
    @try {
        BOOL isLBLT = (tv.tag == 0x4C424C54);
        if (isLBLT && (!tv.dataSource || tv.dataSource == (id)[NSNull null])) {
            UIViewController *listVC = LBActiveDiscoverListVC(host) ?: host;
            LBEnsurePlazaListTableHooks([listVC class]);
            tv.dataSource = (id<UITableViewDataSource>)listVC;
            tv.delegate = (id<UITableViewDelegate>)listVC;
        }
        [tv reloadData];
    } @catch (NSException *ex) {
        LBAppendNativeMarker([NSString stringWithFormat:@"reload soft EX %@", ex.reason ?: @""]);
    }
}

static void LBDiscover_pageTitleSelected(id self, SEL _cmd, id pageTitleView, NSInteger index) {
    BOOL discoverCtx = LBIsDiscoverTabActive() || sNativeChromeBuilt || LBSelfLooksDiscoverWorldHost(self);
    if (!discoverCtx) {
        if (sOrig_pageTitleSelected) {
            sOrig_pageTitleSelected(self, _cmd, pageTitleView, index);
        }
        return;
    }
    // 纯原生发现：完全放行 SGPageTitleView + createCons 翻页，禁止钉页/explore
    if (LBIsDiscoverNativeXBSMode()) {
        if (sOrig_pageTitleSelected) {
            @try {
                sOrig_pageTitleSelected(self, _cmd, pageTitleView, index);
            } @catch (NSException *ex) {
                LBAppendNativeMarker([NSString stringWithFormat:@"pageTitle XBS orig EX %@",
                                      ex.reason ?: @""]);
            }
        }
        LBAppendNativeMarker([NSString stringWithFormat:@"pageTitle XBS passthrough idx=%ld",
                              (long)index]);
        return;
    }
    if (index < 0 || index > 512) {
        LBAppendNativeMarker([NSString stringWithFormat:@"pageTitle drop badIdx=%ld", (long)index]);
        return;
    }
    // 单列表灌书：不走原生翻页（会翻到空兄弟页），只换 Legado explore
    UIViewController *host = [self isKindOfClass:[UIViewController class]]
        ? (UIViewController *)self : LBPrimaryDiscoverHost();
    if (LBDiscoverSingleListFeed()) {
        LBDiscoverHandleKindSelect(host, pageTitleView, index);
        return;
    }
    if (sOrig_pageTitleSelected) {
        @try {
            sOrig_pageTitleSelected(self, _cmd, pageTitleView, index);
        } @catch (NSException *ex) {
            LBAppendNativeMarker([NSString stringWithFormat:@"pageTitle orig EX %@",
                                  ex.reason ?: @""]);
        }
    }
    sSelectedKindIndex = MAX(0, index);
    LBSetDiscoverTabActive(YES);
    LBDiscoverFireExploreForIndex(index, nil);
    if (host) {
        __weak UIViewController *weakHost = host;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIViewController *h = weakHost;
            if (!h || !LBIsDiscoverTabActive()) return;
            if (LBIsDiscoverNativeXBSMode()) return;
            LBReloadDiscoverNativeList(h);
        });
    }
}

static void LBDiscover_onHeaderBtn(id self, SEL _cmd, id sender) {
    // 标签墙点击：先走原生；Legado 态再按按钮标题匹配 kind
    if (sOrig_onHeaderBtn) {
        @try {
            sOrig_onHeaderBtn(self, _cmd, sender);
        } @catch (NSException *ex) {
            LBAppendNativeMarker([NSString stringWithFormat:@"headerBtn orig EX %@",
                                  ex.reason ?: @""]);
        }
    }
    BOOL discoverCtx = LBIsDiscoverTabActive() || sNativeChromeBuilt || LBSelfLooksDiscoverWorldHost(self);
    if (!discoverCtx) return;
    if (LBIsDiscoverNativeXBSMode()) {
        LBAppendNativeMarker(@"headerBtn XBS passthrough only");
        // 点标签后延迟看 arrBaseData：区分「原生未拉」与「有数据未渲染」
        UIViewController *probeHost = [self isKindOfClass:[UIViewController class]]
            ? (UIViewController *)self : LBPrimaryDiscoverHost();
        __weak UIViewController *weakHost = probeHost;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIViewController *h = weakHost;
            if (!h || !LBIsDiscoverNativeXBSMode()) return;
            NSInteger n = -1;
            NSUInteger bwN = 0;
            @try {
                UIViewController *list = LBActiveDiscoverListVC(h) ?: h;
                id a = [list valueForKey:@"arrBaseData"];
                if ([a isKindOfClass:[NSArray class]]) n = (NSInteger)[(NSArray *)a count];
                id dm = [h valueForKey:@"dicModel"];
                if ([dm isKindOfClass:[NSDictionary class]]) {
                    id bw = ((NSDictionary *)dm)[@"bookWorld"];
                    if ([bw isKindOfClass:[NSDictionary class]]) bwN = [(NSDictionary *)bw count];
                }
            } @catch (__unused NSException *e) {}
            LBAppendNativeMarker([NSString stringWithFormat:
                                  @"headerBtn probe arrN=%ld bw=%lu",
                                  (long)n, (unsigned long)bwN]);
        });
        return;
    }

    NSString *title = nil;
    NSInteger tagIdx = -1;
    if ([sender isKindOfClass:[UIButton class]]) {
        UIButton *btn = (UIButton *)sender;
        title = btn.currentTitle;
        if (title.length == 0) title = [btn titleForState:UIControlStateNormal];
        if (title.length == 0) title = btn.titleLabel.text;
        if (btn.tag >= 0 && btn.tag < 64) tagIdx = btn.tag;
    } else if ([sender isKindOfClass:[UIView class]]) {
        tagIdx = [(UIView *)sender tag];
        @try {
            id t = [sender valueForKey:@"title"];
            if ([t isKindOfClass:[NSString class]]) title = t;
        } @catch (__unused NSException *e) {}
    }
    LBAppendNativeMarker([NSString stringWithFormat:@"headerBtn title=%@ tag=%ld",
                          title ?: @"-", (long)tagIdx]);
    LBSetDiscoverTabActive(YES);
    NSInteger exploreIdx = (tagIdx >= 0) ? tagIdx : sSelectedKindIndex;
    LBDiscoverFireExploreForIndex(exploreIdx, title);
    UIViewController *host = [self isKindOfClass:[UIViewController class]]
        ? (UIViewController *)self : nil;
    if (!host || ![NSStringFromClass([host class]) containsString:@"BookWorld"]) {
        host = LBPrimaryDiscoverHost();
    }
    if (host) {
        __weak UIViewController *weakHost = host;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIViewController *h = weakHost;
            if (!h || !LBIsDiscoverTabActive()) return;
            if (LBIsDiscoverNativeXBSMode()) return;
            LBReloadDiscoverNativeList(h);
        });
    }
}

/// 从 dicModel 取展示源名（原生切换常先改模型再改 title）
static NSString *LBNameFromDicModel(id model) {
    if (![model isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *dic = (NSDictionary *)model;
    for (NSString *k in @[@"cf_title", @"title", @"sourceName", @"bookSourceName"]) {
        id v = dic[k];
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) {
            return LBNormalizeSourceDisplayName((NSString *)v) ?: (NSString *)v;
        }
    }
    return nil;
}

/// 点「切换」后持续轮询：用户常在列表里停留 >2.4s，单次延时会 miss 掉确认
static void LBScheduleDiscoverSwitchPoll(UIViewController *host, NSString *beforeName) {
    NSString *beforeCopy = [beforeName copy] ?: @"";
    NSString *beforeNorm = LBNormalizeSourceDisplayName(beforeCopy) ?: beforeCopy;
    NSInteger gen = ++sSwitchPollGeneration;
    __weak UIViewController *weakHost = host;
    // 0.5s × 40 ≈ 20s，覆盖长列表翻找
    __block void (^tick)(NSInteger) = nil;
    tick = ^(NSInteger attempt) {
        if (gen != sSwitchPollGeneration) return;
        UIViewController *h = weakHost ?: LBPrimaryDiscoverHost();
        if (!h) return;
        if (!LBIsDiscoverTabActive() && !LBSelfLooksDiscoverWorldHost(h)) return;
        NSString *name = LBReadHostSourceName(h);
        NSString *cf = nil;
        @try {
            id dic = [h valueForKey:@"dicModel"];
            cf = LBNameFromDicModel(dic);
        } @catch (__unused NSException *e) {}
        NSString *cand = nil;
        NSString *nameNorm = LBNormalizeSourceDisplayName(name);
        if (nameNorm.length > 0 &&
            ![nameNorm isEqualToString:@"切换站点"] &&
            ![nameNorm isEqualToString:@"书源"] &&
            ![nameNorm isEqualToString:@"发现"] &&
            ![nameNorm isEqualToString:beforeNorm]) {
            cand = nameNorm;
        } else if (cf.length > 0 && ![cf isEqualToString:beforeNorm]) {
            cand = cf;
        }
        if (cand.length > 0) {
            LBAppendNativeMarker([NSString stringWithFormat:
                                  @"switchPoll hit attempt=%ld before=%@ after=%@",
                                  (long)attempt, beforeCopy, cand]);
            LBHandleDiscoverSourceSwitched(h, cand);
            return;
        }
        if (attempt >= 40) {
            LBAppendNativeMarker([NSString stringWithFormat:
                                  @"switchPoll timeout before=%@ name=%@ cf=%@",
                                  beforeCopy, name ?: @"-", cf ?: @"-"]);
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            tick(attempt + 1);
        });
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        tick(1);
    });
}

static NSString *LBReadHostSourceName(UIViewController *host) {
    if (!host) return nil;
    NSString *name = nil;
    @try {
        id v = [host valueForKey:@"useSourceName"];
        if ([v isKindOfClass:[NSString class]]) name = v;
    } @catch (__unused NSException *e) {}
    if (name.length == 0) @try { name = host.navigationItem.title; } @catch (__unused NSException *e) {}
    if (name.length == 0) @try { name = host.title; } @catch (__unused NSException *e) {}
    return name;
}

static void LBDiscover_onSwitchBtn(id self, SEL _cmd) {
    // 发现态也走香色原生切换（XBS + 已同步的 Legado），禁止自造 ActionSheet
    UIViewController *host = [self isKindOfClass:[UIViewController class]]
        ? (UIViewController *)self : LBPrimaryDiscoverHost();
    NSString *before = LBReadHostSourceName(host);
    if (sOrig_onSwitchBtn) {
        sOrig_onSwitchBtn(self, _cmd);
    }
    LBScheduleDiscoverSwitchPoll(host, before);
}

static void LBDiscover_onSwitchBtnArg(id self, SEL _cmd, id sender) {
    UIViewController *host = [self isKindOfClass:[UIViewController class]]
        ? (UIViewController *)self : LBPrimaryDiscoverHost();
    NSString *before = LBReadHostSourceName(host);
    if (sOrig_onSwitchBtnArg) {
        sOrig_onSwitchBtnArg(self, _cmd, sender);
    } else if (sOrig_onSwitchBtn) {
        sOrig_onSwitchBtn(self, @selector(onSwitchBtnEvent));
    }
    LBScheduleDiscoverSwitchPoll(host, before);
}

/// 按源名在可发现 Legado 列表里找 url；找不到返回 nil（视为纯 XBS）
static NSString *LBFindLegadoExploreUrlByName(NSString *name) {
    if (name.length == 0) return nil;
    NSString *want = LBNormalizeSourceDisplayName(name);
    if (want.length == 0) want = name;
    id core = LBKindCore();
    if (!core) return nil;
    NSArray *rows = LBParseJSONArray(
        ([core respondsToSelector:@selector(exploreCapableSourcesJSON)]
         ? [core valueForKey:@"exploreCapableSourcesJSON"] : @"[]"));
    // 仅凭显示名不能判定 Legado：XBS 与导入源同名时，必须确认命中的
    // Registry 条目本身仍是 legadoBridge 标记。否则会把原生 bookWorld
    // 切成 Legado surface，后续发现和阅读都会走错链路。
    BOOL hasLegadoIdentity = LBLegadoIsSourceName(want);
    if (!hasLegadoIdentity) {
        for (id row in rows) {
            if (![row isKindOfClass:[NSDictionary class]]) continue;
            NSString *rawName = row[@"name"];
            NSString *normalized = LBNormalizeSourceDisplayName(rawName);
            if (normalized.length > 0 && [normalized isEqualToString:want] &&
                [rawName isKindOfClass:[NSString class]] &&
                LBLegadoIsSourceName(rawName)) {
                hasLegadoIdentity = YES;
                break;
            }
        }
    }
    if (!hasLegadoIdentity) {
        LBAppendNativeMarker([NSString stringWithFormat:
                              @"resolveLegado skip native name=%@", want]);
        return nil;
    }
    // 1) 精确匹配
    for (id row in rows) {
        if (![row isKindOfClass:[NSDictionary class]]) continue;
        NSString *n = LBNormalizeSourceDisplayName(row[@"name"]);
        NSString *u = row[@"url"];
        if (n.length == 0 || ![u isKindOfClass:[NSString class]]) continue;
        if ([n isEqualToString:want]) return u;
    }
    // 2) 双向包含，但要求较短方长度 >= 4，避免「书」这种误伤
    for (id row in rows) {
        if (![row isKindOfClass:[NSDictionary class]]) continue;
        NSString *n = LBNormalizeSourceDisplayName(row[@"name"]);
        NSString *u = row[@"url"];
        if (n.length == 0 || ![u isKindOfClass:[NSString class]]) continue;
        NSUInteger minLen = MIN(n.length, want.length);
        if (minLen < 4) continue;
        if ([n containsString:want] || [want containsString:n]) return u;
    }
    return nil;
}

/// 原生切换书源完成后：Legado → 按该源 exploreUrl 刷新分类+灌书；XBS → 保留原生 bookWorld，清 Legado 残留
static void LBHandleDiscoverSourceSwitched(UIViewController *host, NSString *sourceName) {
    if (!host || sourceName.length == 0) return;
    if (sHandlingDiscoverSwitch) return;
    // onOk 已切源成功时停掉 switchPoll，避免 timeout 误报与二次 Handle
    sSwitchPollGeneration++;
    sHandlingDiscoverSwitch = YES;
    @try {
    LBSetDiscoverTabActive(YES);
    sSelectedKindIndex = 0;
    sLastFeedSig = nil;
    sLastRevealSig = nil;
    sLastRevealArrN = -1;
    NSString *cleanName = LBNormalizeSourceDisplayName(sourceName) ?: sourceName;
    sDiscoverUseSourceName = [cleanName copy];
    sLastHandledSwitchName = [cleanName copy];

    @try { host.navigationItem.title = cleanName; } @catch (__unused NSException *e) {}
    @try { host.title = cleanName; } @catch (__unused NSException *e) {}
    @try { [host setValue:cleanName forKey:@"useSourceName"]; } @catch (__unused NSException *e) {}
    @try { [host setValue:cleanName forKey:@"lastSourceName"]; } @catch (__unused NSException *e) {}
    @try { [host setValue:cleanName forKey:@"sourceName"]; } @catch (__unused NSException *e) {}

    NSString *legadoUrl = LBFindLegadoExploreUrlByName(cleanName);
    // 只按「可发现 Legado 名」判定；禁止看残留 dicModel 的 fromLegadoBridge（切 XBS 后仍可能带）
    BOOL isLegado = (legadoUrl.length > 0);

    LBAppendNativeMarker([NSString stringWithFormat:
                          @"nativeSwitch name=%@ clean=%@ legado=%d url=%@",
                          sourceName, cleanName, isLegado ? 1 : 0, legadoUrl ?: @"-"]);

    if (!isLegado) {
        LBSharedRouterApplySelection(1, cleanName, cleanName, LBDiscoverOwnerIdentity(host), NO);
        LBSetDiscoverNativeXBSMode(YES);
        sCachedKinds = nil;
        sNativeChromeBuilt = NO; // 丢掉 Legado 建的壳，让原生 openConfig 重建 bookWorld
        // 只清 Legado pending/灌行，禁止掏空整表结构
        @try { LBClearDiscoverExplorePendingOnly(); } @catch (__unused NSException *e) {}
        @try { LBClearNativeReadingBridgeState(); } @catch (__unused NSException *e) {}
        id core = LBKindCore();
        if (core) {
            @try { [core setValue:nil forKey:@"selectedExploreSourceUrl"]; } @catch (__unused NSException *e) {}
        }
        // 再跑原生重建（openConfig 常 noSel → setDicModel+resetContent）
        BOOL opened = NO;
        @try { opened = LBRestoreNativeXBSChrome(host, cleanName); } @catch (__unused NSException *e) {}
        LBAppendNativeMarker([NSString stringWithFormat:
                              @"nativeSwitch XBS mode=1 name=%@ openCfg=%d",
                              cleanName, opened ? 1 : 0]);
        // 纯 XBS：resetContent 后交给原生拉书，禁止延迟 LBReload（会 noop/扰刷新）
        return;
    }

    sNativeChromeBuilt = NO; // 允许 Feed 重建被原生掏空的 chrome
    id core = LBKindCore();
    if (core && legadoUrl.length > 0) {
        @try { [core setValue:legadoUrl forKey:@"selectedExploreSourceUrl"]; } @catch (__unused NSException *e) {}
        if ([core respondsToSelector:@selector(warmupExploreKindsForSourceUrl:)]) {
            ((void (*)(id, SEL, NSString *))objc_msgSend)(
                core, @selector(warmupExploreKindsForSourceUrl:), legadoUrl);
        }
    }
    NSArray *kinds = @[];
    if (core && legadoUrl.length > 0 &&
        [core respondsToSelector:@selector(exploreKindsJSONForSourceUrl:)]) {
        NSString *kj = ((NSString *(*)(id, SEL, NSString *))objc_msgSend)(
            core, @selector(exploreKindsJSONForSourceUrl:), legadoUrl);
        kinds = LBParseJSONArray(kj);
    }
    // openConfig 常把分类条顶到 y=0、列表子页掏空 → 白屏；先修 chrome 再保列表面
    if (host.isViewLoaded && host.view) {
        @try {
            if ([host.view.backgroundColor isEqual:[UIColor whiteColor]] ||
                host.view.backgroundColor == nil) {
                host.view.backgroundColor = LBDiscoverPageColor();
            }
        } @catch (__unused NSException *e) {}
    }
    // 完整灌头（donor BW + resetContent）；禁止只 ForceTitles（原生切 DOM 壳后常无 pageTitle/scroll）
    LBFeedNativeDiscoverHeader(host, kinds, cleanName);
    UITableView *surface = LBEnsureDiscoverListSurface(host);
    NSString *kindUrl = nil;
    BOOL deferExploreUntilKinds = NO;
    if (kinds.count > 0) {
        NSInteger pref = LBPreferredExploreKindIndex(kinds);
        sSelectedKindIndex = pref;
        id u = (pref >= 0 && pref < (NSInteger)kinds.count) ? kinds[(NSUInteger)pref][@"url"] : nil;
        if ([u isKindOfClass:[NSString class]] && [(NSString *)u length] > 0) {
            kindUrl = (NSString *)u;
        }
    } else if (legadoUrl.length > 0) {
        // 顶层 JS exploreUrl：kinds 异步预热中，禁止立刻 explore(nil)
        deferExploreUntilKinds = YES;
        BOOL coolFail = NO;
        id coreWarm = LBKindCore();
        if (coreWarm &&
            [coreWarm respondsToSelector:@selector(isExploreKindsWarmFailedRecentlyForSourceUrl:)]) {
            coolFail = ((BOOL (*)(id, SEL, NSString *))objc_msgSend)(
                coreWarm, @selector(isExploreKindsWarmFailedRecentlyForSourceUrl:), legadoUrl);
        }
        if (coolFail) {
            LBShowDiscoverExploreEmptyHint(@"分类加载失败，请稍后重试或切换书源");
        } else {
            LBShowDiscoverExploreEmptyHint(@"分类加载中，请稍后…");
        }
    }
    LBAppendNativeMarker([NSString stringWithFormat:
                          @"nativeSwitch Legado kinds=%lu kind0=%@ sel=%ld surface=%d defer=%d",
                          (unsigned long)kinds.count, kindUrl ?: @"-",
                          (long)sSelectedKindIndex, surface ? 1 : 0,
                          deferExploreUntilKinds ? 1 : 0]);
    if (legadoUrl.length == 0) return;
    if (deferExploreUntilKinds) return;
    NSString *srcCopy = [legadoUrl copy];
    NSString *kindCopy = [kindUrl copy];
    __weak UIViewController *weakHost = host;
    // 只 explore 一次；勿再 ForceTitles（会拆层级）。clear 已在 Core 内防抖。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIViewController *h = weakHost;
        if (!h || !LBIsDiscoverTabActive()) return;
        if (LBIsDiscoverNativeXBSMode()) return;
        LBEnsureDiscoverListSurface(h);
        LBTriggerExploreKind(srcCopy, kindCopy);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIViewController *h2 = weakHost;
            if (!h2 || !LBIsDiscoverTabActive()) return;
            if (LBIsDiscoverNativeXBSMode()) return;
            LBEnsureDiscoverListSurface(h2);
            LBReloadDiscoverNativeList(h2);
            id tv = nil;
            @try { tv = [h2 valueForKey:@"pageTitleView"]; } @catch (__unused NSException *e) {}
            if (tv) LBPaintTitleLabels(tv, sSelectedKindIndex);
        });
    });
    } @finally {
        sHandlingDiscoverSwitch = NO;
    }
}

static void LBDiscover_openConfigByName(id self, SEL _cmd, NSString *name) {
    LBAppendNativeMarker([NSString stringWithFormat:@"openConfigByName enter name=%@ feeding=%d handling=%d",
                          name ?: @"-", sFeedingDiscoverHeader ? 1 : 0, sHandlingDiscoverSwitch ? 1 : 0]);
    if (sOrig_openConfigByName) {
        sOrig_openConfigByName(self, _cmd, name);
    }
    // 建壳 / 正在 Handle 内主动 openConfig：不算二次用户切换
    if (sFeedingDiscoverHeader || sHandlingDiscoverSwitch) return;
    if (!(LBIsDiscoverTabActive() || sNativeChromeBuilt || LBSelfLooksDiscoverWorldHost(self))) return;
    if (![name isKindOfClass:[NSString class]] || name.length == 0) return;
    // 纯 XBS：同名旁路；换源仍 Handle（与 setDicModel 一致）
    NSString *norm = LBNormalizeSourceDisplayName(name) ?: name;
    if (!LBLegadoIsSourceName(norm)) {
        UIViewController *hostX = [self isKindOfClass:[UIViewController class]]
            ? (UIViewController *)self : LBPrimaryDiscoverHost();
        NSString *cur = LBReadHostSourceName(hostX);
        NSString *curN = LBNormalizeSourceDisplayName(cur) ?: cur;
        BOOL same = (curN.length > 0 &&
                     ([curN isEqualToString:norm] ||
                      [curN containsString:norm] || [norm containsString:curN]));
        if (same) {
            LBAppendNativeMarker([NSString stringWithFormat:
                                  @"openConfigByName XBS passthrough same name=%@", norm]);
            return;
        }
        LBAppendNativeMarker([NSString stringWithFormat:
                              @"openConfigByName XBS switch %@ → %@",
                              curN ?: @"-", norm]);
        NSString *nameCopy = [name copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            LBHandleDiscoverSourceSwitched(hostX, nameCopy);
        });
        return;
    }
    UIViewController *host = [self isKindOfClass:[UIViewController class]]
        ? (UIViewController *)self : LBPrimaryDiscoverHost();
    NSString *nameCopy = [name copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        LBHandleDiscoverSourceSwitched(host, nameCopy);
    });
}

/// 原生切换确认常走 setDicModel 而未必再点切换钮；openConfig 又常 noSel → 必须在此接住
static void LBDiscover_setDicModel(id self, SEL _cmd, id model) {
    if (sOrig_setDicModel) {
        sOrig_setDicModel(self, _cmd, model);
    } else {
        @try { [self setValue:model forKey:@"dicModel"]; } @catch (__unused NSException *e) {}
    }
    if (sFeedingDiscoverHeader || sHandlingDiscoverSwitch) return;
    BOOL hostLooks = LBSelfLooksDiscoverWorldHost(self);
    BOOL hasNativeBW = NO;
    if ([model isKindOfClass:[NSDictionary class]]) {
        id bw = ((NSDictionary *)model)[@"bookWorld"];
        if ([bw isKindOfClass:[NSDictionary class]] && [(NSDictionary *)bw count] >= 3) {
            hasNativeBW = YES;
        }
    }
    // T2：发现宿主 / 带 bookWorld 的原生切源都要接住（勿仅依赖 DiscoverTabActive）
    if (!(LBIsDiscoverTabActive() || hostLooks || hasNativeBW)) return;
    NSString *name = LBNameFromDicModel(model);
    if (name.length == 0) return;
    NSString *norm = LBNormalizeSourceDisplayName(name) ?: name;
    if ([norm isEqualToString:@"切换站点"] || [norm isEqualToString:@"书源"] ||
        [norm isEqualToString:@"发现"]) {
        return;
    }
    // 非 Legado：同名只旁路；换源（XBS→XBS）仍 Handle→restore，否则 bookWorld 空、永不拉书
    if (!LBLegadoIsSourceName(norm)) {
        UIViewController *hostX = [self isKindOfClass:[UIViewController class]]
            ? (UIViewController *)self : LBPrimaryDiscoverHost();
        NSString *cur = LBReadHostSourceName(hostX);
        NSString *curN = LBNormalizeSourceDisplayName(cur) ?: cur;
        BOOL same = (curN.length > 0 &&
                     ([curN isEqualToString:norm] ||
                      [curN containsString:norm] || [norm containsString:curN]));
        if (same) {
            LBAppendNativeMarker([NSString stringWithFormat:
                                  @"setDicModel XBS passthrough same name=%@", norm]);
            return;
        }
        LBAppendNativeMarker([NSString stringWithFormat:
                              @"setDicModel XBS switch %@ → %@ → Handle",
                              curN ?: @"-", norm]);
        NSString *nameCopy = [norm copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            LBHandleDiscoverSourceSwitched(hostX, nameCopy);
        });
        return;
    }
    UIViewController *host = [self isKindOfClass:[UIViewController class]]
        ? (UIViewController *)self : LBPrimaryDiscoverHost();
    id tv = nil;
    id scroll = nil;
    @try { tv = [host valueForKey:@"pageTitleView"]; } @catch (__unused NSException *e) {}
    @try { scroll = [host valueForKey:@"pageContentScrollView"]; } @catch (__unused NSException *e) {}
    BOOL chromeMissing = (tv == nil || scroll == nil);
    if (!chromeMissing && sLastHandledSwitchName &&
        [sLastHandledSwitchName isEqualToString:norm]) {
        return;
    }
    LBAppendNativeMarker([NSString stringWithFormat:
                          @"setDicModel switch name=%@ chromeMissing=%d",
                          norm, chromeMissing ? 1 : 0]);
    NSString *nameCopy = [norm copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        LBHandleDiscoverSourceSwitched(host, nameCopy);
    });
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
    SEL selHdr = @selector(onHeaderBtnEvent:);
    Class ownerHdr = LBClassOwningInstanceMethod(cls, selHdr);
    if (ownerHdr) {
        Method m = class_getInstanceMethod(ownerHdr, selHdr);
        if (m && !sOrig_onHeaderBtn) {
            sOrig_onHeaderBtn = (void (*)(id, SEL, id))method_getImplementation(m);
            method_setImplementation(m, (IMP)LBDiscover_onHeaderBtn);
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
    SEL selOpen = @selector(openConfigByName:);
    Class ownerOpen = LBClassOwningInstanceMethod(cls, selOpen);
    if (ownerOpen) {
        Method m = class_getInstanceMethod(ownerOpen, selOpen);
        if (m && !sOrig_openConfigByName) {
            sOrig_openConfigByName = (void (*)(id, SEL, NSString *))method_getImplementation(m);
            method_setImplementation(m, (IMP)LBDiscover_openConfigByName);
        }
    }
    SEL selDic = @selector(setDicModel:);
    Class ownerDic = LBClassOwningInstanceMethod(cls, selDic);
    if (ownerDic) {
        Method m = class_getInstanceMethod(ownerDic, selDic);
        if (m && !sOrig_setDicModel) {
            sOrig_setDicModel = (void (*)(id, SEL, id))method_getImplementation(m);
            method_setImplementation(m, (IMP)LBDiscover_setDicModel);
            NSLog(@"[LegadoBridge] hooked %@ setDicModel:", NSStringFromClass(ownerDic));
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
        LBInstallBookListSafeViewDidLoad();
        LBInstallXBSHandoffHooks();
        // 顶层 JS exploreUrl 异步预热完成后重刷分类条
        [[NSNotificationCenter defaultCenter]
            addObserverForName:@"LegadoExploreKindsDidUpdate"
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            // 预热失败：Core 已盖失败文案；勿再 ForceRefresh（会空 kind→再刷「分类加载中」盖掉失败）
            id failed = note.userInfo[@"failed"];
            if ([failed respondsToSelector:@selector(boolValue)] && [failed boolValue]) {
                LBAppendNativeMarker(@"kindsUpdate failed keepHint");
                return;
            }
            LBRefreshDiscoverKindBarForced();
        }];
        [@"discover native UI hooks installed"
            writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_discover_native.txt"]
            atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    });
}

/// 按当前发现宿主源名判断：找不到可发现 Legado 名 → 纯原生（fail-open 保标签墙）
BOOL LBDiscoverShouldUseNativeXBS(void) {
    UIViewController *host = LBPrimaryDiscoverHost();
    // 刚切源写入的桥接名优先：宿主 title/useSourceName 可能仍滞后（管理页 pop 后 Sync 误判 XBS）
    NSString *name = nil;
    if (sDiscoverUseSourceName.length > 0) {
        name = sDiscoverUseSourceName;
    } else if (sLastHandledSwitchName.length > 0) {
        name = sLastHandledSwitchName;
    } else {
        name = LBReadHostSourceName(host);
    }
    if (name.length > 0) {
        if ([name isEqualToString:@"切换站点"] || [name isEqualToString:@"书源"] ||
            [name isEqualToString:@"发现"]) {
            return YES;
        }
        NSString *legadoUrl = LBFindLegadoExploreUrlByName(name);
        return (legadoUrl.length == 0);
    }
    id core = LBKindCore();
    if (core) {
        NSString *src = nil;
        @try {
            id v = [core valueForKey:@"selectedExploreSourceUrl"];
            if ([v isKindOfClass:[NSString class]]) src = v;
        } @catch (__unused NSException *e) {}
        if (src.length > 0) {
            LBAppendNativeMarker([NSString stringWithFormat:
                                  @"shouldXBS hostName空 selectedExplore=%@ → XBS=1",
                                  src]);
        }
    }
    return YES;
}

BOOL LBDiscoverSyncModeForCurrentSource(void) {
    BOOL xbs = LBDiscoverShouldUseNativeXBS();
    LBSetDiscoverNativeXBSMode(xbs);
    UIViewController *host = LBPrimaryDiscoverHost();
    if (xbs) {
        if (host) {
            @try { LBRemoveDiscoverOverlays(host); } @catch (__unused NSException *e) {}
        }
        sCachedKinds = nil;
        // 勿清 sNativeChromeBuilt：sync 轮询会反复进来；清掉易触发下游误重建
        id core = LBKindCore();
        if (core) {
            @try { [core setValue:nil forKey:@"selectedExploreSourceUrl"]; } @catch (__unused NSException *e) {}
        }
        @try { LBClearDiscoverExplorePendingOnly(); } @catch (__unused NSException *e) {}
        // 不在此 ClearNativeReadingBridgeState：进发现轮询会反复清，可能扰动原生会话

        NSString *name = nil;
        if (sDiscoverUseSourceName.length > 0) {
            name = sDiscoverUseSourceName;
        } else {
            name = LBReadHostSourceName(host);
        }
        // TC-08：XBS syncMode 在 host 空/薄壳时做 exact-key ivar 交接（禁 reset/createCons/donor）。
        // key 必须在 raw manager 表精确存在；禁止模糊名。
        if (host && name.length > 0 && LBBSMRawDicModelForExactKey(name)) {
            BOOL handed = LBPerformSafeXBSHandoff(host, name);
            LBAppendNativeMarker([NSString stringWithFormat:
                                  @"syncMode XBS ensure exactKey handed=%d",
                                  handed ? 1 : 0]);
        } else if (host && name.length > 0) {
            LBAppendNativeMarker(@"syncMode XBS skip ensure (name not exact manager key)");
        }
        NSInteger arrN = -1;
        NSUInteger bwN = 0;
        @try {
            UIViewController *list = LBActiveDiscoverListVC(host) ?: host;
            id a = [list valueForKey:@"arrBaseData"];
            if ([a isKindOfClass:[NSArray class]]) arrN = (NSInteger)[(NSArray *)a count];
            id dm = [host valueForKey:@"dicModel"];
            if ([dm isKindOfClass:[NSDictionary class]]) {
                id bw = ((NSDictionary *)dm)[@"bookWorld"];
                if ([bw isKindOfClass:[NSDictionary class]]) bwN = [(NSDictionary *)bw count];
            }
        } @catch (__unused NSException *e) {}
        LBAppendNativeMarker([NSString stringWithFormat:
                              @"syncMode XBS=1 host=%@ name=%@ arrN=%ld bw=%lu",
                              host ? NSStringFromClass([host class]) : @"-",
                              name ?: @"-", (long)arrN, (unsigned long)bwN]);
    } else {
        LBAppendNativeMarker([NSString stringWithFormat:
                              @"syncMode XBS=0 host=%@ name=%@",
                              host ? NSStringFromClass([host class]) : @"-",
                              LBReadHostSourceName(host) ?: @"-"]);
        // 已是 Legado 名但 chrome 被掏空（切源 Handle miss）→ 让后续 Refresh 重新 Feed
        if (host) {
            id tv = nil;
            id scroll = nil;
            @try { tv = [host valueForKey:@"pageTitleView"]; } @catch (__unused NSException *e) {}
            @try { scroll = [host valueForKey:@"pageContentScrollView"]; } @catch (__unused NSException *e) {}
            if (!tv || !scroll) {
                sNativeChromeBuilt = NO;
                sLastFeedSig = nil;
                sLastHandledSwitchName = nil;
                NSString *nm = LBReadHostSourceName(host);
                NSString *url = LBFindLegadoExploreUrlByName(nm);
                id core2 = LBKindCore();
                if (core2 && url.length > 0) {
                    @try { [core2 setValue:url forKey:@"selectedExploreSourceUrl"]; } @catch (__unused NSException *e) {}
                }
                LBAppendNativeMarker([NSString stringWithFormat:
                                      @"syncMode Legado chromeMissing allowFeed name=%@ url=%@",
                                      nm ?: @"-", url ?: @"-"]);
            }
        }
    }
    return xbs;
}

/// T4：管理页等入口按源名切发现（走 openConfig / HandleDiscoverSourceSwitched）
BOOL LBDiscoverHostAlreadyShowingSource(NSString *sourceName) {
    if (sourceName.length == 0) return NO;
    UIViewController *host = LBPrimaryDiscoverHost();
    if (!host) return NO;
    if (!sNativeChromeBuilt) return NO;
    NSString *cur = LBNormalizeSourceDisplayName(LBReadHostSourceName(host) ?: @"");
    NSString *want = LBNormalizeSourceDisplayName(sourceName);
    if (cur.length == 0 || want.length == 0) return NO;
    return [cur isEqualToString:want];
}

void LBSwitchDiscoverToSourceName(NSString *sourceName) {
    if (sourceName.length == 0) return;
    if (![NSThread isMainThread]) {
        NSString *name = [sourceName copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            LBSwitchDiscoverToSourceName(name);
        });
        return;
    }
    if (LBDiscoverHostAlreadyShowingSource(sourceName)) {
        LBAppendNativeMarker([NSString stringWithFormat:@"switchDiscover skip same name=%@",
                              sourceName]);
        return;
    }
    LBSetDiscoverTabActive(YES);
    // 尽量把书架顶栏切到「发现」
    @try {
        UIWindow *win = LBLegadoKeyWindow();
        UIViewController *root = win.rootViewController;
        NSMutableArray *stack = [NSMutableArray array];
        if (root) [stack addObject:root];
        NSInteger budget = 40;
        while (stack.count && budget-- > 0) {
            UIViewController *vc = stack.lastObject;
            [stack removeLastObject];
            NSString *cn = NSStringFromClass([vc class]);
            if ([cn containsString:@"BookShelf"] && [vc respondsToSelector:@selector(setSquare:)]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(vc, @selector(setSquare:), YES);
                break;
            }
            if (vc.presentedViewController) [stack addObject:vc.presentedViewController];
            if ([vc isKindOfClass:[UINavigationController class]]) {
                UIViewController *top = [(UINavigationController *)vc topViewController];
                if (top) [stack addObject:top];
                for (UIViewController *c in [(UINavigationController *)vc viewControllers]) {
                    [stack addObject:c];
                }
            } else if ([vc isKindOfClass:[UITabBarController class]]) {
                UIViewController *sel = [(UITabBarController *)vc selectedViewController];
                if (sel) [stack addObject:sel];
            } else {
                for (UIViewController *c in vc.childViewControllers) [stack addObject:c];
            }
        }
    } @catch (__unused NSException *e) {}

    LBEnsureNativeDiscoverHostPresented();
    UIViewController *host = LBPrimaryDiscoverHost();
    if (!host) {
        NSArray *found = LBFindDiscoverHostVCs();
        host = found.count ? found.firstObject : nil;
    }
    if (!host) {
        LBAppendNativeMarker([NSString stringWithFormat:@"switchDiscover missHost name=%@", sourceName]);
        return;
    }
    LBAppendNativeMarker([NSString stringWithFormat:@"switchDiscover name=%@ host=%@",
                          sourceName, NSStringFromClass([host class])]);
    // 优先走原生 openConfig（hook 内会再调 HandleDiscoverSourceSwitched）
    if (LBInvokeOpenConfigByName(host, sourceName)) {
        return;
    }
    LBHandleDiscoverSourceSwitched(host, sourceName);
}

void LBNotifyDiscoverNativeSourceSwitched(NSString *sourceName) {
    if (sourceName.length == 0) return;
    if (![NSThread isMainThread]) {
        NSString *copy = [sourceName copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            LBNotifyDiscoverNativeSourceSwitched(copy);
        });
        return;
    }
    UIViewController *host = LBPrimaryDiscoverHost();
    if (!host) {
        LBAppendNativeMarker([NSString stringWithFormat:
                              @"nativeSwitch notify missHost name=%@", sourceName]);
        return;
    }
    NSString *clean = LBNormalizeSourceDisplayName(sourceName) ?: sourceName;
    LBAppendNativeMarker([NSString stringWithFormat:
                          @"nativeSwitch notify name=%@", clean]);
    LBHandleDiscoverSourceSwitched(host, clean);
}

/// 刷新原生分类标签（原 LBRefreshDiscoverKindBar，已去掉 overlay）
void LBRefreshDiscoverKindBar(void) {
    LBRefreshDiscoverKindBarEx(NO);
}

/// 强制刷新（跳过 0.35s 防抖；供 exploreKinds 预热完成通知）
static void LBRefreshDiscoverKindBarForced(void) {
    LBRefreshDiscoverKindBarEx(YES);
}

static void LBRefreshDiscoverKindBarEx(BOOL force) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ LBRefreshDiscoverKindBarEx(force); });
        return;
    }
    if (!LBIsDiscoverTabActive()) return;
    static CFAbsoluteTime sLastRefreshAt = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!force && (now - sLastRefreshAt) < 0.35) return;
    sLastRefreshAt = now;
    LBInstallDiscoverNativeUIHooks();

    UIViewController *host = LBPrimaryDiscoverHost();
    if (!host || !host.isViewLoaded || !host.view) return;

    id core = LBKindCore();
    if (!core) return;

    // 统一走 Sync：XBS 最小干预；Legado 才灌 kinds
    if (LBDiscoverSyncModeForCurrentSource()) {
        LBAppendNativeMarker(@"refreshKind skip after sync XBS");
        return;
    }

    NSString *hostName = LBReadHostSourceName(host);
    NSString *src = LBCurrentExploreSourceUrl(core);
    NSString *srcName = hostName;
    for (id row in LBParseJSONArray(
             ([core respondsToSelector:@selector(exploreCapableSourcesJSON)]
              ? [core valueForKey:@"exploreCapableSourcesJSON"] : @"[]"))) {
        if ([row isKindOfClass:[NSDictionary class]] && [row[@"url"] isEqual:src]) {
            srcName = row[@"name"] ?: srcName;
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
    // 预热完成后：若有可用 kind URL，自动拉一次书（补上切源时 defer 掉的 explore）
    if (force && kinds.count > 0 && src.length > 0 && !LBIsDiscoverNativeXBSMode()) {
        NSInteger pref = LBPreferredExploreKindIndex(kinds);
        sSelectedKindIndex = pref;
        sCachedKinds = [kinds copy];
        id u = (pref >= 0 && pref < (NSInteger)kinds.count) ? kinds[(NSUInteger)pref][@"url"] : nil;
        NSString *kindUrl = ([u isKindOfClass:[NSString class]] && [(NSString *)u length] > 0)
            ? (NSString *)u : nil;
        if (kindUrl.length > 0) {
            LBClearDiscoverExploreEmptyHint();
            LBAppendNativeMarker([NSString stringWithFormat:
                                  @"kindsReady explore pref=%ld kind=%@",
                                  (long)pref, kindUrl]);
            LBTriggerExploreKind(src, kindUrl);
        }
    }
}
