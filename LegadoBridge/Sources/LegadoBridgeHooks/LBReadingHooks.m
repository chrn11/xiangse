#import "LBInternal.h"
#import "LBLoadCurCpBridge.h"
#import "LegadoBridge.h"
#include <stdint.h>

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

        // 3) loadCurCp — 正文请求侧
        NSArray *cpCandidates = @[@"ReadVCBase1", @"ReadVCBase2", @"TextReadVC1", @"TextReadVC2", @"TextReadVC3"];
        SEL curSel = NSSelectorFromString(@"loadCurCp");
        Class curOwner = LBFindClassImplementing(cpCandidates, curSel);
        if (curOwner && LBValidateInstanceMethod(curOwner, curSel, "v16", &enc, &reason)) {
            Method m = class_getInstanceMethod(curOwner, curSel);
            LBOrig_loadCurCp = (void (*)(id, SEL))method_getImplementation(m);
            LBLoadCurCpBridgeRegisterOrig(LBOrig_loadCurCp);
            method_setImplementation(m, (IMP)LBLoadCurCp_IMP);
            [installed addObject:[NSString stringWithFormat:@"loadCurCp@%@", NSStringFromClass(curOwner)]];
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
