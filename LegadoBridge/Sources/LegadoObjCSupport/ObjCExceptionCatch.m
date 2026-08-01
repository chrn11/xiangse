#import "ObjCExceptionCatch.h"

@implementation ObjCExceptionCatch

+ (BOOL)run:(void(NS_NOESCAPE ^)(void))block
      error:(NSString * _Nullable * _Nullable)outError {
    if (!block) {
        return YES;
    }
    @try {
        block();
        return YES;
    } @catch (NSException *ex) {
        if (outError) {
            NSString *reason = ex.reason ?: @"";
            *outError = [NSString stringWithFormat:@"%@: %@", ex.name, reason];
        }
        return NO;
    }
}

+ (nullable id)runReturning:(id _Nullable(NS_NOESCAPE ^)(void))block
                      error:(NSString * _Nullable * _Nullable)outError {
    if (!block) {
        return nil;
    }
    @try {
        return block();
    } @catch (NSException *ex) {
        if (outError) {
            NSString *reason = ex.reason ?: @"";
            *outError = [NSString stringWithFormat:@"%@: %@", ex.name, reason];
        }
        return nil;
    }
}

+ (nullable JSValue *)evaluateScript:(NSString *)script
                           inContext:(JSContext *)context
                               error:(NSString * _Nullable * _Nullable)outError {
    if (!context || script.length == 0) {
        return nil;
    }
    @try {
        return [context evaluateScript:script];
    } @catch (NSException *ex) {
        if (outError) {
            NSString *reason = ex.reason ?: @"";
            *outError = [NSString stringWithFormat:@"%@: %@", ex.name, reason];
        }
        return nil;
    }
}

+ (nullable NSString *)jsonStringLiteral:(NSString *)value
                                   error:(NSString * _Nullable * _Nullable)outError {
    NSString *input = value ?: @"";
    @try {
        NSError *serErr = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:input options:0 error:&serErr];
        if (!data) {
            if (outError) {
                *outError = serErr.localizedDescription ?: @"json serialize failed";
            }
            return nil;
        }
        return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    } @catch (NSException *ex) {
        if (outError) {
            NSString *reason = ex.reason ?: @"";
            *outError = [NSString stringWithFormat:@"%@: %@", ex.name, reason];
        }
        return nil;
    }
}

@end
