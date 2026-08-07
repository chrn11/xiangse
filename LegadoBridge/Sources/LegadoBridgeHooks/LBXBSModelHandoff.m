#import "LBXBSModelHandoff.h"
#import <objc/runtime.h>

NSString *LBXBSModelValidateResultString(LBXBSModelValidateResult r) {
    switch (r) {
        case LBXBSModelValidateValid: return @"valid";
        case LBXBSModelValidateWrongSource: return @"wrongSource";
        case LBXBSModelValidateMissingBookWorld: return @"missingBookWorld";
        case LBXBSModelValidateMissingAction: return @"missingAction";
        case LBXBSModelValidateMissingParser: return @"missingParser";
        case LBXBSModelValidateMissingRequest: return @"missingRequest";
        case LBXBSModelValidateMissingList: return @"missingList";
        case LBXBSModelValidateMissingFiltersWhenRequired: return @"missingFiltersWhenRequired";
        case LBXBSModelValidateThinBridgeShell: return @"thinBridgeShell";
        case LBXBSModelValidateLegadoProjection: return @"legadoProjection";
        case LBXBSModelValidateNilModel: return @"nilModel";
    }
    return @"unknown";
}

static BOOL LBXBSLooksLegadoProjection(NSDictionary *model) {
    id marker = model[@"legadoBridge"] ?: model[@"_lb_adapter"] ?: model[@"_lb_sourceType"];
    if ([marker isKindOfClass:[NSString class]]) {
        NSString *s = (NSString *)marker;
        if ([s isEqualToString:@"1"] || [s isEqualToString:@"legado"]) return YES;
    }
    if ([marker isKindOfClass:[NSNumber class]] && [(NSNumber *)marker boolValue]) return YES;
    if ([model[@"_lb_sourceType"] isEqual:@"legado"]) return YES;
    return NO;
}

static BOOL LBXBSLooksThinThreeKeyShell(NSDictionary *model) {
    // 已知 Bridge 薄壳：仅少量键且无 bookWorld
    NSArray *keys = model.allKeys;
    if (keys.count > 6) return NO;
    if ([model[@"bookWorld"] isKindOfClass:[NSDictionary class]] &&
        [(NSDictionary *)model[@"bookWorld"] count] > 0) {
        return NO;
    }
    // 典型三键/无 marker 空壳
    return keys.count <= 3;
}

LBXBSModelValidateResult LBValidateXBSModelShape(
    NSDictionary *model,
    NSString *expectedManagerKey,
    NSDictionary *pristineIdentity
) {
    (void)pristineIdentity;
    if (![model isKindOfClass:[NSDictionary class]]) {
        return LBXBSModelValidateNilModel;
    }
    if (LBXBSLooksLegadoProjection(model)) {
        return LBXBSModelValidateLegadoProjection;
    }
    if (LBXBSLooksThinThreeKeyShell(model)) {
        return LBXBSModelValidateThinBridgeShell;
    }
    if (expectedManagerKey.length > 0) {
        NSString *name = nil;
        id cf = model[@"cf_title"] ?: model[@"sourceName"] ?: model[@"bookSourceName"];
        if ([cf isKindOfClass:[NSString class]]) name = (NSString *)cf;
        // 允许 key 与 cf_title 一致；不一致不一定失败（manager key 由调用方保证同源 lookup）
        (void)name;
    }
    id bw = model[@"bookWorld"];
    if (![bw isKindOfClass:[NSDictionary class]] || [(NSDictionary *)bw count] == 0) {
        return LBXBSModelValidateMissingBookWorld;
    }
    // 逐 channel/entry 检查结构：至少有一个 entry 含 actionID=bookWorld + parser + request + list
    NSDictionary *bookWorld = (NSDictionary *)bw;
    BOOL anyComplete = NO;
    BOOL sawMissingAction = NO;
    BOOL sawMissingParser = NO;
    BOOL sawMissingRequest = NO;
    BOOL sawMissingList = NO;
    for (id key in bookWorld) {
        id entry = bookWorld[key];
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *e = (NSDictionary *)entry;
        id action = e[@"actionID"] ?: e[@"actionId"];
        if (![action isKindOfClass:[NSString class]] ||
            ![(NSString *)action isEqualToString:@"bookWorld"]) {
            sawMissingAction = YES;
            continue;
        }
        id parser = e[@"parserID"] ?: e[@"parserId"] ?: e[@"parser"];
        if (parser == nil || ([parser isKindOfClass:[NSString class]] && [(NSString *)parser length] == 0)) {
            sawMissingParser = YES;
            continue;
        }
        id req = e[@"requestInfo"];
        if (req == nil || ([req isKindOfClass:[NSString class]] && [(NSString *)req length] == 0)) {
            sawMissingRequest = YES;
            continue;
        }
        id list = e[@"list"];
        if (list == nil) {
            sawMissingList = YES;
            continue;
        }
        anyComplete = YES;
        break;
    }
    if (anyComplete) return LBXBSModelValidateValid;
    if (sawMissingAction) return LBXBSModelValidateMissingAction;
    if (sawMissingParser) return LBXBSModelValidateMissingParser;
    if (sawMissingRequest) return LBXBSModelValidateMissingRequest;
    if (sawMissingList) return LBXBSModelValidateMissingList;
    return LBXBSModelValidateMissingBookWorld;
}

static Ivar LBXBSFindDicModelIvar(Class cls) {
    while (cls && cls != [NSObject class]) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *name = ivar_getName(ivars[i]);
            if (name && strcmp(name, "_dicModel") == 0) {
                Ivar found = ivars[i];
                free(ivars);
                return found;
            }
        }
        if (ivars) free(ivars);
        cls = class_getSuperclass(cls);
    }
    return NULL;
}

BOOL LBXBSHandoffWriteHostDicModel(
    UIViewController *host,
    NSDictionary *completeModel,
    NSString *expectedManagerKey,
    NSError **error
) {
    if (!host) {
        if (error) {
            *error = [NSError errorWithDomain:@"LBXBSModelHandoff" code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"nil host"}];
        }
        return NO;
    }
    LBXBSModelValidateResult vr = LBValidateXBSModelShape(completeModel, expectedManagerKey, nil);
    if (vr != LBXBSModelValidateValid) {
        if (error) {
            *error = [NSError errorWithDomain:@"LBXBSModelHandoff" code:2
                                     userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"model %@",
                                            LBXBSModelValidateResultString(vr)]
            }];
        }
        return NO;
    }
    Ivar iv = LBXBSFindDicModelIvar(object_getClass(host));
    if (!iv) {
        if (error) {
            *error = [NSError errorWithDomain:@"LBXBSModelHandoff" code:3
                                     userInfo:@{NSLocalizedDescriptionKey: @"_dicModel ivar missing"}];
        }
        return NO;
    }
    id previous = object_getIvar(host, iv);
    // 已是同源完整：no-op
    if ([previous isKindOfClass:[NSDictionary class]]) {
        LBXBSModelValidateResult cur = LBValidateXBSModelShape((NSDictionary *)previous, expectedManagerKey, nil);
        if (cur == LBXBSModelValidateValid) {
            return YES;
        }
    }
    NSDictionary *copy = [[NSDictionary alloc] initWithDictionary:completeModel copyItems:YES];
    object_setIvar(host, iv, copy);
    id readBack = object_getIvar(host, iv);
    LBXBSModelValidateResult after = LBValidateXBSModelShape(
        [readBack isKindOfClass:[NSDictionary class]] ? (NSDictionary *)readBack : nil,
        expectedManagerKey,
        nil
    );
    if (after != LBXBSModelValidateValid) {
        object_setIvar(host, iv, previous);
        if (error) {
            *error = [NSError errorWithDomain:@"LBXBSModelHandoff" code:4
                                     userInfo:@{NSLocalizedDescriptionKey: @"readback failed; restored"}];
        }
        return NO;
    }
    return YES;
}
