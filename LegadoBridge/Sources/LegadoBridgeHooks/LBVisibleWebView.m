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
    // 真机：browserAwait 往 keyWindow / WebView VC 挂原生钮均会无崩溃报告退出→SpringBoard；
    // 完成验证改走 WK 页内 DOM 注入（见 LBStartBrowserAwait）。
    Class cfgCls = NSClassFromString(@"LCStandarConfig");
    if (cfgCls) {
        id cfg = [[cfgCls alloc] init];
        if (cfg && [cfg respondsToSelector:sel]) {
            LBVisibleWVMarker([NSString stringWithFormat:
                               @"path=XiangseOpenWebView hit class=%@ url=%@",
                               NSStringFromClass([cfg class]), urlStr]);
            @try {
                ((void (*)(id, SEL, NSString *))objc_msgSend)(cfg, sel, urlStr);
            } @catch (NSException *ex) {
                LBVisibleWVMarker([NSString stringWithFormat:
                                   @"path=XiangseOpenWebView exception class=%@ name=%@ reason=%@",
                                   NSStringFromClass([cfg class]), ex.name, ex.reason]);
                return NO;
            }
            LBVisibleWVMarker(@"path=XiangseOpenWebView returned class=LCStandarConfig");
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
            @try {
                ((void (*)(id, SEL, NSString *))objc_msgSend)(obj, sel, urlStr);
            } @catch (NSException *ex) {
                LBVisibleWVMarker([NSString stringWithFormat:
                                   @"path=XiangseOpenWebView exception class=%@ name=%@ reason=%@",
                                   NSStringFromClass([obj class]), ex.name, ex.reason]);
                continue;
            }
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
            @try {
                ((void (*)(id, SEL, NSString *, NSDictionary *, id, int))objc_msgSend)(
                    mgr, showSel, @"WebViewController_WK", params, nil, 0);
            } @catch (NSException *ex) {
                LBVisibleWVMarker([NSString stringWithFormat:
                                   @"path=XiangseOpenWebView exception class=LCControllerManager name=%@ reason=%@",
                                   ex.name, ex.reason]);
                return NO;
            }
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
        // 落盘 Cookie 原文（截断），供真机对照 /so 是否仍返回 var buid
        if (joined.length > 0) {
            NSString *dumpPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_cookie_dump.txt"];
            NSString *head = joined.length > 4000 ? [joined substringToIndex:4000] : joined;
            NSString *line = [NSString stringWithFormat:@"%@ | url=%@ src=%@ | %@\n",
                             [NSDate date], pageUrl ?: @"", sourceUrl ?: @"", head];
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:dumpPath];
            if (fh) {
                [fh seekToEndOfFile];
                [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
                [fh closeFile];
            } else {
                [line writeToFile:dumpPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            }
        }
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

static UIViewController *LBFindNativeWebViewController(void) {
    UIWindow *win = LBLegadoKeyWindow();
    NSMutableArray *cands = [NSMutableArray array];
    if (win.rootViewController) {
        LBVisibleCollectVCs(win.rootViewController, cands);
    }
    Class wkCls = NSClassFromString(@"WebViewController_WK");
    Class baseCls = NSClassFromString(@"WebViewController_Base");
    for (id obj in cands) {
        if (![obj isKindOfClass:[UIViewController class]]) continue;
        UIViewController *vc = (UIViewController *)obj;
        if (wkCls && [vc isKindOfClass:wkCls]) return vc;
        if (baseCls && [vc isKindOfClass:baseCls]) return vc;
        @try {
            id wv = [vc valueForKey:@"myWebView"];
            if ([wv isKindOfClass:[WKWebView class]]) return vc;
        } @catch (__unused NSException *ex) {}
    }
    return nil;
}

static WKWebView *LBFindNativeWKWebView(void) {
    UIViewController *vc = LBFindNativeWebViewController();
    if (vc) {
        @try {
            id wv = [vc valueForKey:@"myWebView"];
            if ([wv isKindOfClass:[WKWebView class]]) return (WKWebView *)wv;
        } @catch (__unused NSException *ex) {}
        if ([vc.view isKindOfClass:[WKWebView class]]) return (WKWebView *)vc.view;
        for (UIView *sub in vc.view.subviews) {
            if ([sub isKindOfClass:[WKWebView class]]) return (WKWebView *)sub;
        }
    }
    UIWindow *win = LBLegadoKeyWindow();
    NSMutableArray *cands = [NSMutableArray array];
    if (win.rootViewController) {
        LBVisibleCollectVCs(win.rootViewController, cands);
    }
    for (id obj in cands) {
        if (![obj isKindOfClass:[UIViewController class]]) continue;
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

/// 须在主线程调用：立刻走香色开页或 Fallback（不再套一层 dispatch_async）。
static BOOL LBPresentVisibleWebViewNow(NSString *urlStr, NSString *sourceUrl, NSString *modeTag) {
    BOOL usedNative = LBTryCallOpenWebView(urlStr);
    if (usedNative) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            LBHarvestNativeXiangseCookies(urlStr, sourceUrl);
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            LBHarvestNativeXiangseCookies(urlStr, sourceUrl);
        });
        return YES;
    }
    LBPresentFallbackWK(urlStr, sourceUrl, modeTag);
    return NO;
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

    if ([NSThread isMainThread]) {
        LBPresentVisibleWebViewNow(urlStr, sourceUrl, modeTag);
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        LBPresentVisibleWebViewNow(urlStr, sourceUrl, modeTag);
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
        // 无 loginUrl：打开书源根站，便于写 Cookie（起点等场景）
        loginUrl = sourceUrl.length ? sourceUrl : @"https://www.qidian.com/";
    }
    LBPresentVisibleWebView(loginUrl, sourceUrl, @"书源登录/验证");
}

#pragma mark - startBrowserAwait

/// 真机对照（f142774）：legado://webview 开同页存活；legado://browserAwait 在原生
/// 往 WebViewController_WK 挂 UIBarButtonItem/UIButton 后 ≤0.4s 无崩溃报告退出→SpringBoard。
/// 因此「完成验证」只注入到 WK 页面 DOM，用 JS 标志/轮询结束，禁止再改原生 VC 视图树。

static void LBBrowserAwaitFinish(void);

static dispatch_semaphore_t sBrowserAwaitSem = NULL;
static NSString *sBrowserAwaitHTML = nil;
static NSString *sBrowserAwaitSourceUrl = nil;
static NSString *sBrowserAwaitPageUrl = nil;
static BOOL sBrowserAwaitInjectLogged = NO;

/// 仅可在非主线程调用：WK completion 在主线程，主线程 wait 会死锁。
static NSString *LBEvalJSOnWK(WKWebView *wk, NSString *js, NSTimeInterval timeoutSec) {
    if (!wk || js.length == 0) return @"";
    if ([NSThread isMainThread]) {
        LBVisibleWVMarker(@"LBEvalJSOnWK refuse main-thread wait");
        return @"";
    }
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSString *out = @"";
    [wk evaluateJavaScript:js completionHandler:^(id r, NSError *err) {
        if ([r isKindOfClass:[NSString class]]) {
            out = (NSString *)r;
        } else if ([r isKindOfClass:[NSNumber class]]) {
            out = [(NSNumber *)r stringValue];
        } else if (r != nil) {
            out = [r description];
        }
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeoutSec * NSEC_PER_SEC)));
    return out ?: @"";
}

static NSString *LBBrowserAwaitInjectJS(void) {
    return @"((function(){\n"
           @"  try {\n"
           @"    if (document.getElementById('lb-await-done-btn')) return 'exists';\n"
           @"    var b = document.createElement('button');\n"
           @"    b.id = 'lb-await-done-btn';\n"
           @"    b.type = 'button';\n"
           @"    b.setAttribute('aria-label', '完成验证');\n"
           @"    b.textContent = '完成验证';\n"
           @"    b.style.cssText = 'position:fixed;top:12px;right:12px;z-index:2147483647;"
           @"padding:10px 16px;background:rgba(0,0,0,0.78);color:#fff;border:none;"
           @"border-radius:8px;font:bold 16px -apple-system,sans-serif;';\n"
           @"    b.onclick = function(){\n"
           @"      try { document.cookie = 'LB_AWAIT_DONE=1; path=/; max-age=600'; } catch(e) {}\n"
           @"      window.__lbAwaitDone = 1;\n"
           @"      try {\n"
           @"        if (document.title.indexOf('LB_AWAIT_DONE') !== 0) {\n"
           @"          document.title = 'LB_AWAIT_DONE|' + document.title;\n"
           @"        }\n"
           @"      } catch(e2) {}\n"
           @"    };\n"
           @"    (document.body || document.documentElement).appendChild(b);\n"
           @"    return 'injected';\n"
           @"  } catch (err) { return 'err:' + String(err); }\n"
           @"})())";
}

static NSString *LBBrowserAwaitPollJS(void) {
    return @"((function(){\n"
           @"  var done = (window.__lbAwaitDone === 1) ? '1' : '0';\n"
           @"  var hasBtn = document.getElementById('lb-await-done-btn') ? '1' : '0';\n"
           @"  var ck = '';\n"
           @"  try { ck = String(document.cookie || ''); } catch (e) {}\n"
           @"  var ttl = '';\n"
           @"  try { ttl = String(document.title || ''); } catch (e2) {}\n"
           @"  return done + '|' + hasBtn + '|' + ck + '|' + ttl;\n"
           @"})())";
}

static BOOL LBBrowserAwaitProbeUserDone(NSString *probe) {
    if (probe.length == 0) return NO;
    if ([probe hasPrefix:@"1|"]) return YES;
    if ([probe containsString:@"LB_AWAIT_DONE="]) return YES;
    if ([probe containsString:@"LB_AWAIT_DONE|"]) return YES;
    return NO;
}

static void LBBrowserAwaitTryInjectAndProbe(BOOL *outDone, BOOL *outHasBtn) {
    if (outDone) *outDone = NO;
    if (outHasBtn) *outHasBtn = NO;
    __block WKWebView *wk = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        wk = LBFindNativeWKWebView();
    });
    if (!wk) return;

    NSString *inj = LBEvalJSOnWK(wk, LBBrowserAwaitInjectJS(), 2.0);
    if (!sBrowserAwaitInjectLogged &&
        ([inj isEqualToString:@"injected"] || [inj isEqualToString:@"exists"])) {
        sBrowserAwaitInjectLogged = YES;
        LBVisibleWVMarker(@"startBrowserAwait overlay host=WKInject hasBtn=1");
    } else if (inj.length > 0 && [inj hasPrefix:@"err:"]) {
        LBVisibleWVMarker([NSString stringWithFormat:@"startBrowserAwait inject %@", inj]);
    }

    NSString *probe = LBEvalJSOnWK(wk, LBBrowserAwaitPollJS(), 2.0);
    if (outHasBtn && probe.length >= 3) {
        // format: done|hasBtn|cookie|title
        NSArray *parts = [probe componentsSeparatedByString:@"|"];
        if (parts.count >= 2) {
            *outHasBtn = [parts[1] isEqualToString:@"1"];
        }
    }
    if (outDone) {
        *outDone = LBBrowserAwaitProbeUserDone(probe);
    }
}

static void LBBrowserAwaitRemoveDoneUI(void) {
    if ([NSThread isMainThread]) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            LBBrowserAwaitRemoveDoneUI();
        });
        return;
    }
    __block WKWebView *wk = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        wk = LBFindNativeWKWebView();
    });
    if (!wk) return;
    (void)LBEvalJSOnWK(wk,
        @"(function(){ var b=document.getElementById('lb-await-done-btn');"
        @" if(b&&b.parentNode){b.parentNode.removeChild(b);} return 'ok'; })()",
        1.5);
}

static void LBBrowserAwaitFinish(void) {
    if ([NSThread isMainThread]) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            LBBrowserAwaitFinish();
        });
        return;
    }

    __block WKWebView *wk = nil;
    __block NSString *page = sBrowserAwaitPageUrl ?: @"";
    dispatch_sync(dispatch_get_main_queue(), ^{
        wk = LBFindNativeWKWebView();
        if (wk.URL.absoluteString.length) page = wk.URL.absoluteString;
    });
    NSString *src = sBrowserAwaitSourceUrl ?: @"";
    if (wk) {
        NSString *html = LBEvalJSOnWK(wk, @"document.documentElement.outerHTML", 3.0);
        sBrowserAwaitHTML = html ?: @"";
        // 必须等 Cookie 回灌完成再放行后续 AnalyzeUrl，否则 @js 紧接的 ajax/搜索会空 Cookie
        dispatch_semaphore_t cookieSem = dispatch_semaphore_create(0);
        LBHarvestWKCookies(wk, page, src, ^{
            LBVisibleWVMarker(@"startBrowserAwait harvest done");
            dispatch_semaphore_signal(cookieSem);
        });
        long cookieWait = dispatch_semaphore_wait(
            cookieSem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)));
        if (cookieWait != 0) {
            LBVisibleWVMarker(@"startBrowserAwait harvest timeout");
        }
    } else {
        sBrowserAwaitHTML = @"";
        dispatch_sync(dispatch_get_main_queue(), ^{
            LBHarvestNativeXiangseCookies(page, src);
        });
    }
    LBBrowserAwaitRemoveDoneUI();
    if (sBrowserAwaitSem) {
        dispatch_semaphore_signal(sBrowserAwaitSem);
    }
}

NSString *LBStartBrowserAwait(NSString *urlStr, NSString *sourceUrl, NSString *title, NSTimeInterval timeoutSec) {
    if (urlStr.length == 0) return @"";
    if (timeoutSec <= 0) timeoutSec = 180;

    // 禁止在主线程阻塞
    if ([NSThread isMainThread]) {
        LBVisibleWVMarker(@"startBrowserAwait refuse main-thread block");
        dispatch_async(dispatch_get_main_queue(), ^{
            LBPresentVisibleWebView(urlStr, sourceUrl, title.length ? title : @"网页验证");
        });
        return @"";
    }

    sBrowserAwaitHTML = @"";
    sBrowserAwaitSourceUrl = sourceUrl ?: @"";
    sBrowserAwaitPageUrl = urlStr;
    sBrowserAwaitInjectLogged = NO;
    sBrowserAwaitSem = dispatch_semaphore_create(0);

    dispatch_semaphore_t presentedSem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        // 与存活的 legado://webview 同路径：只开香色 WebView，不改原生 VC 视图树
        LBPresentVisibleWebView(urlStr, sourceUrl, title.length ? title : @"网页验证");
        LBVisibleWVMarker([NSString stringWithFormat:
                           @"startBrowserAwait presented url=%@ title=%@",
                           urlStr, title ?: @""]);
        dispatch_semaphore_signal(presentedSem);
    });
    // 最多等 2s 确认主线程已执行开页
    dispatch_semaphore_wait(presentedSem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)));

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeoutSec];
    BOOL userDone = NO;
    while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
        BOOL done = NO;
        BOOL hasBtn = NO;
        LBBrowserAwaitTryInjectAndProbe(&done, &hasBtn);
        if (done) {
            userDone = YES;
            LBVisibleWVMarker(@"startBrowserAwait user done");
            break;
        }
        [NSThread sleepForTimeInterval:0.4];
    }
    if (!userDone) {
        LBVisibleWVMarker(@"startBrowserAwait timeout");
    }
    // 已在后台线程，直接 Finish（harvest + 放行）
    LBBrowserAwaitFinish();
    // Finish 会 signal；若已 signal 过则此处再 wait 立即返回
    dispatch_semaphore_wait(sBrowserAwaitSem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)));

    NSString *out = sBrowserAwaitHTML ?: @"";
    sBrowserAwaitSem = NULL;
    return out;
}
