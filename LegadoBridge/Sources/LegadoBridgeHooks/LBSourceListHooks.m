#import "LBInternal.h"
#import "LegadoBridge.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>

// 书源列表组

static void LBInstallInvertAvailabilityGuard(void);
static void LBInstallSourceListUpdateObserver(void);

#pragma mark - Source List Hooks (站点管理列表)

static NSArray * (*LBOrig_BSM_getSortedSourceNames)(id, SEL) = NULL;
static NSArray * (*LBOrig_BSM_getSortedSourceNamesByPriority)(id, SEL, id) = NULL;
static NSDictionary * (*LBOrig_BSM_dicModelList)(id, SEL) = NULL;
static NSString * (*LBOrig_BSM_sourceTypeBySourceName)(id, SEL, NSString *) = NULL;
static NSString * (*LBOrig_BSM_sourceTypeTitleBySourceName)(id, SEL, NSString *) = NULL;

static NSArray *LBBSM_getSortedSourceNames_IMP(id self, SEL _cmd) {
    NSArray *orig = LBOrig_BSM_getSortedSourceNames ? LBOrig_BSM_getSortedSourceNames(self, _cmd) : @[];
    return LBMergeLegadoNames(orig);
}

/// 搜索页「文本/小说」等筛选走此方法；编码 @24@0:8@16（参数为对象，常为 NSString 类型名）
static NSArray *LBBSM_getSortedSourceNamesByPriority_IMP(id self, SEL _cmd, id priorityType) {
    NSArray *orig = LBOrig_BSM_getSortedSourceNamesByPriority
        ? LBOrig_BSM_getSortedSourceNamesByPriority(self, _cmd, priorityType)
        : @[];
    NSArray *merged = LBMergeLegadoNames(orig);
#if DEBUG
    static dispatch_once_t onceDbg;
    dispatch_once(&onceDbg, ^{
        NSString *priDesc = @"nil";
        if ([priorityType isKindOfClass:[NSString class]]) priDesc = (NSString *)priorityType;
        else if ([priorityType isKindOfClass:[NSNumber class]]) priDesc = [(NSNumber *)priorityType stringValue];
        else if (priorityType) priDesc = NSStringFromClass([priorityType class]);
        NSString *dbg = [NSString stringWithFormat:@"pri=%@ orig=%lu legadoMerged=%lu",
                         priDesc,
                         (unsigned long)(orig.count),
                         (unsigned long)merged.count];
        [dbg writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_sorted_by_pri.txt"]
              atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    });
#endif
    return merged;
}

// 合并缓存：导入新源后必须主动失效，否则 UI 仍吃旧表直至杀进程
static __weak NSDictionary *sCachedOrig;
static NSArray *sCachedLegadoNames;
static NSDictionary *sCachedMerged;

void LBInvalidateSourceListMergeCache(void) {
    sCachedOrig = nil;
    sCachedLegadoNames = nil;
    sCachedMerged = nil;
}

static NSDictionary *LBBSM_dicModelList_IMP(id self, SEL _cmd) {
    NSDictionary *orig = LBOrig_BSM_dicModelList ? LBOrig_BSM_dicModelList(self, _cmd) : @{};
    NSArray *legadoNames = LBLegadoGetSourceNames();
    if (legadoNames.count == 0) return orig ?: @{};

    // 性能：UI 会高频调 getter；同 orig 指针 + 同 Legado 名集时复用合并结果
    if (sCachedMerged && orig == sCachedOrig &&
        sCachedLegadoNames.count == legadoNames.count &&
        [sCachedLegadoNames isEqualToArray:legadoNames]) {
        return sCachedMerged;
    }

    NSMutableDictionary *merged = [orig mutableCopy];
    if (!merged) merged = [NSMutableDictionary dictionary];
    for (NSString *name in legadoNames) {
        NSDictionary *model = LBLegadoNativeModel(name);
        if (model) merged[name] = model;
    }
    sCachedOrig = orig;
    sCachedLegadoNames = [legadoNames copy];
    sCachedMerged = [merged copy];
    return sCachedMerged;
}

static NSString *LBBSM_sourceTypeBySourceName_IMP(id self, SEL _cmd, NSString *name) {
    // 与搜索页 filterSourceType=text 对齐；返回 DOM 会被筛成空列表
    if (LBLegadoIsSourceName(name)) return @"text";
    if (LBOrig_BSM_sourceTypeBySourceName) {
        return LBOrig_BSM_sourceTypeBySourceName(self, _cmd, name);
    }
    return @"text";
}

static NSString *LBBSM_sourceTypeTitleBySourceName_IMP(id self, SEL _cmd, NSString *name) {
    // 真机：可用 DOM 源的 typeTitle 为空；返回 @"Legado" 会被 BookSearchController
    // 的 filterSourceType=text 筛掉，UI 弹「无可用站点 / 或修改筛选类型」。
    if (LBLegadoIsSourceName(name)) return @"";
    if (LBOrig_BSM_sourceTypeTitleBySourceName) {
        return LBOrig_BSM_sourceTypeTitleBySourceName(self, _cmd, name);
    }
    return @"";
}

static id (*LBOrig_Config_getGroupData)(id, SEL) = NULL;

static id LBConfig_getGroupData_IMP(id self, SEL _cmd) {
    id orig = LBOrig_Config_getGroupData ? LBOrig_Config_getGroupData(self, _cmd) : nil;
    NSArray *legadoNames = LBLegadoGetSourceNames();
#if DEBUG
    static dispatch_once_t onceDbg;
    dispatch_once(&onceDbg, ^{
        NSUInteger origNameCount = 0;
        if ([orig isKindOfClass:[NSArray class]]) {
            for (id section in (NSArray *)orig) {
                if ([section isKindOfClass:[NSArray class]]) {
                    origNameCount += [(NSArray *)section count];
                }
            }
        }
        NSString *dbg = [NSString stringWithFormat:@"origClass=%@ origNames=%lu legado=%lu",
                         orig ? NSStringFromClass([orig class]) : @"(nil)",
                         (unsigned long)origNameCount,
                         (unsigned long)legadoNames.count];
        [dbg writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_getgroupdata_hook.txt"]
              atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    });
#endif
    if (legadoNames.count == 0) return orig;
    // getGroupData 返回 5 段 NSArray（TOP/文本/图片/音频/视频），Legado DOM 源归入「文本/小说」段（index 1）
    if ([orig isKindOfClass:[NSArray class]]) {
        NSMutableArray *groups = [orig mutableCopy];
        if (groups.count > 1) {
            id section = groups[1];
            NSMutableArray *names = [section isKindOfClass:[NSArray class]] ? [section mutableCopy] : [NSMutableArray array];
            for (NSString *name in legadoNames) {
                if (name.length > 0 && ![names containsObject:name]) {
                    [names addObject:name];
                }
            }
            groups[1] = names;
        }
        return groups;
    }
    return orig;
}

static NSArray * (*LBOrig_Config_getUseSourceNames)(id, SEL) = NULL;

typedef NSArray *(*LBGetUseSourceNamesFn)(id, SEL);

static NSMutableDictionary<NSString *, NSValue *> *LBOrigGetUseSourceNamesMap(void) {
    static NSMutableDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ map = [NSMutableDictionary dictionary]; });
    return map;
}

static NSArray *LBConfig_getUseSourceNames_IMP(id self, SEL _cmd) {
    NSArray *orig = @[];
    NSString *key = NSStringFromClass(object_getClass(self));
    NSValue *val = LBOrigGetUseSourceNamesMap()[key];
    if (!val) {
        Class cls = object_getClass(self);
        while (cls && !val) {
            val = LBOrigGetUseSourceNamesMap()[NSStringFromClass(cls)];
            cls = class_getSuperclass(cls);
        }
    }
    if (val) {
        LBGetUseSourceNamesFn fn = (LBGetUseSourceNamesFn)val.pointerValue;
        if (fn) orig = fn(self, _cmd) ?: @[];
    } else if (LBOrig_Config_getUseSourceNames) {
        // 兼容：仅挂到单一类时的旧指针
        orig = LBOrig_Config_getUseSourceNames(self, _cmd) ?: @[];
    }
    NSArray *legadoNames = LBLegadoGetSourceNames();
    // 调试：记录 Hook 命中
    NSString *dbg = [NSString stringWithFormat:@"orig=%lu legado=%lu", (unsigned long)orig.count, (unsigned long)legadoNames.count];
    [dbg writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_getusesources_hook.txt"]
          atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    if (legadoNames.count == 0) return orig ?: @[];
    NSMutableOrderedSet *merged = [NSMutableOrderedSet orderedSetWithArray:orig ?: @[]];
    for (NSString *name in legadoNames) {
        [merged addObject:name];
    }
    return merged.array;
}

static void LBLegadoShowTapBlockedAlert(UIViewController *vc) {
    if (!vc) return;
    // 直接进入管理页（原生站点列表接入），不再只弹说明框
    LBLegadoPresentManagerVC(nil);
    (void)vc;
}

/// 点击原生列表中的 Legado 源时：U2 直接推编辑页（返回落回原版站点列表）；
/// 无 URL / 编辑类缺失时回退管理页。右上角「书源」仍走完整管理页。
static void LBLegadoOpenManagerForSourceName(NSString *name) {
    if (name.length == 0) {
        LBLegadoPresentManagerVC(nil);
        return;
    }
    // 消歧后缀：原生键「笔趣读·Legado」→ Registry 名「笔趣读」
    NSString *lookup = name;
    if ([name hasSuffix:@"·Legado"]) {
        lookup = [name substringToIndex:name.length - @"·Legado".length];
    }
    id core = LBLegadoCoreIfReady();
    NSString *focusUrl = nil;
    if (core && [core respondsToSelector:@selector(allSourcesInfo)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        NSArray *info = [core performSelector:@selector(allSourcesInfo)];
#pragma clang diagnostic pop
        for (NSDictionary *dict in info) {
            if (![dict isKindOfClass:[NSDictionary class]]) continue;
            NSString *n = dict[@"bookSourceName"];
            if ([n isKindOfClass:[NSString class]] &&
                ([n isEqualToString:lookup] || [n isEqualToString:name])) {
                focusUrl = dict[@"bookSourceUrl"];
                break;
            }
        }
    }
    if (focusUrl.length > 0) {
        LBLegadoPresentSourceEditor(focusUrl);
    } else {
        LBLegadoPresentManagerVC(nil);
    }
}

/// 剥掉 textByIndexPath 可能带的「(相对时间)」后缀，得到纯源名
static NSString *LBLegadoStripDisplaySuffix(NSString *name) {
    if (name.length == 0) return name;
    NSRange r = [name rangeOfString:@"(" options:NSBackwardsSearch];
    if (r.location != NSNotFound && r.location > 0) {
        name = [name substringToIndex:r.location];
    }
    return [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

/// 从列表 VC 按 indexPath 解析源名：优先 textByIndexPath，失败则用 getUseSourceNames / getSortedSourceNames
static NSString *LBLegadoSourceNameAtIndexPath(id self, NSIndexPath *indexPath) {
    SEL textSel = @selector(textByIndexPath:);
    if ([self respondsToSelector:textSel]) {
        id text = ((id (*)(id, SEL, NSIndexPath *))objc_msgSend)(self, textSel, indexPath);
        if ([text isKindOfClass:[NSString class]] && [(NSString *)text length] > 0) {
            return LBLegadoStripDisplaySuffix((NSString *)text);
        }
    }

    NSInteger row = indexPath.row;
    if (row < 0) return nil;

    SEL useSel = @selector(getUseSourceNames);
    if ([self respondsToSelector:useSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id names = [self performSelector:useSel];
#pragma clang diagnostic pop
        if ([names isKindOfClass:[NSArray class]] && (NSUInteger)row < [(NSArray *)names count]) {
            id item = [(NSArray *)names objectAtIndex:(NSUInteger)row];
            if ([item isKindOfClass:[NSString class]]) {
                return LBLegadoStripDisplaySuffix((NSString *)item);
            }
        }
    }

    SEL sortedSel = @selector(getSortedSourceNames);
    if ([self respondsToSelector:sortedSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id names = [self performSelector:sortedSel];
#pragma clang diagnostic pop
        if ([names isKindOfClass:[NSArray class]] && (NSUInteger)row < [(NSArray *)names count]) {
            id item = [(NSArray *)names objectAtIndex:(NSUInteger)row];
            if ([item isKindOfClass:[NSString class]]) {
                return LBLegadoStripDisplaySuffix((NSString *)item);
            }
        }
    }
    return nil;
}

/// 查 dicModelList[name][@"legadoBridge"] == @"1"（壳模型持久化标记）
static BOOL LBLegadoModelMarkedInDicList(id listVC, NSString *name) {
    if (name.length == 0) return NO;
    id manager = nil;
    Class managerClass = NSClassFromString(@"BookSourceModelManager");
    if (managerClass) {
        SEL sharedSel = @selector(sharedInstance);
        if ([managerClass respondsToSelector:sharedSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            manager = [managerClass performSelector:sharedSel];
#pragma clang diagnostic pop
        }
    }
    if (!manager) {
        // 部分列表 VC 可能持有 manager 属性
        @try {
            manager = [listVC valueForKey:@"manager"];
        } @catch (__unused NSException *e) {
            manager = nil;
        }
    }
    if (!manager || ![manager respondsToSelector:@selector(dicModelList)]) return NO;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id list = [manager performSelector:@selector(dicModelList)];
#pragma clang diagnostic pop
    if (![list isKindOfClass:[NSDictionary class]]) return NO;
    id model = [(NSDictionary *)list objectForKey:name];
    if ([model isKindOfClass:[NSDictionary class]]) {
        return [[(NSDictionary *)model objectForKey:@"legadoBridge"] isEqual:@"1"];
    }
    if (model) {
        @try {
            id marker = [model valueForKey:@"legadoBridge"];
            return [marker isEqual:@"1"] || [marker isEqual:@1];
        } @catch (__unused NSException *e) {
            return NO;
        }
    }
    return NO;
}

static BOOL LBLegadoShouldBlockSourceName(id listVC, NSString *name) {
    if (name.length == 0) return NO;
    if (LBLegadoIsSourceName(name)) return YES;
    return LBLegadoModelMarkedInDicList(listVC, name);
}

/// 从任意 model（NSDictionary 或原生对象）用 KVC 读源名 / legadoBridge
static BOOL LBLegadoShouldBlockModel(id model) {
    if (!model) return NO;
    NSString *name = nil;
    id marker = nil;
    if ([model isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)model;
        name = dict[@"sourceName"];
        if (name.length == 0) name = dict[@"title"];
        marker = dict[@"legadoBridge"];
    } else {
        @try {
            name = [model valueForKey:@"sourceName"];
        } @catch (__unused NSException *e) {
            name = nil;
        }
        if (![name isKindOfClass:[NSString class]] || name.length == 0) {
            @try {
                id title = [model valueForKey:@"title"];
                name = [title isKindOfClass:[NSString class]] ? title : nil;
            } @catch (__unused NSException *e) {
                name = nil;
            }
        } else if (![name isKindOfClass:[NSString class]]) {
            name = nil;
        }
        @try {
            marker = [model valueForKey:@"legadoBridge"];
        } @catch (__unused NSException *e) {
            marker = nil;
        }
    }
    if ([marker isEqual:@"1"] || [marker isEqual:@1]) return YES;
    if ([name isKindOfClass:[NSString class]] && LBLegadoIsSourceName(name)) return YES;
    return NO;
}

static void LBLegadoDeselectRow(id tableView, NSIndexPath *indexPath) {
    if (!tableView || !indexPath) return;
    if ([tableView respondsToSelector:@selector(deselectRowAtIndexPath:animated:)]) {
        ((void (*)(id, SEL, NSIndexPath *, BOOL))objc_msgSend)(
            tableView, @selector(deselectRowAtIndexPath:animated:), indexPath, YES
        );
    }
}

// 每个被 Hook 的类各自保存原 IMP，避免多类共享同一函数指针互相覆盖
typedef void (*LBDidSelectFn)(id, SEL, id, NSIndexPath *);
typedef void (*LBOpenModelFn)(id, SEL, id, BOOL);

static NSMutableDictionary<NSString *, NSValue *> *LBOrigDidSelectMap(void) {
    static NSMutableDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ map = [NSMutableDictionary dictionary]; });
    return map;
}

static NSMutableDictionary<NSString *, NSValue *> *LBOrigOpenModelMap(void) {
    static NSMutableDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ map = [NSMutableDictionary dictionary]; });
    return map;
}

static void LBConfig_tableView_didSelect_IMP(id self, SEL _cmd, id tableView, NSIndexPath *indexPath) {
    NSString *name = LBLegadoSourceNameAtIndexPath(self, indexPath);
    if (LBLegadoShouldBlockSourceName(self, name)) {
        LBLegadoDeselectRow(tableView, indexPath);
        LBLegadoOpenManagerForSourceName(name);
        return;
    }
    NSString *key = NSStringFromClass(object_getClass(self));
    NSValue *val = LBOrigDidSelectMap()[key];
    // 子类可能继承父类方法：按 isa 找不到时回退遍历已保存的原 IMP（同签名）
    if (!val) {
        Class cls = object_getClass(self);
        while (cls && !val) {
            val = LBOrigDidSelectMap()[NSStringFromClass(cls)];
            cls = class_getSuperclass(cls);
        }
    }
    if (val) {
        LBDidSelectFn orig = (LBDidSelectFn)val.pointerValue;
        if (orig) orig(self, _cmd, tableView, indexPath);
    }
}

static void LBConfig_openModel_IMP(id self, SEL _cmd, id model, BOOL createNew) {
    if (LBLegadoShouldBlockModel(model)) {
        NSString *name = nil;
        if ([model isKindOfClass:[NSDictionary class]]) {
            name = [(NSDictionary *)model objectForKey:@"sourceName"];
            if (![name isKindOfClass:[NSString class]] || name.length == 0) {
                name = [(NSDictionary *)model objectForKey:@"title"];
            }
        } else if (model) {
            @try { name = [model valueForKey:@"sourceName"]; } @catch (__unused NSException *e) { name = nil; }
            if (![name isKindOfClass:[NSString class]] || name.length == 0) {
                @try {
                    id title = [model valueForKey:@"title"];
                    name = [title isKindOfClass:[NSString class]] ? title : nil;
                } @catch (__unused NSException *e) { name = nil; }
            }
        }
        LBLegadoOpenManagerForSourceName([name isKindOfClass:[NSString class]] ? name : nil);
        return;
    }
    NSString *key = NSStringFromClass(object_getClass(self));
    NSValue *val = LBOrigOpenModelMap()[key];
    if (!val) {
        Class cls = object_getClass(self);
        while (cls && !val) {
            val = LBOrigOpenModelMap()[NSStringFromClass(cls)];
            cls = class_getSuperclass(cls);
        }
    }
    if (val) {
        LBOpenModelFn orig = (LBOpenModelFn)val.pointerValue;
        if (orig) orig(self, _cmd, model, createNew);
    }
}

/// 对「实际拥有方法」的类安装 didSelect / openModel；按类名分别保存原 IMP，避免继承链重复挂导致递归
static void LBInstallDidSelectAndOpenModelOnClass(Class requested) {
    if (!requested) return;

    SEL selectSel = @selector(tableView:didSelectRowAtIndexPath:);
    Class selectOwner = LBClassOwningInstanceMethod(requested, selectSel);
    if (selectOwner) {
        NSString *classKey = NSStringFromClass(selectOwner);
        if (!LBOrigDidSelectMap()[classKey]) {
            Method selectMethod = class_getInstanceMethod(selectOwner, selectSel);
            if (selectMethod) {
                IMP prev = method_getImplementation(selectMethod);
                LBOrigDidSelectMap()[classKey] = [NSValue valueWithPointer:prev];
                method_setImplementation(selectMethod, (IMP)LBConfig_tableView_didSelect_IMP);
                NSLog(@"[LegadoBridge] hooked %@ tableView:didSelectRowAtIndexPath: (via %@)",
                      classKey, NSStringFromClass(requested));
            }
        }
    }

    SEL openSel = @selector(openModel:createNew:);
    Class openOwner = LBClassOwningInstanceMethod(requested, openSel);
    if (openOwner) {
        NSString *classKey = NSStringFromClass(openOwner);
        if (!LBOrigOpenModelMap()[classKey]) {
            Method openMethod = class_getInstanceMethod(openOwner, openSel);
            if (openMethod) {
                IMP prev = method_getImplementation(openMethod);
                LBOrigOpenModelMap()[classKey] = [NSValue valueWithPointer:prev];
                method_setImplementation(openMethod, (IMP)LBConfig_openModel_IMP);
                NSLog(@"[LegadoBridge] hooked %@ openModel:createNew: (via %@)",
                      classKey, NSStringFromClass(requested));
            }
        }
    }
}

static void LBInstallNativeSourceListLegadoButton(void);

void LBInstallSourceListHooks(void) {
    @try {
    Class managerClass = NSClassFromString(@"BookSourceModelManager");
    if (!managerClass) {
        NSLog(@"[LegadoBridge] BookSourceModelManager not found, skip source list hooks");
        LBCapabilityMarkSkipped(LBHookGroupSourceList, @"BookSourceModelManager missing");
        return;
    }

    SEL sortedSel = @selector(getSortedSourceNames);
    Method sortedMethod = class_getInstanceMethod(managerClass, sortedSel);
    if (sortedMethod) {
        LBOrig_BSM_getSortedSourceNames = (NSArray * (*)(id, SEL))method_getImplementation(sortedMethod);
        method_setImplementation(sortedMethod, (IMP)LBBSM_getSortedSourceNames_IMP);
        NSLog(@"[LegadoBridge] hooked BookSourceModelManager getSortedSourceNames");
    }

    SEL sortedPriSel = @selector(getSortedSourceNamesByPrioritySourceType:);
    Method sortedPriMethod = class_getInstanceMethod(managerClass, sortedPriSel);
    if (sortedPriMethod) {
        LBOrig_BSM_getSortedSourceNamesByPriority =
            (NSArray * (*)(id, SEL, id))method_getImplementation(sortedPriMethod);
        method_setImplementation(sortedPriMethod, (IMP)LBBSM_getSortedSourceNamesByPriority_IMP);
        NSLog(@"[LegadoBridge] hooked BookSourceModelManager getSortedSourceNamesByPrioritySourceType:");
    }

    SEL listSel = @selector(dicModelList);
    Method listMethod = class_getInstanceMethod(managerClass, listSel);
    if (listMethod) {
        LBOrig_BSM_dicModelList = (NSDictionary * (*)(id, SEL))method_getImplementation(listMethod);
        method_setImplementation(listMethod, (IMP)LBBSM_dicModelList_IMP);
        NSLog(@"[LegadoBridge] hooked BookSourceModelManager dicModelList");
    }

    SEL typeSel = @selector(sourceTypeBySourceName:);
    Method typeMethod = class_getInstanceMethod(managerClass, typeSel);
    if (typeMethod) {
        LBOrig_BSM_sourceTypeBySourceName = (NSString * (*)(id, SEL, NSString *))method_getImplementation(typeMethod);
        method_setImplementation(typeMethod, (IMP)LBBSM_sourceTypeBySourceName_IMP);
        NSLog(@"[LegadoBridge] hooked BookSourceModelManager sourceTypeBySourceName:");
    }

    SEL titleSel = @selector(sourceTypeTitleBySourceName:);
    Method titleMethod = class_getInstanceMethod(managerClass, titleSel);
    if (titleMethod) {
        LBOrig_BSM_sourceTypeTitleBySourceName = (NSString * (*)(id, SEL, NSString *))method_getImplementation(titleMethod);
        method_setImplementation(titleMethod, (IMP)LBBSM_sourceTypeTitleBySourceName_IMP);
        NSLog(@"[LegadoBridge] hooked BookSourceModelManager sourceTypeTitleBySourceName:");
    }

    Class listBaseClass = NSClassFromString(@"ConfigSourceListBase");
    if (listBaseClass) {
        SEL groupSel = @selector(getGroupData);
        Method groupMethod = class_getInstanceMethod(listBaseClass, groupSel);
        if (groupMethod) {
            LBOrig_Config_getGroupData = (id (*)(id, SEL))method_getImplementation(groupMethod);
            method_setImplementation(groupMethod, (IMP)LBConfig_getGroupData_IMP);
            NSLog(@"[LegadoBridge] hooked ConfigSourceListBase getGroupData");
        }
    }

    // getUseSourceNames：挂到实际拥有该方法的类（按类分别保存原 IMP）
    NSArray<NSString *> *useNameClasses = @[
        @"ConfigSourceModelListCon",
        @"ConfigSourceModelListCon_NoneSourceModel",
        @"ConfigSourceListBase",
        @"ConfigSourceModelConBase"
    ];
    for (NSString *cn in useNameClasses) {
        Class requested = NSClassFromString(cn);
        if (!requested) continue;
        Class owner = LBClassOwningInstanceMethod(requested, @selector(getUseSourceNames));
        if (!owner) continue;
        NSString *ownerKey = NSStringFromClass(owner);
        if (LBOrigGetUseSourceNamesMap()[ownerKey]) continue;
        Method useMethod = class_getInstanceMethod(owner, @selector(getUseSourceNames));
        if (!useMethod) continue;
        IMP prev = method_getImplementation(useMethod);
        LBOrigGetUseSourceNamesMap()[ownerKey] = [NSValue valueWithPointer:prev];
        if (!LBOrig_Config_getUseSourceNames) {
            LBOrig_Config_getUseSourceNames = (NSArray * (*)(id, SEL))prev;
        }
        method_setImplementation(useMethod, (IMP)LBConfig_getUseSourceNames_IMP);
        NSLog(@"[LegadoBridge] hooked %@ getUseSourceNames (via %@)", ownerKey, cn);
    }

    // didSelect / openModel：多类安装，覆盖逆向确认的列表实现类
    NSArray<NSString *> *tapHookClasses = @[
        @"ConfigSourceModelListCon",
        @"ConfigSourceModelListCon_NoneSourceModel",
        @"ConfigSourceListBase",
        @"ConfigSourceModelConBase"
    ];
    NSMutableArray *hooked = [NSMutableArray array];
    for (NSString *cn in tapHookClasses) {
        Class c = NSClassFromString(cn);
        if (!c) {
            NSLog(@"[LegadoBridge] class %@ not found, skip tap hooks", cn);
            continue;
        }
        LBInstallDidSelectAndOpenModelOnClass(c);
        [hooked addObject:cn];
    }
    NSString *marker = [NSString stringWithFormat:@"tapHooks=%@", [hooked componentsJoinedByString:@","]];
    [marker writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_tap_hooks.txt"]
             atomically:YES encoding:NSUTF8StringEncoding error:NULL];

    LBInstallNativeSourceListLegadoButton();
    LBInstallInvertAvailabilityGuard();
    LBInstallSourceListUpdateObserver();
    LBCapabilityMarkEnabled(LBHookGroupSourceList, [NSString stringWithFormat:@"tap=%@", [hooked componentsJoinedByString:@","]]);
    } @catch (NSException *e) {
        LBCapabilityMarkFailed(LBHookGroupSourceList, e.reason ?: @"exception");
        NSLog(@"[LegadoBridge] source list hooks exception: %@", e);
    }
}

/// 站点管理页「Legado」按钮的 target（替代启动强弹窗入口）
@interface LBLegadoBarButtonTarget : NSObject
+ (instancetype)shared;
- (void)onLegadoTapped;
- (void)onNativeImportTapped;
@end

@implementation LBLegadoBarButtonTarget
+ (instancetype)shared {
    static LBLegadoBarButtonTarget *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [LBLegadoBarButtonTarget new]; });
    return inst;
}
- (void)onLegadoTapped {
    LBPresentLegadoSourceManager(nil);
}
- (void)onNativeImportTapped {
    // U3：原版「导入」→ ConfigSourceModelSyncCon；失败再 UIAlert（含 Legado URL/粘贴）
    [@"tap onNativeImportTapped" writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_u3_tap.txt"]
                                  atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    if (!LBLegadoPresentNativeImport()) {
        LBShowLegadoImportAlert();
    }
}
@end

static void LBRebindImportButtonsInView(UIView *view) {
    if (!view) return;
    if ([view isKindOfClass:[UIButton class]]) {
        UIButton *btn = (UIButton *)view;
        NSString *t = btn.currentTitle ?: [btn titleForState:UIControlStateNormal] ?: @"";
        // 无障碍标签有时比 title 更准
        NSString *acc = btn.accessibilityLabel ?: @"";
        if ([t isEqualToString:@"导入"] || [acc isEqualToString:@"导入"]) {
            [btn removeTarget:nil action:NULL forControlEvents:UIControlEventTouchUpInside];
            [btn addTarget:[LBLegadoBarButtonTarget shared]
                    action:@selector(onNativeImportTapped)
          forControlEvents:UIControlEventTouchUpInside];
            [@"rebind import navbar-btn" writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_u3_rebind.txt"]
                                          atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        }
    }
    for (UIView *sub in view.subviews) {
        LBRebindImportButtonsInView(sub);
    }
}

static void LBInstallNativeSourceListLegadoButton(void) {
    static NSMutableSet *installed;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ installed = [NSMutableSet set]; });

    NSArray<NSString *> *barHookClasses = @[
        @"ConfigSourceModelListCon",
        @"ConfigSourceModelListCon_NoneSourceModel",
        @"ConfigSourceListBase"
    ];
    for (NSString *cn in barHookClasses) {
        Class c = NSClassFromString(cn);
        if (!c) continue;
        Class owner = LBClassOwningInstanceMethod(c, @selector(viewDidAppear:));
        if (!owner) continue;
        NSString *ownerKey = NSStringFromClass(owner);
        if ([installed containsObject:ownerKey]) continue;
        Method m = class_getInstanceMethod(owner, @selector(viewDidAppear:));
        if (!m) continue;
        IMP prev = method_getImplementation(m);
        IMP hook = imp_implementationWithBlock(^void(id selfObj, BOOL animated) {
            ((void (*)(id, SEL, BOOL))prev)(selfObj, @selector(viewDidAppear:), animated);
            if (![selfObj isKindOfClass:[UIViewController class]]) return;
            UIViewController *vc = (UIViewController *)selfObj;
            UINavigationItem *item = vc.navigationItem;
            BOOL hasLegadoBtn = NO;
            for (UIBarButtonItem *bi in item.rightBarButtonItems ?: @[]) {
                if ([bi.accessibilityIdentifier isEqualToString:@"legado.manage.entry"]) {
                    hasLegadoBtn = YES;
                }
                // U3：把原版「导入」接到 SyncCon / Legado 导入链（标题或 customView UIButton）
                if ([bi.accessibilityIdentifier isEqualToString:@"legado.import.entry"]) {
                    continue;
                }
                BOOL isImport = [bi.title isEqualToString:@"导入"];
                if (!isImport && [bi.customView isKindOfClass:[UIButton class]]) {
                    UIButton *btn = (UIButton *)bi.customView;
                    NSString *t = btn.currentTitle ?: @"";
                    if (t.length == 0) {
                        t = [btn titleForState:UIControlStateNormal] ?: @"";
                    }
                    isImport = [t isEqualToString:@"导入"];
                    if (isImport) {
                        [btn removeTarget:nil action:NULL forControlEvents:UIControlEventTouchUpInside];
                        [btn addTarget:[LBLegadoBarButtonTarget shared]
                                action:@selector(onNativeImportTapped)
                      forControlEvents:UIControlEventTouchUpInside];
                        bi.accessibilityIdentifier = @"legado.import.entry";
                        [@"rebind import customView" writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_u3_rebind.txt"]
                                                      atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                        continue;
                    }
                }
                if (isImport) {
                    bi.target = [LBLegadoBarButtonTarget shared];
                    bi.action = @selector(onNativeImportTapped);
                    bi.accessibilityIdentifier = @"legado.import.entry";
                    [@"rebind import bar" writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_u3_rebind.txt"]
                                           atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                }
            }
            if (!hasLegadoBtn) {
                UIBarButtonItem *legadoBtn = [[UIBarButtonItem alloc]
                    initWithTitle:@"书源"
                    style:UIBarButtonItemStylePlain
                    target:[LBLegadoBarButtonTarget shared]
                    action:@selector(onLegadoTapped)];
                legadoBtn.accessibilityIdentifier = @"legado.manage.entry";
                NSMutableArray *rights = [item.rightBarButtonItems mutableCopy] ?: [NSMutableArray array];
                [rights insertObject:legadoBtn atIndex:0];
                item.rightBarButtonItems = rights;
            }
            // 导航栏子视图再扫一遍（部分构建「导入」是自定义 UIButton）
            UINavigationController *nav = vc.navigationController;
            if (nav.navigationBar) {
                LBRebindImportButtonsInView(nav.navigationBar);
            }
        });
        method_setImplementation(m, hook);
        [installed addObject:ownerKey];
        NSLog(@"[LegadoBridge] hooked %@ viewDidAppear: for Legado bar button", ownerKey);
    }
}

#pragma mark - A-09 反转可用性 fail-open

/// 对勾选源中的注入源走 Core 启停；原生路径包 @try，避免踢回主屏
static void LBToggleLegadoSourcesByNames(NSArray *names) {
    if (names.count == 0) return;
    id core = LBLegadoCoreIfReady();
    if (!core) return;
    for (id raw in names) {
        if (![raw isKindOfClass:[NSString class]]) continue;
        NSString *name = LBLegadoStripDisplaySuffix((NSString *)raw);
        NSDictionary *model = LBLegadoNativeModel(name);
        NSString *url = nil;
        if ([model isKindOfClass:[NSDictionary class]]) {
            url = model[@"bookSourceUrl"] ?: model[@"sourceUrl"] ?: model[@"legadoBookSourceUrl"];
        }
        if (url.length == 0 && core && [core respondsToSelector:@selector(allSourcesInfo)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            for (NSDictionary *dict in [core performSelector:@selector(allSourcesInfo)]) {
                if (![dict isKindOfClass:[NSDictionary class]]) continue;
                NSString *n = dict[@"bookSourceName"];
                if ([n isKindOfClass:[NSString class]] &&
                    ([n isEqualToString:name] || [name hasSuffix:n] || [n isEqualToString:[name stringByReplacingOccurrencesOfString:@"·Legado" withString:@""]])) {
                    url = dict[@"bookSourceUrl"];
                    break;
                }
            }
#pragma clang diagnostic pop
        }
        if (url.length == 0) continue;
        BOOL enabled = YES;
        if ([core respondsToSelector:@selector(isSourceEnabled:)]) {
            enabled = ((BOOL (*)(id, SEL, NSString *))objc_msgSend)(core, @selector(isSourceEnabled:), url);
        } else {
            id en = model[@"enable"];
            if ([en isKindOfClass:[NSString class]]) enabled = [en isEqualToString:@"1"];
            else if ([en isKindOfClass:[NSNumber class]]) enabled = [en boolValue];
        }
        if ([core respondsToSelector:@selector(setSourceEnabled:enabled:)]) {
            ((void (*)(id, SEL, NSString *, BOOL))objc_msgSend)(
                core, @selector(setSourceEnabled:enabled:), url, !enabled
            );
        }
    }
}

static NSArray *LBCollectSelectedSourceNames(id listVC) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *key in @[@"arrSelectedSourceNames", @"selectedSourceNames", @"arrSelected", @"selectedNames"]) {
        @try {
            id v = [listVC valueForKey:key];
            if ([v isKindOfClass:[NSArray class]]) {
                for (id item in (NSArray *)v) {
                    if ([item isKindOfClass:[NSString class]]) [out addObject:item];
                    else if ([item isKindOfClass:[NSDictionary class]]) {
                        NSString *n = item[@"sourceName"] ?: item[@"bookSourceName"] ?: item[@"title"];
                        if ([n isKindOfClass:[NSString class]]) [out addObject:n];
                    }
                }
            }
        } @catch (__unused NSException *e) {}
    }
    // indexPathsForSelectedRows
    @try {
        UITableView *tv = nil;
        if ([listVC respondsToSelector:@selector(tableView)]) {
            tv = ((UITableView *(*)(id, SEL))objc_msgSend)(listVC, @selector(tableView));
        }
        if ([tv isKindOfClass:[UITableView class]]) {
            for (NSIndexPath *ip in tv.indexPathsForSelectedRows ?: @[]) {
                NSString *n = LBLegadoSourceNameAtIndexPath(listVC, ip);
                if (n.length) [out addObject:n];
            }
        }
    } @catch (__unused NSException *e) {}
    return out;
}

void LBPostSourceListRefresh(void) {
    // 原生监听 dNotifyName_UpdateBookSourceModelList；旧错误名一并发以防漏网
    @try {
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc postNotificationName:@"dNotifyName_UpdateBookSourceModelList" object:nil];
        [nc postNotificationName:@"dNotifyName_UpdateSourceList" object:nil];
    } @catch (__unused NSException *e) {}
}

static void LBTryReloadSourceListVC(UIViewController *vc) {
    if (!vc) return;
    NSString *cn = NSStringFromClass(vc.class);
    BOOL isSourceUI =
        [cn containsString:@"ConfigSource"] ||
        [cn containsString:@"SourceModel"] ||
        [cn isEqualToString:@"LBLegadoSourceManagerVC"];
    if (!isSourceUI) return;

    @try {
        if ([vc respondsToSelector:@selector(reloadSources)]) {
            ((void (*)(id, SEL))objc_msgSend)(vc, @selector(reloadSources));
            return;
        }
    } @catch (__unused NSException *e) {}
    @try {
        if ([vc respondsToSelector:@selector(reloadData)]) {
            ((void (*)(id, SEL))objc_msgSend)(vc, @selector(reloadData));
        }
    } @catch (__unused NSException *e) {}
    @try {
        UITableView *tv = nil;
        if ([vc respondsToSelector:@selector(tableView)]) {
            tv = ((UITableView *(*)(id, SEL))objc_msgSend)(vc, @selector(tableView));
        }
        if ([tv isKindOfClass:[UITableView class]]) {
            [tv reloadData];
        }
    } @catch (__unused NSException *e) {}
    // 常见原生刷新入口
    for (NSString *selName in @[@"refresh", @"onRefresh", @"reload", @"loadData", @"reloadSourceList"]) {
        SEL sel = NSSelectorFromString(selName);
        if (![vc respondsToSelector:sel]) continue;
        @try {
            ((void (*)(id, SEL))objc_msgSend)(vc, sel);
        } @catch (__unused NSException *e) {}
    }
}

static void LBWalkReloadSourceListVCs(UIViewController *root) {
    if (!root) return;
    LBTryReloadSourceListVC(root);
    for (UIViewController *child in root.childViewControllers) {
        LBWalkReloadSourceListVCs(child);
    }
    if (root.presentedViewController) {
        LBWalkReloadSourceListVCs(root.presentedViewController);
    }
    if ([root isKindOfClass:[UINavigationController class]]) {
        for (UIViewController *vc in ((UINavigationController *)root).viewControllers) {
            LBWalkReloadSourceListVCs(vc);
        }
    }
    if ([root isKindOfClass:[UITabBarController class]]) {
        for (UIViewController *vc in ((UITabBarController *)root).viewControllers ?: @[]) {
            LBWalkReloadSourceListVCs(vc);
        }
    }
}

void LBRefreshVisibleSourceListUIs(void) {
    void (^work)(void) = ^{
        LBInvalidateSourceListMergeCache();
        LBPostSourceListRefresh();
        // AK：仅主线程碰 windows
        UIWindow *window = LBLegadoKeyWindow();
        if (!window) return;
        LBWalkReloadSourceListVCs(window.rootViewController);
        // 再扫一层可见 window（部分弹层挂在独立 window）
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            if (scene.activationState != UISceneActivationStateForegroundActive &&
                scene.activationState != UISceneActivationStateForegroundInactive) {
                continue;
            }
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (!w.isHidden) LBWalkReloadSourceListVCs(w.rootViewController);
            }
        }
    };
    if ([NSThread isMainThread]) {
        work();
    } else {
        dispatch_async(dispatch_get_main_queue(), work);
    }
}

static void LBOnBookSourceModelListUpdated(NSNotification *note) {
    (void)note;
    LBInvalidateSourceListMergeCache();
    // 不递归再 post；只刷可见 VC
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = LBLegadoKeyWindow();
        if (window) LBWalkReloadSourceListVCs(window.rootViewController);
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            if (scene.activationState != UISceneActivationStateForegroundActive &&
                scene.activationState != UISceneActivationStateForegroundInactive) {
                continue;
            }
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (!w.isHidden) LBWalkReloadSourceListVCs(w.rootViewController);
            }
        }
    });
}

static void LBInstallSourceListUpdateObserver(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserverForName:@"dNotifyName_UpdateBookSourceModelList"
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification *note) {
            LBOnBookSourceModelListUpdated(note);
        }];
        [nc addObserverForName:@"dNotifyName_UpdateSourceList"
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification *note) {
            LBOnBookSourceModelListUpdated(note);
        }];
    });
}

/// 拆分勾选源：注入源走 Core，原生源才调 onFanzhuanEvent
static void LBInvertAvailabilityForListVC(id listVC) {
    if (!listVC) return;
    NSArray *names = LBCollectSelectedSourceNames(listVC);
    NSMutableArray *legadoNames = [NSMutableArray array];
    BOOL hasNative = NO;
    for (id raw in names) {
        if (![raw isKindOfClass:[NSString class]]) continue;
        NSString *name = LBLegadoStripDisplaySuffix((NSString *)raw);
        if (LBLegadoIsSourceName(name) || LBLegadoModelMarkedInDicList(listVC, name)) {
            [legadoNames addObject:name];
        } else {
            hasNative = YES;
        }
    }
    LBToggleLegadoSourcesByNames(legadoNames);
    if (!hasNative) {
        LBPostSourceListRefresh();
        NSString *msg = [NSString stringWithFormat:@"invert legadoOnly n=%lu", (unsigned long)legadoNames.count];
        [msg writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_a09_invert.txt"]
              atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return;
    }
}

typedef void (*LBOnFanzhuanFn)(id, SEL);

static NSMutableDictionary<NSString *, NSValue *> *LBOrigOnFanzhuanMap(void) {
    static NSMutableDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ map = [NSMutableDictionary dictionary]; });
    return map;
}

static void LBConfig_onFanzhuanEvent_IMP(id self, SEL _cmd) {
    @try {
        LBInvertAvailabilityForListVC(self);
        NSArray *names = LBCollectSelectedSourceNames(self);
        BOOL hasNative = NO;
        for (id raw in names) {
            if (![raw isKindOfClass:[NSString class]]) continue;
            NSString *name = LBLegadoStripDisplaySuffix((NSString *)raw);
            if (!LBLegadoIsSourceName(name) && !LBLegadoModelMarkedInDicList(self, name)) {
                hasNative = YES;
                break;
            }
        }
        if (!hasNative) return;
        NSString *key = NSStringFromClass(object_getClass(self));
        NSValue *val = LBOrigOnFanzhuanMap()[key];
        if (!val) {
            Class cls = object_getClass(self);
            while (cls && !val) {
                val = LBOrigOnFanzhuanMap()[NSStringFromClass(cls)];
                cls = class_getSuperclass(cls);
            }
        }
        if (val) {
            LBOnFanzhuanFn orig = (LBOnFanzhuanFn)val.pointerValue;
            if (orig) {
                @try {
                    orig(self, _cmd);
                } @catch (NSException *e) {
                    NSString *msg = [NSString stringWithFormat:@"invert native fail-open: %@", e.reason ?: @""];
                    [msg writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_a09_invert.txt"]
                          atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                    NSLog(@"[LegadoBridge] %@", msg);
                    LBPostSourceListRefresh();
                }
            }
        }
    } @catch (NSException *e) {
        NSString *msg = [NSString stringWithFormat:@"invert outer fail-open: %@", e.reason ?: @""];
        [msg writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_a09_invert.txt"]
              atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        NSLog(@"[LegadoBridge] %@", msg);
    }
}

static void LBInstallOnFanzhuanHookOnClass(Class requested) {
    if (!requested) return;
    SEL sel = NSSelectorFromString(@"onFanzhuanEvent");
    Class owner = LBClassOwningInstanceMethod(requested, sel);
    if (!owner) return;
    NSString *ownerKey = NSStringFromClass(owner);
    if (LBOrigOnFanzhuanMap()[ownerKey]) return;
    Method m = class_getInstanceMethod(owner, sel);
    if (!m) return;
    IMP prev = method_getImplementation(m);
    LBOrigOnFanzhuanMap()[ownerKey] = [NSValue valueWithPointer:prev];
    method_setImplementation(m, (IMP)LBConfig_onFanzhuanEvent_IMP);
    NSLog(@"[LegadoBridge] hooked %@ onFanzhuanEvent (via %@)", ownerKey, NSStringFromClass(requested));
}

static void LBInstallInvertAvailabilityGuard(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray<NSString *> *fanzhuanClasses = @[
            @"ConfigSourceModelListCon",
            @"ConfigSourceModelListCon_NoneSourceModel",
            @"ConfigSourceListBase",
            @"ConfigSourceModelConBase"
        ];
        for (NSString *cn in fanzhuanClasses) {
            LBInstallOnFanzhuanHookOnClass(NSClassFromString(cn));
        }
        NSLog(@"[LegadoBridge] A-09 onFanzhuanEvent guard installed");
    });
}
