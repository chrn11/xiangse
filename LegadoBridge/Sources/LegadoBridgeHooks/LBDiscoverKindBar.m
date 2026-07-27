#import "LBInternal.h"
#import "LegadoBridge.h"

/// Reader0 对齐：发现壳上挂分类标签栏；点标签拉该 kind 的书列表。

static const NSInteger kLBKindBarTag = 0x4C424B42; // 'LBKB'
static const NSInteger kLBOverlayTVTag = 0x4C425056; // 'LBPV'
static NSInteger sSelectedKindIndex = 0;

@interface LBKindBarTarget : NSObject
+ (instancetype)shared;
- (void)onKind:(UIButton *)sender;
- (void)onSwitch:(id)sender;
@end

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

static void LBSetHostNavTitle(UIViewController *host, NSString *title) {
    if (!host || title.length == 0) return;
    @try { host.navigationItem.title = title; } @catch (__unused NSException *e) {}
    @try { host.title = title; } @catch (__unused NSException *e) {}
}

static void LBLayoutDiscoverOverlay(UIViewController *host, CGFloat kindH) {
    if (!host.isViewLoaded || !host.view) return;
    UIView *root = host.view;
    CGFloat y = 0;
    UIView *bar = [root viewWithTag:kLBKindBarTag];
    if (bar) {
        bar.frame = CGRectMake(0, y, root.bounds.size.width, kindH);
    }
    for (UIView *sub in root.subviews) {
        if (sub.tag == kLBOverlayTVTag && [sub isKindOfClass:[UITableView class]]) {
            CGFloat ty = y + (bar ? kindH : 0);
            sub.frame = CGRectMake(0, ty, root.bounds.size.width, MAX(0, root.bounds.size.height - ty));
            break;
        }
    }
    if (bar) [root bringSubviewToFront:bar];
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

void LBRefreshDiscoverKindBar(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ LBRefreshDiscoverKindBar(); });
        return;
    }
    if (!LBIsDiscoverTabActive()) return;
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
    if (srcName.length > 0) LBSetHostNavTitle(host, srcName);

    NSString *kindsJSON = @"[]";
    if ([core respondsToSelector:@selector(exploreKindsJSONForSourceUrl:)]) {
        kindsJSON = ((NSString *(*)(id, SEL, NSString *))objc_msgSend)(
            core, @selector(exploreKindsJSONForSourceUrl:), src);
    }
    NSArray *kinds = LBParseJSONArray(kindsJSON);
    if (sSelectedKindIndex >= (NSInteger)kinds.count) sSelectedKindIndex = 0;

    UIView *root = host.view;
    UIScrollView *bar = (UIScrollView *)[root viewWithTag:kLBKindBarTag];
    if (![bar isKindOfClass:[UIScrollView class]]) {
        bar = [[UIScrollView alloc] initWithFrame:CGRectZero];
        bar.tag = kLBKindBarTag;
        bar.showsHorizontalScrollIndicator = NO;
        bar.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1.0];
        bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [root addSubview:bar];
    }
    for (UIView *v in [bar.subviews copy]) [v removeFromSuperview];

    CGFloat x = 10;
    CGFloat h = 40;
    CGFloat btnH = 30;
    NSInteger i = 0;
    for (id item in kinds) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSString *title = item[@"title"] ?: @"分类";
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:title forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        BOOL on = (i == sSelectedKindIndex);
        UIColor *c = on
            ? [UIColor colorWithRed:0.35 green:0.62 blue:1 alpha:1]
            : [UIColor colorWithWhite:0.85 alpha:1];
        [b setTitleColor:c forState:UIControlStateNormal];
        [b sizeToFit];
        CGFloat w = MAX(44, b.bounds.size.width + 16);
        b.frame = CGRectMake(x, 5, w, btnH);
        b.tag = 1000 + i;
        [b addTarget:[LBKindBarTarget shared]
              action:@selector(onKind:)
    forControlEvents:UIControlEventTouchUpInside];
        [bar addSubview:b];
        x += w + 6;
        if (i + 1 < (NSInteger)kinds.count) {
            UILabel *dot = [[UILabel alloc] initWithFrame:CGRectMake(x, 5, 10, btnH)];
            dot.text = @"·";
            dot.textColor = [UIColor colorWithWhite:0.45 alpha:1];
            dot.font = [UIFont systemFontOfSize:14];
            [bar addSubview:dot];
            x += 12;
        }
        i++;
    }
    UIButton *sw = [UIButton buttonWithType:UIButtonTypeSystem];
    [sw setTitle:@"切换源" forState:UIControlStateNormal];
    sw.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    [sw setTitleColor:[UIColor colorWithRed:0.35 green:0.62 blue:1 alpha:1]
              forState:UIControlStateNormal];
    [sw sizeToFit];
    sw.frame = CGRectMake(x + 8, 5, MAX(56, sw.bounds.size.width + 12), btnH);
    [sw addTarget:[LBKindBarTarget shared]
            action:@selector(onSwitch:)
  forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:sw];
    x = CGRectGetMaxX(sw.frame) + 12;
    bar.contentSize = CGSizeMake(MAX(x, root.bounds.size.width), h);

    LBLayoutDiscoverOverlay(host, h);

    NSString *marker = [NSString stringWithFormat:@"kindBar src=%@ name=%@ kinds=%lu sel=%ld",
                        src ?: @"", srcName ?: @"", (unsigned long)kinds.count, (long)sSelectedKindIndex];
    [marker writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_discover_kindbar.txt"]
             atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

@implementation LBKindBarTarget
+ (instancetype)shared {
    static LBKindBarTarget *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [LBKindBarTarget new]; });
    return s;
}
- (void)onKind:(UIButton *)sender {
    NSInteger idx = sender.tag - 1000;
    sSelectedKindIndex = MAX(0, idx);
    id core = LBKindCore();
    if (!core) return;
    NSString *src = LBCurrentExploreSourceUrl(core);
    NSString *kindsJSON = @"[]";
    if ([core respondsToSelector:@selector(exploreKindsJSONForSourceUrl:)]) {
        kindsJSON = ((NSString *(*)(id, SEL, NSString *))objc_msgSend)(
            core, @selector(exploreKindsJSONForSourceUrl:), src);
    }
    NSArray *kinds = LBParseJSONArray(kindsJSON);
    if (idx < 0 || idx >= (NSInteger)kinds.count) return;
    NSDictionary *k = kinds[(NSUInteger)idx];
    NSString *url = [k[@"url"] isKindOfClass:[NSString class]] ? k[@"url"] : @"";
    LBRefreshDiscoverKindBar();
    LBTriggerExploreKind(src, url);
}
- (void)onSwitch:(id)sender {
    UIViewController *host = LBPrimaryDiscoverHost();
    if (host) LBPresentExploreSourcePicker(host);
}
@end
