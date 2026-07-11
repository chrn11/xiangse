#import "LBInternal.h"
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
    if (LBOrig_setDicBook) {
        LBOrig_setDicBook(self, _cmd, dicBook);
    }
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
        }
    } @catch (NSException *e) {
        NSLog(@"[LegadoBridge] loadCatalog probe fail-open: %@", e);
    }
    // fail-open：始终回原实现；void* 转发避免 ARC 对 BOOL(0x1) 二次 retain
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
        if (chapterUrl.length > 0) {
            LBReadingRequestContent(chapterUrl, bookUrl, sourceUrl);
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

        // 1) setDicBook: — 生产锚点（类型编码校验：void + 对象参数）
        Class detailCls = NSClassFromString(@"BookDetailController");
        SEL setDicSel = @selector(setDicBook:);
        NSString *enc = nil;
        NSString *reason = nil;
        // 期望包含 @16（首个对象参数偏移）；不强制完整串，避免 ABI 细微差导致全组跳过
        if (LBValidateInstanceMethod(detailCls, setDicSel, "@16", &enc, &reason)) {
            Method m = class_getInstanceMethod(detailCls, setDicSel);
            LBOrig_setDicBook = (void (*)(id, SEL, id))method_getImplementation(m);
            method_setImplementation(m, (IMP)LBSetDicBook_IMP);
            [installed addObject:[NSString stringWithFormat:@"setDicBook enc=%@", enc]];
        } else {
            LBReadingDiagLog([NSString stringWithFormat:@"setDicBook skip: %@", reason ?: @""]);
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
