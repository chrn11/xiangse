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

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Legado 书源导入"
                                                                   message:@"可填 URL（http/https），或在第二框粘贴 JSON 正文"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"https://example.com/source.json";
        textField.keyboardType = UIKeyboardTypeURL;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"或粘贴 Legado JSON 正文";
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
            LBLegadoShowResult(@"请粘贴 Legado JSON 正文");
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
        if (!isLegado) { LBLegadoShowResult(@"不是 Legado JSON 格式"); return; }
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
            LBLegadoShowResult(@"Legado 书源导入成功");
        }
    } @catch (NSException *e) {
        LBLegadoShowResult([NSString stringWithFormat:@"异常: %@", e]);
    }
}

/// 异步下载并导入 Legado 书源 JSON（超时 15 秒，主线程回调提示）
void LBLegadoFetchAndImport(NSURL *url) {
    if (!url) { LBLegadoShowResult(@"URL 为空"); return; }
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 15.0;
    config.timeoutIntervalForResource = 15.0;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    [[session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                LBLegadoShowResult([NSString stringWithFormat:@"下载失败: %@", error.localizedDescription]);
                return;
            }
            NSHTTPURLResponse *httpResp = nil;
            if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
                httpResp = (NSHTTPURLResponse *)response;
            }
            if (httpResp && httpResp.statusCode != 200) {
                LBLegadoShowResult([NSString stringWithFormat:@"HTTP 错误: %ld", (long)httpResp.statusCode]);
                return;
            }
            if (!data || data.length == 0) {
                LBLegadoShowResult(@"下载成功但数据为空");
                return;
            }
            // 验证是否为合法 JSON
            NSError *jsonErr = nil;
            id jsonObj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
            if (jsonErr || !jsonObj) {
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
                LBLegadoShowResult(@"JSON 格式正确，但不是 Legado 书源格式");
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
                LBLegadoShowResult([NSString stringWithFormat:@"导入失败: %@", importError.localizedDescription]);
            } else {
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
    if (url) {
        NSString *scheme = url.scheme.lowercaseString;
        if ([scheme isEqualToString:@"legado"] || [scheme isEqualToString:@"yuedu"]) {
            NSString *src = LBQueryParameterFromURL(url, @"src");
            if (src.length > 0) {
                NSURL *srcURL = [NSURL URLWithString:src];
                if (srcURL && srcURL.scheme.length > 0) {
                    LBLegadoFetchAndImport(srcURL);
                } else {
                    LBLegadoShowResult([NSString stringWithFormat:@"src 参数无效: %@", src]);
                }
            } else {
                LBLegadoShowResult(@"缺少 src 参数");
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
