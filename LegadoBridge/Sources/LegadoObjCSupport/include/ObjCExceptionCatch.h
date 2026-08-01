#import <Foundation/Foundation.h>
#import <JavaScriptCore/JavaScriptCore.h>

NS_ASSUME_NONNULL_BEGIN

@interface ObjCExceptionCatch : NSObject

+ (BOOL)run:(void(NS_NOESCAPE ^)(void))block
      error:(NSString * _Nullable * _Nullable)outError;

+ (nullable id)runReturning:(id _Nullable(NS_NOESCAPE ^)(void))block
                      error:(NSString * _Nullable * _Nullable)outError;

/// 必须在 ObjC 内直接调 evaluateScript：NSException 穿过 Swift 帧会 abort，外层 @try 接不住
+ (nullable JSValue *)evaluateScript:(NSString *)script
                           inContext:(JSContext *)context
                               error:(NSString * _Nullable * _Nullable)outError;

/// JSON 字符串字面量（供嵌 eval）；NSJSONSerialization 也可能抛 NSException
+ (nullable NSString *)jsonStringLiteral:(NSString *)value
                                   error:(NSString * _Nullable * _Nullable)outError;

@end

NS_ASSUME_NONNULL_END
