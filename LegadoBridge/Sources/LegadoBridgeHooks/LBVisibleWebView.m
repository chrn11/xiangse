#import "LBInternal.h"
#import <WebKit/WebKit.h>

/// 可见 WebView：优先香色原生入口，否则回退本模块 WKWebView。
/// Mach-O 差分：`openWebViewWithUrlStr:` 实现在 `LCStandarConfig`（非 VC/AppDelegate）；
/// 体内转发 `[LCControllerManager sharedInstance] show:@"WebViewController_WK" params:@{url:} parent:nil showType:0`。
/// `loginWebView` 为 `ReadVCBase1` 的 `WebViewController_WK` ivar，不是开页入口。

static void LBVisibleWVMarker(NSString *line) {
    if (line.length == 0) return;
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_visible_webview.txt"];
    NSString *full = [NSString stringWithFormat:@"%@ | %@\n", [NSDate date], line];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [full writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    } else {
        [fh seekToEndOfFile];
        [fh writeData:[full dataUsingEncoding:NSUTF8StringEncoding]];
        [fh synchronizeFile];
        [fh closeFile];
    }
}

static UIViewController *LBVisibleTopVC(void) {
    UIWindow *win = LBLegadoKeyWindow();
    UIViewController *root = win.rootViewController;
    while (root.presentedViewController) root = root.presentedViewController;
    if ([root isKindOfClass:[UINavigationController class]]) {
        UIViewController *top = ((UINavigationController *)root).visibleViewController;
        if (top) return top;
    }
    if ([root isKindOfClass:[UITabBarController class]]) {
        UIViewController *sel = ((UITabBarController *)root).selectedViewController;
        if ([sel isKindOfClass:[UINavigationController class]]) {
            return ((UINavigationController *)sel).visibleViewController ?: sel;
        }
        if (sel) return sel;
    }
    return root;
}

static void LBVisibleCollectVCs(UIViewController *vc, NSMutableArray *out) {
    if (!vc) return;
    [out addObject:vc];
    for (UIViewController *child in vc.childViewControllers) {
        LBVisibleCollectVCs(child, out);
    }
    if (vc.presentedViewController) {
        LBVisibleCollectVCs(vc.presentedViewController, out);
    }
    if ([vc isKindOfClass:[UINavigationController class]]) {
        for (UIViewController *c in ((UINavigationController *)vc).viewControllers) {
            LBVisibleCollectVCs(c, out);
        }
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        for (UIViewController *c in ((UITabBarController *)vc).viewControllers) {
            LBVisibleCollectVCs(c, out);
        }
    }
}

static BOOL LBTryCallOpenWebView(NSString *urlStr) {
    SEL sel = NSSelectorFromString(@"openWebViewWithUrlStr:");

    // 主路径（香色规格）：LCStandarConfig -openWebViewWithUrlStr:
    // self 在 IMP 内未使用，alloc/init 即可；由 LCControllerManager present WK VC。
    Class cfgCls = NSClassFromString(@"LCStandarConfig");
    if (cfgCls) {
        id cfg = [[cfgCls alloc] init];
        if (cfg && [cfg respondsToSelector:sel]) {
            LBVisibleWVMarker([NSString stringWithFormat:
                               @"path=XiangseOpenWebView hit class=%@ url=%@",
                               NSStringFromClass([cfg class]), urlStr]);
            ((void (*)(id, SEL, NSString *))objc_msgSend)(cfg, sel, urlStr);
            return YES;
        }
        LBVisibleWVMarker([NSString stringWithFormat:
                           @"path=XiangseOpenWebView LCStandarConfig no-sel cfg=%@",
                           cfg ? @"ok" : @"nil"]);
    } else {
        LBVisibleWVMarker(@"path=XiangseOpenWebView LCStandarConfig class-missing");
    }

    // 次路径：VC 树 / AppDelegate 上若挂有同名选择子（历史扫描，通常无）
    UIWindow *win = LBLegadoKeyWindow();
    NSMutableArray *cands = [NSMutableArray array];
    id appDel = UIApplication.sharedApplication.delegate;
    if (appDel) [cands addObject:appDel];
    if (win.rootViewController) {
        LBVisibleCollectVCs(win.rootViewController, cands);
    }
    for (id obj in cands) {
        if ([obj respondsToSelector:sel]) {
            LBVisibleWVMarker([NSString stringWithFormat:
                               @"path=XiangseOpenWebView hit class=%@ url=%@",
                               NSStringFromClass([obj class]), urlStr]);
            ((void (*)(id, SEL, NSString *))objc_msgSend)(obj, sel, urlStr);
            return YES;
        }
    }

    // 直调 LCControllerManager（与 LCStandarConfig IMP 等价，作差分备份）
    Class mgrCls = NSClassFromString(@"LCControllerManager");
    SEL sharedSel = NSSelectorFromString(@"sharedInstance");
    SEL showSel = NSSelectorFromString(@"show:params:parent:showType:");
    if (mgrCls && [mgrCls respondsToSelector:sharedSel]) {
        id mgr = ((id (*)(id, SEL))objc_msgSend)(mgrCls, sharedSel);
        if (mgr && [mgr respondsToSelector:showSel]) {
            NSDictionary *params = urlStr.length ? @{@"url": urlStr} : @{};
            LBVisibleWVMarker([NSString stringWithFormat:
                               @"path=XiangseOpenWebView hit class=LCControllerManager via=show url=%@",
                               urlStr]);
            ((void (*)(id, SEL, NSString *, NSDictionary *, id, int))objc_msgSend)(
                mgr, showSel, @"WebViewController_WK", params, nil, 0);
            return YES;
        }
    }

    LBVisibleWVMarker(@"path=XiangseOpenWebView miss");
    return NO;
}

static void LBSaveCookieStringToJar(NSString *cookieStr, NSString *pageUrl, NSString *sourceUrl) {
    if (cookieStr.length == 0) return;
    id core = LBLegadoCoreIfReady();
    SEL sel = @selector(saveCookieJarForUrl:cookieString:);
    if (core && [core respondsToSelector:sel]) {
        NSString *key = sourceUrl.length > 0 ? sourceUrl : pageUrl;
        ((void (*)(id, SEL, NSString *, NSString *))objc_msgSend)(core, sel, key ?: @"", cookieStr);
        if (pageUrl.length > 0 && ![pageUrl isEqualToString:key]) {
            ((void (*)(id, SEL, NSString *, NSString *))objc_msgSend)(core, sel, pageUrl, cookieStr);
        }
        LBVisibleWVMarker([NSString stringWithFormat:
                           @"cookieJarSaved len=%lu key=%@",
                           (unsigned long)cookieStr.length, key ?: @""]);
    } else {
        // 兜底落盘，供后续手工核对
        NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_login_cookie.txt"];
        [cookieStr writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        LBVisibleWVMarker(@"cookieJar core missing; wrote legado_login_cookie.txt");
    }
}

static void LBHarvestWKCookies(WKWebView *webView, NSString *pageUrl, NSString *sourceUrl, void (^done)(void)) {
    if (!webView) {
        if (done) done();
        return;
    }
    WKHTTPCookieStore *store = webView.configuration.websiteDataStore.httpCookieStore;
    [store getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
        NSMutableArray *parts = [NSMutableArray array];
        NSURL *u = [NSURL URLWithString:pageUrl ?: @""];
        NSString *host = u.host.lowercaseString ?: @"";
        for (NSHTTPCookie *ck in cookies) {
            if (host.length > 0) {
                NSString *dh = ck.domain.lowercaseString ?: @"";
                NSString *h = host;
                if (dh.length > 0 && ![h hasSuffix:dh] && ![dh hasSuffix:h] && ![h isEqualToString:dh]) {
                    // 宽松：仍收录（过盾 Cookie 常挂在父域）
                }
            }
            [parts addObject:[NSString stringWithFormat:@"%@=%@", ck.name, ck.value]];
        }
        NSString *joined = [parts componentsJoinedByString:@"; "];
        LBSaveCookieStringToJar(joined, pageUrl, sourceUrl);
        if (done) done();
    }];
}

@interface LBVisibleWebViewController : UIViewController <WKNavigationDelegate>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, copy) NSString *pageURL;
@property (nonatomic, copy) NSString *sourceURL;
@property (nonatomic, copy) NSString *modeTag;
@end

@implementation LBVisibleWebViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.whiteColor;
    self.title = self.modeTag.length ? self.modeTag : @"网页";
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"完成"
                                         style:UIBarButtonItemStyleDone
                                        target:self
                                        action:@selector(onDone)];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"回灌Cookie"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(onHarvest)];

    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    self.webView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:cfg];
    self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.webView.navigationDelegate = self;
    [self.view addSubview:self.webView];

    NSURL *url = [NSURL URLWithString:self.pageURL ?: @""];
    if (url) {
        [self.webView loadRequest:[NSURLRequest requestWithURL:url]];
        LBVisibleWVMarker([NSString stringWithFormat:
                           @"path=FallbackWKWebView load url=%@ mode=%@",
                           self.pageURL ?: @"", self.modeTag ?: @""]);
    }
}

- (void)onHarvest {
    __weak typeof(self) weakSelf = self;
    LBHarvestWKCookies(self.webView, self.webView.URL.absoluteString ?: self.pageURL, self.sourceURL, ^{
        LBVisibleWVMarker(@"manual harvest done");
        (void)weakSelf;
    });
}

- (void)onDone {
    __weak typeof(self) weakSelf = self;
    NSString *cur = self.webView.URL.absoluteString ?: self.pageURL;
    LBHarvestWKCookies(self.webView, cur, self.sourceURL, ^{
        LBVisibleWVMarker([NSString stringWithFormat:@"done dismiss url=%@", cur ?: @""]);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (weakSelf.navigationController.presentingViewController) {
                [weakSelf.navigationController dismissViewControllerAnimated:YES completion:nil];
            } else if (weakSelf.navigationController) {
                [weakSelf.navigationController popViewControllerAnimated:YES];
            } else {
                [weakSelf dismissViewControllerAnimated:YES completion:nil];
            }
        });
    });
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    LBVisibleWVMarker([NSString stringWithFormat:@"didFinish url=%@", webView.URL.absoluteString ?: @""]);
    // 自动尝试回灌一次（过盾后 Cookie 常在此时就绪）
    LBHarvestWKCookies(webView, webView.URL.absoluteString ?: self.pageURL, self.sourceURL, nil);
}

@end

static void LBPresentFallbackWK(NSString *urlStr, NSString *sourceUrl, NSString *modeTag) {
    LBVisibleWebViewController *vc = [[LBVisibleWebViewController alloc] init];
    vc.pageURL = urlStr;
    vc.sourceURL = sourceUrl ?: @"";
    vc.modeTag = modeTag.length ? modeTag : @"可见WebView";
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    UIViewController *top = LBVisibleTopVC();
    if (!top) {
        LBVisibleWVMarker(@"present fail: no top VC");
        return;
    }
    [top presentViewController:nav animated:YES completion:^{
        LBVisibleWVMarker(@"fallback presented");
    }];
}

static WKWebView *LBFindNativeWKWebView(void) {
    UIWindow *win = LBLegadoKeyWindow();
    NSMutableArray *cands = [NSMutableArray array];
    if (win.rootViewController) {
        LBVisibleCollectVCs(win.rootViewController, cands);
    }
    for (id obj in cands) {
        if (![obj isKindOfClass:[UIViewController class]]) continue;
        // WebViewController_Base ivar myWebView
        @try {
            id wv = [obj valueForKey:@"myWebView"];
            if ([wv isKindOfClass:[WKWebView class]]) return (WKWebView *)wv;
        } @catch (__unused NSException *ex) {}
        if ([obj respondsToSelector:@selector(view)]) {
            UIView *v = [obj view];
            if ([v isKindOfClass:[WKWebView class]]) return (WKWebView *)v;
            for (UIView *sub in v.subviews) {
                if ([sub isKindOfClass:[WKWebView class]]) return (WKWebView *)sub;
            }
        }
    }
    return nil;
}

static void LBHarvestNativeXiangseCookies(NSString *urlStr, NSString *sourceUrl) {
    WKWebView *wk = LBFindNativeWKWebView();
    if (wk) {
        NSString *page = wk.URL.absoluteString.length ? wk.URL.absoluteString : urlStr;
        LBHarvestWKCookies(wk, page, sourceUrl, ^{
            LBVisibleWVMarker(@"xiangse path WKCookieStore harvest done");
        });
        return;
    }
    NSHTTPCookieStorage *store = NSHTTPCookieStorage.sharedHTTPCookieStorage;
    NSMutableArray *parts = [NSMutableArray array];
    for (NSHTTPCookie *ck in store.cookies ?: @[]) {
        [parts addObject:[NSString stringWithFormat:@"%@=%@", ck.name, ck.value]];
    }
    if (parts.count > 0) {
        LBSaveCookieStringToJar([parts componentsJoinedByString:@"; "], urlStr, sourceUrl);
    }
    LBVisibleWVMarker(@"xiangse path NSHTTPCookieStorage snapshot (no WK found)");
}

void LBPresentVisibleWebView(NSString *urlStr, NSString *sourceUrl, NSString *modeTag) {
    if (urlStr.length == 0) {
        LBVisibleWVMarker(@"abort empty url");
        return;
    }
    [[NSString stringWithFormat:@"open visibleWV url=%@ src=%@ mode=%@",
      urlStr, sourceUrl ?: @"", modeTag ?: @""]
        writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_visible_webview_open.txt"]
        atomically:YES encoding:NSUTF8StringEncoding error:NULL];

    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL usedNative = LBTryCallOpenWebView(urlStr);
        if (usedNative) {
            // 香色 WK 的 Cookie 在 WKHTTPCookieStore；延迟从原生 VC 的 myWebView 回灌
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                LBHarvestNativeXiangseCookies(urlStr, sourceUrl);
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                LBHarvestNativeXiangseCookies(urlStr, sourceUrl);
            });
            return;
        }
        LBPresentFallbackWK(urlStr, sourceUrl, modeTag);
    });
}

void LBPresentLoginWebViewForSource(NSString *sourceUrl) {
    NSString *loginUrl = nil;
    id core = LBLegadoCoreIfReady();
    if (core && [core respondsToSelector:@selector(loginUrlForSourceUrl:)]) {
        loginUrl = ((NSString * (*)(id, SEL, NSString *))objc_msgSend)(
            core, @selector(loginUrlForSourceUrl:), sourceUrl);
    }
    if (loginUrl.length == 0) {
        // 无 loginUrl：打开书源根站，便于过盾写 Cookie（起点等场景）
        loginUrl = sourceUrl.length ? sourceUrl : @"https://www.qidian.com/";
    }
    LBPresentVisibleWebView(loginUrl, sourceUrl, @"书源登录/过盾");
}
