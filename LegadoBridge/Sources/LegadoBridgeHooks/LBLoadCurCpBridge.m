#import "LBLoadCurCpBridge.h"
#import "LBInternal.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>

static void (*sOrigLoadCurCp)(id, SEL) = NULL;
static LBLoadCurCpState sState = LBLoadCurCpStateIdle;
static NSString *sToken = nil;
static NSString *sChapterUrl = nil;
static NSString *sBookUrl = nil;
static NSInteger sCpIndex = 0;
static NSUInteger sInvokeCount = 0;
static NSDictionary *sPendingPayload = nil;
static __weak id sWeakReader = nil;
static __weak id sWeakHookReceiver = nil;
static BOOL sReentryGuard = NO;
static const void *kLBAssocFoundContainerKey = &kLBAssocFoundContainerKey;

static void LBTraceLoadCurCp(NSString *msg) {
    if (msg.length == 0) return;
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_openreader_trace.txt"];
    NSString *line = [NSString stringWithFormat:@"%@ | %@\n", [NSDate date], msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return;
    }
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

static void LBStateLog(NSString *msg) {
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_loadcurcp_state.txt"];
    NSString *line = [NSString stringWithFormat:@"%@ | %@ | state=%@ token=%@ ch=%@ inv=%lu\n",
                      [NSDate date], msg ?: @"",
                      LBLoadCurCpBridgeStateName(), sToken ?: @"-",
                      sChapterUrl ?: @"-", (unsigned long)sInvokeCount];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return;
    }
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
    LBTraceLoadCurCp([NSString stringWithFormat:@"loadCurCp %@ sm=%@", msg ?: @"", LBLoadCurCpBridgeStateName()]);
}

static void LBSetState(LBLoadCurCpState next, NSString *why) {
    sState = next;
    LBStateLog(why ?: @"transition");
}

NSString *LBLoadCurCpBridgeStateName(void) {
    switch (sState) {
        case LBLoadCurCpStateIdle: return @"idle";
        case LBLoadCurCpStateFetching: return @"fetching";
        case LBLoadCurCpStateContentReady: return @"contentReady";
        case LBLoadCurCpStateInvokingOriginal: return @"invokingOriginal";
        case LBLoadCurCpStateRendered: return @"rendered";
        case LBLoadCurCpStateFailed: return @"failed";
    }
    return @"?";
}

void LBLoadCurCpBridgeRegisterOrig(void (*orig)(id, SEL)) {
    if (!orig) return;
    sOrigLoadCurCp = orig;
    LBStateLog([NSString stringWithFormat:@"register_orig imp=%p", orig]);
}

static NSString *LBBodyFromPayload(NSDictionary *payload);
static void LBTryContentReadyAndInvoke(id reader, NSDictionary *payload);
static void LBScheduleContentReadyWhenReaderReady(NSInteger attempt);

void LBLoadCurCpBridgeCacheContainer(id readerVC, id container) {
    if (!readerVC || !container) return;
    objc_setAssociatedObject(readerVC, kLBAssocFoundContainerKey, container,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    LBStateLog([NSString stringWithFormat:@"hypothesis_F cache_container %@",
                NSStringFromClass(object_getClass(container))]);
    // 路 B：正文常先于 reader 可见到达（contentReady_no_reader_yet）。
    // F 探针在 onReset 后写入 pageContainerA 时立刻重试 invoke，不依赖 CExports 1s delayed_postCurCp。
    if (sPendingPayload && LBBodyFromPayload(sPendingPayload).length > 0 &&
        (sState == LBLoadCurCpStateContentReady || sState == LBLoadCurCpStateFetching)) {
        LBStateLog(@"routeB retry_on_cache_container");
        sWeakReader = readerVC;
        LBTryContentReadyAndInvoke(readerVC, sPendingPayload);
    }
}

BOOL LBLoadCurCpBridgePassThroughToNative(void) {
    return sReentryGuard || sState == LBLoadCurCpStateInvokingOriginal;
}

void LBLoadCurCpBridgeReset(NSString *reason) {
    sToken = nil;
    sChapterUrl = nil;
    sBookUrl = nil;
    sCpIndex = 0;
    sInvokeCount = 0;
    sPendingPayload = nil;
    sWeakReader = nil;
    sReentryGuard = NO;
    LBSetState(LBLoadCurCpStateIdle, reason ?: @"reset");
}

void LBLoadCurCpBridgeMarkRendered(void) {
    if (sState == LBLoadCurCpStateInvokingOriginal || sState == LBLoadCurCpStateContentReady) {
        LBSetState(LBLoadCurCpStateRendered, @"native_render_evidence");
    }
}

static NSString *LBBodyFromPayload(NSDictionary *payload) {
    id c = payload[@"chapterContent"] ?: payload[@"content"];
    return [c isKindOfClass:[NSString class]] ? (NSString *)c : nil;
}

static BOOL LBPayloadHasRealError(NSDictionary *payload) {
    id err = payload[@"error"];
    if (!err || err == [NSNull null]) return NO;
    if ([err isKindOfClass:[NSString class]]) return [(NSString *)err length] > 0;
    return YES;
}

static NSInteger LBCpIndexFromPayload(NSDictionary *payload, id reader) {
    id cpi = payload[@"cpIndex"] ?: payload[@"index"];
    if ([cpi respondsToSelector:@selector(integerValue)]) return [cpi integerValue];
    @try {
        id cur = [reader valueForKey:@"curCpIndex"];
        if ([cur respondsToSelector:@selector(integerValue)]) return [cur integerValue];
    } @catch (__unused NSException *e) {}
    return 0;
}

static BOOL LBObjectIsReadPageContainerLike(id obj) {
    if (!obj) return NO;
    NSString *n = NSStringFromClass(object_getClass(obj));
    if ([n containsString:@"ScrollContainer"]) return NO;
    if ([n isEqualToString:@"ReadPageContainer"] ||
        [n isEqualToString:@"TextRPageContainer"] ||
        [n containsString:@"ReadPageContainer"] ||
        [n containsString:@"TextRPageContainer"]) {
        return YES;
    }
    return [obj respondsToSelector:NSSelectorFromString(@"curPageVC")];
}

/// 假设 F：含 TextRScrollContainer（loadCurCp/division 可能挂在此类）
static BOOL LBObjectIsHypothesisFContainerLike(id obj) {
    if (!obj) return NO;
    NSString *n = NSStringFromClass(object_getClass(obj));
    if ([n isEqualToString:@"TextRScrollContainer"]) return YES;
    return LBObjectIsReadPageContainerLike(obj);
}

static NSInteger LBReadPageContainerPriority(id obj) {
    NSString *n = NSStringFromClass(object_getClass(obj));
    if ([n isEqualToString:@"TextRPageContainer"]) return 0;
    if ([n isEqualToString:@"ReadPageContainer"]) return 1;
    if ([n containsString:@"TextRPageContainer"]) return 2;
    if ([n containsString:@"ReadPageContainer"]) return 3;
    if ([n isEqualToString:@"TextRScrollContainer"]) return 4;
    if ([obj respondsToSelector:NSSelectorFromString(@"curPageVC")]) return 5;
    return 99;
}

/// 从 TextReadVC3 解析 loadCurCp IMP owner（ReadPageContainer，非 VC3 自身）
static id LBReadIvarObject(id obj, const char *name) {
    if (!obj || !name) return nil;
    Class cls = object_getClass(obj);
    while (cls && cls != [NSObject class]) {
        Ivar iv = class_getInstanceVariable(cls, name);
        if (iv) {
            const char *enc = ivar_getTypeEncoding(iv);
            if (enc && enc[0] == '@') {
                return object_getIvar(obj, iv);
            }
            return nil;
        }
        cls = class_getSuperclass(cls);
    }
    return nil;
}

static id LBFindReadPageContainerForReader(id readerVC) {
    if (!readerVC) return nil;
    id cached = objc_getAssociatedObject(readerVC, kLBAssocFoundContainerKey);
    if (cached && LBObjectIsHypothesisFContainerLike(cached)) {
        LBStateLog([NSString stringWithFormat:
                    @"hypothesis_F findContainer hit %@ via=assoc",
                    NSStringFromClass(object_getClass(cached))]);
        return cached;
    }
    // 假设 R2：禁止 valueForKey(@"container"…)（getter 杀进程）；
    // childVC 常为 0；改用 object_getIvar 直读 + 全量 ivar 扫描。
    NSMutableArray *raw = [NSMutableArray array];
    void (^add)(id) = ^(id v) {
        if (v && ![raw containsObject:v]) [raw addObject:v];
    };
    static const char *kNames[] = {
        "_container", "_pageContainer", "_pageContainerA", "_pageContainerB",
        "_rPageContainer", "_readPageContainer", "_curPageContainer",
        "container", "pageContainer", "pageContainerA", "pageContainerB",
        "rPageContainer", "readPageContainer", "curPageContainer",
    };
    for (size_t i = 0; i < sizeof(kNames) / sizeof(kNames[0]); i++) {
        add(LBReadIvarObject(readerVC, kNames[i]));
    }
    id dpv = LBReadIvarObject(readerVC, "_dicPageVC");
    if (!dpv) dpv = LBReadIvarObject(readerVC, "dicPageVC");
    if ([dpv isKindOfClass:[NSDictionary class]]) {
        for (id v in [(NSDictionary *)dpv allValues]) add(v);
    }
    // 扫描 VC 继承链全部对象 ivar，捕获未知命名的 container
    static BOOL sDumped = NO;
    Class cls = object_getClass(readerVC);
    while (cls && cls != [NSObject class]) {
        unsigned int n = 0;
        Ivar *ivs = class_copyIvarList(cls, &n);
        for (unsigned int i = 0; i < n; i++) {
            const char *enc = ivar_getTypeEncoding(ivs[i]);
            const char *nm = ivar_getName(ivs[i]);
            if (!enc || enc[0] != '@') continue;
            id val = object_getIvar(readerVC, ivs[i]);
            if (!sDumped) {
                LBStateLog([NSString stringWithFormat:
                            @"hypothesis_R2 ivar_dump %@::%s -> %@",
                            NSStringFromClass(cls), nm ?: "?",
                            val ? NSStringFromClass(object_getClass(val)) : @"nil"]);
            }
            if (val) add(val);
        }
        if (ivs) free(ivs);
        cls = class_getSuperclass(cls);
    }
    sDumped = YES;
    if ([readerVC isKindOfClass:[UIViewController class]]) {
        for (UIViewController *ch in ((UIViewController *)readerVC).childViewControllers) {
            add(ch);
        }
    }
    id best = nil;
    NSInteger bestPrio = 99;
    for (id c in raw) {
        if (!LBObjectIsHypothesisFContainerLike(c)) continue;
        NSInteger p = LBReadPageContainerPriority(c);
        if (p < bestPrio) {
            bestPrio = p;
            best = c;
        }
    }
    if (!best) {
        LBStateLog([NSString stringWithFormat:
                    @"hypothesis_R2 findContainer miss raw=%lu children=%lu",
                    (unsigned long)raw.count,
                    (unsigned long)([readerVC isKindOfClass:[UIViewController class]]
                        ? ((UIViewController *)readerVC).childViewControllers.count : 0)]);
    } else {
        LBStateLog([NSString stringWithFormat:
                    @"hypothesis_R2 findContainer hit %@ via=ivar",
                    NSStringFromClass(object_getClass(best))]);
    }
    return best;
}

/// 路 B：解析 loadCurCp 的 receiver（优先 hook 捕获的 container，再 ivar pageContainerA）
static id LBRouteBResolveContainer(id reader) {
    id container = nil;
    if (sWeakHookReceiver && LBObjectIsHypothesisFContainerLike(sWeakHookReceiver)) {
        container = sWeakHookReceiver;
        LBStateLog([NSString stringWithFormat:@"routeB_resolve hit hookReceiver %@",
                    NSStringFromClass(object_getClass(container))]);
        return container;
    }
    container = LBFindReadPageContainerForReader(reader);
    if (container) {
        LBStateLog([NSString stringWithFormat:@"routeB_resolve hit find %@",
                    NSStringFromClass(object_getClass(container))]);
        return container;
    }
    if (reader) {
        static const char *kPageContainerIvars[] = {
            "_pageContainerA", "pageContainerA", "_pageContainer", "pageContainer",
            "_pageContainerB", "pageContainerB",
        };
        for (size_t i = 0; i < sizeof(kPageContainerIvars) / sizeof(kPageContainerIvars[0]); i++) {
            id v = LBReadIvarObject(reader, kPageContainerIvars[i]);
            if (v && LBObjectIsHypothesisFContainerLike(v)) {
                LBStateLog([NSString stringWithFormat:
                            @"routeB_resolve hit ivar %s -> %@",
                            kPageContainerIvars[i],
                            NSStringFromClass(object_getClass(v))]);
                return v;
            }
        }
    }
    LBStateLog(@"routeB_resolve miss");
    return nil;
}

static id LBReaderVCFromContext(id obj) {
    if (!obj) return nil;
    if ([obj isKindOfClass:[UIViewController class]]) return obj;
    if (LBObjectIsReadPageContainerLike(obj)) {
        @try {
            id r = [obj valueForKey:@"reader"];
            if ([r isKindOfClass:[UIViewController class]]) return r;
        } @catch (__unused NSException *e) {}
    }
    return obj;
}

static void LBApplyDicContents(id target, NSMutableDictionary *dc, NSMutableArray *paths, NSString *tag) {
    if (!target || !dc || dc.count == 0) return;
    @try {
        if ([target respondsToSelector:@selector(setDicContents:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(target, @selector(setDicContents:), dc);
        } else {
            @try { [target setValue:dc forKey:@"dicContents"]; } @catch (__unused NSException *e) {}
        }
        if (tag.length > 0) [paths addObject:tag];
    } @catch (__unused NSException *e) {}
}

/// confirmed 边界：dicContents / xsfolder / setCpCached（禁 UI / pageModel）
static BOOL LBSeedConfirmedCache(id reader, NSDictionary *payload, NSMutableArray *paths) {
    if (!reader || ![payload isKindOfClass:[NSDictionary class]]) return NO;
    NSString *body = LBBodyFromPayload(payload);
    if (body.length == 0) return NO;

    NSString *title = payload[@"cpTitle"] ?: payload[@"title"] ?: @"章节";
    if (![title isKindOfClass:[NSString class]] || title.length == 0) title = @"章节";
    NSInteger cpIndex = LBCpIndexFromPayload(payload, reader);

    NSDictionary *dicBook = nil;
    @try {
        id d = [reader valueForKey:@"dicBook"];
        if ([d isKindOfClass:[NSDictionary class]]) dicBook = d;
    } @catch (__unused NSException *e) {}
    NSString *bookKey = [dicBook[@"bookKey"] isKindOfClass:[NSString class]] ? dicBook[@"bookKey"] : @"legado|bridge";
    NSString *sourceName = [dicBook[@"sourceName"] isKindOfClass:[NSString class]] ? dicBook[@"sourceName"] : @"本地静态测试源";
    if (sourceName.length == 0) {
        sourceName = [payload[@"sourceName"] isKindOfClass:[NSString class]] ? payload[@"sourceName"] : @"本地静态测试源";
    }

    // 1) dicContents
    @try {
        NSMutableDictionary *dc = nil;
        id cur = nil;
        @try { cur = [reader valueForKey:@"dicContents"]; } @catch (__unused NSException *e) {}
        if ([cur isKindOfClass:[NSMutableDictionary class]]) {
            dc = (NSMutableDictionary *)cur;
        } else if ([cur isKindOfClass:[NSDictionary class]]) {
            dc = [NSMutableDictionary dictionaryWithDictionary:(NSDictionary *)cur];
        } else {
            dc = [NSMutableDictionary dictionary];
        }
        dc[@(cpIndex)] = body;
        dc[[@(cpIndex) stringValue]] = body;
        if (title.length > 0) dc[title] = body;
        NSString *chUrl = payload[@"chapterUrl"] ?: payload[@"cpUrl"];
        if ([chUrl isKindOfClass:[NSString class]] && chUrl.length > 0) dc[chUrl] = body;
        if ([reader respondsToSelector:@selector(setDicContents:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(reader, @selector(setDicContents:), dc);
        } else {
            @try { [reader setValue:dc forKey:@"dicContents"]; } @catch (__unused NSException *e) {}
        }
        [paths addObject:@"dicContents"];
        id container = LBFindReadPageContainerForReader(reader);
        if (container) {
            LBApplyDicContents(container, dc, paths,
                               [NSString stringWithFormat:@"dicContents@%@",
                                NSStringFromClass(object_getClass(container))]);
        }
    } @catch (__unused NSException *e) {}

    // 2) xsfolder + localSourceText（供 queryCpFileByBook 读本地缓存）
    @try {
        NSString *bookDir = [NSHomeDirectory() stringByAppendingPathComponent:
                             [NSString stringWithFormat:@"Documents/xsfolder/book/%@", bookKey]];
        [[NSFileManager defaultManager] createDirectoryAtPath:bookDir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];
        NSString *cpPath = [bookDir stringByAppendingPathComponent:
                            [NSString stringWithFormat:@"%ld", (long)cpIndex]];
        [body writeToFile:cpPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        NSString *altPath = [bookDir stringByAppendingPathComponent:
                             [NSString stringWithFormat:@"%@%ld", bookKey, (long)cpIndex]];
        [body writeToFile:altPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        NSDictionary *lstPlist = @{
            @"list": @[ @{
                @"title": title,
                @"url": [@(cpIndex) stringValue]
            } ]
        };
        [lstPlist writeToFile:[bookDir stringByAppendingPathComponent:@"localSourceText"]
                   atomically:YES];
        for (id tgt in @[reader, LBFindReadPageContainerForReader(reader) ?: [NSNull null]]) {
            if (tgt == (id)[NSNull null]) continue;
            @try { [tgt setValue:bookDir forKey:@"bookDirPath"]; } @catch (__unused NSException *e) {}
            if ([tgt respondsToSelector:NSSelectorFromString(@"setBookDirPath:")]) {
                ((void (*)(id, SEL, id))objc_msgSend)(
                    tgt, NSSelectorFromString(@"setBookDirPath:"), bookDir);
            }
        }
        [paths addObject:@"xsfolder"];
        [paths addObject:@"localSourceText"];
    } @catch (__unused NSException *e) {}

    // 3) BookDbManager#setCpCached
    @try {
        id mgr = nil;
        for (NSString *cn in @[@"BookDbManager", @"BookQueryManager", @"CacherManager"]) {
            Class cls = NSClassFromString(cn);
            if (!cls) continue;
            if ([cls respondsToSelector:@selector(sharedInstance)]) {
                mgr = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(sharedInstance));
            } else if ([cls respondsToSelector:@selector(sharedManager)]) {
                mgr = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(sharedManager));
            }
            if (!mgr) continue;
            SEL sel = NSSelectorFromString(@"setCpCached:cpIndex:bookKey:sourceName:");
            if (![mgr respondsToSelector:sel]) continue;
            @try {
                ((void (*)(id, SEL, id, NSInteger, id, id))objc_msgSend)(
                    mgr, sel, body, cpIndex, bookKey, sourceName);
                [paths addObject:[NSString stringWithFormat:@"setCpCached@%@", cn]];
                break;
            } @catch (__unused NSException *e1) {
                @try {
                    ((void (*)(id, SEL, id, NSInteger, id, id))objc_msgSend)(
                        mgr, sel, title, cpIndex, bookKey, sourceName);
                    [paths addObject:[NSString stringWithFormat:@"setCpCachedTitle@%@", cn]];
                    break;
                } @catch (__unused NSException *e2) {}
            }
        }
    } @catch (__unused NSException *e) {}

    return paths.count > 0;
}

static void LBRequestContent(NSString *chapterUrl, NSString *bookUrl, NSString *sourceUrl) {
    if (chapterUrl.length == 0 || bookUrl.length == 0) return;
    id core = LBLegadoCoreIfReady();
    if (![core respondsToSelector:@selector(handleContentRequestWithChapterUrl:bookUrl:sourceUrl:)]) return;
    ((void (*)(id, SEL, NSString *, NSString *, NSString *))objc_msgSend)(
        core, @selector(handleContentRequestWithChapterUrl:bookUrl:sourceUrl:),
        chapterUrl, bookUrl, sourceUrl ?: @""
    );
}

/// 假设 P：loadCurCp 静态 callee 含 curPageVC；过早 invoke 会跳过 queryCpFile
static id LBContainerCurPageVC(id container) {
    if (!container) return nil;
    @try {
        id v = [container valueForKey:@"curPageVC"];
        return v;
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static void LBEnsureContainerReaderLink(id container, id reader) {
    if (!container || !reader) return;
    @try {
        id cur = nil;
        @try { cur = [container valueForKey:@"reader"]; } @catch (__unused NSException *e) {}
        if (cur == reader) return;
        if ([container respondsToSelector:NSSelectorFromString(@"setReader:")]) {
            ((void (*)(id, SEL, id))objc_msgSend)(
                container, NSSelectorFromString(@"setReader:"), reader);
        } else {
            @try { [container setValue:reader forKey:@"reader"]; } @catch (__unused NSException *e) {}
        }
        LBStateLog([NSString stringWithFormat:@"hypothesis_P link_reader %@",
                    NSStringFromClass(object_getClass(reader))]);
    } @catch (__unused NSException *e) {}
}

static NSUInteger LBCountOrZero(id obj) {
    if ([obj isKindOfClass:[NSArray class]]) return [(NSArray *)obj count];
    if ([obj isKindOfClass:[NSDictionary class]]) return [(NSDictionary *)obj count];
    if ([obj respondsToSelector:@selector(count)]) {
        @try { return [[obj valueForKey:@"count"] unsignedIntegerValue]; } @catch (__unused NSException *e) {}
    }
    return 0;
}

static void LBSetIntegerKey(id target, NSString *key, NSInteger value) {
    if (!target || key.length == 0) return;
    NSString *setter = [NSString stringWithFormat:@"set%@%@:",
                        [[key substringToIndex:1] uppercaseString],
                        [key substringFromIndex:1]];
    SEL sel = NSSelectorFromString(setter);
    @try {
        if ([target respondsToSelector:sel]) {
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(target, sel, value);
            return;
        }
    } @catch (__unused NSException *e) {}
    // 假设 R：标量 q/Q ivar 不能 object_setIvar(NSNumber*)，按 offset 写
    NSString *ivarName = [@"_" stringByAppendingString:key];
    Class cls = object_getClass(target);
    while (cls && cls != [NSObject class]) {
        Ivar iv = class_getInstanceVariable(cls, ivarName.UTF8String);
        if (iv) {
            const char *enc = ivar_getTypeEncoding(iv);
            if (enc && (enc[0] == 'q' || enc[0] == 'Q' || enc[0] == 'i' || enc[0] == 'I'
                        || enc[0] == 'l' || enc[0] == 'L')) {
                ptrdiff_t off = ivar_getOffset(iv);
                void *base = (__bridge void *)target;
                if (enc[0] == 'q' || enc[0] == 'l') {
                    *(NSInteger *)((uint8_t *)base + off) = value;
                } else if (enc[0] == 'Q' || enc[0] == 'L') {
                    *(NSUInteger *)((uint8_t *)base + off) = (NSUInteger)value;
                } else {
                    *(int *)((uint8_t *)base + off) = (int)value;
                }
                return;
            }
        }
        cls = class_getSuperclass(cls);
    }
    @try { [target setValue:@(value) forKey:key]; } @catch (__unused NSException *e) {}
}

static NSInteger LBReadIntegerKey(id target, NSString *key, NSInteger fallback) {
    if (!target || key.length == 0) return fallback;
    @try {
        if ([target respondsToSelector:NSSelectorFromString(key)]) {
            return ((NSInteger (*)(id, SEL))objc_msgSend)(target, NSSelectorFromString(key));
        }
    } @catch (__unused NSException *e) {}
    @try {
        id v = [target valueForKey:key];
        if ([v respondsToSelector:@selector(integerValue)]) return [v integerValue];
    } @catch (__unused NSException *e) {}
    return fallback;
}

/// 假设 Q：loadCurCp callee 还含 arrCatalog/count；缺目录会跳过 query
/// 假设 R/R2：分页模式 index 在 ReadPageModel._nCpIndex（method-map confirmed）；
/// TextReadVC3/ReadPageContainer **无** _curCpIndex（gates 的 curCp@r/c=-999 是误报）。
/// ReadScrollContainer 才有 curCpIndex，滚动模式再写。
static void LBEnsureLoadCurCpPrereqs(id reader, id container, NSDictionary *payload) {
    if (!reader || ![payload isKindOfClass:[NSDictionary class]]) return;
    NSInteger cpIndex = LBCpIndexFromPayload(payload, reader);
    NSString *title = payload[@"cpTitle"] ?: payload[@"title"] ?: @"章节";
    if (![title isKindOfClass:[NSString class]] || title.length == 0) title = @"章节";
    NSString *chUrl = payload[@"chapterUrl"] ?: payload[@"cpUrl"];
    if (![chUrl isKindOfClass:[NSString class]] || chUrl.length == 0) {
        chUrl = [@(cpIndex) stringValue];
    }

    id curPage = LBContainerCurPageVC(container);
    id pageModel = nil;
    if (curPage) {
        @try { pageModel = [curPage valueForKey:@"pageModel"]; } @catch (__unused NSException *e) {}
        if (!pageModel) {
            @try { pageModel = [curPage valueForKey:@"readPageModel"]; } @catch (__unused NSException *e) {}
        }
    }

    // 分页：只写 ReadPageModel 标量
    if (pageModel) {
        LBSetIntegerKey(pageModel, @"nCpIndex", cpIndex);
        LBSetIntegerKey(pageModel, @"nPageIndex", 0);
        NSUInteger cpCount = 1;
        @try {
            id cat = [reader valueForKey:@"arrCatalog"];
            NSUInteger n = LBCountOrZero(cat);
            if (n > 0) cpCount = n;
        } @catch (__unused NSException *e) {}
        LBSetIntegerKey(pageModel, @"nCpCount", (NSInteger)cpCount);
        // 假设 V：loadCurCp @0x1000d7d8c 为 cmp pageStatus,#3；!=3 则 epilogue 早退，
        // 永不进入 queryCpFileByBook（chain-msg + 反汇编 confirmed）。R2 误 seed=0。
        LBSetIntegerKey(pageModel, @"pageStatus", 3);
        LBStateLog([NSString stringWithFormat:
                    @"hypothesis_V seed pageModel nCpIndex=%ld nCpCount=%lu pageStatus=3",
                    (long)cpIndex, (unsigned long)cpCount]);
    }
    // 滚动容器若在栈上，补 curCpIndex
    for (id tgt in @[container ?: [NSNull null], curPage ?: [NSNull null]]) {
        if (tgt == (id)[NSNull null]) continue;
        NSString *cn = NSStringFromClass(object_getClass(tgt));
        if ([cn containsString:@"Scroll"]) {
            LBSetIntegerKey(tgt, @"curCpIndex", cpIndex);
        }
    }

    id cat = nil;
    @try { cat = [reader valueForKey:@"arrCatalog"]; } @catch (__unused NSException *e) {}
    if (LBCountOrZero(cat) == 0) {
        NSDictionary *chapter = @{
            @"title": title,
            @"name": title,
            @"url": chUrl,
            @"cpUrl": chUrl,
            @"index": @(cpIndex),
            @"cpIndex": @(cpIndex),
        };
        NSArray *arr = @[chapter];
        @try {
            if ([reader respondsToSelector:NSSelectorFromString(@"setArrCatalog:")]) {
                ((void (*)(id, SEL, id))objc_msgSend)(
                    reader, NSSelectorFromString(@"setArrCatalog:"), arr);
            } else {
                [reader setValue:arr forKey:@"arrCatalog"];
            }
            LBStateLog(@"hypothesis_Q seed_arrCatalog count=1");
        } @catch (__unused NSException *e) {
            LBStateLog(@"hypothesis_Q seed_arrCatalog_failed");
        }
    }

    // 假设 W：queryCpFileByBook → queryByActionID 调 AppConfig#getBookKey:(book)。
    // book=nil 或非 Dictionary / 缺 bookName|author → @0x10006114c cbz 早退，无 QF。
    // V 真机：pre pageStatus=3 → post=1，已越过 cmp #3；ivar _dicFatBook 仍为 nil。
    @try {
        id existing = nil;
        @try { existing = [reader valueForKey:@"dicFatBook"]; } @catch (__unused NSException *e) {}
        NSMutableDictionary *fat = nil;
        if ([existing isKindOfClass:[NSMutableDictionary class]]) {
            fat = (NSMutableDictionary *)existing;
        } else if ([existing isKindOfClass:[NSDictionary class]]) {
            fat = [NSMutableDictionary dictionaryWithDictionary:(NSDictionary *)existing];
        } else {
            fat = [NSMutableDictionary dictionary];
        }
        NSDictionary *dicBook = nil;
        @try {
            id d = [reader valueForKey:@"dicBook"];
            if ([d isKindOfClass:[NSDictionary class]]) dicBook = (NSDictionary *)d;
        } @catch (__unused NSException *e) {}
        NSString *bookName = nil;
        NSString *author = nil;
        if ([dicBook[@"bookName"] isKindOfClass:[NSString class]]) bookName = dicBook[@"bookName"];
        else if ([dicBook[@"name"] isKindOfClass:[NSString class]]) bookName = dicBook[@"name"];
        else if ([dicBook[@"title"] isKindOfClass:[NSString class]]) bookName = dicBook[@"title"];
        if ([dicBook[@"author"] isKindOfClass:[NSString class]]) author = dicBook[@"author"];
        if (bookName.length == 0 && [payload[@"bookName"] isKindOfClass:[NSString class]]) {
            bookName = payload[@"bookName"];
        }
        if (author.length == 0 && [payload[@"author"] isKindOfClass:[NSString class]]) {
            author = payload[@"author"];
        }
        if (bookName.length == 0) bookName = @"斗破苍穹";
        if (author.length == 0) author = @"天蚕土豆";
        if (![fat[@"bookName"] isKindOfClass:[NSString class]] || [fat[@"bookName"] length] == 0) {
            fat[@"bookName"] = bookName;
        }
        if (![fat[@"author"] isKindOfClass:[NSString class]] || [fat[@"author"] length] == 0) {
            fat[@"author"] = author;
        }
        id bk = nil;
        @try { bk = [reader valueForKey:@"bookKey"]; } @catch (__unused NSException *e) {}
        if (![bk isKindOfClass:[NSString class]] || [(NSString *)bk length] == 0) {
            bk = dicBook[@"bookKey"];
        }
        if ([bk isKindOfClass:[NSString class]] && [(NSString *)bk length] > 0 &&
            !([fat[@"bookKey"] isKindOfClass:[NSString class]] && [fat[@"bookKey"] length] > 0)) {
            fat[@"bookKey"] = bk;
        }
        // 假设 X（反汇编校正）：@0x10006116c/1a8 的 chapterList|chapterContent 是
        // queryByActionID 的 actionID（queryCpFileByBook 已硬编码 @"chapterContent"），
        // 不是 fat 字典键。W 之后最先挡住的字段是 book[@"_useSName"]：
        // sourceName 实参恒 nil（@0x100060ec0），length==0 → @0x100061204 返
        // 「没有使用中的站点」。本 commit 只种这一字段。
        if (![fat[@"_useSName"] isKindOfClass:[NSString class]] ||
            [fat[@"_useSName"] length] == 0) {
            NSString *useSName = nil;
            if ([dicBook[@"_useSName"] isKindOfClass:[NSString class]] &&
                [dicBook[@"_useSName"] length] > 0) {
                useSName = dicBook[@"_useSName"];
            } else if ([dicBook[@"sourceName"] isKindOfClass:[NSString class]] &&
                       [dicBook[@"sourceName"] length] > 0) {
                useSName = dicBook[@"sourceName"];
            } else if ([payload[@"sourceName"] isKindOfClass:[NSString class]] &&
                       [payload[@"sourceName"] length] > 0) {
                useSName = payload[@"sourceName"];
            } else {
                // 与 LBSeedConfirmedCache / bookShelf.plist 本地文本源对齐
                useSName = @"localSourceText";
            }
            fat[@"_useSName"] = useSName;
        }
        if ([reader respondsToSelector:NSSelectorFromString(@"setDicFatBook:")]) {
            ((void (*)(id, SEL, id))objc_msgSend)(
                reader, NSSelectorFromString(@"setDicFatBook:"), fat);
        } else {
            [reader setValue:fat forKey:@"dicFatBook"];
        }
        LBStateLog([NSString stringWithFormat:
                    @"hypothesis_W seed dicFatBook bookNameLen=%lu authorLen=%lu bookKeyLen=%lu",
                    (unsigned long)[fat[@"bookName"] length],
                    (unsigned long)[fat[@"author"] length],
                    (unsigned long)([fat[@"bookKey"] isKindOfClass:[NSString class]]
                                    ? [fat[@"bookKey"] length] : 0)]);
        LBStateLog([NSString stringWithFormat:
                    @"hypothesis_X seed _useSNameLen=%lu",
                    (unsigned long)([fat[@"_useSName"] isKindOfClass:[NSString class]]
                                    ? [fat[@"_useSName"] length] : 0)]);
    } @catch (__unused NSException *e) {
        LBStateLog(@"hypothesis_W seed_dicFatBook_failed");
    }
}

static void LBLogLoadCurCpGates(id reader, id container, NSString *tag) {
    NSUInteger nCat = 0, nDc = 0, nDcC = 0, nFat = 0;
    NSString *bookKey = @"-";
    NSString *bookDir = @"-";
    NSInteger curR = -999, curC = -999, nCp = -999;
    @try { nCat = LBCountOrZero([reader valueForKey:@"arrCatalog"]); } @catch (__unused NSException *e) {}
    @try { nDc = LBCountOrZero([reader valueForKey:@"dicContents"]); } @catch (__unused NSException *e) {}
    @try { nFat = LBCountOrZero([reader valueForKey:@"dicFatBook"]); } @catch (__unused NSException *e) {}
    if (container) {
        @try { nDcC = LBCountOrZero([container valueForKey:@"dicContents"]); } @catch (__unused NSException *e) {}
    }
    @try {
        id bk = [reader valueForKey:@"bookKey"];
        if (![bk isKindOfClass:[NSString class]]) {
            id db = [reader valueForKey:@"dicBook"];
            if ([db isKindOfClass:[NSDictionary class]]) bk = db[@"bookKey"];
        }
        if ([bk isKindOfClass:[NSString class]]) bookKey = bk;
    } @catch (__unused NSException *e) {}
    @try {
        id bd = [reader valueForKey:@"bookDirPath"];
        if ([bd isKindOfClass:[NSString class]]) bookDir = bd;
    } @catch (__unused NSException *e) {}
    curR = LBReadIntegerKey(reader, @"curCpIndex", -999);
    if (container) curC = LBReadIntegerKey(container, @"curCpIndex", -999);
    id curPage = LBContainerCurPageVC(container);
    id pageModel = nil;
    if (curPage) {
        @try { pageModel = [curPage valueForKey:@"pageModel"]; } @catch (__unused NSException *e) {}
    }
    if (pageModel) nCp = LBReadIntegerKey(pageModel, @"nCpIndex", -999);
    NSInteger pageStatus = -999;
    if (pageModel) pageStatus = LBReadIntegerKey(pageModel, @"pageStatus", -999);
    else if (container) pageStatus = LBReadIntegerKey(container, @"pageStatus", -999);
    NSUInteger useSNameLen = 0, sourceILKeys = 0;
    @try {
        id fat = [reader valueForKey:@"dicFatBook"];
        if ([fat isKindOfClass:[NSDictionary class]]) {
            id us = fat[@"_useSName"] ?: fat[@"sourceName"];
            if ([us isKindOfClass:[NSString class]]) useSNameLen = [(NSString *)us length];
            id sil = fat[@"_sourceIL"];
            if ([sil isKindOfClass:[NSDictionary class]]) sourceILKeys = [(NSDictionary *)sil count];
        }
    } @catch (__unused NSException *e) {}

    LBStateLog([NSString stringWithFormat:
                @"hypothesis_R2 gates(%@) arrCatalog=%lu dicContents@r=%lu dicContents@c=%lu "
                @"dicFatBook=%lu bookKeyLen=%lu bookDirLen=%lu nCp@pm=%ld pageStatus=%ld "
                @"useSNameLen=%lu sourceILKeys=%lu "
                @"(curCp@r/c N/A paged-no-ivar got %ld/%ld)",
                tag ?: @"-",
                (unsigned long)nCat, (unsigned long)nDc, (unsigned long)nDcC,
                (unsigned long)nFat,
                (unsigned long)bookKey.length, (unsigned long)bookDir.length,
                (long)nCp, (long)pageStatus,
                (unsigned long)useSNameLen, (unsigned long)sourceILKeys,
                (long)curR, (long)curC]);
}

/// 假设 T：loadViewIfNeeded 阶段会 contentReady，但此时 VC 尚未 push，过早 invoke 无窗口/无链并很快回到书架
static BOOL LBReaderIsAttachedToUI(id reader) {
    if (![reader isKindOfClass:[UIViewController class]]) return NO;
    UIViewController *vc = (UIViewController *)reader;
    @try {
        if (vc.viewIfLoaded.window != nil) return YES;
    } @catch (__unused NSException *e) {}
    @try {
        if (vc.navigationController != nil) return YES;
    } @catch (__unused NSException *e) {}
    @try {
        if (vc.parentViewController != nil) return YES;
    } @catch (__unused NSException *e) {}
    @try {
        if (vc.presentingViewController != nil) return YES;
    } @catch (__unused NSException *e) {}
    return NO;
}

static void LBInvokeOriginalLoadCurCp(id reader, BOOL forceWithoutCurPage);
static void LBScheduleInvokeWhenPageReady(id reader, NSInteger attempt);

static void LBInvokeOriginalLoadCurCp(id reader, BOOL forceWithoutCurPage) {
    if (!reader) {
        LBStateLog(@"invoke_skip reason=null_reader");
        return;
    }
    if (!sOrigLoadCurCp) {
        LBStateLog(@"invoke_skip reason=null_orig");
        return;
    }
    if (sReentryGuard) {
        LBStateLog(@"invoke_skip reason=reentry");
        return;
    }
    if (sState == LBLoadCurCpStateInvokingOriginal || sState == LBLoadCurCpStateRendered) {
        LBStateLog([NSString stringWithFormat:@"invoke_skip reason=bad_state sm=%@",
                    LBLoadCurCpBridgeStateName()]);
        return;
    }

    id container = LBRouteBResolveContainer(reader);
    if (!container) {
        LBStateLog(@"invoke_skip reason=no_container");
        return;
    }
    // 假设 R2：+load 时 ReadPageContainer 可能未链入，此处补注册 native IMP
    if (!sOrigLoadCurCp) {
        for (NSString *cn in @[@"ReadPageContainer", @"TextRPageContainer",
                               NSStringFromClass(object_getClass(container))]) {
            Class cls = NSClassFromString(cn);
            if (!cls) continue;
            Method m = class_getInstanceMethod(cls, @selector(loadCurCp));
            if (!m) continue;
            IMP imp = method_getImplementation(m);
            if (!imp) continue;
            LBLoadCurCpBridgeRegisterOrig((void (*)(id, SEL))imp);
            LBStateLog([NSString stringWithFormat:
                        @"hypothesis_R2 late_register_orig %@ imp=%p", cn, imp]);
            break;
        }
    }
    if (!sOrigLoadCurCp) {
        LBStateLog(@"invoke_skip reason=null_orig_after_late_register");
        return;
    }
    LBEnsureContainerReaderLink(container, reader);
    id curPage = LBContainerCurPageVC(container);
    BOOL attached = LBReaderIsAttachedToUI(reader);
    id pageStatus = nil;
    @try { pageStatus = [container valueForKey:@"pageStatus"]; } @catch (__unused NSException *e) {}
    NSString *containerName = NSStringFromClass(object_getClass(container));
    LBStateLog([NSString stringWithFormat:
                @"hypothesis_T pre_invoke target=%@ curPageVC=%@ attached=%d pageStatus=%@ force=%d",
                containerName,
                curPage ? NSStringFromClass(object_getClass(curPage)) : @"nil",
                attached ? 1 : 0,
                pageStatus ?: @"nil",
                forceWithoutCurPage ? 1 : 0]);
    if (!attached && !forceWithoutCurPage) {
        LBStateLog([NSString stringWithFormat:
                    @"routeB defer_invoke attached=0 container=%@",
                    containerName]);
        LBScheduleInvokeWhenPageReady(reader, 0);
        return;
    }

    if (sPendingPayload) {
        NSMutableArray *paths = [NSMutableArray array];
        LBSeedConfirmedCache(reader, sPendingPayload, paths);
        LBEnsureLoadCurCpPrereqs(reader, container, sPendingPayload);
        LBLogLoadCurCpGates(reader, container, @"pre_invoke_routeB");
    } else {
        LBLogLoadCurCpGates(reader, container, @"no_payload");
    }

    sReentryGuard = YES;
    sInvokeCount++;
    LBSetState(LBLoadCurCpStateInvokingOriginal, @"routeB_invoke_begin");
    LBTraceLoadCurCp([NSString stringWithFormat:
                      @"sm=invokingOriginal ch=%@ target=%@ orig=%p",
                      sChapterUrl ?: @"-", containerName, sOrigLoadCurCp]);
    @try {
        sOrigLoadCurCp(container, @selector(loadCurCp));
        LBStateLog([NSString stringWithFormat:@"invoke_orig_OK target=%@", containerName]);
        LBTraceLoadCurCp(@"ORIG loadCurCp OK");
        LBLogLoadCurCpGates(reader, container, @"post_invoke_routeB");
        // 假设 O：invoke_orig_OK 后禁止人工 kick；等原生 queryCpFileByBook→QF→DR→finish
        if (sPendingPayload && LBBodyFromPayload(sPendingPayload).length > 0) {
            LBTraceLoadCurCp(@"hypothesis_O kick_disabled await_native_chain");
            LBStateLog(@"hypothesis_O kick_disabled await_native_QF_DR_finish");
        }
    } @catch (NSException *ex) {
        LBSetState(LBLoadCurCpStateFailed, [NSString stringWithFormat:@"invoke_orig_EX %@", ex.reason ?: @""]);
        sReentryGuard = NO;
        return;
    }
    sReentryGuard = NO;
    if (sState == LBLoadCurCpStateInvokingOriginal) {
        LBSetState(LBLoadCurCpStateIdle, @"invoke_orig_done_pending_render");
    }
}

static void LBScheduleInvokeWhenPageReady(id reader, NSInteger attempt) {
    if (attempt >= 30) {
        LBStateLog(@"routeB wait_container_timeout");
        LBSetState(LBLoadCurCpStateFailed, @"routeB_wait_container_timeout");
        return;
    }
    __weak id weakReader = reader;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        id strong = weakReader;
        if (!strong) {
            LBStateLog(@"hypothesis_R2 defer_tick reader_gone");
            return;
        }
        LBStateLog([NSString stringWithFormat:
                    @"hypothesis_R2 defer_tick_enter attempt=%ld", (long)attempt]);
        id container = nil;
        id curPage = nil;
        BOOL attached = NO;
        @try {
            container = LBRouteBResolveContainer(strong);
            curPage = LBContainerCurPageVC(container);
            attached = LBReaderIsAttachedToUI(strong);
        } @catch (NSException *ex) {
            LBStateLog([NSString stringWithFormat:@"hypothesis_R2 defer_tick EX %@",
                        ex.reason ?: @""]);
            LBScheduleInvokeWhenPageReady(strong, attempt + 1);
            return;
        }
        LBStateLog([NSString stringWithFormat:
                    @"routeB defer_tick attempt=%ld container=%@ curPageVC=%@ attached=%d",
                    (long)attempt,
                    container ? NSStringFromClass(object_getClass(container)) : @"nil",
                    curPage ? NSStringFromClass(object_getClass(curPage)) : @"nil",
                    attached ? 1 : 0]);
        if (container && attached) {
            LBInvokeOriginalLoadCurCp(strong, NO);
        } else if (attached && attempt >= 12) {
            LBStateLog(@"routeB defer_giveup attached_no_container");
            LBSetState(LBLoadCurCpStateFailed, @"routeB_no_container");
        } else {
            LBScheduleInvokeWhenPageReady(strong, attempt + 1);
        }
    });
}

/// 在窗口/导航栈上找 TextReadVC*（不依赖 CExports）
static id LBFindTextReaderVCInHierarchy(void) {
    NSArray *windows = [UIApplication sharedApplication].windows;
    if (windows.count == 0) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        UIWindow *kw = [UIApplication sharedApplication].keyWindow;
#pragma clang diagnostic pop
        if (kw) windows = @[kw];
    }
    for (UIWindow *w in windows) {
        UIViewController *root = w.rootViewController;
        if (!root) continue;
        NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
        while (stack.count > 0) {
            UIViewController *vc = stack.lastObject;
            [stack removeLastObject];
            NSString *cn = NSStringFromClass([vc class]);
            if ([cn containsString:@"TextReadVC"] || [cn containsString:@"ReadVCBase"]) {
                return vc;
            }
            for (UIViewController *c in vc.childViewControllers) [stack addObject:c];
            if (vc.presentedViewController) [stack addObject:vc.presentedViewController];
            if ([vc isKindOfClass:[UINavigationController class]]) {
                for (UIViewController *c in [(UINavigationController *)vc viewControllers]) {
                    [stack addObject:c];
                }
            }
        }
    }
    return nil;
}

static void LBScheduleContentReadyWhenReaderReady(NSInteger attempt) {
    if (attempt >= 40) {
        LBStateLog(@"routeB wait_reader_timeout");
        return;
    }
    if (!sPendingPayload || LBBodyFromPayload(sPendingPayload).length == 0) return;
    if (sState != LBLoadCurCpStateContentReady && sState != LBLoadCurCpStateFetching) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!sPendingPayload || LBBodyFromPayload(sPendingPayload).length == 0) return;
        if (sState != LBLoadCurCpStateContentReady && sState != LBLoadCurCpStateFetching) return;
        id reader = sWeakReader ?: LBFindTextReaderVCInHierarchy();
        if (reader) {
            LBStateLog([NSString stringWithFormat:
                        @"routeB reader_ready attempt=%ld cls=%@",
                        (long)attempt, NSStringFromClass(object_getClass(reader))]);
            LBTryContentReadyAndInvoke(reader, sPendingPayload);
            return;
        }
        LBStateLog([NSString stringWithFormat:
                    @"routeB wait_reader attempt=%ld", (long)attempt]);
        LBScheduleContentReadyWhenReaderReady(attempt + 1);
    });
}

static void LBTryContentReadyAndInvoke(id reader, NSDictionary *payload) {
    if (!reader || ![payload isKindOfClass:[NSDictionary class]]) return;
    if (LBBodyFromPayload(payload).length == 0) {
        LBSetState(LBLoadCurCpStateFailed, @"contentReady_no_body");
        return;
    }
    sPendingPayload = [payload copy];
    sWeakReader = reader;
    LBSetState(LBLoadCurCpStateContentReady, @"contentReady");

    NSMutableArray *paths = [NSMutableArray array];
    LBSeedConfirmedCache(reader, payload, paths);
    LBStateLog([NSString stringWithFormat:@"routeB seed_cache paths=%@",
                [paths componentsJoinedByString:@","] ?: @"-"]);

    id container = LBRouteBResolveContainer(reader);
    if (container) {
        LBEnsureLoadCurCpPrereqs(reader, container, payload);
        LBStateLog(@"routeB_container_hit immediate");
        // 有 container 即尝试 invoke；attached=0 时由 LBInvokeOriginalLoadCurCp 内部 defer
        LBInvokeOriginalLoadCurCp(reader, YES);
        return;
    }
    LBStateLog(@"routeB schedule_wait_container");
    LBScheduleInvokeWhenPageReady(reader, 0);
}

BOOL LBLoadCurCpBridgeHandleHook(id self, SEL _cmd,
                                 BOOL isLegado,
                                 NSString *bookUrl,
                                 NSString *sourceUrl,
                                 NSString *chapterUrl) {
    if (!isLegado) return NO;

    if (self) {
        sWeakHookReceiver = self;
    }

    if (LBLoadCurCpBridgePassThroughToNative()) {
        LBStateLog(@"hook_passthrough_native");
        return NO;
    }

    sWeakReader = LBReaderVCFromContext(self) ?: self;
    if (bookUrl.length > 0) sBookUrl = [bookUrl copy];
    if (chapterUrl.length > 0) {
        sChapterUrl = [chapterUrl copy];
        sToken = [chapterUrl copy];
    }

    if (sState == LBLoadCurCpStateRendered) {
        LBStateLog(@"hook_skip_rendered");
        return YES;
    }

    if (sPendingPayload && LBBodyFromPayload(sPendingPayload).length > 0 &&
        sState != LBLoadCurCpStateFetching) {
        // 路 B：contentReady 后放行原生 loadCurCp，由原版走完 queryCpFile→division
        if (sState == LBLoadCurCpStateContentReady ||
            sState == LBLoadCurCpStateInvokingOriginal) {
            LBStateLog(@"routeB hook_passthrough_native_loadCurCp");
            return NO;
        }
        LBStateLog(@"hypothesis_T5 hook_block_early_invoke await_postCurCp");
        return YES;
    }

    if (sState == LBLoadCurCpStateFetching) {
        LBStateLog(@"hook_already_fetching");
        return YES;
    }

    if (chapterUrl.length > 0 && bookUrl.length > 0) {
        LBSetState(LBLoadCurCpStateFetching, @"hook_start_fetch");
        LBRequestContent(chapterUrl, bookUrl, sourceUrl);
        LBStateLog([NSString stringWithFormat:@"hook_fetch book=%@ ch=%@", bookUrl, chapterUrl]);
        return YES;
    }

    LBSetState(LBLoadCurCpStateFailed, @"hook_no_chapter_url");
    return YES;
}

void LBLoadCurCpBridgeOnContentPosted(NSDictionary *payload, id readerVC) {
    if (![payload isKindOfClass:[NSDictionary class]] || payload.count == 0) return;

    NSString *body = LBBodyFromPayload(payload);
    BOOL hasBody = body.length > 0;
    BOOL hasRealError = LBPayloadHasRealError(payload);

    if (!hasBody && hasRealError) {
        LBSetState(LBLoadCurCpStateFailed,
                   [NSString stringWithFormat:@"content_err %@", payload[@"error"]]);
        return;
    }
    if (!hasBody && !hasRealError && payload[@"error"]) {
        LBStateLog(@"content_err_empty_ignored");
        return;
    }
    if (!hasBody) {
        LBStateLog(@"content_post_no_body");
        return;
    }

    sPendingPayload = [payload copy];
    NSString *ch = payload[@"chapterUrl"] ?: payload[@"cpUrl"];
    if ([ch isKindOfClass:[NSString class]] && ch.length > 0) {
        sChapterUrl = ch;
        sToken = ch;
    }
    id bookUrl = payload[@"bookUrl"];
    if ([bookUrl isKindOfClass:[NSString class]]) sBookUrl = bookUrl;

    id reader = readerVC ?: sWeakReader ?: LBFindTextReaderVCInHierarchy();
    if (!reader) {
        LBSetState(LBLoadCurCpStateContentReady, @"contentReady_no_reader_yet");
        LBStateLog(@"routeB schedule_wait_reader");
        LBScheduleContentReadyWhenReaderReady(0);
        return;
    }
    LBTryContentReadyAndInvoke(reader, payload);
}
