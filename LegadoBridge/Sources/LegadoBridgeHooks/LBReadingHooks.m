#import "LBInternal.h"
#import "LBLoadCurCpBridge.h"
#import "LegadoBridge.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdint.h>
#include <dlfcn.h>

static void LBInstallCatalogOrderAndSearchAssist(void);

/// 阅读链路（生产路径收窄）：
/// 1) BookDetailController setDicBook: — 记忆 bookUrl↔sourceUrl，并请求目录
/// 2) loadCatalog:ignoringCache: — Legado 书走 handleCatalogRequest
/// 3) loadCurCp / gotoCp:... — Legado 书走 handleContentRequest
/// 4) BookShelfManager addBook:... — 加书架时再次落盘绑定（进度/缓存仍走香色原生）
/// BookBindingStore 持久映射经 Core.rememberBookBinding / sourceUrlForBookUrl。

#pragma mark - Reading helpers

static void LBReadingDiagLog(NSString *msg) {
    if (!LBDiagProbesEnabled()) return;
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_reading_diag.txt"];
    NSString *line = [NSString stringWithFormat:@"%@ | %@\n", [NSDate date], msg ?: @""];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return;
    }
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

static void LBReadingCatalogLog(NSString *msg) {
    // 目录链路始终落盘（不依赖 diag），便于真机验收对照
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_catalog_hook.txt"];
    NSString *line = [NSString stringWithFormat:@"%@ | %@\n", [NSDate date], msg ?: @""];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return;
    }
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

static void LBReadingRequestCatalog(NSString *bookUrl, NSString *sourceUrl) {
    if (bookUrl.length == 0) return;
    id core = LBLegadoCoreIfReady();
    if (![core respondsToSelector:@selector(handleCatalogRequestWithBookUrl:sourceUrl:)]) return;
    ((void (*)(id, SEL, NSString *, NSString *))objc_msgSend)(
        core, @selector(handleCatalogRequestWithBookUrl:sourceUrl:), bookUrl, sourceUrl
    );
    LBReadingDiagLog([NSString stringWithFormat:@"catalog book=%@ source=%@", bookUrl, sourceUrl ?: @""]);
    LBReadingCatalogLog([NSString stringWithFormat:@"request book=%@ source=%@", bookUrl, sourceUrl ?: @""]);
}

static void LBReadingRequestContent(NSString *chapterUrl, NSString *bookUrl, NSString *sourceUrl) {
    if (chapterUrl.length == 0 || bookUrl.length == 0) return;
    id core = LBLegadoCoreIfReady();
    if (![core respondsToSelector:@selector(handleContentRequestWithChapterUrl:bookUrl:sourceUrl:)]) return;
    ((void (*)(id, SEL, NSString *, NSString *, NSString *))objc_msgSend)(
        core, @selector(handleContentRequestWithChapterUrl:bookUrl:sourceUrl:),
        chapterUrl, bookUrl, sourceUrl
    );
    LBReadingDiagLog([NSString stringWithFormat:@"content ch=%@ book=%@", chapterUrl, bookUrl]);
}

static NSString *LBReadingChapterUrlFromObject(id object) {
    if (!object) return nil;
    for (NSString *key in @[@"chapterUrl", @"url", @"curChapterUrl", @"cpUrl"]) {
        id v = nil;
        @try { v = [object valueForKey:key]; } @catch (__unused NSException *e) { v = nil; }
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) return v;
    }
    NSDictionary *dic = LBReadingDicFromObject(object);
    if (dic) {
        for (NSString *key in @[@"chapterUrl", @"url"]) {
            id v = dic[key];
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) return v;
        }
    }
    return nil;
}

static BOOL LBReadingObjectIsLegado(id object, NSString **outBookUrl, NSString **outSourceUrl) {
    NSDictionary *dic = LBReadingDicFromObject(object);
    if (LBReadingDicLooksLegado(dic)) {
        NSString *bookUrl = LBReadingBookUrlFromDic(dic);
        NSString *sourceUrl = LBReadingSourceUrlFromDic(dic) ?: LBReadingSourceUrlForBookUrl(bookUrl);
        if (outBookUrl) *outBookUrl = bookUrl;
        if (outSourceUrl) *outSourceUrl = sourceUrl;
        return bookUrl.length > 0;
    }
    // 尝试从已知映射反查
    NSString *bookUrl = LBReadingBookUrlFromDic(dic);
    if (bookUrl.length == 0) {
        @try {
            id v = [object valueForKey:@"bookUrl"];
            if ([v isKindOfClass:[NSString class]]) bookUrl = v;
        } @catch (__unused NSException *e) {}
    }
    NSString *sourceUrl = LBReadingSourceUrlForBookUrl(bookUrl);
    if (sourceUrl.length > 0) {
        if (outBookUrl) *outBookUrl = bookUrl;
        if (outSourceUrl) *outSourceUrl = sourceUrl;
        return YES;
    }
    return NO;
}

#pragma mark - Production hooks

static void (*LBOrig_setDicBook)(id, SEL, id) = NULL;
static void LBSetDicBook_IMP(id self, SEL _cmd, id dicBook) {
    NSDictionary *dic = nil;
    if ([dicBook isKindOfClass:[NSDictionary class]]) {
        dic = dicBook;
    } else {
        dic = LBReadingDicFromObject(dicBook) ?: LBReadingDicFromObject(self);
    }
    // 重启后原生可能只留 bookUrl：用持久绑定补 sourceUrl 再记忆
    if (!LBReadingDicLooksLegado(dic)) {
        NSString *bookUrl = LBReadingBookUrlFromDic(dic);
        NSString *persisted = LBReadingSourceUrlForBookUrl(bookUrl);
        if (persisted.length > 0) {
            NSMutableDictionary *enriched = [NSMutableDictionary dictionaryWithDictionary:dic ?: @{}];
            enriched[@"sourceUrl"] = persisted;
            enriched[@"legadoBridge"] = @"1";
            id core = LBLegadoCoreIfReady();
            if ([core respondsToSelector:@selector(detailDictForBookUrl:)]) {
                NSDictionary *detail = ((NSDictionary * (*)(id, SEL, NSString *))objc_msgSend)(
                    core, @selector(detailDictForBookUrl:), bookUrl
                );
                if ([detail isKindOfClass:[NSDictionary class]]) {
                    [enriched addEntriesFromDictionary:detail];
                }
            }
            dic = enriched;
        }
    }
    id passBook = dicBook;
    if (LBReadingDicLooksLegado(dic)) {
        NSMutableDictionary *safe = [NSMutableDictionary dictionaryWithDictionary:dic];
        // 调用原生前消毒：TextReadVC appear 对 nil 字段 @[...] 会 abort
        for (NSString *k in @[
                 @"name", @"bookName", @"author", @"coverUrl", @"intro",
                 @"sourceName", @"bookSourceName", @"querySourceName", @"sourceUrl",
                 @"chapterUrl", @"cpUrl", @"cpTitle", @"title", @"url", @"bookUrl"
             ]) {
            id v = safe[k];
            if (v == nil || v == [NSNull null]) {
                safe[k] = @"";
            } else if (![v isKindOfClass:[NSString class]] &&
                       ![v isKindOfClass:[NSNumber class]]) {
                safe[k] = [[v description] copy] ?: @"";
            }
        }
        NSString *nm = [safe[@"name"] isKindOfClass:[NSString class]] ? safe[@"name"] : @"";
        NSString *bn = [safe[@"bookName"] isKindOfClass:[NSString class]] ? safe[@"bookName"] : @"";
        if (nm.length == 0) {
            safe[@"name"] = bn.length > 0 ? bn : @"书";
        }
        if (bn.length == 0) {
            safe[@"bookName"] = [safe[@"name"] isKindOfClass:[NSString class]] ? safe[@"name"] : @"书";
        }
        dic = safe;
        passBook = safe;
    }
    if (LBOrig_setDicBook) {
        LBOrig_setDicBook(self, _cmd, passBook);
    }
    if (LBReadingDicLooksLegado(dic)) {
        LBReadingRememberBook(dic);
        NSString *bookUrl = LBReadingBookUrlFromDic(dic);
        NSString *sourceUrl = LBReadingSourceUrlFromDic(dic) ?: LBReadingSourceUrlForBookUrl(bookUrl);
        LBReadingRequestCatalog(bookUrl, sourceUrl);
        LBReadingDiagLog([NSString stringWithFormat:@"setDicBook legado book=%@", bookUrl ?: @""]);
    }
}

/// 真机崩溃根因：loadCatalog: 首参偶发为 BOOL YES(0x1)，ARC 对 id 参数 objc_retain → EXC_BAD_ACCESS。
/// 用 void* 接参避免入口 retain；仅当指针像对象时才当 Legado 字典探测。
static BOOL LBPointerLooksLikeObject(const void *p) {
    if (!p) return NO;
    uintptr_t v = (uintptr_t)p;
    if (v < 0x10000) return NO;
    return YES;
}

static void (*LBOrig_loadCatalog)(id, SEL, void *, BOOL) = NULL;
static void LBLoadCatalog_IMP(id self, SEL _cmd, void *argRaw, BOOL ignoringCache) {
    id arg = LBPointerLooksLikeObject(argRaw) ? (__bridge id)argRaw : nil;
    @try {
        NSString *bookUrl = nil;
        NSString *sourceUrl = nil;
        BOOL isLegado = NO;
        if (self) {
            isLegado = LBReadingObjectIsLegado(self, &bookUrl, &sourceUrl);
        }
        if (!isLegado && arg) {
            isLegado = LBReadingObjectIsLegado(arg, &bookUrl, &sourceUrl);
        }
        if (isLegado) {
            LBReadingRequestCatalog(bookUrl, sourceUrl);
            // Legado：禁止回原生 loadCatalog（会牵出 TextReadVC/空站点 SIGABRT）
            LBReadingCatalogLog([NSString stringWithFormat:
                                @"loadCatalog short-circuit book=%@", bookUrl ?: @""]);
            return;
        }
    } @catch (NSException *e) {
        NSLog(@"[LegadoBridge] loadCatalog probe fail-open: %@", e);
    }
    // 非 Legado：void* 转发避免 ARC 对 BOOL(0x1) 二次 retain
    if (LBOrig_loadCatalog) {
        @try {
            LBOrig_loadCatalog(self, _cmd, argRaw, ignoringCache);
        } @catch (NSException *e) {
            NSLog(@"[LegadoBridge] loadCatalog orig fail-open: %@", e);
        }
    }
}

static void (*LBOrig_loadCurCp)(id, SEL) = NULL;
static void LBLoadCurCp_IMP(id self, SEL _cmd);

typedef IMP (*LBForensicsEarlyWrapIMPFn)(NSString *);
typedef IMP (*LBForensicsResolveOrigIMPFn)(Class, SEL);
typedef IMP (*LBForensicsResolveObserverOrigIMPFn)(Class, SEL);
typedef IMP (*LBForensicsHookIMPForSelectorNameFn)(NSString *);

/// AR：IMP 是否落在主二进制（StandarReader.app/StandarReader）--视为 native IMP
static BOOL LBIsMainAppImageIMP(IMP imp) {
    if (!imp) return NO;
    Dl_info info;
    if (!dladdr((void *)imp, &info) || !info.dli_fname) return NO;
    const char *path = info.dli_fname;
    if (strstr(path, "LegadoBridge") != NULL) return NO;
    if (strstr(path, "StandarReader") != NULL) return YES;
    return strstr(path, ".app/") != NULL && strstr(path, ".dylib") == NULL;
}

/// AR：IMP 是否为 _block_invoke 短桩（imp_implementationWithBlock 产生）
static BOOL LBIsBlockInvokeIMP(IMP imp) {
    if (!imp) return NO;
    Dl_info info;
    if (!dladdr((void *)imp, &info) || !info.dli_sname) return NO;
    return strstr(info.dli_sname, "block_invoke") != NULL;
}

static BOOL LBIsKnownLoadCurCpHookIMP(IMP imp) {
    if (!imp) return NO;
    if (imp == (IMP)LBLoadCurCp_IMP) return YES;
    static LBForensicsEarlyWrapIMPFn earlyWrapFn = NULL;
    static dispatch_once_t onceEarly;
    dispatch_once(&onceEarly, ^{
        earlyWrapFn = (LBForensicsEarlyWrapIMPFn)dlsym(RTLD_DEFAULT,
                                                        "LBForensicsEarlyWrapIMPForSelectorName");
    });
    if (earlyWrapFn) {
        IMP early = earlyWrapFn(@"loadCurCp");
        if (early && imp == early) return YES;
    }
    // AR：forensics observer 短桩（LBFHook_v_at 等）也须识别，否则解包提前终止
    static LBForensicsHookIMPForSelectorNameFn hookImpFn = NULL;
    static dispatch_once_t onceHook;
    dispatch_once(&onceHook, ^{
        hookImpFn = (LBForensicsHookIMPForSelectorNameFn)dlsym(RTLD_DEFAULT,
                                                                "LBForensicsHookIMPForSelectorName");
    });
    if (hookImpFn) {
        IMP obs = hookImpFn(@"loadCurCp");
        if (obs && imp == obs) return YES;
        // loadCurCp 在 observer 用 LBFHook_v_at（0 参 hook）
        IMP obs0 = hookImpFn(@"viewDidLoad");
        if (obs0 && imp == obs0) return YES;
    }
    if (LBIsBlockInvokeIMP(imp)) return YES;
    return NO;
}

/// AR：沿 Bridge hook / EarlyWrap / Observer / block 解包到真 native IMP。
/// 终止条件改为「IMP 落在主二进制且非已知钩子」--dladdr 比 LBIsKnown 更可靠，
/// 修复 AQ 发现的 sOrigLoadCurCp 错位（imp=0x10017fcf4 cls=?）。
static IMP LBUnwrapLoadCurCpOrigIMP(Class cls, IMP start) {
    SEL sel = @selector(loadCurCp);
    IMP imp = start;
    static LBForensicsResolveOrigIMPFn resolveOrig = NULL;
    static LBForensicsResolveObserverOrigIMPFn resolveObs = NULL;
    static dispatch_once_t onceResolve;
    dispatch_once(&onceResolve, ^{
        resolveOrig = (LBForensicsResolveOrigIMPFn)dlsym(RTLD_DEFAULT, "LBForensicsResolveOrigIMP");
        resolveObs = (LBForensicsResolveObserverOrigIMPFn)dlsym(RTLD_DEFAULT,
                                                                 "LBForensicsResolveObserverOrigIMP");
    });

    NSMutableSet<NSValue *> *seen = [NSMutableSet set];
    IMP best = NULL;
    for (int hop = 0; hop < 16 && imp; hop++) {
        NSValue *key = [NSValue valueWithPointer:imp];
        if ([seen containsObject:key]) break;
        [seen addObject:key];

        // 主二进制 native IMP -- 终止
        if (LBIsMainAppImageIMP(imp) && !LBIsKnownLoadCurCpHookIMP(imp)) {
            best = imp;
            break;
        }
        // 已知钩子 -- 继续解包
        if (!LBIsKnownLoadCurCpHookIMP(imp)) {
            // 非 main、非已知钩子（如 dyld 共享缓存 CF/UIKit）--保守保留
            best = imp;
            break;
        }

        IMP next = NULL;
        if (resolveOrig) {
            IMP early = resolveOrig(cls, sel);
            if (early && early != imp && ![seen containsObject:[NSValue valueWithPointer:early]]) {
                next = early;
            }
        }
        if ((!next || next == imp) && resolveObs) {
            IMP obs = resolveObs(cls, sel);
            if (obs && obs != imp && ![seen containsObject:[NSValue valueWithPointer:obs]]) {
                next = obs;
            }
        }
        if (!next || next == imp) break;
        imp = next;
    }

    // 最后兜底：若解包未命中主二进制，尝试 resolveOrig/resolveObs 直接给的 IMP
    if (!best || !LBIsMainAppImageIMP(best)) {
        if (resolveOrig) {
            IMP early = resolveOrig(cls, sel);
            if (early && LBIsMainAppImageIMP(early) && !LBIsKnownLoadCurCpHookIMP(early)) {
                best = early;
            }
        }
    }
    if (!best || !LBIsMainAppImageIMP(best)) {
        if (resolveObs) {
            IMP obs = resolveObs(cls, sel);
            if (obs && LBIsMainAppImageIMP(obs) && !LBIsKnownLoadCurCpHookIMP(obs)) {
                best = obs;
            }
        }
    }
    return best ?: imp;
}

static void LBLoadCurCp_IMP(id self, SEL _cmd) {
    NSString *bookUrl = nil;
    NSString *sourceUrl = nil;
    if (LBReadingObjectIsLegado(self, &bookUrl, &sourceUrl)) {
        NSString *chapterUrl = LBReadingChapterUrlFromObject(self);
        if (LBLoadCurCpBridgeHandleHook(self, _cmd, YES, bookUrl, sourceUrl, chapterUrl)) {
            LBReadingDiagLog([NSString stringWithFormat:
                             @"loadCurCp sm=%@ book=%@ ch=%@",
                             LBLoadCurCpBridgeStateName(), bookUrl ?: @"", chapterUrl ?: @""]);
            return;
        }
    }
    if (LBOrig_loadCurCp) {
        LBOrig_loadCurCp(self, _cmd);
    }
}

static Class LBFindClassImplementing(NSArray<NSString *> *candidates, SEL sel) {
    for (NSString *cn in candidates) {
        Class c = NSClassFromString(cn);
        if (!c) continue;
        Class owner = LBClassOwningInstanceMethod(c, sel);
        if (owner) return owner;
    }
    // 穷举代价高，仅诊断模式对关键 sel 做有限扫描
    if (!LBDiagProbesEnabled()) return Nil;
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    Class found = Nil;
    for (unsigned int i = 0; i < count; i++) {
        Class c = classes[i];
        if (!class_respondsToSelector(c, sel)) continue;
        Class owner = LBClassOwningInstanceMethod(c, sel);
        if (!owner) continue;
        NSString *name = NSStringFromClass(owner);
        if ([name containsString:@"Read"] || [name containsString:@"Catalog"] ||
            [name containsString:@"BookDetail"]) {
            found = owner;
            break;
        }
    }
    if (classes) free(classes);
    return found;
}

void LBInstallReadingHooks(void) {
    @try {
        NSMutableArray *installed = [NSMutableArray array];

        // 1) setDicBook: — 生产锚点（详情 + 阅读页；按真正实现类去重，防把 hook 当 orig）
        NSArray *dicBookOwners = @[
            @"BookDetailController", @"BookDetailVCBase",
            @"TextReadVC1", @"TextReadVC2", @"TextReadVC3",
            @"ReadVCBase1", @"ReadVCBase2"
        ];
        SEL setDicSel = @selector(setDicBook:);
        NSString *enc = nil;
        NSString *reason = nil;
        NSMutableSet *dicBookHooked = [NSMutableSet set];
        for (NSString *cn in dicBookOwners) {
            Class detailCls = NSClassFromString(cn);
            if (!detailCls) continue;
            Class owner = LBClassOwningInstanceMethod(detailCls, setDicSel) ?: detailCls;
            NSString *ownerKey = NSStringFromClass(owner);
            if ([dicBookHooked containsObject:ownerKey]) continue;
            if (!LBValidateInstanceMethod(owner, setDicSel, "@16", &enc, &reason)) {
                LBReadingDiagLog([NSString stringWithFormat:@"setDicBook skip %@: %@", ownerKey, reason ?: @""]);
                continue;
            }
            Method m = class_getInstanceMethod(owner, setDicSel);
            if (!m) continue;
            if (!LBOrig_setDicBook) {
                LBOrig_setDicBook = (void (*)(id, SEL, id))method_getImplementation(m);
            }
            method_setImplementation(m, (IMP)LBSetDicBook_IMP);
            [dicBookHooked addObject:ownerKey];
            [installed addObject:[NSString stringWithFormat:@"setDicBook@%@ enc=%@", ownerKey, enc ?: @""]];
        }

        // 2) loadCatalog:ignoringCache:
        NSArray *catalogCandidates = @[
            @"ReadVCBase1", @"ReadVCBase2", @"TextReadVC1", @"TextReadVC2", @"TextReadVC3",
            @"BookDetailController", @"BookDetailVCBase", @"CatalogCon"
        ];
        SEL catalogSel = NSSelectorFromString(@"loadCatalog:ignoringCache:");
        Class catalogOwner = LBFindClassImplementing(catalogCandidates, catalogSel);
        if (catalogOwner &&
            LBValidateInstanceMethod(catalogOwner, catalogSel, NULL, &enc, &reason)) {
            // 生产要求至少像 (id, BOOL)：编码中出现 @ 与 B
            if (enc && [enc containsString:@"@"] && [enc.uppercaseString containsString:@"B"]) {
                Method m = class_getInstanceMethod(catalogOwner, catalogSel);
                IMP prev = method_getImplementation(m);
                LBOrig_loadCatalog = (void (*)(id, SEL, void *, BOOL))prev;
                method_setImplementation(m, (IMP)LBLoadCatalog_IMP);
                [installed addObject:[NSString stringWithFormat:@"loadCatalog@%@ enc=%@",
                                      NSStringFromClass(catalogOwner), enc ?: @""]];
            } else {
                LBReadingDiagLog([NSString stringWithFormat:@"loadCatalog enc mismatch: %@", enc ?: @""]);
            }
        } else if (reason) {
            LBReadingDiagLog([NSString stringWithFormat:@"loadCatalog skip: %@", reason]);
        }

        // 3) loadCurCp — 正文请求侧（ReadPageContainer 为常见真正实现类）
        NSArray *cpCandidates = @[
            @"ReadPageContainer", @"ReadVCBase1", @"ReadVCBase2",
            @"TextReadVC1", @"TextReadVC2", @"TextReadVC3"
        ];
        SEL curSel = NSSelectorFromString(@"loadCurCp");
        Class curOwner = LBFindClassImplementing(cpCandidates, curSel);
        if (curOwner && LBValidateInstanceMethod(curOwner, curSel, "v16", &enc, &reason)) {
            Method m = class_getInstanceMethod(curOwner, curSel);
            IMP raw = method_getImplementation(m);
            IMP native = LBUnwrapLoadCurCpOrigIMP(curOwner, raw);
            if (!native) native = raw;
            LBOrig_loadCurCp = (void (*)(id, SEL))native;
            LBLoadCurCpBridgeRegisterOrig(LBOrig_loadCurCp);
            method_setImplementation(m, (IMP)LBLoadCurCp_IMP);
            // AR 探针：记录解包前后 IMP 的 dladdr fname / 是否主二进制，便于真机核对 orig 是否修正
            NSString *arRawFname = @"?";
            NSString *arNatFname = @"?";
            BOOL arRawMain = NO;
            BOOL arNatMain = NO;
            Dl_info arDi;
            if (dladdr((void *)raw, &arDi) && arDi.dli_fname) {
                arRawFname = [NSString stringWithUTF8String:arDi.dli_fname].lastPathComponent ?: @"?";
                arRawMain = (strstr(arDi.dli_fname, "StandarReader") != NULL &&
                             strstr(arDi.dli_fname, "LegadoBridge") == NULL);
            }
            if (dladdr((void *)native, &arDi) && arDi.dli_fname) {
                arNatFname = [NSString stringWithUTF8String:arDi.dli_fname].lastPathComponent ?: @"?";
                arNatMain = (strstr(arDi.dli_fname, "StandarReader") != NULL &&
                             strstr(arDi.dli_fname, "LegadoBridge") == NULL);
            }
            LBReadingDiagLog([NSString stringWithFormat:
                             @"ar_loadCurCp_resolve owner=%@ raw=%p rawFname=%@ rawMain=%d "
                             @"native=%p natFname=%@ natMain=%d knownHook_raw=%d knownHook_nat=%d",
                             NSStringFromClass(curOwner), raw, arRawFname, arRawMain ? 1 : 0,
                             native, arNatFname, arNatMain ? 1 : 0,
                             LBIsKnownLoadCurCpHookIMP(raw) ? 1 : 0,
                             LBIsKnownLoadCurCpHookIMP(native) ? 1 : 0]);
            [installed addObject:[NSString stringWithFormat:@"loadCurCp@%@", NSStringFromClass(curOwner)]];
        } else if (reason) {
            LBReadingDiagLog([NSString stringWithFormat:@"loadCurCp skip: %@", reason]);
        }

        // 3b) loadCp: — 滚动容器正文入口（ReadScrollContainer；与 loadCurCp 互斥）
        {
            NSArray *scrollCpCandidates = @[@"ReadScrollContainer", @"TextRScrollContainer"];
            SEL loadCpSel = NSSelectorFromString(@"loadCp:");
            Class scrollOwner = LBFindClassImplementing(scrollCpCandidates, loadCpSel);
            NSString *scrollReason = nil;
            NSString *scrollEnc = nil;
            if (scrollOwner &&
                LBValidateInstanceMethod(scrollOwner, loadCpSel, NULL, &scrollEnc, &scrollReason)) {
                Method m = class_getInstanceMethod(scrollOwner, loadCpSel);
                IMP raw = method_getImplementation(m);
                if (raw) {
                    LBLoadCurCpBridgeRegisterLoadCpOrig((id (*)(id, SEL, long long))raw);
                    [installed addObject:[NSString stringWithFormat:@"loadCp:@%@ enc=%@",
                                          NSStringFromClass(scrollOwner), scrollEnc ?: @""]];
                }
            } else if (scrollReason) {
                LBReadingDiagLog([NSString stringWithFormat:@"loadCp: skip: %@", scrollReason]);
            }
        }

        // 4) addBook:groupKey:tempBook: — 加书架时落盘绑定；进度/缓存不 Hook
        Class shelfMgr = NSClassFromString(@"BookShelfManager");
        SEL addSel = NSSelectorFromString(@"addBook:groupKey:tempBook:");
        if (shelfMgr && LBValidateInstanceMethod(shelfMgr, addSel, NULL, &enc, &reason)) {
            Method m = class_getInstanceMethod(shelfMgr, addSel);
            IMP orig = method_getImplementation(m);
            const char *types = method_getTypeEncoding(m) ?: "v40@0:8@16@24@32";
            void (^rememberIfLegado)(id, id) = ^(id book, id tempBook) {
                NSDictionary *dic = LBReadingDicFromObject(tempBook) ?: LBReadingDicFromObject(book);
                NSString *bu = LBReadingBookUrlFromDic(dic);
                if (LBReadingDicLooksLegado(dic) || LBReadingSourceUrlForBookUrl(bu).length > 0) {
                    if (!LBReadingDicLooksLegado(dic) && bu.length > 0) {
                        NSMutableDictionary *enriched = [NSMutableDictionary dictionaryWithDictionary:dic ?: @{}];
                        NSString *su = LBReadingSourceUrlForBookUrl(bu);
                        if (su.length > 0) {
                            enriched[@"sourceUrl"] = su;
                            enriched[@"legadoBridge"] = @"1";
                        }
                        dic = enriched;
                    }
                    LBReadingRememberBook(dic);
                    LBReadingDiagLog([NSString stringWithFormat:@"addBook shelf book=%@", bu ?: @""]);
                }
            };
            IMP hook = NULL;
            if (types[0] == 'B' || types[0] == 'c') {
                hook = imp_implementationWithBlock(^BOOL(id selfObj, id book, id groupKey, id tempBook) {
                    rememberIfLegado(book, tempBook);
                    return ((BOOL (*)(id, SEL, id, id, id))orig)(selfObj, addSel, book, groupKey, tempBook);
                });
            } else {
                hook = imp_implementationWithBlock(^void(id selfObj, id book, id groupKey, id tempBook) {
                    rememberIfLegado(book, tempBook);
                    ((void (*)(id, SEL, id, id, id))orig)(selfObj, addSel, book, groupKey, tempBook);
                });
            }
            method_setImplementation(m, hook);
            [installed addObject:[NSString stringWithFormat:@"addBook enc=%@", enc ?: @""]];
        } else if (reason) {
            LBReadingDiagLog([NSString stringWithFormat:@"addBook skip: %@", reason]);
        }

        // 目录 UI：详情页引擎先返回，CatalogCon 后 push → 对齐搜索的 appear pending 冲刷
        LBInstallCatalogUIAppearFlush();
        [installed addObject:@"catalogUIAppearFlush"];
        // 正文：ReadVC appear 时重投 ResetContent（openReader 后才有监听者）
        LBInstallReaderContentAppearFlush();
        [installed addObject:@"readerContentAppearFlush"];
        // 原生护栏：Legado openReader/beginRead 消毒模型后走原生；点章失败再 Bridge
        LBInstallLegadoReaderKillSwitch();
        [installed addObject:@"readerNativeGuard"];
        LBInstallCatalogOrderAndSearchAssist();
        [installed addObject:@"catalogOrderSearchAssist"];

        if (installed.count == 0) {
            LBCapabilityMarkSkipped(LBHookGroupReading, @"no production reading anchors");
        } else {
            LBCapabilityMarkEnabled(LBHookGroupReading, [installed componentsJoinedByString:@";"]);
        }
    } @catch (NSException *e) {
        LBCapabilityMarkFailed(LBHookGroupReading, e.reason ?: @"exception");
        NSLog(@"[LegadoBridge] reading hooks exception: %@", e);
    }
}

#pragma mark - E-02/E-03 目录倒序与搜索辅助
// CatalogCon 真机字段是 arrSource（setArrSource:），不是 arrCatalog（后者在阅读器侧）

static NSString *LBCatalogItemTitle(id item) {
    if ([item isKindOfClass:[NSString class]]) return (NSString *)item;
    if (![item isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *d = (NSDictionary *)item;
    NSString *t = d[@"cpTitle"] ?: d[@"title"] ?: d[@"chapterName"] ?: d[@"name"];
    id val = d[@"value"];
    if ([val isKindOfClass:[NSDictionary class]]) {
        NSDictionary *inner = (NSDictionary *)val;
        NSString *it = inner[@"cpTitle"] ?: inner[@"title"] ?: inner[@"chapterName"] ?: inner[@"name"];
        if ([it isKindOfClass:[NSString class]] && it.length > 0) {
            if (![t isKindOfClass:[NSString class]] || t.length == 0 || [t containsString:@"(null)"]) {
                t = it;
            }
        }
    }
    return [t isKindOfClass:[NSString class]] ? t : nil;
}

/// 与 cellForRow / numberOfRows 同源：有标题的数组优先，再 pending
static NSArray *LBCatalogReadChapters(id catalogVC) {
    if (!catalogVC) return LBCopyPendingCatalogChapters();
    for (NSString *key in @[@"arrSource", @"arrCatalog", @"arrCpInfo", @"arrBaseData"]) {
        @try {
            id arr = [catalogVC valueForKey:key];
            if (![arr isKindOfClass:[NSArray class]] || [(NSArray *)arr count] == 0) continue;
            NSString *t0 = LBCatalogItemTitle([(NSArray *)arr firstObject]);
            if ([t0 isKindOfClass:[NSString class]] && t0.length > 0) {
                return (NSArray *)arr;
            }
        } @catch (__unused NSException *e) {}
    }
    NSArray *pending = LBCopyPendingCatalogChapters();
    if (pending.count > 0) return pending;
    return nil;
}

static void LBCatalogWriteChapters(id catalogVC, NSArray *chapters) {
    if (!catalogVC || !chapters) return;
    BOOL wrote = NO;
    @try {
        // setArrSource: 会再包一层 {index,title,value}；优先原地改现有可变数组
        if ([catalogVC respondsToSelector:@selector(arrSource)]) {
            id cur = ((id (*)(id, SEL))objc_msgSend)(catalogVC, @selector(arrSource));
            if ([cur isKindOfClass:[NSMutableArray class]]) {
                [(NSMutableArray *)cur setArray:chapters];
                wrote = YES;
            }
        }
    } @catch (__unused NSException *e) {}
    if (!wrote) {
        @try {
            if ([catalogVC respondsToSelector:@selector(setArrSource:)]) {
                ((void (*)(id, SEL, id))objc_msgSend)(catalogVC, @selector(setArrSource:), chapters);
                wrote = YES;
            }
        } @catch (__unused NSException *e) {}
    }
    // 同步其它展示字段 + pending，避免 cell/numberOfRows 仍画引擎原始顺序
    for (NSString *key in @[@"arrCatalog", @"arrBaseData", @"arrCpInfo"]) {
        @try { [catalogVC setValue:chapters forKey:key]; } @catch (__unused NSException *e) {}
    }
    LBSyncPendingCatalogChapters(chapters);
    @try {
        if ([catalogVC respondsToSelector:@selector(reloadData)]) {
            ((void (*)(id, SEL))objc_msgSend)(catalogVC, @selector(reloadData));
        }
    } @catch (__unused NSException *e) {}
    @try {
        UITableView *tv = nil;
        if ([catalogVC respondsToSelector:@selector(tableView)]) {
            tv = ((UITableView *(*)(id, SEL))objc_msgSend)(catalogVC, @selector(tableView));
        }
        [tv reloadData];
    } @catch (__unused NSException *e) {}
    // 扫可见 table 再 reload 一次（dataSource 可能不是 VC）
    @try {
        UIView *root = [catalogVC isKindOfClass:[UIViewController class]]
            ? ((UIViewController *)catalogVC).view : nil;
        if (root) {
            NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
            while (stack.count > 0) {
                UIView *v = stack.lastObject;
                [stack removeLastObject];
                if ([v isKindOfClass:[UITableView class]]) {
                    [(UITableView *)v reloadData];
                }
                for (UIView *sub in v.subviews) [stack addObject:sub];
            }
        }
    } @catch (__unused NSException *e) {}
}

static void LBCatalogWriteE02Marker(NSString *msg) {
    if (msg.length == 0) return;
    [msg writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_e02_reverse.txt"]
          atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

static void LBCatalogReverseArrayOnVC(id catalogVC) {
    [@"E02 tap" writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_e02_tap.txt"]
                 atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    if (!catalogVC) {
        LBCatalogWriteE02Marker(@"E02 reverse fail=noVC");
        return;
    }
    @try {
        NSArray *arr = LBCatalogReadChapters(catalogVC);
        if (![arr isKindOfClass:[NSArray class]] || arr.count < 2) {
            LBCatalogWriteE02Marker([NSString stringWithFormat:@"E02 reverse fail=n=%lu",
                                     (unsigned long)([arr isKindOfClass:[NSArray class]] ? arr.count : 0)]);
            return;
        }
        NSArray *rev = [[arr reverseObjectEnumerator] allObjects];
        LBCatalogWriteChapters(catalogVC, rev);
        LBCatalogWriteE02Marker([NSString stringWithFormat:@"E02 reverse n=%lu first=%@ last=%@",
                                 (unsigned long)rev.count,
                                 LBCatalogItemTitle(rev.firstObject) ?: @"",
                                 LBCatalogItemTitle(rev.lastObject) ?: @""]);
    } @catch (NSException *e) {
        LBCatalogWriteE02Marker([NSString stringWithFormat:@"E02 reverse fail=ex %@", e.reason ?: @""]);
    }
}

static void LBCatalogFilterByKeyword(id catalogVC, NSString *keyword) {
    if (!catalogVC) return;
    NSString *key = [keyword stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    @try {
        static char kOrigKey;
        NSArray *orig = objc_getAssociatedObject(catalogVC, &kOrigKey);
        if (!orig) {
            NSArray *arr = LBCatalogReadChapters(catalogVC);
            if (![arr isKindOfClass:[NSArray class]] || arr.count == 0) {
                [@"E03 filter fail=empty"
                 writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_e03_filter.txt"]
                  atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                return;
            }
            orig = [arr copy];
            objc_setAssociatedObject(catalogVC, &kOrigKey, orig, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        NSArray *use = orig;
        if (key.length > 0) {
            NSMutableArray *filtered = [NSMutableArray array];
            for (id item in orig) {
                NSString *title = LBCatalogItemTitle(item);
                if ([title isKindOfClass:[NSString class]] && [title containsString:key]) {
                    [filtered addObject:item];
                }
            }
            use = filtered;
        }
        LBCatalogWriteChapters(catalogVC, use);
        NSString *msg = [NSString stringWithFormat:@"E03 filter key=%@ n=%lu", key, (unsigned long)use.count];
        [msg writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_e03_filter.txt"]
              atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    } @catch (NSException *e) {
        NSString *msg = [NSString stringWithFormat:@"E03 filter fail=ex %@", e.reason ?: @""];
        [msg writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_e03_filter.txt"]
              atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }
}

@interface LBCatalogSearchAssist : NSObject <UISearchBarDelegate>
@property (nonatomic, weak) id catalogVC;
@property (nonatomic, weak) id originalDelegate;
@end
@implementation LBCatalogSearchAssist
- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    LBCatalogFilterByKeyword(self.catalogVC, searchText ?: @"");
    id del = self.originalDelegate;
    if (del && del != self && [del respondsToSelector:@selector(searchBar:textDidChange:)]) {
        [del searchBar:searchBar textDidChange:searchText];
    }
}
- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
    LBCatalogFilterByKeyword(self.catalogVC, searchBar.text ?: @"");
    id del = self.originalDelegate;
    if (del && del != self && [del respondsToSelector:@selector(searchBarSearchButtonClicked:)]) {
        [del searchBarSearchButtonClicked:searchBar];
    }
}
- (BOOL)respondsToSelector:(SEL)aSelector {
    if ([super respondsToSelector:aSelector]) return YES;
    id del = self.originalDelegate;
    return del && del != self && [del respondsToSelector:aSelector];
}
- (id)forwardingTargetForSelector:(SEL)aSelector {
    id del = self.originalDelegate;
    if (del && del != self && [del respondsToSelector:aSelector]) return del;
    return [super forwardingTargetForSelector:aSelector];
}
@end

static void LBEnsureCatalogReverseSelector(UIViewController *vc) {
    if (!vc) return;
    Class cls = [vc class];
    NSString *cn = NSStringFromClass(cls) ?: @"?";
    static NSMutableSet *sEnsured;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ sEnsured = [NSMutableSet set]; });
    SEL sel = @selector(lb_catalogReverseTapped);
    if (![sEnsured containsObject:cn]) {
        IMP imp = imp_implementationWithBlock(^void(id selfObj) {
            LBCatalogReverseArrayOnVC(selfObj);
        });
        if (!class_addMethod(cls, sel, imp, "v@:")) {
            Method m = class_getInstanceMethod(cls, sel);
            if (m) method_setImplementation(m, imp);
        }
        [sEnsured addObject:cn];
    }
}

static BOOL LBBarItemLooksReverse(UIBarButtonItem *bi) {
    if (!bi) return NO;
    NSString *t = bi.title ?: @"";
    if ([t containsString:@"倒序"] || [t containsString:@"正序"]) return YES;
    UIView *cv = bi.customView;
    if ([cv isKindOfClass:[UIButton class]]) {
        UIButton *b = (UIButton *)cv;
        NSString *bt = b.currentTitle ?: [b titleForState:UIControlStateNormal] ?: @"";
        NSString *acc = b.accessibilityLabel ?: @"";
        if ([bt containsString:@"倒序"] || [bt containsString:@"正序"] ||
            [acc containsString:@"倒序"] || [acc containsString:@"正序"]) {
            return YES;
        }
    }
    NSString *acc = bi.accessibilityLabel ?: @"";
    return [acc containsString:@"倒序"] || [acc containsString:@"正序"];
}

static void LBWireSearchBarOnCatalog(UIViewController *vc, UISearchBar *sb) {
    if (!vc || !sb) return;
    static char kAssistKey;
    LBCatalogSearchAssist *assist = objc_getAssociatedObject(vc, &kAssistKey);
    if (!assist) {
        assist = [LBCatalogSearchAssist new];
        assist.catalogVC = vc;
        objc_setAssociatedObject(vc, &kAssistKey, assist, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (sb.delegate != assist) {
        assist.originalDelegate = sb.delegate;
        sb.delegate = assist;
    }
    sb.hidden = NO;
    sb.userInteractionEnabled = YES;
}

static void LBWireCatalogAssistOnVC(UIViewController *vc) {
    if (!vc.isViewLoaded || !vc.view) return;
    LBEnsureCatalogReverseSelector(vc);
    SEL sel = @selector(lb_catalogReverseTapped);
    __block NSInteger rewiredBtns = 0;
    __block NSInteger rewiredBars = 0;

    void (^rewireButton)(UIButton *) = ^(UIButton *b) {
        NSString *t = b.currentTitle ?: [b titleForState:UIControlStateNormal] ?: @"";
        NSString *acc = b.accessibilityLabel ?: @"";
        if (!([t containsString:@"倒序"] || [t containsString:@"正序"] ||
              [acc containsString:@"倒序"] || [acc containsString:@"正序"])) {
            return;
        }
        b.hidden = NO;
        b.enabled = YES;
        b.userInteractionEnabled = YES;
        [b removeTarget:nil action:NULL forControlEvents:UIControlEventTouchUpInside];
        [b addTarget:vc action:sel forControlEvents:UIControlEventTouchUpInside];
        rewiredBtns++;
    };

    void (^walk)(UIView *) = NULL;
    __block __weak void (^weakWalk)(UIView *) = nil;
    weakWalk = walk = ^(UIView *v) {
        if ([v isKindOfClass:[UIButton class]]) rewireButton((UIButton *)v);
        if ([v isKindOfClass:[UISearchBar class]]) {
            LBWireSearchBarOnCatalog(vc, (UISearchBar *)v);
            rewiredBars++;
        }
        for (UIView *sub in v.subviews) weakWalk(sub);
    };
    walk(vc.view);
    // 导航栏不在 vc.view 内，必须单独扫
    UINavigationBar *navBar = vc.navigationController.navigationBar;
    if (navBar) walk(navBar);

    // UISearchController.searchBar 常挂在 navigationItem 上
    @try {
        UISearchController *sc = vc.navigationItem.searchController;
        if (sc.searchBar) {
            LBWireSearchBarOnCatalog(vc, sc.searchBar);
            rewiredBars++;
        }
    } @catch (__unused NSException *e) {}

    // 强制替换「倒序」UIBarButtonItem（避免 primaryAction / 空 action 重绑无效）
    NSMutableArray *oldRights = [NSMutableArray array];
    if (vc.navigationItem.rightBarButtonItems.count > 0) {
        [oldRights addObjectsFromArray:vc.navigationItem.rightBarButtonItems];
    } else if (vc.navigationItem.rightBarButtonItem) {
        [oldRights addObject:vc.navigationItem.rightBarButtonItem];
    }
    NSMutableArray *newRights = [NSMutableArray array];
    BOOL replacedRev = NO;
    for (UIBarButtonItem *bi in oldRights) {
        if (LBBarItemLooksReverse(bi)) {
            if (bi.customView && [bi.customView isKindOfClass:[UIButton class]]) {
                rewireButton((UIButton *)bi.customView);
                [newRights addObject:bi];
            } else {
                NSString *title = bi.title.length > 0 ? bi.title : @"倒序";
                UIBarButtonItem *neu = [[UIBarButtonItem alloc] initWithTitle:title
                                                                       style:UIBarButtonItemStylePlain
                                                                      target:vc
                                                                      action:sel];
                [newRights addObject:neu];
            }
            replacedRev = YES;
        } else {
            [newRights addObject:bi];
        }
    }
    if (!replacedRev) {
        static char kRevItemKey;
        UIBarButtonItem *ours = objc_getAssociatedObject(vc, &kRevItemKey);
        if (![ours isKindOfClass:[UIBarButtonItem class]] || ![newRights containsObject:ours]) {
            ours = [[UIBarButtonItem alloc] initWithTitle:@"倒序"
                                                    style:UIBarButtonItemStylePlain
                                                   target:vc
                                                   action:sel];
            objc_setAssociatedObject(vc, &kRevItemKey, ours, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else {
            ours.target = vc;
            ours.action = sel;
        }
        // [0] 最靠右；追加 → 显示在「到底部」左侧
        [newRights addObject:ours];
        replacedRev = YES;
    }
    vc.navigationItem.rightBarButtonItems = newRights;

    NSString *wire = [NSString stringWithFormat:
                      @"E02 wire vc=%@ btns=%ld bars=%ld replaced=%d rights=%lu",
                      NSStringFromClass([vc class]),
                      (long)rewiredBtns, (long)rewiredBars, replacedRev ? 1 : 0,
                      (unsigned long)newRights.count];
    [wire writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_e02_wire.txt"]
           atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

static void LBScheduleCatalogAssistRewire(UIViewController *vc) {
    if (!vc) return;
    LBWireCatalogAssistOnVC(vc);
    __weak UIViewController *weakVC = vc;
    for (NSNumber *delayNum in @[@0.15, @0.5, @1.2]) {
        NSTimeInterval delay = delayNum.doubleValue;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIViewController *strong = weakVC;
            if (!strong || !strong.isViewLoaded || !strong.view.window) return;
            LBWireCatalogAssistOnVC(strong);
        });
    }
}

static void LBInstallCatalogOrderAndSearchAssist(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = NSClassFromString(@"CatalogCon");
        if (!cls) return;
        Class owner = LBClassOwningInstanceMethod(cls, @selector(viewDidAppear:));
        if (!owner) owner = cls;
        Method m = class_getInstanceMethod(owner, @selector(viewDidAppear:));
        if (!m) return;
        IMP prev = method_getImplementation(m);
        IMP hook = imp_implementationWithBlock(^void(id selfObj, BOOL animated) {
            ((void (*)(id, SEL, BOOL))prev)(selfObj, @selector(viewDidAppear:), animated);
            if ([selfObj isKindOfClass:[UIViewController class]]) {
                LBScheduleCatalogAssistRewire((UIViewController *)selfObj);
            }
        });
        method_setImplementation(m, hook);

        // 原生目录用 UISearchController；在原实现后再按关键字过滤
        Method mSearch = class_getInstanceMethod(cls, @selector(updateSearchResultsForSearchController:));
        if (mSearch) {
            IMP prevSearch = method_getImplementation(mSearch);
            IMP hookSearch = imp_implementationWithBlock(^void(id selfObj, id searchController) {
                ((void (*)(id, SEL, id))prevSearch)(selfObj, @selector(updateSearchResultsForSearchController:), searchController);
                NSString *text = nil;
                @try {
                    id bar = ((id (*)(id, SEL))objc_msgSend)(searchController, @selector(searchBar));
                    text = ((id (*)(id, SEL))objc_msgSend)(bar, @selector(text));
                } @catch (__unused NSException *e) {}
                LBCatalogFilterByKeyword(selfObj, text ?: @"");
            });
            method_setImplementation(mSearch, hookSearch);
        }
        NSLog(@"[LegadoBridge] E-02/E-03 CatalogCon order/search assist installed (pending/base aware)");
    });
}
