#ifndef LBNativeBookNavigation_h
#define LBNativeBookNavigation_h

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const LBNativeBookNavigationErrorDomain;

typedef NS_ERROR_ENUM(LBNativeBookNavigationErrorDomain, LBNativeBookNavigationErrorCode) {
    LBNativeBookNavigationErrorBadArgs = 1,
    LBNativeBookNavigationErrorMissingBridgeMarker = 2,
    LBNativeBookNavigationErrorMissingPair = 3,
    LBNativeBookNavigationErrorInvalidToken = 4,
    LBNativeBookNavigationErrorUpsertFailed = 5,
    LBNativeBookNavigationErrorMissingBookKey = 6,
    LBNativeBookNavigationErrorMissingDetailABI = 7,
    LBNativeBookNavigationErrorNoNavigation = 8,
    LBNativeBookNavigationErrorNativeOrXBSRow = 9,
    LBNativeBookNavigationErrorDoublePushBlocked = 10,
    LBNativeBookNavigationErrorShelfMultiSourceUnsupported = 11,
};

/// 唯一原生 bookKey 入口：优先 AppConfig -getBookKey:，否则 -getBookKeyByBookName:author:。
/// 宿主 API 不可用时返回 nil（fail-closed）；禁止自制 name|author 公式。
FOUNDATION_EXPORT NSString *_Nullable LBNativeBookKeyForDictionary(NSDictionary *_Nullable book);

/// TC-03A：同名同作者多源在原生书架并存 — 合同 unsupported，恒为 NO。
FOUNDATION_EXPORT BOOL LBNativeShelfMultiSourceCoexistenceSupported(void);

/// Gate-A 详情 Router：create → setDicBook → setBookKey → 单次 push。
/// 要求显式 Bridge marker + exact pair；token 须为 lb2_ 且与 pair 一致（或由 upsert 生成）。
/// 禁止 CatalogCon / Bridge catalog / kill-file / 预取导航。
FOUNDATION_EXPORT BOOL LBOpenLegadoBookDetail(
    id _Nullable host,
    NSDictionary *_Nullable bookDictionary,
    NSString *_Nullable entryPoint,
    NSError *_Nullable *_Nullable error);

#if DEBUG
/// 测试：注入详情类名（默认 BookDetailController）；传 nil 恢复。
FOUNDATION_EXPORT void LBNativeNavSetDetailClassNameForTests(NSString *_Nullable className);
/// 测试：跳过 Core upsert（仅校验导航 ABI 顺序）；默认 NO。
FOUNDATION_EXPORT void LBNativeNavSetSkipUpsertForTests(BOOL skip);
/// 测试：重置防双 push 状态。
FOUNDATION_EXPORT void LBNativeNavResetPushGuardForTests(void);
#endif

NS_ASSUME_NONNULL_END

#endif /* LBNativeBookNavigation_h */
