#import "LBLoadCurCpBridge.h"
#import "LBInternal.h"
#import <objc/message.h>
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
static BOOL sReentryGuard = NO;

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

static NSInteger LBReadPageContainerPriority(id obj) {
    NSString *n = NSStringFromClass(object_getClass(obj));
    if ([n isEqualToString:@"TextRPageContainer"]) return 0;
    if ([n isEqualToString:@"ReadPageContainer"]) return 1;
    if ([n containsString:@"TextRPageContainer"]) return 2;
    if ([n containsString:@"ReadPageContainer"]) return 3;
    if ([obj respondsToSelector:NSSelectorFromString(@"curPageVC")]) return 4;
    return 99;
}

/// 从 TextReadVC3 解析 loadCurCp IMP owner（ReadPageContainer，非 VC3 自身）
static id LBFindReadPageContainerForReader(id readerVC) {
    if (!readerVC) return nil;
    if ([readerVC isKindOfClass:[UIViewController class]]) {
        UIViewController *vc = (UIViewController *)readerVC;
        @try {
            if (!vc.isViewLoaded) [vc loadViewIfNeeded];
        } @catch (__unused NSException *e) {}
    }
    NSMutableArray *raw = [NSMutableArray array];
    void (^add)(id) = ^(id v) {
        if (v && ![raw containsObject:v]) [raw addObject:v];
    };
    for (NSString *k in @[@"container", @"pageContainer", @"pageContainerA",
                          @"pageContainerB", @"rPageContainer", @"readPageContainer",
                          @"curPageContainer"]) {
        @try { add([readerVC valueForKey:k]); } @catch (__unused NSException *e) {}
    }
    @try {
        id dpv = [readerVC valueForKey:@"dicPageVC"];
        if ([dpv isKindOfClass:[NSDictionary class]]) {
            for (id v in [(NSDictionary *)dpv allValues]) add(v);
        }
    } @catch (__unused NSException *e) {}
    if ([readerVC isKindOfClass:[UIViewController class]]) {
        for (UIViewController *ch in ((UIViewController *)readerVC).childViewControllers) {
            add(ch);
        }
    }
    id best = nil;
    NSInteger bestPrio = 99;
    for (id c in raw) {
        if (!LBObjectIsReadPageContainerLike(c)) continue;
        NSInteger p = LBReadPageContainerPriority(c);
        if (p < bestPrio) {
            bestPrio = p;
            best = c;
        }
    }
    return best;
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

    // 2) xsfolder 本地章文件 + localSourceText（供原版 queryCpFile 读缓存）
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

static BOOL LBHasNativeRenderEvidence(id reader, id container) {
    NSArray *hosts = @[container ?: [NSNull null], reader ?: [NSNull null]];
    for (id host in hosts) {
        if (host == (id)[NSNull null]) continue;
        @try {
            for (NSString *k in @[@"textViewL", @"textViewR", @"curPageTV"]) {
                id tv = nil;
                @try { tv = [host valueForKey:k]; } @catch (__unused NSException *e) {}
                if (!tv) continue;
                NSString *txt = nil;
                if ([tv respondsToSelector:@selector(text)]) {
                    txt = ((id (*)(id, SEL))objc_msgSend)(tv, @selector(text));
                } else {
                    @try { txt = [tv valueForKey:@"text"]; } @catch (__unused NSException *e) {}
                }
                if ([txt isKindOfClass:[NSString class]] && [(NSString *)txt length] > 20) {
                    return YES;
                }
                id pm = nil;
                @try { pm = [tv valueForKey:@"pageModel"]; } @catch (__unused NSException *e) {}
                if (pm) return YES;
                id fr = nil;
                @try { fr = [tv valueForKey:@"frameRef"]; } @catch (__unused NSException *e) {}
                if (fr) return YES;
            }
            id pvc = nil;
            @try { pvc = [host valueForKey:@"curPageVC"]; } @catch (__unused NSException *e) {}
            if (pvc) {
                for (NSString *k in @[@"textViewL", @"textViewR"]) {
                    id tv = nil;
                    @try { tv = [pvc valueForKey:k]; } @catch (__unused NSException *e) {}
                    if (tv) {
                        id pm = nil;
                        @try { pm = [tv valueForKey:@"pageModel"]; } @catch (__unused NSException *e) {}
                        if (pm) return YES;
                    }
                }
            }
        } @catch (__unused NSException *e) {}
    }
    return NO;
}

static void LBScheduleDivisionKickAfterInvoke(id reader, id container, NSDictionary *payload) {
    if (![payload isKindOfClass:[NSDictionary class]] || payload.count == 0) return;
    NSDictionary *payloadCopy = [payload copy];
    __weak id weakReader = reader;
    __weak id weakContainer = container;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (sState == LBLoadCurCpStateRendered) return;
        id r = weakReader;
        id c = weakContainer;
        if (LBHasNativeRenderEvidence(r, c)) {
            LBLoadCurCpBridgeMarkRendered();
            LBStateLog(@"division_kick_skip render_evidence");
            return;
        }
        LBStateLog(@"division_kick_begin");
        LBLoadCurCpBridgeKickDivisionChain(r, c, payloadCopy);
        if (LBHasNativeRenderEvidence(r, c)) {
            LBLoadCurCpBridgeMarkRendered();
            LBStateLog(@"division_kick_OK render_evidence");
        } else {
            LBStateLog(@"division_kick_done pending_render");
        }
    });
}

static void LBInvokeOriginalLoadCurCp(id reader) {
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

    id container = LBFindReadPageContainerForReader(reader);
    if (!container) {
        LBStateLog(@"invoke_skip reason=no_container");
        return;
    }
    NSString *containerName = NSStringFromClass(object_getClass(container));

    sReentryGuard = YES;
    sInvokeCount++;
    LBSetState(LBLoadCurCpStateInvokingOriginal, @"invoke_orig_begin");
    LBTraceLoadCurCp([NSString stringWithFormat:
                      @"sm=invokingOriginal ch=%@ target=%@ orig=%p",
                      sChapterUrl ?: @"-", containerName, sOrigLoadCurCp]);
    @try {
        sOrigLoadCurCp(container, @selector(loadCurCp));
        LBStateLog([NSString stringWithFormat:@"invoke_orig_OK target=%@", containerName]);
        LBTraceLoadCurCp(@"ORIG loadCurCp OK");
        if (sPendingPayload && LBBodyFromPayload(sPendingPayload).length > 0) {
            LBScheduleDivisionKickAfterInvoke(reader, container, sPendingPayload);
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
    if (!LBSeedConfirmedCache(reader, payload, paths)) {
        LBSetState(LBLoadCurCpStateFailed, @"cache_seed_failed");
        return;
    }
    LBStateLog([NSString stringWithFormat:@"cache_seeded %@", [paths componentsJoinedByString:@","]]);

    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            LBInvokeOriginalLoadCurCp(reader);
        });
    } else {
        LBInvokeOriginalLoadCurCp(reader);
    }
}

BOOL LBLoadCurCpBridgeHandleHook(id self, SEL _cmd,
                                 BOOL isLegado,
                                 NSString *bookUrl,
                                 NSString *sourceUrl,
                                 NSString *chapterUrl) {
    if (!isLegado) return NO;

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
        id readerVC = LBReaderVCFromContext(self) ?: self;
        LBTryContentReadyAndInvoke(readerVC, sPendingPayload);
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

    id reader = readerVC ?: sWeakReader;
    if (!reader) {
        LBSetState(LBLoadCurCpStateContentReady, @"contentReady_no_reader_yet");
        return;
    }
    LBTryContentReadyAndInvoke(reader, payload);
}
