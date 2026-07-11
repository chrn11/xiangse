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
            BOOL hasArr = NO;
            @try { hasArr = ([vc valueForKey:@"arrCatalog"] != nil) || [vc respondsToSelector:@selector(setArrCatalog:)]; } @catch (__unused NSException *e) {}
            [lines addObject:[NSString stringWithFormat:@"%@%@%@",
                              name,
                              LBVCIsVisibleInWindow(vc) ? @"*" : @"",
                              hasArr ? @"[arrCatalog]" : @""]];
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

static NSArray<UIViewController *> *LBFindCatalogVCs(void) {
    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    void (^consider)(UIViewController *) = ^(UIViewController *vc) {
        if (!vc || [seen containsObject:vc]) return;
        [seen addObject:vc];
        NSString *cn = NSStringFromClass([vc class]);
        BOOL nameHit = [cn containsString:@"Catalog"] || [cn containsString:@"BookDetail"] ||
                       [cn containsString:@"ReadVC"] || [cn containsString:@"TextRead"];
        BOOL hasArr = NO;
        @try {
            hasArr = [vc respondsToSelector:@selector(setArrCatalog:)] ||
                     (class_getInstanceVariable(object_getClass(vc), "_arrCatalog") != NULL);
            if (!hasArr) {
                id cur = [vc valueForKey:@"arrCatalog"];
                (void)cur;
                hasArr = YES; // KVC 未抛则认为可写/可读
            }
        } @catch (__unused NSException *e) {
            hasArr = NO;
        }
        if (nameHit || hasArr) {
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
    // 也扫可见 TableView 的 responder 链（对齐搜索 Find）
    for (UIWindow *w in LBAllAppWindows()) {
        NSMutableArray *views = [NSMutableArray arrayWithObject:w];
        while (views.count > 0) {
            UIView *v = views.lastObject;
            [views removeLastObject];
            if ([v isKindOfClass:[UITableView class]] && LBVCIsVisibleInWindow((id)v)) {
                UIResponder *r = v;
                while (r) {
                    if ([r isKindOfClass:[UIViewController class]]) {
                        consider((UIViewController *)r);
                        break;
                    }
                    r = r.nextResponder;
                }
            }
            for (UIView *sub in v.subviews) [views addObject:sub];
        }
    }
    return out;
}

static void LBReloadCatalogVC(UIViewController *vc) {
    @try {
        if ([vc respondsToSelector:@selector(reloadData)]) {
            ((void (*)(id, SEL))objc_msgSend)(vc, @selector(reloadData));
        }
    } @catch (__unused NSException *e) {}
    @try {
        id tv = nil;
        @try { tv = [vc valueForKey:@"tableView"]; } @catch (__unused NSException *e) {}
        if (!tv) @try { tv = [vc valueForKey:@"tv"]; } @catch (__unused NSException *e) {}
        if ([tv isKindOfClass:[UITableView class]]) {
            [(UITableView *)tv reloadData];
        }
    } @catch (__unused NSException *e) {}
    // 扫子视图 table
    @try {
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
        LBCatalogDumpVCTree();
        NSArray *vcs = LBFindCatalogVCs();
        if (vcs.count == 0) {
            LBCatalogWriteMarker([NSString stringWithFormat:@"uiInject pending n=%lu book=%@ (no CatalogVC)",
                                  (unsigned long)chapters.count, bookUrl ?: @""]);
            return;
        }
        NSMutableArray *targets = [NSMutableArray array];
        NSUInteger applied = 0;
        for (UIViewController *vc in vcs) {
            BOOL wrote = NO;
            @try {
                [vc setValue:chapters forKey:@"arrCatalog"];
                wrote = YES;
            } @catch (__unused NSException *e) {
                @try {
                    if ([vc respondsToSelector:@selector(setArrCatalog:)]) {
                        ((void (*)(id, SEL, id))objc_msgSend)(vc, @selector(setArrCatalog:), chapters);
                        wrote = YES;
                    }
                } @catch (__unused NSException *e2) {}
            }
            if (wrote) {
                applied++;
                [targets addObject:[NSString stringWithFormat:@"%@%@",
                                    NSStringFromClass([vc class]),
                                    LBVCIsVisibleInWindow(vc) ? @"*" : @""]];
                LBReloadCatalogVC(vc);
            }
        }
        LBCatalogWriteMarker([NSString stringWithFormat:@"uiInject ok vcs=%lu applied=%lu book=%@ n=%lu targets=%@",
                              (unsigned long)vcs.count, (unsigned long)applied, bookUrl ?: @"",
                              (unsigned long)chapters.count, [targets componentsJoinedByString:@","]]);
        // 原生可能稍后清空，延迟再灌
        NSArray *chCopy = [chapters copy];
        NSString *buCopy = [bookUrl copy];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            for (UIViewController *vc in LBFindCatalogVCs()) {
                @try { [vc setValue:chCopy forKey:@"arrCatalog"]; LBReloadCatalogVC(vc); } @catch (__unused NSException *e) {}
            }
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            for (UIViewController *vc in LBFindCatalogVCs()) {
                @try { [vc setValue:chCopy forKey:@"arrCatalog"]; LBReloadCatalogVC(vc); } @catch (__unused NSException *e) {}
            }
            LBCatalogWriteMarker([NSString stringWithFormat:@"uiInject reapply book=%@ n=%lu",
                                  buCopy ?: @"", (unsigned long)chCopy.count]);
        });
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
