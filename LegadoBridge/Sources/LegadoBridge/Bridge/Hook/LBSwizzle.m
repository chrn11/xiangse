#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "LegadoBridge.h"

@class LegadoBridgeCore;

void LBInstallImportHooks(void);
void LBInstallSearchHooks(void);

void LBInstallHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        LBInstallImportHooks();
        LBInstallSearchHooks();
        NSLog(@"[LegadoBridge] hooks installed, version=%@", LBBridgeVersion());
    });
}

static void LBSwizzleClassMethod(Class cls, SEL original, SEL swizzled) {
    Method origMethod = class_getClassMethod(cls, original);
    Method newMethod = class_getClassMethod(cls, swizzled);
    if (origMethod && newMethod) {
        method_exchangeImplementations(origMethod, newMethod);
    }
}

static void LBSwizzleInstanceMethod(Class cls, SEL original, SEL swizzled) {
    Method origMethod = class_getInstanceMethod(cls, original);
    Method newMethod = class_getInstanceMethod(cls, swizzled);
    if (origMethod && newMethod) {
        method_exchangeImplementations(origMethod, newMethod);
    }
}

#pragma mark - Import Hook

@interface LBJSONSerializationHook : NSObject
@end

@implementation LBJSONSerializationHook

+ (id)lb_JSONObjectWithData:(NSData *)data
                    options:(NSJSONReadingOptions)opt
                      error:(NSError **)error {
    id result = [self lb_JSONObjectWithData:data options:opt error:error];
    if (data.length > 0) {
        @try {
            Class coreClass = NSClassFromString(@"LegadoBridge.LegadoBridgeCore");
            if (coreClass) {
                id core = [coreClass performSelector:@selector(shared)];
                if ([core respondsToSelector:@selector(isLegadoJSONData:)]) {
                    BOOL isLegado = ((BOOL (*)(id, SEL, NSData *))objc_msgSend)(core, @selector(isLegadoJSONData:), data);
                    if (isLegado) {
                        NSError *importError = nil;
                        ((NSInteger (*)(id, SEL, NSData *, NSError **))objc_msgSend)(
                            core, @selector(importLegadoJSONData:error:), data, &importError
                        );
                        if (importError) {
                            NSLog(@"[LegadoBridge] import error: %@", importError);
                        } else {
                            NSLog(@"[LegadoBridge] Legado JSON imported");
                        }
                    }
                }
            }
        } @catch (NSException *e) {
            NSLog(@"[LegadoBridge] import hook exception: %@", e);
        }
    }
    return result;
}

@end

void LBInstallImportHooks(void) {
    Class jsonClass = objc_getClass("NSJSONSerialization");
    if (!jsonClass) return;

    SEL original = @selector(JSONObjectWithData:options:error:);
    SEL swizzled = @selector(lb_JSONObjectWithData:options:error:);

    Method origMethod = class_getClassMethod(jsonClass, original);
    Method newMethod = class_getClassMethod([LBJSONSerializationHook class], swizzled);
    if (origMethod && newMethod) {
        method_exchangeImplementations(origMethod, newMethod);
    }

    // 拦截 openURL / 文档导入：检测 .json 扩展名走 Legado 路径
    Class appDelegateMeta = objc_getMetaClass("UIApplication.class");
    (void)appDelegateMeta;
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
    LBInstallHooks();
}
