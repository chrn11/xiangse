#import "LBInternal.h"
#import <WebKit/WebKit.h>

/// 可见 WebView：优先调用香色 `openWebViewWithUrlStr:` / `WebViewController_WK`；
/// 找不到时回退为本模块 WKWebView 容器。完成后 Cookie → CookieJar。

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
                               @"path=XiangseOpenWebView class=%@ url=%@",
                               NSStringFromClass([obj class]), urlStr]);
            ((void (*)(id, SEL, NSString *))objc_msgSend)(obj, sel, urlStr);
            return YES;
        }
    }
    // 尝试 WebViewController_WK 实例方法 / 类方法
    Class wk = NSClassFromString(@"WebViewController_WK");
    if (wk) {
        if ([wk respondsToSelector:sel]) {
            LBVisibleWVMarker([NSString stringWithFormat:
                               @"path=XiangseWKClassMethod url=%@", urlStr]);
            ((void (*)(id, SEL, NSString *))objc_msgSend)(wk, sel, urlStr);
            return YES;
        }
        // alloc/init 常见形态后 push
        id inst = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        if ([wk instancesRespondToSelector:@selector(init)]) {
            inst = [[wk alloc] init];
        }
#pragma clang diagnostic pop
        if (inst && [inst respondsToSelector:sel]) {
            LBVisibleWVMarker([NSString stringWithFormat:
                               @"path=XiangseWKInstance url=%@", urlStr]);
            ((void (*)(id, SEL, NSString *))objc_msgSend)(inst, sel, urlStr);
            UIViewController *top = LBVisibleTopVC();
            if ([inst isKindOfClass:[UIViewController class]] && top.navigationController) {
                [top.navigationController pushViewController:(UIViewController *)inst animated:YES];
                return YES;
            }
            if ([inst isKindOfClass:[UIViewController class]] && top) {
                UINavigationController *nav = [[UINavigationController alloc]
                    initWithRootViewController:(UIViewController *)inst];
                nav.modalPresentationStyle = UIModalPresentationFullScreen;
                [top presentViewController:nav animated:YES completion:nil];
                return YES;
            }
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
            // 香色路径无直接 Cookie 回调：延迟从 NSHTTPCookieStorage 抽一份
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                NSHTTPCookieStorage *store = NSHTTPCookieStorage.sharedHTTPCookieStorage;
                NSMutableArray *parts = [NSMutableArray array];
                for (NSHTTPCookie *ck in store.cookies ?: @[]) {
                    [parts addObject:[NSString stringWithFormat:@"%@=%@", ck.name, ck.value]];
                }
                if (parts.count > 0) {
                    LBSaveCookieStringToJar([parts componentsJoinedByString:@"; "], urlStr, sourceUrl);
                }
                LBVisibleWVMarker(@"xiangse path cookie snapshot attempted");
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
