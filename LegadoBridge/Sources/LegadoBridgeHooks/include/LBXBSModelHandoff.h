#ifndef LBXBSModelHandoff_h
#define LBXBSModelHandoff_h

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, LBXBSModelValidateResult) {
    LBXBSModelValidateValid = 0,
    LBXBSModelValidateWrongSource = 1,
    LBXBSModelValidateMissingBookWorld = 2,
    LBXBSModelValidateMissingAction = 3,
    LBXBSModelValidateMissingParser = 4,
    LBXBSModelValidateMissingRequest = 5,
    LBXBSModelValidateMissingList = 6,
    LBXBSModelValidateMissingFiltersWhenRequired = 7,
    LBXBSModelValidateThinBridgeShell = 8,
    LBXBSModelValidateLegadoProjection = 9,
    LBXBSModelValidateNilModel = 10,
};

/// 纯 validator：不访问 manager / 网络；不复制请求语义值到外部。
FOUNDATION_EXPORT LBXBSModelValidateResult LBValidateXBSModelShape(
    NSDictionary *_Nullable model,
    NSString *_Nullable expectedManagerKey,
    NSDictionary *_Nullable pristineIdentity);

FOUNDATION_EXPORT NSString *LBXBSModelValidateResultString(LBXBSModelValidateResult r);

/// 将 manager 同源完整模型写入宿主 declaring-class `_dicModel` ivar（合同路径）。
/// 禁止 KVC / setDicModel: fallback；失败恢复原指针。
FOUNDATION_EXPORT BOOL LBXBSHandoffWriteHostDicModel(
    UIViewController *_Nullable host,
    NSDictionary *_Nullable completeModel,
    NSString *_Nullable expectedManagerKey,
    NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END

#endif /* LBXBSModelHandoff_h */
