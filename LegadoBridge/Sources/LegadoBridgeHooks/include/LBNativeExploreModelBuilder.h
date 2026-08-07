#ifndef LBNativeExploreModelBuilder_h
#define LBNativeExploreModelBuilder_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// TC-07：结构常量（合同规定的 actionID/parserID；无 requestInfo/list 规则）。
FOUNDATION_EXPORT NSString * const LBNativeExploreAdapterSchema;
FOUNDATION_EXPORT NSString * const LBNativeExploreAdapterMarkerKey;
FOUNDATION_EXPORT NSString * const LBNativeExploreStructureActionID;
FOUNDATION_EXPORT NSString * const LBNativeExploreStructureParserID;

/// 无状态纯 builder：sanitized snapshot metadata → 宿主最小 mutable dictionaries。
/// 禁止访问 manager / SourceRegistry / 网络 / raw target。
@interface LBNativeExploreModelBuilder : NSObject

/// 从 24.6 sanitized metadata JSON 构建发现宿主 adapter model。
/// 输出不含 raw URL / Cookie / token / requestInfo / list 规则。
+ (NSDictionary *)adapterModelFromMetadataJSON:(NSData *)jsonData
                                         error:(NSError *_Nullable *_Nullable)error;

/// 单 channel：标签墙 titles（display）与 values（nodeID only）。
+ (NSArray<NSString *> *)tagTitlesFromChannel:(NSDictionary *)channel;
+ (NSArray<NSString *> *)tagNodeIDsFromChannel:(NSDictionary *)channel;

/// 结构完整性：必有 _lb_adapter / schema / snapshotID / sourceIdentityHash。
+ (BOOL)validateAdapterModel:(NSDictionary *)model
                       error:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END

#endif /* LBNativeExploreModelBuilder_h */
