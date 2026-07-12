#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>
#import "LegadoBridge.h"
#import "LBInternal.h"

@class LegadoBridgeCore;

NSString *LBBridgeVersion(void) {
    return @"1.0.0-mvp";
}

BOOL LBIsLegadoJSONData(NSData *data) {
    if (data.length == 0) return NO;
    Class coreClass = NSClassFromString(@"LegadoBridge.LegadoBridgeCore");
    if (!coreClass) return NO;
    id core = [coreClass performSelector:@selector(shared)];
    if (![core respondsToSelector:@selector(isLegadoJSONData:)]) return NO;
    return ((BOOL (*)(id, SEL, NSData *))objc_msgSend)(core, @selector(isLegadoJSONData:), data);
}

NSInteger LBImportLegadoJSONData(NSData *data, NSError **error) {
    Class coreClass = NSClassFromString(@"LegadoBridge.LegadoBridgeCore");
    if (!coreClass) {
        if (error) *error = [NSError errorWithDomain:@"LegadoBridge" code:1 userInfo:@{NSLocalizedDescriptionKey: @"LegadoBridgeCore not loaded"}];
        return 0;
    }
    id core = [coreClass performSelector:@selector(shared)];
    NSInteger count = ((NSInteger (*)(id, SEL, NSData *, NSError **))objc_msgSend)(
        core, @selector(importLegadoJSONData:error:), data, error
    );
    return count;
}

void LBHandleSearchRequest(NSString *keyword, NSString *sourceUrl) {
    Class coreClass = NSClassFromString(@"LegadoBridge.LegadoBridgeCore");
    if (!coreClass) return;
    id core = [coreClass performSelector:@selector(shared)];
    ((void (*)(id, SEL, NSString *, NSString *))objc_msgSend)(
        core, @selector(handleSearchRequestWithKeyword:sourceUrl:), keyword ?: @"", sourceUrl
    );
}

/// 优先走原生 startSearch，建立 dicSearchingBook / 搜索页监听态，再由 coexist Hook 踢 Legado。
/// 深链/沙盒旁路若只调 handleSearchRequest，引擎有结果但 UI 无观察者 → 空列表。
void LBTriggerMixedSearch(NSString *keyword, NSString *sourceUrl) {
    NSString *kw = keyword ?: @"";
    if (kw.length == 0) return;
    // startSearch / UI 必须在主线程；沙盒 poller 在后台队列
    if (![NSThread isMainThread]) {
        NSString *kwCopy = [kw copy];
        NSString *urlCopy = [sourceUrl copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            LBTriggerMixedSearch(kwCopy, urlCopy);
        });
        return;
    }

    Class managerClass = NSClassFromString(@"BookSourceManager");
    if (!managerClass) managerClass = NSClassFromString(@"BookSourceManagerBase");
    id mgr = nil;
    if (managerClass && [managerClass respondsToSelector:@selector(sharedInstance)]) {
        mgr = ((id (*)(Class, SEL))objc_msgSend)(managerClass, @selector(sharedInstance));
    }
    SEL searchSel = NSSelectorFromString(@"startSearch:prioritySourceType:fromShuping:quick:");
    if (mgr && [mgr respondsToSelector:searchSel]) {
        // type 传 nil：与 Hook 签名 (id) 一致；Hook 内会并存踢 Legado 全源
        BOOL ok = ((BOOL (*)(id, SEL, NSString *, id, BOOL, BOOL))objc_msgSend)(
            mgr, searchSel, kw, nil, NO, NO
        );
        NSString *marker = [NSString stringWithFormat:@"triggerMixed startSearch ok=%d key=%@ src=%@",
                            (int)ok, kw, sourceUrl ?: @"all"];
        [marker writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_trigger.txt"]
                 atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        if (!ok) {
            // 原生未启动且 Hook 未接管时，兜底直调引擎（仍 post 通知）
            LBHandleSearchRequest(kw, sourceUrl.length > 0 ? sourceUrl : nil);
        }
        return;
    }
    LBHandleSearchRequest(kw, sourceUrl.length > 0 ? sourceUrl : nil);
}

/// 真机闭环根因：通知 dNotifyName_SearchBookSourceResponse 的 handler 不在 BookSearchController；
/// 列表行数读的是 arrBaseData（LCTableViewControllerBase_Plain），且 dataSource 可能是
/// 断裂的 _UIFilteredDataSource → 引擎有结果 / arrSearchItems 有条目但 UITableView 仍空。
/// 深链搜索时常尚未 push 搜索页 → 需 pending，等 viewDidAppear 再灌入。
static NSMutableArray *sPendingSearchBooks;
static NSMutableArray *sLastAppliedSearchBooks;
static NSString *sPendingSearchKeyword;
static BOOL sSearchUIAppearHooked;
static IMP sOrigNumberOfRows;
static IMP sOrigCellForRow;
static NSHashTable *sKnownSearchVCs; // weak
static __strong UIViewController *sCurrentSearchVC; // 短时强引用，防 weak 过早清空

static void LBSetSearchKeywordOnVC(UIViewController *vc, NSString *keyword);
static NSArray<UIWindow *> *LBAllAppWindows(void);

/// 是否为搜索结果页控制器（避免误命中 BookShelfController）
static BOOL LBVCLooksLikeBookSearch(UIViewController *vc) {
    if (!vc) return NO;
    NSString *cn = NSStringFromClass([vc class]);
    if ([cn containsString:@"BookSearch"] || [cn containsString:@"SearchController"]) return YES;
    // UISearchController 系统类排除
    if ([cn isEqualToString:@"UISearchController"] || [cn containsString:@"UIInput"]) return NO;
    @try {
        id items = [vc valueForKey:@"arrSearchItems"];
        if (items) return YES;
    } @catch (__unused NSException *e) {}
    @try {
        id bar = [vc valueForKey:@"searchBar"];
        if (bar) return YES;
    } @catch (__unused NSException *e) {}
    return NO;
}

static BOOL LBVCIsVisibleInWindow(UIViewController *vc) {
    if (![vc isKindOfClass:[UIViewController class]]) return NO;
    return vc.isViewLoaded && vc.view.window != nil;
}

static UIViewController *LBViewControllerOwningView(UIView *view) {
    for (UIResponder *r = view; r; r = r.nextResponder) {
        if ([r isKindOfClass:[UIViewController class]]) {
            return (UIViewController *)r;
        }
    }
    return nil;
}

static void LBCollectBookSearchVCs(UIViewController *vc, NSMutableArray *out) {
    if (!vc) return;
    if (LBVCLooksLikeBookSearch(vc) && ![out containsObject:vc]) {
        [out addObject:vc];
    }
    for (UIViewController *child in vc.childViewControllers) {
        LBCollectBookSearchVCs(child, out);
    }
    if (vc.presentedViewController) {
        LBCollectBookSearchVCs(vc.presentedViewController, out);
    }
    if ([vc isKindOfClass:[UINavigationController class]]) {
        for (UIViewController *child in ((UINavigationController *)vc).viewControllers) {
            LBCollectBookSearchVCs(child, out);
        }
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        UITabBarController *tab = (UITabBarController *)vc;
        for (UIViewController *child in tab.viewControllers) {
            LBCollectBookSearchVCs(child, out);
        }
        if (tab.selectedViewController) {
            LBCollectBookSearchVCs(tab.selectedViewController, out);
        }
    }
}

/// 从可视 view 树找持有 UISearchBar / UITableView 的搜索相关 VC（不依赖 nav 父子链）
static void LBCollectSearchVCsFromView(UIView *view, NSMutableArray *out, NSMutableArray *diag, NSInteger depth) {
    if (!view || depth > 40) return;
    BOOL interesting =
        [view isKindOfClass:[UITableView class]] ||
        [view isKindOfClass:[UISearchBar class]] ||
        [NSStringFromClass([view class]) containsString:@"SearchBar"];
    if (interesting) {
        UIViewController *owner = LBViewControllerOwningView(view);
        NSString *ownCn = owner ? NSStringFromClass([owner class]) : @"(nil)";
        NSString *vCn = NSStringFromClass([view class]);
        BOOL hit = LBVCLooksLikeBookSearch(owner);
        // 可见空列表：table 的 dataSource/delegate 若是搜索 VC 也算
        if (!hit && [view isKindOfClass:[UITableView class]]) {
            UITableView *tv = (UITableView *)view;
            id ds = tv.dataSource;
            if ([ds isKindOfClass:[UIViewController class]] && LBVCLooksLikeBookSearch((UIViewController *)ds)) {
                owner = (UIViewController *)ds;
                hit = YES;
                ownCn = NSStringFromClass([owner class]);
            }
        }
        if (diag) {
            [diag addObject:[NSString stringWithFormat:@"%@ -> %@ hit=%d win=%d",
                             vCn, ownCn, hit ? 1 : 0,
                             (owner && LBVCIsVisibleInWindow(owner)) ? 1 : 0]];
        }
        if (hit && owner && ![out containsObject:owner]) {
            [out addObject:owner];
            sCurrentSearchVC = owner; // 可见持有者优先强引用
        }
    }
    for (UIView *sub in view.subviews) {
        LBCollectSearchVCsFromView(sub, out, diag, depth + 1);
    }
}

static void LBCollectSearchVCsFromVisibleViews(NSMutableArray *out, NSMutableArray *diag) {
    for (UIWindow *win in LBAllAppWindows()) {
        if (diag) {
            [diag addObject:[NSString stringWithFormat:@"VIEWWALK %@", NSStringFromClass([win class])]];
        }
        LBCollectSearchVCsFromView(win, out, diag, 0);
    }
}

static void LBDumpVCWalk(UIViewController *vc, NSInteger depth, NSMutableArray *lines) {
    if (!vc) return;
    NSMutableString *pad = [NSMutableString string];
    for (NSInteger i = 0; i < depth; i++) [pad appendString:@"  "];
    BOOL vis = LBVCIsVisibleInWindow(vc);
    BOOL search = LBVCLooksLikeBookSearch(vc);
    [lines addObject:[NSString stringWithFormat:@"%@%@%@%@",
                      pad, NSStringFromClass([vc class]),
                      vis ? @" [vis]" : @"",
                      search ? @" [search]" : @""]];
    for (UIViewController *c in vc.childViewControllers) LBDumpVCWalk(c, depth + 1, lines);
    if (vc.presentedViewController) LBDumpVCWalk(vc.presentedViewController, depth + 1, lines);
    if ([vc isKindOfClass:[UINavigationController class]]) {
        for (UIViewController *c in ((UINavigationController *)vc).viewControllers) {
            LBDumpVCWalk(c, depth + 1, lines);
        }
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        UITabBarController *tab = (UITabBarController *)vc;
        for (UIViewController *c in tab.viewControllers) LBDumpVCWalk(c, depth + 1, lines);
        if (tab.selectedViewController) LBDumpVCWalk(tab.selectedViewController, depth + 1, lines);
    }
}

static void LBDumpVisibleVCTree(void) {
    NSMutableArray *lines = [NSMutableArray array];
    NSArray *wins = LBAllAppWindows();
    [lines addObject:[NSString stringWithFormat:@"windows=%lu known=%lu strong=%@",
                      (unsigned long)wins.count,
                      (unsigned long)sKnownSearchVCs.count,
                      sCurrentSearchVC ? NSStringFromClass([sCurrentSearchVC class]) : @"(nil)"]];
    for (UIWindow *w in wins) {
        [lines addObject:[NSString stringWithFormat:@"WINDOW %@", NSStringFromClass([w class])]];
        LBDumpVCWalk(w.rootViewController, 0, lines);
    }
    NSMutableArray *viewHits = [NSMutableArray array];
    NSMutableArray *diag = [NSMutableArray array];
    LBCollectSearchVCsFromVisibleViews(viewHits, diag);
    [lines addObject:@"--- view holders ---"];
    [lines addObjectsFromArray:diag];
    NSMutableArray *hitNames = [NSMutableArray array];
    for (UIViewController *vc in viewHits) {
        [hitNames addObject:NSStringFromClass([vc class])];
    }
    [lines addObject:[NSString stringWithFormat:@"viewHitVCs=%@",
                      hitNames.count ? [hitNames componentsJoinedByString:@","] : @"(none)"]];
    [[lines componentsJoinedByString:@"\n"]
        writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_vc_tree.txt"]
         atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

static NSArray<UIWindow *> *LBAllAppWindows(void) {
    NSMutableArray *wins = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w) [wins addObject:w];
            }
        }
    }
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (w && ![wins containsObject:w]) [wins addObject:w];
    }
    UIWindow *key = LBLegadoKeyWindow();
    if (key && ![wins containsObject:key]) [wins addObject:key];
    return wins;
}

/// 可见搜索 VC 优先；强引用/弱缓存兜底；最后扫 view 树
static NSArray *LBFindBookSearchVCs(void) {
    NSMutableArray *vcs = [NSMutableArray array];
    for (UIWindow *win in LBAllAppWindows()) {
        LBCollectBookSearchVCs(win.rootViewController, vcs);
    }
    if (sCurrentSearchVC && ![vcs containsObject:sCurrentSearchVC]) {
        [vcs addObject:sCurrentSearchVC];
    }
    if (sKnownSearchVCs.count > 0) {
        for (UIViewController *vc in sKnownSearchVCs) {
            if (vc && ![vcs containsObject:vc]) [vcs addObject:vc];
        }
    }
    // 关键：VC 树漏掉但屏幕上仍有搜索栏/空列表时，从 view→nextResponder 找回
    NSMutableArray *fromViews = [NSMutableArray array];
    LBCollectSearchVCsFromVisibleViews(fromViews, nil);
    for (UIViewController *vc in fromViews) {
        if (vc && ![vcs containsObject:vc]) [vcs addObject:vc];
    }
    if (vcs.count == 0) {
        UIWindow *key = LBLegadoKeyWindow();
        if (key.rootViewController) {
            LBCollectBookSearchVCs(key.rootViewController, vcs);
        }
    }
    // 可见优先排序
    [vcs sortUsingComparator:^NSComparisonResult(UIViewController *a, UIViewController *b) {
        BOOL va = LBVCIsVisibleInWindow(a);
        BOOL vb = LBVCIsVisibleInWindow(b);
        if (va == vb) return NSOrderedSame;
        return va ? NSOrderedAscending : NSOrderedDescending;
    }];
    return vcs;
}

static NSString *LBSearchBookKey(NSDictionary *book) {
    NSString *name = book[@"bookName"] ?: book[@"name"] ?: @"";
    NSString *author = book[@"author"] ?: @"";
    if (name.length == 0) {
        return book[@"bookUrl"] ?: book[@"url"] ?: [[NSUUID UUID] UUIDString];
    }
    if (author.length > 0) {
        return [NSString stringWithFormat:@"%@|%@", name, author];
    }
    return name;
}

static void LBMergeBookIntoSearchVC(UIViewController *vc, NSDictionary *book, NSString *keyword) {
    if (![book isKindOfClass:[NSDictionary class]] || book.count == 0) return;
    NSString *key = LBSearchBookKey(book);

    NSMutableArray *arrBase = nil;
    @try {
        id cur = [vc valueForKey:@"arrBaseData"];
        if ([cur isKindOfClass:[NSMutableArray class]]) arrBase = cur;
        else if ([cur isKindOfClass:[NSArray class]]) arrBase = [cur mutableCopy];
    } @catch (__unused NSException *e) {}
    if (!arrBase) arrBase = [NSMutableArray array];

    BOOL found = NO;
    for (id item in arrBase) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        if ([LBSearchBookKey(item) isEqualToString:key]) { found = YES; break; }
    }
    if (!found) [arrBase addObject:book];
    @try { [vc setValue:arrBase forKey:@"arrBaseData"]; } @catch (__unused NSException *e) {}

    NSMutableArray *arrItems = nil;
    @try {
        id cur = [vc valueForKey:@"arrSearchItems"];
        if ([cur isKindOfClass:[NSMutableArray class]]) arrItems = cur;
        else if ([cur isKindOfClass:[NSArray class]]) arrItems = [cur mutableCopy];
    } @catch (__unused NSException *e) {}
    if (!arrItems) arrItems = [NSMutableArray array];
    found = NO;
    for (id item in arrItems) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        if ([LBSearchBookKey(item) isEqualToString:key]) { found = YES; break; }
    }
    if (!found) [arrItems addObject:book];
    @try { [vc setValue:arrItems forKey:@"arrSearchItems"]; } @catch (__unused NSException *e) {}

    NSMutableDictionary *dicItems = nil;
    @try {
        id cur = [vc valueForKey:@"dicSearchItems"];
        if ([cur isKindOfClass:[NSMutableDictionary class]]) dicItems = cur;
        else if ([cur isKindOfClass:[NSDictionary class]]) dicItems = [cur mutableCopy];
    } @catch (__unused NSException *e) {}
    if (!dicItems) dicItems = [NSMutableDictionary dictionary];
    dicItems[key] = book;
    @try { [vc setValue:dicItems forKey:@"dicSearchItems"]; } @catch (__unused NSException *e) {}

    NSMutableDictionary *dicAll = nil;
    @try {
        id cur = [vc valueForKey:@"dicAllBookList"];
        if ([cur isKindOfClass:[NSMutableDictionary class]]) dicAll = cur;
        else if ([cur isKindOfClass:[NSDictionary class]]) dicAll = [cur mutableCopy];
    } @catch (__unused NSException *e) {}
    if (!dicAll) dicAll = [NSMutableDictionary dictionary];
    dicAll[key] = book;
    @try { [vc setValue:dicAll forKey:@"dicAllBookList"]; } @catch (__unused NSException *e) {}

    if (keyword.length > 0) {
        LBSetSearchKeywordOnVC(vc, keyword);
    }
    // 与原生 filterSourceType（默认 text）对齐；DOM 会被筛成 0 行
    @try {
        id filter = [vc valueForKey:@"filterSourceType"];
        NSString *fs = [filter isKindOfClass:[NSString class]] && [filter length] > 0
            ? filter : @"text";
        NSMutableDictionary *patched = [book mutableCopy];
        NSString *curType = [patched[@"sourceType"] isKindOfClass:[NSString class]]
            ? patched[@"sourceType"] : @"";
        if (![curType isEqualToString:fs]) {
            patched[@"sourceType"] = fs;
            dicItems[key] = patched;
            dicAll[key] = patched;
            NSUInteger idx = [arrBase indexOfObject:book];
            if (idx != NSNotFound) arrBase[idx] = patched;
            NSUInteger idx2 = [arrItems indexOfObject:book];
            if (idx2 != NSNotFound) arrItems[idx2] = patched;
            @try { [vc setValue:arrBase forKey:@"arrBaseData"]; } @catch (__unused NSException *e) {}
            @try { [vc setValue:arrItems forKey:@"arrSearchItems"]; } @catch (__unused NSException *e) {}
            @try { [vc setValue:dicItems forKey:@"dicSearchItems"]; } @catch (__unused NSException *e) {}
            @try { [vc setValue:dicAll forKey:@"dicAllBookList"]; } @catch (__unused NSException *e) {}
        }
    } @catch (__unused NSException *e) {}

    @try {
        // 探针：_UIFilteredDataSource.filteredDataSource=nil 时 rows 恒 0。
        // 有 Legado 结果时强制 DS=VC（仅在 DS==self 时才允许 rows 兜底，避免 SIGABRT）
        @try { [vc setValue:@NO forKey:@"showFilterTip"]; } @catch (__unused NSException *e) {}
        @try { [vc setValue:@0 forKey:@"nFilterResultType"]; } @catch (__unused NSException *e) {}
        UITableView *tv = [vc valueForKey:@"tableView"];
        if ([tv isKindOfClass:[UITableView class]]) {
            id ds = tv.dataSource;
            NSString *dsCls = ds ? NSStringFromClass([ds class]) : @"(nil)";
            BOOL needOwnDS = (ds == nil)
                || (ds != (id)vc)
                || [dsCls containsString:@"FilteredDataSource"];
            if (needOwnDS && [vc respondsToSelector:@selector(tableView:numberOfRowsInSection:)]) {
                tv.dataSource = (id<UITableViewDataSource>)vc;
                if ([vc respondsToSelector:@selector(tableView:cellForRowAtIndexPath:)]) {
                    tv.delegate = (id<UITableViewDelegate>)vc;
                }
            }
            [tv reloadData];
            NSInteger rows = 0;
            @try {
                if ([tv.dataSource respondsToSelector:@selector(tableView:numberOfRowsInSection:)]) {
                    rows = [tv.dataSource tableView:tv numberOfRowsInSection:0];
                }
            } @catch (__unused NSException *e) {}
            NSUInteger arrN = 0;
            @try {
                id cur = [vc valueForKey:@"arrBaseData"];
                if ([cur isKindOfClass:[NSArray class]]) arrN = [cur count];
            } @catch (__unused NSException *e) {}
            NSString *diag = [NSString stringWithFormat:
                @"uiInject ds=%@ rows=%ld arr=%lu needOwn=%d",
                dsCls, (long)rows, (unsigned long)arrN, needOwnDS ? 1 : 0];
            [diag writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_ui_ds.txt"]
                     atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        }
    } @catch (__unused NSException *e) {}
}

static void LBReapplyLastSearchBooks(void) {
    if (sLastAppliedSearchBooks.count == 0) return;
    NSArray *vcs = LBFindBookSearchVCs();
    if (vcs.count == 0) return;
    NSString *kw = sPendingSearchKeyword;
    for (UIViewController *vc in vcs) {
        for (id b in sLastAppliedSearchBooks) {
            if (![b isKindOfClass:[NSDictionary class]]) continue;
            LBMergeBookIntoSearchVC(vc, b, kw);
        }
    }
}

static void LBFlushPendingSearchUI(void) {
    if (sPendingSearchBooks.count == 0) return;
    NSArray *books = [sPendingSearchBooks copy];
    NSString *kw = [sPendingSearchKeyword copy];
    NSArray *vcs = LBFindBookSearchVCs();
    if (vcs.count == 0) return;
    for (UIViewController *vc in vcs) {
        for (id b in books) {
            if (![b isKindOfClass:[NSDictionary class]]) continue;
            LBMergeBookIntoSearchVC(vc, b, kw);
        }
    }
    [sPendingSearchBooks removeAllObjects];
    NSString *marker = [NSString stringWithFormat:@"uiInject flush ok vcs=%lu books=%lu key=%@",
                        (unsigned long)vcs.count, (unsigned long)books.count, kw ?: @""];
    [marker writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_ui_inject.txt"]
             atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

static void LBSetSearchKeywordOnVC(UIViewController *vc, NSString *keyword) {
    if (keyword.length == 0) return;
    @try { [vc setValue:keyword forKey:@"searchTextOutSide"]; } @catch (__unused NSException *e) {}
    @try { [vc setValue:keyword forKey:@"searchText"]; } @catch (__unused NSException *e) {}
    // searchText 的 setter 常不落地；直接写 ivar
    Class cls = [vc class];
    while (cls && cls != [NSObject class]) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *name = ivar_getName(ivars[i]);
            if (!name) continue;
            if (strcmp(name, "_searchText") == 0 || strcmp(name, "_searchTextOutSide") == 0) {
                object_setIvar(vc, ivars[i], keyword);
            }
        }
        free(ivars);
        cls = class_getSuperclass(cls);
    }
    @try {
        if ([vc respondsToSelector:@selector(setSearchTextOutSide:)]) {
            ((void (*)(id, SEL, NSString *))objc_msgSend)(vc, @selector(setSearchTextOutSide:), keyword);
        }
    } @catch (__unused NSException *e) {}
}

static NSInteger LBHookedNumberOfRows(id self, SEL _cmd, UITableView *tv, NSInteger section) {
    NSInteger orig = 0;
    if (sOrigNumberOfRows) {
        orig = ((NSInteger (*)(id, SEL, UITableView *, NSInteger))sOrigNumberOfRows)(self, _cmd, tv, section);
    }
    if (orig > 0) return orig;
    // 仅当 table 的 dataSource 就是 self 时兜底，避免与 FilteredDataSource 行数不一致崩
    if (tv.dataSource != self) return orig;
    @try {
        id cur = [self valueForKey:@"arrBaseData"];
        if (![cur isKindOfClass:[NSArray class]] || [cur count] == 0) return orig;
        BOOL hasLegado = NO;
        for (id item in cur) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            if (item[@"legadoBridge"] || item[@"fromLegadoBridge"]) { hasLegado = YES; break; }
        }
        if (hasLegado) return (NSInteger)[cur count];
    } @catch (__unused NSException *e) {}
    return orig;
}

static UITableViewCell *LBHookedCellForRow(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    // fail-open：不拦截 cell 渲染，避免越界/类型崩
    if (sOrigCellForRow) {
        return ((UITableViewCell * (*)(id, SEL, UITableView *, NSIndexPath *))sOrigCellForRow)(self, _cmd, tv, ip);
    }
    return nil;
}

void LBInstallSearchUIAppearFlush(void) {
    if (sSearchUIAppearHooked) return;
    sSearchUIAppearHooked = YES;
    NSArray *names = @[@"BookSearchController", @"BookSearchVCBase1", @"BookSearchVCBase2"];
    for (NSString *cn in names) {
        Class cls = NSClassFromString(cn);
        if (!cls) continue;
        SEL sel = @selector(viewDidAppear:);
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) continue;
        IMP orig = method_getImplementation(m);
        IMP hook = imp_implementationWithBlock(^void(id self, BOOL animated) {
            ((void (*)(id, SEL, BOOL))orig)(self, sel, animated);
            if (!sKnownSearchVCs) {
                sKnownSearchVCs = [NSHashTable weakObjectsHashTable];
            }
            [sKnownSearchVCs addObject:self];
            sCurrentSearchVC = self; // 强引用直到下一次 appear/搜索结束
            NSString *appear = [NSString stringWithFormat:@"appear %@ known=%lu strong=%@",
                                NSStringFromClass([self class]),
                                (unsigned long)sKnownSearchVCs.count,
                                NSStringFromClass([sCurrentSearchVC class])];
            [appear writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_appear.txt"]
                     atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            dispatch_async(dispatch_get_main_queue(), ^{
                LBFlushPendingSearchUI();
                LBReapplyLastSearchBooks();
            });
        });
        method_setImplementation(m, hook);
    }
    // 兜底：有 arrBaseData+legadoBridge 时强制 numberOfRows / 填 cell
    Class base1 = NSClassFromString(@"BookSearchVCBase1");
    if (base1) {
        Method rowsM = class_getInstanceMethod(base1, @selector(tableView:numberOfRowsInSection:));
        if (rowsM && !sOrigNumberOfRows) {
            sOrigNumberOfRows = method_getImplementation(rowsM);
            method_setImplementation(rowsM, (IMP)LBHookedNumberOfRows);
        }
        Method cellM = class_getInstanceMethod(base1, @selector(tableView:cellForRowAtIndexPath:));
        if (cellM && !sOrigCellForRow) {
            sOrigCellForRow = method_getImplementation(cellM);
            method_setImplementation(cellM, (IMP)LBHookedCellForRow);
        }
    }
}

void LBApplySearchResultsToUI(NSArray *books, NSString *keyword) {
    if (![books isKindOfClass:[NSArray class]] || books.count == 0) return;
    if (![NSThread isMainThread]) {
        NSArray *booksCopy = [books copy];
        NSString *kwCopy = [keyword copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            LBApplySearchResultsToUI(booksCopy, kwCopy);
        });
        return;
    }
    @try {
    LBInstallSearchUIAppearFlush();
    if (!sPendingSearchBooks) sPendingSearchBooks = [NSMutableArray array];
    // 合并进 pending（同 key 去重）
    for (id b in books) {
        if (![b isKindOfClass:[NSDictionary class]]) continue;
        NSString *k = LBSearchBookKey(b);
        BOOL exists = NO;
        for (id cur in sPendingSearchBooks) {
            if ([cur isKindOfClass:[NSDictionary class]] && [LBSearchBookKey(cur) isEqualToString:k]) {
                exists = YES;
                break;
            }
        }
        if (!exists) [sPendingSearchBooks addObject:b];
    }
    if (keyword.length > 0) sPendingSearchKeyword = [keyword copy];

    NSArray *vcs = LBFindBookSearchVCs();
    // 每次 Apply 都 dump，便于对照「空列表」实际持有者
    LBDumpVisibleVCTree();
    if (vcs.count == 0) {
        NSString *marker = [NSString stringWithFormat:@"uiInject pending n=%lu key=%@ (no BookSearchVC yet)",
                            (unsigned long)sPendingSearchBooks.count, keyword ?: @""];
        [marker writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_ui_inject.txt"]
                 atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return;
    }
    NSUInteger applied = 0;
    if (!sLastAppliedSearchBooks) sLastAppliedSearchBooks = [NSMutableArray array];
    [sLastAppliedSearchBooks removeAllObjects];
    NSMutableArray *vcNames = [NSMutableArray array];
    for (UIViewController *vc in vcs) {
        [vcNames addObject:[NSString stringWithFormat:@"%@%@",
                            NSStringFromClass([vc class]),
                            LBVCIsVisibleInWindow(vc) ? @"*" : @""]];
        for (id b in sPendingSearchBooks) {
            if (![b isKindOfClass:[NSDictionary class]]) continue;
            LBMergeBookIntoSearchVC(vc, b, keyword ?: sPendingSearchKeyword);
            if (![sLastAppliedSearchBooks containsObject:b]) {
                [sLastAppliedSearchBooks addObject:b];
            }
            applied++;
        }
        if (LBVCIsVisibleInWindow(vc)) {
            sCurrentSearchVC = vc;
        }
    }
    [sPendingSearchBooks removeAllObjects];
    NSString *marker = [NSString stringWithFormat:@"uiInject ok vcs=%lu applied=%lu key=%@ targets=%@",
                        (unsigned long)vcs.count, (unsigned long)applied, keyword ?: @"",
                        [vcNames componentsJoinedByString:@","]];
    [marker writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_ui_inject.txt"]
             atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    // 原生搜索结束常回写空 FilteredDS；延迟再灌两次
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        LBReapplyLastSearchBooks();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        LBReapplyLastSearchBooks();
    });
    } @catch (NSException *e) {
        NSLog(@"[LegadoBridge] LBApplySearchResultsToUI fail-open: %@", e);
    }
}

#pragma mark - Catalog UI inject

static NSArray *sPendingCatalogChapters = nil;
static NSString *sPendingCatalogBookUrl = nil;
static NSDictionary *sPendingResetContent = nil;
static BOOL sReaderContentAppearHooked = NO;
static BOOL sCatalogUIAppearHooked = NO;
static BOOL sCatalogInjectReentrant = NO;
static IMP sOrigCatalogNumberOfRows = NULL;
static IMP sOrigCatalogCellForRow = NULL;
static void (*LBOrig_setArrCatalog)(id, SEL, id) = NULL;
static id (*LBOrig_getArrCatalog)(id, SEL) = NULL;
static void (*LBOrig_catalogDidSelect)(id, SEL, UITableView *, NSIndexPath *) = NULL;

static void LBCatalogWriteMarker(NSString *msg) {
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_catalog_ui_inject.txt"];
    [msg writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

static void LBCatalogDumpVCTree(void) {
    NSMutableArray *lines = [NSMutableArray array];
    for (UIWindow *w in LBAllAppWindows()) {
        UIViewController *root = w.rootViewController;
        if (!root) continue;
        NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
        while (stack.count > 0) {
            UIViewController *vc = stack.lastObject;
            [stack removeLastObject];
            NSString *name = NSStringFromClass([vc class]);
            BOOL hasArr = [vc respondsToSelector:@selector(setArrCatalog:)] ||
                          (class_getInstanceVariable(object_getClass(vc), "_arrCatalog") != NULL);
            NSUInteger arrN = 0;
            @try {
                id cur = [vc valueForKey:@"arrCatalog"];
                if ([cur isKindOfClass:[NSArray class]]) arrN = [cur count];
            } @catch (__unused NSException *e) {}
            [lines addObject:[NSString stringWithFormat:@"%@%@%@ n=%lu",
                              name,
                              LBVCIsVisibleInWindow(vc) ? @"*" : @"",
                              hasArr ? @"[arrCatalog]" : @"",
                              (unsigned long)arrN]];
            for (UIViewController *c in vc.childViewControllers) [stack addObject:c];
            if (vc.presentedViewController) [stack addObject:vc.presentedViewController];
            if ([vc isKindOfClass:[UINavigationController class]]) {
                for (UIViewController *c in [(UINavigationController *)vc viewControllers]) [stack addObject:c];
            }
            if ([vc isKindOfClass:[UITabBarController class]]) {
                for (UIViewController *c in [(UITabBarController *)vc viewControllers]) [stack addObject:c];
            }
        }
    }
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_catalog_vc_tree.txt"];
    [[lines componentsJoinedByString:@"\n"] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

static BOOL LBObjectHasCatalogArray(id obj) {
    if (!obj) return NO;
    if ([obj respondsToSelector:@selector(setArrCatalog:)]) return YES;
    if (class_getInstanceVariable(object_getClass(obj), "_arrCatalog") != NULL) return YES;
    if ([obj respondsToSelector:@selector(setArrBaseData:)]) return YES;
    if (class_getInstanceVariable(object_getClass(obj), "_arrBaseData") != NULL) return YES;
    return NO;
}

static NSArray<UIViewController *> *LBFindCatalogVCs(void) {
    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    void (^consider)(UIViewController *) = ^(UIViewController *vc) {
        if (!vc || [seen containsObject:vc]) return;
        [seen addObject:vc];
        NSString *cn = NSStringFromClass([vc class]);
        BOOL nameHit = [cn containsString:@"Catalog"] || [cn containsString:@"BookDetail"] ||
                       [cn containsString:@"ReadVC"] || [cn containsString:@"TextRead"];
        if (nameHit || LBObjectHasCatalogArray(vc)) {
            [out addObject:vc];
        }
    };
    for (UIWindow *w in LBAllAppWindows()) {
        UIViewController *root = w.rootViewController;
        if (!root) continue;
        NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
        while (stack.count > 0) {
            UIViewController *vc = stack.lastObject;
            [stack removeLastObject];
            consider(vc);
            for (UIViewController *c in vc.childViewControllers) [stack addObject:c];
            if (vc.presentedViewController) [stack addObject:vc.presentedViewController];
            if ([vc isKindOfClass:[UINavigationController class]]) {
                for (UIViewController *c in [(UINavigationController *)vc viewControllers]) [stack addObject:c];
            }
            if ([vc isKindOfClass:[UITabBarController class]]) {
                for (UIViewController *c in [(UITabBarController *)vc viewControllers]) [stack addObject:c];
            }
        }
    }
    // 可见 TableView → owner（对齐搜索；目录页常是 CatalogCon）
    for (UIWindow *w in LBAllAppWindows()) {
        NSMutableArray *views = [NSMutableArray arrayWithObject:w];
        while (views.count > 0) {
            UIView *v = views.lastObject;
            [views removeLastObject];
            if ([v isKindOfClass:[UITableView class]]) {
                UIViewController *owner = LBViewControllerOwningView(v);
                if (owner && LBVCIsVisibleInWindow(owner)) {
                    consider(owner);
                }
                UITableView *tv = (UITableView *)v;
                if ([tv.dataSource isKindOfClass:[UIViewController class]] &&
                    LBVCIsVisibleInWindow((UIViewController *)tv.dataSource)) {
                    consider((UIViewController *)tv.dataSource);
                }
            }
            for (UIView *sub in v.subviews) [views addObject:sub];
        }
    }
    [out sortUsingComparator:^NSComparisonResult(UIViewController *a, UIViewController *b) {
        NSString *ca = NSStringFromClass([a class]);
        NSString *cb = NSStringFromClass([b class]);
        BOOL aCat = [ca containsString:@"Catalog"];
        BOOL bCat = [cb containsString:@"Catalog"];
        if (aCat != bCat) return aCat ? NSOrderedAscending : NSOrderedDescending;
        BOOL va = LBVCIsVisibleInWindow(a);
        BOOL vb = LBVCIsVisibleInWindow(b);
        if (va == vb) return NSOrderedSame;
        return va ? NSOrderedAscending : NSOrderedDescending;
    }];
    return out;
}

static void LBReloadCatalogVC(UIViewController *vc) {
    @try {
        if ([vc respondsToSelector:@selector(reloadData)]) {
            ((void (*)(id, SEL))objc_msgSend)(vc, @selector(reloadData));
        }
    } @catch (__unused NSException *e) {}
    for (NSString *selName in @[@"onCatalogUpdated", @"updateCatalog", @"onShowCatalogEvent"]) {
        @try {
            SEL sel = NSSelectorFromString(selName);
            if ([vc respondsToSelector:sel]) {
                ((void (*)(id, SEL))objc_msgSend)(vc, sel);
            }
        } @catch (__unused NSException *e) {}
    }
    @try {
        id tv = nil;
        @try { tv = [vc valueForKey:@"tableView"]; } @catch (__unused NSException *e) {}
        if (!tv) @try { tv = [vc valueForKey:@"tv"]; } @catch (__unused NSException *e) {}
        if ([tv isKindOfClass:[UITableView class]]) {
            [(UITableView *)tv reloadData];
        }
    } @catch (__unused NSException *e) {}
    @try {
        if (!vc.isViewLoaded) return;
        NSMutableArray *stack = [NSMutableArray arrayWithObject:vc.view];
        while (stack.count > 0) {
            UIView *v = stack.lastObject;
            [stack removeLastObject];
            if ([v isKindOfClass:[UITableView class]]) {
                [(UITableView *)v reloadData];
            }
            for (UIView *sub in v.subviews) [stack addObject:sub];
        }
    } @catch (__unused NSException *e) {}
}

static NSUInteger LBReadArrayCount(id obj, NSString *key) {
    @try {
        id cur = [obj valueForKey:key];
        if ([cur isKindOfClass:[NSArray class]]) return [cur count];
    } @catch (__unused NSException *e) {}
    return 0;
}

static BOOL LBTrySetArrayKey(id obj, NSString *key, NSArray *chapters) {
    if (!obj || key.length == 0) return NO;
    @try {
        [obj setValue:chapters forKey:key];
    } @catch (__unused NSException *e) {
        NSString *setter = [NSString stringWithFormat:@"set%@%@:",
                            [[key substringToIndex:1] uppercaseString],
                            [key substringFromIndex:1]];
        SEL sel = NSSelectorFromString(setter);
        if ([obj respondsToSelector:sel]) {
            @try {
                ((void (*)(id, SEL, id))objc_msgSend)(obj, sel, chapters);
            } @catch (__unused NSException *e2) {}
        }
    }
    // 无论 setter 是否过滤，沿继承链强制写 ivar（CatalogCon.arrCatalog 常拒收 NSDictionary）
    NSString *ivarName = [@"_" stringByAppendingString:key];
    Class cls = object_getClass(obj);
    while (cls && cls != [NSObject class]) {
        Ivar ivar = class_getInstanceVariable(cls, [ivarName UTF8String]);
        if (ivar) {
            object_setIvar(obj, ivar, chapters);
            return YES;
        }
        cls = class_getSuperclass(cls);
    }
    // 无 ivar 时：若 valueForKey 已能读回则算成功
    return LBReadArrayCount(obj, key) > 0;
}

static BOOL LBArrayLooksLegado(NSArray *arr) {
    if (![arr isKindOfClass:[NSArray class]] || arr.count == 0) return NO;
    for (id item in arr) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        if (item[@"legadoBridge"] || item[@"fromLegadoBridge"] || item[@"cpTitle"]) return YES;
    }
    return NO;
}

static NSString *LBChapterTitleFromItem(id item) {
    if ([item isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = item;
        for (NSString *k in @[@"cpTitle", @"title", @"name", @"chapterName"]) {
            id v = d[k];
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) return v;
        }
        return nil;
    }
    for (NSString *k in @[@"cpTitle", @"title", @"name", @"chapterName"]) {
        @try {
            id v = [item valueForKey:k];
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) return v;
        } @catch (__unused NSException *e) {}
    }
    return nil;
}

static void LBDeliverCatalogNotify(id target, NSArray *chapters, NSString *bookUrl) {
    if (!target || chapters.count == 0) return;
    NSDictionary *userInfo = @{
        @"bookUrl": bookUrl ?: @"",
        @"chapterList": chapters,
        @"arrCatalog": chapters,
        @"arrChapter": chapters,
        @"legadoBridge": @"1",
        @"fromLegadoBridge": @YES
    };
    NSNotification *note = [NSNotification notificationWithName:@"dNotifyName_QueryCatalogResponse"
                                                          object:nil
                                                        userInfo:userInfo];
    SEL sel = @selector(onCatalogQueryFinishNotify:);
    if ([target respondsToSelector:sel]) {
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(target, sel, note);
        } @catch (__unused NSException *e) {}
    }
}

/// 写入 arrCatalog / arrBaseData / arrCpInfo，并尝试嵌套 catalogView + 通知
static BOOL LBWriteChaptersOntoObject(id obj, NSArray *chapters) {
    if (!obj || ![chapters isKindOfClass:[NSArray class]] || chapters.count == 0) return NO;
    BOOL wrote = NO;
    BOOL prev = sCatalogInjectReentrant;
    sCatalogInjectReentrant = YES;
    for (NSString *key in @[@"arrCatalog", @"arrBaseData", @"arrCpInfo", @"chapterList"]) {
        if (LBTrySetArrayKey(obj, key, chapters)) wrote = YES;
    }
    @try {
        id cv = [obj valueForKey:@"catalogView"];
        if (cv && cv != obj) {
            if (LBWriteChaptersOntoObject(cv, chapters)) wrote = YES;
        }
    } @catch (__unused NSException *e) {}
    sCatalogInjectReentrant = prev;
    return wrote;
}

static void LBWriteChaptersOntoVisibleTables(NSArray *chapters, NSString *bookUrl, NSMutableArray *targets) {
    for (UIWindow *w in LBAllAppWindows()) {
        NSMutableArray *views = [NSMutableArray arrayWithObject:w];
        while (views.count > 0) {
            UIView *v = views.lastObject;
            [views removeLastObject];
            if ([v isKindOfClass:[UITableView class]] && v.window) {
                UITableView *tv = (UITableView *)v;
                id ds = tv.dataSource;
                if (ds) {
                    BOOL wrote = LBWriteChaptersOntoObject(ds, chapters);
                    NSUInteger nCat = LBReadArrayCount(ds, @"arrCatalog");
                    NSUInteger nBase = LBReadArrayCount(ds, @"arrBaseData");
                    if (wrote || nCat > 0 || nBase > 0) {
                        [targets addObject:[NSString stringWithFormat:@"TV.ds=%@ cat=%lu base=%lu",
                                            NSStringFromClass([ds class]),
                                            (unsigned long)nCat, (unsigned long)nBase]];
                    }
                }
                UIViewController *owner = LBViewControllerOwningView(tv);
                if (owner && owner != ds) {
                    LBWriteChaptersOntoObject(owner, chapters);
                    LBDeliverCatalogNotify(owner, chapters, bookUrl);
                }
                @try { [tv reloadData]; } @catch (__unused NSException *e) {}
            }
            for (UIView *sub in v.subviews) [views addObject:sub];
        }
    }
}

static NSUInteger LBApplyPendingCatalogToVCs(NSArray *chapters, NSString *bookUrl, NSString *phase) {
    if (![chapters isKindOfClass:[NSArray class]] || chapters.count == 0) return 0;
    LBCatalogDumpVCTree();
    NSArray *vcs = LBFindCatalogVCs();
    NSMutableArray *targets = [NSMutableArray array];
    NSUInteger applied = 0;
    for (UIViewController *vc in vcs) {
        BOOL wrote = LBWriteChaptersOntoObject(vc, chapters);
        LBDeliverCatalogNotify(vc, chapters, bookUrl);
        NSUInteger nCat = LBReadArrayCount(vc, @"arrCatalog");
        NSUInteger nBase = LBReadArrayCount(vc, @"arrBaseData");
        if (wrote || nCat > 0 || nBase > 0) {
            applied++;
            [targets addObject:[NSString stringWithFormat:@"%@%@ cat=%lu base=%lu",
                                NSStringFromClass([vc class]),
                                LBVCIsVisibleInWindow(vc) ? @"*" : @"",
                                (unsigned long)nCat, (unsigned long)nBase]];
            if ([vc isKindOfClass:[UIViewController class]]) {
                LBReloadCatalogVC(vc);
            }
        }
    }
    LBWriteChaptersOntoVisibleTables(chapters, bookUrl, targets);
    LBCatalogWriteMarker([NSString stringWithFormat:
                          @"uiInject %@ vcs=%lu applied=%lu book=%@ n=%lu targets=%@",
                          phase ?: @"ok", (unsigned long)vcs.count, (unsigned long)applied,
                          bookUrl ?: @"", (unsigned long)chapters.count,
                          [targets componentsJoinedByString:@","]]);
    return applied;
}

static void LBScheduleCatalogReapply(NSArray *chapters, NSString *bookUrl) {
    NSArray *chCopy = [chapters copy];
    NSString *buCopy = [bookUrl copy];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        LBApplyPendingCatalogToVCs(chCopy, buCopy, @"reapply0.35");
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        LBApplyPendingCatalogToVCs(chCopy, buCopy, @"reapply1.0");
    });
}

static NSInteger LBHookedCatalogNumberOfRows(id self, SEL _cmd, UITableView *tv, NSInteger section) {
    // legado 兜底优先：避免原生 orig>0 的脏行盖过我们的 2 章
    for (NSString *key in @[@"arrCatalog", @"arrBaseData", @"arrCpInfo"]) {
        @try {
            id cur = [self valueForKey:key];
            if (!LBArrayLooksLegado(cur)) continue;
            return (NSInteger)[cur count];
        } @catch (__unused NSException *e) {}
    }
    if (tv && tv.dataSource && tv.dataSource != self) {
        id dsObj = (id)tv.dataSource;
        for (NSString *key in @[@"arrCatalog", @"arrBaseData", @"arrCpInfo"]) {
            @try {
                id cur = [dsObj valueForKey:key];
                if (!LBArrayLooksLegado(cur)) continue;
                return (NSInteger)[cur count];
            } @catch (__unused NSException *e) {}
        }
    }
    NSInteger orig = 0;
    if (sOrigCatalogNumberOfRows) {
        orig = ((NSInteger (*)(id, SEL, UITableView *, NSInteger))sOrigCatalogNumberOfRows)(self, _cmd, tv, section);
    }
    return orig;
}

static UITableViewCell *LBHookedCatalogCellForRow(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    NSArray *cat = nil;
    NSArray *base = nil;
    @try {
        id c = [self valueForKey:@"arrCatalog"];
        if ([c isKindOfClass:[NSArray class]]) cat = c;
    } @catch (__unused NSException *e) {}
    @try {
        id b = [self valueForKey:@"arrBaseData"];
        if ([b isKindOfClass:[NSArray class]]) base = b;
    } @catch (__unused NSException *e) {}
    BOOL legadoFallback = (!cat || cat.count == 0) && LBArrayLooksLegado(base);
    if (!legadoFallback && sOrigCatalogCellForRow) {
        return ((UITableViewCell * (*)(id, SEL, UITableView *, NSIndexPath *))sOrigCatalogCellForRow)(self, _cmd, tv, ip);
    }
    if (legadoFallback && ip.row >= 0 && ip.row < (NSInteger)base.count) {
        id item = base[(NSUInteger)ip.row];
        NSString *title = LBChapterTitleFromItem(item) ?: [NSString stringWithFormat:@"章节 %ld", (long)ip.row + 1];
        UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"legado.catalog.cp"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                         reuseIdentifier:@"legado.catalog.cp"];
        }
        cell.textLabel.text = title;
        cell.textLabel.textColor = [UIColor labelColor];
        cell.backgroundColor = [UIColor clearColor];
        return cell;
    }
    if (sOrigCatalogCellForRow) {
        return ((UITableViewCell * (*)(id, SEL, UITableView *, NSIndexPath *))sOrigCatalogCellForRow)(self, _cmd, tv, ip);
    }
    return nil;
}

static void LBCatalogSetArrCatalog_IMP(id self, SEL _cmd, id arr) {
    if (LBOrig_setArrCatalog) {
        LBOrig_setArrCatalog(self, _cmd, arr);
    }
    if (sCatalogInjectReentrant) return;
    BOOL empty = (!arr || ([arr isKindOfClass:[NSArray class]] && [arr count] == 0));
    if (!empty || sPendingCatalogChapters.count == 0) return;
    // 原生异步回写空目录时，用 pending 盖回（含 ivar 强写）
    NSArray *ch = [sPendingCatalogChapters copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (sPendingCatalogChapters.count == 0) return;
        LBWriteChaptersOntoObject(self, ch);
        if ([self isKindOfClass:[UIViewController class]]) {
            LBReloadCatalogVC((UIViewController *)self);
        }
        LBCatalogWriteMarker([NSString stringWithFormat:@"uiInject setArrCatalog-guard n=%lu on=%@",
                              (unsigned long)ch.count, NSStringFromClass([self class])]);
    });
}

/// 组装 openReader 所需书本字典（优先详情 dicBook，避免把章节 dict 当书）
static NSMutableDictionary *LBBookDictForOpenReader(NSString *bookUrl,
                                                    id chapterItem,
                                                    NSInteger idx,
                                                    NSString *chUrl,
                                                    NSString **outSourceName) {
    NSMutableDictionary *book = [NSMutableDictionary dictionary];
    NSString *sourceName = nil;
    for (UIViewController *vc in LBFindCatalogVCs()) {
        NSString *cn = NSStringFromClass([vc class]);
        if (![cn containsString:@"BookDetail"]) continue;
        @try {
            id dic = [vc valueForKey:@"dicBook"];
            if ([dic isKindOfClass:[NSDictionary class]] && [(NSDictionary *)dic count] > 0) {
                [book addEntriesFromDictionary:(NSDictionary *)dic];
            }
        } @catch (__unused NSException *e) {}
        @try {
            id sn = [vc valueForKeyPath:@"dicBook.sourceName"];
            if ([sn isKindOfClass:[NSString class]] && [(NSString *)sn length] > 0) {
                sourceName = sn;
            }
        } @catch (__unused NSException *e) {}
        if (book.count > 0) break;
    }
    if (book.count == 0) {
        id core = LBLegadoCoreIfReady();
        if ([core respondsToSelector:@selector(detailDictForBookUrl:)]) {
            @try {
                NSDictionary *detail = ((NSDictionary * (*)(id, SEL, NSString *))objc_msgSend)(
                    core, @selector(detailDictForBookUrl:), bookUrl
                );
                if ([detail isKindOfClass:[NSDictionary class]]) {
                    [book addEntriesFromDictionary:detail];
                }
            } @catch (__unused NSException *e) {}
        }
    }
    // 章节字段叠上去，但 bookUrl/url 必须保持书籍地址
    if ([chapterItem isKindOfClass:[NSDictionary class]]) {
        NSDictionary *ch = (NSDictionary *)chapterItem;
        for (NSString *k in @[@"cpTitle", @"title", @"name", @"chapterName", @"cpIndex", @"index"]) {
            if (ch[k]) book[k] = ch[k];
        }
        if (!sourceName) {
            id sn = ch[@"sourceName"];
            if ([sn isKindOfClass:[NSString class]]) sourceName = sn;
        }
    }
    if (bookUrl.length > 0) {
        book[@"bookUrl"] = bookUrl;
        book[@"url"] = bookUrl;
    }
    if (chUrl.length > 0) {
        book[@"chapterUrl"] = chUrl;
        book[@"cpUrl"] = chUrl;
        book[@"curChapterUrl"] = chUrl;
    }
    book[@"cpIndex"] = @(idx);
    book[@"chapterIndex"] = @(idx);
    book[@"legadoBridge"] = @"1";
    if (sourceName.length == 0) {
        id sn = book[@"sourceName"] ?: book[@"bookSourceName"];
        if ([sn isKindOfClass:[NSString class]]) sourceName = sn;
    }
    // 详情页「站点(0+)」时 openReader 会静默空转：补 sourceUrl + arrSource
    NSString *sourceUrl = nil;
    id su = book[@"sourceUrl"];
    if ([su isKindOfClass:[NSString class]] && [(NSString *)su length] > 0) {
        sourceUrl = su;
    }
    if (sourceUrl.length == 0) {
        sourceUrl = LBReadingSourceUrlForBookUrl(bookUrl);
    }
    if (sourceName.length > 0) {
        book[@"sourceName"] = sourceName;
        book[@"bookSourceName"] = sourceName;
        book[@"querySourceName"] = sourceName;
    }
    if (sourceUrl.length > 0) {
        book[@"sourceUrl"] = sourceUrl;
    }
    if (sourceName.length > 0 || sourceUrl.length > 0) {
        NSMutableDictionary *site = [NSMutableDictionary dictionary];
        if (sourceName.length > 0) {
            site[@"sourceName"] = sourceName;
            site[@"bookSourceName"] = sourceName;
            site[@"title"] = sourceName;
            site[@"name"] = sourceName;
        }
        if (sourceUrl.length > 0) {
            site[@"sourceUrl"] = sourceUrl;
            site[@"url"] = sourceUrl;
            site[@"bookSourceUrl"] = sourceUrl;
        }
        // 搜索/详情筛选默认 text；DOM 会被当成不可用站点
        site[@"sourceType"] = @"text";
        site[@"enable"] = @"1";
        site[@"enabled"] = @YES;
        site[@"legadoBridge"] = @"1";
        book[@"arrSource"] = @[site];
        book[@"arrSourceInfoRequired"] = @[site];
    }
    if (outSourceName) *outSourceName = sourceName ?: @"";
    return book;
}

/// 把书/站点写回 BookDetail，并触发原生「开始阅读」
static BOOL LBInvokeBeginReadOnDetail(NSMutableDictionary *book, NSString *sourceName, NSString **outMsg) {
    UIViewController *detail = nil;
    for (UIViewController *vc in LBFindCatalogVCs()) {
        NSString *cn = NSStringFromClass([vc class]);
        if ([cn containsString:@"BookDetail"]) {
            detail = vc;
            break;
        }
    }
    if (!detail) {
        for (UIWindow *w in LBAllAppWindows()) {
            UIViewController *root = w.rootViewController;
            if (!root) continue;
            NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
            while (stack.count > 0) {
                UIViewController *vc = stack.lastObject;
                [stack removeLastObject];
                NSString *cn = NSStringFromClass([vc class]);
                if ([cn containsString:@"BookDetail"]) {
                    detail = vc;
                    break;
                }
                for (UIViewController *c in vc.childViewControllers) [stack addObject:c];
                if (vc.presentedViewController) [stack addObject:vc.presentedViewController];
                if ([vc isKindOfClass:[UINavigationController class]]) {
                    for (UIViewController *c in [(UINavigationController *)vc viewControllers]) {
                        [stack addObject:c];
                    }
                }
            }
            if (detail) break;
        }
    }
    if (!detail) {
        if (outMsg) *outMsg = @"beginRead miss: no BookDetail";
        return NO;
    }
    @try {
        if ([detail respondsToSelector:@selector(setDicBook:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(detail, @selector(setDicBook:), book);
        } else {
            [detail setValue:book forKey:@"dicBook"];
        }
    } @catch (__unused NSException *e) {}
    id arrSource = book[@"arrSource"];
    if ([arrSource isKindOfClass:[NSArray class]]) {
        @try {
            SEL setSrc = NSSelectorFromString(@"setArrSource:");
            if ([detail respondsToSelector:setSrc]) {
                ((void (*)(id, SEL, id))objc_msgSend)(detail, setSrc, arrSource);
            } else {
                [detail setValue:arrSource forKey:@"arrSource"];
            }
        } @catch (__unused NSException *e) {}
        @try {
            SEL resetSrc = NSSelectorFromString(@"resetSourceInfo");
            if ([detail respondsToSelector:resetSrc]) {
                ((void (*)(id, SEL))objc_msgSend)(detail, resetSrc);
            }
        } @catch (__unused NSException *e) {}
    }
    if (sourceName.length > 0) {
        @try { [detail setValue:sourceName forKey:@"sourceName"]; } @catch (__unused NSException *e) {}
    }
    // 原生「开始阅读」按钮
    for (NSString *selName in @[@"onBeginReadEvent", @"onBeginReadEvent:"]) {
        SEL sel = NSSelectorFromString(selName);
        if (![detail respondsToSelector:sel]) continue;
        @try {
            if ([selName hasSuffix:@":"]) {
                ((void (*)(id, SEL, id))objc_msgSend)(detail, sel, nil);
            } else {
                ((void (*)(id, SEL))objc_msgSend)(detail, sel);
            }
            if (outMsg) {
                *outMsg = [NSString stringWithFormat:@"beginRead ok %@ on %@",
                           selName, NSStringFromClass([detail class])];
            }
            return YES;
        } @catch (NSException *e) {
            if (outMsg) {
                *outMsg = [NSString stringWithFormat:@"beginRead ex %@: %@",
                           selName, e.reason ?: @""];
            }
        }
    }
    if (outMsg) {
        *outMsg = [NSString stringWithFormat:@"beginRead miss sel on %@",
                   NSStringFromClass([detail class])];
    }
    return NO;
}

/// 原生 openReader 在 AppDelegate（非 BookDetail）；失败时再扫详情/目录 VC
static BOOL LBCallOpenReader(NSDictionary *book, NSString *sourceName, NSString **outMsg) {
    SEL openSel = NSSelectorFromString(@"openReader:sourceName:record:");
    NSMutableArray *targets = [NSMutableArray array];
    id appDel = [UIApplication sharedApplication].delegate;
    if (appDel) [targets addObject:appDel];
    for (UIViewController *vc in LBFindCatalogVCs()) {
        if (![targets containsObject:vc]) [targets addObject:vc];
    }
    for (UIWindow *w in LBAllAppWindows()) {
        UIViewController *root = w.rootViewController;
        if (!root) continue;
        NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
        while (stack.count > 0) {
            UIViewController *vc = stack.lastObject;
            [stack removeLastObject];
            if (![targets containsObject:vc]) [targets addObject:vc];
            for (UIViewController *c in vc.childViewControllers) [stack addObject:c];
            if (vc.presentedViewController) [stack addObject:vc.presentedViewController];
            if ([vc isKindOfClass:[UINavigationController class]]) {
                for (UIViewController *c in [(UINavigationController *)vc viewControllers]) {
                    [stack addObject:c];
                }
            }
        }
    }
    NSMutableArray *tried = [NSMutableArray array];
    for (id t in targets) {
        NSString *cn = NSStringFromClass([t class]);
        Method m = class_getInstanceMethod(object_getClass(t), openSel);
        Class walk = [t class];
        while (!m && walk && walk != [NSObject class]) {
            m = class_getInstanceMethod(walk, openSel);
            walk = class_getSuperclass(walk);
        }
        [tried addObject:[NSString stringWithFormat:@"%@/%@", cn, m ? @"has" : @"no"]];
        if (!m) continue;
        @try {
            NSMutableDictionary *mutableBook =
                [book isKindOfClass:[NSMutableDictionary class]]
                    ? (NSMutableDictionary *)book
                    : [(book ?: @{}) mutableCopy];
            if (!mutableBook) mutableBook = [NSMutableDictionary dictionary];
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(
                t, openSel, mutableBook, sourceName ?: @"", nil
            );
            if (outMsg) {
                *outMsg = [NSString stringWithFormat:@"openReader ok on %@ src=%@",
                           cn, sourceName ?: @""];
            }
            return YES;
        } @catch (NSException *e) {
            NSLog(@"[LegadoBridge] openReader on %@ fail-open: %@", cn, e);
            [tried addObject:[NSString stringWithFormat:@"%@/ex:%@", cn, e.reason ?: @""]];
        }
    }
    if (outMsg) {
        *outMsg = [NSString stringWithFormat:@"openReader miss tried=%@",
                   [tried componentsJoinedByString:@","]];
    }
    return NO;
}

/// openReader 不可靠时：dismiss 目录并 push TextReadVC，再靠 ResetContent 灌正文
static BOOL LBPushTextReaderFallback(NSDictionary *book, NSString *sourceName, NSString **outMsg) {
    Class cls = NSClassFromString(@"TextReadVC3");
    if (!cls) cls = NSClassFromString(@"TextReadVC2");
    if (!cls) cls = NSClassFromString(@"TextReadVC1");
    if (!cls) cls = NSClassFromString(@"ReadVCBase1");
    if (!cls) {
        if (outMsg) *outMsg = @"pushReader miss: no TextReadVC class";
        return NO;
    }
    id vc = nil;
    @try {
        vc = [[cls alloc] init];
    } @catch (__unused NSException *e) {
        vc = nil;
    }
    if (!vc) {
        if (outMsg) *outMsg = @"pushReader miss: alloc init failed";
        return NO;
    }
    NSMutableDictionary *dic = [NSMutableDictionary dictionaryWithDictionary:book ?: @{}];
    if (sourceName.length > 0) {
        dic[@"sourceName"] = sourceName;
        dic[@"bookSourceName"] = sourceName;
        dic[@"querySourceName"] = sourceName;
    }
    dic[@"legadoBridge"] = @"1";
    @try {
        if ([vc respondsToSelector:@selector(setDicBook:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(vc, @selector(setDicBook:), dic);
        } else {
            [vc setValue:dic forKey:@"dicBook"];
        }
    } @catch (__unused NSException *e) {}
    // 关掉可见 CatalogCon
    for (UIViewController *c in LBFindCatalogVCs()) {
        NSString *cn = NSStringFromClass([c class]);
        if (![cn containsString:@"Catalog"]) continue;
        @try {
            if (c.presentingViewController) {
                [c dismissViewControllerAnimated:NO completion:nil];
            } else if (c.navigationController) {
                [c.navigationController popViewControllerAnimated:NO];
            }
        } @catch (__unused NSException *e) {}
    }
    UINavigationController *nav = nil;
    for (UIWindow *w in LBAllAppWindows()) {
        UIViewController *root = w.rootViewController;
        if (!root) continue;
        NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
        while (stack.count > 0) {
            UIViewController *cur = stack.lastObject;
            [stack removeLastObject];
            if ([cur isKindOfClass:[UINavigationController class]]) {
                UINavigationController *n = (UINavigationController *)cur;
                if (LBVCIsVisibleInWindow(n.visibleViewController ?: n)) {
                    nav = n;
                    break;
                }
            }
            if (cur.navigationController && LBVCIsVisibleInWindow(cur)) {
                nav = cur.navigationController;
                break;
            }
            for (UIViewController *ch in cur.childViewControllers) [stack addObject:ch];
            if (cur.presentedViewController) [stack addObject:cur.presentedViewController];
            if ([cur isKindOfClass:[UITabBarController class]]) {
                for (UIViewController *ch in [(UITabBarController *)cur viewControllers]) {
                    [stack addObject:ch];
                }
            }
        }
        if (nav) break;
    }
    if (!nav) {
        // CatalogCon 常以 present 盖住；退而 present TextReadVC
        UIViewController *host = nil;
        for (UIWindow *w in LBAllAppWindows()) {
            UIViewController *root = w.rootViewController;
            if (!root) continue;
            host = root;
            while (host.presentedViewController) host = host.presentedViewController;
            if (host) break;
        }
        if (!host) {
            if (outMsg) *outMsg = @"pushReader miss: no nav/host";
            return NO;
        }
        @try {
            UINavigationController *wrap =
                [[UINavigationController alloc] initWithRootViewController:(UIViewController *)vc];
            wrap.modalPresentationStyle = UIModalPresentationFullScreen;
            [host presentViewController:wrap animated:YES completion:nil];
            if (outMsg) {
                *outMsg = [NSString stringWithFormat:@"presentReader ok %@ on %@",
                           NSStringFromClass(cls), NSStringFromClass([host class])];
            }
            return YES;
        } @catch (NSException *e) {
            if (outMsg) *outMsg = [NSString stringWithFormat:@"presentReader fail: %@", e.reason ?: @""];
            return NO;
        }
    }
    @try {
        [nav pushViewController:(UIViewController *)vc animated:YES];
        if (outMsg) {
            *outMsg = [NSString stringWithFormat:@"pushReader ok %@ on %@",
                       NSStringFromClass(cls), NSStringFromClass([nav class])];
        }
        return YES;
    } @catch (NSException *e) {
        if (outMsg) *outMsg = [NSString stringWithFormat:@"pushReader fail: %@", e.reason ?: @""];
        return NO;
    }
}

void LBNoteResetContentPosted(NSDictionary *userInfo) {
    if (![userInfo isKindOfClass:[NSDictionary class]] || userInfo.count == 0) return;
    sPendingResetContent = [userInfo copy];
    NSString *ch = userInfo[@"chapterUrl"] ?: @"";
    NSString *marker = [NSString stringWithFormat:@"pendingResetContent ch=%@ keys=%lu",
                        ch, (unsigned long)userInfo.count];
    [marker writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_content_pending.txt"]
             atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

static void LBFlushPendingResetContent(NSString *phase) {
    if (sPendingResetContent.count == 0) return;
    NSDictionary *payload = [sPendingResetContent copy];
    void (^post)(void) = ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"dNotifyName_ReadView_ResetContent"
                          object:nil
                        userInfo:payload];
        NSString *marker = [NSString stringWithFormat:@"flushResetContent %@ ch=%@",
                            phase ?: @"", payload[@"chapterUrl"] ?: @""];
        [marker writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_content_flush.txt"]
                 atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    };
    if ([NSThread isMainThread]) post();
    else dispatch_async(dispatch_get_main_queue(), post);
}

void LBInstallReaderContentAppearFlush(void) {
    if (sReaderContentAppearHooked) return;
    sReaderContentAppearHooked = YES;
    NSArray *names = @[
        @"ReadVCBase1", @"ReadVCBase2",
        @"TextReadVC1", @"TextReadVC2", @"TextReadVC3"
    ];
    for (NSString *cn in names) {
        Class cls = NSClassFromString(cn);
        if (!cls) continue;
        SEL sel = @selector(viewDidAppear:);
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) continue;
        IMP orig = method_getImplementation(m);
        IMP hook = imp_implementationWithBlock(^void(id selfObj, BOOL animated) {
            ((void (*)(id, SEL, BOOL))orig)(selfObj, sel, animated);
            if (sPendingResetContent.count == 0) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                LBFlushPendingResetContent([NSString stringWithFormat:@"appear:%@",
                                            NSStringFromClass([selfObj class])]);
            });
        });
        method_setImplementation(m, hook);
    }
}

static void LBInstallCatalogTableHooksOnClass(Class cls) {
    if (!cls) return;
    SEL rowsSel = @selector(tableView:numberOfRowsInSection:);
    Class rowsOwner = LBClassOwningInstanceMethod(cls, rowsSel) ?: cls;
    Method rowsM = class_getInstanceMethod(rowsOwner, rowsSel);
    if (rowsM && !sOrigCatalogNumberOfRows) {
        sOrigCatalogNumberOfRows = method_getImplementation(rowsM);
        method_setImplementation(rowsM, (IMP)LBHookedCatalogNumberOfRows);
    }
    SEL cellSel = @selector(tableView:cellForRowAtIndexPath:);
    Class cellOwner = LBClassOwningInstanceMethod(cls, cellSel) ?: cls;
    Method cellM = class_getInstanceMethod(cellOwner, cellSel);
    if (cellM && !sOrigCatalogCellForRow) {
        sOrigCatalogCellForRow = method_getImplementation(cellM);
        method_setImplementation(cellM, (IMP)LBHookedCatalogCellForRow);
    }
    SEL selSel = @selector(tableView:didSelectRowAtIndexPath:);
    Class selOwner = LBClassOwningInstanceMethod(cls, selSel) ?: cls;
    Method selM = class_getInstanceMethod(selOwner, selSel);
    if (selM && !LBOrig_catalogDidSelect) {
        LBOrig_catalogDidSelect = (void (*)(id, SEL, UITableView *, NSIndexPath *))method_getImplementation(selM);
        IMP hook = imp_implementationWithBlock(^void(id selfObj, UITableView *tv, NSIndexPath *ip) {
            NSArray *use = sPendingCatalogChapters;
            if (use.count == 0) {
                @try {
                    id b = [selfObj valueForKey:@"arrBaseData"];
                    if (LBArrayLooksLegado(b)) use = b;
                } @catch (__unused NSException *e) {}
            }
            if (use.count > 0 && ip && ip.row >= 0 && ip.row < (NSInteger)use.count) {
                LBTrySetArrayKey(selfObj, @"arrCatalog", use);
                id item = use[(NSUInteger)ip.row];
                NSString *chUrl = nil;
                if ([item isKindOfClass:[NSDictionary class]]) {
                    NSDictionary *d = (NSDictionary *)item;
                    chUrl = d[@"cpUrl"] ?: d[@"chapterUrl"] ?: d[@"url"];
                }
                NSString *bookUrl = sPendingCatalogBookUrl;
                if (bookUrl.length == 0) {
                    @try {
                        id bu = [selfObj valueForKeyPath:@"dicBook.bookUrl"];
                        if ([bu isKindOfClass:[NSString class]]) bookUrl = bu;
                    } @catch (__unused NSException *e) {}
                }
                if (chUrl.length > 0 && bookUrl.length > 0) {
                    NSString *msg = [NSString stringWithFormat:@"didSelect ch=%@ book=%@ idx=%ld",
                                     chUrl, bookUrl, (long)ip.row];
                    [msg writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_catalog_select.txt"]
                          atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                    LBInstallReaderContentAppearFlush();
                    NSString *sourceName = nil;
                    NSDictionary *book = LBBookDictForOpenReader(
                        bookUrl, item, ip.row, chUrl, &sourceName
                    );
                    NSString *chCopy = [chUrl copy];
                    NSString *buCopy = [bookUrl copy];
                    // openReader 会对 book 做下标赋值；必须传可变副本，不能 [book copy]
                    NSMutableDictionary *bookCopy = [book mutableCopy] ?: [NSMutableDictionary dictionary];
                    NSString *srcCopy = [sourceName copy] ?: @"";
                    // 1) 原生 didSelect：关掉 CatalogCon / 详情回调
                    // 2) 延迟 AppDelegate.openReader（立即调常被目录 dismiss 冲掉）
                    // 3) 再取正文 + appear/delay 重投 ResetContent
                    if (LBOrig_catalogDidSelect) {
                        @try {
                            LBOrig_catalogDidSelect(selfObj, selSel, tv, ip);
                        } @catch (NSException *e) {
                            NSLog(@"[LegadoBridge] catalog didSelect fail-open: %@", e);
                        }
                    }
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        NSMutableArray *steps = [NSMutableArray array];
                        NSString *beginMsg = nil;
                        BOOL began = LBInvokeBeginReadOnDetail(bookCopy, srcCopy, &beginMsg);
                        [steps addObject:beginMsg ?: @"beginRead ?" ];
                        NSString *orm = nil;
                        BOOL opened = LBCallOpenReader(bookCopy, srcCopy, &orm);
                        [steps addObject:orm ?: @"openReader ?" ];
                        // openReader 常因无站点静默空转：无论是否 ok 都兜底 present/push
                        NSString *pushMsg = nil;
                        BOOL pushed = LBPushTextReaderFallback(bookCopy, srcCopy, &pushMsg);
                        [steps addObject:pushMsg ?: @"pushReader ?" ];
                        NSString *line = [NSString stringWithFormat:@"began=%d opened=%d pushed=%d | %@",
                                         began ? 1 : 0, opened ? 1 : 0, pushed ? 1 : 0,
                                         [steps componentsJoinedByString:@" || "]];
                        [line writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_catalog_openreader.txt"]
                               atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                    });
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        LBHandleContentRequest(chCopy, buCopy, nil);
                    });
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        LBFlushPendingResetContent(@"delay1.6s");
                    });
                    // 再冲一次：阅读页可能稍晚才注册通知
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        LBFlushPendingResetContent(@"delay2.5s");
                    });
                    return;
                }
            }
            if (LBOrig_catalogDidSelect) {
                @try {
                    LBOrig_catalogDidSelect(selfObj, selSel, tv, ip);
                } @catch (NSException *e) {
                    NSLog(@"[LegadoBridge] catalog didSelect fail-open: %@", e);
                }
            }
        });
        method_setImplementation(selM, hook);
    }
}

void LBInstallCatalogUIAppearFlush(void) {
    if (sCatalogUIAppearHooked) return;
    sCatalogUIAppearHooked = YES;
    LBInstallReaderContentAppearFlush();
    NSArray *names = @[@"CatalogCon", @"BookDetailController", @"BookDetailVCBase"];
    for (NSString *cn in names) {
        Class cls = NSClassFromString(cn);
        if (!cls) continue;
        SEL sel = @selector(viewDidAppear:);
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) continue;
        IMP orig = method_getImplementation(m);
        IMP hook = imp_implementationWithBlock(^void(id selfObj, BOOL animated) {
            ((void (*)(id, SEL, BOOL))orig)(selfObj, sel, animated);
            if (sPendingCatalogChapters.count == 0) return;
            NSArray *ch = [sPendingCatalogChapters copy];
            NSString *bu = [sPendingCatalogBookUrl copy];
            dispatch_async(dispatch_get_main_queue(), ^{
                LBApplyPendingCatalogToVCs(ch, bu, @"appear");
                LBScheduleCatalogReapply(ch, bu);
            });
            NSString *appear = [NSString stringWithFormat:@"catalogAppear %@ pending=%lu",
                                NSStringFromClass([selfObj class]),
                                (unsigned long)ch.count];
            [appear writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_catalog_appear.txt"]
                     atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        });
        method_setImplementation(m, hook);
    }
    Class catalogCls = NSClassFromString(@"CatalogCon");
    if (catalogCls) {
        SEL setSel = @selector(setArrCatalog:);
        Method setM = class_getInstanceMethod(catalogCls, setSel);
        if (setM && !LBOrig_setArrCatalog) {
            LBOrig_setArrCatalog = (void (*)(id, SEL, id))method_getImplementation(setM);
            method_setImplementation(setM, (IMP)LBCatalogSetArrCatalog_IMP);
        }
        SEL getSel = @selector(arrCatalog);
        Method getM = class_getInstanceMethod(catalogCls, getSel);
        if (getM && !LBOrig_getArrCatalog) {
            LBOrig_getArrCatalog = (id (*)(id, SEL))method_getImplementation(getM);
            IMP ghook = imp_implementationWithBlock(^id(id selfObj) {
                id orig = LBOrig_getArrCatalog ? LBOrig_getArrCatalog(selfObj, getSel) : nil;
                if ([orig isKindOfClass:[NSArray class]] && [(NSArray *)orig count] > 0) return orig;
                if (sPendingCatalogChapters.count > 0) return sPendingCatalogChapters;
                @try {
                    id base = [selfObj valueForKey:@"arrBaseData"];
                    if (LBArrayLooksLegado(base)) return base;
                } @catch (__unused NSException *e) {}
                return orig;
            });
            method_setImplementation(getM, ghook);
        }
        LBInstallCatalogTableHooksOnClass(catalogCls);
    }
    for (NSString *baseName in @[@"ReadVCBase1", @"BookDetailVCBase"]) {
        LBInstallCatalogTableHooksOnClass(NSClassFromString(baseName));
    }
}

void LBApplyCatalogToUI(NSArray *chapters, NSString *bookUrl) {
    if (![chapters isKindOfClass:[NSArray class]] || chapters.count == 0) return;
    if (![NSThread isMainThread]) {
        NSArray *chCopy = [chapters copy];
        NSString *buCopy = [bookUrl copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            LBApplyCatalogToUI(chCopy, buCopy);
        });
        return;
    }
    @try {
        LBInstallCatalogUIAppearFlush();
        sPendingCatalogChapters = [chapters copy];
        sPendingCatalogBookUrl = [bookUrl copy];
        NSUInteger applied = LBApplyPendingCatalogToVCs(chapters, bookUrl, @"ok");
        if (applied == 0) {
            LBCatalogWriteMarker([NSString stringWithFormat:@"uiInject pending n=%lu book=%@ (no writable CatalogVC)",
                                  (unsigned long)chapters.count, bookUrl ?: @""]);
        }
        // 保留 pending：CatalogCon 常在详情引擎返回之后才 push
        LBScheduleCatalogReapply(chapters, bookUrl);
    } @catch (NSException *e) {
        NSLog(@"[LegadoBridge] LBApplyCatalogToUI fail-open: %@", e);
        LBCatalogWriteMarker([NSString stringWithFormat:@"uiInject fail: %@", e.reason ?: @""]);
    }
}

void LBHandleCatalogRequest(NSString *bookUrl, NSString *sourceUrl) {
    Class coreClass = NSClassFromString(@"LegadoBridge.LegadoBridgeCore");
    if (!coreClass) return;
    id core = [coreClass performSelector:@selector(shared)];
    ((void (*)(id, SEL, NSString *, NSString *))objc_msgSend)(
        core, @selector(handleCatalogRequestWithBookUrl:sourceUrl:), bookUrl ?: @"", sourceUrl
    );
}

void LBHandleContentRequest(NSString *chapterUrl, NSString *bookUrl, NSString *sourceUrl) {
    Class coreClass = NSClassFromString(@"LegadoBridge.LegadoBridgeCore");
    if (!coreClass) return;
    id core = [coreClass performSelector:@selector(shared)];
    ((void (*)(id, SEL, NSString *, NSString *, NSString *))objc_msgSend)(
        core, @selector(handleContentRequestWithChapterUrl:bookUrl:sourceUrl:),
        chapterUrl ?: @"", bookUrl ?: @"", sourceUrl
    );
}
