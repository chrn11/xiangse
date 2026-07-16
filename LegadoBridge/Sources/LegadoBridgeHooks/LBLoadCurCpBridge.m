#import "LBLoadCurCpBridge.h"
#import "LBInternal.h"
#import <objc/message.h>
#import <dlfcn.h>

static void (*sOrigLoadCurCp)(id, SEL) = NULL;
static LBLoadCurCpState sState = LBLoadCurCpStateIdle;
static NSString *sToken = nil;
static NSString *sChapterUrl = nil;
static NSString *sBookUrl = nil;
static NSString *sSourceUrl = nil;
static NSInteger sCpIndex = 0;
static NSUInteger sInvokeCount = 0;
static NSDictionary *sPendingPayload = nil;
static __weak id sWeakReader = nil;
static BOOL sReentryGuard = NO;
static int sRetryToken = 0;

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
    if (orig && !sOrigLoadCurCp) sOrigLoadCurCp = orig;
}

void LBLoadCurCpBridgeReset(NSString *reason) {
    sToken = nil;
    sChapterUrl = nil;
    sBookUrl = nil;
    sSourceUrl = nil;
    sCpIndex = 0;
    sInvokeCount = 0;
    sPendingPayload = nil;
    sWeakReader = nil;
    sReentryGuard = NO;
    sRetryToken++;
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

static NSInteger LBCpIndexFromPayload(NSDictionary *payload, id reader) {
    id cpi = payload[@"cpIndex"] ?: payload[@"index"];
    if ([cpi respondsToSelector:@selector(integerValue)]) return [cpi integerValue];
    @try {
        id cur = [reader valueForKey:@"curCpIndex"];
        if ([cur respondsToSelector:@selector(integerValue)]) return [cur integerValue];
    } @catch (__unused NSException *e) {}
    return 0;
}

static NSString *LBChapterUrlFromReader(id reader) {
    if (!reader) return nil;
    for (NSString *key in @[@"chapterUrl", @"url", @"curChapterUrl", @"cpUrl"]) {
        @try {
            id v = [reader valueForKey:key];
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) return v;
        } @catch (__unused NSException *e) {}
    }
    NSDictionary *dic = LBReadingDicFromObject(reader);
    if (dic) {
        for (NSString *key in @[@"chapterUrl", @"url", @"cpUrl"]) {
            id v = dic[key];
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) return v;
        }
    }
    return nil;
}

static NSString *LBBookUrlFromReader(id reader) {
    NSDictionary *dic = LBReadingDicFromObject(reader);
    NSString *u = LBReadingBookUrlFromDic(dic);
    if (u.length > 0) return u;
    @try {
        id v = [reader valueForKey:@"bookUrl"];
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) return v;
    } @catch (__unused NSException *e) {}
    return nil;
}

/// confirmed 边界：dicContents / xsfolder / setCpCached（禁 UI / pageModel）
static BOOL LBSeedConfirmedCache(id reader, NSDictionary *payload, NSMutableArray *paths) {
    if (!reader || ![payload isKindOfClass:[NSDictionary class]]) return NO;
    NSString *body = LBBodyFromPayload(payload);
    if (body.length == 0) return NO;

    NSString *title = payload[@"cpTitle"] ?: payload[@"title"] ?: @"章节";
    if (![title isKindOfClass:[NSString class]] || title.length == 0) title = @"章节";
    NSInteger cpIndex = LBCpIndexFromPayload(payload, reader);
    sCpIndex = cpIndex;

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
    } @catch (__unused NSException *e) {}

    // 2) xsfolder 本地章文件
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
        [paths addObject:@"xsfolder"];
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
    if (sourceUrl.length > 0) sSourceUrl = [sourceUrl copy];
    id core = LBLegadoCoreIfReady();
    if (![core respondsToSelector:@selector(handleContentRequestWithChapterUrl:bookUrl:sourceUrl:)]) return;
    ((void (*)(id, SEL, NSString *, NSString *, NSString *))objc_msgSend)(
        core, @selector(handleContentRequestWithChapterUrl:bookUrl:sourceUrl:),
        chapterUrl, bookUrl, sourceUrl ?: @""
    );
}

static void LBInvokeOriginalLoadCurCp(id reader) {
    if (!reader || !sOrigLoadCurCp || sReentryGuard) {
        LBTraceLoadCurCp([NSString stringWithFormat:@"ORIG loadCurCp SKIP reader=%d orig=%d guard=%d",
                          reader ? 1 : 0, sOrigLoadCurCp ? 1 : 0, sReentryGuard ? 1 : 0]);
        return;
    }
    if (sState == LBLoadCurCpStateInvokingOriginal || sState == LBLoadCurCpStateRendered) {
        LBStateLog(@"invoke_skip_state");
        return;
    }

    sReentryGuard = YES;
    sInvokeCount++;
    LBSetState(LBLoadCurCpStateInvokingOriginal, @"invoke_orig_begin");
    LBTraceLoadCurCp([NSString stringWithFormat:@"sm=invokingOriginal ch=%@ idx=%ld",
                      sChapterUrl ?: @"-", (long)sCpIndex]);
    @try {
        sOrigLoadCurCp(reader, @selector(loadCurCp));
        LBStateLog(@"invoke_orig_OK");
        LBTraceLoadCurCp(@"ORIG loadCurCp OK");
    } @catch (NSException *ex) {
        LBSetState(LBLoadCurCpStateFailed, [NSString stringWithFormat:@"invoke_orig_EX %@", ex.reason ?: @""]);
        LBTraceLoadCurCp([NSString stringWithFormat:@"ORIG loadCurCp EX %@", ex.reason ?: @""]);
        sReentryGuard = NO;
        return;
    }
    sReentryGuard = NO;
    if (sState == LBLoadCurCpStateInvokingOriginal) {
        LBSetState(LBLoadCurCpStateContentReady, @"invoke_orig_done_pending_render");
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

    void (^invokeBlock)(void) = ^{
        LBInvokeOriginalLoadCurCp(reader);
    };
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), invokeBlock);
    } else {
        invokeBlock();
    }
}

static void LBScheduleReaderRetry(int token) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (token != sRetryToken) return;
        id reader = sWeakReader;
        if (!reader) return;
        if (sPendingPayload && LBBodyFromPayload(sPendingPayload).length > 0 &&
            sState != LBLoadCurCpStateInvokingOriginal && sState != LBLoadCurCpStateRendered) {
            LBStateLog(@"retry_pending_reader");
            LBTryContentReadyAndInvoke(reader, sPendingPayload);
        }
    });
}

BOOL LBLoadCurCpBridgeHandleHook(id self, SEL _cmd,
                                 BOOL isLegado,
                                 NSString *bookUrl,
                                 NSString *sourceUrl,
                                 NSString *chapterUrl) {
    if (!isLegado) return NO;

    sWeakReader = self;
    if (bookUrl.length > 0) sBookUrl = [bookUrl copy];
    if (sourceUrl.length > 0) sSourceUrl = [sourceUrl copy];
    if (chapterUrl.length == 0) chapterUrl = LBChapterUrlFromReader(self);
    if (chapterUrl.length > 0) {
        sChapterUrl = [chapterUrl copy];
        sToken = [chapterUrl copy];
    }

    if (sState == LBLoadCurCpStateInvokingOriginal || sState == LBLoadCurCpStateRendered) {
        LBStateLog(@"hook_skip_reentry");
        return YES;
    }

    if (sPendingPayload && LBBodyFromPayload(sPendingPayload).length > 0 &&
        sState != LBLoadCurCpStateFetching) {
        LBTryContentReadyAndInvoke(self, sPendingPayload);
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

    LBStateLog(@"hook_wait_urls");
    return YES;
}

void LBLoadCurCpBridgeOnContentPosted(NSDictionary *payload, id readerVC) {
    if (![payload isKindOfClass:[NSDictionary class]] || payload.count == 0) return;
    if (payload[@"error"]) {
        LBSetState(LBLoadCurCpStateFailed, [NSString stringWithFormat:@"content_err %@", payload[@"error"]]);
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
    id sourceUrl = payload[@"sourceUrl"];
    if ([sourceUrl isKindOfClass:[NSString class]]) sSourceUrl = sourceUrl;

    id reader = readerVC ?: sWeakReader;
    if (!reader) {
        LBSetState(LBLoadCurCpStateContentReady, @"contentReady_no_reader_yet");
        int token = sRetryToken;
        LBScheduleReaderRetry(token);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (token != sRetryToken) return;
            LBScheduleReaderRetry(token);
        });
        return;
    }
    LBTryContentReadyAndInvoke(reader, payload);
}

void LBLoadCurCpBridgeReaderActivated(id reader) {
    if (!reader) return;
    sWeakReader = reader;
    NSString *bookUrl = sBookUrl.length > 0 ? sBookUrl : LBBookUrlFromReader(reader);
    NSString *chapterUrl = sChapterUrl.length > 0 ? sChapterUrl : LBChapterUrlFromReader(reader);
    NSString *sourceUrl = sSourceUrl.length > 0 ? sSourceUrl : LBReadingSourceUrlForBookUrl(bookUrl);
    if (bookUrl.length > 0) sBookUrl = bookUrl;
    if (chapterUrl.length > 0) {
        sChapterUrl = chapterUrl;
        sToken = chapterUrl;
    }
    if (sourceUrl.length > 0) sSourceUrl = sourceUrl;

    LBStateLog([NSString stringWithFormat:@"reader_activated cls=%@",
                NSStringFromClass([reader class])]);

    if (sPendingPayload && LBBodyFromPayload(sPendingPayload).length > 0 &&
        sState != LBLoadCurCpStateInvokingOriginal && sState != LBLoadCurCpStateRendered) {
        LBTryContentReadyAndInvoke(reader, sPendingPayload);
        return;
    }

    if (sState == LBLoadCurCpStateFetching || sState == LBLoadCurCpStateContentReady) {
        return;
    }

    LBLoadCurCpBridgeHandleHook(reader, @selector(loadCurCp), YES, bookUrl, sourceUrl, chapterUrl);
}
