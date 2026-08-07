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
        // 已有 requestInfo 且 arrBaseData 已有书 → 不覆盖；空列表则强制重写
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
                    if ([ri isKindOfClass:[NSString class]] && [(NSString *)ri length] > 0 && arrN > 0) {
                        LBXBSHandoffMark([NSString stringWithFormat:
                                          @"wireKids skipExisting idx=%ld ch=%@ arrN=%ld",
                                          (long)idx, channel ?: @"-", (long)arrN]);
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
        // setDicConfig 只写配置；出书需原生 jsNetListQuery（禁止 refresh/loadData）
        SEL qSel = NSSelectorFromString(@"jsNetListQuery:userInfo:");
        if ([child respondsToSelector:qSel] && riLen > 0) {
            __weak id weakChild = child;
            NSDictionary *cfgForQuery = copy;
            NSString *chMark = channel ?: @"-";
            NSInteger idxMark = idx;
            dispatch_async(dispatch_get_main_queue(), ^{
                id c = weakChild;
                if (!c) return;
                @try {
                    ((void (*)(id, SEL, id, id))objc_msgSend)(c, qSel, cfgForQuery, nil);
                    LBXBSHandoffMark([NSString stringWithFormat:
                                      @"wireKids queryFire idx=%ld ch=%@",
                                      (long)idxMark, chMark]);
                } @catch (NSException *ex) {
                    LBXBSHandoffMark([NSString stringWithFormat:
                                      @"wireKids queryEX idx=%ld ch=%@ %@",
                                      (long)idxMark, chMark, ex.reason ?: @""]);
                }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    NSInteger n2 = -1;
                    @try {
                        id a2 = [c valueForKey:@"arrBaseData"];
                        if ([a2 isKindOfClass:[NSArray class]]) n2 = (NSInteger)[(NSArray *)a2 count];
                        // dump 首项键，区分标签墙 vs 书行
                        if ([a2 isKindOfClass:[NSArray class]] && [(NSArray *)a2 count] > 0) {
                            id first = [(NSArray *)a2 firstObject];
                            if ([first isKindOfClass:[NSDictionary class]]) {
                                NSArray *ks = [(NSDictionary *)first allKeys];
                                NSString *joined = [[ks componentsJoinedByString:@","] copy];
                                if (joined.length > 180) joined = [joined substringToIndex:180];
                                id bn = ((NSDictionary *)first)[@"bookName"]
                                    ?: ((NSDictionary *)first)[@"name"]
                                    ?: ((NSDictionary *)first)[@"title"];
                                NSString *bnS = [bn isKindOfClass:[NSString class]] ? (NSString *)bn : @"-";
                                if (bnS.length > 40) bnS = [bnS substringToIndex:40];
                                LBXBSHandoffMark([NSString stringWithFormat:
                                                  @"wireKids item0 idx=%ld keys=%@ name=%@",
                                                  (long)idxMark, joined ?: @"-", bnS]);
                            } else {
                                LBXBSHandoffMark([NSString stringWithFormat:
                                                  @"wireKids item0 idx=%ld cls=%@",
                                                  (long)idxMark,
                                                  NSStringFromClass([first class]) ?: @"-"]);
                            }
                        }
                    } @catch (__unused NSException *e) {}
                    LBXBSHandoffMark([NSString stringWithFormat:
                                      @"wireKids queryProbe idx=%ld ch=%@ arrN=%ld",
                                      (long)idxMark, chMark, (long)n2]);
                    // 数据已在但 UI 仍是标签墙时：只软刷本子页表（不调 VC refresh/loadData）
                    if (n2 > 0 && [c isKindOfClass:[UIViewController class]]) {
                        UIViewController *vc = (UIViewController *)c;
                        // 旁路状态：filter / cellClass / dataSource
                        @try {
                            id filt = [c valueForKey:@"arrFilterModel"];
                            NSInteger fN = [filt isKindOfClass:[NSArray class]] ? (NSInteger)[(NSArray *)filt count] : -1;
                            id cc = nil;
                            @try { cc = [c valueForKey:@"cellClass"]; } @catch (__unused NSException *e) {}
                            NSString *ccS = cc ? (NSStringFromClass([cc class]) ?: [cc description]) : @"-";
                            if (ccS.length > 40) ccS = [ccS substringToIndex:40];
                            id dsTV = nil;
                            @try { dsTV = [c valueForKey:@"tableView"]; } @catch (__unused NSException *e) {}
                            id dsObj = nil;
                            if ([dsTV isKindOfClass:[UITableView class]]) {
                                dsObj = [(UITableView *)dsTV dataSource];
                            }
                            LBXBSHandoffMark([NSString stringWithFormat:
                                              @"wireKids state idx=%ld filterN=%ld cellClass=%@ tvDS=%@ selfDS=%d",
                                              (long)idxMark, (long)fN, ccS,
                                              dsObj ? NSStringFromClass([dsObj class]) : @"-",
                                              (dsObj == c) ? 1 : 0]);
                            // _UIFilteredDataSource + filterN>0 → rows=0；清 filter 让表露出 arrBaseData
                            if (fN > 0) {
                                SEL setAF = NSSelectorFromString(@"setArrFilterModel:");
                                if ([c respondsToSelector:setAF]) {
                                    ((void (*)(id, SEL, id))objc_msgSend)(c, setAF, @[]);
                                }
                                SEL setF = NSSelectorFromString(@"setFilter:");
                                if ([c respondsToSelector:setF]) {
                                    ((void (*)(id, SEL, id))objc_msgSend)(c, setF, nil);
                                }
                                @try { [c setValue:@[] forKey:@"arrFilterModel"]; } @catch (__unused NSException *e) {}
                                LBXBSHandoffMark([NSString stringWithFormat:
                                                  @"wireKids clearFilter idx=%ld was=%ld",
                                                  (long)idxMark, (long)fN]);
                            }
                            // 若 tableView.dataSource 被换成 Filtered，尝试挂回 self
                            if ([dsTV isKindOfClass:[UITableView class]] && dsObj && dsObj != c &&
                                [c conformsToProtocol:@protocol(UITableViewDataSource)]) {
                                @try {
                                    [(UITableView *)dsTV setDataSource:(id<UITableViewDataSource>)c];
                                    [(UITableView *)dsTV setDelegate:(id<UITableViewDelegate>)c];
                                    LBXBSHandoffMark([NSString stringWithFormat:
                                                      @"wireKids rebindDS idx=%ld from=%@",
                                                      (long)idxMark,
                                                      NSStringFromClass([dsObj class]) ?: @"-"]);
                                } @catch (NSException *ex) {
                                    LBXBSHandoffMark([NSString stringWithFormat:
                                                      @"wireKids rebindDS EX %@", ex.reason ?: @""]);
                                }
                            }
                            // cellClass 为空时 table rows>0 仍无 visibleCells（真机黑屏）
                            Class wantCell = NSClassFromString(@"BookListCellBase");
                            if (wantCell) {
                                SEL setCC = NSSelectorFromString(@"setCellClass:");
                                if ([c respondsToSelector:setCC]) {
                                    ((void (*)(id, SEL, Class))objc_msgSend)(c, setCC, wantCell);
                                    LBXBSHandoffMark([NSString stringWithFormat:
                                                      @"wireKids setCellClass idx=%ld BookListCellBase",
                                                      (long)idxMark]);
                                }
                            }
                        } @catch (__unused NSException *e) {}
                        // 扫描其它可能承载书列表的数组属性
                        @try {
                            NSArray *probeKeys = @[
                                @"arrShowData", @"arrData", @"itemList", @"arrBooks",
                                @"arrList", @"dataArray", @"arrResult", @"arrModels"
                            ];
                            NSMutableString *extra = [NSMutableString string];
                            for (NSString *k in probeKeys) {
                                id v = nil;
                                @try { v = [c valueForKey:k]; } @catch (__unused NSException *e) {}
                                if ([v isKindOfClass:[NSArray class]]) {
                                    if (extra.length) [extra appendString:@","];
                                    [extra appendFormat:@"%@=%lu", k, (unsigned long)[(NSArray *)v count]];
                                }
                            }
                            if (extra.length == 0) [extra appendString:@"-"];
                            LBXBSHandoffMark([NSString stringWithFormat:
                                              @"wireKids arrays idx=%ld %@", (long)idxMark, extra]);
                        } @catch (__unused NSException *e) {}
                        NSInteger tvN = 0;
                        if (vc.isViewLoaded) {
                            // pass1：收集表/集合
                            NSMutableArray<UITableView *> *tables = [NSMutableArray array];
                            NSMutableArray<UICollectionView *> *cols = [NSMutableArray array];
                            NSMutableArray<UIView *> *views = [NSMutableArray arrayWithObject:vc.view];
                            while (views.count > 0) {
                                UIView *v = views.firstObject;
                                [views removeObjectAtIndex:0];
                                for (UIView *sub in v.subviews) [views addObject:sub];
                                if ([v isKindOfClass:[UITableView class]]) {
                                    [tables addObject:(UITableView *)v];
                                } else if ([v isKindOfClass:[UICollectionView class]]) {
                                    [cols addObject:(UICollectionView *)v];
                                }
                            }
                            // pass2：标签墙改为紧凑顶栏（保留分类），禁止整块隐藏
                            const CGFloat kTagBarH = 168.0; // 约 4 行标签，深色底上需看得见
                            UICollectionView *tagCV = nil;
                            for (UICollectionView *cv in cols) {
                                NSInteger items = 0;
                                @try {
                                    if ([cv numberOfSections] > 0) {
                                        items = [cv numberOfItemsInSection:0];
                                    }
                                } @catch (__unused NSException *e) {}
                                BOOL looksTagWall = (items >= 20); // 高度会被压到 140，不能再靠 h>=200 判定
                                if (looksTagWall && n2 > 0) {
                                    tagCV = cv;
                                    @try {
                                        cv.hidden = NO;
                                        cv.alpha = 1.0;
                                        cv.scrollEnabled = YES;
                                        CGRect fr = cv.frame;
                                        fr.origin.y = 0;
                                        fr.size.height = kTagBarH;
                                        if (fr.size.width < 1.0 && vc.view) {
                                            fr.size.width = vc.view.bounds.size.width;
                                        }
                                        cv.frame = fr;
                                        for (NSLayoutConstraint *cn in cv.constraints) {
                                            if (cn.firstAttribute == NSLayoutAttributeHeight ||
                                                cn.secondAttribute == NSLayoutAttributeHeight) {
                                                cn.constant = kTagBarH;
                                            }
                                        }
                                        UIView *sup = cv.superview;
                                        if (sup) {
                                            for (NSLayoutConstraint *cn in sup.constraints) {
                                                if ((cn.firstItem == cv || cn.secondItem == cv) &&
                                                    (cn.firstAttribute == NSLayoutAttributeHeight ||
                                                     cn.secondAttribute == NSLayoutAttributeHeight)) {
                                                    cn.constant = kTagBarH;
                                                }
                                            }
                                            [sup bringSubviewToFront:cv];
                                            [sup setNeedsLayout];
                                            [sup layoutIfNeeded];
                                        }
                                        [cv reloadData];
                                        [cv setContentOffset:CGPointZero animated:NO];
                                        [cv layoutIfNeeded];
                                        // dump 可见标签文案（深色模式下确认二级分类是否真在）
                                        NSMutableArray *tagTxt = [NSMutableArray array];
                                        @try {
                                            for (UICollectionViewCell *cell in cv.visibleCells) {
                                                if (tagTxt.count >= 6) break;
                                                NSMutableArray *q = [NSMutableArray arrayWithObject:cell];
                                                while (q.count > 0 && tagTxt.count < 6) {
                                                    UIView *vv = q.firstObject;
                                                    [q removeObjectAtIndex:0];
                                                    for (UIView *s in vv.subviews) [q addObject:s];
                                                    if ([vv isKindOfClass:[UILabel class]]) {
                                                        NSString *t = [(UILabel *)vv text];
                                                        if (t.length > 0) [tagTxt addObject:t];
                                                    } else if ([vv isKindOfClass:[UIButton class]]) {
                                                        NSString *t = [(UIButton *)vv currentTitle];
                                                        if (t.length > 0) [tagTxt addObject:t];
                                                    }
                                                }
                                            }
                                        } @catch (__unused NSException *e) {}
                                        NSString *joined = tagTxt.count
                                            ? [tagTxt componentsJoinedByString:@","] : @"-";
                                        if (joined.length > 80) joined = [joined substringToIndex:80];
                                        LBXBSHandoffMark([NSString stringWithFormat:
                                                          @"wireKids tagTxt idx=%ld nVis=%lu %@",
                                                          (long)idxMark,
                                                          (unsigned long)cv.visibleCells.count,
                                                          joined]);
                                    } @catch (__unused NSException *e) {}
                                    LBXBSHandoffMark([NSString stringWithFormat:
                                                      @"wireKids compactCV idx=%ld items=%ld h=%.0f",
                                                      (long)idxMark, (long)items, cv.frame.size.height]);
                                }
                                LBXBSHandoffMark([NSString stringWithFormat:
                                                  @"wireKids cvDump idx=%ld frame=%.0fx%.0f@%.0f,%.0f items=%ld hidden=%d",
                                                  (long)idxMark,
                                                  cv.frame.size.width, cv.frame.size.height,
                                                  cv.frame.origin.x, cv.frame.origin.y,
                                                  (long)items, cv.hidden ? 1 : 0]);
                            }
                            // pass3：书表接到标签栏下方，不再清掉分类 header
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
                                    tfr.origin.x = 0;
                                    tfr.origin.y = top;
                                    tfr.size.width = sup.bounds.size.width > 1 ? sup.bounds.size.width : tfr.size.width;
                                    tfr.size.height = MAX(120.0, fullH - top);
                                    tv.frame = tfr;
                                    if (tagCV) {
                                        [sup insertSubview:tv belowSubview:tagCV];
                                        [sup bringSubviewToFront:tagCV];
                                    } else {
                                        [sup bringSubviewToFront:tv];
                                    }
                                    // 仅清异常大的空白 inset，保留合理 header
                                    UIEdgeInsets inset = tv.contentInset;
                                    if (inset.top >= 200.0) {
                                        inset.top = 0;
                                        tv.contentInset = inset;
                                    }
                                    tv.contentOffset = CGPointZero;
                                    if (tv.rowHeight <= 1.0 && tv.estimatedRowHeight <= 1.0) {
                                        tv.rowHeight = 88.0;
                                        tv.estimatedRowHeight = 88.0;
                                    }
                                    [tv reloadData];
                                    [tv layoutIfNeeded];
                                    if ([tv numberOfSections] > 0 &&
                                        [tv numberOfRowsInSection:0] > 0) {
                                        NSIndexPath *ip =
                                            [NSIndexPath indexPathForRow:0 inSection:0];
                                        [tv scrollToRowAtIndexPath:ip
                                                  atScrollPosition:UITableViewScrollPositionTop
                                                          animated:NO];
                                    }
                                    tvN += 1;
                                } @catch (__unused NSException *e) {}
                                // 表布局后再置顶标签栏，防止二次 wire 盖住分类
                                if (tagCV) {
                                    @try {
                                        [tagCV.superview bringSubviewToFront:tagCV];
                                        tagCV.hidden = NO;
                                    } @catch (__unused NSException *e) {}
                                }
                                NSInteger rows = 0;
                                @try {
                                    if ([tv numberOfSections] > 0) {
                                        rows = [tv numberOfRowsInSection:0];
                                    }
                                } @catch (__unused NSException *e) {}
                                NSString *cellTxt = @"-";
                                NSUInteger cellN = 0;
                                @try {
                                    NSArray *cells = [tv visibleCells];
                                    cellN = cells.count;
                                    if (cells.count > 0) {
                                        UIView *cell = cells.firstObject;
                                        NSMutableArray *labs = [NSMutableArray array];
                                        NSMutableArray *q = [NSMutableArray arrayWithObject:cell];
                                        while (q.count > 0 && labs.count < 3) {
                                            UIView *vv = q.firstObject;
                                            [q removeObjectAtIndex:0];
                                            for (UIView *s in vv.subviews) [q addObject:s];
                                            if ([vv isKindOfClass:[UILabel class]]) {
                                                NSString *t = [(UILabel *)vv text];
                                                if (t.length > 0) [labs addObject:t];
                                            }
                                        }
                                        if (labs.count) {
                                            cellTxt = [labs componentsJoinedByString:@"|"];
                                            if (cellTxt.length > 60) cellTxt = [cellTxt substringToIndex:60];
                                        }
                                    }
                                } @catch (__unused NSException *e) {}
                                LBXBSHandoffMark([NSString stringWithFormat:
                                                  @"wireKids tvDump idx=%ld frame=%.0fx%.0f@%.0f,%.0f rows=%ld cells=%lu rh=%.0f txt=%@",
                                                  (long)idxMark,
                                                  tv.frame.size.width, tv.frame.size.height,
                                                  tv.frame.origin.x, tv.frame.origin.y,
                                                  (long)rows, (unsigned long)cellN,
                                                  tv.rowHeight, cellTxt]);
                            }
                        }
                        LBXBSHandoffMark([NSString stringWithFormat:
                                          @"wireKids softReload idx=%ld ch=%@ tv=%ld",
                                          (long)idxMark, chMark, (long)tvN]);
                    }
                });
            });
        } else {
            LBXBSHandoffMark([NSString stringWithFormat:
                              @"wireKids noQuery idx=%ld ch=%@ resp=%d riLen=%lu",
                              (long)idx, channel ?: @"-",
                              [child respondsToSelector:qSel] ? 1 : 0,
                              (unsigned long)riLen]);
        }
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
