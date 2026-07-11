#import "LBInternal.h"
#import "LegadoBridge.h"
#include <string.h>

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
    id core = LBLegadoCoreIfReady();
    if (!core || ![core respondsToSelector:@selector(allLegadoSourceNames)]) return @[];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    NSArray *names = [core performSelector:@selector(allLegadoSourceNames)];
#pragma clang diagnostic pop
    return names ?: @[];
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
    NSArray *legadoNames = LBLegadoGetSourceNames();
    if (legadoNames.count == 0) return orig ?: @[];
    NSMutableOrderedSet *merged = [NSMutableOrderedSet orderedSetWithArray:orig ?: @[]];
    for (NSString *name in legadoNames) {
        if (name.length > 0) [merged addObject:name];
    }
    return merged.array;
}

UIWindow *LBLegadoKeyWindow(void) {
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

void LBLegadoShowResult(NSString *msg) {
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

void LBLegadoPresentManagerVC(NSString *focusSourceUrl) {
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
        [(id)managerVC setFocusSourceUrl:focusSourceUrl];
    }
    UINavigationController *nav = rootVC.navigationController;
    if (!nav && [rootVC isKindOfClass:[UINavigationController class]]) {
        nav = (UINavigationController *)rootVC;
    }
    if (!nav && [rootVC isKindOfClass:[UITabBarController class]]) {
        UIViewController *selected = [(UITabBarController *)rootVC selectedViewController];
        if ([selected isKindOfClass:[UINavigationController class]]) {
            nav = (UINavigationController *)selected;
        }
    }
    if (nav) {
        [nav pushViewController:managerVC animated:YES];
    } else {
        UINavigationController *wrapNav = [[UINavigationController alloc] initWithRootViewController:managerVC];
        wrapNav.modalPresentationStyle = UIModalPresentationFullScreen;
        [rootVC presentViewController:wrapNav animated:YES completion:nil];
    }
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

#pragma mark - 阅读会话（进程内，非持久化）

static NSMutableDictionary<NSString *, NSString *> *LBReadingMap(void) {
    static NSMutableDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ map = [NSMutableDictionary dictionary]; });
    return map;
}

BOOL LBReadingDicLooksLegado(NSDictionary *dic) {
    if (![dic isKindOfClass:[NSDictionary class]]) return NO;
    id marker = dic[@"legadoBridge"];
    if ([marker isEqual:@"1"] || [marker isEqual:@1] || [marker isEqual:@YES]) return YES;
    if ([dic[@"fromLegadoBridge"] boolValue]) return YES;
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

void LBReadingRememberBook(NSDictionary *dicBook) {
    if (!LBReadingDicLooksLegado(dicBook)) return;
    NSString *bookUrl = LBReadingBookUrlFromDic(dicBook);
    NSString *sourceUrl = LBReadingSourceUrlFromDic(dicBook);
    if (bookUrl.length == 0 || sourceUrl.length == 0) return;
    @synchronized (LBReadingMap()) {
        LBReadingMap()[bookUrl] = sourceUrl;
    }
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
        NSString *token = [dicBook[@"legadoBridgeToken"] isKindOfClass:[NSString class]] ? dicBook[@"legadoBridgeToken"] : nil;
        ((NSString * (*)(id, SEL, NSString *, NSString *, NSString *, NSString *, NSString *, NSString *, NSString *))objc_msgSend)(
            core,
            @selector(rememberBookBindingWithBookUrl:sourceUrl:sourceName:name:author:coverUrl:bridgeToken:),
            bookUrl, sourceUrl, sourceName, name, author, cover, token
        );
    }
}

NSString *LBReadingSourceUrlForBookUrl(NSString *bookUrl) {
    if (bookUrl.length == 0) return nil;
    @synchronized (LBReadingMap()) {
        NSString *mem = LBReadingMap()[bookUrl];
        if (mem.length > 0) return mem;
    }
    // 回退持久绑定
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
    if ([object isKindOfClass:[NSDictionary class]]) return object;
    for (NSString *key in @[@"dicBook", @"book", @"dicGoAfterLoadCatalog", @"dicContents"]) {
        id v = nil;
        @try { v = [object valueForKey:key]; } @catch (__unused NSException *e) { v = nil; }
        if ([v isKindOfClass:[NSDictionary class]]) return v;
    }
    return nil;
}
