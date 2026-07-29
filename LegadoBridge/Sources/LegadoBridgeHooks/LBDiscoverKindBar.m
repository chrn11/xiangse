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
static BOOL sBookListSafeVDLInstalled = NO;
static void (*sOrig_bookListViewDidLoad)(id, SEL) = NULL;

static void (*sOrig_pageTitleSelected)(id, SEL, id, NSInteger) = NULL;
static void (*sOrig_onSwitchBtn)(id, SEL) = NULL;
static void (*sOrig_onSwitchBtnArg)(id, SEL, id) = NULL;
static void (*sOrig_onHeaderBtn)(id, SEL, id) = NULL;
static void (*sOrig_openConfigByName)(id, SEL, NSString *) = NULL;
static NSString *(*sOrig_getUseSourceName)(id, SEL) = NULL;
static NSString *sDiscoverUseSourceName = nil;
static BOOL sFeedingDiscoverHeader = NO;
static BOOL sApplyingKinds = NO; // ForceTitles/ApplyKinds 期间禁 explore，防连环 clear

static void LBPaintTitleLabels(id tv, NSInteger selectedIndex);
static void LBRestoreDiscoverTitleSelected(id pageTitleView, NSInteger index);
static void LBDiscoverHandleKindSelect(UIViewController *host, id pageTitleView, NSInteger index);
static void LBAttachDiscoverKindButtonActions(UIViewController *host, id titleView);
static void LBUnlinkDiscoverTitleContent(UIViewController *host);
static NSString *LBCurrentExploreSourceUrl(id core);
static void LBTriggerExploreKind(NSString *sourceUrl, NSString *kindUrl);
static void LBDiscoverFireExploreForIndex(NSInteger index, NSString *titleHint);
static NSArray *LBDonorTitlesFromHost(UIViewController *host, NSDictionary *prepared);
static void LBForceLegadoTitlesOnChrome(UIViewController *host, NSArray *titles);
static void LBApplyLegadoSourceKindsToChrome(UIViewController *host, NSArray *kinds, NSString *srcName);
static void LBHandleDiscoverSourceSwitched(UIViewController *host, NSString *sourceName);
static NSString *LBFindLegadoExploreUrlByName(NSString *name);
static void LBRevealDiscoverTitleAndList(UIViewController *host);

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

/// 发现态：分类只换数据，固定灌第一个 BookListCon（分类条用当前 Legado 源 kinds）
static BOOL LBDiscoverSingleListFeed(void) {
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

    void (^pinSV)(UIScrollView *) = ^(UIScrollView *sv) {
        if (!sv) return;
        @try {
            sv.scrollEnabled = NO;
            sv.pagingEnabled = NO;
            [sv setContentOffset:CGPointMake(0, sv.contentOffset.y) animated:NO];
        } @catch (__unused NSException *e) {}
    };
    if ([scroll isKindOfClass:[UIScrollView class]]) {
        pinSV((UIScrollView *)scroll);
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
            if ([v isKindOfClass:[UIScrollView class]]) pinSV((UIScrollView *)v);
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
    id u = kinds[(NSUInteger)idx][@"url"];
    return [u isKindOfClass:[NSString class]] ? u : nil;
}

static void LBDiscoverFireExploreForIndex(NSInteger index, NSString *titleHint) {
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
    @try {
        LBTriggerExploreKind(src, url);
    } @catch (NSException *ex) {
        LBAppendNativeMarker([NSString stringWithFormat:@"nativeExplore EX %@",
                              ex.reason ?: @""]);
    }
}

/// 分类切换：原生多页翻页后，按 index 触发 explore（不再钉死第一页）
static void LBDiscoverHandleKindSelect(UIViewController *host, id pageTitleView, NSInteger index) {
    if (sHandlingKindSelect) return;
    // SG 若仍用被污染的 btn.tag 回调，会传来 0x4C424Bxx；直接丢弃
    if (index < 0 || index > 64) {
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

/// 断开标题条与内容滚动联动，避免选分类时翻到不存在的空页
static void LBUnlinkDiscoverTitleContent(UIViewController *host) {
    if (!host) return;
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
    LBEnsureDiscoverKindBtnMethod([host class]);
    SEL sel = @selector(lb_discoverKindBtn:);
    UIView *root = (UIView *)titleView;
    NSMutableArray<UIButton *> *btns = [NSMutableArray array];
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
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

/// donor bookWorld 的 key 数决定 createCons 出多少子页。Legado 分类多于 donor 时，
/// 以 donor 的抓取规则为模板扩到 titles.count 个 key（key 用 Legado 分类名）。
static NSDictionary *LBExpandBookWorldToTitles(NSDictionary *donorBW, NSArray *titles) {
    if (![donorBW isKindOfClass:[NSDictionary class]] || donorBW.count == 0) return donorBW;
    if (titles.count <= donorBW.count) return donorBW;

    NSArray *keys = donorBW.allKeys;
    id tmpl = donorBW[keys.firstObject];
    if (![tmpl isKindOfClass:[NSDictionary class]]) return donorBW;

    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < titles.count; i++) {
        id rawTitle = titles[i];
        NSString *k = [rawTitle isKindOfClass:[NSString class]]
            ? (NSString *)rawTitle
            : [NSString stringWithFormat:@"分类%lu", (unsigned long)(i + 1)];
        if (k.length == 0) k = [NSString stringWithFormat:@"分类%lu", (unsigned long)(i + 1)];
        NSUInteger dup = 2;
        while (out[k]) {
            k = [NSString stringWithFormat:@"%@%lu", k, (unsigned long)dup++];
        }
        id src = (i < keys.count) ? donorBW[keys[i]] : tmpl;
        out[k] = [src isKindOfClass:[NSDictionary class]] ? [src mutableCopy] : src;
    }
    LBAppendNativeMarker([NSString stringWithFormat:@"bwExpand %lu -> %lu",
                          (unsigned long)donorBW.count, (unsigned long)out.count]);
    return out;
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

    if ([donorBW isKindOfClass:[NSDictionary class]] && donorBW.count > 0) {
        NSArray *bwKeysArr = donorBW.allKeys;
        id sampleVal = donorBW[bwKeysArr.firstObject];
        NSString *sampleDesc = @"-";
        if ([sampleVal isKindOfClass:[NSDictionary class]]) {
            NSArray *sk = [(NSDictionary *)sampleVal allKeys];
            sampleDesc = [NSString stringWithFormat:@"dict{%@}",
                          [[sk subarrayWithRange:NSMakeRange(0, MIN(sk.count, (NSUInteger)8))]
                           componentsJoinedByString:@","]];
        } else if ([sampleVal isKindOfClass:[NSArray class]]) {
            id f = [(NSArray *)sampleVal firstObject];
            sampleDesc = [NSString stringWithFormat:@"array[%lu] of %@",
                          (unsigned long)[(NSArray *)sampleVal count],
                          f ? NSStringFromClass([f class]) : @"nil"];
            if ([f isKindOfClass:[NSDictionary class]]) {
                NSArray *sk = [(NSDictionary *)f allKeys];
                sampleDesc = [sampleDesc stringByAppendingFormat:@"{%@}",
                              [[sk subarrayWithRange:NSMakeRange(0, MIN(sk.count, (NSUInteger)8))]
                               componentsJoinedByString:@","]];
            }
        } else {
            sampleDesc = NSStringFromClass([sampleVal class]);
        }
        LBAppendNativeMarker([NSString stringWithFormat:@"bwShape keys=%@ | first=%@ -> %@",
                              [bwKeysArr componentsJoinedByString:@","],
                              bwKeysArr.firstObject, sampleDesc]);
    }

    // 对齐原版：保留 donor bookWorld 键（男生/女频/出版），禁止用 Legado 分类名扩键摊平
    (void)titles;
    // donorBW = LBExpandBookWorldToTitles(donorBW, titles);  // disabled: breaks native tag wall

    if (donorName.length > 0) {
        sDiscoverUseSourceName = [donorName copy];
    }

    NSString *cfgName = donorName.length ? donorName : srcName;
    BOOL opened = NO;
    if (cfgName.length > 0) {
        opened = LBInvokeOpenConfigByName(host, cfgName);
    }

    if (opened) {
        // 顶栏标题跟 donor bookWorld keys，勿写 Legado kinds
        NSArray *donorTitles = nil;
        id cur0 = nil;
        @try { cur0 = [host valueForKey:@"dicModel"]; } @catch (__unused NSException *e) {}
        if ([cur0 isKindOfClass:[NSDictionary class]]) {
            id bw = cur0[@"bookWorld"];
            if ([bw isKindOfClass:[NSDictionary class]]) {
                donorTitles = [(NSDictionary *)bw allKeys];
            }
            id hdr = cur0[@"arrHeaderBtnTitle"];
            if ([hdr isKindOfClass:[NSArray class]] && [(NSArray *)hdr count] > 0) {
                donorTitles = hdr;
            }
        }
        if (donorTitles.count > 0) {
            @try { [host setValue:donorTitles forKey:@"arrHeaderBtnTitle"]; } @catch (__unused NSException *e) {}
        } else if (titles.count > 0) {
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
            fixed[@"arrHeaderBtnTitle"] = donorBW.allKeys ?: @[];
            LBForceSetDicModel(host, fixed);
            return fixed;
        }
        if (donorBW.count >= 6) {
            NSMutableDictionary *model = [NSMutableDictionary dictionary];
            model[@"bookWorld"] = donorBW;
            model[@"arrHeaderBtnTitle"] = donorBW.allKeys ?: @[];
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
    model[@"arrHeaderBtnTitle"] = donorBW.allKeys ?: @[];
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

/// 发现态：优先走原生 viewDidLoad（才能出标签墙）；崩了再退回空表兜底
static void LBBookList_safeViewDidLoad(id self, SEL _cmd) {
    BOOL discover = LBIsDiscoverTabActive() || sFeedingDiscoverHeader || sBookListSafeVDLInstalled;
    if (!discover) {
        if (sOrig_bookListViewDidLoad) {
            sOrig_bookListViewDidLoad(self, _cmd);
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
/// 新建一份 configure，失败则就地改色。
static id LBDiscoverTitleConfigure(id donorConfigure) {
    UIColor *normal = [UIColor colorWithWhite:0.20 alpha:1];
    UIColor *selected = [UIColor colorWithRed:0.90 green:0.35 blue:0.10 alpha:1];
    Class cfgCls = NSClassFromString(@"SGPageTitleViewConfigure");
    id cfg = nil;
    SEL make = NSSelectorFromString(@"pageTitleViewConfigure");
    if (cfgCls && [cfgCls respondsToSelector:make]) {
        @try { cfg = ((id (*)(id, SEL))objc_msgSend)(cfgCls, make); } @catch (__unused NSException *e) {}
    }
    if (!cfg && cfgCls) {
        @try { cfg = [[cfgCls alloc] init]; } @catch (__unused NSException *e) {}
    }
    if (!cfg) cfg = donorConfigure;
    if (!cfg) return nil;

    NSDictionary *kv = @{
        @"titleColor": normal,
        @"titleSelectedColor": selected,
        @"indicatorColor": selected,
        @"titleFont": [UIFont systemFontOfSize:15],
        @"titleSelectedFont": [UIFont boldSystemFontOfSize:16],
        @"titleAdditionalWidth": @20,
        @"equivalence": @NO,
        @"isShowIndicator": @YES,
        @"showIndicator": @YES,
        @"isNeedBounces": @YES,
        @"bounces": @YES,
        @"isOpenTitleTextZoom": @YES,
        @"openTitleTextZoom": @YES,
        @"titleTextZoomScale": @0.18,
        @"indicatorStyle": @0,
        @"indicatorHeight": @2,
        @"indicatorWidth": @16,
        @"indicatorSpacing": @4,
        @"contentInsetSpacing": @16,
        @"spacingBetweenButtons": @24,
        @"startSpacing": @12,
    };
    NSMutableArray *okKeys = [NSMutableArray array];
    for (NSString *k in kv) {
        @try {
            [cfg setValue:kv[k] forKey:k];
            [okKeys addObject:k];
        } @catch (__unused NSException *e) {}
    }
    LBAppendNativeMarker([NSString stringWithFormat:@"titleCfg cls=%@ fresh=%d keys=%@",
                          NSStringFromClass([cfg class]),
                          (cfg != donorConfigure) ? 1 : 0,
                          [okKeys componentsJoinedByString:@","]]);
    return cfg;
}

/// 兜底：不改动 SG 内部 layout（易崩），只叠可见 overlay UILabel
static void LBPaintTitleLabels(id tv, NSInteger selectedIndex) {
    if (![tv isKindOfClass:[UIView class]]) return;
    UIView *root = (UIView *)tv;
    // 浅底深字：黑内容区上分类条必须显眼
    @try {
        root.backgroundColor = [UIColor colorWithWhite:0.97 alpha:1];
        root.opaque = YES;
        root.hidden = NO;
        root.alpha = 1;
        root.clipsToBounds = NO;
    } @catch (__unused NSException *e) {}
    UIColor *normal = [UIColor colorWithWhite:0.15 alpha:1];
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

    NSMutableArray *dump = [NSMutableArray array];
    NSInteger idx = 0;
    NSInteger tag = 0x4C4254; // 'LBT'
    for (UIButton *btn in btns) {
        UIColor *c = (idx == selectedIndex) ? selected : normal;
        @try {
            NSString *t = [btn titleForState:UIControlStateNormal];
            if (t.length == 0) @try { t = btn.currentTitle; } @catch (__unused NSException *e) {}
            if (t.length == 0) @try { t = btn.titleLabel.text; } @catch (__unused NSException *e) {}
            [btn setTitleColor:c forState:UIControlStateNormal];
            [btn setTitleColor:selected forState:UIControlStateSelected];
            @try { btn.backgroundColor = [UIColor clearColor]; } @catch (__unused NSException *e) {}
            @try { btn.titleLabel.alpha = 1; btn.alpha = 1; btn.hidden = NO; } @catch (__unused NSException *e) {}

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
static void LBRevealDiscoverTitleAndList(UIViewController *host) {
    if (!host || !host.isViewLoaded || !host.view) return;
    static const NSInteger kLBFO = 0x4C42464F; // 'LBFO' feed overlay

    id tv = nil;
    @try { tv = [host valueForKey:@"pageTitleView"]; } @catch (__unused NSException *e) {}
    UIView *title = [tv isKindOfClass:[UIView class]] ? (UIView *)tv : nil;
    if (title) {
        if (!title.superview) [host.view addSubview:title];
        title.hidden = NO;
        title.alpha = 1;
        title.backgroundColor = [UIColor colorWithWhite:0.97 alpha:1];
    }

    LBPinDiscoverContentToFirstPage(host);

    UIViewController *list = nil;
    @try { list = LBActiveDiscoverListVC(host); } @catch (__unused NSException *e) {}
    // 兜底：从宿主子树找回 BookList（含已挂在 host.view 上的）
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
    }

    CGFloat titleBottom = title ? CGRectGetMaxY(title.frame) : 0;
    if (titleBottom < 100) titleBottom = 129;

    id scroll = nil;
    @try { scroll = [host valueForKey:@"pageContentScrollView"]; } @catch (__unused NSException *e) {}
    if ([scroll isKindOfClass:[UIView class]]) {
        UIView *sv = (UIView *)scroll;
        sv.hidden = NO;
        sv.alpha = 1;
        CGRect hb = host.view.bounds;
        if (hb.size.width > 2 && hb.size.height > titleBottom + 40) {
            sv.frame = CGRectMake(0, titleBottom, hb.size.width, hb.size.height - titleBottom);
        }
        [host.view bringSubviewToFront:sv];
    }

    if (list && list.isViewLoaded && list.view) {
        list.view.hidden = NO;
        list.view.alpha = 1;
        if (list.view.superview) {
            [list.view.superview bringSubviewToFront:list.view];
        }
    }

    NSUInteger arrN = 0;
    @try {
        id a = [list valueForKey:@"arrBaseData"];
        if ([a isKindOfClass:[NSArray class]]) arrN = [(NSArray *)a count];
    } @catch (__unused NSException *e) {}

    // 有书：在宿主上叠一层可见表（不拆 SG 父子，避免 VC 被释放）
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
            overlay.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1];
            overlay.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
            overlay.separatorColor = [UIColor colorWithWhite:0.2 alpha:1];
            overlay.rowHeight = 108;
            overlay.estimatedRowHeight = 108;
            [host.view addSubview:overlay];
            LBAppendNativeMarker([NSString stringWithFormat:
                                  @"reveal feedOverlay new arr=%lu frame=%.0fx%.0f@%.0f,%.0f",
                                  (unsigned long)arrN, of.size.width, of.size.height,
                                  of.origin.x, of.origin.y]);
        } else {
            overlay.frame = of;
            overlay.hidden = NO;
            overlay.alpha = 1;
        }
        overlay.dataSource = (id<UITableViewDataSource>)list;
        overlay.delegate = (id<UITableViewDelegate>)list;
        @try {
            [overlay reloadData];
            [overlay layoutIfNeeded];
        } @catch (__unused NSException *e) {}
        [host.view bringSubviewToFront:overlay];
        NSInteger vis = 0;
        @try { vis = (NSInteger)overlay.visibleCells.count; } @catch (__unused NSException *e) {}
        LBAppendNativeMarker([NSString stringWithFormat:
                              @"reveal feedOverlay vis=%ld rows~%lu csh=%.0f",
                              (long)vis, (unsigned long)arrN, overlay.contentSize.height]);
    }

    // 分类条最上
    if (title) [host.view bringSubviewToFront:title];
}

static void LBForceLegadoTitlesOnChrome(UIViewController *host, NSArray *titles) {
    if (!host || titles.count == 0) return;
    BOOL prev = sApplyingKinds;
    sApplyingKinds = YES;
    @try { [host setValue:titles forKey:@"arrHeaderBtnTitle"]; } @catch (__unused NSException *e) {}

    id tv = nil;
    @try { tv = [host valueForKey:@"pageTitleView"]; } @catch (__unused NSException *e) {}
    if (!tv) {
        LBAppendNativeMarker(@"forceTitles no pageTitleView (will create)");
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
        CGFloat top = 88;
        if (@available(iOS 11.0, *)) {
            if (host.isViewLoaded) {
                top = MAX(88, host.view.safeAreaInsets.top + 44);
            }
        }
        CGRect frame = old.frame;
        if (CGRectIsEmpty(frame) || frame.size.width < 2 || frame.size.height < 2 || frame.origin.y < top - 2) {
            frame = CGRectMake(0, top, w, MAX(38, frame.size.height > 2 ? frame.size.height : 44));
            old.frame = frame;
            LBAppendNativeMarker([NSString stringWithFormat:
                                  @"forceTitles fixFrameOnly y=%.0f h=%.0f", frame.origin.y, frame.size.height]);
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
        CGFloat top = 88;
        if (@available(iOS 11.0, *)) {
            top = MAX(88, host.view.safeAreaInsets.top + 44);
        }
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
    if ([tv isKindOfClass:[UIView class]]) {
        NSMutableArray<UIButton *> *btns = [NSMutableArray array];
        NSMutableArray *stack = [NSMutableArray arrayWithObject:(UIView *)tv];
        while (stack.count) {
            UIView *v = stack.lastObject;
            [stack removeLastObject];
            if ([v isKindOfClass:[UIButton class]]) [btns addObject:(UIButton *)v];
            for (UIView *sub in v.subviews) [stack addObject:sub];
        }
        NSArray *sorted = [btns sortedArrayUsingComparator:^NSComparisonResult(UIButton *a, UIButton *b) {
            return a.frame.origin.x < b.frame.origin.x ? NSOrderedAscending : NSOrderedDescending;
        }];
        for (NSUInteger i = 0; i < sorted.count && i < titles.count; i++) {
            NSString *name = [titles[i] isKindOfClass:[NSString class]] ? titles[i] : @"分类";
            UIButton *b = sorted[i];
            @try {
                [b setTitle:name forState:UIControlStateNormal];
                [b setTitle:name forState:UIControlStateSelected];
                b.titleLabel.text = name;
            } @catch (__unused NSException *e) {}
        }
        LBAppendNativeMarker([NSString stringWithFormat:@"forceTitles softBtn n=%lu want=%lu",
                              (unsigned long)sorted.count, (unsigned long)titles.count]);
    }
    LBEnableTitleScroll(tv);
    LBAttachDiscoverKindButtonActions(host, tv);
    // 最后再画字并置顶，避免 scroll/unlink 盖住 overlay
    LBPaintTitleLabels(tv, 0);
    if ([tv isKindOfClass:[UIView class]] && host.isViewLoaded && host.view) {
        UIView *title = (UIView *)tv;
        if (title.superview != host.view) {
            @try { [host.view addSubview:title]; } @catch (__unused NSException *e) {}
        }
        [host.view bringSubviewToFront:title];
        title.hidden = NO;
        title.alpha = 1;
        @try {
            host.view.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1];
        } @catch (__unused NSException *e) {}
    }

    LBAppendNativeMarker([NSString stringWithFormat:@"forceTitles n=%lu applied=%d",
                          (unsigned long)titles.count, applied ? 1 : 0]);
    LBRevealDiscoverTitleAndList(host);
    sApplyingKinds = prev;
    __weak UIViewController *weakHost = host;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIViewController *h = weakHost;
        if (!h) return;
        LBRevealDiscoverTitleAndList(h);
        id ptv = nil;
        @try { ptv = [h valueForKey:@"pageTitleView"]; } @catch (__unused NSException *e) {}
        if (ptv) LBPaintTitleLabels(ptv, sSelectedKindIndex);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIViewController *h = weakHost;
        if (!h || !LBIsDiscoverTabActive()) return;
        LBRevealDiscoverTitleAndList(h);
        LBEnsureDiscoverListSurface(h);
        LBReloadDiscoverNativeList(h);
    });
}

/// 分类条跟当前 Legado 源 exploreUrl 解析结果走（换源即换分类），donor 只当壳
static void LBApplyLegadoSourceKindsToChrome(UIViewController *host, NSArray *kinds, NSString *srcName) {
    if (!host) return;
    NSMutableArray *titles = [NSMutableArray array];
    for (id item in kinds) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSString *t = item[@"title"];
        [titles addObject:([t isKindOfClass:[NSString class]] && t.length > 0) ? t : @"分类"];
    }
    if (titles.count == 0) [titles addObject:@"发现"];
    if (srcName.length > 0) {
        @try { host.navigationItem.title = srcName; } @catch (__unused NSException *e) {}
        @try { host.title = srcName; } @catch (__unused NSException *e) {}
    }
    LBForceLegadoTitlesOnChrome(host, titles);
    sCachedKinds = [kinds copy];
    if (sSelectedKindIndex >= (NSInteger)titles.count) sSelectedKindIndex = 0;
    LBAppendNativeMarker([NSString stringWithFormat:@"applySrcKinds n=%lu src=%@ sample=%@",
                          (unsigned long)titles.count, srcName ?: @"",
                          [[titles subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)4, titles.count))]
                           componentsJoinedByString:@","]]);
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

/// 清空原生子页书数据，但不动 UI/table（sanitize 后立刻 reload 会把标签墙撑乱）
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
        // 仍先保证顶栏源名可见；顶栏大类留给 donor，勿写 Legado kinds
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

        NSDictionary *prepared = LBPrepareDiscoverDicModel(host, srcName, titles);
        id bwObj = prepared[@"bookWorld"];
        NSUInteger bwKeys = [bwObj isKindOfClass:[NSDictionary class]] ? [(NSDictionary *)bwObj count] : 0;
        NSArray *donorTitles = LBDonorTitlesFromHost(host, prepared);
        if (!prepared || bwKeys < 6) {
            if (srcName.length > 0) {
                @try { host.navigationItem.title = srcName; } @catch (__unused NSException *e) {}
                @try { host.title = srcName; } @catch (__unused NSException *e) {}
            }
            if (donorTitles.count > 0) {
                @try { [host setValue:donorTitles forKey:@"arrHeaderBtnTitle"]; } @catch (__unused NSException *e) {}
            }
            sCachedKinds = [kinds copy];
            LBAppendNativeMarker([NSString stringWithFormat:
                                  @"shellFallback noDonorBW keys=%lu",
                                  (unsigned long)bwKeys]);
            LBAppendNativeHostState(host, @"shellFallback");
            return;
        }
        LBAppendNativeMarker([NSString stringWithFormat:@"preparedBW keys=%lu useReset=1 donorTitles=%lu",
                              (unsigned long)bwKeys, (unsigned long)donorTitles.count]);

        // 必须在 resetContent 前装好：BookListCon viewDidLoad 会在挂页时立刻跑
        LBInstallBookListSafeViewDidLoad();

        NSString *consName = sDiscoverUseSourceName.length ? sDiscoverUseSourceName : (srcName ?: @"");
        if (donorTitles.count > 0) {
            @try { [host setValue:donorTitles forKey:@"arrHeaderBtnTitle"]; } @catch (__unused NSException *e) {}
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

        // 对齐原版：顶栏用 donor bookWorld keys，禁止用 Legado kinds 覆盖
        NSArray *postDonorTitles = LBDonorTitlesFromHost(host, prepared);
        if (postDonorTitles.count == 0 && scrollKids > 0) {
            // 已有子页时按子页数占位，勿塞 Legado 13 类
            NSMutableArray *aligned = [NSMutableArray array];
            for (NSUInteger i = 0; i < scrollKids; i++) {
                [aligned addObject:[NSString stringWithFormat:@"分类%lu", (unsigned long)(i + 1)]];
            }
            postDonorTitles = aligned;
        }
        if (postDonorTitles.count > 0) {
            donorTitles = postDonorTitles;
            @try { [host setValue:donorTitles forKey:@"arrHeaderBtnTitle"]; } @catch (__unused NSException *e) {}
            LBAppendNativeMarker([NSString stringWithFormat:@"keepDonorTitles n=%lu sample=%@",
                                  (unsigned long)donorTitles.count,
                                  [[donorTitles subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)4, donorTitles.count))]
                                   componentsJoinedByString:@","]]);
        }
        // 缓存 Legado kinds 供点标签/切页时 explore，但不改顶栏 UI
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
                    id u = sCachedKinds[0][@"url"];
                    if ([u isKindOfClass:[NSString class]]) kindUrl = u;
                }
                LBAppendNativeMarker([NSString stringWithFormat:
                                      @"postChrome explore src=%@ kind=%@",
                                      src ?: @"", kindUrl ?: @""]);
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
        // 用 donor 大类标题，勿用 Legado 13 类摊平
        NSArray *consTitles = donorTitles.count > 0 ? donorTitles : LBDonorTitlesFromHost(host, prepared);
        if (consTitles.count == 0) consTitles = @[@"男生", @"女频", @"出版"];
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
        NSUInteger kindCap = donorTitles.count > 0 ? donorTitles.count : titles.count;
        if (sSelectedKindIndex >= (NSInteger)kindCap && kindCap > 0) sSelectedKindIndex = 0;

        // 顶栏仍显示 Legado 源名（donor 只用于建壳）
        if (srcName.length > 0) {
            @try { host.navigationItem.title = srcName; } @catch (__unused NSException *e) {}
            @try { host.title = srcName; } @catch (__unused NSException *e) {}
        }

        LBAppendNativeMarker([NSString stringWithFormat:@"nativeHeader host=%@ src=%@ donor=%lu legadoKinds=%lu sel=%ld",
                              NSStringFromClass([host class]), srcName ?: @"",
                              (unsigned long)donorTitles.count, (unsigned long)kinds.count,
                              (long)sSelectedKindIndex]);
        LBAppendNativeHostState(host, @"feedDone");
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

/// 把零尺寸原生表拉回可见区域；去掉盖在 host 上的空 LBLT
static void LBRepairDiscoverTableFrame(UIViewController *host, UIViewController *listVC, UITableView *tv) {
    if (!host || !tv) return;
    static const NSInteger kLBLT = 0x4C424C54;
    if (host.isViewLoaded && host.view) {
        NSMutableArray *junk = [NSMutableArray array];
        for (UIView *sub in host.view.subviews) {
            if ([sub isKindOfClass:[UITableView class]] && sub.tag == kLBLT && sub != tv) {
                [junk addObject:sub];
            }
        }
        for (UIView *v in junk) {
            [v removeFromSuperview];
            LBAppendNativeMarker(@"ensureListSurface remove host LBLT");
        }
    }

    CGRect fr = tv.frame;
    BOOL bad = (fr.size.width < 2 || fr.size.height < 2);
    if (!bad) return;

    UIView *container = tv.superview;
    if (!container && listVC.isViewLoaded) container = listVC.view;
    CGRect target = container ? container.bounds : CGRectZero;
    if (target.size.width < 2 || target.size.height < 2) {
        id scroll = nil;
        @try { scroll = [host valueForKey:@"pageContentScrollView"]; } @catch (__unused NSException *e) {}
        if ([scroll isKindOfClass:[UIView class]]) target = [(UIView *)scroll bounds];
    }
    if (target.size.width < 2 || target.size.height < 2) {
        if (host.isViewLoaded) {
            CGFloat top = 132;
            id titleView = nil;
            @try { titleView = [host valueForKey:@"pageTitleView"]; } @catch (__unused NSException *e) {}
            if ([titleView isKindOfClass:[UIView class]]) {
                top = MAX(top, CGRectGetMaxY([(UIView *)titleView frame]));
            }
            target = CGRectMake(0, 0, host.view.bounds.size.width,
                                MAX(200, host.view.bounds.size.height - top));
        }
    }
    if (target.size.width < 2 || target.size.height < 2) return;
    tv.frame = target;
    tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tv.hidden = NO;
    tv.alpha = 1;
    if (tv.superview) [tv.superview setNeedsLayout];
    LBAppendNativeMarker([NSString stringWithFormat:
                          @"repairTV frame %.0fx%.0f owner=%@",
                          target.size.width, target.size.height,
                          listVC ? NSStringFromClass([listVC class]) : @"-"]);
}

/// 优先修复 BookListCon 原生表；仅无子页时才建 LBLT（禁止盖住分类条的全屏脏表）
UITableView *LBEnsureDiscoverListSurface(UIViewController *host) {
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
                tv.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1];
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
    neu.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1];
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
            container.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1];
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

/// 书列表灌入后：软刷新；无表时建 LBLT（不建 LBDT 全屏脏表）
void LBReloadDiscoverNativeList(UIViewController *host) {
    if (!host) return;
    LBRevealDiscoverTitleAndList(host);
    UITableView *tv = LBEnsureDiscoverListSurface(host);
    if (!tv) {
        LBAppendNativeMarker(@"reload skip: no list surface");
        return;
    }
    @try {
        // 已有表：不改 frame / 不 bringToFront；LBLT 可保留我们设的 DS
        BOOL isLBLT = (tv.tag == 0x4C424C54);
        if (isLBLT && (!tv.dataSource || tv.dataSource == (id)[NSNull null])) {
            UIViewController *listVC = LBActiveDiscoverListVC(host) ?: host;
            LBEnsurePlazaListTableHooks([listVC class]);
            tv.dataSource = (id<UITableViewDataSource>)listVC;
            tv.delegate = (id<UITableViewDelegate>)listVC;
        }
        [tv reloadData];
        NSInteger rows = 0;
        @try { rows = [tv numberOfRowsInSection:0]; } @catch (__unused NSException *e) {}
        static NSInteger sReloadLog = 0;
        if (sReloadLog < 8) {
            LBAppendNativeMarker([NSString stringWithFormat:
                                  @"reload soft tv=%.0fx%.0f@%.0f,%.0f rows=%ld ds=%@ tag=%ld",
                                  tv.frame.size.width, tv.frame.size.height,
                                  tv.frame.origin.x, tv.frame.origin.y,
                                  (long)rows,
                                  tv.dataSource ? NSStringFromClass([tv.dataSource class]) : @"nil",
                                  (long)tv.tag]);
            sReloadLog++;
        }
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
    if (index < 0 || index > 64) {
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
            LBReloadDiscoverNativeList(h);
        });
    }
}

static void LBDiscover_onHeaderBtn(id self, SEL _cmd, id sender) {
    // 标签墙点击：先走原生，再按按钮标题匹配 Legado kind
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
            LBReloadDiscoverNativeList(h);
        });
    }
}

static void LBDiscover_onSwitchBtn(id self, SEL _cmd) {
    // 发现态也走香色原生切换（XBS + 已同步的 Legado），禁止自造 ActionSheet
    if (sOrig_onSwitchBtn) {
        sOrig_onSwitchBtn(self, _cmd);
        return;
    }
}

static void LBDiscover_onSwitchBtnArg(id self, SEL _cmd, id sender) {
    if (sOrig_onSwitchBtnArg) {
        sOrig_onSwitchBtnArg(self, _cmd, sender);
        return;
    }
    if (sOrig_onSwitchBtn) sOrig_onSwitchBtn(self, @selector(onSwitchBtnEvent));
}

/// 按源名在可发现 Legado 列表里找 url；找不到返回 nil（视为纯 XBS）
static NSString *LBFindLegadoExploreUrlByName(NSString *name) {
    if (name.length == 0) return nil;
    id core = LBKindCore();
    if (!core) return nil;
    NSArray *rows = LBParseJSONArray(
        ([core respondsToSelector:@selector(exploreCapableSourcesJSON)]
         ? [core valueForKey:@"exploreCapableSourcesJSON"] : @"[]"));
    for (id row in rows) {
        if (![row isKindOfClass:[NSDictionary class]]) continue;
        NSString *n = row[@"name"];
        NSString *u = row[@"url"];
        if (![n isKindOfClass:[NSString class]] || ![u isKindOfClass:[NSString class]]) continue;
        if ([n isEqualToString:name]) return u;
    }
    for (id row in rows) {
        if (![row isKindOfClass:[NSDictionary class]]) continue;
        NSString *n = row[@"name"];
        NSString *u = row[@"url"];
        if (![n isKindOfClass:[NSString class]] || ![u isKindOfClass:[NSString class]]) continue;
        if ([n containsString:name] || [name containsString:n]) return u;
    }
    // dicModel 带 legadoBridge 时，用 selected 或按名再试
    return nil;
}

static BOOL LBDicModelLooksLegado(id dic) {
    if (![dic isKindOfClass:[NSDictionary class]]) return NO;
    id m = dic[@"legadoBridge"] ?: dic[@"fromLegadoBridge"];
    if ([m isKindOfClass:[NSString class]] && [(NSString *)m length] > 0) return YES;
    if ([m isKindOfClass:[NSNumber class]] && [m boolValue]) return YES;
    return NO;
}

/// 原生切换书源完成后：Legado → 按该源 exploreUrl 刷新分类+灌书；XBS → 保留原生 bookWorld，清 Legado 残留
static void LBHandleDiscoverSourceSwitched(UIViewController *host, NSString *sourceName) {
    if (!host || sourceName.length == 0) return;
    LBSetDiscoverTabActive(YES);
    sSelectedKindIndex = 0;
    sLastFeedSig = nil;
    sDiscoverUseSourceName = [sourceName copy];

    @try { host.navigationItem.title = sourceName; } @catch (__unused NSException *e) {}
    @try { host.title = sourceName; } @catch (__unused NSException *e) {}
    @try { [host setValue:sourceName forKey:@"useSourceName"]; } @catch (__unused NSException *e) {}
    @try { [host setValue:sourceName forKey:@"lastSourceName"]; } @catch (__unused NSException *e) {}
    @try { [host setValue:sourceName forKey:@"sourceName"]; } @catch (__unused NSException *e) {}

    id dic = nil;
    @try { dic = [host valueForKey:@"dicModel"]; } @catch (__unused NSException *e) {}
    NSString *legadoUrl = LBFindLegadoExploreUrlByName(sourceName);
    BOOL isLegado = (legadoUrl.length > 0) || LBDicModelLooksLegado(dic);

    LBAppendNativeMarker([NSString stringWithFormat:
                          @"nativeSwitch name=%@ legado=%d url=%@",
                          sourceName, isLegado ? 1 : 0, legadoUrl ?: @"-"]);

    if (!isLegado) {
        // 纯 XBS：分类/标签/书都交给原生 openConfig 结果，清掉我们强加的 kinds
        sCachedKinds = nil;
        @try { LBClearDiscoverExploreBooks(); } @catch (__unused NSException *e) {}
        // 顶栏跟 dicModel.arrHeaderBtnTitle / bookWorld keys
        NSArray *donorTitles = LBDonorTitlesFromHost(host, [dic isKindOfClass:[NSDictionary class]] ? dic : nil);
        if (donorTitles.count > 0) {
            LBForceLegadoTitlesOnChrome(host, donorTitles);
        }
        LBAppendNativeMarker([NSString stringWithFormat:@"nativeSwitch XBS titles=%lu",
                              (unsigned long)donorTitles.count]);
        return;
    }

    id core = LBKindCore();
    if (core && legadoUrl.length > 0) {
        @try { [core setValue:legadoUrl forKey:@"selectedExploreSourceUrl"]; } @catch (__unused NSException *e) {}
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
                host.view.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1];
            }
        } @catch (__unused NSException *e) {}
    }
    LBApplyLegadoSourceKindsToChrome(host, kinds, sourceName);
    UITableView *surface = LBEnsureDiscoverListSurface(host);
    NSString *kindUrl = nil;
    if (kinds.count > 0 && [kinds[0][@"url"] isKindOfClass:[NSString class]]) {
        kindUrl = kinds[0][@"url"];
    }
    LBAppendNativeMarker([NSString stringWithFormat:
                          @"nativeSwitch Legado kinds=%lu kind0=%@ surface=%d",
                          (unsigned long)kinds.count, kindUrl ?: @"-",
                          surface ? 1 : 0]);
    if (legadoUrl.length == 0) return;

    NSString *srcCopy = [legadoUrl copy];
    NSString *kindCopy = [kindUrl copy];
    __weak UIViewController *weakHost = host;
    // 只 explore 一次；勿再 ForceTitles（会拆层级）。clear 已在 Core 内防抖。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIViewController *h = weakHost;
        if (!h || !LBIsDiscoverTabActive()) return;
        LBEnsureDiscoverListSurface(h);
        LBTriggerExploreKind(srcCopy, kindCopy);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIViewController *h2 = weakHost;
            if (!h2 || !LBIsDiscoverTabActive()) return;
            LBEnsureDiscoverListSurface(h2);
            LBReloadDiscoverNativeList(h2);
            id tv = nil;
            @try { tv = [h2 valueForKey:@"pageTitleView"]; } @catch (__unused NSException *e) {}
            if (tv) LBPaintTitleLabels(tv, sSelectedKindIndex);
        });
    });
}

static void LBDiscover_openConfigByName(id self, SEL _cmd, NSString *name) {
    if (sOrig_openConfigByName) {
        sOrig_openConfigByName(self, _cmd, name);
    }
    // 建壳阶段的 openConfig 不算用户切换
    if (sFeedingDiscoverHeader) return;
    if (!(LBIsDiscoverTabActive() || sNativeChromeBuilt || LBSelfLooksDiscoverWorldHost(self))) return;
    if (![name isKindOfClass:[NSString class]] || name.length == 0) return;
    UIViewController *host = [self isKindOfClass:[UIViewController class]]
        ? (UIViewController *)self : LBPrimaryDiscoverHost();
    NSString *nameCopy = [name copy];
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

    // 导航栏真实源名优先（避免 selectedExplore 卡在旧的速读谷、屏上却是领域书库）
    NSString *hostName = nil;
    @try { hostName = host.navigationItem.title; } @catch (__unused NSException *e) {}
    if (hostName.length == 0) @try { hostName = host.title; } @catch (__unused NSException *e) {}
    if (hostName.length == 0) @try {
        id v = [host valueForKey:@"useSourceName"];
        if ([v isKindOfClass:[NSString class]]) hostName = v;
    } @catch (__unused NSException *e) {}
    if (hostName.length > 0) {
        NSString *byName = LBFindLegadoExploreUrlByName(hostName);
        if (byName.length > 0) {
            @try { [core setValue:byName forKey:@"selectedExploreSourceUrl"]; } @catch (__unused NSException *e) {}
            LBAppendNativeMarker([NSString stringWithFormat:@"syncExploreFromNav name=%@ url=%@",
                                  hostName, byName]);
        }
    }

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
}
