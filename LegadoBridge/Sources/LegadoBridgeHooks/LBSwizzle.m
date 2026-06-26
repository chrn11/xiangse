#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
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

static id LBLegadoDetectAndImport(NSData *data) {
    if (data.length == 0) return nil;
    @try {
        Class coreClass = NSClassFromString(@"LegadoBridge.LegadoBridgeCore");
        if (!coreClass) return nil;
        id core = [coreClass performSelector:@selector(shared)];
        if (![core respondsToSelector:@selector(isLegadoJSONData:)]) return nil;
        BOOL isLegado = ((BOOL (*)(id, SEL, NSData *))objc_msgSend)(core, @selector(isLegadoJSONData:), data);
        if (!isLegado) return nil;
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
    // 启动后延迟弹 Legado 书源导入 alert（主线程异步，不阻塞启动）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        LBLegadoShowImportAlert();
    });
    return ret;
}

// 弹 UIAlertController 让用户粘贴 Legado JSON 的 URL，拉取后注册到 SourceRegistry
static void LBLegadoShowImportAlert(void) {
    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    if (!window) return;
    UIViewController *rootVC = window.rootViewController;
    if (!rootVC) return;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Legado 书源导入"
                                                                   message:@"粘贴 Legado 书源 JSON 的 URL（http/https）"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"https://example.com/source.json";
        textField.keyboardType = UIKeyboardTypeURL;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"导入" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *input = alert.textFields.firstObject.text;
        if (input.length == 0) return;
        NSURL *url = [NSURL URLWithString:input];
        if (!url) return;
        NSData *data = [NSData dataWithContentsOfURL:url];
        if (data.length == 0) {
            LBLegadoShowResult(@"拉取失败：无数据");
            return;
        }
        LBLegadoImportData(data);
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [rootVC presentViewController:alert animated:YES completion:nil];
}

static void LBLegadoImportData(NSData *data) {
    @try {
        Class coreClass = NSClassFromString(@"LegadoBridge.LegadoBridgeCore");
        if (!coreClass) { LBLegadoShowResult(@"无 LegadoBridgeCore"); return; }
        id core = [coreClass performSelector:@selector(shared)];
        if (![core respondsToSelector:@selector(isLegadoJSONData:)]) { LBLegadoShowResult(@"无 isLegadoJSONData:"); return; }
        BOOL isLegado = ((BOOL (*)(id, SEL, NSData *))objc_msgSend)(core, @selector(isLegadoJSONData:), data);
        if (!isLegado) { LBLegadoShowResult(@"不是 Legado JSON 格式"); return; }
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
    UIWindow *window = [UIApplication sharedApplication].keyWindow;
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
                    id core = [coreClass performSelector:@selector(shared)];
                    if ([core respondsToSelector:@selector(isLegadoJSONData:)]) {
                        BOOL isLegado = ((BOOL (*)(id, SEL, NSData *))objc_msgSend)(core, @selector(isLegadoJSONData:), fileData);
                        // 调试标记 1：isLegado 检测结果
                        [(isLegado ? @"YES" : @"NO") writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_islegado_result.txt"] atomically:NO encoding:NSUTF8StringEncoding error:NULL];
                        if (isLegado) {
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
                            // 已作为 Legado 书源处理，短路原生流程
                            return YES;
                        }
                    } else {
                        [@"no isLegadoJSONData:" writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_islegado_result.txt"] atomically:NO encoding:NSUTF8StringEncoding error:NULL];
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
    Class coreClass = NSClassFromString(@"LegadoBridge.LegadoBridgeCore");
    if (!coreClass) return nil;
    return [coreClass performSelector:@selector(shared)];
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

static NSArray * (*LBOrig_Config_getUseSourceNames)(id, SEL) = NULL;

static NSArray *LBConfig_getUseSourceNames_IMP(id self, SEL _cmd) {
    NSArray *orig = LBOrig_Config_getUseSourceNames ? LBOrig_Config_getUseSourceNames(self, _cmd) : @[];
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

    Class listConClass = NSClassFromString(@"ConfigSourceModelListCon");
    if (listConClass) {
        SEL useSel = @selector(getUseSourceNames);
        Method useMethod = class_getInstanceMethod(listConClass, useSel);
        if (useMethod) {
            LBOrig_Config_getUseSourceNames = (NSArray * (*)(id, SEL))method_getImplementation(useMethod);
            method_setImplementation(useMethod, (IMP)LBConfig_getUseSourceNames_IMP);
            NSLog(@"[LegadoBridge] hooked ConfigSourceModelListCon getUseSourceNames");
        }
    }
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
    Class coreClass = NSClassFromString(@"LegadoBridge.LegadoBridgeCore");
    if (coreClass) {
        id core = [coreClass performSelector:@selector(shared)];
        if ([core respondsToSelector:@selector(handleSearchRequestWithKeyword:sourceUrl:)]) {
            ((void (*)(id, SEL, NSString *, NSString *))objc_msgSend)(
                core, @selector(handleSearchRequestWithKeyword:sourceUrl:), keyword, nil
            );
        }
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
        SEL searchSel = NSSelectorFromString(@"startSearch:prioritySourceType:fromShuping:quick:");
        Method searchMethod = class_getInstanceMethod(managerClass, searchSel);
        if (searchMethod) {
            IMP originalIMP = method_getImplementation(searchMethod);
            (void)originalIMP;

            IMP hookIMP = imp_implementationWithBlock(^void(id self, NSString *keyword, NSInteger type, BOOL shuping, BOOL quick) {
                Class coreClass = NSClassFromString(@"LegadoBridge.LegadoBridgeCore");
                if (coreClass) {
                    id core = [coreClass performSelector:@selector(shared)];
                    if ([core respondsToSelector:@selector(handleSearchRequestWithKeyword:sourceUrl:)]) {
                        ((void (*)(id, SEL, NSString *, NSString *))objc_msgSend)(
                            core, @selector(handleSearchRequestWithKeyword:sourceUrl:), keyword ?: @"", nil
                        );
                        return;
                    }
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
