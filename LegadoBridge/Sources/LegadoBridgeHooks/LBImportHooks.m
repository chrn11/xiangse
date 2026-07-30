#import "LBInternal.h"
#import "LegadoBridge.h"

// 导入组：JSON 备用 Hook + openURL 主入口 + 用户导入弹窗

// 保存 NSJSONSerialization +JSONObjectWithData:options:error: 的原始实现指针。
// 采用「保存原 IMP + method_setImplementation」而非 selector 交换，
// 避免 hook 内部调原实现时因 swizzled selector 未注册到目标类表而触发
// unrecognized selector（曾导致冷启动 SIGABRT）。
static id (*LBOrig_NSJSONSerialization_JSONObjectWithData)(Class, SEL, NSData *, NSJSONReadingOptions, NSError **) = NULL;

// 重入保护：isLegadoJSONData / importLegadoJSONData 内部会再次调用
// +[NSJSONSerialization JSONObjectWithData:]，若不拦截会无限递归直至栈溢出
// （KERN_PROTECTION_FAILURE / SIGSEGV）。用线程局部标志守卫，重入期间只走原 IMP。
static NSString *const LBReentryKey = @"LegadoBridge.JSONHook.Reentry";

// Core.shared 初始化重入守卫：static let shared 底层是 dispatch_once，
// 若在 once 回调内再次取 shared（JSON Hook / dicModelList Hook）会 SIGTRAP。
// 仅在「首次初始化进行中」返回 nil；shared 就绪后的正常访问不受影响。
/// 轻量启发式：无 bookSourceUrl 的 JSON（如 AXCodeLoader 包映射）绝不触碰 Core.shared
static BOOL LBDataMightBeLegadoJSON(NSData *data) {
    if (data.length < 24 || data.length > 16 * 1024 * 1024) return NO;
    if (!data.bytes) return NO;
    NSData *needle = [@"bookSourceUrl" dataUsingEncoding:NSUTF8StringEncoding];
    if (!needle.length) return NO;
    if ([data rangeOfData:needle options:0 range:NSMakeRange(0, data.length)].location == NSNotFound) {
        return NO;
    }
    NSData *n2 = [@"searchUrl" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *n3 = [@"ruleSearch" dataUsingEncoding:NSUTF8StringEncoding];
    BOOL hasSearch = n2.length && [data rangeOfData:n2 options:0 range:NSMakeRange(0, data.length)].location != NSNotFound;
    BOOL hasRule = n3.length && [data rangeOfData:n3 options:0 range:NSMakeRange(0, data.length)].location != NSNotFound;
    return hasSearch || hasRule;
}

void LBLegadoShowImportAlert(void);
void LBLegadoImportData(NSData *data);
void LBLegadoFetchAndImport(NSURL *url);

static id LBLegadoDetectAndImport(NSData *data) {
    if (data.length == 0) return nil;
    // 先挡掉绝大多数系统/无障碍 JSON，避免在任意后台队列上拉起 LegadoBridgeCore.shared
    if (!LBDataMightBeLegadoJSON(data)) return nil;
    @try {
        Class coreClass = NSClassFromString(@"LegadoBridge.LegadoBridgeCore");
        if (!coreClass) return nil;
        // 类方法探测，不经过 instance shared 的 dispatch_once
        BOOL isLegado = NO;
        SEL probeSel = @selector(probeLegadoJSONData:);
        if ([coreClass respondsToSelector:probeSel]) {
            isLegado = ((BOOL (*)(Class, SEL, NSData *))objc_msgSend)(coreClass, probeSel, data);
        }
        if (!isLegado) return nil;
        id core = LBLegadoCoreIfReady();
        if (!core || ![core respondsToSelector:@selector(importLegadoJSONData:error:)]) return nil;
        NSError *importError = nil;
        ((NSInteger (*)(id, SEL, NSData *, NSError **))objc_msgSend)(
            core, @selector(importLegadoJSONData:error:), data, &importError
        );
        if (importError) {
            NSLog(@"[LegadoBridge] import error: %@", importError);
        } else {
            NSLog(@"[LegadoBridge] Legado JSON imported");
        }
    } @catch (NSException *e) {
        NSLog(@"[LegadoBridge] import hook exception: %@", e);
    }
    return nil;
}

// 替换 +[NSJSONSerialization JSONObjectWithData:options:error:] 的新 IMP。
// 不依赖任何「self 上存在 lb_JSONObjectWithData:」selector，直接调用保存的原 IMP。
// 重入保护：检测/导入分支（内部会再次调用本 hook）用线程局部标志守卫，避免无限递归。
static id LBNSJSONSerialization_JSONObjectWithData_IMP(Class self, SEL _cmd, NSData *data, NSJSONReadingOptions opt, NSError **error) {
    id result = NULL;
    if (LBOrig_NSJSONSerialization_JSONObjectWithData) {
        result = LBOrig_NSJSONSerialization_JSONObjectWithData(self, @selector(JSONObjectWithData:options:error:), data, opt, error);
    }

    NSMutableDictionary *td = [NSThread currentThread].threadDictionary;
    if ([td objectForKey:LBReentryKey]) {
        return result;
    }
    [td setObject:@YES forKey:LBReentryKey];
    @try {
        LBLegadoDetectAndImport(data);
    } @finally {
        [td removeObjectForKey:LBReentryKey];
    }
    return result;
}

void LBInstallImportHooks(void) {
    @try {
    Class jsonClass = objc_getClass("NSJSONSerialization");
    if (!jsonClass) {
        LBCapabilityMarkSkipped(LBHookGroupImport, @"NSJSONSerialization missing");
        return;
    }

    SEL original = @selector(JSONObjectWithData:options:error:);
    Method origMethod = class_getClassMethod(jsonClass, original);
    if (!origMethod) {
        LBCapabilityMarkSkipped(LBHookGroupImport, @"JSONObjectWithData missing");
        return;
    }

    LBOrig_NSJSONSerialization_JSONObjectWithData = (id (*)(Class, SEL, NSData *, NSJSONReadingOptions, NSError **))method_getImplementation(origMethod);
    method_setImplementation(origMethod, (IMP)LBNSJSONSerialization_JSONObjectWithData_IMP);
    NSLog(@"[LegadoBridge] hooked +[NSJSONSerialization JSONObjectWithData:options:error:]");
    // openURL 同属导入组，由 LBInstallOpenURLHook 补齐后统一 mark
    } @catch (NSException *e) {
        LBCapabilityMarkFailed(LBHookGroupImport, e.reason ?: @"json hook exception");
    }
}
#pragma mark - openURL Hook (文件/URL 接收入口)

// 保存 AppDelegate -application:openURL:options: 的原始实现。
// App 接收「打开方式」分享文件时经此入口（NSURL 指向 Documents/Inbox/<file>）。
// 在此拦截：若文件是 Legado JSON 书源，注册到 SourceRegistry 并返回 YES（已处理），
// 不走 App 原生 xbs/txt 分流（原生不识别 public.json 会丢弃）。
static BOOL (*LBOrig_AppDelegate_application_openURL_options)(id, SEL, id, NSURL *, NSDictionary *) = NULL;
// 判别用：didFinishLaunching 启动必调，确认 IMP 替换机制工作
static BOOL (*LBOrig_AppDelegate_didFinishLaunching)(id, SEL, id, NSDictionary *) = NULL;

static BOOL LBAppDelegate_didFinishLaunching_IMP(id self, SEL _cmd, id application, NSDictionary *options) {
    [@"didFinishLaunching hit" writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_didfinishlaunch_hit.txt"] atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    BOOL ret = YES;
    if (LBOrig_AppDelegate_didFinishLaunching) {
        ret = LBOrig_AppDelegate_didFinishLaunching(self, @selector(application:didFinishLaunchingWithOptions:), application, options);
    }
    // shared 就绪后再恢复磁盘书源（禁止在 Core.init 内 restore，避免 dispatch_once 重入）
    @try {
        id core = LBLegadoCoreIfReady();
        if ([core respondsToSelector:@selector(restorePersistedSources)]) {
            NSInteger n = ((NSInteger (*)(id, SEL))objc_msgSend)(core, @selector(restorePersistedSources));
            NSLog(@"[LegadoBridge] restored persisted sources: %ld", (long)n);
        }
    } @catch (NSException *e) {
        NSLog(@"[LegadoBridge] restorePersistedSources exception: %@", e);
    }
    // 不再启动 2.5s 强弹窗；入口改为原生站点管理页「Legado」按钮 / URL Scheme / 文件打开
    return ret;
}

/// Scene 安全取 keyWindow：优先 foreground scene 的 isKeyWindow，再 fallback 可见 window。
/// iOS 13+ 上 `[UIApplication sharedApplication].keyWindow` 常为 nil，会导致导入弹窗静默失败。
void LBLegadoShowImportAlert(void) {
    // AK：上游不得在 bg 触达任何 windows API
    if (![NSThread isMainThread]) {
        NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_ab_probe.txt"];
        NSString *line = [NSString stringWithFormat:
                          @"%@ | hypothesis_AK ak_bg_windows_api_skip caller=LBLegadoShowImportAlert\n",
                          [NSDate date]];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        } else {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh synchronizeFile];
            [fh closeFile];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            LBLegadoShowImportAlert();
        });
        return;
    }
    // U3：优先原版 ConfigSourceModelSyncCon；失败或 force_alert 再 UIAlert
    if (LBLegadoPresentNativeImport()) {
        return;
    }
    UIWindow *window = LBLegadoKeyWindow();
    if (!window) {
        // 冷启动窗口未就绪时短暂重试，避免弹窗静默失败
        static int retryCount = 0;
        if (retryCount < 5) {
            retryCount += 1;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                LBLegadoShowImportAlert();
            });
        }
        return;
    }
    UIViewController *rootVC = window.rootViewController;
    if (!rootVC) return;
    // 已有 presented 时挂到最顶层，避免被盖住或 present 失败
    while (rootVC.presentedViewController) {
        rootVC = rootVC.presentedViewController;
    }
    if ([rootVC isKindOfClass:[UIAlertController class]]) {
        // 已在展示 alert，不重复弹
        return;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"书源导入"
                                                                   message:@"可填 URL（http/https），或在第二框粘贴 JSON 正文"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"https://example.com/source.json";
        textField.keyboardType = UIKeyboardTypeURL;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"或粘贴书源 JSON 正文";
        textField.keyboardType = UIKeyboardTypeDefault;
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"从 URL 导入" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *input = alert.textFields.count > 0 ? alert.textFields[0].text : nil;
        if (input.length == 0) {
            LBLegadoShowResult(@"请填写书源 JSON 的 URL");
            return;
        }
        NSURL *url = [NSURL URLWithString:input];
        if (!url || url.scheme.length == 0) {
            LBLegadoShowResult(@"URL 无效");
            return;
        }
        LBLegadoFetchAndImport(url);
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"粘贴 JSON 导入" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *jsonText = alert.textFields.count > 1 ? alert.textFields[1].text : nil;
        if (jsonText.length == 0) {
            // 第二框为空时尝试系统剪贴板，方便真机快速粘贴
            jsonText = UIPasteboard.generalPasteboard.string;
        }
        if (jsonText.length == 0) {
            LBLegadoShowResult(@"请粘贴书源 JSON 正文");
            return;
        }
        NSData *data = [jsonText dataUsingEncoding:NSUTF8StringEncoding];
        if (data.length == 0) {
            LBLegadoShowResult(@"JSON 正文为空");
            return;
        }
        LBLegadoImportData(data);
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"管理已有" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        LBLegadoPresentManagerVC(nil);
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [rootVC presentViewController:alert animated:YES completion:^{
        [@"import_alert_shown" writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_import_alert.txt"]
                                atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }];
}

void LBLegadoImportData(NSData *data) {
    @try {
        Class coreClass = NSClassFromString(@"LegadoBridge.LegadoBridgeCore");
        if (!coreClass) { LBLegadoShowResult(@"无 LegadoBridgeCore"); return; }
        BOOL isLegado = NO;
        SEL probeSel = @selector(probeLegadoJSONData:);
        if ([coreClass respondsToSelector:probeSel]) {
            isLegado = ((BOOL (*)(Class, SEL, NSData *))objc_msgSend)(coreClass, probeSel, data);
        }
        if (!isLegado) { LBLegadoShowResult(@"不是书源 JSON 格式"); return; }
        id core = LBLegadoCoreIfReady();
        if (!core || ![core respondsToSelector:@selector(importLegadoJSONData:error:)]) {
            LBLegadoShowResult(@"LegadoBridgeCore 未就绪");
            return;
        }
        NSError *importError = nil;
        ((NSInteger (*)(id, SEL, NSData *, NSError **))objc_msgSend)(
            core, @selector(importLegadoJSONData:error:), data, &importError
        );
        if (importError) {
            LBLegadoShowResult([NSString stringWithFormat:@"导入失败: %@", importError.localizedDescription]);
        } else {
            // 写成功标记
            [@"imported OK" writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_import_result.txt"] atomically:NO encoding:NSUTF8StringEncoding error:NULL];
            LBLegadoShowResult(@"书源导入成功");
        }
    } @catch (NSException *e) {
        LBLegadoShowResult([NSString stringWithFormat:@"异常: %@", e]);
    }
}

/// 异步下载并导入 Legado 书源 JSON（超时 15 秒，主线程回调提示）
void LBLegadoFetchAndImport(NSURL *url) {
    if (!url) { LBLegadoShowResult(@"URL 为空"); return; }
    NSString *markPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_import_fetch.txt"];
    [[NSString stringWithFormat:@"fetch begin %@", url.absoluteString ?: @""]
        writeToFile:markPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 15.0;
    config.timeoutIntervalForResource = 15.0;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    [[session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                [[NSString stringWithFormat:@"fetch err %@", error.localizedDescription ?: @""]
                    writeToFile:markPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                LBLegadoShowResult([NSString stringWithFormat:@"下载失败: %@", error.localizedDescription]);
                return;
            }
            NSHTTPURLResponse *httpResp = nil;
            if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
                httpResp = (NSHTTPURLResponse *)response;
            }
            if (httpResp && httpResp.statusCode != 200) {
                [[NSString stringWithFormat:@"fetch http %ld", (long)httpResp.statusCode]
                    writeToFile:markPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                LBLegadoShowResult([NSString stringWithFormat:@"HTTP 错误: %ld", (long)httpResp.statusCode]);
                return;
            }
            if (!data || data.length == 0) {
                [@"fetch empty" writeToFile:markPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                LBLegadoShowResult(@"下载成功但数据为空");
                return;
            }
            // 验证是否为合法 JSON
            NSError *jsonErr = nil;
            id jsonObj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
            if (jsonErr || !jsonObj) {
                [@"fetch not-json" writeToFile:markPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                LBLegadoShowResult(@"非 JSON 格式，无法解析");
                return;
            }
            // 验证是否为 Legado 书源格式
            Class coreClass = NSClassFromString(@"LegadoBridge.LegadoBridgeCore");
            if (!coreClass) { LBLegadoShowResult(@"无 LegadoBridgeCore"); return; }
            BOOL isLegado = NO;
            SEL probeSel = @selector(probeLegadoJSONData:);
            if ([coreClass respondsToSelector:probeSel]) {
                isLegado = ((BOOL (*)(Class, SEL, NSData *))objc_msgSend)(coreClass, probeSel, data);
            }
            if (!isLegado) {
                [@"fetch not-legado" writeToFile:markPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                LBLegadoShowResult(@"JSON 格式正确，但不是书源格式");
                return;
            }
            // 导入
            id core = LBLegadoCoreIfReady();
            if (!core || ![core respondsToSelector:@selector(importLegadoJSONData:error:)]) {
                LBLegadoShowResult(@"LegadoBridgeCore 未就绪");
                return;
            }
            NSError *importError = nil;
            NSInteger count = ((NSInteger (*)(id, SEL, NSData *, NSError **))objc_msgSend)(
                core, @selector(importLegadoJSONData:error:), data, &importError
            );
            if (importError) {
                [[NSString stringWithFormat:@"import err %@", importError.localizedDescription ?: @""]
                    writeToFile:markPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                LBLegadoShowResult([NSString stringWithFormat:@"导入失败: %@", importError.localizedDescription]);
            } else {
                [[NSString stringWithFormat:@"import ok count=%ld", (long)count]
                    writeToFile:markPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                LBLegadoShowResult([NSString stringWithFormat:@"导入 %ld 个书源", (long)count]);
            }
        });
    }] resume];
}

/// 从 URL 的 query 中提取指定参数值
static NSString *LBQueryParameterFromURL(NSURL *url, NSString *key) {
    NSURLComponents *comp = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in comp.queryItems) {
        if ([item.name isEqualToString:key]) return item.value;
    }
    return nil;
}

static BOOL LBAppDelegate_openURL_options_IMP(id self, SEL _cmd, id application, NSURL *url, NSDictionary *options) {
    // 调试标记 0：openURL hook 被调用（记录 URL）
    [url.absoluteString writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_openurl_hit.txt"] atomically:NO encoding:NSUTF8StringEncoding error:NULL];

    // legado://import/bookSource?src=<url> 或 yuedu://booksource/importonline?src=<url>
    // legado://search?keyword=<kw>[&sourceUrl=...] — 绕过软键盘触发混合搜索（验收深链）
    if (url) {
        NSString *scheme = url.scheme.lowercaseString;
        if ([scheme isEqualToString:@"legado"] || [scheme isEqualToString:@"yuedu"]) {
            NSString *src = LBQueryParameterFromURL(url, @"src");
            NSString *keyword = LBQueryParameterFromURL(url, @"keyword");
            if (keyword.length == 0) keyword = LBQueryParameterFromURL(url, @"key");
            if (keyword.length == 0) keyword = LBQueryParameterFromURL(url, @"q");
            NSString *host = url.host.lowercaseString ?: @"";
            NSString *pathLower = url.path.lowercaseString ?: @"";
            BOOL wantSearch = [host isEqualToString:@"search"]
                || [pathLower containsString:@"/search"]
                || (keyword.length > 0 && src.length == 0);
            if (wantSearch) {
                if (keyword.length == 0) {
                    LBLegadoShowResult(@"缺少 keyword/key/q 参数");
                    return YES;
                }
                NSString *sourceUrl = LBQueryParameterFromURL(url, @"sourceUrl");
                [[NSString stringWithFormat:@"openURL search key=%@ src=%@", keyword, sourceUrl ?: @"all"]
                    writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_openurl.txt"]
                    atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                LBTriggerMixedSearch(keyword, sourceUrl.length > 0 ? sourceUrl : nil);
                return YES;
            }
            // legado://nativeRead?bookUrl=...&sourceUrl=...&idx=0 — 验收：原生点章旁路
            BOOL wantNativeRead = [host isEqualToString:@"nativeread"]
                || [host isEqualToString:@"opennative"]
                || [pathLower containsString:@"/nativeread"]
                || [pathLower containsString:@"/opennative"];
            if (wantNativeRead) {
                NSString *bookUrl = LBQueryParameterFromURL(url, @"bookUrl");
                NSString *sourceUrl = LBQueryParameterFromURL(url, @"sourceUrl");
                NSString *idxStr = LBQueryParameterFromURL(url, @"idx");
                NSInteger idx = idxStr.length > 0 ? idxStr.integerValue : 0;
                if (bookUrl.length == 0) {
                    LBLegadoShowResult(@"nativeRead 缺少 bookUrl");
                    return YES;
                }
                [[NSString stringWithFormat:@"openURL nativeRead book=%@ src=%@ idx=%ld",
                  bookUrl, sourceUrl ?: @"", (long)idx]
                    writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_nativeread_openurl.txt"]
                    atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                LBOpenNativeChapterAtIndex(bookUrl, sourceUrl, idx);
                return YES;
            }
            // legado://reviews?bookUrl=...&sourceUrl=... — Wave0 书评（不经桥接页导航栏）
            BOOL wantReviews = [host isEqualToString:@"reviews"]
                || [host isEqualToString:@"bookreview"]
                || [pathLower containsString:@"/reviews"]
                || [pathLower containsString:@"/bookreview"];
            if (wantReviews) {
                NSString *bookUrl = LBQueryParameterFromURL(url, @"bookUrl");
                NSString *sourceUrl = LBQueryParameterFromURL(url, @"sourceUrl");
                if (bookUrl.length == 0) {
                    LBLegadoShowResult(@"reviews 缺少 bookUrl");
                    return YES;
                }
                [[NSString stringWithFormat:@"openURL reviews book=%@ src=%@", bookUrl, sourceUrl ?: @""]
                    writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_reviews_openurl.txt"]
                    atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                dispatch_async(dispatch_get_main_queue(), ^{
                    Class coreClass = NSClassFromString(@"LegadoBridge.LegadoBridgeCore");
                    id core = coreClass ? [coreClass performSelector:@selector(shared)] : nil;
                    if (core && [core respondsToSelector:@selector(presentReviewsForBookUrl:sourceUrl:)]) {
                        ((void (*)(id, SEL, NSString *, NSString *))objc_msgSend)(
                            core, @selector(presentReviewsForBookUrl:sourceUrl:), bookUrl, sourceUrl
                        );
                    } else {
                        LBLegadoShowResult(@"书评 Core 入口不可用");
                    }
                });
                return YES;
            }
            // legado://tts?bookUrl=...&chapterUrl=...&title=...[&speakText=...][&ttsUrl=...]
            BOOL wantTTS = [host isEqualToString:@"tts"]
                || [host isEqualToString:@"audio"]
                || [pathLower containsString:@"/tts"]
                || [pathLower containsString:@"/audio"];
            if (wantTTS) {
                NSString *bookUrl = LBQueryParameterFromURL(url, @"bookUrl");
                NSString *chapterUrl = LBQueryParameterFromURL(url, @"chapterUrl");
                NSString *title = LBQueryParameterFromURL(url, @"title");
                NSString *speakText = LBQueryParameterFromURL(url, @"speakText");
                NSString *ttsUrl = LBQueryParameterFromURL(url, @"ttsUrl");
                if (bookUrl.length == 0) {
                    LBLegadoShowResult(@"tts 缺少 bookUrl");
                    return YES;
                }
                if (chapterUrl.length == 0) chapterUrl = @"";
                [[NSString stringWithFormat:@"openURL tts book=%@ ch=%@ title=%@",
                  bookUrl, chapterUrl, title ?: @""]
                    writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_tts_openurl.txt"]
                    atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (speakText.length > 0 || ttsUrl.length > 0) {
                        Class coreClass = NSClassFromString(@"LegadoBridge.LegadoBridgeCore");
                        id core = coreClass ? [coreClass performSelector:@selector(shared)] : nil;
                        if (core && [core respondsToSelector:@selector(openTTSForBookUrl:chapterUrl:chapterTitle:speakText:ttsURLTemplate:)]) {
                            ((void (*)(id, SEL, NSString *, NSString *, NSString *, NSString *, NSString *))objc_msgSend)(
                                core,
                                @selector(openTTSForBookUrl:chapterUrl:chapterTitle:speakText:ttsURLTemplate:),
                                bookUrl, chapterUrl, title, speakText, ttsUrl
                            );
                            return;
                        }
                    }
                    LBOpenTTS(bookUrl, chapterUrl, title);
                });
                return YES;
            }
            // legado://nativeOpenFile?src=file://... 或 ?path=/var/.../Inbox/x.txt
            // MCP 无法可靠触发系统 document-open；用深链把 file:// 交给本 Hook 的原生 TXT/xbs 分流。
            BOOL wantNativeOpenFile = [host isEqualToString:@"nativeopenfile"]
                || [host isEqualToString:@"openlocalfile"]
                || [pathLower containsString:@"/nativeopenfile"]
                || [pathLower containsString:@"/openlocalfile"];
            if (wantNativeOpenFile) {
                NSString *srcParam = LBQueryParameterFromURL(url, @"src");
                if (srcParam.length == 0) srcParam = LBQueryParameterFromURL(url, @"path");
                if (srcParam.length == 0) srcParam = LBQueryParameterFromURL(url, @"file");
                NSString *decoded = srcParam.length
                    ? ([srcParam stringByRemovingPercentEncoding] ?: srcParam)
                    : nil;
                NSURL *fileURL = nil;
                if (decoded.length > 0) {
                    if ([decoded hasPrefix:@"file:"]) {
                        fileURL = [NSURL URLWithString:decoded];
                        if (!fileURL) {
                            // 容错：file:///path 解析失败时退回 path
                            NSString *p = [decoded hasPrefix:@"file://"]
                                ? [decoded substringFromIndex:7] : decoded;
                            if ([p hasPrefix:@"//"]) p = [p substringFromIndex:1];
                            fileURL = [NSURL fileURLWithPath:p];
                        }
                    } else if ([decoded hasPrefix:@"/"]) {
                        fileURL = [NSURL fileURLWithPath:decoded];
                    }
                }
                if (!fileURL.isFileURL) {
                    LBLegadoShowResult(@"nativeOpenFile 缺少有效 src/path（file:// 或绝对路径）");
                    return YES;
                }
                [[NSString stringWithFormat:@"openURL nativeOpenFile -> %@", fileURL.absoluteString]
                    writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_nativeopenfile.txt"]
                    atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                // 递归进入 file:// 分支：JSON→Legado 导入；TXT/xbs→原 IMP 原生分流
                return LBAppDelegate_openURL_options_IMP(self, _cmd, application, fileURL, options ?: @{});
            }
            // legado://read?chapterUrl=...&bookUrl=...&title=... — 直达 Bridge 阅读页（验收/旁路）
            BOOL wantRead = [host isEqualToString:@"read"] || [pathLower containsString:@"/read"];
            if (wantRead) {
                NSString *chapterUrl = LBQueryParameterFromURL(url, @"chapterUrl");
                NSString *bookUrl = LBQueryParameterFromURL(url, @"bookUrl");
                NSString *title = LBQueryParameterFromURL(url, @"title");
                if (chapterUrl.length == 0 || bookUrl.length == 0) {
                    LBLegadoShowResult(@"read 缺少 chapterUrl 或 bookUrl");
                    return YES;
                }
                NSString *chCopy = [chapterUrl copy];
                NSString *buCopy = [bookUrl copy];
                NSString *titleCopy = title.length > 0 ? [title copy] : @"章节";
                [[NSString stringWithFormat:@"openURL read ch=%@ book=%@ title=%@",
                  chCopy, buCopy, titleCopy]
                    writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_read_openurl.txt"]
                    atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSString *brMsg = nil;
                    BOOL ok = LBPresentBridgeReader(titleCopy, chCopy, buCopy, &brMsg);
                    NSString *line = [NSString stringWithFormat:
                                      @"bridgeReader deeplink presented=%d | %@",
                                      ok ? 1 : 0, brMsg ?: @"?"];
                    [line writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_catalog_openreader.txt"]
                             atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                });
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    LBHandleContentRequest(chCopy, buCopy, nil);
                });
                return YES;
            }
            // legado://explore?sourceUrl=...&page=1 — 发现频道验收深链
            BOOL wantExplore = [host isEqualToString:@"explore"]
                || [pathLower containsString:@"/explore"];
            // legado://discover — 顶栏发现路径：标记发现态并拉全部可发现 Legado 源
            BOOL wantDiscoverTab = [host isEqualToString:@"discover"]
                || [pathLower containsString:@"/discover"];
            if (wantDiscoverTab) {
                LBSetDiscoverTabActive(YES);
                [[NSString stringWithFormat:@"openURL discoverTab force explore"]
                    writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_discover_hook.txt"]
                    atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                // 只切「书架|发现」分段到发现，并推出原生 BookList 宿主
                @try {
                    UIWindow *win = LBLegadoKeyWindow();
                    UIViewController *root = win.rootViewController;
                    NSMutableArray *stack = [NSMutableArray array];
                    if (root) [stack addObject:root];
                    while (stack.count > 0) {
                        UIViewController *vc = stack.lastObject;
                        [stack removeLastObject];
                        NSMutableArray *views = [NSMutableArray array];
                        if (vc.isViewLoaded && vc.view) [views addObject:vc.view];
                        if (vc.navigationItem.titleView) [views addObject:vc.navigationItem.titleView];
                        while (views.count > 0) {
                            UIView *cur = views.lastObject;
                            [views removeLastObject];
                            if ([cur isKindOfClass:[UISegmentedControl class]]) {
                                UISegmentedControl *sc = (UISegmentedControl *)cur;
                                BOOL hasShelf = NO;
                                NSInteger discoverIdx = -1;
                                for (NSUInteger i = 0; i < sc.numberOfSegments; i++) {
                                    NSString *t = [sc titleForSegmentAtIndex:i] ?: @"";
                                    if ([t containsString:@"书架"]) hasShelf = YES;
                                    if ([t containsString:@"发现"]) discoverIdx = (NSInteger)i;
                                }
                                if (hasShelf && discoverIdx >= 0 &&
                                    sc.selectedSegmentIndex != discoverIdx) {
                                    // 用原实现设 index，避免我们 hook 把 sticky 打乱；再手动触发
                                    sc.selectedSegmentIndex = discoverIdx;
                                    [sc sendActionsForControlEvents:UIControlEventValueChanged];
                                }
                            }
                            for (UIView *sub in cur.subviews) [views addObject:sub];
                        }
                        if ([vc respondsToSelector:@selector(setSquare:)]) {
                            // 恢复原生发现：deeplink 也走 setSquare，再弹掉可能误推的 BookSearch
                            ((void (*)(id, SEL, BOOL))objc_msgSend)(vc, @selector(setSquare:), YES);
                        }
                        for (UIViewController *c in vc.childViewControllers) [stack addObject:c];
                        if (vc.presentedViewController) [stack addObject:vc.presentedViewController];
                        if ([vc isKindOfClass:[UINavigationController class]]) {
                            for (UIViewController *c in [(UINavigationController *)vc viewControllers]) {
                                [stack addObject:c];
                            }
                        }
                    }
                } @catch (__unused NSException *e) {}
                // 分段动作可能异步把状态打回书架；deeplink 再强制 sticky + 宿主
                LBSetDiscoverTabActive(YES);
                LBEnsureNativeDiscoverHostPresented();
                wantExplore = YES;
            }
            if (wantExplore) {
                NSString *sourceUrl = LBQueryParameterFromURL(url, @"sourceUrl");
                NSString *exploreUrl = LBQueryParameterFromURL(url, @"exploreUrl");
                NSString *pageStr = LBQueryParameterFromURL(url, @"page");
                NSInteger page = pageStr.length > 0 ? pageStr.integerValue : 1;
                if (page < 1) page = 1;
                // discover 深链未带 sourceUrl → 扫全部可发现源
                if (wantDiscoverTab && sourceUrl.length == 0) {
                    sourceUrl = nil;
                }
                Class coreClass = NSClassFromString(@"LegadoBridge.LegadoBridgeCore");
                id core = nil;
                if (coreClass) {
                    core = ((id (*)(Class, SEL))objc_msgSend)(coreClass, @selector(shared));
                }
                if (!core || ![core respondsToSelector:@selector(handleExploreRequestWithSourceUrl:exploreUrl:page:)]) {
                    LBLegadoShowResult(@"explore API 未就绪");
                    return YES;
                }
                [[NSString stringWithFormat:@"openURL explore src=%@ url=%@ page=%ld",
                  sourceUrl ?: @"", exploreUrl ?: @"", (long)page]
                    writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_explore_openurl.txt"]
                    atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                ((void (*)(id, SEL, NSString *, NSString *, NSInteger))objc_msgSend)(
                    core,
                    @selector(handleExploreRequestWithSourceUrl:exploreUrl:page:),
                    sourceUrl,
                    exploreUrl,
                    page
                );
                return YES;
            }
            // legado://nativeImport — U3：打开原版导入（ConfigSourceModelSyncCon / UIAlert 回退）
            BOOL wantNativeImport = [host isEqualToString:@"nativeimport"]
                || [host isEqualToString:@"importui"]
                || [pathLower containsString:@"/nativeimport"]
                || [pathLower containsString:@"/importui"];
            if (wantNativeImport) {
                [[NSString stringWithFormat:@"openURL nativeImport host=%@", host]
                    writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_u3_deeplink.txt"]
                    atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                LBLegadoShowImportAlert();
                return YES;
            }
            // legado://browserAwaitDone — 页内「完成验证」深链，解除 startBrowserAwait 等待
            BOOL wantAwaitDone = [host isEqualToString:@"browserawaitdone"]
                || [host isEqualToString:@"awaitdone"]
                || [pathLower containsString:@"/browserawaitdone"]
                || [pathLower containsString:@"/awaitdone"];
            if (wantAwaitDone) {
                LBBrowserAwaitSignalUserDone(@"deepLink");
                return YES;
            }
            // legado://browserAwait?url=...[&sourceUrl=...][&title=...] — 书源等价等待探针
            // 禁止主线程阻塞：后台队列调用 LBStartBrowserAwait，点「完成验证」后回灌 Cookie
            BOOL wantBrowserAwait = [host isEqualToString:@"browserawait"]
                || [host isEqualToString:@"await"]
                || [pathLower containsString:@"/browserawait"]
                || [pathLower containsString:@"/await"];
            if (wantBrowserAwait) {
                NSString *pageUrl = LBQueryParameterFromURL(url, @"url");
                if (pageUrl.length == 0) pageUrl = LBQueryParameterFromURL(url, @"src");
                NSString *sourceUrl = LBQueryParameterFromURL(url, @"sourceUrl");
                NSString *title = LBQueryParameterFromURL(url, @"title");
                if (pageUrl.length == 0) {
                    LBLegadoShowResult(@"browserAwait 缺少 url");
                    return YES;
                }
                NSString *decoded = [pageUrl stringByRemovingPercentEncoding] ?: pageUrl;
                NSString *titleDecoded = title.length
                    ? ([title stringByRemovingPercentEncoding] ?: title)
                    : @"网页验证";
                NSString *srcCopy = [sourceUrl copy] ?: @"";
                NSString *urlCopy = [decoded copy];
                NSString *titleCopy = [titleDecoded copy];
                [[NSString stringWithFormat:@"openURL browserAwait url=%@ src=%@ title=%@",
                  urlCopy, srcCopy, titleCopy]
                    writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_browser_await_openurl.txt"]
                    atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    NSString *html = LBStartBrowserAwait(urlCopy, srcCopy, titleCopy, 180) ?: @"";
                    NSString *line = [NSString stringWithFormat:
                                      @"browserAwait done htmlLen=%lu url=%@",
                                      (unsigned long)html.length, urlCopy];
                    [line writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_browser_await_result.txt"]
                           atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                });
                return YES;
            }
            // legado://webview?url=...[&sourceUrl=...] — 可见 WebView（过盾/登录页）
            BOOL wantWebView = [host isEqualToString:@"webview"]
                || [host isEqualToString:@"browser"]
                || [pathLower containsString:@"/webview"]
                || [pathLower containsString:@"/browser"];
            if (wantWebView) {
                NSString *pageUrl = LBQueryParameterFromURL(url, @"url");
                if (pageUrl.length == 0) pageUrl = LBQueryParameterFromURL(url, @"src");
                NSString *sourceUrl = LBQueryParameterFromURL(url, @"sourceUrl");
                if (pageUrl.length == 0) {
                    LBLegadoShowResult(@"webview 缺少 url");
                    return YES;
                }
                // 百分号解码（open_url 可能保留编码）
                NSString *decoded = [pageUrl stringByRemovingPercentEncoding] ?: pageUrl;
                LBPresentVisibleWebView(decoded, sourceUrl, @"可见WebView");
                return YES;
            }
            // legado://login?sourceUrl=...[&mode=alert] — 默认可见网页登录；mode=alert 保留旧 UIAlert
            BOOL wantLogin = [host isEqualToString:@"login"] || [pathLower containsString:@"/login"];
            if (wantLogin) {
                NSString *sourceUrl = LBQueryParameterFromURL(url, @"sourceUrl");
                if (sourceUrl.length == 0) {
                    LBLegadoShowResult(@"login 缺少 sourceUrl");
                    return YES;
                }
                NSString *mode = LBQueryParameterFromURL(url, @"mode");
                NSString *pageUrl = LBQueryParameterFromURL(url, @"url");
                [[NSString stringWithFormat:@"openURL login src=%@ mode=%@ url=%@",
                  sourceUrl, mode ?: @"webview", pageUrl ?: @""]
                    writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_login_openurl.txt"]
                    atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                if ([mode.lowercaseString isEqualToString:@"alert"]) {
                    NSString *suCopy = [sourceUrl copy];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        UIAlertController *alert =
                            [UIAlertController alertControllerWithTitle:@"书源登录"
                                                                message:suCopy
                                                         preferredStyle:UIAlertControllerStyleAlert];
                        [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
                            tf.placeholder = @"username";
                        }];
                        [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
                            tf.placeholder = @"password";
                            tf.secureTextEntry = YES;
                        }];
                        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
                        [alert addAction:[UIAlertAction actionWithTitle:@"登录" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                            NSString *user = alert.textFields.count > 0 ? alert.textFields[0].text : @"";
                            NSString *pass = alert.textFields.count > 1 ? alert.textFields[1].text : @"";
                            NSString *line = [NSString stringWithFormat:@"login submit user=%@ passLen=%lu src=%@",
                                              user ?: @"", (unsigned long)(pass.length), suCopy];
                            [line writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_login_submit.txt"]
                                   atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                            NSString *cookie = [NSString stringWithFormat:@"LBSESS=%@; Path=/", user.length ? user : @"anon"];
                            [cookie writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_login_cookie.txt"]
                                     atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                        }]];
                        UIViewController *root = UIApplication.sharedApplication.keyWindow.rootViewController;
                        while (root.presentedViewController) root = root.presentedViewController;
                        [root presentViewController:alert animated:YES completion:nil];
                    });
                    return YES;
                }
                if (pageUrl.length > 0) {
                    NSString *decoded = [pageUrl stringByRemovingPercentEncoding] ?: pageUrl;
                    LBPresentVisibleWebView(decoded, sourceUrl, @"书源登录/过盾");
                } else {
                    LBPresentLoginWebViewForSource(sourceUrl);
                }
                return YES;
            }
            if (src.length > 0) {
                NSURL *srcURL = [NSURL URLWithString:src];
                if (srcURL && srcURL.scheme.length > 0) {
                    LBLegadoFetchAndImport(srcURL);
                } else {
                    LBLegadoShowResult([NSString stringWithFormat:@"src 参数无效: %@", src]);
                }
            } else {
                LBLegadoShowResult(@"缺少 src 或 keyword 参数");
            }
            return YES;
        }
    }

    if (url && [url isFileURL]) {
        NSError *readErr = nil;
        NSData *fileData = [NSData dataWithContentsOfURL:url options:0 error:&readErr];
        if (fileData.length > 0) {
            @try {
                Class coreClass = NSClassFromString(@"LegadoBridge.LegadoBridgeCore");
                if (coreClass) {
                    BOOL isLegado = NO;
                    SEL probeSel = @selector(probeLegadoJSONData:);
                    if ([coreClass respondsToSelector:probeSel]) {
                        isLegado = ((BOOL (*)(Class, SEL, NSData *))objc_msgSend)(coreClass, probeSel, fileData);
                    }
                    // 调试标记 1：isLegado 检测结果
                    [(isLegado ? @"YES" : @"NO") writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_islegado_result.txt"] atomically:NO encoding:NSUTF8StringEncoding error:NULL];
                    if (isLegado) {
                        id core = LBLegadoCoreIfReady();
                        if (core && [core respondsToSelector:@selector(importLegadoJSONData:error:)]) {
                            NSError *importError = nil;
                            ((NSInteger (*)(id, SEL, NSData *, NSError **))objc_msgSend)(
                                core, @selector(importLegadoJSONData:error:), fileData, &importError
                            );
                            // 调试标记 2：导入结果
                            [(importError ? importError.localizedDescription : @"OK") writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_import_result.txt"] atomically:NO encoding:NSUTF8StringEncoding error:NULL];
                            if (importError) {
                                NSLog(@"[LegadoBridge] openURL import error: %@", importError);
                            } else {
                                NSLog(@"[LegadoBridge] openURL Legado JSON imported: %@", url.lastPathComponent);
                            }
                        }
                        // 已作为 Legado 书源处理，短路原生流程
                        return YES;
                    }
                } else {
                    [@"no LegadoBridgeCore" writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_islegado_result.txt"] atomically:NO encoding:NSUTF8StringEncoding error:NULL];
                }
            } @catch (NSException *e) {
                [[NSString stringWithFormat:@"exception: %@", e] writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_import_result.txt"] atomically:NO encoding:NSUTF8StringEncoding error:NULL];
                NSLog(@"[LegadoBridge] openURL hook exception: %@", e);
            }
        }
    }
    // 非 Legado 文件 / 非 file URL：走 App 原生处理
    if (LBOrig_AppDelegate_application_openURL_options) {
        return LBOrig_AppDelegate_application_openURL_options(self, @selector(application:openURL:options:), application, url, options);
    }
    return NO;
}

void LBInstallOpenURLHook(void) {
    @try {
    Class appDelegateClass = objc_getClass("AppDelegate");
    if (!appDelegateClass) {
        [@"FAIL: AppDelegate class not found" writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_openurl_install.txt"] atomically:NO encoding:NSUTF8StringEncoding error:NULL];
        NSLog(@"[LegadoBridge] AppDelegate class not found, skip openURL hook");
        if (LBCapabilityStatus(LBHookGroupImport) == LBHookGroupStatusPending) {
            LBCapabilityMarkSkipped(LBHookGroupImport, @"AppDelegate missing");
        }
        return;
    }
    SEL sel = @selector(application:openURL:options:);
    Method m = class_getInstanceMethod(appDelegateClass, sel);
    if (!m) {
        [[NSString stringWithFormat:@"FAIL: method not found on %@", NSStringFromClass(appDelegateClass)] writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_openurl_install.txt"] atomically:NO encoding:NSUTF8StringEncoding error:NULL];
        NSLog(@"[LegadoBridge] application:openURL:options: not found, skip");
        LBCapabilityMarkSkipped(LBHookGroupImport, @"openURL selector missing");
        return;
    }
    LBOrig_AppDelegate_application_openURL_options = (BOOL (*)(id, SEL, id, NSURL *, NSDictionary *))method_getImplementation(m);
    method_setImplementation(m, (IMP)LBAppDelegate_openURL_options_IMP);
    [[NSString stringWithFormat:@"OK: hooked on %@", NSStringFromClass(appDelegateClass)] writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_openurl_install.txt"] atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    NSLog(@"[LegadoBridge] hooked AppDelegate application:openURL:options:");

    // 判别：同时 hook didFinishLaunchingWithOptions（启动必调）
    SEL launchSel = @selector(application:didFinishLaunchingWithOptions:);
    Method lm = class_getInstanceMethod(appDelegateClass, launchSel);
    if (lm) {
        LBOrig_AppDelegate_didFinishLaunching = (BOOL (*)(id, SEL, id, NSDictionary *))method_getImplementation(lm);
        method_setImplementation(lm, (IMP)LBAppDelegate_didFinishLaunching_IMP);
        NSLog(@"[LegadoBridge] hooked application:didFinishLaunchingWithOptions:");
    }
    LBCapabilityMarkEnabled(LBHookGroupImport, @"json+openURL");
    } @catch (NSException *e) {
        if (LBCapabilityStatus(LBHookGroupImport) != LBHookGroupStatusFailed) {
            LBCapabilityMarkFailed(LBHookGroupImport, e.reason ?: @"openURL exception");
        }
    }
}
