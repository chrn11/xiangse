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

/// 假设 Q：loadCurCp callee 还含 arrCatalog/count；缺目录或 curCpIndex 错位会跳过 query
/// 假设 R：curCpIndex 必须写到 container/pageModel 的标量 ivar；Q 日志曾见 curCpIndex=-1
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

    for (id tgt in @[reader,
                     container ?: [NSNull null],
                     curPage ?: [NSNull null],
                     pageModel ?: [NSNull null]]) {
        if (tgt == (id)[NSNull null]) continue;
        LBSetIntegerKey(tgt, @"curCpIndex", cpIndex);
        LBSetIntegerKey(tgt, @"nCpIndex", cpIndex);
    }
    // 假设 S：pageStatus 在 ReadPageModel；未初始化可能导致 loadCurCp 早退
    if (pageModel) {
        LBSetIntegerKey(pageModel, @"pageStatus", 0);
        LBStateLog(@"hypothesis_S set pageStatus=0 on pageModel");
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
}

static void LBLogLoadCurCpGates(id reader, id container, NSString *tag) {
    NSUInteger nCat = 0, nDc = 0, nDcC = 0;
    NSString *bookKey = @"-";
    NSString *bookDir = @"-";
    NSInteger curR = -999, curC = -999, nCp = -999;
    @try { nCat = LBCountOrZero([reader valueForKey:@"arrCatalog"]); } @catch (__unused NSException *e) {}
    @try { nDc = LBCountOrZero([reader valueForKey:@"dicContents"]); } @catch (__unused NSException *e) {}
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

    LBStateLog([NSString stringWithFormat:
                @"hypothesis_R gates(%@) arrCatalog=%lu dicContents=%lu dicContents@c=%lu "
                @"bookKeyLen=%lu bookDirLen=%lu curCp@r=%ld curCp@c=%ld nCp@pm=%ld pageStatus=%ld",
                tag ?: @"-",
                (unsigned long)nCat, (unsigned long)nDc, (unsigned long)nDcC,
                (unsigned long)bookKey.length, (unsigned long)bookDir.length,
                (long)curR, (long)curC, (long)nCp, (long)pageStatus]);
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

    id container = LBFindReadPageContainerForReader(reader);
    if (!container) {
        LBStateLog(@"invoke_skip reason=no_container");
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
    if ((!curPage || !attached) && !forceWithoutCurPage) {
        LBStateLog([NSString stringWithFormat:
                    @"hypothesis_T defer_invoke curPage=%d attached=%d",
                    curPage ? 1 : 0, attached ? 1 : 0]);
        LBScheduleInvokeWhenPageReady(reader, 0);
        return;
    }

    if (sPendingPayload) {
        LBEnsureLoadCurCpPrereqs(reader, container, sPendingPayload);
    }

    // 就绪后再 seed 一次，确保 dicContents/bookDir 落在最终 container
    if (sPendingPayload) {
        NSMutableArray *paths = [NSMutableArray array];
        if (LBSeedConfirmedCache(reader, sPendingPayload, paths)) {
            LBStateLog([NSString stringWithFormat:@"hypothesis_P reseed %@",
                        [paths componentsJoinedByString:@","]]);
        }
        // 假设 R：reseed 后再写一次 index，并打 post_seed gates
        LBEnsureLoadCurCpPrereqs(reader, container, sPendingPayload);
        LBLogLoadCurCpGates(reader, container, @"post_seed");
    } else {
        LBLogLoadCurCpGates(reader, container, @"no_payload");
    }

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
    if (attempt >= 20) {
        LBStateLog(@"hypothesis_T defer_giveup force_invoke attached/curPage timeout");
        LBInvokeOriginalLoadCurCp(reader, YES);
        return;
    }
    __weak id weakReader = reader;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        id strong = weakReader;
        if (!strong) return;
        id container = LBFindReadPageContainerForReader(strong);
        id curPage = LBContainerCurPageVC(container);
        BOOL attached = LBReaderIsAttachedToUI(strong);
        LBStateLog([NSString stringWithFormat:
                    @"hypothesis_T defer_tick attempt=%ld curPageVC=%@ attached=%d",
                    (long)attempt,
                    curPage ? NSStringFromClass(object_getClass(curPage)) : @"nil",
                    attached ? 1 : 0]);
        if (curPage && attached) {
            LBInvokeOriginalLoadCurCp(strong, NO);
        } else {
            LBScheduleInvokeWhenPageReady(strong, attempt + 1);
        }
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
    if (!LBSeedConfirmedCache(reader, payload, paths)) {
        LBSetState(LBLoadCurCpStateFailed, @"cache_seed_failed");
        return;
    }
    LBStateLog([NSString stringWithFormat:@"cache_seeded %@", [paths componentsJoinedByString:@","]]);

    void (^go)(void) = ^{
        LBInvokeOriginalLoadCurCp(reader, NO);
    };
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), go);
    } else {
        go();
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
        // 假设 T5：loadViewIfNeeded 内 hook 只拦截原生 loadCurCp，不在 push 前 invoke
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

    id reader = readerVC ?: sWeakReader;
    if (!reader) {
        LBSetState(LBLoadCurCpStateContentReady, @"contentReady_no_reader_yet");
        return;
    }
    LBTryContentReadyAndInvoke(reader, payload);
}
