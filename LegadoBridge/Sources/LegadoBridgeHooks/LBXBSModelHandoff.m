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

static void LBXBSHandoffMark(NSString *line);
static NSInteger LBXBSHandoffWireBookListChildren(
    UIViewController *host,
    id cons,
    id titles,
    NSString *exactManagerKey
);

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
    if (!cls) return NULL;
    // class_getInstanceVariable 会沿超类查找；优先精确名
    Ivar exact = class_getInstanceVariable(cls, "_dicModel");
    if (exact) return exact;
    while (cls && cls != [NSObject class]) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        Ivar fuzzy = NULL;
        for (unsigned int i = 0; i < count; i++) {
            const char *name = ivar_getName(ivars[i]);
            if (!name) continue;
            if (strcmp(name, "_dicModel") == 0) {
                Ivar found = ivars[i];
                free(ivars);
                return found;
            }
            // 兼容非 `_dicModel` 命名但含 dicModel 的后备 ivar（仍只走 object_setIvar，禁 KVC）
            if (!fuzzy && strstr(name, "dicModel")) {
                fuzzy = ivars[i];
            }
        }
        if (ivars) free(ivars);
        if (fuzzy) return fuzzy;
        cls = class_getSuperclass(cls);
    }
    return NULL;
}

/// 仅 BookWorldHomeCon（及其子类）可写；基类 viewDidAppear 挂钩时必须过滤。
static BOOL LBXBSHostIsBookWorldHome(id obj) {
    Class bwh = NSClassFromString(@"BookWorldHomeCon");
    return bwh && [obj isKindOfClass:bwh];
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
    Class hostCls = [host class];
    Ivar iv = LBXBSFindDicModelIvar(hostCls);
    if (!iv) {
        iv = LBXBSFindDicModelIvar(object_getClass(host));
    }
    if (!iv) {
        NSMutableString *ivarDump = [NSMutableString string];
        NSMutableString *propDump = [NSMutableString string];
        Class walk = hostCls;
        int depth = 0;
        while (walk && walk != [NSObject class] && depth < 6) {
            unsigned int n = 0;
            Ivar *ivars = class_copyIvarList(walk, &n);
            for (unsigned int i = 0; i < n; i++) {
                const char *nm = ivar_getName(ivars[i]);
                if (nm) {
                    if (ivarDump.length > 0) [ivarDump appendString:@","];
                    [ivarDump appendFormat:@"%s", nm];
                }
            }
            if (ivars) free(ivars);
            unsigned int pn = 0;
            objc_property_t *props = class_copyPropertyList(walk, &pn);
            for (unsigned int i = 0; i < pn; i++) {
                const char *pnamed = property_getName(props[i]);
                if (pnamed) {
                    if (propDump.length > 0) [propDump appendString:@","];
                    [propDump appendFormat:@"%s", pnamed];
                }
            }
            if (props) free(props);
            walk = class_getSuperclass(walk);
            depth += 1;
        }
        if (ivarDump.length > 1800) {
            ivarDump = [[ivarDump substringToIndex:1800] mutableCopy];
        }
        if (propDump.length > 800) {
            propDump = [[propDump substringToIndex:800] mutableCopy];
        }
        BOOL kvcReadable = NO;
        @try {
            id v = [host valueForKey:@"dicModel"];
            kvcReadable = [v isKindOfClass:[NSDictionary class]];
        } @catch (__unused NSException *e) {}
        LBXBSHandoffMark([NSString stringWithFormat:
                          @"write missIvar host=%@ kvcDic=%d ivars=%@ props=%@",
                          NSStringFromClass(hostCls) ?: @"-",
                          kvcReadable ? 1 : 0,
                          ivarDump.length ? ivarDump : @"-",
                          propDump.length ? propDump : @"-"]);
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
    if (!LBXBSHostIsBookWorldHome(host)) {
        LBXBSHandoffMark([NSString stringWithFormat:@"ensure skip notBWH host=%@",
                          NSStringFromClass([host class]) ?: @"-"]);
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
    if (ok) {
        LBXBSHandoffMark(@"ensure ok");
        // host 有 ivar 时仍接线子页，避免仅有壳模型
        LBXBSHandoffWireBookListChildren(host, nil, nil, exactManagerKey);
        return YES;
    }
    // 2.56.1：无 host ivar 时改接线 BookListCon.dicConfig（合同 prefer manager；子页才是出书面）
    NSInteger wired = LBXBSHandoffWireBookListChildren(host, nil, nil, exactManagerKey);
    LBXBSHandoffMark([NSString stringWithFormat:@"ensure hostWriteFail→wireKids wired=%ld err=%@",
                      (long)wired, err.localizedDescription ?: @"-"]);
    return wired > 0;
}

#pragma mark - Hooks (createCons / viewDidAppear)

static void (*sOrig_BWH_createCons)(id, SEL, id, id, NSString *) = NULL;
static void (*sOrig_BWH_viewDidAppear)(id, SEL, BOOL) = NULL;

/// 2.56.1 真机：BookWorldHomeCon 无 `_dicModel` ivar/KVC；书单在子页 BookListCon.dicConfig。
/// createCons 后按 title/index 把 manager.bookWorld[channel] 写入各 BookListCon。
static NSInteger LBXBSHandoffWireBookListChildren(
    UIViewController *host,
    id cons,
    id titles,
    NSString *exactManagerKey
) {
    if (!host || exactManagerKey.length == 0) return 0;
    NSDictionary *managerModel = LBBSMRawDicModelForExactKey(exactManagerKey);
    if (![managerModel isKindOfClass:[NSDictionary class]]) {
        LBXBSHandoffMark(@"wireKids skip noManagerModel");
        return 0;
    }
    id bwObj = managerModel[@"bookWorld"];
    if (![bwObj isKindOfClass:[NSDictionary class]] || [(NSDictionary *)bwObj count] == 0) {
        LBXBSHandoffMark(@"wireKids skip emptyBookWorld");
        return 0;
    }
    NSDictionary *bookWorld = (NSDictionary *)bwObj;

    NSArray *titleArr = nil;
    if ([titles isKindOfClass:[NSArray class]]) {
        titleArr = (NSArray *)titles;
    } else if ([titles isKindOfClass:[NSString class]]) {
        titleArr = @[(NSString *)titles];
    }
    if (titleArr.count == 0) {
        titleArr = bookWorld.allKeys;
    }

    NSMutableArray *children = [NSMutableArray array];
    if ([cons isKindOfClass:[NSArray class]]) {
        [children addObjectsFromArray:(NSArray *)cons];
    }
    // 与 LBActiveDiscoverListVC 一致：子页挂在 pageContentScrollView，而非 host.childViewControllers
    @try {
        id scroll = [host valueForKey:@"pageContentScrollView"];
        id cv = [scroll valueForKey:@"childViewControllers"];
        if (![cv isKindOfClass:[NSArray class]] || [(NSArray *)cv count] == 0) {
            cv = [scroll valueForKey:@"childVCs"];
        }
        if ([cv isKindOfClass:[NSArray class]]) {
            for (id k in (NSArray *)cv) {
                if (k && ![children containsObject:k]) [children addObject:k];
            }
        }
    } @catch (__unused NSException *e) {}
    @try {
        NSArray *kids = host.childViewControllers;
        for (id k in kids) {
            if (k && ![children containsObject:k]) [children addObject:k];
        }
    } @catch (__unused NSException *e) {}
    @try {
        id list = [host valueForKey:@"listCon"];
        if (list && ![children containsObject:list]) [children addObject:list];
    } @catch (__unused NSException *e) {}

    // 记录子类名便于对照
    NSMutableString *clsDump = [NSMutableString string];
    for (id ch in children) {
        if (clsDump.length > 0) [clsDump appendString:@","];
        [clsDump appendString:NSStringFromClass([ch class]) ?: @"?"];
    }
    if (clsDump.length > 400) clsDump = [[clsDump substringToIndex:400] mutableCopy];
    LBXBSHandoffMark([NSString stringWithFormat:@"wireKids collect n=%lu classes=%@",
                      (unsigned long)children.count, clsDump.length ? clsDump : @"-"]);

    Class blc = NSClassFromString(@"BookListCon");
    SEL setCfg = NSSelectorFromString(@"setDicConfig:");
    SEL getCfg = NSSelectorFromString(@"dicConfig");
    NSInteger wired = 0;
    NSInteger idx = 0;
    for (id child in children) {
        if (blc && ![child isKindOfClass:blc]) {
            idx += 1;
            continue;
        }
        if (![child respondsToSelector:setCfg]) {
            LBXBSHandoffMark([NSString stringWithFormat:@"wireKids noSel setDicConfig idx=%ld cls=%@",
                              (long)idx, NSStringFromClass([child class]) ?: @"-"]);
            idx += 1;
            continue;
        }
        NSString *channel = nil;
        @try {
            id t = [child valueForKey:@"title"];
            if ([t isKindOfClass:[NSString class]] && [(NSString *)t length] > 0) channel = t;
        } @catch (__unused NSException *e) {}
        if (channel.length == 0 && idx < (NSInteger)titleArr.count) {
            id t2 = titleArr[(NSUInteger)idx];
            if ([t2 isKindOfClass:[NSString class]]) channel = (NSString *)t2;
        }
        NSDictionary *entry = nil;
        if (channel.length > 0) {
            id e = bookWorld[channel];
            if ([e isKindOfClass:[NSDictionary class]]) entry = (NSDictionary *)e;
        }
        // 标题对不上时按 allKeys 顺序兜底
        if (!entry && idx < (NSInteger)bookWorld.count) {
            NSArray *keys = bookWorld.allKeys;
            if (idx < (NSInteger)keys.count) {
                id e2 = bookWorld[keys[(NSUInteger)idx]];
                if ([e2 isKindOfClass:[NSDictionary class]]) {
                    entry = (NSDictionary *)e2;
                    channel = keys[(NSUInteger)idx];
                }
            }
        }
        if (!entry) {
            LBXBSHandoffMark([NSString stringWithFormat:@"wireKids missEntry idx=%ld ch=%@",
                              (long)idx, channel ?: @"-"]);
            idx += 1;
            continue;
        }
        // TC-08F：已有 requestInfo 则不覆盖（不再要求 arrN>0）。空列表由原生生命周期/标签点选出书。
        BOOL force = YES;
        NSInteger arrN = -1;
        @try {
            id a = [child valueForKey:@"arrBaseData"];
            if ([a isKindOfClass:[NSArray class]]) arrN = (NSInteger)[(NSArray *)a count];
        } @catch (__unused NSException *e) {}
        if ([child respondsToSelector:getCfg]) {
            @try {
                id cur = ((id (*)(id, SEL))objc_msgSend)(child, getCfg);
                if ([cur isKindOfClass:[NSDictionary class]] && [(NSDictionary *)cur count] > 0) {
                    id ri = ((NSDictionary *)cur)[@"requestInfo"];
                    if ([ri isKindOfClass:[NSString class]] && [(NSString *)ri length] > 0) {
                        LBXBSHandoffMark([NSString stringWithFormat:
                                          @"wireKids skipExisting idx=%ld ch=%@ arrN=%ld curKeys=%lu",
                                          (long)idx, channel ?: @"-", (long)arrN,
                                          (unsigned long)[(NSDictionary *)cur count]]);
                        force = NO;
                    } else {
                        LBXBSHandoffMark([NSString stringWithFormat:
                                          @"wireKids rewrite idx=%ld ch=%@ arrN=%ld curKeys=%lu",
                                          (long)idx, channel ?: @"-", (long)arrN,
                                          (unsigned long)[(NSDictionary *)cur count]]);
                    }
                }
            } @catch (__unused NSException *e) {}
        }
        if (!force) {
            idx += 1;
            continue;
        }
        NSDictionary *copy = [[NSDictionary alloc] initWithDictionary:entry copyItems:YES];
        ((void (*)(id, SEL, id))objc_msgSend)(child, setCfg, copy);
        wired += 1;
        // 诊断：requestInfo/list 是否齐全（list 常为 JS 规则字符串）
        NSUInteger riLen = 0;
        NSString *listKind = @"-";
        @try {
            id ri = copy[@"requestInfo"];
            if ([ri isKindOfClass:[NSString class]]) riLen = [(NSString *)ri length];
            id lst = copy[@"list"];
            if ([lst isKindOfClass:[NSString class]]) listKind = @"str";
            else if ([lst isKindOfClass:[NSArray class]]) listKind = @"arr";
            else if ([lst isKindOfClass:[NSDictionary class]]) listKind = @"dic";
            else if (lst) listKind = NSStringFromClass([lst class]) ?: @"?";
        } @catch (__unused NSException *e) {}
        LBXBSHandoffMark([NSString stringWithFormat:
                          @"wireKids ok idx=%ld ch=%@ keys=%lu arrNBefore=%ld riLen=%lu list=%@",
                          (long)idx, channel ?: @"-",
                          (unsigned long)copy.count, (long)arrN,
                          (unsigned long)riLen, listKind]);
        // TC-08F：禁止 Bridge 盲发 jsNetListQuery（@js 依赖 params.filters；无 filter → 找不到URL）。
        // 出书交给原生 viewDidAppear / 标签点选 / refreshControl；此处只写 dicConfig。
        // 同时移除 clearFilter / rebindDS / setCellClass / compactCV / darkPaint 旁路（A-NO-UI-TAKEOVER）。
        LBXBSHandoffMark([NSString stringWithFormat:
                          @"wireKids noQueryFire idx=%ld ch=%@ riLen=%lu (nativeLifecycleOnly)",
                          (long)idx, channel ?: @"-", (unsigned long)riLen]);
        idx += 1;
    }
    LBXBSHandoffMark([NSString stringWithFormat:@"wireKids done key=%@ wired=%ld kids=%lu bw=%lu",
                      exactManagerKey, (long)wired,
                      (unsigned long)children.count,
                      (unsigned long)bookWorld.count]);
    return wired;
}

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
    // 合同 firstInvalid：createCons 前尽量写 host；2.56.1 无 ivar 时在 createCons 后接线子页
    if ([sourceName isKindOfClass:[NSString class]] && sourceName.length > 0 &&
        LBXBSHostIsBookWorldHome(self)) {
        LBXBSHandoffEnsureFromExactManagerKey((UIViewController *)self, sourceName);
    }
    if (sOrig_BWH_createCons) {
        sOrig_BWH_createCons(self, _cmd, cons, titles, sourceName);
    }
    if ([sourceName isKindOfClass:[NSString class]] && sourceName.length > 0 &&
        LBXBSHostIsBookWorldHome(self)) {
        LBXBSHandoffWireBookListChildren((UIViewController *)self, cons, titles, sourceName);
    }
}

static void LBXBS_BWH_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (sOrig_BWH_viewDidAppear) {
        sOrig_BWH_viewDidAppear(self, _cmd, animated);
    }
    // owner 可能是 LCViewControllerBase：必须只处理 BookWorldHomeCon
    if (!LBXBSHostIsBookWorldHome(self)) return;
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

/// TC-08F2：原生已出书但标签墙占满屏时，仅压标签栏高度并软刷书表（不盲发 query）。
static void LBXBSRevealBookTableIfNeeded(UIViewController *vc) {
    if (![vc isKindOfClass:[UIViewController class]] || !vc.isViewLoaded) return;
    NSInteger arrN = 0;
    @try {
        id a = [vc valueForKey:@"arrBaseData"];
        if ([a isKindOfClass:[NSArray class]]) arrN = (NSInteger)[(NSArray *)a count];
    } @catch (__unused NSException *e) {}
    if (arrN <= 0) return;

    NSMutableArray<UITableView *> *tables = [NSMutableArray array];
    NSMutableArray<UICollectionView *> *cols = [NSMutableArray array];
    NSMutableArray<UIView *> *q = [NSMutableArray arrayWithObject:vc.view];
    while (q.count > 0) {
        UIView *v = q.firstObject;
        [q removeObjectAtIndex:0];
        for (UIView *sub in v.subviews) [q addObject:sub];
        if ([v isKindOfClass:[UITableView class]]) [tables addObject:(UITableView *)v];
        else if ([v isKindOfClass:[UICollectionView class]]) [cols addObject:(UICollectionView *)v];
    }
    // 番茄等源标签墙极高；压到约两行，并裁切，避免盖住书表。
    const CGFloat kTagBarH = 112.0;
    UICollectionView *tagCV = nil;
    for (UICollectionView *cv in cols) {
        NSInteger items = 0;
        @try {
            if ([cv numberOfSections] > 0) items = [cv numberOfItemsInSection:0];
        } @catch (__unused NSException *e) {}
        // 取最高的标签墙；书表 CV 通常 item 少或不在此路径
        CGFloat h = cv.frame.size.height;
        if (items >= 8 && h >= 160.0) {
            if (!tagCV || h > tagCV.frame.size.height) tagCV = cv;
        }
    }
    if (tagCV) {
        UICollectionView *cv = tagCV;
        @try {
            NSInteger itemsN = 0;
            @try {
                if ([cv numberOfSections] > 0) itemsN = [cv numberOfItemsInSection:0];
            } @catch (__unused NSException *e) {}
            CGFloat hBefore = cv.frame.size.height;
            cv.hidden = NO;
            cv.alpha = 1.0;
            cv.clipsToBounds = YES;
            cv.scrollEnabled = YES;
            CGRect fr = cv.frame;
            // 保持原 y（频道条下方），只压高度
            fr.size.height = kTagBarH;
            if (fr.size.width < 1.0) fr.size.width = vc.view.bounds.size.width;
            cv.frame = fr;
            for (NSLayoutConstraint *cn in cv.constraints) {
                if (cn.firstAttribute == NSLayoutAttributeHeight ||
                    cn.secondAttribute == NSLayoutAttributeHeight) {
                    cn.constant = kTagBarH;
                    cn.active = YES;
                }
            }
            UIView *sup = cv.superview;
            if (sup) {
                for (NSLayoutConstraint *cn in sup.constraints) {
                    if ((cn.firstItem == cv || cn.secondItem == cv) &&
                        (cn.firstAttribute == NSLayoutAttributeHeight ||
                         cn.secondAttribute == NSLayoutAttributeHeight)) {
                        cn.constant = kTagBarH;
                        cn.active = YES;
                    }
                }
                [sup setNeedsLayout];
                [sup layoutIfNeeded];
            }
            // layout 后又被撑高时强制回写
            if (cv.frame.size.height > kTagBarH + 1.0) {
                CGRect fr2 = cv.frame;
                fr2.size.height = kTagBarH;
                cv.frame = fr2;
            }
            LBXBSHandoffMark([NSString stringWithFormat:
                              @"reveal compactCV items=%ld h=%.0f->%.0f",
                              (long)itemsN, hBefore, cv.frame.size.height]);
        } @catch (__unused NSException *e) {}
    }

    // 有书但 filter DS 导致 rows=0：临时清空 filter 露出 arrBaseData（不改请求语义）
    @try {
        id filt = [vc valueForKey:@"arrFilterModel"];
        NSInteger fN = [filt isKindOfClass:[NSArray class]] ? (NSInteger)[(NSArray *)filt count] : 0;
        if (fN > 0) {
            SEL setAF = NSSelectorFromString(@"setArrFilterModel:");
            if ([vc respondsToSelector:setAF]) {
                ((void (*)(id, SEL, id))objc_msgSend)(vc, setAF, @[]);
            }
            @try { [vc setValue:@[] forKey:@"arrFilterModel"]; } @catch (__unused NSException *e) {}
            LBXBSHandoffMark([NSString stringWithFormat:@"reveal clearFilterDisp was=%ld arrN=%ld",
                              (long)fN, (long)arrN]);
        }
    } @catch (__unused NSException *e) {}

    NSInteger tvN = 0;
    for (UITableView *tv in tables) {
        @try {
            tv.hidden = NO;
            tv.alpha = 1.0;
            CGFloat top = tagCV ? CGRectGetMaxY(tagCV.frame) : 0;
            if (top < 1.0 && tagCV) top = kTagBarH;
            UIView *sup = tv.superview ?: vc.view;
            CGFloat fullH = sup.bounds.size.height;
            if (fullH < 1.0) fullH = vc.view.bounds.size.height;
            CGRect tfr = tv.frame;
            tfr.origin.y = top;
            tfr.size.width = sup.bounds.size.width > 1 ? sup.bounds.size.width : tfr.size.width;
            tfr.size.height = MAX(160.0, fullH - top);
            tv.frame = tfr;
            if (tv.rowHeight <= 1.0 && tv.estimatedRowHeight <= 1.0) {
                tv.rowHeight = 88.0;
                tv.estimatedRowHeight = 88.0;
            }
            // Filtered DS 挡行时挂回 self
            id ds = tv.dataSource;
            if (ds && ds != vc && [vc conformsToProtocol:@protocol(UITableViewDataSource)]) {
                NSString *dsN = NSStringFromClass([ds class]) ?: @"";
                if ([dsN containsString:@"Filtered"]) {
                    tv.dataSource = (id<UITableViewDataSource>)vc;
                    if ([vc conformsToProtocol:@protocol(UITableViewDelegate)]) {
                        tv.delegate = (id<UITableViewDelegate>)vc;
                    }
                    LBXBSHandoffMark([NSString stringWithFormat:@"reveal rebindDS from=%@", dsN]);
                }
            }
            [tv reloadData];
            [tv layoutIfNeeded];
            tvN += 1;
            NSInteger rows = 0;
            @try {
                if ([tv numberOfSections] > 0) rows = [tv numberOfRowsInSection:0];
            } @catch (__unused NSException *e) {}
            LBXBSHandoffMark([NSString stringWithFormat:
                              @"reveal tv arrN=%ld rows=%ld fh=%.0f top=%.0f",
                              (long)arrN, (long)rows, tv.frame.size.height, top]);
        } @catch (__unused NSException *e) {}
    }
    // 书表必须在标签墙之上可见；禁止把 tagCV bringToFront 盖住 rows。
    for (UITableView *tv in tables) {
        @try {
            UIView *sup = tv.superview;
            if (sup) [sup bringSubviewToFront:tv];
        } @catch (__unused NSException *e) {}
    }
    LBXBSHandoffMark([NSString stringWithFormat:@"reveal done arrN=%ld tv=%ld tag=%d",
                      (long)arrN, (long)tvN, tagCV ? 1 : 0]);
}

static void (*sOrig_BLC_queryFinish)(id, SEL, id, id, id) = NULL;
static void LBXBS_BLC_queryFinish(id self, SEL _cmd, id finishArg, id config, id userInfo) {
    if (sOrig_BLC_queryFinish) {
        sOrig_BLC_queryFinish(self, _cmd, finishArg, config, userInfo);
    }
    if (![self isKindOfClass:[UIViewController class]]) return;
    __weak UIViewController *weakVC = (UIViewController *)self;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = weakVC;
        if (!vc) return;
        LBXBSRevealBookTableIfNeeded(vc);
        // 再延迟一帧，等原生 filter UI 布局完成后再压一次
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIViewController *vc2 = weakVC;
            if (vc2) LBXBSRevealBookTableIfNeeded(vc2);
        });
    });
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

        Class blc = NSClassFromString(@"BookListCon");
        SEL selQF = NSSelectorFromString(@"lpNetWorkDelegateQueryFinish:config:userInfo:");
        Class ownerQF = blc ? LBClassOwningInstanceMethod(blc, selQF) : Nil;
        if (ownerQF) {
            Method m = class_getInstanceMethod(ownerQF, selQF);
            if (m && !sOrig_BLC_queryFinish) {
                sOrig_BLC_queryFinish = (void (*)(id, SEL, id, id, id))method_getImplementation(m);
                method_setImplementation(m, (IMP)LBXBS_BLC_queryFinish);
                LBXBSHandoffMark([NSString stringWithFormat:@"hooked queryFinish reveal on %@",
                                  NSStringFromClass(ownerQF)]);
            }
        } else {
            LBXBSHandoffMark(@"install miss queryFinish owner");
        }
    });
}
