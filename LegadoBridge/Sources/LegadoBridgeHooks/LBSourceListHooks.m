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
static char kLBSelectedDiscoverSourceNameKey;

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
        if (!model) continue;
        NSString *key = name;
        NSDictionary *existing = [merged[name] isKindOfClass:[NSDictionary class]]
            ? merged[name] : nil;
        id marker = existing[@"legadoBridge"];
        if (existing && ![marker isEqual:@"1"] && ![marker isEqual:@1]) {
            key = [name stringByAppendingString:@"·Legado"];
            NSMutableDictionary *disambiguated = [model mutableCopy];
            disambiguated[@"sourceName"] = key;
            disambiguated[@"bookSourceName"] = key;
            disambiguated[@"title"] = key;
            model = disambiguated;
        }
        merged[key] = model;
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

/// T3：切换站点右侧索引条含大量空串/"|" 垫片，原生把它们映射到 section0（TOP）。
/// TOP 段常为 0 行时，点垫片会「回顶」，看起来像索引失灵。显式 Top 仍回顶；垫片改落到最近有行段。
static NSInteger (*LBOrig_Config_sectionForIndexTitle)(id, SEL, UITableView *, NSString *, NSInteger) = NULL;

static NSInteger LBConfig_sectionForIndexTitle_IMP(id self, SEL _cmd, UITableView *tableView,
                                                   NSString *title, NSInteger index) {
    NSInteger sec = 0;
    if (LBOrig_Config_sectionForIndexTitle) {
        sec = LBOrig_Config_sectionForIndexTitle(self, _cmd, tableView, title, index);
    }
    if (![tableView isKindOfClass:[UITableView class]]) return sec;
    @try {
        NSInteger nSec = [tableView numberOfSections];
        if (sec < 0 || sec >= nSec) return sec;
        // 只纠正「误落到空 TOP」；图/音/视空段仍按原生滚到该段头
        if (sec != 0) return sec;
        if ([tableView numberOfRowsInSection:0] > 0) return sec;
        NSString *t = [title isKindOfClass:[NSString class]] ? title : @"";
        BOOL explicitTop = (t.length > 0) &&
            ([t caseInsensitiveCompare:@"Top"] == NSOrderedSame || [t isEqualToString:@"TOP"]);
        if (explicitTop) return sec;
        for (NSInteger s = 1; s < nSec; s++) {
            if ([tableView numberOfRowsInSection:s] > 0) return s;
        }
    } @catch (__unused NSException *e) {}
    return sec;
}

static void (*LBOrig_SwitchVC_viewWillAppear)(id, SEL, BOOL) = NULL;

static void LBSwitchVC_viewWillAppear_IMP(id self, SEL _cmd, BOOL animated) {
    if (LBOrig_SwitchVC_viewWillAppear) LBOrig_SwitchVC_viewWillAppear(self, _cmd, animated);
    objc_setAssociatedObject(self, &kLBSelectedDiscoverSourceNameKey, nil,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    // 防御：发现页 pinPageSV 曾误伤过内部表；切换面板打开时强制可滚
    @try {
        UITableView *tv = nil;
        if ([self isKindOfClass:[UITableViewController class]]) {
            tv = [(UITableViewController *)self tableView];
        }
        if (!tv) {
            @try { tv = [self valueForKey:@"tableView"]; } @catch (__unused NSException *e) { tv = nil; }
        }
        if ([tv isKindOfClass:[UITableView class]]) {
            tv.scrollEnabled = YES;
            tv.userInteractionEnabled = YES;
            UIPanGestureRecognizer *pan = tv.panGestureRecognizer;
            if (pan) pan.enabled = YES;
        }
    } @catch (__unused NSException *e) {}
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
        NSString *displayName = [orig containsObject:name]
            ? [name stringByAppendingString:@"·Legado"]
            : name;
        [merged addObject:displayName];
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

#pragma mark - B4 阅读换源（BookSourceSwitchVC2）

static void (*LBOrig_SwitchVC_didSelect)(id, SEL, id, NSIndexPath *) = NULL;
static void (*LBOrig_SwitchVC_onOk)(id, SEL) = NULL;
static void (*LBOrig_SwitchVC_onOkArg)(id, SEL, id) = NULL;

/// 切换面板可能是 present 也可能是 push，两种都关
static void LBSwitchVC_DismissSwitchPanel(id switchVC) {
    if (!switchVC) return;
    @try {
        UIViewController *vc = [switchVC isKindOfClass:[UIViewController class]]
            ? (UIViewController *)switchVC : nil;
        if (!vc) return;
        if (vc.presentingViewController) {
            [vc dismissViewControllerAnimated:NO completion:nil];
            return;
        }
        UINavigationController *nav = vc.navigationController;
        if (nav && nav.topViewController == vc) {
            [nav popViewControllerAnimated:NO];
            return;
        }
        if (nav) {
            NSMutableArray *stack = [nav.viewControllers mutableCopy];
            if ([stack containsObject:vc]) {
                [stack removeObject:vc];
                [nav setViewControllers:stack animated:NO];
                return;
            }
        }
        // 兜底：仍尝试 dismiss
        [vc dismissViewControllerAnimated:NO completion:nil];
    } @catch (__unused NSException *e) {}
}

static NSString *LBSwitchVC_BookField(id book, NSArray<NSString *> *keys) {
    if (!book || keys.count == 0) return nil;
    for (NSString *k in keys) {
        id v = nil;
        if ([book isKindOfClass:[NSDictionary class]]) {
            v = [(NSDictionary *)book objectForKey:k];
        } else {
            @try { v = [book valueForKey:k]; } @catch (__unused NSException *e) { v = nil; }
        }
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) return (NSString *)v;
        if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v stringValue];
    }
    return nil;
}

static NSInteger LBSwitchVC_BookIndex(id book) {
    NSArray *keys = @[@"cpIndex", @"chapterIndex", @"curChapterIndex", @"index"];
    for (NSString *k in keys) {
        id v = nil;
        if ([book isKindOfClass:[NSDictionary class]]) {
            v = [(NSDictionary *)book objectForKey:k];
        } else {
            @try { v = [book valueForKey:k]; } @catch (__unused NSException *e) { v = nil; }
        }
        if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v integerValue];
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) {
            return [(NSString *)v integerValue];
        }
    }
    return -1;
}

static NSString *LBSwitchVC_ResolveSourceUrl(NSString *name) {
    if (name.length == 0) return nil;
    NSString *lookup = name;
    if ([name hasSuffix:@"·Legado"]) {
        lookup = [name substringToIndex:name.length - @"·Legado".length];
    }
    NSDictionary *model = LBLegadoNativeModel(lookup);
    if (!model) model = LBLegadoNativeModel(name);
    if ([model isKindOfClass:[NSDictionary class]]) {
        NSString *url = model[@"bookSourceUrl"] ?: model[@"sourceUrl"] ?: model[@"url"];
        if ([url isKindOfClass:[NSString class]] && url.length > 0) return url;
    }
    // CoreIfReady 可能因初始化闸门返回 nil；换源路径直接 shared
    id core = LBLegadoCoreIfReady();
    if (!core) {
        Class cls = NSClassFromString(@"LegadoBridge.LegadoBridgeCore");
        if (cls) {
            core = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(shared));
        }
    }
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
                NSString *url = dict[@"bookSourceUrl"];
                if ([url isKindOfClass:[NSString class]] && url.length > 0) return url;
            }
        }
    }
    return nil;
}

static void LBSwitchVC_StartLegadoSwitch(id switchVC, NSString *sourceName) {
    if (!switchVC || sourceName.length == 0) return;
    NSString *srcUrl = LBSwitchVC_ResolveSourceUrl(sourceName);
    if (srcUrl.length == 0) {
        NSString *miss = [NSString stringWithFormat:@"fail noUrl name=%@\n", sourceName];
        [miss writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_b4_switch_start.txt"]
               atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        LBLegadoShowResult(@"未找到该 Legado 源");
        return;
    }
    id book = nil;
    @try { book = [switchVC valueForKey:@"dicBook"]; } @catch (__unused NSException *e) {}
    if (!book) {
        @try { book = [switchVC valueForKey:@"dicFatBook"]; } @catch (__unused NSException *e) {}
    }
    NSString *bookName = LBSwitchVC_BookField(book, @[@"bookName", @"name", @"title", @"novelName"]);
    NSString *author = LBSwitchVC_BookField(book, @[@"author", @"writer"]);
    NSString *oldUrl = LBSwitchVC_BookField(book, @[@"bookUrl", @"url", @"detailUrl", @"novelUrl"]);
    NSString *chapterTitle = LBSwitchVC_BookField(book, @[@"cpTitle", @"chapterName", @"chapterTitle", @"lastChapterTitle"]);
    // 阅读页 title 常是章名，避免把章名当书名
    if (bookName.length == 0 || [bookName isEqualToString:chapterTitle]) {
        NSString *alt = LBSwitchVC_BookField(book, @[@"bookName", @"name", @"novelName"]);
        if (alt.length > 0) bookName = alt;
    }
    NSInteger chapterIndex = LBSwitchVC_BookIndex(book);
    if (bookName.length == 0) {
        NSString *miss = [NSString stringWithFormat:@"fail noBookName src=%@\n", srcUrl];
        [miss writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_b4_switch_start.txt"]
               atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        LBLegadoShowResult(@"无法换源：缺少书名");
        return;
    }
    if (oldUrl.length == 0) oldUrl = @"";

    id core = LBLegadoCoreIfReady();
    if (!core) {
        Class cls = NSClassFromString(@"LegadoBridge.LegadoBridgeCore");
        if (cls) core = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(shared));
    }
    SEL sel = @selector(switchReadingSourceWithBookName:author:oldBookUrl:newSourceUrl:chapterTitle:chapterIndex:);
    if (!core || ![core respondsToSelector:sel]) {
        NSString *miss = [NSString stringWithFormat:@"fail noAPI core=%d\n", core ? 1 : 0];
        [miss writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_b4_switch_start.txt"]
               atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        LBLegadoShowResult(@"换源接口不可用");
        return;
    }
    NSString *probe = [NSString stringWithFormat:
                       @"start name=%@ src=%@ book=%@ old=%@ ch=%@ idx=%ld\n",
                       sourceName, srcUrl, bookName, oldUrl,
                       chapterTitle ?: @"", (long)chapterIndex];
    [probe writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_b4_switch_start.txt"]
            atomically:YES encoding:NSUTF8StringEncoding error:NULL];

    ((void (*)(id, SEL, NSString *, NSString *, NSString *, NSString *, NSString *, NSInteger))objc_msgSend)(
        core, sel, bookName, author ?: @"", oldUrl, srcUrl, chapterTitle ?: @"", chapterIndex
    );
    // 阅读换源已发起：先关面板，避免用户以为没点上
    LBSwitchVC_DismissSwitchPanel(switchVC);
    LBLegadoShowResult(@"正在换源…");
}

static void LBSwitchVC_DismissSelf(id switchVC) {
    if (![switchVC isKindOfClass:[UIViewController class]]) return;
    UIViewController *vc = (UIViewController *)switchVC;
    UINavigationController *nav = vc.navigationController;
    if (nav && nav.topViewController == vc) {
        [nav popViewControllerAnimated:YES];
        return;
    }
    if (vc.presentingViewController) {
        [vc dismissViewControllerAnimated:YES completion:nil];
    }
}

static void LBSwitchVC_ApplySwitchedInfo(NSDictionary *info) {
    if (![info isKindOfClass:[NSDictionary class]]) return;
    NSString *err = info[@"error"];
    if ([err isKindOfClass:[NSString class]] && err.length > 0) {
        LBLegadoShowResult([NSString stringWithFormat:@"换源失败：%@", err]);
        return;
    }
    NSString *newBookUrl = info[@"newBookUrl"];
    NSString *sourceUrl = info[@"sourceUrl"];
    NSString *sourceName = info[@"sourceName"];
    NSString *matchedUrl = info[@"matchedUrl"];
    NSString *matchedTitle = info[@"matchedTitle"];
    NSNumber *matchedIndex = info[@"matchedIndex"];
    if (![matchedUrl isKindOfClass:[NSString class]] || matchedUrl.length == 0) {
        matchedUrl = info[@"firstUrl"];
    }
    if (![matchedTitle isKindOfClass:[NSString class]] || matchedTitle.length == 0) {
        matchedTitle = info[@"firstTitle"];
    }
    NSInteger idx = [matchedIndex respondsToSelector:@selector(integerValue)] ? matchedIndex.integerValue : 0;

    // 关掉换源页
    UIWindow *win = LBLegadoKeyWindow();
    UIViewController *root = win.rootViewController;
    while (root.presentedViewController) root = root.presentedViewController;
    NSMutableArray *stack = [NSMutableArray array];
    if (root) [stack addObject:root];
    while (stack.count > 0) {
        UIViewController *cur = stack.lastObject;
        [stack removeLastObject];
        if ([NSStringFromClass([cur class]) isEqualToString:@"BookSourceSwitchVC2"]) {
            LBSwitchVC_DismissSelf(cur);
        }
        if ([cur isKindOfClass:[UINavigationController class]]) {
            for (UIViewController *c in ((UINavigationController *)cur).viewControllers) {
                [stack addObject:c];
            }
        }
        for (UIViewController *c in cur.childViewControllers) {
            [stack addObject:c];
        }
    }

    // 更新可见阅读壳 dicBook / dicFatBook
    UIViewController *reader = nil;
    if (win) {
        NSMutableArray *rstack = [NSMutableArray array];
        if (win.rootViewController) [rstack addObject:win.rootViewController];
        while (rstack.count > 0) {
            UIViewController *cur = rstack.lastObject;
            [rstack removeLastObject];
            NSString *cn = NSStringFromClass([cur class]);
            if ([cn containsString:@"TextReader"] || [cn containsString:@"Reader"] ||
                [cn containsString:@"ReadPage"] || [cn containsString:@"Reading"]) {
                @try {
                    id db = [cur valueForKey:@"dicBook"];
                    if (db) { reader = cur; break; }
                } @catch (__unused NSException *e) {}
            }
            if ([cur isKindOfClass:[UINavigationController class]]) {
                for (UIViewController *c in ((UINavigationController *)cur).viewControllers.reverseObjectEnumerator) {
                    [rstack addObject:c];
                }
            }
            if (cur.presentedViewController) [rstack addObject:cur.presentedViewController];
            for (UIViewController *c in cur.childViewControllers) [rstack addObject:c];
        }
    }

    void (^patchBook)(id) = ^(id bookObj) {
        if (!bookObj) return;
        NSMutableDictionary *md = nil;
        if ([bookObj isKindOfClass:[NSMutableDictionary class]]) {
            md = (NSMutableDictionary *)bookObj;
        } else if ([bookObj isKindOfClass:[NSDictionary class]]) {
            md = [(NSDictionary *)bookObj mutableCopy];
        }
        if (!md) return;
        if ([newBookUrl isKindOfClass:[NSString class]] && newBookUrl.length > 0) {
            md[@"bookUrl"] = newBookUrl;
            md[@"url"] = newBookUrl;
        }
        if ([sourceUrl isKindOfClass:[NSString class]] && sourceUrl.length > 0) {
            md[@"sourceUrl"] = sourceUrl;
            md[@"bookSourceUrl"] = sourceUrl;
        }
        if ([sourceName isKindOfClass:[NSString class]] && sourceName.length > 0) {
            md[@"sourceName"] = sourceName;
            md[@"bookSourceName"] = sourceName;
        }
        if ([matchedUrl isKindOfClass:[NSString class]] && matchedUrl.length > 0) {
            md[@"chapterUrl"] = matchedUrl;
            md[@"cpUrl"] = matchedUrl;
            md[@"curChapterUrl"] = matchedUrl;
        }
        if ([matchedTitle isKindOfClass:[NSString class]] && matchedTitle.length > 0) {
            md[@"cpTitle"] = matchedTitle;
            md[@"chapterName"] = matchedTitle;
            md[@"title"] = matchedTitle;
        }
        md[@"cpIndex"] = @(idx);
        md[@"chapterIndex"] = @(idx);
        md[@"legadoBridge"] = @"1";
        if (reader) {
            @try { [reader setValue:md forKey:@"dicBook"]; } @catch (__unused NSException *e) {}
            @try { [reader setValue:md forKey:@"dicFatBook"]; } @catch (__unused NSException *e) {}
        }
    };
    if (reader) {
        id db = nil;
        @try { db = [reader valueForKey:@"dicBook"]; } @catch (__unused NSException *e) {}
        patchBook(db);
        id fat = nil;
        @try { fat = [reader valueForKey:@"dicFatBook"]; } @catch (__unused NSException *e) {}
        if (fat && fat != db) patchBook(fat);
        if ([matchedTitle isKindOfClass:[NSString class]] && matchedTitle.length > 0) {
            @try { [reader setValue:matchedTitle forKey:@"title"]; } @catch (__unused NSException *e) {}
        }
    }

    if ([matchedUrl isKindOfClass:[NSString class]] && matchedUrl.length > 0 &&
        [newBookUrl isKindOfClass:[NSString class]] && newBookUrl.length > 0) {
        NSString *su = [sourceUrl isKindOfClass:[NSString class]] ? sourceUrl : @"";
        LBHandleContentRequest(matchedUrl, newBookUrl, su);
    }

    NSString *toast = [NSString stringWithFormat:@"已换源%@",
                       ([matchedTitle isKindOfClass:[NSString class]] && matchedTitle.length > 0)
                           ? [NSString stringWithFormat:@" · %@", matchedTitle] : @""];
    LBLegadoShowResult(toast);
}

static void LBSwitchVC_tableView_didSelect_IMP(id self, SEL _cmd, id tableView, NSIndexPath *indexPath) {
    NSString *name = LBLegadoSourceNameAtIndexPath(self, indexPath);
    if (name.length > 0) {
        objc_setAssociatedObject(self, &kLBSelectedDiscoverSourceNameKey, name,
                                 OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    if (LBLegadoShouldBlockSourceName(self, name)) {
        // Legado：只选中，不进管理页；点确定再真正换源
        if ([self respondsToSelector:@selector(setUseSourceName:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(self, @selector(setUseSourceName:), name);
        } else {
            @try { [self setValue:name forKey:@"useSourceName"]; } @catch (__unused NSException *e) {}
        }
        LBLegadoDeselectRow(tableView, indexPath);
        if ([tableView respondsToSelector:@selector(reloadData)]) {
            ((void (*)(id, SEL))objc_msgSend)(tableView, @selector(reloadData));
        }
        return;
    }
    if (LBOrig_SwitchVC_didSelect) {
        LBOrig_SwitchVC_didSelect(self, _cmd, tableView, indexPath);
    }
}

/// 统一处理 onOkBtnEvent / onOkBtnEvent:（发现切源与阅读换源共用）
static void LBSwitchVC_HandleOnOk(id self, SEL _cmd, id sender, BOOL hasSender) {
    NSString *name = nil;
    @try {
        id v = [self valueForKey:@"useSourceName"];
        if ([v isKindOfClass:[NSString class]]) name = (NSString *)v;
    } @catch (__unused NSException *e) {}
    if (name.length == 0 && [self respondsToSelector:@selector(useSourceName)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id v = [self performSelector:@selector(useSourceName)];
#pragma clang diagnostic pop
        if ([v isKindOfClass:[NSString class]]) name = (NSString *)v;
    }
    if (name.length == 0) {
        @try {
            id cfg = [self valueForKey:@"_currentConfig"];
            if (cfg) {
                id n1 = [cfg valueForKey:@"name"];
                id n2 = [cfg valueForKey:@"sourceName"];
                if ([n1 isKindOfClass:[NSString class]] && [(NSString *)n1 length] > 0) {
                    name = (NSString *)n1;
                } else if ([n2 isKindOfClass:[NSString class]] && [(NSString *)n2 length] > 0) {
                    name = (NSString *)n2;
                }
            }
        } @catch (__unused NSException *e) {}
    }
    NSString *selectedName = objc_getAssociatedObject(self, &kLBSelectedDiscoverSourceNameKey);
    if ([selectedName isKindOfClass:[NSString class]] && selectedName.length > 0) {
        name = selectedName;
    } else {
        name = LBLegadoStripDisplaySuffix(name);
    }
    // 发现页「切换站点」与阅读「换源」共用 BookSourceSwitchVC2：无书时按发现切源处理，
    // 否则 LBSwitchVC_StartLegadoSwitch 会因缺书名报「无法换源：缺少书名」
    id book = nil;
    @try { book = [self valueForKey:@"dicBook"]; } @catch (__unused NSException *e) {}
    if (!book) {
        @try { book = [self valueForKey:@"dicFatBook"]; } @catch (__unused NSException *e) {}
    }
    if (!book && name.length > 0) {
        // 无书 = 发现页「切换站点」（阅读「换源」必有书）。Legado 源走发现切源；
        // 原生源必须交给原生 onOk（useSourceName 在原生 didSelect 下不更新，直接读会拿旧名 → 切不动）
        BOOL isLegado = LBLegadoShouldBlockSourceName(self, name);
        if (!isLegado && [name hasSuffix:@"·Legado"]) {
            isLegado = (LBSwitchVC_ResolveSourceUrl(name).length > 0);
        }
        NSString *discoverDiag = [NSString stringWithFormat:
                                  @"onOk discover-switch name=%@ legado=%d hasSender=%d\n",
                                  name ?: @"", isLegado ? 1 : 0, hasSender ? 1 : 0];
        @try {
            [discoverDiag writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_b4_onok.txt"]
                           atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        } @catch (__unused NSException *e) {}
        if (isLegado) {
            // Legado 发现切源：关掉切换面板并让发现页跟随所选源
            LBSwitchVC_DismissSwitchPanel(self);
            LBSwitchDiscoverToSourceName(name);
        } else if (hasSender && LBOrig_SwitchVC_onOkArg) {
            LBOrig_SwitchVC_onOkArg(self, _cmd, sender);
            NSString *selected = objc_getAssociatedObject(self, &kLBSelectedDiscoverSourceNameKey);
            if ([selected isKindOfClass:[NSString class]] && selected.length > 0) {
                NSString *selectedCopy = [selected copy];
                dispatch_async(dispatch_get_main_queue(), ^{
                    LBNotifyDiscoverNativeSourceSwitched(selectedCopy);
                });
            }
        } else if (LBOrig_SwitchVC_onOk) {
            // 原生源：原生 onOk 自己切源（它内部知道选中的是谁）
            LBOrig_SwitchVC_onOk(self, hasSender ? @selector(onOkBtnEvent) : _cmd);
            NSString *selected = objc_getAssociatedObject(self, &kLBSelectedDiscoverSourceNameKey);
            if ([selected isKindOfClass:[NSString class]] && selected.length > 0) {
                NSString *selectedCopy = [selected copy];
                dispatch_async(dispatch_get_main_queue(), ^{
                    // 原生 onOk 已完成实际切源；直接通知发现页恢复原生 bookWorld，
                    // 不再等待宿主标题轮询。
                    LBNotifyDiscoverNativeSourceSwitched(selectedCopy);
                });
            }
        }
        return;
    }
    BOOL isLegado = LBLegadoShouldBlockSourceName(self, name);
    if (!isLegado && [name hasSuffix:@"·Legado"]) {
        isLegado = (LBSwitchVC_ResolveSourceUrl(name).length > 0);
    }
    if (!isLegado && name.length > 0 &&
        ([name hasPrefix:@"[阅读]"] || LBLegadoIsSourceName(name))) {
        isLegado = YES;
    }
    @try {
        NSString *diag = [NSString stringWithFormat:@"onOk name=%@ legado=%d hasSender=%d\n",
                          name ?: @"", isLegado ? 1 : 0, hasSender ? 1 : 0];
        [diag writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_b4_onok.txt"]
               atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    } @catch (__unused NSException *e) {}
    if (isLegado) {
        LBSwitchVC_StartLegadoSwitch(self, name);
        return;
    }
    if (hasSender && LBOrig_SwitchVC_onOkArg) {
        LBOrig_SwitchVC_onOkArg(self, _cmd, sender);
    } else if (LBOrig_SwitchVC_onOk) {
        LBOrig_SwitchVC_onOk(self, hasSender ? @selector(onOkBtnEvent) : _cmd);
    }
}

static void LBSwitchVC_onOkBtnEvent_IMP(id self, SEL _cmd) {
    LBSwitchVC_HandleOnOk(self, _cmd, nil, NO);
}

static void LBSwitchVC_onOkBtnEventArg_IMP(id self, SEL _cmd, id sender) {
    LBSwitchVC_HandleOnOk(self, _cmd, sender, YES);
}

static void LBInstallBookSourceSwitchHooks(void) {
    Class switchCls = NSClassFromString(@"BookSourceSwitchVC2");
    if (!switchCls) {
        NSLog(@"[LegadoBridge] BookSourceSwitchVC2 missing, skip B4 switch hooks");
        return;
    }

    SEL didSel = @selector(tableView:didSelectRowAtIndexPath:);
    Class didOwner = LBClassOwningInstanceMethod(switchCls, didSel);
    // 必须是 SwitchVC 自有实现；勿覆盖 ConfigSourceListBase 管理页 hook
    if (didOwner == switchCls && !LBOrig_SwitchVC_didSelect) {
        Method m = class_getInstanceMethod(didOwner, didSel);
        if (m) {
            LBOrig_SwitchVC_didSelect =
                (void (*)(id, SEL, id, NSIndexPath *))method_getImplementation(m);
            method_setImplementation(m, (IMP)LBSwitchVC_tableView_didSelect_IMP);
            NSLog(@"[LegadoBridge] hooked BookSourceSwitchVC2 didSelect for B4 switch");
        }
    } else if (didOwner && didOwner != switchCls && !LBOrig_SwitchVC_didSelect) {
        // 继承父类（常为已挂管理页拦截的 ConfigSourceListBase）：在 SwitchVC 上加覆盖实现
        Method parentM = class_getInstanceMethod(didOwner, didSel);
        if (parentM) {
            LBOrig_SwitchVC_didSelect =
                (void (*)(id, SEL, id, NSIndexPath *))method_getImplementation(parentM);
            BOOL added = class_addMethod(switchCls, didSel, (IMP)LBSwitchVC_tableView_didSelect_IMP,
                                         method_getTypeEncoding(parentM));
            if (added) {
                NSLog(@"[LegadoBridge] added BookSourceSwitchVC2 didSelect override (parent=%@)",
                      NSStringFromClass(didOwner));
            } else {
                Method own = class_getInstanceMethod(switchCls, didSel);
                if (own) {
                    method_setImplementation(own, (IMP)LBSwitchVC_tableView_didSelect_IMP);
                    NSLog(@"[LegadoBridge] replaced BookSourceSwitchVC2 didSelect");
                }
            }
        }
    }

    SEL okSel = @selector(onOkBtnEvent);
    Method okM = class_getInstanceMethod(switchCls, okSel);
    if (okM && !LBOrig_SwitchVC_onOk) {
        Class okOwner = LBClassOwningInstanceMethod(switchCls, okSel);
        Method targetM = okOwner ? class_getInstanceMethod(okOwner, okSel) : okM;
        LBOrig_SwitchVC_onOk = (void (*)(id, SEL))method_getImplementation(targetM);
        const char *enc = method_getTypeEncoding(targetM);
        // 始终挂到 SwitchVC 自身，避免改父类 IMP
        class_replaceMethod(switchCls, okSel, (IMP)LBSwitchVC_onOkBtnEvent_IMP, enc);
        NSString *hookMark = [NSString stringWithFormat:@"okOwner=%@ replaceOn=BookSourceSwitchVC2\n",
                              okOwner ? NSStringFromClass(okOwner) : @"?"];
        [hookMark writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_b4_hooks.txt"]
                   atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        NSLog(@"[LegadoBridge] hooked BookSourceSwitchVC2 onOkBtnEvent (owner=%@)",
              okOwner ? NSStringFromClass(okOwner) : @"?");
    }

    // 带参变体：onOkBtnEvent:
    SEL okSelArg = @selector(onOkBtnEvent:);
    Method okMArg = class_getInstanceMethod(switchCls, okSelArg);
    if (okMArg && !LBOrig_SwitchVC_onOkArg) {
        Class okOwnerArg = LBClassOwningInstanceMethod(switchCls, okSelArg);
        Method targetArg = okOwnerArg ? class_getInstanceMethod(okOwnerArg, okSelArg) : okMArg;
        LBOrig_SwitchVC_onOkArg = (void (*)(id, SEL, id))method_getImplementation(targetArg);
        const char *encArg = method_getTypeEncoding(targetArg);
        class_replaceMethod(switchCls, okSelArg, (IMP)LBSwitchVC_onOkBtnEventArg_IMP, encArg);
        NSLog(@"[LegadoBridge] hooked BookSourceSwitchVC2 onOkBtnEvent:");
    }

    static dispatch_once_t onceObs;
    dispatch_once(&onceObs, ^{
        [[NSNotificationCenter defaultCenter]
            addObserverForName:@"LegadoBridgeSourceSwitched"
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            LBSwitchVC_ApplySwitchedInfo(note.userInfo);
        }];
        NSLog(@"[LegadoBridge] observing LegadoBridgeSourceSwitched");
    });
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

    // T3：索引条 section 映射（挂到实际实现类）
    {
        SEL idxSel = @selector(tableView:sectionForSectionIndexTitle:atIndex:);
        NSArray<NSString *> *idxClasses = @[
            @"BookSourceSwitchVC2",
            @"ConfigSourceListBase",
            @"LCTableViewControllerBase_Group"
        ];
        for (NSString *cn in idxClasses) {
            Class requested = NSClassFromString(cn);
            if (!requested) continue;
            Class owner = LBClassOwningInstanceMethod(requested, idxSel);
            if (!owner || LBOrig_Config_sectionForIndexTitle) continue;
            Method m = class_getInstanceMethod(owner, idxSel);
            if (!m) continue;
            LBOrig_Config_sectionForIndexTitle =
                (NSInteger (*)(id, SEL, UITableView *, NSString *, NSInteger))method_getImplementation(m);
            method_setImplementation(m, (IMP)LBConfig_sectionForIndexTitle_IMP);
            NSLog(@"[LegadoBridge] hooked %@ sectionForSectionIndexTitle (via %@)",
                  NSStringFromClass(owner), cn);
            break;
        }
    }

    // T3：切换站点面板打开时确保 table 可滚
    {
        Class switchCls = NSClassFromString(@"BookSourceSwitchVC2");
        SEL appearSel = @selector(viewWillAppear:);
        if (switchCls) {
            Method appearMethod = class_getInstanceMethod(switchCls, appearSel);
            if (appearMethod && !LBOrig_SwitchVC_viewWillAppear) {
                LBOrig_SwitchVC_viewWillAppear =
                    (void (*)(id, SEL, BOOL))method_getImplementation(appearMethod);
                method_setImplementation(appearMethod, (IMP)LBSwitchVC_viewWillAppear_IMP);
                NSLog(@"[LegadoBridge] hooked BookSourceSwitchVC2 viewWillAppear:");
            } else if (!appearMethod) {
                // 子类未实现则加到自身，先调父类
                Class superCls = class_getSuperclass(switchCls);
                Method superM = superCls ? class_getInstanceMethod(superCls, appearSel) : NULL;
                if (superM) {
                    LBOrig_SwitchVC_viewWillAppear =
                        (void (*)(id, SEL, BOOL))method_getImplementation(superM);
                    class_addMethod(switchCls, appearSel, (IMP)LBSwitchVC_viewWillAppear_IMP,
                                    method_getTypeEncoding(superM));
                    NSLog(@"[LegadoBridge] added BookSourceSwitchVC2 viewWillAppear:");
                }
            }
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
    LBInstallBookSourceSwitchHooks();
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
@property (nonatomic, weak) UIViewController *sourceListVC;
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
    UIViewController *from = self.sourceListVC;
    if (!LBLegadoPresentNativeImportFrom(from)) {
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
            [LBLegadoBarButtonTarget shared].sourceListVC = vc;
            UINavigationItem *item = vc.navigationItem;
            BOOL hasLegadoBtn = NO;
            for (UIBarButtonItem *bi in item.rightBarButtonItems ?: @[]) {
                if ([bi.accessibilityIdentifier isEqualToString:@"legado.manage.entry"]) {
                    hasLegadoBtn = YES;
                }
                // U3：每次 appear 都校验/重绑「导入」，避免 id 残留但 action 丢失
                BOOL isImport = [bi.title isEqualToString:@"导入"] ||
                    [bi.accessibilityIdentifier isEqualToString:@"legado.import.entry"];
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
    // 混合勾选：Legado 已启停，原生留给 orig onFanzhuanEvent
    NSString *msg = [NSString stringWithFormat:@"invert mixed legado=%lu native=1",
                     (unsigned long)legadoNames.count];
    [msg writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_a09_invert.txt"]
          atomically:YES encoding:NSUTF8StringEncoding error:NULL];
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
