#import "LBInternal.h"
#import "LegadoBridge.h"

// 书源列表组

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
    return merged;
}

static NSDictionary *LBBSM_dicModelList_IMP(id self, SEL _cmd) {
    NSDictionary *orig = LBOrig_BSM_dicModelList ? LBOrig_BSM_dicModelList(self, _cmd) : @{};
    NSArray *legadoNames = LBLegadoGetSourceNames();
    if (legadoNames.count == 0) return orig ?: @{};
    NSMutableDictionary *merged = [orig mutableCopy];
    if (!merged) merged = [NSMutableDictionary dictionary];
    for (NSString *name in legadoNames) {
        NSDictionary *model = LBLegadoNativeModel(name);
        if (model) merged[name] = model;
    }
    return merged;
}

static NSString *LBBSM_sourceTypeBySourceName_IMP(id self, SEL _cmd, NSString *name) {
    if (LBLegadoIsSourceName(name)) return @"DOM";
    if (LBOrig_BSM_sourceTypeBySourceName) {
        return LBOrig_BSM_sourceTypeBySourceName(self, _cmd, name);
    }
    return @"DOM";
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
    NSString *dbg = [NSString stringWithFormat:@"origClass=%@ legado=%lu",
                     orig ? NSStringFromClass([orig class]) : @"(nil)",
                     (unsigned long)legadoNames.count];
    [dbg writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_getgroupdata_hook.txt"]
          atomically:YES encoding:NSUTF8StringEncoding error:NULL];
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

/// 点击原生列表中的 Legado 源时，打开对应源的编辑器
static void LBLegadoOpenManagerForSourceName(NSString *name) {
    if (name.length == 0) {
        LBLegadoPresentManagerVC(nil);
        return;
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
            if ([n isKindOfClass:[NSString class]] && [n isEqualToString:name]) {
                focusUrl = dict[@"bookSourceUrl"];
                break;
            }
        }
    }
    LBLegadoPresentManagerVC(focusUrl);
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
    LBCapabilityMarkEnabled(LBHookGroupSourceList, [NSString stringWithFormat:@"tap=%@", [hooked componentsJoinedByString:@","]]);
    } @catch (NSException *e) {
        LBCapabilityMarkFailed(LBHookGroupSourceList, e.reason ?: @"exception");
        NSLog(@"[LegadoBridge] source list hooks exception: %@", e);
    }
}

static void LBInstallNativeSourceListLegadoButton(void);

/// 站点管理页「Legado」按钮的 target（替代启动强弹窗入口）
@interface LBLegadoBarButtonTarget : NSObject
+ (instancetype)shared;
- (void)onLegadoTapped;
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
@end

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
            for (UIBarButtonItem *bi in item.rightBarButtonItems ?: @[]) {
                if ([bi.accessibilityIdentifier isEqualToString:@"legado.manage.entry"]) return;
            }
            UIBarButtonItem *legadoBtn = [[UIBarButtonItem alloc]
                initWithTitle:@"Legado"
                style:UIBarButtonItemStylePlain
                target:[LBLegadoBarButtonTarget shared]
                action:@selector(onLegadoTapped)];
            legadoBtn.accessibilityIdentifier = @"legado.manage.entry";
            NSMutableArray *rights = [item.rightBarButtonItems mutableCopy] ?: [NSMutableArray array];
            [rights insertObject:legadoBtn atIndex:0];
            item.rightBarButtonItems = rights;
        });
        method_setImplementation(m, hook);
        [installed addObject:ownerKey];
        NSLog(@"[LegadoBridge] hooked %@ viewDidAppear: for Legado bar button", ownerKey);
    }
}
