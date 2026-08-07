#import "LBNativeBookNavigation.h"
#import "LBCoreAccess.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <pthread.h>

NSErrorDomain const LBNativeBookNavigationErrorDomain = @"LBNativeBookNavigationErrorDomain";

#if DEBUG
static NSString *sTestDetailClassName = nil;
static BOOL sSkipUpsertForTests = NO;
#endif

static NSString *sLastPushFingerprint = nil;
static CFAbsoluteTime sLastPushAt = 0;
static pthread_mutex_t sPushGuardMu = PTHREAD_MUTEX_INITIALIZER;

static void LBNavSetError(NSError **error, LBNativeBookNavigationErrorCode code, NSString *msg) {
    if (!error) return;
    *error = [NSError errorWithDomain:LBNativeBookNavigationErrorDomain
                                 code:code
                             userInfo:@{NSLocalizedDescriptionKey: msg ?: @"error"}];
}

static BOOL LBNavHasBridgeMarker(NSDictionary *book) {
    id m = book[@"legadoBridge"] ?: book[@"fromLegadoBridge"] ?: book[@"_lb_sourceType"];
    if ([m isKindOfClass:[NSNumber class]] && [(NSNumber *)m boolValue]) return YES;
    if ([m isKindOfClass:[NSString class]]) {
        NSString *s = [(NSString *)m lowercaseString];
        if ([s isEqualToString:@"1"] || [s isEqualToString:@"yes"] ||
            [s isEqualToString:@"true"] || [s isEqualToString:@"legado"]) {
            return YES;
        }
    }
    return NO;
}

static BOOL LBNavLooksExplicitNativeOrXBS(NSDictionary *book) {
    if (LBReadingDicLooksExplicitNativeXBS(book)) return YES;
    if (LBNavHasBridgeMarker(book)) return NO;
    id st = book[@"_lb_sourceType"];
    if ([st isKindOfClass:[NSString class]]) {
        NSString *s = [(NSString *)st lowercaseString];
        if ([s isEqualToString:@"native"] || [s isEqualToString:@"xbs"] ||
            [s isEqualToString:@"xiangse"]) {
            return YES;
        }
    }
    return NO;
}

static BOOL LBNavTokenLooksValid(NSString *token) {
    if (token.length < 8) return NO;
    if (![token hasPrefix:@"lb2_"]) return NO;
    NSString *hex = [token substringFromIndex:4];
    if (hex.length != 64) return NO;
    static NSCharacterSet *nonHex = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        nonHex = [[NSCharacterSet characterSetWithCharactersInString:
                   @"0123456789abcdef"] invertedSet];
    });
    return [hex.lowercaseString rangeOfCharacterFromSet:nonHex].location == NSNotFound;
}

static id LBNavAppConfigShared(void) {
    Class cls = NSClassFromString(@"AppConfig");
    if (!cls) return nil;
    SEL shared = NSSelectorFromString(@"shared");
    if (![cls respondsToSelector:shared]) {
        shared = NSSelectorFromString(@"sharedInstance");
    }
    if (![cls respondsToSelector:shared]) {
        shared = NSSelectorFromString(@"shareInstance");
    }
    if (![cls respondsToSelector:shared]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(cls, shared);
}

NSString *LBNativeBookKeyForDictionary(NSDictionary *book) {
    if (![book isKindOfClass:[NSDictionary class]]) return nil;
    id cfg = LBNavAppConfigShared();
    if (!cfg) return nil;

    SEL gk = NSSelectorFromString(@"getBookKey:");
    if ([cfg respondsToSelector:gk]) {
        @try {
            id k = ((id (*)(id, SEL, id))objc_msgSend)(cfg, gk, book);
            if ([k isKindOfClass:[NSString class]] && [(NSString *)k length] > 0) {
                return (NSString *)k;
            }
        } @catch (__unused NSException *e) {}
    }

    NSString *name = nil;
    for (NSString *key in @[@"bookName", @"name", @"title"]) {
        id v = book[key];
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) {
            name = (NSString *)v;
            break;
        }
    }
    NSString *author = [book[@"author"] isKindOfClass:[NSString class]] ? book[@"author"] : @"";
    if (name.length == 0) return nil;

    SEL gk2 = NSSelectorFromString(@"getBookKeyByBookName:author:");
    if ([cfg respondsToSelector:gk2]) {
        @try {
            id k = ((id (*)(id, SEL, id, id))objc_msgSend)(cfg, gk2, name, author);
            if ([k isKindOfClass:[NSString class]] && [(NSString *)k length] > 0) {
                return (NSString *)k;
            }
        } @catch (__unused NSException *e) {}
    }
    return nil;
}

BOOL LBNativeShelfMultiSourceCoexistenceSupported(void) {
    // TC-03A selectedBranch=unsupportedNativeBookKeyCollision
    return NO;
}

#if DEBUG
void LBNativeNavSetDetailClassNameForTests(NSString *className) {
    sTestDetailClassName = [className copy];
}
void LBNativeNavSetSkipUpsertForTests(BOOL skip) {
    sSkipUpsertForTests = skip;
}
void LBNativeNavResetPushGuardForTests(void) {
    pthread_mutex_lock(&sPushGuardMu);
    sLastPushFingerprint = nil;
    sLastPushAt = 0;
    pthread_mutex_unlock(&sPushGuardMu);
}
#endif

static NSString *LBNavDetailClassName(void) {
#if DEBUG
    if (sTestDetailClassName.length > 0) return sTestDetailClassName;
#endif
    return @"BookDetailController";
}

static BOOL LBNavUpsertBinding(NSMutableDictionary *detail, NSError **error) {
#if DEBUG
    if (sSkipUpsertForTests) {
        NSString *tok = LBReadingTokenFromDic(detail);
        if (!LBNavTokenLooksValid(tok)) {
            // 测试 harness：合成可校验占位（非生产路径）
            detail[@"legadoBridgeToken"] =
                @"lb2_0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        }
        return YES;
    }
#endif
    id core = LBLegadoCoreIfReady();
    if (!core) {
        LBNavSetError(error, LBNativeBookNavigationErrorUpsertFailed, @"core not ready");
        return NO;
    }
    NSString *bookUrl = LBReadingBookUrlFromDic(detail);
    NSString *sourceUrl = LBReadingSourceUrlFromDic(detail);
    NSString *token = LBReadingTokenFromDic(detail);
    if (![core respondsToSelector:@selector(rememberBookBindingWithBookUrl:sourceUrl:sourceName:name:author:coverUrl:bridgeToken:)]) {
        LBNavSetError(error, LBNativeBookNavigationErrorUpsertFailed, @"upsert ABI missing");
        return NO;
    }
    NSString *sourceName = nil;
    id sn = detail[@"sourceName"] ?: detail[@"bookSourceName"];
    if ([sn isKindOfClass:[NSString class]]) sourceName = sn;
    NSString *name = nil;
    id nm = detail[@"name"] ?: detail[@"bookName"];
    if ([nm isKindOfClass:[NSString class]]) name = nm;
    NSString *author = [detail[@"author"] isKindOfClass:[NSString class]] ? detail[@"author"] : nil;
    NSString *cover = nil;
    for (NSString *ck in @[@"coverUrl", @"cover"]) {
        id cv = detail[ck];
        if ([cv isKindOfClass:[NSString class]] && [(NSString *)cv length] > 0) {
            cover = cv;
            break;
        }
    }
    NSString *saved = ((NSString * (*)(id, SEL, NSString *, NSString *, NSString *, NSString *, NSString *, NSString *, NSString *))objc_msgSend)(
        core,
        @selector(rememberBookBindingWithBookUrl:sourceUrl:sourceName:name:author:coverUrl:bridgeToken:),
        bookUrl, sourceUrl, sourceName, name, author, cover, token
    );
    if (saved.length == 0 || !LBNavTokenLooksValid(saved)) {
        LBNavSetError(error, LBNativeBookNavigationErrorUpsertFailed, @"upsertAndFlush failed");
        return NO;
    }
    detail[@"legadoBridgeToken"] = saved;
    detail[@"bridgeToken"] = saved;
    LBReadingRememberPair(sourceUrl, bookUrl, saved);
    return YES;
}

static id LBNavCreateDetailController(NSError **error) {
    Class cls = NSClassFromString(LBNavDetailClassName());
    if (!cls) {
        LBNavSetError(error, LBNativeBookNavigationErrorMissingDetailABI, @"BookDetailController missing");
        return nil;
    }
    SEL createSel = NSSelectorFromString(@"create");
    id detail = nil;
    if ([cls respondsToSelector:createSel]) {
        @try {
            detail = ((id (*)(id, SEL))objc_msgSend)(cls, createSel);
        } @catch (__unused NSException *e) {
            detail = nil;
        }
    }
    if (!detail) {
        LBNavSetError(error, LBNativeBookNavigationErrorMissingDetailABI, @"+create failed");
        return nil;
    }
    return detail;
}

static BOOL LBNavApplyDicBookAndKey(id detail, NSDictionary *dic, NSString *bookKey, NSError **error) {
    SEL setDic = NSSelectorFromString(@"setDicBook:");
    if (![detail respondsToSelector:setDic]) {
        LBNavSetError(error, LBNativeBookNavigationErrorMissingDetailABI, @"setDicBook: missing");
        return NO;
    }
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(detail, setDic, dic);
    } @catch (NSException *e) {
        LBNavSetError(error, LBNativeBookNavigationErrorMissingDetailABI,
                      [NSString stringWithFormat:@"setDicBook: %@", e.reason ?: @""]);
        return NO;
    }

    SEL setKey = NSSelectorFromString(@"setBookKey:");
    if ([detail respondsToSelector:setKey] && bookKey.length > 0) {
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(detail, setKey, bookKey);
        } @catch (__unused NSException *e) {}
    }
    return YES;
}

static UINavigationController *LBNavFindNav(UIViewController *host) {
    if (host.navigationController) return host.navigationController;
    UIViewController *p = host.parentViewController;
    while (p) {
        if ([p isKindOfClass:[UINavigationController class]]) return (UINavigationController *)p;
        if (p.navigationController) return p.navigationController;
        p = p.parentViewController;
    }
    return nil;
}

static BOOL LBNavPushOnce(UIViewController *host, UIViewController *detail,
                          NSString *fingerprint, NSError **error) {
    pthread_mutex_lock(&sPushGuardMu);
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (sLastPushFingerprint.length > 0 &&
        [sLastPushFingerprint isEqualToString:fingerprint] &&
        (now - sLastPushAt) < 0.8) {
        pthread_mutex_unlock(&sPushGuardMu);
        LBNavSetError(error, LBNativeBookNavigationErrorDoublePushBlocked, @"double push blocked");
        return NO;
    }
    UINavigationController *nav = LBNavFindNav(host);
    if (!nav) {
        pthread_mutex_unlock(&sPushGuardMu);
        LBNavSetError(error, LBNativeBookNavigationErrorNoNavigation, @"no UINavigationController");
        return NO;
    }
    @try {
        [nav pushViewController:detail animated:YES];
    } @catch (NSException *e) {
        pthread_mutex_unlock(&sPushGuardMu);
        LBNavSetError(error, LBNativeBookNavigationErrorNoNavigation,
                      [NSString stringWithFormat:@"push failed: %@", e.reason ?: @""]);
        return NO;
    }
    sLastPushFingerprint = [fingerprint copy];
    sLastPushAt = now;
    pthread_mutex_unlock(&sPushGuardMu);
    return YES;
}

BOOL LBOpenLegadoBookDetail(id host,
                            NSDictionary *bookDictionary,
                            NSString *entryPoint,
                            NSError **error) {
    if (error) *error = nil;
    if (![host isKindOfClass:[UIViewController class]] ||
        ![bookDictionary isKindOfClass:[NSDictionary class]]) {
        LBNavSetError(error, LBNativeBookNavigationErrorBadArgs, @"host/book invalid");
        return NO;
    }
    (void)entryPoint;

    if (LBNavLooksExplicitNativeOrXBS(bookDictionary)) {
        LBNavSetError(error, LBNativeBookNavigationErrorNativeOrXBSRow,
                      @"native/XBS row must not enter Legado detail router");
        return NO;
    }
    if (!LBNavHasBridgeMarker(bookDictionary)) {
        LBNavSetError(error, LBNativeBookNavigationErrorMissingBridgeMarker, @"missing Bridge marker");
        return NO;
    }

    NSString *bookUrl = LBReadingBookUrlFromDic(bookDictionary);
    NSString *sourceUrl = LBReadingSourceUrlFromDic(bookDictionary);
    if (bookUrl.length == 0 || sourceUrl.length == 0) {
        LBNavSetError(error, LBNativeBookNavigationErrorMissingPair, @"exact pair required");
        return NO;
    }

    NSString *token = LBReadingTokenFromDic(bookDictionary);
    if (token.length > 0 && !LBNavTokenLooksValid(token)) {
        LBNavSetError(error, LBNativeBookNavigationErrorInvalidToken, @"token must be lb2_");
        return NO;
    }

    NSMutableDictionary *detail = [NSMutableDictionary dictionaryWithDictionary:bookDictionary];
    detail[@"legadoBridge"] = @"1";
    detail[@"fromLegadoBridge"] = @YES;
    detail[@"bookUrl"] = bookUrl;
    detail[@"sourceUrl"] = sourceUrl;
    // 禁止伪造章节/目录
    [detail removeObjectForKey:@"arrCatalog"];
    [detail removeObjectForKey:@"arrSource"];
    [detail removeObjectForKey:@"chapters"];

    if (!LBNavUpsertBinding(detail, error)) {
        return NO;
    }

    NSString *bookKey = LBNativeBookKeyForDictionary(detail);
#if DEBUG
    if (sSkipUpsertForTests && bookKey.length == 0) {
        // AppConfig 在单测中常缺失：仅 harness 允许用稳定占位，生产仍 fail-closed
        bookKey = @"test_book_key";
        detail[@"bookKey"] = bookKey;
    }
#endif
    if (bookKey.length == 0) {
        LBNavSetError(error, LBNativeBookNavigationErrorMissingBookKey,
                      @"AppConfig bookKey API unavailable");
        return NO;
    }
    detail[@"bookKey"] = bookKey;

    __block BOOL ok = NO;
    __block NSError *localErr = nil;
    void (^work)(void) = ^{
        id vc = LBNavCreateDetailController(&localErr);
        if (!vc) {
            ok = NO;
            return;
        }
        if (![vc isKindOfClass:[UIViewController class]]) {
            LBNavSetError(&localErr, LBNativeBookNavigationErrorMissingDetailABI, @"create not VC");
            ok = NO;
            return;
        }
        if (!LBNavApplyDicBookAndKey(vc, [detail copy], bookKey, &localErr)) {
            ok = NO;
            return;
        }
        NSString *fp = [NSString stringWithFormat:@"%@|%@|%@", bookUrl, sourceUrl,
                        LBReadingTokenFromDic(detail) ?: @""];
        ok = LBNavPushOnce((UIViewController *)host, (UIViewController *)vc, fp, &localErr);
    };

    if ([NSThread isMainThread]) {
        work();
    } else {
        dispatch_sync(dispatch_get_main_queue(), work);
    }
    if (!ok && error && localErr) *error = localErr;
    return ok;
}
