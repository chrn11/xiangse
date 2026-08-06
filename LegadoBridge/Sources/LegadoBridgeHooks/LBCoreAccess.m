#import "LBInternal.h"
#import "LegadoBridge.h"
#include <string.h>
#include <stdint.h>

static _Atomic(bool) LBCoreReady = false;
static _Atomic(bool) LBCoreInitializing = false;

id LBLegadoCoreIfReady(void) {
    Class coreClass = NSClassFromString(@"LegadoBridge.LegadoBridgeCore");
    if (!coreClass) return nil;

    if (atomic_load(&LBCoreReady)) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        return [coreClass performSelector:@selector(shared)];
#pragma clang diagnostic pop
    }
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

NSArray *LBLegadoGetSourceNames(void) {
    // 无原生名上下文时退回 display 名；合并路径请用 LBMergeLegadoNames。
    id core = LBLegadoCoreIfReady();
    if (!core || ![core respondsToSelector:@selector(allLegadoSourceNames)]) return @[];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    NSArray *names = [core performSelector:@selector(allLegadoSourceNames)];
#pragma clang diagnostic pop
    return names ?: @[];
}

/// TC-06：与 orig 冲突时返回 projectionKey，禁止新写 ·Legado。
static NSArray *LBLegadoListKeysWithNativeNames(NSArray *orig) {
    id core = LBLegadoCoreIfReady();
    if (!core) return @[];
    if ([core respondsToSelector:@selector(allLegadoListKeysWithNativeNames:)]) {
        return ((NSArray * (*)(id, SEL, NSArray *))objc_msgSend)(
            core, @selector(allLegadoListKeysWithNativeNames:), orig ?: @[]) ?: @[];
    }
    return LBLegadoGetSourceNames();
}

BOOL LBLegadoIsSourceName(NSString *name) {
    if (name.length == 0) return NO;
    id core = LBLegadoCoreIfReady();
    if (!core || ![core respondsToSelector:@selector(isLegadoSourceName:)]) return NO;
    return ((BOOL (*)(id, SEL, NSString *))objc_msgSend)(core, @selector(isLegadoSourceName:), name);
}

NSDictionary *LBLegadoNativeModel(NSString *name) {
    id core = LBLegadoCoreIfReady();
    if (!core || ![core respondsToSelector:@selector(legadoNativeModelForSourceName:)]) return nil;
    return ((NSDictionary * (*)(id, SEL, NSString *))objc_msgSend)(core, @selector(legadoNativeModelForSourceName:), name);
}

NSArray *LBMergeLegadoNames(NSArray *orig) {
    NSArray *legadoKeys = LBLegadoListKeysWithNativeNames(orig);
    if (legadoKeys.count == 0) return orig ?: @[];
    NSMutableOrderedSet *merged = [NSMutableOrderedSet orderedSetWithArray:orig ?: @[]];
    for (NSString *key in legadoKeys) {
        if (key.length == 0) continue;
        [merged addObject:key];
    }
    return merged.array;
}

/// TC-06：列表键 → 可见标题；projectionKey / 旧 ·Legado 绝不作为 cell 文案。
NSString *LBLegadoDisplayNameForListKey(NSString *key) {
    if (key.length == 0) return key;
    id core = LBLegadoCoreIfReady();
    if (core && [core respondsToSelector:@selector(displayNameForLegadoListKey:)]) {
        NSString *d = ((NSString * (*)(id, SEL, NSString *))objc_msgSend)(
            core, @selector(displayNameForLegadoListKey:), key);
        if (d.length > 0) return d;
    }
    if ([key hasPrefix:@"__lb_src_v2_"]) {
        NSDictionary *m = LBLegadoNativeModel(key);
        NSString *t = m[@"title"] ?: m[@"sourceName"] ?: m[@"bookSourceName"];
        if ([t isKindOfClass:[NSString class]] && t.length > 0) return t;
    }
    if ([key hasSuffix:@"·Legado"]) {
        return [key substringToIndex:key.length - @"·Legado".length];
    }
    return key;
}

/// AK：主线程弱缓存；bg 禁止任何 windows API（含 keyWindow / UIApplication.windows / scene.windows）
static __weak UIWindow *sLBCachedKeyWindow = nil;

static void LBAKProbeLine(NSString *tag) {
    if (tag.length == 0) return;
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_ab_probe.txt"];
    NSString *line = [NSString stringWithFormat:@"%@ | %@\n", [NSDate date], tag];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    } else {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh synchronizeFile];
        [fh closeFile];
    }
}

UIWindow *LBLegadoKeyWindow(void) {
    if (![NSThread isMainThread]) {
        // AK：禁止 legacy keyWindow/windows（AJ 回落后仍触 UIWindowScene syslog）
        UIWindow *cached = sLBCachedKeyWindow;
        LBAKProbeLine([NSString stringWithFormat:
                       @"hypothesis_AK ak_bg_windows_api_skip caller=LBLegadoKeyWindow cached=%d",
                       cached ? 1 : 0]);
        if (cached && cached.rootViewController) return cached;
        return nil;
    }
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
                if (window.isKeyWindow) {
                    sLBCachedKeyWindow = window;
                    return window;
                }
                if (!fallback) fallback = window;
            }
        }
    }
    if (fallback) {
        sLBCachedKeyWindow = fallback;
        return fallback;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    UIWindow *legacyKey = UIApplication.sharedApplication.keyWindow;
#pragma clang diagnostic pop
    if (legacyKey.rootViewController) {
        sLBCachedKeyWindow = legacyKey;
        return legacyKey;
    }
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (!window.isHidden && window.alpha > 0.01 && window.rootViewController) {
            sLBCachedKeyWindow = window;
            return window;
        }
    }
    return nil;
}

void LBLegadoShowResult(NSString *msg) {
    if (![NSThread isMainThread]) {
        LBAKProbeLine(@"hypothesis_AK ak_bg_windows_api_skip caller=LBLegadoShowResult");
        NSString *copy = [msg copy] ?: @"";
        dispatch_async(dispatch_get_main_queue(), ^{
            LBLegadoShowResult(copy);
        });
        return;
    }
    UIWindow *window = LBLegadoKeyWindow();
    UIViewController *rootVC = window.rootViewController;
    if (!rootVC) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil message:msg preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    if (rootVC.presentedViewController) {
        [rootVC dismissViewControllerAnimated:NO completion:^{
            [rootVC presentViewController:alert animated:YES completion:nil];
        }];
    } else {
        [rootVC presentViewController:alert animated:YES completion:nil];
    }
}

/// 取当前可见导航栈（优先 topmost presented 链上的 UINavigationController）
static UINavigationController *LBLegadoVisibleNavigationController(void) {
    UIWindow *window = LBLegadoKeyWindow();
    if (!window) return nil;
    UIViewController *rootVC = window.rootViewController;
    while (rootVC.presentedViewController) {
        rootVC = rootVC.presentedViewController;
    }
    if ([rootVC isKindOfClass:[UINavigationController class]]) {
        return (UINavigationController *)rootVC;
    }
    if (rootVC.navigationController) {
        return rootVC.navigationController;
    }
    if ([rootVC isKindOfClass:[UITabBarController class]]) {
        UIViewController *selected = [(UITabBarController *)rootVC selectedViewController];
        if ([selected isKindOfClass:[UINavigationController class]]) {
            return (UINavigationController *)selected;
        }
        if (selected.navigationController) {
            return selected.navigationController;
        }
    }
    // 再挖一层：tab/nav 上已 push 的 topVC 可能自带 nav
    UIViewController *top = rootVC;
    while (top.presentedViewController) {
        top = top.presentedViewController;
    }
    if ([top isKindOfClass:[UINavigationController class]]) {
        return (UINavigationController *)top;
    }
    return top.navigationController;
}

void LBLegadoPresentManagerVC(NSString *focusSourceUrl) {
    if (![NSThread isMainThread]) {
        LBAKProbeLine(@"hypothesis_AK ak_bg_windows_api_skip caller=LBLegadoPresentManagerVC");
        NSString *url = [focusSourceUrl copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            LBLegadoPresentManagerVC(url);
        });
        return;
    }
    UIWindow *window = LBLegadoKeyWindow();
    if (!window) return;
    UIViewController *rootVC = window.rootViewController;
    while (rootVC.presentedViewController) {
        rootVC = rootVC.presentedViewController;
    }
    Class managerVCClass = NSClassFromString(@"LBLegadoSourceManagerVC");
    if (!managerVCClass) {
        LBLegadoShowResult(@"管理页未加载（LBLegadoSourceManagerVC 不存在）");
        return;
    }
    UIViewController *managerVC = [[managerVCClass alloc] init];
    if (focusSourceUrl.length > 0 && [managerVC respondsToSelector:@selector(setFocusSourceUrl:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [managerVC performSelector:@selector(setFocusSourceUrl:) withObject:focusSourceUrl];
#pragma clang diagnostic pop
    }
    UINavigationController *nav = LBLegadoVisibleNavigationController();
    if (nav) {
        UIViewController *top = nav.topViewController;
        if ([top isKindOfClass:managerVCClass]) {
            if (focusSourceUrl.length > 0 && [top respondsToSelector:@selector(setFocusSourceUrl:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [top performSelector:@selector(setFocusSourceUrl:) withObject:focusSourceUrl];
#pragma clang diagnostic pop
            }
            return;
        }
        [nav pushViewController:managerVC animated:YES];
    } else {
        UINavigationController *wrapNav = [[UINavigationController alloc] initWithRootViewController:managerVC];
        wrapNav.modalPresentationStyle = UIModalPresentationFullScreen;
        [rootVC presentViewController:wrapNav animated:YES completion:nil];
    }
}

void LBLegadoPresentSourceEditor(NSString *sourceUrl) {
    if (![NSThread isMainThread]) {
        NSString *url = [sourceUrl copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            LBLegadoPresentSourceEditor(url);
        });
        return;
    }
    if (sourceUrl.length == 0) {
        LBLegadoPresentManagerVC(nil);
        return;
    }
    // 回退开关：Documents/legado_u2_use_bridge_manager.txt 存在则走旧「管理列表→编辑」
    NSString *legacyFlag = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_u2_use_bridge_manager.txt"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:legacyFlag]) {
        LBLegadoPresentManagerVC(sourceUrl);
        return;
    }
    Class editorCls = NSClassFromString(@"LBLegadoSourceEditorVC");
    if (!editorCls) {
        LBLegadoPresentManagerVC(sourceUrl);
        return;
    }
    UITableViewController *editor = [[editorCls alloc] initWithStyle:UITableViewStyleInsetGrouped];
    if ([editor respondsToSelector:@selector(setSourceUrl:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [editor performSelector:@selector(setSourceUrl:) withObject:sourceUrl];
#pragma clang diagnostic pop
    }
    UINavigationController *nav = LBLegadoVisibleNavigationController();
    if (nav) {
        [nav pushViewController:editor animated:YES];
        NSString *marker = [NSString stringWithFormat:@"u2_editor_push url=%@", sourceUrl];
        [marker writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_u2_editor_push.txt"]
                 atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return;
    }
    // 无导航栈：包一层再 present，关闭后不落桥接列表
    UINavigationController *wrapNav = [[UINavigationController alloc] initWithRootViewController:editor];
    wrapNav.modalPresentationStyle = UIModalPresentationFullScreen;
    UIWindow *window = LBLegadoKeyWindow();
    UIViewController *rootVC = window.rootViewController;
    while (rootVC.presentedViewController) {
        rootVC = rootVC.presentedViewController;
    }
    if (rootVC) {
        [rootVC presentViewController:wrapNav animated:YES completion:nil];
    } else {
        LBLegadoPresentManagerVC(sourceUrl);
    }
}

BOOL LBLegadoPresentNativeImport(void) {
    return LBLegadoPresentNativeImportFrom(nil);
}

BOOL LBLegadoPresentNativeImportFrom(UIViewController *fromVC) {
    if (![NSThread isMainThread]) {
        __block BOOL ok = NO;
        UIViewController *vcCopy = fromVC;
        dispatch_sync(dispatch_get_main_queue(), ^{
            ok = LBLegadoPresentNativeImportFrom(vcCopy);
        });
        return ok;
    }
    // 回退：Documents/legado_u3_force_alert.txt 强制 UIAlert
    NSString *forceAlert = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_u3_force_alert.txt"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:forceAlert]) {
        [@"SKIP force_alert" writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_u3_import.txt"]
                              atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return NO;
    }
    Class syncCls = NSClassFromString(@"ConfigSourceModelSyncCon");
    if (!syncCls) {
        [@"FAIL no ConfigSourceModelSyncCon" writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_u3_import.txt"]
                                              atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return NO;
    }
    UIViewController *vc = nil;
    @try {
        vc = [[syncCls alloc] init];
    } @catch (NSException *e) {
        NSString *msg = [NSString stringWithFormat:@"FAIL init exception %@", e.reason ?: @""];
        [msg writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_u3_import.txt"]
              atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return NO;
    }
    if (!vc) {
        [@"FAIL init nil" writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_u3_import.txt"]
                           atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return NO;
    }
    // 优先用站点列表自己的 nav，避免全局「可见」nav 指到错栈却 return YES
    UINavigationController *nav = fromVC.navigationController;
    if (!nav) {
        nav = LBLegadoVisibleNavigationController();
    }
    if (nav) {
        for (UIViewController *top in nav.viewControllers) {
            if ([top isKindOfClass:syncCls]) {
                [nav popToViewController:top animated:YES];
                [@"OK popTo existing ConfigSourceModelSyncCon" writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_u3_import.txt"]
                                                                atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                return YES;
            }
        }
        [nav pushViewController:vc animated:YES];
        NSString *mark = [NSString stringWithFormat:@"OK push ConfigSourceModelSyncCon via=%@",
                          fromVC ? NSStringFromClass([fromVC class]) : @"visibleNav"];
        [mark writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_u3_import.txt"]
               atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return YES;
    }
    UIWindow *window = LBLegadoKeyWindow();
    UIViewController *rootVC = window.rootViewController;
    while (rootVC.presentedViewController) {
        rootVC = rootVC.presentedViewController;
    }
    if (!rootVC) {
        [@"FAIL no rootVC" writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_u3_import.txt"]
                            atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return NO;
    }
    UINavigationController *wrapNav = [[UINavigationController alloc] initWithRootViewController:vc];
    wrapNav.modalPresentationStyle = UIModalPresentationFullScreen;
    [rootVC presentViewController:wrapNav animated:YES completion:nil];
    [@"OK present ConfigSourceModelSyncCon" writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_u3_import.txt"]
                                              atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    return YES;
}

Class LBClassOwningInstanceMethod(Class cls, SEL sel) {
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

static BOOL LBValidateMethod(Method m, SEL sel, const char *expectedHint,
                             NSString **outActualEnc, NSString **outReason) {
    if (!m) {
        if (outReason) *outReason = [NSString stringWithFormat:@"missing %@", NSStringFromSelector(sel)];
        return NO;
    }
    const char *enc = method_getTypeEncoding(m) ?: "";
    if (outActualEnc) *outActualEnc = @(enc);
    if (expectedHint && expectedHint[0] != '\0') {
        if (strstr(enc, expectedHint) == NULL) {
            if (outReason) {
                *outReason = [NSString stringWithFormat:@"%@ enc=%s expect~%s",
                              NSStringFromSelector(sel), enc, expectedHint];
            }
            return NO;
        }
    }
    return YES;
}

BOOL LBValidateInstanceMethod(Class cls, SEL sel, const char *expectedHint,
                              NSString **outActualEnc, NSString **outReason) {
    if (!cls) {
        if (outReason) *outReason = @"class nil";
        return NO;
    }
    Method m = class_getInstanceMethod(cls, sel);
    return LBValidateMethod(m, sel, expectedHint, outActualEnc, outReason);
}

BOOL LBValidateClassMethod(Class cls, SEL sel, const char *expectedHint,
                           NSString **outActualEnc, NSString **outReason) {
    if (!cls) {
        if (outReason) *outReason = @"class nil";
        return NO;
    }
    Method m = class_getClassMethod(cls, sel);
    return LBValidateMethod(m, sel, expectedHint, outActualEnc, outReason);
}

BOOL LBInstallInstanceHook(Class cls, SEL sel, const char *expectedHint,
                           IMP newIMP, IMP *outOrigIMP, NSString *hookLabel) {
    if (!cls || !newIMP) return NO;
    NSString *reason = nil;
    NSString *enc = nil;
    if (!LBValidateInstanceMethod(cls, sel, expectedHint, &enc, &reason)) {
        NSLog(@"[LegadoBridge] skip hook %@ on %@: %@",
              hookLabel ?: NSStringFromSelector(sel),
              NSStringFromClass(cls),
              reason ?: @"validate failed");
        return NO;
    }
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    IMP prev = method_getImplementation(m);
    if (outOrigIMP) *outOrigIMP = prev;
    method_setImplementation(m, newIMP);
    NSLog(@"[LegadoBridge] hooked %@ %@ enc=%@",
          NSStringFromClass(cls), hookLabel ?: NSStringFromSelector(sel), enc ?: @"");
    return YES;
}

#pragma mark - 阅读会话（进程内，非持久化；按 token / pair 索引）

/// token → @{ sourceUrl, bookUrl, token }
static NSMutableDictionary<NSString *, NSDictionary *> *LBReadingTokenMap(void) {
    static NSMutableDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ map = [NSMutableDictionary dictionary]; });
    return map;
}

/// bookUrl → 唯一 token；歧义时移除
static NSMutableDictionary<NSString *, NSString *> *LBReadingBookUrlToToken(void) {
    static NSMutableDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ map = [NSMutableDictionary dictionary]; });
    return map;
}

/// 歧义 bookUrl 集合
static NSMutableSet<NSString *> *LBReadingAmbiguousBookUrls(void) {
    static NSMutableSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSMutableSet set]; });
    return set;
}

BOOL LBReadingDicLooksLegado(NSDictionary *dic) {
    if (![dic isKindOfClass:[NSDictionary class]]) return NO;
    id marker = dic[@"legadoBridge"];
    if ([marker isEqual:@"1"] || [marker isEqual:@1] || [marker isEqual:@YES]) return YES;
    if ([dic[@"fromLegadoBridge"] boolValue]) return YES;
    if (LBReadingDicLooksExplicitNativeXBS(dic)) return NO;
    NSString *sourceUrl = LBReadingSourceUrlFromDic(dic);
    if (sourceUrl.length == 0) return NO;
    id core = LBLegadoCoreIfReady();
    if (!core) return NO;
    if ([core respondsToSelector:@selector(isLegadoSourceName:)]) {
        NSString *name = dic[@"sourceName"];
        if (![name isKindOfClass:[NSString class]]) name = dic[@"bookSourceName"];
        if ([name isKindOfClass:[NSString class]] && LBLegadoIsSourceName(name)) return YES;
    }
    // sourceUrl 出现在已注册源中
    if ([core respondsToSelector:@selector(allSourcesInfo)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        NSArray *info = [core performSelector:@selector(allSourcesInfo)];
#pragma clang diagnostic pop
        for (NSDictionary *row in info) {
            if (![row isKindOfClass:[NSDictionary class]]) continue;
            NSString *u = row[@"bookSourceUrl"];
            if ([u isKindOfClass:[NSString class]] && [u isEqualToString:sourceUrl]) return YES;
        }
    }
    return NO;
}

BOOL LBReadingDicLooksExplicitNativeXBS(NSDictionary *dic) {
    if (![dic isKindOfClass:[NSDictionary class]]) return NO;
    id marker = dic[@"legadoBridge"];
    if ([marker isEqual:@"1"] || [marker isEqual:@1] || [marker isEqual:@YES]) return NO;
    if ([dic[@"fromLegadoBridge"] boolValue]) return NO;

    NSString *name = nil;
    for (NSString *key in @[@"sourceName", @"bookSourceName", @"querySourceName"]) {
        id value = dic[key];
        if ([value isKindOfClass:[NSString class]] &&
            [(NSString *)value stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]].length > 0) {
            name = [(NSString *)value stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            break;
        }
    }
    if (name.length == 0) return NO;
    return !LBLegadoIsSourceName(name);
}

NSString *LBReadingBookUrlFromDic(NSDictionary *dic) {
    if (![dic isKindOfClass:[NSDictionary class]]) return nil;
    for (NSString *key in @[@"bookUrl", @"url", @"book_url"]) {
        id v = dic[key];
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) return v;
    }
    return nil;
}

NSString *LBReadingSourceUrlFromDic(NSDictionary *dic) {
    if (![dic isKindOfClass:[NSDictionary class]]) return nil;
    for (NSString *key in @[@"sourceUrl", @"bookSourceUrl", @"source_url"]) {
        id v = dic[key];
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) return v;
    }
    return nil;
}

NSString *LBReadingTokenFromDic(NSDictionary *dic) {
    if (![dic isKindOfClass:[NSDictionary class]]) return nil;
    for (NSString *key in @[@"legadoBridgeToken", @"bridgeToken", @"token"]) {
        id v = dic[key];
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) return v;
    }
    return nil;
}

void LBReadingRememberPair(NSString *sourceUrl, NSString *bookUrl, NSString *token) {
    if (sourceUrl.length == 0 || bookUrl.length == 0) return;
    NSString *tok = token.length > 0 ? token : [NSString stringWithFormat:@"pair:%@|%@", sourceUrl, bookUrl];
    NSDictionary *pair = @{
        @"sourceUrl": sourceUrl,
        @"bookUrl": bookUrl,
        @"token": tok
    };
    @synchronized (LBReadingTokenMap()) {
        LBReadingTokenMap()[tok] = pair;
        if ([LBReadingAmbiguousBookUrls() containsObject:bookUrl]) {
            // 已歧义：不再写入 bookUrl→token
        } else if (LBReadingBookUrlToToken()[bookUrl] &&
                   ![LBReadingBookUrlToToken()[bookUrl] isEqualToString:tok]) {
            [LBReadingBookUrlToToken() removeObjectForKey:bookUrl];
            [LBReadingAmbiguousBookUrls() addObject:bookUrl];
        } else {
            LBReadingBookUrlToToken()[bookUrl] = tok;
        }
    }
}

void LBReadingRememberBook(NSDictionary *dicBook) {
    if (!LBReadingDicLooksLegado(dicBook)) return;
    NSString *bookUrl = LBReadingBookUrlFromDic(dicBook);
    NSString *sourceUrl = LBReadingSourceUrlFromDic(dicBook);
    if (bookUrl.length == 0 || sourceUrl.length == 0) return;
    NSString *token = LBReadingTokenFromDic(dicBook);
    LBReadingRememberPair(sourceUrl, bookUrl, token);
    // 持久化到 BookBindingStore（经 Core），重启不串源
    id core = LBLegadoCoreIfReady();
    if ([core respondsToSelector:@selector(rememberBookBindingWithBookUrl:sourceUrl:sourceName:name:author:coverUrl:bridgeToken:)]) {
        NSString *sourceName = nil;
        id sn = dicBook[@"sourceName"];
        if (![sn isKindOfClass:[NSString class]]) sn = dicBook[@"bookSourceName"];
        if ([sn isKindOfClass:[NSString class]]) sourceName = sn;
        NSString *name = nil;
        id nm = dicBook[@"name"];
        if (![nm isKindOfClass:[NSString class]]) nm = dicBook[@"bookName"];
        if ([nm isKindOfClass:[NSString class]]) name = nm;
        NSString *author = [dicBook[@"author"] isKindOfClass:[NSString class]] ? dicBook[@"author"] : nil;
        NSString *cover = [dicBook[@"coverUrl"] isKindOfClass:[NSString class]] ? dicBook[@"coverUrl"] : nil;
        ((NSString * (*)(id, SEL, NSString *, NSString *, NSString *, NSString *, NSString *, NSString *, NSString *))objc_msgSend)(
            core,
            @selector(rememberBookBindingWithBookUrl:sourceUrl:sourceName:name:author:coverUrl:bridgeToken:),
            bookUrl, sourceUrl, sourceName, name, author, cover, token
        );
    }
}

NSString *LBReadingSourceUrlForToken(NSString *token) {
    if (token.length == 0) return nil;
    @synchronized (LBReadingTokenMap()) {
        NSDictionary *pair = LBReadingTokenMap()[token];
        NSString *src = pair[@"sourceUrl"];
        if (src.length > 0) return src;
    }
    id core = LBLegadoCoreIfReady();
    if ([core respondsToSelector:@selector(sourceUrlForBridgeToken:)]) {
        return ((NSString * (*)(id, SEL, NSString *))objc_msgSend)(
            core, @selector(sourceUrlForBridgeToken:), token
        );
    }
    return nil;
}

NSDictionary *LBReadingPairForToken(NSString *token) {
    if (token.length == 0) return nil;
    @synchronized (LBReadingTokenMap()) {
        return [LBReadingTokenMap()[token] copy];
    }
}

NSString *LBReadingSourceUrlForBookUrl(NSString *bookUrl) {
    if (bookUrl.length == 0) return nil;
    @synchronized (LBReadingTokenMap()) {
        if ([LBReadingAmbiguousBookUrls() containsObject:bookUrl]) {
            return nil; // 歧义 fail-closed
        }
        NSString *tok = LBReadingBookUrlToToken()[bookUrl];
        if (tok.length > 0) {
            NSDictionary *pair = LBReadingTokenMap()[tok];
            NSString *mem = pair[@"sourceUrl"];
            if (mem.length > 0) return mem;
        }
    }
    // 回退持久绑定：仅唯一 legacy
    id core = LBLegadoCoreIfReady();
    if ([core respondsToSelector:@selector(sourceUrlForBookUrl:)]) {
        return ((NSString * (*)(id, SEL, NSString *))objc_msgSend)(
            core, @selector(sourceUrlForBookUrl:), bookUrl
        );
    }
    return nil;
}

NSDictionary *LBReadingDicFromObject(id object) {
    if (!object) return nil;
    // 拒绝 BOOL YES(0x1) 等小整数被当成对象（与 LBLoadCatalog_IMP 同源防护）
    if ((uintptr_t)object < 0x10000) return nil;
    @try {
        if ([object isKindOfClass:[NSDictionary class]]) return object;
        for (NSString *key in @[@"dicBook", @"book", @"dicGoAfterLoadCatalog", @"dicContents"]) {
            id v = nil;
            @try { v = [object valueForKey:key]; } @catch (__unused NSException *e) { v = nil; }
            if ([v isKindOfClass:[NSDictionary class]]) return v;
        }
    } @catch (__unused NSException *e) {
        return nil;
    }
    return nil;
}
