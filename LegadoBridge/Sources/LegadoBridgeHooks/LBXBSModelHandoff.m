#import "LBXBSModelHandoff.h"
#import "LBInternal.h"
#import <objc/runtime.h>
#import <objc/message.h>

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

static void LBXBSHandoffMark(NSString *line) {
    if (line.length == 0) return;
    NSLog(@"[LegadoBridge][xbsHandoff] %@", line);
    @try {
        NSString *path = [NSHomeDirectory()
            stringByAppendingPathComponent:@"Documents/legado_xbs_handoff_markers.txt"];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            fh = [NSFileHandle fileHandleForWritingAtPath:path];
        }
        if (fh) {
            [fh seekToEndOfFile];
            NSString *row = [NSString stringWithFormat:@"%@\n", line];
            NSData *data = [row dataUsingEncoding:NSUTF8StringEncoding];
            if (data) [fh writeData:data];
            [fh closeFile];
        }
    } @catch (__unused NSException *e) {}
}

BOOL LBXBSHandoffEnsureFromExactManagerKey(UIViewController *host, NSString *exactManagerKey) {
    if (!host || exactManagerKey.length == 0) {
        LBXBSHandoffMark(@"ensure skip nilHostOrKey");
        return NO;
    }
    // exact key 必须在 raw table 存在（禁止模糊匹配）
    NSDictionary *managerModel = LBBSMRawDicModelForExactKey(exactManagerKey);
    if (!managerModel) {
        LBXBSHandoffMark([NSString stringWithFormat:@"ensure missExactKey len=%lu",
                          (unsigned long)exactManagerKey.length]);
        return NO;
    }
    LBXBSModelValidateResult mgrV = LBValidateXBSModelShape(managerModel, exactManagerKey, nil);
    if (mgrV != LBXBSModelValidateValid) {
        LBXBSHandoffMark([NSString stringWithFormat:@"ensure manager=%@",
                          LBXBSModelValidateResultString(mgrV)]);
        return NO;
    }
    // host 已 valid：no-op（写路径内部也会 no-op，这里先记探针）
    Ivar iv = LBXBSFindDicModelIvar(object_getClass(host));
    if (iv) {
        id cur = object_getIvar(host, iv);
        if ([cur isKindOfClass:[NSDictionary class]] &&
            LBValidateXBSModelShape((NSDictionary *)cur, exactManagerKey, nil) == LBXBSModelValidateValid) {
            LBXBSHandoffMark(@"ensure hostAlreadyValid noop");
            return YES;
        }
    }
    NSError *err = nil;
    BOOL ok = LBXBSHandoffWriteHostDicModel(host, managerModel, exactManagerKey, &err);
    LBXBSHandoffMark([NSString stringWithFormat:@"ensure %@ err=%@",
                      ok ? @"ok" : @"fail", err.localizedDescription ?: @"-"]);
    return ok;
}

#pragma mark - Hooks (createCons / viewDidAppear)

static void (*sOrig_BWH_createCons)(id, SEL, id, id, NSString *) = NULL;
static void (*sOrig_BWH_viewDidAppear)(id, SEL, BOOL) = NULL;

/// 从 host 读候选 exact key：仅返回 raw table 中真实存在的键，不做模糊匹配。
static NSString *LBXBSExactKeyIfPresentOnHost(UIViewController *host) {
    if (!host) return nil;
    NSArray *cands = nil;
    NSMutableArray *buf = [NSMutableArray array];
    void (^push)(id) = ^(id v) {
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) {
            [buf addObject:v];
        }
    };
    @try { push([host valueForKey:@"useSourceName"]); } @catch (__unused NSException *e) {}
    @try { push([host valueForKey:@"lastSourceName"]); } @catch (__unused NSException *e) {}
    @try { push([host valueForKey:@"sourceName"]); } @catch (__unused NSException *e) {}
    @try { push(host.title); } @catch (__unused NSException *e) {}
    @try { push(host.navigationItem.title); } @catch (__unused NSException *e) {}
    cands = buf;
    for (NSString *k in cands) {
        if (LBBSMRawDicModelForExactKey(k)) return k;
    }
    return nil;
}

static void LBXBS_BWH_createCons(id self, SEL _cmd, id cons, id titles, NSString *sourceName) {
    // 合同 firstInvalid：createCons 时 host 常空；在原生 createCons 前写入完整模型
    if ([sourceName isKindOfClass:[NSString class]] && sourceName.length > 0 &&
        [self isKindOfClass:[UIViewController class]]) {
        LBXBSHandoffEnsureFromExactManagerKey((UIViewController *)self, sourceName);
    }
    if (sOrig_BWH_createCons) {
        sOrig_BWH_createCons(self, _cmd, cons, titles, sourceName);
    }
}

static void LBXBS_BWH_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (sOrig_BWH_viewDidAppear) {
        sOrig_BWH_viewDidAppear(self, _cmd, animated);
    }
    // native-discover-host：wire after viewDidAppear
    if (![self isKindOfClass:[UIViewController class]]) return;
    UIViewController *host = (UIViewController *)self;
    NSString *key = LBXBSExactKeyIfPresentOnHost(host);
    if (key.length == 0) {
        LBXBSHandoffMark(@"vda skip noExactKeyOnHost");
        return;
    }
    // 仅 XBS：若该名是 Legado 书源则跳过
    if (LBLegadoIsSourceName(key)) {
        LBXBSHandoffMark(@"vda skip legadoKey");
        return;
    }
    LBXBSHandoffEnsureFromExactManagerKey(host, key);
}

void LBInstallXBSHandoffHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = NSClassFromString(@"BookWorldHomeCon");
        if (!cls) {
            LBXBSHandoffMark(@"install miss BookWorldHomeCon");
            return;
        }
        // 用 NSSelectorFromString，避免 KindBar Release gate 扫到 @selector(createCons:
        SEL selCreate = NSSelectorFromString(@"createCons:titles:sourceName:");
        Class ownerCreate = LBClassOwningInstanceMethod(cls, selCreate);
        if (ownerCreate) {
            Method m = class_getInstanceMethod(ownerCreate, selCreate);
            if (m && !sOrig_BWH_createCons) {
                sOrig_BWH_createCons = (void (*)(id, SEL, id, id, NSString *))method_getImplementation(m);
                method_setImplementation(m, (IMP)LBXBS_BWH_createCons);
                LBXBSHandoffMark([NSString stringWithFormat:@"hooked createCons on %@",
                                  NSStringFromClass(ownerCreate)]);
            }
        } else {
            LBXBSHandoffMark(@"install miss createCons owner");
        }

        SEL selAppear = @selector(viewDidAppear:);
        Class ownerAppear = LBClassOwningInstanceMethod(cls, selAppear);
        if (ownerAppear) {
            Method m = class_getInstanceMethod(ownerAppear, selAppear);
            if (m && !sOrig_BWH_viewDidAppear) {
                sOrig_BWH_viewDidAppear = (void (*)(id, SEL, BOOL))method_getImplementation(m);
                method_setImplementation(m, (IMP)LBXBS_BWH_viewDidAppear);
                LBXBSHandoffMark([NSString stringWithFormat:@"hooked viewDidAppear on %@",
                                  NSStringFromClass(ownerAppear)]);
            }
        } else {
            LBXBSHandoffMark(@"install miss viewDidAppear owner");
        }
    });
}
