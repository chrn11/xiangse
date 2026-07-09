#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdatomic.h>
#import "LegadoBridge.h"

@class LegadoBridgeCore;

static void LBLegadoShowImportAlert(void);
static void LBLegadoImportData(NSData *data);
static void LBLegadoShowResult(NSString *msg);

void LBInstallImportHooks(void);
void LBInstallSearchHooks(void);
void LBInstallOpenURLHook(void);
void LBInstallSourceListHooks(void);

void LBInstallHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        LBInstallImportHooks();
        LBInstallOpenURLHook();
        LBInstallSearchHooks();
        LBInstallSourceListHooks();
        NSLog(@"[LegadoBridge] hooks installed, version=%@", LBBridgeVersion());
    });
}

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
static _Atomic(bool) LBCoreReady = false;
static _Atomic(bool) LBCoreInitializing = false;

static id LBLegadoCoreIfReady(void) {
    Class coreClass = NSClassFromString(@"LegadoBridge.LegadoBridgeCore");
    if (!coreClass) return nil;

    if (atomic_load(&LBCoreReady)) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        return [coreClass performSelector:@selector(shared)];
#pragma clang diagnostic pop
    }
    // 同线程重入或其它线程正在 init：禁止再次进入 shared getter
    if (atomic_exchange(&LBCoreInitializing, true)) {
        return nil;
    }
    id core = nil;
    @try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        core = [coreClass performSelector:@selector(shared)];
#pragma clang diagnostic pop
        if (core) {
            atomic_store(&LBCoreReady, true);
        }
    } @finally {
        atomic_store(&LBCoreInitializing, false);
    }
    return core;
}

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
    Class jsonClass = objc_getClass("NSJSONSerialization");
    if (!jsonClass) return;

    SEL original = @selector(JSONObjectWithData:options:error:);
    Method origMethod = class_getClassMethod(jsonClass, original);
    if (!origMethod) return;

    LBOrig_NSJSONSerialization_JSONObjectWithData = (id (*)(Class, SEL, NSData *, NSJSONReadingOptions, NSError **))method_getImplementation(origMethod);
    method_setImplementation(origMethod, (IMP)LBNSJSONSerialization_JSONObjectWithData_IMP);
    NSLog(@"[LegadoBridge] hooked +[NSJSONSerialization JSONObjectWithData:options:error:]");
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
    // 启动后延迟弹 Legado 书源导入 alert（主线程异步，不阻塞启动）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        LBLegadoShowImportAlert();
    });
    return ret;
}

/// Scene 安全取 keyWindow：优先 foreground scene 的 isKeyWindow，再 fallback 可见 window。
/// iOS 13+ 上 `[UIApplication sharedApplication].keyWindow` 常为 nil，会导致导入弹窗静默失败。
static UIWindow *LBLegadoKeyWindow(void) {
    UIWindow *fallback = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UISceneActivationState state = scene.activationState;
            if (state != UISceneActivationStateForegroundActive &&
                state != UISceneActivationStateForegroundInactive) {
                continue;
            }
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            for (UIWindow *window in windowScene.windows) {
                if (window.isHidden || window.alpha <= 0.01 || !window.rootViewController) continue;
                if (window.isKeyWindow) return window;
                if (!fallback) fallback = window;
            }
        }
    }
    if (fallback) return fallback;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    UIWindow *legacyKey = UIApplication.sharedApplication.keyWindow;
#pragma clang diagnostic pop
    if (legacyKey.rootViewController) return legacyKey;
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (!window.isHidden && window.alpha > 0.01 && window.rootViewController) {
            return window;
        }
    }
    return nil;
}

static void LBLegadoShowImportAlert(void) {
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
        NSData *data = [NSData dataWithContentsOfURL:url];
        if (data.length == 0) {
            LBLegadoShowResult(@"拉取失败：无数据");
            return;
        }
        LBLegadoImportData(data);
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
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [rootVC presentViewController:alert animated:YES completion:^{
        [@"import_alert_shown" writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_import_alert.txt"]
                                atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }];
}

static void LBLegadoImportData(NSData *data) {
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

static void LBLegadoShowResult(NSString *msg) {
    UIWindow *window = LBLegadoKeyWindow();
    UIViewController *rootVC = window.rootViewController;
    if (!rootVC) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil message:msg preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    // 如果当前有 presented controller，先 dismiss 再 present
    if (rootVC.presentedViewController) {
        [rootVC dismissViewControllerAnimated:NO completion:^{
            [rootVC presentViewController:alert animated:YES completion:nil];
        }];
    } else {
        [rootVC presentViewController:alert animated:YES completion:nil];
    }
}

static BOOL LBAppDelegate_openURL_options_IMP(id self, SEL _cmd, id application, NSURL *url, NSDictionary *options) {
    // 调试标记 0：openURL hook 被调用（记录 URL）
    [url.absoluteString writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_openurl_hit.txt"] atomically:NO encoding:NSUTF8StringEncoding error:NULL];
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
    Class appDelegateClass = objc_getClass("AppDelegate");
    if (!appDelegateClass) {
        [@"FAIL: AppDelegate class not found" writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_openurl_install.txt"] atomically:NO encoding:NSUTF8StringEncoding error:NULL];
        NSLog(@"[LegadoBridge] AppDelegate class not found, skip openURL hook");
        return;
    }
    SEL sel = @selector(application:openURL:options:);
    Method m = class_getInstanceMethod(appDelegateClass, sel);
    if (!m) {
        [[NSString stringWithFormat:@"FAIL: method not found on %@", NSStringFromClass(appDelegateClass)] writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_openurl_install.txt"] atomically:NO encoding:NSUTF8StringEncoding error:NULL];
        NSLog(@"[LegadoBridge] application:openURL:options: not found, skip");
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
}

#pragma mark - Source List Hooks (站点管理列表)

static id LBLegadoCore(void) {
    // 列表 Hook 可能在 Core.init → sync → dicModelList 路径上被同步调用；
    // 必须用 IfReady，避免 dispatch_once 同线程重入 SIGTRAP。
    return LBLegadoCoreIfReady();
}

static NSArray *LBLegadoGetSourceNames(void) {
    id core = LBLegadoCore();
    if (!core || ![core respondsToSelector:@selector(allLegadoSourceNames)]) return @[];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    NSArray *names = [core performSelector:@selector(allLegadoSourceNames)];
#pragma clang diagnostic pop
    return names ?: @[];
}

static BOOL LBLegadoIsSourceName(NSString *name) {
    if (name.length == 0) return NO;
    id core = LBLegadoCore();
    if (!core || ![core respondsToSelector:@selector(isLegadoSourceName:)]) return NO;
    return ((BOOL (*)(id, SEL, NSString *))objc_msgSend)(core, @selector(isLegadoSourceName:), name);
}

static NSDictionary *LBLegadoNativeModel(NSString *name) {
    id core = LBLegadoCore();
    if (!core || ![core respondsToSelector:@selector(legadoNativeModelForSourceName:)]) return nil;
    return ((NSDictionary * (*)(id, SEL, NSString *))objc_msgSend)(core, @selector(legadoNativeModelForSourceName:), name);
}

static NSArray * (*LBOrig_BSM_getSortedSourceNames)(id, SEL) = NULL;
static NSDictionary * (*LBOrig_BSM_dicModelList)(id, SEL) = NULL;
static NSString * (*LBOrig_BSM_sourceTypeBySourceName)(id, SEL, NSString *) = NULL;
static NSString * (*LBOrig_BSM_sourceTypeTitleBySourceName)(id, SEL, NSString *) = NULL;

static NSArray *LBBSM_getSortedSourceNames_IMP(id self, SEL _cmd) {
    NSArray *orig = LBOrig_BSM_getSortedSourceNames ? LBOrig_BSM_getSortedSourceNames(self, _cmd) : @[];
    NSArray *legadoNames = LBLegadoGetSourceNames();
    if (legadoNames.count == 0) return orig ?: @[];
    NSMutableOrderedSet *merged = [NSMutableOrderedSet orderedSetWithArray:orig ?: @[]];
    for (NSString *name in legadoNames) {
        [merged addObject:name];
    }
    return merged.array;
}

static NSDictionary *LBBSM_dicModelList_IMP(id self, SEL _cmd) {
    NSDictionary *orig = LBOrig_BSM_dicModelList ? LBOrig_BSM_dicModelList(self, _cmd) : @{};
    NSArray *legadoNames = LBLegadoGetSourceNames();
    if (legadoNames.count == 0) return orig ?: @{};
    NSMutableDictionary *merged = [orig mutableCopy];
    if (!merged) merged = [NSMutableDictionary dictionary];
    for (NSString *name in legadoNames) {
        NSDictionary *model = LBLegadoNativeModel(name);
        if (model) merged[name] = model;
    }
    return merged;
}

static NSString *LBBSM_sourceTypeBySourceName_IMP(id self, SEL _cmd, NSString *name) {
    if (LBLegadoIsSourceName(name)) return @"DOM";
    if (LBOrig_BSM_sourceTypeBySourceName) {
        return LBOrig_BSM_sourceTypeBySourceName(self, _cmd, name);
    }
    return @"DOM";
}

static NSString *LBBSM_sourceTypeTitleBySourceName_IMP(id self, SEL _cmd, NSString *name) {
    if (LBLegadoIsSourceName(name)) return @"Legado";
    if (LBOrig_BSM_sourceTypeTitleBySourceName) {
        return LBOrig_BSM_sourceTypeTitleBySourceName(self, _cmd, name);
    }
    return @"";
}

static id (*LBOrig_Config_getGroupData)(id, SEL) = NULL;

static id LBConfig_getGroupData_IMP(id self, SEL _cmd) {
    id orig = LBOrig_Config_getGroupData ? LBOrig_Config_getGroupData(self, _cmd) : nil;
    NSArray *legadoNames = LBLegadoGetSourceNames();
    if (legadoNames.count == 0) return orig;
    // getGroupData 返回 5 段 NSArray（TOP/文本/图片/音频/视频），Legado DOM 源归入「文本/小说」段（index 1）
    if ([orig isKindOfClass:[NSArray class]]) {
        NSMutableArray *groups = [orig mutableCopy];
        if (groups.count > 1) {
            id section = groups[1];
            NSMutableArray *names = [section isKindOfClass:[NSArray class]] ? [section mutableCopy] : [NSMutableArray array];
            for (NSString *name in legadoNames) {
                if (name.length > 0 && ![names containsObject:name]) {
                    [names addObject:name];
                }
            }
            groups[1] = names;
        }
        return groups;
    }
    return orig;
}

static NSArray * (*LBOrig_Config_getUseSourceNames)(id, SEL) = NULL;

typedef NSArray *(*LBGetUseSourceNamesFn)(id, SEL);

static NSMutableDictionary<NSString *, NSValue *> *LBOrigGetUseSourceNamesMap(void) {
    static NSMutableDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ map = [NSMutableDictionary dictionary]; });
    return map;
}

static NSArray *LBConfig_getUseSourceNames_IMP(id self, SEL _cmd) {
    NSArray *orig = @[];
    NSString *key = NSStringFromClass(object_getClass(self));
    NSValue *val = LBOrigGetUseSourceNamesMap()[key];
    if (!val) {
        Class cls = object_getClass(self);
        while (cls && !val) {
            val = LBOrigGetUseSourceNamesMap()[NSStringFromClass(cls)];
            cls = class_getSuperclass(cls);
        }
    }
    if (val) {
        LBGetUseSourceNamesFn fn = (LBGetUseSourceNamesFn)val.pointerValue;
        if (fn) orig = fn(self, _cmd) ?: @[];
    } else if (LBOrig_Config_getUseSourceNames) {
        // 兼容：仅挂到单一类时的旧指针
        orig = LBOrig_Config_getUseSourceNames(self, _cmd) ?: @[];
    }
    NSArray *legadoNames = LBLegadoGetSourceNames();
    // 调试：记录 Hook 命中
    NSString *dbg = [NSString stringWithFormat:@"orig=%lu legado=%lu", (unsigned long)orig.count, (unsigned long)legadoNames.count];
    [dbg writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_getusesources_hook.txt"]
          atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    if (legadoNames.count == 0) return orig ?: @[];
    NSMutableOrderedSet *merged = [NSMutableOrderedSet orderedSetWithArray:orig ?: @[]];
    for (NSString *name in legadoNames) {
        [merged addObject:name];
    }
    return merged.array;
}

static void LBLegadoShowTapBlockedAlert(UIViewController *vc) {
    if (!vc) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Legado 书源"
                                                                   message:@"该源由 LegadoBridge 管理，请通过「搜索」使用，暂不支持在站点管理内编辑。"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [vc presentViewController:alert animated:YES completion:nil];
}

/// 剥掉 textByIndexPath 可能带的「(相对时间)」后缀，得到纯源名
static NSString *LBLegadoStripDisplaySuffix(NSString *name) {
    if (name.length == 0) return name;
    NSRange r = [name rangeOfString:@"(" options:NSBackwardsSearch];
    if (r.location != NSNotFound && r.location > 0) {
        name = [name substringToIndex:r.location];
    }
    return [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

/// 从列表 VC 按 indexPath 解析源名：优先 textByIndexPath，失败则用 getUseSourceNames / getSortedSourceNames
static NSString *LBLegadoSourceNameAtIndexPath(id self, NSIndexPath *indexPath) {
    SEL textSel = @selector(textByIndexPath:);
    if ([self respondsToSelector:textSel]) {
        id text = ((id (*)(id, SEL, NSIndexPath *))objc_msgSend)(self, textSel, indexPath);
        if ([text isKindOfClass:[NSString class]] && [(NSString *)text length] > 0) {
            return LBLegadoStripDisplaySuffix((NSString *)text);
        }
    }

    NSInteger row = indexPath.row;
    if (row < 0) return nil;

    SEL useSel = @selector(getUseSourceNames);
    if ([self respondsToSelector:useSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id names = [self performSelector:useSel];
#pragma clang diagnostic pop
        if ([names isKindOfClass:[NSArray class]] && (NSUInteger)row < [(NSArray *)names count]) {
            id item = [(NSArray *)names objectAtIndex:(NSUInteger)row];
            if ([item isKindOfClass:[NSString class]]) {
                return LBLegadoStripDisplaySuffix((NSString *)item);
            }
        }
    }

    SEL sortedSel = @selector(getSortedSourceNames);
    if ([self respondsToSelector:sortedSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id names = [self performSelector:sortedSel];
#pragma clang diagnostic pop
        if ([names isKindOfClass:[NSArray class]] && (NSUInteger)row < [(NSArray *)names count]) {
            id item = [(NSArray *)names objectAtIndex:(NSUInteger)row];
            if ([item isKindOfClass:[NSString class]]) {
                return LBLegadoStripDisplaySuffix((NSString *)item);
            }
        }
    }
    return nil;
}

/// 查 dicModelList[name][@"legadoBridge"] == @"1"（壳模型持久化标记）
static BOOL LBLegadoModelMarkedInDicList(id listVC, NSString *name) {
    if (name.length == 0) return NO;
    id manager = nil;
    Class managerClass = NSClassFromString(@"BookSourceModelManager");
    if (managerClass) {
        SEL sharedSel = @selector(sharedInstance);
        if ([managerClass respondsToSelector:sharedSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            manager = [managerClass performSelector:sharedSel];
#pragma clang diagnostic pop
        }
    }
    if (!manager) {
        // 部分列表 VC 可能持有 manager 属性
        @try {
            manager = [listVC valueForKey:@"manager"];
        } @catch (__unused NSException *e) {
            manager = nil;
        }
    }
    if (!manager || ![manager respondsToSelector:@selector(dicModelList)]) return NO;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id list = [manager performSelector:@selector(dicModelList)];
#pragma clang diagnostic pop
    if (![list isKindOfClass:[NSDictionary class]]) return NO;
    id model = [(NSDictionary *)list objectForKey:name];
    if ([model isKindOfClass:[NSDictionary class]]) {
        return [[(NSDictionary *)model objectForKey:@"legadoBridge"] isEqual:@"1"];
    }
    if (model) {
        @try {
            id marker = [model valueForKey:@"legadoBridge"];
            return [marker isEqual:@"1"] || [marker isEqual:@1];
        } @catch (__unused NSException *e) {
            return NO;
        }
    }
    return NO;
}

static BOOL LBLegadoShouldBlockSourceName(id listVC, NSString *name) {
    if (name.length == 0) return NO;
    if (LBLegadoIsSourceName(name)) return YES;
    return LBLegadoModelMarkedInDicList(listVC, name);
}

/// 从任意 model（NSDictionary 或原生对象）用 KVC 读源名 / legadoBridge
static BOOL LBLegadoShouldBlockModel(id model) {
    if (!model) return NO;
    NSString *name = nil;
    id marker = nil;
    if ([model isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)model;
        name = dict[@"sourceName"];
        if (name.length == 0) name = dict[@"title"];
        marker = dict[@"legadoBridge"];
    } else {
        @try {
            name = [model valueForKey:@"sourceName"];
        } @catch (__unused NSException *e) {
            name = nil;
        }
        if (![name isKindOfClass:[NSString class]] || name.length == 0) {
            @try {
                id title = [model valueForKey:@"title"];
                name = [title isKindOfClass:[NSString class]] ? title : nil;
            } @catch (__unused NSException *e) {
                name = nil;
            }
        } else if (![name isKindOfClass:[NSString class]]) {
            name = nil;
        }
        @try {
            marker = [model valueForKey:@"legadoBridge"];
        } @catch (__unused NSException *e) {
            marker = nil;
        }
    }
    if ([marker isEqual:@"1"] || [marker isEqual:@1]) return YES;
    if ([name isKindOfClass:[NSString class]] && LBLegadoIsSourceName(name)) return YES;
    return NO;
}

static void LBLegadoDeselectRow(id tableView, NSIndexPath *indexPath) {
    if (!tableView || !indexPath) return;
    if ([tableView respondsToSelector:@selector(deselectRowAtIndexPath:animated:)]) {
        ((void (*)(id, SEL, NSIndexPath *, BOOL))objc_msgSend)(
            tableView, @selector(deselectRowAtIndexPath:animated:), indexPath, YES
        );
    }
}

// 每个被 Hook 的类各自保存原 IMP，避免多类共享同一函数指针互相覆盖
typedef void (*LBDidSelectFn)(id, SEL, id, NSIndexPath *);
typedef void (*LBOpenModelFn)(id, SEL, id, BOOL);

static NSMutableDictionary<NSString *, NSValue *> *LBOrigDidSelectMap(void) {
    static NSMutableDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ map = [NSMutableDictionary dictionary]; });
    return map;
}

static NSMutableDictionary<NSString *, NSValue *> *LBOrigOpenModelMap(void) {
    static NSMutableDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ map = [NSMutableDictionary dictionary]; });
    return map;
}

static void LBConfig_tableView_didSelect_IMP(id self, SEL _cmd, id tableView, NSIndexPath *indexPath) {
    NSString *name = LBLegadoSourceNameAtIndexPath(self, indexPath);
    if (LBLegadoShouldBlockSourceName(self, name)) {
        LBLegadoDeselectRow(tableView, indexPath);
        LBLegadoShowTapBlockedAlert((UIViewController *)self);
        return;
    }
    NSString *key = NSStringFromClass(object_getClass(self));
    NSValue *val = LBOrigDidSelectMap()[key];
    // 子类可能继承父类方法：按 isa 找不到时回退遍历已保存的原 IMP（同签名）
    if (!val) {
        Class cls = object_getClass(self);
        while (cls && !val) {
            val = LBOrigDidSelectMap()[NSStringFromClass(cls)];
            cls = class_getSuperclass(cls);
        }
    }
    if (val) {
        LBDidSelectFn orig = (LBDidSelectFn)val.pointerValue;
        if (orig) orig(self, _cmd, tableView, indexPath);
    }
}

static void LBConfig_openModel_IMP(id self, SEL _cmd, id model, BOOL createNew) {
    if (LBLegadoShouldBlockModel(model)) {
        LBLegadoShowTapBlockedAlert((UIViewController *)self);
        return;
    }
    NSString *key = NSStringFromClass(object_getClass(self));
    NSValue *val = LBOrigOpenModelMap()[key];
    if (!val) {
        Class cls = object_getClass(self);
        while (cls && !val) {
            val = LBOrigOpenModelMap()[NSStringFromClass(cls)];
            cls = class_getSuperclass(cls);
        }
    }
    if (val) {
        LBOpenModelFn orig = (LBOpenModelFn)val.pointerValue;
        if (orig) orig(self, _cmd, model, createNew);
    }
}

/// 返回真正实现该实例方法的类（向上查找 class_copyMethodList），找不到返回 Nil
static Class LBClassOwningInstanceMethod(Class cls, SEL sel) {
    while (cls) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(cls, &count);
        BOOL found = NO;
        for (unsigned int i = 0; i < count; i++) {
            if (method_getName(methods[i]) == sel) {
                found = YES;
                break;
            }
        }
        if (methods) free(methods);
        if (found) return cls;
        cls = class_getSuperclass(cls);
    }
    return Nil;
}

/// 对「实际拥有方法」的类安装 didSelect / openModel；按类名分别保存原 IMP，避免继承链重复挂导致递归
static void LBInstallDidSelectAndOpenModelOnClass(Class requested) {
    if (!requested) return;

    SEL selectSel = @selector(tableView:didSelectRowAtIndexPath:);
    Class selectOwner = LBClassOwningInstanceMethod(requested, selectSel);
    if (selectOwner) {
        NSString *classKey = NSStringFromClass(selectOwner);
        if (!LBOrigDidSelectMap()[classKey]) {
            Method selectMethod = class_getInstanceMethod(selectOwner, selectSel);
            if (selectMethod) {
                IMP prev = method_getImplementation(selectMethod);
                LBOrigDidSelectMap()[classKey] = [NSValue valueWithPointer:prev];
                method_setImplementation(selectMethod, (IMP)LBConfig_tableView_didSelect_IMP);
                NSLog(@"[LegadoBridge] hooked %@ tableView:didSelectRowAtIndexPath: (via %@)",
                      classKey, NSStringFromClass(requested));
            }
        }
    }

    SEL openSel = @selector(openModel:createNew:);
    Class openOwner = LBClassOwningInstanceMethod(requested, openSel);
    if (openOwner) {
        NSString *classKey = NSStringFromClass(openOwner);
        if (!LBOrigOpenModelMap()[classKey]) {
            Method openMethod = class_getInstanceMethod(openOwner, openSel);
            if (openMethod) {
                IMP prev = method_getImplementation(openMethod);
                LBOrigOpenModelMap()[classKey] = [NSValue valueWithPointer:prev];
                method_setImplementation(openMethod, (IMP)LBConfig_openModel_IMP);
                NSLog(@"[LegadoBridge] hooked %@ openModel:createNew: (via %@)",
                      classKey, NSStringFromClass(requested));
            }
        }
    }
}

void LBInstallSourceListHooks(void) {
    Class managerClass = NSClassFromString(@"BookSourceModelManager");
    if (!managerClass) {
        NSLog(@"[LegadoBridge] BookSourceModelManager not found, skip source list hooks");
        return;
    }

    SEL sortedSel = @selector(getSortedSourceNames);
    Method sortedMethod = class_getInstanceMethod(managerClass, sortedSel);
    if (sortedMethod) {
        LBOrig_BSM_getSortedSourceNames = (NSArray * (*)(id, SEL))method_getImplementation(sortedMethod);
        method_setImplementation(sortedMethod, (IMP)LBBSM_getSortedSourceNames_IMP);
        NSLog(@"[LegadoBridge] hooked BookSourceModelManager getSortedSourceNames");
    }

    SEL listSel = @selector(dicModelList);
    Method listMethod = class_getInstanceMethod(managerClass, listSel);
    if (listMethod) {
        LBOrig_BSM_dicModelList = (NSDictionary * (*)(id, SEL))method_getImplementation(listMethod);
        method_setImplementation(listMethod, (IMP)LBBSM_dicModelList_IMP);
        NSLog(@"[LegadoBridge] hooked BookSourceModelManager dicModelList");
    }

    SEL typeSel = @selector(sourceTypeBySourceName:);
    Method typeMethod = class_getInstanceMethod(managerClass, typeSel);
    if (typeMethod) {
        LBOrig_BSM_sourceTypeBySourceName = (NSString * (*)(id, SEL, NSString *))method_getImplementation(typeMethod);
        method_setImplementation(typeMethod, (IMP)LBBSM_sourceTypeBySourceName_IMP);
        NSLog(@"[LegadoBridge] hooked BookSourceModelManager sourceTypeBySourceName:");
    }

    SEL titleSel = @selector(sourceTypeTitleBySourceName:);
    Method titleMethod = class_getInstanceMethod(managerClass, titleSel);
    if (titleMethod) {
        LBOrig_BSM_sourceTypeTitleBySourceName = (NSString * (*)(id, SEL, NSString *))method_getImplementation(titleMethod);
        method_setImplementation(titleMethod, (IMP)LBBSM_sourceTypeTitleBySourceName_IMP);
        NSLog(@"[LegadoBridge] hooked BookSourceModelManager sourceTypeTitleBySourceName:");
    }

    Class listBaseClass = NSClassFromString(@"ConfigSourceListBase");
    if (listBaseClass) {
        SEL groupSel = @selector(getGroupData);
        Method groupMethod = class_getInstanceMethod(listBaseClass, groupSel);
        if (groupMethod) {
            LBOrig_Config_getGroupData = (id (*)(id, SEL))method_getImplementation(groupMethod);
            method_setImplementation(groupMethod, (IMP)LBConfig_getGroupData_IMP);
            NSLog(@"[LegadoBridge] hooked ConfigSourceListBase getGroupData");
        }
    }

    // getUseSourceNames：挂到实际拥有该方法的类（按类分别保存原 IMP）
    NSArray<NSString *> *useNameClasses = @[
        @"ConfigSourceModelListCon",
        @"ConfigSourceModelListCon_NoneSourceModel",
        @"ConfigSourceListBase",
        @"ConfigSourceModelConBase"
    ];
    for (NSString *cn in useNameClasses) {
        Class requested = NSClassFromString(cn);
        if (!requested) continue;
        Class owner = LBClassOwningInstanceMethod(requested, @selector(getUseSourceNames));
        if (!owner) continue;
        NSString *ownerKey = NSStringFromClass(owner);
        if (LBOrigGetUseSourceNamesMap()[ownerKey]) continue;
        Method useMethod = class_getInstanceMethod(owner, @selector(getUseSourceNames));
        if (!useMethod) continue;
        IMP prev = method_getImplementation(useMethod);
        LBOrigGetUseSourceNamesMap()[ownerKey] = [NSValue valueWithPointer:prev];
        if (!LBOrig_Config_getUseSourceNames) {
            LBOrig_Config_getUseSourceNames = (NSArray * (*)(id, SEL))prev;
        }
        method_setImplementation(useMethod, (IMP)LBConfig_getUseSourceNames_IMP);
        NSLog(@"[LegadoBridge] hooked %@ getUseSourceNames (via %@)", ownerKey, cn);
    }

    // didSelect / openModel：多类安装，覆盖逆向确认的列表实现类
    NSArray<NSString *> *tapHookClasses = @[
        @"ConfigSourceModelListCon",
        @"ConfigSourceModelListCon_NoneSourceModel",
        @"ConfigSourceListBase",
        @"ConfigSourceModelConBase"
    ];
    NSMutableArray *hooked = [NSMutableArray array];
    for (NSString *cn in tapHookClasses) {
        Class c = NSClassFromString(cn);
        if (!c) {
            NSLog(@"[LegadoBridge] class %@ not found, skip tap hooks", cn);
            continue;
        }
        LBInstallDidSelectAndOpenModelOnClass(c);
        [hooked addObject:cn];
    }
    NSString *marker = [NSString stringWithFormat:@"tapHooks=%@", [hooked componentsJoinedByString:@","]];
    [marker writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_tap_hooks.txt"]
             atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

#pragma mark - Search / Catalog / Content Hooks

@interface LBSearchHookTarget : NSObject
@end

@implementation LBSearchHookTarget

- (void)lb_onSearchBookSourceResponse:(NSNotification *)note {
    // 若已由 LegadoBridge 注入则跳过原生 XBS 路径
    if ([note.userInfo[@"fromLegadoBridge"] boolValue]) {
        return;
    }
}

- (void)lb_startSearch:(NSString *)keyword
    prioritySourceType:(NSInteger)type
            fromShuping:(BOOL)shuping
                 quick:(BOOL)quick {
    // 转发给 LegadoBridge
    id core = LBLegadoCoreIfReady();
    if ([core respondsToSelector:@selector(handleSearchRequestWithKeyword:sourceUrl:)]) {
        ((void (*)(id, SEL, NSString *, NSString *))objc_msgSend)(
            core, @selector(handleSearchRequestWithKeyword:sourceUrl:), keyword, nil
        );
    }
}

@end

static void LBHookClassIfExists(NSString *className, NSString *selectorName, IMP newIMP) {
    Class cls = NSClassFromString(className);
    if (!cls) return;
    SEL sel = NSSelectorFromString(selectorName);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    const char *types = method_getTypeEncoding(m);
    class_replaceMethod(cls, sel, newIMP, types);
}

void LBInstallSearchHooks(void) {
    // BookSourceManagerBase / SearchBookSource — 运行时按符号名挂钩
    Class managerClass = NSClassFromString(@"BookSourceManager");
    if (!managerClass) {
        managerClass = NSClassFromString(@"BookSourceManagerBase");
    }

    if (managerClass) {
        // canSearch:fromShuping: — UI 在 startSearch 前据此弹「无可用站点」；
        // 有 Legado 源时强制 YES，避免壳模型缺 enable 时被原生拦死。
        SEL canSel = NSSelectorFromString(@"canSearch:fromShuping:");
        Method canMethod = class_getInstanceMethod(managerClass, canSel);
        if (canMethod) {
            IMP canOrigIMP = method_getImplementation(canMethod);
            IMP canHookIMP = imp_implementationWithBlock(^BOOL(id self, NSInteger type, BOOL shuping) {
                id core = LBLegadoCoreIfReady();
                if ([core respondsToSelector:@selector(allLegadoSourceNames)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    NSArray *names = [core performSelector:@selector(allLegadoSourceNames)];
#pragma clang diagnostic pop
                    if (names.count > 0) {
                        [@"canSearch=YES legado" writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_cansearch.txt"]
                                                  atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                        return YES;
                    }
                }
                return ((BOOL (*)(id, SEL, NSInteger, BOOL))canOrigIMP)(self, canSel, type, shuping);
            });
            method_setImplementation(canMethod, canHookIMP);
            NSLog(@"[LegadoBridge] hooked canSearch:fromShuping: on %@", NSStringFromClass(managerClass));
        }

        SEL searchSel = NSSelectorFromString(@"startSearch:prioritySourceType:fromShuping:quick:");
        Method searchMethod = class_getInstanceMethod(managerClass, searchSel);
        if (searchMethod) {
            IMP originalIMP = method_getImplementation(searchMethod);
            (void)originalIMP;

            IMP hookIMP = imp_implementationWithBlock(^void(id self, NSString *keyword, NSInteger type, BOOL shuping, BOOL quick) {
                // 仅当 SourceRegistry 已有 Legado 源时拦截；否则走原生 XBS 搜索
                id core = LBLegadoCoreIfReady();
                BOOL hasLegado = NO;
                if ([core respondsToSelector:@selector(allLegadoSourceNames)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    NSArray *names = [core performSelector:@selector(allLegadoSourceNames)];
#pragma clang diagnostic pop
                    hasLegado = names.count > 0;
                }
                if (hasLegado && [core respondsToSelector:@selector(handleSearchRequestWithKeyword:sourceUrl:)]) {
                    [@"startSearch legado" writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_hook.txt"]
                                            atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                    ((void (*)(id, SEL, NSString *, NSString *))objc_msgSend)(
                        core, @selector(handleSearchRequestWithKeyword:sourceUrl:), keyword ?: @"", nil
                    );
                    return;
                }
                ((void (*)(id, SEL, NSString *, NSInteger, BOOL, BOOL))originalIMP)(
                    self, searchSel, keyword, type, shuping, quick
                );
            });
            method_setImplementation(searchMethod, hookIMP);
            NSLog(@"[LegadoBridge] hooked startSearch on %@", NSStringFromClass(managerClass));
        }
    }

    // 目录查询通知拦截 — 当 userInfo 含 legadoBridge 标记时由引擎驱动
    [[NSNotificationCenter defaultCenter] addObserverForName:@"dNotifyName_QueryCatalogResponse"
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(NSNotification *note) {
        if ([note.userInfo[@"fromLegadoBridge"] boolValue]) return;
    }];
}

__attribute__((constructor))
static void LBBridgeAutoInit(void) {
    // 调试标记：dylib constructor 执行（写到 App 沙盒 Home，constructor 时已挂载）
    [@"dylib loaded" writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_dylib_loaded.txt"] atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    LBInstallHooks();
    // 调试标记：hooks 安装完成
    [@"hooks installed" writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_hooks_installed.txt"] atomically:NO encoding:NSUTF8StringEncoding error:NULL];
}
