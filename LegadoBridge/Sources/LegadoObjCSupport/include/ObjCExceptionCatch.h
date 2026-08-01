#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 捕获 NSException，避免穿过 Swift 导致 abort（真机 AnalyzeUrl.evalJS 曾因此杀进程）
@interface ObjCExceptionCatch : NSObject

+ (BOOL)run:(void(NS_NOESCAPE ^)(void))block
      error:(NSString * _Nullable * _Nullable)outError;

+ (nullable id)runReturning:(id _Nullable(NS_NOESCAPE ^)(void))block
                      error:(NSString * _Nullable * _Nullable)outError;

@end

NS_ASSUME_NONNULL_END
