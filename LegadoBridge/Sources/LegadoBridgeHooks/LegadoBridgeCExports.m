#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>
#import <signal.h>
#import <fcntl.h>
#import <unistd.h>
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
static NSString *sPendingCatalogSourceName = nil;
static NSString *sPendingCatalogSourceUrl = nil;
/// legado://nativeRead 等待目录返回后再点章
static NSInteger sDeferredNativeOpenIdx = -1;
static NSString *sDeferredNativeOpenBookUrl = nil;
static NSDictionary *sPendingResetContent = nil;
static BOOL sReaderContentAppearHooked = NO;
static BOOL sCatalogUIAppearHooked = NO;
static BOOL sCatalogInjectReentrant = NO;
static BOOL sNativeOpenCrashGuardsInstalled = NO;
static char sNativeOpenMarkerPath[512] = {0};
static void (*LBOrig_openReader)(id, SEL, id, id, id) = NULL;
static void (*LBOrig_tryOpenRecord)(id, SEL, id, id) = NULL;
static IMP sOrigCatalogNumberOfRows = NULL;
static IMP sOrigCatalogCellForRow = NULL;
static void (*LBOrig_setArrCatalog)(id, SEL, id) = NULL;
static id (*LBOrig_getArrCatalog)(id, SEL) = NULL;
static void (*LBOrig_catalogDidSelect)(id, SEL, UITableView *, NSIndexPath *) = NULL;
static NSTimeInterval sLastLegadoChapterOpenTs = 0;
static UIViewController *sHiddenBookDetail = nil;

static void LBFlushPendingResetContent(NSString *phase);
static const char kLBCatIdxKey;

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

static BOOL LBVCIsSearchTableContext(id selfObj);
static BOOL LBVCIsCatalogTableContext(id selfObj);

static NSArray<UIViewController *> *LBFindCatalogVCs(void) {
    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    void (^consider)(UIViewController *) = ^(UIViewController *vc) {
        if (!vc || [seen containsObject:vc]) return;
        [seen addObject:vc];
        // 搜索/书架等也有 arrBaseData，绝不能当目录灌章节（真机点书/nativeRead 回桌面根因）
        if (LBVCIsSearchTableContext(vc)) return;
        NSString *cn = NSStringFromClass([vc class]);
        BOOL nameHit = [cn containsString:@"Catalog"] || [cn containsString:@"BookDetail"] ||
                       [cn containsString:@"ReadVC"] || [cn containsString:@"TextRead"];
        // 仅名称命中或明确目录上下文；不再用「有 arrBaseData」兜底（会吃进 BookSearch）
        if (nameHit || LBVCIsCatalogTableContext(vc)) {
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

/// 目录 table hook 挂在公共基类上时，BookSearch 也会进同一 IMP。
/// 搜索结果带 legadoBridge，绝不能当成章节去 openReader（真机点书→SpringBoard 根因）。
static BOOL LBVCIsSearchTableContext(id selfObj) {
    if (!selfObj) return NO;
    NSString *cn = NSStringFromClass([selfObj class]);
    if ([cn containsString:@"BookSearch"] || [cn containsString:@"SearchController"] ||
        [cn containsString:@"SearchVC"] || [cn containsString:@"SearchView"]) {
        return YES;
    }
    return NO;
}

static BOOL LBVCIsCatalogTableContext(id selfObj) {
    if (!selfObj || LBVCIsSearchTableContext(selfObj)) return NO;
    NSString *cn = NSStringFromClass([selfObj class]);
    if ([cn containsString:@"Catalog"]) return YES;
    if ([cn containsString:@"BookDetail"]) return YES;
    if ([cn containsString:@"TextRead"] || [cn containsString:@"ReadVC"]) return YES;
    return NO;
}

/// 章节行：有 cpUrl/chapterUrl；搜索书行通常只有 bookUrl+name
static BOOL LBItemLooksLikeChapter(id item) {
    if (![item isKindOfClass:[NSDictionary class]]) return NO;
    NSDictionary *d = (NSDictionary *)item;
    for (NSString *k in @[@"cpUrl", @"chapterUrl", @"curChapterUrl"]) {
        id v = d[k];
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) return YES;
    }
    if (d[@"cpTitle"] != nil) {
        id bu = d[@"bookUrl"];
        // 纯章节 dict 常有 cpTitle；书搜索结果有 bookUrl+name 无 cpTitle
        if (![bu isKindOfClass:[NSString class]] || [(NSString *)bu length] == 0) return YES;
    }
    return NO;
}

static BOOL LBArrayLooksLikeChapters(NSArray *arr) {
    if (![arr isKindOfClass:[NSArray class]] || arr.count == 0) return NO;
    NSUInteger hit = 0;
    for (id item in arr) {
        if (LBItemLooksLikeChapter(item)) hit++;
        if (hit >= 1) return YES;
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
                UIViewController *owner = LBViewControllerOwningView(tv);
                if (LBVCIsSearchTableContext(owner) || LBVCIsSearchTableContext(tv.dataSource)) {
                    for (UIView *sub in v.subviews) [views addObject:sub];
                    continue;
                }
                if (owner && !LBVCIsCatalogTableContext(owner) &&
                    !(tv.dataSource && LBVCIsCatalogTableContext(tv.dataSource))) {
                    for (UIView *sub in v.subviews) [views addObject:sub];
                    continue;
                }
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
    // 搜索页共用基类 IMP：绝不能用章节 pending 覆盖搜索行数
    if (LBVCIsSearchTableContext(self) || !LBVCIsCatalogTableContext(self)) {
        if (sOrigCatalogNumberOfRows) {
            return ((NSInteger (*)(id, SEL, UITableView *, NSInteger))sOrigCatalogNumberOfRows)(self, _cmd, tv, section);
        }
        return 0;
    }
    // 目录上下文：章节数组优先（含 pending），避免原生脏行盖过
    for (NSString *key in @[@"arrCatalog", @"arrCpInfo", @"arrBaseData"]) {
        @try {
            id cur = [self valueForKey:key];
            if (!LBArrayLooksLikeChapters(cur)) continue;
            return (NSInteger)[cur count];
        } @catch (__unused NSException *e) {}
    }
    if (sPendingCatalogChapters.count > 0) {
        return (NSInteger)sPendingCatalogChapters.count;
    }
    if (tv && tv.dataSource && tv.dataSource != self) {
        id dsObj = (id)tv.dataSource;
        for (NSString *key in @[@"arrCatalog", @"arrCpInfo", @"arrBaseData"]) {
            @try {
                id cur = [dsObj valueForKey:key];
                if (!LBArrayLooksLikeChapters(cur)) continue;
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

/// TextReadVC viewDidAppear 会对 @[...] 中的 nil 直接 abort。
/// injectChapters=NO：openReader 瘦身（灌满章节数组曾致 callingOrig 后静默杀进程）
/// keepBridge=YES：保留 legadoBridge，便于 setDicBook/loadCurCp 走桥接短路而非原生 abort
static void LBSanitizeBookDictForReaderEx(NSMutableDictionary *dic, BOOL injectChapters, BOOL keepBridge) {
    if (![dic isKindOfClass:[NSMutableDictionary class]]) return;
    NSArray *strKeys = @[
        @"name", @"bookName", @"author", @"coverUrl", @"intro",
        @"sourceName", @"bookSourceName", @"querySourceName", @"sourceUrl", @"bookSourceUrl",
        @"chapterUrl", @"cpUrl", @"cpTitle", @"title", @"lastChapterTitle", @"chapterName",
        @"url", @"bookUrl", @"curChapterUrl", @"bookKey", @"sourceType", @"type"
    ];
    for (NSString *k in strKeys) {
        id v = dic[k];
        if (v == nil || v == [NSNull null]) {
            dic[k] = @"";
        } else if (![v isKindOfClass:[NSString class]] &&
                   ![v isKindOfClass:[NSNumber class]] &&
                   ![v isKindOfClass:[NSArray class]] &&
                   ![v isKindOfClass:[NSDictionary class]]) {
            dic[k] = [[v description] copy] ?: @"";
        }
    }
    id name = dic[@"name"];
    id bookName = dic[@"bookName"];
    if ([name isKindOfClass:[NSString class]] && [(NSString *)name length] == 0) {
        if ([bookName isKindOfClass:[NSString class]] && [(NSString *)bookName length] > 0) {
            dic[@"name"] = bookName;
        } else {
            dic[@"name"] = @"书";
        }
    }
    if ([dic[@"bookName"] isKindOfClass:[NSString class]] &&
        [(NSString *)dic[@"bookName"] length] == 0) {
        dic[@"bookName"] = dic[@"name"] ?: @"书";
    }
    NSString *nm = [dic[@"name"] isKindOfClass:[NSString class]] ? dic[@"name"] : @"";
    NSString *au = [dic[@"author"] isKindOfClass:[NSString class]] ? dic[@"author"] : @"";
    NSString *bk = [dic[@"bookKey"] isKindOfClass:[NSString class]] ? dic[@"bookKey"] : @"";
    if (bk.length == 0 && nm.length > 0) {
        dic[@"bookKey"] = au.length > 0 ? [NSString stringWithFormat:@"%@|%@", nm, au] : nm;
    }
    if (![dic[@"sourceType"] isKindOfClass:[NSString class]] ||
        [(NSString *)dic[@"sourceType"] length] == 0) {
        dic[@"sourceType"] = @"text";
    }
    // 站点数组：enable 统一字符串；站点可留 bridge 标记供识别
    for (NSString *siteKey in @[@"arrSource", @"arrSourceInfoRequired", @"arrSourceInfoOptional"]) {
        id arr = dic[siteKey];
        if (![arr isKindOfClass:[NSArray class]]) continue;
        NSMutableArray *cleanSites = [NSMutableArray arrayWithCapacity:[(NSArray *)arr count]];
        for (id s in (NSArray *)arr) {
            if (![s isKindOfClass:[NSDictionary class]]) continue;
            NSMutableDictionary *site = [NSMutableDictionary dictionaryWithDictionary:(NSDictionary *)s];
            for (NSString *k in @[@"sourceName", @"bookSourceName", @"title", @"name",
                                  @"sourceUrl", @"url", @"bookSourceUrl", @"bookUrl",
                                  @"sourceType", @"type", @"enable"]) {
                id v = site[k];
                if (v == nil || v == [NSNull null]) {
                    site[k] = @"";
                } else if ([v isKindOfClass:[NSNumber class]]) {
                    site[k] = [(NSNumber *)v stringValue] ?: @"";
                } else if (![v isKindOfClass:[NSString class]]) {
                    site[k] = [[v description] copy] ?: @"";
                }
            }
            if ([(NSString *)site[@"sourceType"] length] == 0) site[@"sourceType"] = @"text";
            if ([(NSString *)site[@"type"] length] == 0) site[@"type"] = @"text";
            if ([(NSString *)site[@"enable"] length] == 0) site[@"enable"] = @"1";
            [site removeObjectForKey:@"enabled"];
            [site removeObjectForKey:@"isEnabled"];
            if (!keepBridge) {
                [site removeObjectForKey:@"legadoBridge"];
                [site removeObjectForKey:@"fromLegadoBridge"];
            }
            [cleanSites addObject:site];
        }
        if (cleanSites.count > 0) dic[siteKey] = cleanSites;
    }
    if (![dic[@"arrSourceType"] isKindOfClass:[NSArray class]] ||
        [(NSArray *)dic[@"arrSourceType"] count] == 0) {
        dic[@"arrSourceType"] = @[@"text"];
    }
    if (injectChapters) {
        NSArray *chapterSrc = nil;
        if (sPendingCatalogChapters.count > 0) {
            chapterSrc = sPendingCatalogChapters;
        } else if ([dic[@"arrCatalog"] isKindOfClass:[NSArray class]]) {
            chapterSrc = dic[@"arrCatalog"];
        }
        if (chapterSrc.count > 0) {
            NSMutableArray *clean = [NSMutableArray arrayWithCapacity:chapterSrc.count];
            NSInteger i = 0;
            for (id item in chapterSrc) {
                if (![item isKindOfClass:[NSDictionary class]]) continue;
                NSMutableDictionary *ch = [NSMutableDictionary dictionaryWithDictionary:(NSDictionary *)item];
                for (NSString *k in @[@"cpTitle", @"title", @"name", @"chapterName",
                                      @"cpUrl", @"chapterUrl", @"url"]) {
                    id v = ch[k];
                    if (v == nil || v == [NSNull null]) ch[k] = @"";
                    else if (![v isKindOfClass:[NSString class]]) ch[k] = [[v description] copy] ?: @"";
                }
                id cpi = ch[@"cpIndex"] ?: ch[@"index"] ?: @(i);
                if ([cpi respondsToSelector:@selector(integerValue)]) {
                    ch[@"cpIndex"] = @([cpi integerValue]);
                } else {
                    ch[@"cpIndex"] = @(i);
                }
                if (!keepBridge) {
                    [ch removeObjectForKey:@"legadoBridge"];
                    [ch removeObjectForKey:@"fromLegadoBridge"];
                }
                [clean addObject:ch];
                i++;
            }
            if (clean.count > 0) {
                dic[@"arrCatalog"] = clean;
                dic[@"arrChapter"] = clean;
                dic[@"arrBaseData"] = clean;
                dic[@"arrCpInfo"] = clean;
                dic[@"chapterList"] = clean;
            }
        }
    } else {
        // openReader 瘦身：去掉章节大数组，只留当前章标量字段
        for (NSString *k in @[@"arrCatalog", @"arrChapter", @"arrBaseData", @"arrCpInfo", @"chapterList"]) {
            [dic removeObjectForKey:k];
        }
    }
    if (keepBridge) {
        dic[@"legadoBridge"] = @"1";
        dic[@"fromLegadoBridge"] = @"1";
    } else {
        [dic removeObjectForKey:@"legadoBridge"];
        [dic removeObjectForKey:@"fromLegadoBridge"];
    }
}

static void LBSanitizeBookDictForReader(NSMutableDictionary *dic) {
    // 默认：给 TextRead appear 消毒时灌章节 + 保留 bridge（阅读 hook 依赖）
    LBSanitizeBookDictForReaderEx(dic, YES, YES);
}

static void LBAppendOpenReaderTrace(NSString *msg) {
    if (msg.length == 0) return;
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_openreader_trace.txt"];
    NSString *line = [NSString stringWithFormat:@"%@ | %@\n", [NSDate date], msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return;
    }
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

static void LBWriteOpenReaderMarker(NSString *msg) {
    if (msg.length == 0) return;
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_catalog_openreader.txt"];
    [msg writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

static void LBDumpBookDictForOpenReader(NSDictionary *book, NSString *phase) {
    if (![book isKindOfClass:[NSDictionary class]]) {
        LBWriteOpenReaderMarker([NSString stringWithFormat:@"%@ dump: nil", phase ?: @"?"]);
        return;
    }
    NSMutableArray *parts = [NSMutableArray array];
    [parts addObject:[NSString stringWithFormat:@"%@ keys=%lu", phase ?: @"dump", (unsigned long)book.count]];
    for (NSString *k in @[@"name", @"author", @"bookKey", @"bookUrl", @"sourceName", @"sourceUrl",
                          @"cpTitle", @"cpUrl", @"cpIndex", @"sourceType"]) {
        id v = book[k];
        NSString *cls = v ? NSStringFromClass([v class]) : @"nil";
        NSString *s = [v isKindOfClass:[NSString class]] ? (NSString *)v
            : ([v isKindOfClass:[NSNumber class]] ? [(NSNumber *)v stringValue] : cls);
        if (s.length > 80) s = [[s substringToIndex:80] stringByAppendingString:@"…"];
        [parts addObject:[NSString stringWithFormat:@"%@=%@(%@)", k, s ?: @"", cls]];
    }
    id ac = book[@"arrCatalog"];
    id as = book[@"arrSource"];
    [parts addObject:[NSString stringWithFormat:@"arrCatalog=%lu arrSource=%lu",
                      [ac isKindOfClass:[NSArray class]] ? (unsigned long)[(NSArray *)ac count] : 0,
                      [as isKindOfClass:[NSArray class]] ? (unsigned long)[(NSArray *)as count] : 0]];
    LBWriteOpenReaderMarker([parts componentsJoinedByString:@" | "]);
}

static void LBNativeOpenSignalHandler(int sig) {
    char buf[96];
    int n = snprintf(buf, sizeof(buf), "nativeOpen SIGNAL sig=%d\n", sig);
    if (sNativeOpenMarkerPath[0] && n > 0) {
        int fd = open(sNativeOpenMarkerPath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0) {
            write(fd, buf, (size_t)n);
            close(fd);
        }
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

static void LBNativeOpenExceptionHandler(NSException *exception) {
    NSString *msg = [NSString stringWithFormat:@"nativeOpen UNCAUGHT %@ %@",
                     exception.name ?: @"?", exception.reason ?: @""];
    LBWriteOpenReaderMarker(msg);
}

static void LBInstallNativeOpenCrashGuards(void) {
    if (sNativeOpenCrashGuardsInstalled) return;
    sNativeOpenCrashGuardsInstalled = YES;
    NSString *p = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_catalog_openreader.txt"];
    snprintf(sNativeOpenMarkerPath, sizeof(sNativeOpenMarkerPath), "%s",
             p.fileSystemRepresentation ?: "");
    NSSetUncaughtExceptionHandler(&LBNativeOpenExceptionHandler);
    signal(SIGABRT, LBNativeOpenSignalHandler);
    signal(SIGSEGV, LBNativeOpenSignalHandler);
    signal(SIGBUS, LBNativeOpenSignalHandler);
    signal(SIGILL, LBNativeOpenSignalHandler);
}

static NSMutableDictionary *LBBookDictForOpenReader(NSString *bookUrl,
                                                    id chapterItem,
                                                    NSInteger idx,
                                                    NSString *chUrl,
                                                    NSString **outSourceName);
static BOOL LBCallOpenReader(NSDictionary *book, NSString *sourceName, NSString **outMsg);
static BOOL LBPushTextReaderFallback(NSDictionary *book, NSString *sourceName, NSString **outMsg);
static void LBInjectPendingContentIntoReader(UIViewController *readerVC, NSString *phase);
static BOOL LBPrepareDetailForOpenReader(NSMutableDictionary *book, NSString *sourceName, NSString **outMsg);
static void LBFlushPendingResetContent(NSString *phase);
static BOOL LBIsTextReaderVisible(void);
static UIViewController *LBFindBookDetailVC(void);
static BOOL LBPushLegadoBookDetailFromSearch(id searchVC, NSDictionary *bookDic);

/// 点章：默认原生 openReader → TextReadVC；超时仍无原生页再 Bridge 兜底
static void LBOpenLegadoChapterAtIndex(NSInteger idx) {
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now - sLastLegadoChapterOpenTs < 2.5) return;
    sLastLegadoChapterOpenTs = now;
    NSArray *use = sPendingCatalogChapters;
    if (use.count == 0) return;
    if (idx < 0 || idx >= (NSInteger)use.count) return;
    id item = use[(NSUInteger)idx];
    NSString *chUrl = nil;
    NSString *chTitle = nil;
    if ([item isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = (NSDictionary *)item;
        chUrl = d[@"cpUrl"] ?: d[@"chapterUrl"] ?: d[@"url"];
        chTitle = d[@"cpTitle"] ?: d[@"title"] ?: d[@"name"] ?: d[@"chapterName"];
    }
    NSString *bookUrl = sPendingCatalogBookUrl;
    if (bookUrl.length == 0 || chUrl.length == 0) return;
    NSString *titleCopy = chTitle.length > 0 ? [chTitle copy] : @"章节";
    NSString *chCopy = [chUrl copy];
    NSString *buCopy = [bookUrl copy];
    id itemCopy = item;
    NSInteger idxCopy = idx;
    NSString *msg = [NSString stringWithFormat:@"didSelect ch=%@ book=%@ idx=%ld title=%@",
                     chUrl, bookUrl, (long)idx, titleCopy];
    [msg writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_catalog_select.txt"]
           atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    void (^go)(void) = ^{
        LBInstallNativeOpenCrashGuards();
        LBWriteOpenReaderMarker([NSString stringWithFormat:@"nativeOpen phase=goStart ch=%@", chCopy]);
        // 对齐已导入书源：本地静态测试源 / http://192.168.1.4:8765（勿用 404 的 source.json、勿用「本地 mock」）
        NSString *sourceName = sPendingCatalogSourceName.length > 0
            ? sPendingCatalogSourceName : @"本地静态测试源";
        NSString *sourceUrl = sPendingCatalogSourceUrl.length > 0
            ? sPendingCatalogSourceUrl : @"http://192.168.1.4:8765";
        NSString *bookName = @"斗破苍穹";
        NSString *author = @"天蚕土豆";
        for (UIViewController *vc in LBFindCatalogVCs()) {
            NSString *cn = NSStringFromClass([vc class]);
            if (![cn containsString:@"LBLegadoCatalogListVC"]) continue;
            @try {
                id su = [vc valueForKey:@"sourceUrl"];
                if ([su isKindOfClass:[NSString class]] && [(NSString *)su length] > 0) {
                    sourceUrl = su;
                }
                id bt = [vc valueForKey:@"bookTitle"];
                if ([bt isKindOfClass:[NSString class]] && [(NSString *)bt length] > 0) {
                    bookName = bt;
                }
            } @catch (__unused NSException *e) {}
            break;
        }
        NSMutableDictionary *book = [NSMutableDictionary dictionary];
        book[@"name"] = bookName;
        book[@"bookName"] = bookName;
        book[@"author"] = author;
        book[@"bookKey"] = [NSString stringWithFormat:@"%@|%@", bookName, author];
        book[@"coverUrl"] = @"";
        book[@"intro"] = @"这里是斗气的世界，没有花俏的魔法，有的，只是繁衍到巅峰的斗气！";
        book[@"bookUrl"] = buCopy ?: @"";
        book[@"url"] = buCopy ?: @"";
        book[@"chapterUrl"] = chCopy ?: @"";
        book[@"cpUrl"] = chCopy ?: @"";
        book[@"curChapterUrl"] = chCopy ?: @"";
        book[@"cpIndex"] = @(idxCopy);
        book[@"chapterIndex"] = @(idxCopy);
        book[@"sourceName"] = sourceName;
        book[@"bookSourceName"] = sourceName;
        book[@"querySourceName"] = sourceName;
        book[@"sourceUrl"] = sourceUrl;
        book[@"bookSourceUrl"] = sourceUrl;
        book[@"sourceType"] = @"text";
        book[@"type"] = @"text";
        book[@"lastChapterTitle"] = titleCopy ?: @"";
        if ([itemCopy isKindOfClass:[NSDictionary class]]) {
            NSDictionary *ch = (NSDictionary *)itemCopy;
            id cpTitle = ch[@"cpTitle"] ?: ch[@"title"] ?: ch[@"name"] ?: ch[@"chapterName"];
            if (cpTitle) {
                book[@"cpTitle"] = cpTitle;
                book[@"chapterName"] = cpTitle;
                book[@"title"] = cpTitle;
            }
        } else if (titleCopy.length > 0) {
            book[@"cpTitle"] = titleCopy;
            book[@"chapterName"] = titleCopy;
            book[@"title"] = titleCopy;
        }
        NSMutableDictionary *site = [NSMutableDictionary dictionary];
        site[@"sourceName"] = sourceName;
        site[@"bookSourceName"] = sourceName;
        site[@"title"] = sourceName;
        site[@"name"] = sourceName;
        site[@"sourceUrl"] = sourceUrl;
        site[@"url"] = sourceUrl;
        site[@"bookSourceUrl"] = sourceUrl;
        site[@"sourceType"] = @"text";
        site[@"type"] = @"text";
        site[@"enable"] = @"1";
        site[@"bookUrl"] = buCopy ?: @"";
        book[@"arrSource"] = @[site];
        book[@"arrSourceInfoRequired"] = @[site];
        book[@"arrSourceInfoOptional"] = @[site];
        book[@"arrSourceType"] = @[@"text"];
        @try {
            LBSanitizeBookDictForReaderEx(book, NO, YES);
        } @catch (NSException *e) {
            LBWriteOpenReaderMarker([NSString stringWithFormat:@"nativeOpen fail sanitize: %@", e.reason ?: @""]);
            return;
        }
        LBDumpBookDictForOpenReader(book, @"nativeOpen phase=bookDictOK");
        LBAppendOpenReaderTrace(@"goStart leanDict ready");
        LBInstallReaderContentAppearFlush();
        LBHandleContentRequest(chCopy, buCopy, nil);
        LBWriteOpenReaderMarker(@"nativeOpen beforeCall preferPush=1");
        NSString *orm = nil;
        BOOL opened = NO;
        @try {
            // openReader / appear 链式钩均会杀进程；只走 push TextRead* + delay flush
            LBWriteOpenReaderMarker(@"nativeOpen callingPush");
            opened = LBPushTextReaderFallback(book, sourceName, &orm);
            LBWriteOpenReaderMarker([NSString stringWithFormat:@"nativeOpen origReturned opened=%d | %@",
                                     opened ? 1 : 0, orm ?: @"?"]);
        } @catch (NSException *e) {
            orm = [NSString stringWithFormat:@"openReader exception: %@", e.reason ?: @""];
            opened = NO;
            LBWriteOpenReaderMarker([NSString stringWithFormat:@"nativeOpen catch %@", orm]);
        }
        NSString *line = [NSString stringWithFormat:
                          @"nativeOpen opened=%d readerVis=%d | %@ || via=alignedDict preferNative=1",
                          opened ? 1 : 0, LBIsTextReaderVisible() ? 1 : 0, orm ?: @"?"];
        LBWriteOpenReaderMarker(line);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!LBIsTextReaderVisible()) return;
            // 禁止 ResetContent；对前台 TextRead* 直接灌 UITextView
            for (UIWindow *w in LBAllAppWindows()) {
                UIViewController *root = w.rootViewController;
                if (!root) continue;
                NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
                while (stack.count > 0) {
                    UIViewController *vc = stack.lastObject;
                    [stack removeLastObject];
                    NSString *cn = NSStringFromClass([vc class]);
                    if ([cn containsString:@"TextReadVC"] || [cn containsString:@"ReadVCBase"]) {
                        if (LBVCIsVisibleInWindow(vc)) {
                            LBInjectPendingContentIntoReader(vc, @"go0.9");
                        }
                    }
                    for (UIViewController *c in vc.childViewControllers) [stack addObject:c];
                    if (vc.presentedViewController) [stack addObject:vc.presentedViewController];
                    if ([vc isKindOfClass:[UINavigationController class]]) {
                        for (UIViewController *c in [(UINavigationController *)vc viewControllers]) {
                            [stack addObject:c];
                        }
                    }
                }
            }
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (LBIsTextReaderVisible()) {
                LBWriteOpenReaderMarker([NSString stringWithFormat:
                                        @"nativeOpen keepTextRead readerVis=1 ch=%@", chCopy]);
                return;
            }
            NSString *brMsg = nil;
            BOOL presented = LBPresentBridgeReader(titleCopy, chCopy, buCopy, &brMsg);
            LBWriteOpenReaderMarker([NSString stringWithFormat:
                                    @"bridgeFallback presented=%d | %@ || nativeMiss ch=%@",
                                    presented ? 1 : 0, brMsg ?: @"?", chCopy]);
            if (sPendingResetContent.count > 0) {
                LBBridgeReaderApplyContent(sPendingResetContent);
            }
        });
    };
    if ([NSThread isMainThread]) go();
    else dispatch_async(dispatch_get_main_queue(), go);
}

@interface LBCatalogCellOpenProxy : NSObject
@end
@implementation LBCatalogCellOpenProxy
- (void)openChapter:(UIButton *)sender {
    NSNumber *idxNum = objc_getAssociatedObject(sender, &kLBCatIdxKey);
    if (![idxNum isKindOfClass:[NSNumber class]]) return;
    LBOpenLegadoChapterAtIndex(idxNum.integerValue);
}
@end
static LBCatalogCellOpenProxy *LBCatalogCellProxy(void) {
    static LBCatalogCellOpenProxy *p;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ p = [[LBCatalogCellOpenProxy alloc] init]; });
    return p;
}

static UITableViewCell *LBHookedCatalogCellForRow(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    // 搜索页：必须走原生 cell，禁止铺 openChapter 透明按钮（点搜索结果否则直接 openReader 崩桌面）
    if (LBVCIsSearchTableContext(self) || !LBVCIsCatalogTableContext(self)) {
        if (sOrigCatalogCellForRow) {
            return ((UITableViewCell * (*)(id, SEL, UITableView *, NSIndexPath *))sOrigCatalogCellForRow)(self, _cmd, tv, ip);
        }
        return nil;
    }
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
    // pending 优先：原生 arrCatalog 常为空，列表靠 arrBaseData / pending（仅章节）
    NSArray *use = sPendingCatalogChapters.count > 0 ? sPendingCatalogChapters : nil;
    if (!use) {
        if (LBArrayLooksLikeChapters(cat)) use = cat;
        else if (LBArrayLooksLikeChapters(base)) use = base;
    }
    BOOL legadoFallback = (use.count > 0);
    if (!legadoFallback && sOrigCatalogCellForRow) {
        return ((UITableViewCell * (*)(id, SEL, UITableView *, NSIndexPath *))sOrigCatalogCellForRow)(self, _cmd, tv, ip);
    }
    if (legadoFallback && ip.row >= 0 && ip.row < (NSInteger)use.count) {
        id item = use[(NSUInteger)ip.row];
        NSString *title = LBChapterTitleFromItem(item) ?: [NSString stringWithFormat:@"章节 %ld", (long)ip.row + 1];
        UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"legado.catalog.cp"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                         reuseIdentifier:@"legado.catalog.cp"];
        }
        cell.textLabel.text = title;
        cell.textLabel.textColor = [UIColor labelColor];
        cell.backgroundColor = [UIColor clearColor];
        // 禁选：点章走透明按钮 → 原生 openReader（失败再 Bridge）
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        // 无障碍/坐标点常碰不到原生 didSelect：透明按钮铺满 cell
        const NSInteger kBtnTag = 0x4C424354; // LBCT
        UIButton *btn = [cell.contentView viewWithTag:kBtnTag];
        if (![btn isKindOfClass:[UIButton class]]) {
            btn = [UIButton buttonWithType:UIButtonTypeCustom];
            btn.tag = kBtnTag;
            btn.backgroundColor = [UIColor clearColor];
            [btn addTarget:LBCatalogCellProxy()
                    action:@selector(openChapter:)
          forControlEvents:UIControlEventTouchUpInside];
            [cell.contentView addSubview:btn];
        }
        btn.frame = cell.contentView.bounds;
        btn.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        btn.accessibilityLabel = title;
        btn.accessibilityIdentifier = @"legado_catalog_chapter_btn";
        objc_setAssociatedObject(btn, &kLBCatIdxKey, @(ip.row), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
    // 保留书名，勿被章节 title/name 覆盖（TextReadVC 用 name 组数组）
    NSString *preservedBookName = nil;
    id bn0 = book[@"name"] ?: book[@"bookName"];
    if ([bn0 isKindOfClass:[NSString class]] && [(NSString *)bn0 length] > 0) {
        preservedBookName = bn0;
    }
    if ([chapterItem isKindOfClass:[NSDictionary class]]) {
        NSDictionary *ch = (NSDictionary *)chapterItem;
        id cpTitle = ch[@"cpTitle"] ?: ch[@"title"] ?: ch[@"name"] ?: ch[@"chapterName"];
        if (cpTitle) {
            book[@"cpTitle"] = cpTitle;
            book[@"chapterName"] = cpTitle;
        }
        id cpi = ch[@"cpIndex"] ?: ch[@"index"];
        if (cpi) book[@"cpIndex"] = cpi;
        if (!sourceName) {
            id sn = ch[@"sourceName"];
            if ([sn isKindOfClass:[NSString class]]) sourceName = sn;
        }
    }
    if (preservedBookName.length > 0) {
        book[@"name"] = preservedBookName;
        book[@"bookName"] = preservedBookName;
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
        site[@"type"] = @"text";
        site[@"enable"] = @"1";
        site[@"enabled"] = @YES;
        site[@"isEnabled"] = @YES;
        site[@"legadoBridge"] = @"1";
        site[@"bookUrl"] = bookUrl ?: @"";
        book[@"arrSource"] = @[site];
        book[@"arrSourceInfoRequired"] = @[site];
        book[@"arrSourceInfoOptional"] = @[site];
        book[@"arrSourceType"] = @[@"text"];
    }
    LBSanitizeBookDictForReader(book);
    if (outSourceName) *outSourceName = sourceName ?: @"";
    return book;
}

static UIViewController *LBFindBookDetailVC(void) {
    for (UIViewController *vc in LBFindCatalogVCs()) {
        NSString *cn = NSStringFromClass([vc class]);
        if ([cn containsString:@"BookDetail"]) return vc;
    }
    for (UIWindow *w in LBAllAppWindows()) {
        UIViewController *root = w.rootViewController;
        if (!root) continue;
        NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
        while (stack.count > 0) {
            UIViewController *vc = stack.lastObject;
            [stack removeLastObject];
            NSString *cn = NSStringFromClass([vc class]);
            if ([cn containsString:@"BookDetail"]) return vc;
            for (UIViewController *c in vc.childViewControllers) [stack addObject:c];
            if (vc.presentedViewController) [stack addObject:vc.presentedViewController];
            if ([vc isKindOfClass:[UINavigationController class]]) {
                for (UIViewController *c in [(UINavigationController *)vc viewControllers]) {
                    [stack addObject:c];
                }
            }
        }
    }
    if (sHiddenBookDetail) return sHiddenBookDetail;
    return nil;
}

/// 向上/全窗找可用 UINavigationController
static UINavigationController *LBFindBestNavigationController(UIViewController *from) {
    if ([from isKindOfClass:[UINavigationController class]]) {
        return (UINavigationController *)from;
    }
    UINavigationController *nav = from.navigationController;
    if (nav) return nav;
    UIViewController *p = from.parentViewController;
    while (p) {
        if ([p isKindOfClass:[UINavigationController class]]) return (UINavigationController *)p;
        if (p.navigationController) return p.navigationController;
        p = p.parentViewController;
    }
    for (UIWindow *w in LBAllAppWindows()) {
        UIViewController *root = w.rootViewController;
        if (!root) continue;
        NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
        while (stack.count > 0) {
            UIViewController *vc = stack.lastObject;
            [stack removeLastObject];
            if ([vc isKindOfClass:[UINavigationController class]] && LBVCIsVisibleInWindow(vc)) {
                return (UINavigationController *)vc;
            }
            if ([vc isKindOfClass:[UITabBarController class]]) {
                UIViewController *sel = [(UITabBarController *)vc selectedViewController];
                if (sel) [stack addObject:sel];
            }
            if (vc.presentedViewController) [stack addObject:vc.presentedViewController];
            for (UIViewController *c in vc.childViewControllers) [stack addObject:c];
            if ([vc isKindOfClass:[UINavigationController class]]) {
                for (UIViewController *c in [(UINavigationController *)vc viewControllers]) {
                    [stack addObject:c];
                }
            }
        }
    }
    return nil;
}

/// 自建目录页：避开原生 BookDetail（真机 push/setDicBook 无 ips 回桌面）
@interface LBLegadoCatalogListVC : UITableViewController
@property (nonatomic, copy) NSString *bookUrl;
@property (nonatomic, copy) NSString *sourceUrl;
@property (nonatomic, copy) NSString *bookTitle;
@property (nonatomic, copy) NSArray *chapters;
- (void)lb_reloadFromPending;
@end
@implementation LBLegadoCatalogListVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.bookTitle.length ? self.bookTitle : @"目录";
    self.tableView.rowHeight = 48;
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"c"];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self lb_reloadFromPending];
}
- (void)lb_reloadFromPending {
    if (sPendingCatalogChapters.count > 0 &&
        (self.bookUrl.length == 0 || sPendingCatalogBookUrl.length == 0 ||
         [sPendingCatalogBookUrl isEqualToString:self.bookUrl])) {
        self.chapters = sPendingCatalogChapters;
    }
    [self.tableView reloadData];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.chapters.count;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"c" forIndexPath:ip];
    NSString *t = @"章节";
    if (ip.row >= 0 && ip.row < (NSInteger)self.chapters.count) {
        t = LBChapterTitleFromItem(self.chapters[(NSUInteger)ip.row]) ?: @"章节";
    }
    cell.textLabel.text = t;
    cell.textLabel.numberOfLines = 2;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.userInteractionEnabled = YES;
    cell.contentView.userInteractionEnabled = YES;
    // 覆盖透明按钮：须 Auto Layout，cellForRow 时 bounds 常为 0 导致 MCP 点不到
    for (UIView *v in cell.contentView.subviews) {
        if (v.tag == 91001) [v removeFromSuperview];
    }
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.tag = 91001;
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    btn.accessibilityLabel = t;
    btn.backgroundColor = [UIColor clearColor];
    objc_setAssociatedObject(btn, &kLBCatIdxKey, @(ip.row), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [btn addTarget:LBCatalogCellProxy() action:@selector(openChapter:)
      forControlEvents:UIControlEventTouchUpInside];
    [cell.contentView addSubview:btn];
    [NSLayoutConstraint activateConstraints:@[
        [btn.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor],
        [btn.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor],
        [btn.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor],
        [btn.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor],
    ]];
    [cell.contentView bringSubviewToFront:btn];
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    [[NSString stringWithFormat:@"didSelect ch=%@ idx=%ld via=LBLegadoCatalogListVC",
      LBChapterTitleFromItem((ip.row < (NSInteger)self.chapters.count)
                                 ? self.chapters[(NSUInteger)ip.row] : nil) ?: @"?",
      (long)ip.row]
        writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_catalog_select.txt"]
        atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    if (self.chapters.count == 0) return;
    if (sPendingCatalogChapters.count == 0) sPendingCatalogChapters = [self.chapters copy];
    if (self.bookUrl.length > 0) sPendingCatalogBookUrl = [self.bookUrl copy];
    LBOpenLegadoChapterAtIndex(ip.row);
}
@end

static void LBReloadLegadoCatalogListIfVisible(void) {
    UIApplication *app = [UIApplication sharedApplication];
    UIWindow *win = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *sc in app.connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                if (w.isKeyWindow) { win = w; break; }
            }
            if (win) break;
        }
    }
    if (!win) win = app.keyWindow;
    UIViewController *root = win.rootViewController;
    NSMutableArray *stack = [NSMutableArray array];
    if (root) [stack addObject:root];
    while (stack.count) {
        UIViewController *vc = stack.lastObject;
        [stack removeLastObject];
        if ([vc isKindOfClass:[LBLegadoCatalogListVC class]]) {
            [(LBLegadoCatalogListVC *)vc lb_reloadFromPending];
        }
        if (vc.presentedViewController) [stack addObject:vc.presentedViewController];
        if ([vc isKindOfClass:[UINavigationController class]]) {
            for (UIViewController *c in ((UINavigationController *)vc).viewControllers) [stack addObject:c];
        }
        if ([vc isKindOfClass:[UITabBarController class]]) {
            for (UIViewController *c in ((UITabBarController *)vc).viewControllers ?: @[]) [stack addObject:c];
        }
        for (UIViewController *c in vc.childViewControllers) [stack addObject:c];
    }
}

/// 搜索点书：推自建目录页（不碰原生 BookDetail）
static BOOL LBPushLegadoBookDetailFromSearch(id searchVC, NSDictionary *bookDic) {
    void (^mark)(NSString *) = ^(NSString *s) {
        [s writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_select.txt"]
             atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    };
    mark(@"searchPush enter");
    if (![searchVC isKindOfClass:[UIViewController class]] ||
        ![bookDic isKindOfClass:[NSDictionary class]]) {
        mark(@"searchPush fail: bad args");
        return NO;
    }
    @try {
        [[(UIViewController *)searchVC view] endEditing:YES];
    } @catch (__unused NSException *e) {}

    NSMutableDictionary *safe = [NSMutableDictionary dictionaryWithDictionary:bookDic];
    safe[@"legadoBridge"] = @"1";
    safe[@"fromLegadoBridge"] = @YES;
    NSArray *pendingSave = sPendingCatalogChapters;
    NSString *pendingBu = sPendingCatalogBookUrl;
    sPendingCatalogChapters = nil;
    LBSanitizeBookDictForReader(safe);
    sPendingCatalogChapters = pendingSave;
    sPendingCatalogBookUrl = pendingBu;

    NSString *bu = nil;
    for (NSString *k in @[@"bookUrl", @"url"]) {
        id v = safe[k];
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) { bu = v; break; }
    }
    NSString *su = nil;
    for (NSString *k in @[@"sourceUrl", @"bookSourceUrl"]) {
        id v = safe[k];
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) { su = v; break; }
    }
    NSString *title = nil;
    for (NSString *k in @[@"name", @"bookName", @"title"]) {
        id v = safe[k];
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) { title = v; break; }
    }
    if (bu.length == 0) {
        mark(@"searchPush fail: no bookUrl");
        return NO;
    }
    sPendingCatalogBookUrl = [bu copy];
    if (su.length > 0) sPendingCatalogSourceUrl = [su copy];
    else if (sPendingCatalogSourceUrl.length == 0) {
        sPendingCatalogSourceUrl = @"http://192.168.1.4:8765";
    }
    id sn0 = safe[@"sourceName"] ?: safe[@"bookSourceName"] ?: safe[@"querySourceName"];
    if ([sn0 isKindOfClass:[NSString class]] && [(NSString *)sn0 length] > 0) {
        sPendingCatalogSourceName = [(NSString *)sn0 copy];
    } else if (sPendingCatalogSourceName.length == 0) {
        sPendingCatalogSourceName = @"本地静态测试源";
    }
    if (su.length == 0) su = sPendingCatalogSourceUrl;

    LBLegadoCatalogListVC *list = [[LBLegadoCatalogListVC alloc] initWithStyle:UITableViewStylePlain];
    list.bookUrl = bu;
    list.sourceUrl = su;
    list.bookTitle = title ?: @"目录";
    if (sPendingCatalogChapters.count > 0 &&
        (sPendingCatalogBookUrl.length == 0 || [sPendingCatalogBookUrl isEqualToString:bu])) {
        list.chapters = sPendingCatalogChapters;
    }

    UINavigationController *nav = [(UIViewController *)searchVC navigationController];
    if (!nav) {
        nav = LBFindBestNavigationController((UIViewController *)searchVC);
    }
    BOOL presentedWrap = NO;
    @try {
        if (nav && [nav.viewControllers containsObject:(UIViewController *)searchVC]) {
            [nav pushViewController:list animated:NO];
        } else if (nav) {
            // 搜索页不在该 nav 栈内时，勿推到隐藏栈；改 present
            UINavigationController *wrap =
                [[UINavigationController alloc] initWithRootViewController:list];
            UIViewController *host = (UIViewController *)searchVC;
            while (host.presentedViewController) host = host.presentedViewController;
            [host presentViewController:wrap animated:NO completion:nil];
            presentedWrap = YES;
            nav = wrap;
        } else {
            UINavigationController *wrap =
                [[UINavigationController alloc] initWithRootViewController:list];
            UIViewController *host = (UIViewController *)searchVC;
            while (host.presentedViewController) host = host.presentedViewController;
            [host presentViewController:wrap animated:NO completion:nil];
            presentedWrap = YES;
            nav = wrap;
        }
    } @catch (NSException *e) {
        mark([NSString stringWithFormat:@"searchPush fail: push %@", e.reason ?: @""]);
        return NO;
    }

    LBHandleCatalogRequest(bu, su);
    mark([NSString stringWithFormat:
          @"searchPushDetail book=%@ src=%@ on=LBLegadoCatalogListVC wrap=%d nav=%@ phase=catalogList",
          bu, su ?: @"", presentedWrap ? 1 : 0,
          nav ? NSStringFromClass([nav class]) : @"nil"]);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        LBReloadLegadoCatalogListIfVisible();
        NSString *alive = [NSString stringWithFormat:
                           @"searchPush alive book=%@ ch=%lu",
                           bu, (unsigned long)sPendingCatalogChapters.count];
        [alive writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_select.txt"]
                atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    });
    return YES;
}

static BOOL LBBookLooksLegadoForKillSwitch(id bookOrRecord, NSString **outBookUrl, NSString **outChUrl, NSString **outTitle);
static void LBKillSwitchPresentBridge(NSString *phase, NSString *bookUrl, NSString *chUrl, NSString *title);

/// 写回详情书/站点：用隐藏 BookDetail 实例（绝不插入导航栈——插入真机会无 ips 杀进程）
static BOOL LBPrepareDetailForOpenReader(NSMutableDictionary *book, NSString *sourceName, NSString **outMsg) {
    LBSanitizeBookDictForReader(book);
    UIViewController *detail = LBFindBookDetailVC();
    if (!detail) {
        if (!sHiddenBookDetail) {
            Class cls = NSClassFromString(@"BookDetailController");
            if (!cls) cls = NSClassFromString(@"BookDetailVCBase");
            if (!cls) {
                if (outMsg) *outMsg = @"prep miss: no BookDetail class";
                return NO;
            }
            @try {
                sHiddenBookDetail = [[cls alloc] init];
            } @catch (NSException *e) {
                if (outMsg) *outMsg = [NSString stringWithFormat:@"prep alloc fail: %@", e.reason ?: @""];
                return NO;
            }
        }
        detail = sHiddenBookDetail;
        if (!detail) {
            if (outMsg) *outMsg = @"prep miss: detail nil";
            return NO;
        }
    }
    @try {
        [detail setValue:book forKey:@"dicBook"];
    } @catch (__unused NSException *e) {}
    id arrSource = book[@"arrSource"];
    if ([arrSource isKindOfClass:[NSArray class]]) {
        @try { [detail setValue:arrSource forKey:@"arrSource"]; } @catch (__unused NSException *e) {}
    }
    if (sourceName.length > 0) {
        @try { [detail setValue:sourceName forKey:@"sourceName"]; } @catch (__unused NSException *e) {}
    }
    if (outMsg) {
        *outMsg = [NSString stringWithFormat:@"prep ok on %@ hidden=%d",
                   NSStringFromClass([detail class]),
                   (detail == sHiddenBookDetail) ? 1 : 0];
    }
    return YES;
}

/// 详情「开始阅读」：消毒后回原生（点章主路径仍优先 openReader）
static BOOL __attribute__((unused)) LBInvokeBeginReadOnDetail(NSMutableDictionary *book, NSString *sourceName, NSString **outMsg) {
    LBPrepareDetailForOpenReader(book, sourceName, NULL);
    UIViewController *detail = LBFindBookDetailVC();
    if (!detail) {
        if (outMsg) *outMsg = @"beginRead miss: no BookDetail";
        return NO;
    }
    SEL beginSel = NSSelectorFromString(@"onBeginReadEvent:");
    if (![detail respondsToSelector:beginSel]) {
        beginSel = NSSelectorFromString(@"onBeginEvent:");
    }
    if (![detail respondsToSelector:beginSel]) {
        if (outMsg) *outMsg = @"beginRead miss: no selector";
        return NO;
    }
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(detail, beginSel, nil);
        if (outMsg) {
            *outMsg = [NSString stringWithFormat:@"beginRead ok on %@", NSStringFromClass([detail class])];
        }
        return YES;
    } @catch (NSException *e) {
        if (outMsg) *outMsg = [NSString stringWithFormat:@"beginRead fail: %@", e.reason ?: @""];
        return NO;
    }
}

static BOOL LBIsTextReaderVisible(void) {
    for (UIWindow *w in LBAllAppWindows()) {
        UIViewController *root = w.rootViewController;
        if (!root) continue;
        NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
        while (stack.count > 0) {
            UIViewController *vc = stack.lastObject;
            [stack removeLastObject];
            NSString *cn = NSStringFromClass([vc class]);
            if ([cn containsString:@"TextReadVC"] || [cn containsString:@"ReadVCBase"]) {
                if (LBVCIsVisibleInWindow(vc)) return YES;
            }
            for (UIViewController *c in vc.childViewControllers) [stack addObject:c];
            if (vc.presentedViewController) [stack addObject:vc.presentedViewController];
            if ([vc isKindOfClass:[UINavigationController class]]) {
                for (UIViewController *c in [(UINavigationController *)vc viewControllers]) {
                    [stack addObject:c];
                }
            }
            if ([vc isKindOfClass:[UITabBarController class]]) {
                for (UIViewController *c in [(UITabBarController *)vc viewControllers]) {
                    [stack addObject:c];
                }
            }
        }
    }
    return NO;
}

/// 调用 AppDelegate.openReader:sourceName:record:（经护栏消毒后进原生）
static BOOL LBTryAddBookToShelf(NSDictionary *book) {
    if (![book isKindOfClass:[NSDictionary class]]) return NO;
    SEL addSel = NSSelectorFromString(@"addBook:groupKey:tempBook:");
    NSMutableArray *targets = [NSMutableArray array];
    id appDel = [UIApplication sharedApplication].delegate;
    if (appDel) [targets addObject:appDel];
    for (NSString *cn in @[@"BookShelfManager", @"BookShelfController",
                           @"LCRecordGroupManagerV3", @"AppDelegate"]) {
        Class cls = NSClassFromString(cn);
        if (!cls) continue;
        id shared = nil;
        @try {
            if ([cls respondsToSelector:@selector(shared)]) {
                shared = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(shared));
            } else if ([cls respondsToSelector:@selector(sharedInstance)]) {
                shared = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(sharedInstance));
            }
        } @catch (__unused NSException *e) {}
        if (shared && ![targets containsObject:shared]) [targets addObject:shared];
        if (![targets containsObject:cls]) [targets addObject:cls];
    }
    for (id t in targets) {
        if (![t respondsToSelector:addSel]) continue;
        @try {
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(t, addSel, book, @"", book);
            LBWriteOpenReaderMarker([NSString stringWithFormat:@"nativeOpen addBook ok on %@",
                                     NSStringFromClass([t class])]);
            LBAppendOpenReaderTrace([NSString stringWithFormat:@"addBook ok %@",
                                     NSStringFromClass([t class])]);
            return YES;
        } @catch (NSException *e) {
            LBWriteOpenReaderMarker([NSString stringWithFormat:@"nativeOpen addBook fail %@ %@",
                                     NSStringFromClass([t class]), e.reason ?: @""]);
            LBAppendOpenReaderTrace([NSString stringWithFormat:@"addBook fail %@ %@",
                                     NSStringFromClass([t class]), e.reason ?: @""]);
        }
    }
    LBWriteOpenReaderMarker(@"nativeOpen addBook miss");
    LBAppendOpenReaderTrace(@"addBook miss");
    return NO;
}

static id LBGetFullBookFromShelf(NSDictionary *book, NSString *sourceName) {
    SEL getSel = NSSelectorFromString(@"getFullBook:sourceName:");
    NSString *key = nil;
    id bk = book[@"bookKey"];
    if ([bk isKindOfClass:[NSString class]] && [(NSString *)bk length] > 0) key = bk;
    if (key.length == 0) {
        NSString *nm = [book[@"name"] isKindOfClass:[NSString class]] ? book[@"name"] : @"";
        NSString *au = [book[@"author"] isKindOfClass:[NSString class]] ? book[@"author"] : @"";
        if (nm.length > 0) key = au.length > 0 ? [NSString stringWithFormat:@"%@|%@", nm, au] : nm;
    }
    if (key.length == 0) key = [book[@"bookUrl"] isKindOfClass:[NSString class]] ? book[@"bookUrl"] : @"";
    NSMutableArray *targets = [NSMutableArray array];
    id appDel = [UIApplication sharedApplication].delegate;
    if (appDel) [targets addObject:appDel];
    for (NSString *cn in @[@"BookShelfManager", @"LCRecordGroupManagerV3", @"AppDelegate"]) {
        Class cls = NSClassFromString(cn);
        if (!cls) continue;
        id shared = nil;
        @try {
            if ([cls respondsToSelector:@selector(shared)]) {
                shared = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(shared));
            } else if ([cls respondsToSelector:@selector(sharedInstance)]) {
                shared = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(sharedInstance));
            }
        } @catch (__unused NSException *e) {}
        if (shared) [targets addObject:shared];
        [targets addObject:cls];
    }
    for (id t in targets) {
        if (![t respondsToSelector:getSel]) continue;
        @try {
            id full = ((id (*)(id, SEL, id, id))objc_msgSend)(t, getSel, key ?: book, sourceName ?: @"");
            if (full) {
                LBAppendOpenReaderTrace([NSString stringWithFormat:@"getFullBook ok %@ cls=%@",
                                         NSStringFromClass([t class]),
                                         NSStringFromClass([full class])]);
                return full;
            }
        } @catch (NSException *e) {
            LBAppendOpenReaderTrace([NSString stringWithFormat:@"getFullBook ex %@ %@",
                                     NSStringFromClass([t class]), e.reason ?: @""]);
        }
    }
    LBAppendOpenReaderTrace(@"getFullBook miss");
    return nil;
}

static BOOL LBCallOpenReader(NSDictionary *book, NSString *sourceName, NSString **outMsg) {
    SEL openSel = NSSelectorFromString(@"openReader:sourceName:record:");
    NSMutableDictionary *mutableBook = nil;
    if ([book isKindOfClass:[NSMutableDictionary class]]) {
        mutableBook = (NSMutableDictionary *)book;
    } else if ([book isKindOfClass:[NSDictionary class]]) {
        mutableBook = [NSMutableDictionary dictionaryWithDictionary:book];
    } else {
        mutableBook = [NSMutableDictionary dictionary];
    }
    // lean：不灌章节大数组；keepBridge：阅读 hook 可识别
    LBSanitizeBookDictForReaderEx(mutableBook, NO, YES);
    LBReadingRememberBook(mutableBook);
    LBTryAddBookToShelf(mutableBook);
    id fullBook = LBGetFullBookFromShelf(mutableBook, sourceName);
    id openBook = mutableBook;
    if ([fullBook isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *merged = [NSMutableDictionary dictionaryWithDictionary:(NSDictionary *)fullBook];
        for (NSString *k in @[@"cpUrl", @"chapterUrl", @"curChapterUrl", @"cpTitle", @"chapterName",
                              @"title", @"cpIndex", @"chapterIndex", @"sourceName", @"sourceUrl",
                              @"bookUrl", @"url", @"bookKey", @"name", @"author"]) {
            id v = mutableBook[k];
            if (v != nil && v != [NSNull null]) merged[k] = v;
        }
        LBSanitizeBookDictForReaderEx(merged, NO, YES);
        openBook = merged;
        LBAppendOpenReaderTrace(@"openBook=mergedFull");
    } else if (fullBook != nil) {
        // 非字典书架对象：仍用 lean dict 调 openReader，record 传 fullBook
        LBAppendOpenReaderTrace([NSString stringWithFormat:@"openBook=lean recordCls=%@",
                                 NSStringFromClass([fullBook class])]);
    } else {
        LBAppendOpenReaderTrace(@"openBook=leanDict record=nil");
    }
    LBDumpBookDictForOpenReader(
        [openBook isKindOfClass:[NSDictionary class]] ? (NSDictionary *)openBook : mutableBook,
        @"nativeOpen preCallLean"
    );
    LBAppendOpenReaderTrace([NSString stringWithFormat:@"preCallLean keys=%lu src=%@",
                             (unsigned long)mutableBook.count, sourceName ?: @""]);
    NSMutableArray *targets = [NSMutableArray array];
    id appDel = [UIApplication sharedApplication].delegate;
    if (appDel) [targets addObject:appDel];
    for (UIViewController *vc in LBFindCatalogVCs()) {
        if ([vc respondsToSelector:openSel] && ![targets containsObject:vc]) {
            [targets addObject:vc];
        }
    }
    for (UIWindow *w in LBAllAppWindows()) {
        UIViewController *root = w.rootViewController;
        if (!root) continue;
        NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
        while (stack.count > 0) {
            UIViewController *vc = stack.lastObject;
            [stack removeLastObject];
            if ([vc respondsToSelector:openSel] && ![targets containsObject:vc]) {
                [targets addObject:vc];
            }
            for (UIViewController *c in vc.childViewControllers) [stack addObject:c];
            if (vc.presentedViewController) [stack addObject:vc.presentedViewController];
            if ([vc isKindOfClass:[UINavigationController class]]) {
                for (UIViewController *c in [(UINavigationController *)vc viewControllers]) {
                    [stack addObject:c];
                }
            }
        }
    }
    // record：优先书架 fullBook 对象；否则 nil（自制章节 dict 曾致 callingOrig 后杀进程）
    id recordArg = ([fullBook isKindOfClass:[NSDictionary class]]) ? nil : fullBook;
    NSMutableArray *tried = [NSMutableArray array];
    for (id t in targets) {
        NSString *cn = NSStringFromClass([t class]);
        [tried addObject:cn];
        if (![t respondsToSelector:openSel]) continue;
        @try {
            NSString *mark = [NSString stringWithFormat:@"nativeOpen callingOrig on %@ lean=1 rec=%@",
                              cn, recordArg ? NSStringFromClass([recordArg class]) : @"nil"];
            LBWriteOpenReaderMarker(mark);
            LBAppendOpenReaderTrace(mark);
            if (LBOrig_openReader && t == appDel) {
                LBOrig_openReader(t, openSel, openBook, sourceName ?: @"", recordArg);
            } else {
                ((void (*)(id, SEL, id, id, id))objc_msgSend)(
                    t, openSel, openBook, sourceName ?: @"", recordArg
                );
            }
            if (outMsg) {
                *outMsg = [NSString stringWithFormat:@"openReader ok on %@ src=%@ lean=1",
                           cn, sourceName ?: @""];
            }
            LBAppendOpenReaderTrace([NSString stringWithFormat:@"openReader returned %@", cn]);
            return YES;
        } @catch (NSException *e) {
            NSLog(@"[LegadoBridge] openReader on %@ fail-open: %@", cn, e);
            LBWriteOpenReaderMarker([NSString stringWithFormat:@"nativeOpen openEx %@ %@",
                                     cn, e.reason ?: @""]);
            LBAppendOpenReaderTrace([NSString stringWithFormat:@"openEx %@ %@",
                                     cn, e.reason ?: @""]);
        }
    }
    if (outMsg) {
        *outMsg = [NSString stringWithFormat:@"openReader miss tried=%@",
                   [tried componentsJoinedByString:@","]];
    }
    return NO;
}

/// 不调 openReader：alloc TextReadVC 后 push/present，正文靠 ResetContent 灌入
static void LBInjectPendingContentIntoReader(UIViewController *readerVC, NSString *phase) {
    NSDictionary *payload = sPendingResetContent;
    if (![payload isKindOfClass:[NSDictionary class]] || payload.count == 0) {
        LBAppendOpenReaderTrace([NSString stringWithFormat:@"injectSkip empty phase=%@", phase ?: @""]);
        return;
    }
    NSString *body = nil;
    id c = payload[@"chapterContent"] ?: payload[@"content"];
    if ([c isKindOfClass:[NSString class]]) body = (NSString *)c;
    if (body.length == 0) {
        LBAppendOpenReaderTrace([NSString stringWithFormat:@"injectSkip noBody phase=%@", phase ?: @""]);
        return;
    }
    // 禁止 post ResetContent：裸 TextRead 收通知会 SIGABRT。直接灌 UITextView。
    NSMutableArray *stack = [NSMutableArray array];
    if (readerVC.isViewLoaded && readerVC.view) [stack addObject:readerVC.view];
    UITextView *target = nil;
    while (stack.count > 0) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if ([v isKindOfClass:[UITextView class]]) {
            target = (UITextView *)v;
            // 偏好面积较大的正文视图
            if (v.bounds.size.width >= 200 && v.bounds.size.height >= 200) break;
        }
        for (UIView *sub in v.subviews) [stack addObject:sub];
    }
    if (!target) {
        // 再试 KVC 常见出口
        for (NSString *k in @[@"textView", @"textViewL", @"tv", @"contentTextView"]) {
            @try {
                id tv = [readerVC valueForKey:k];
                if ([tv isKindOfClass:[UITextView class]]) {
                    target = (UITextView *)tv;
                    break;
                }
            } @catch (__unused NSException *e) {}
        }
    }
    if (!target) {
        LBAppendOpenReaderTrace([NSString stringWithFormat:@"injectMiss noTV phase=%@", phase ?: @""]);
        return;
    }
    @try {
        NSString *title = payload[@"cpTitle"] ?: payload[@"title"] ?: @"";
        if (![title isKindOfClass:[NSString class]]) title = @"";
        target.text = title.length > 0
            ? [NSString stringWithFormat:@"%@\n\n%@", title, body]
            : body;
        target.accessibilityLabel = body;
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"injectOK phase=%@ len=%lu tv=%@",
                                 phase ?: @"", (unsigned long)body.length,
                                 NSStringFromClass([target class])]);
        if ([body containsString:@"萧炎"] || [body containsString:@"斗气"]) {
            LBWriteOpenReaderMarker([NSString stringWithFormat:
                                    @"nativeOpen keepTextRead readerVis=1 via=injectTV phase=%@",
                                    phase ?: @""]);
        }
    } @catch (NSException *e) {
        LBAppendOpenReaderTrace([NSString stringWithFormat:@"injectEx %@", e.reason ?: @""]);
    }
}

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
    LBSanitizeBookDictForReaderEx(dic, NO, YES);
    LBReadingRememberBook(dic);
    (void)dic; // 仅用于绑定记忆；不写入 TextRead（setter/ResetContent 会 SIGABRT）
    LBAppendOpenReaderTrace([NSString stringWithFormat:@"pushReader deferInject %@ keys=%lu",
                             NSStringFromClass(cls), (unsigned long)dic.count]);
    id vcRef = vc;
    void (^applyDicLater)(void) = ^{
        @try {
            LBAppendOpenReaderTrace(@"pushReader applyDic now");
            // 不写 dicBook、不发 ResetContent（二者均曾致 SIGABRT）
            LBAppendOpenReaderTrace(@"pushReader skipDicBook injectTVOnly");
            UIViewController *rvc = (UIViewController *)vcRef;
            LBInjectPendingContentIntoReader(rvc, @"t0");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                LBInjectPendingContentIntoReader(rvc, @"t0.8");
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                LBInjectPendingContentIntoReader(rvc, @"t1.6");
                BOOL vis = LBIsTextReaderVisible();
                if (vis) {
                    LBWriteOpenReaderMarker(@"nativeOpen keepTextRead readerVis=1 via=pushInject");
                } else {
                    LBWriteOpenReaderMarker(@"nativeOpen pushDone readerVis=0");
                }
                LBAppendOpenReaderTrace([NSString stringWithFormat:
                                        @"pushReader settle vis=%d", vis ? 1 : 0]);
            });
        } @catch (NSException *e) {
            LBAppendOpenReaderTrace([NSString stringWithFormat:@"pushReader setDicEx %@", e.reason ?: @""]);
            LBWriteOpenReaderMarker([NSString stringWithFormat:@"nativeOpen pushSetDicEx %@",
                                     e.reason ?: @""]);
        }
    };
    // 优先推到自建目录页的 nav（避免 dismiss 整条链路）
    UINavigationController *nav = nil;
    for (UIViewController *c in LBFindCatalogVCs()) {
        NSString *cn = NSStringFromClass([c class]);
        if ([cn containsString:@"LBLegadoCatalogListVC"] && c.navigationController) {
            nav = c.navigationController;
            break;
        }
    }
    if (!nav) {
        for (UIViewController *c in LBFindCatalogVCs()) {
            if (c.navigationController) {
                nav = c.navigationController;
                break;
            }
        }
    }
    if (!nav) {
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
            }
            if (nav) break;
        }
    }
    if (nav) {
        @try {
            LBWriteOpenReaderMarker([NSString stringWithFormat:@"nativeOpen pushing %@ on %@",
                                     NSStringFromClass(cls), NSStringFromClass([nav class])]);
            LBAppendOpenReaderTrace(@"pushReader pushVC");
            [nav pushViewController:(UIViewController *)vc animated:YES];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), applyDicLater);
            if (outMsg) {
                *outMsg = [NSString stringWithFormat:@"pushReader ok %@ on %@",
                           NSStringFromClass(cls), NSStringFromClass([nav class])];
            }
            return YES;
        } @catch (NSException *e) {
            if (outMsg) *outMsg = [NSString stringWithFormat:@"pushReader fail: %@", e.reason ?: @""];
            LBAppendOpenReaderTrace([NSString stringWithFormat:@"pushEx %@", e.reason ?: @""]);
        }
    }
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
        LBWriteOpenReaderMarker([NSString stringWithFormat:@"nativeOpen presenting %@ on %@",
                                 NSStringFromClass(cls), NSStringFromClass([host class])]);
        LBAppendOpenReaderTrace(@"pushReader presentVC");
        [host presentViewController:wrap animated:YES completion:^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), applyDicLater);
        }];
        if (outMsg) {
            *outMsg = [NSString stringWithFormat:@"presentReader ok %@ on %@",
                       NSStringFromClass(cls), NSStringFromClass([host class])];
        }
        return YES;
    } @catch (NSException *e) {
        if (outMsg) *outMsg = [NSString stringWithFormat:@"presentReader fail: %@", e.reason ?: @""];
        LBAppendOpenReaderTrace([NSString stringWithFormat:@"presentEx %@", e.reason ?: @""]);
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
    if (LBIsTextReaderVisible()) {
        // 禁止 post ResetContent（裸 TextRead 会 SIGABRT）；改为 UITextView 直灌
        for (UIWindow *w in LBAllAppWindows()) {
            UIViewController *root = w.rootViewController;
            if (!root) continue;
            NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
            while (stack.count > 0) {
                UIViewController *vc = stack.lastObject;
                [stack removeLastObject];
                NSString *cn = NSStringFromClass([vc class]);
                if ([cn containsString:@"TextReadVC"] || [cn containsString:@"ReadVCBase"]) {
                    if (LBVCIsVisibleInWindow(vc)) {
                        LBInjectPendingContentIntoReader(vc, @"notePosted");
                    }
                }
                for (UIViewController *c in vc.childViewControllers) [stack addObject:c];
                if (vc.presentedViewController) [stack addObject:vc.presentedViewController];
                if ([vc isKindOfClass:[UINavigationController class]]) {
                    for (UIViewController *c in [(UINavigationController *)vc viewControllers]) {
                        [stack addObject:c];
                    }
                }
            }
        }
    } else {
        // Bridge 可见时同步灌入；否则等 inject / delay
        LBBridgeReaderApplyContent(userInfo);
    }
}

void LBBridgeReaderApplyPendingOnAppear(void) {
    if (sPendingResetContent.count == 0) return;
    LBBridgeReaderApplyContent(sPendingResetContent);
}

static void LBFlushPendingResetContent(NSString *phase) {
    if (sPendingResetContent.count == 0) return;
    // 原生 TextRead 在场时绝不 post ResetContent（SIGABRT）；只直灌 TV / Bridge
    if (LBIsTextReaderVisible()) {
        for (UIWindow *w in LBAllAppWindows()) {
            UIViewController *root = w.rootViewController;
            if (!root) continue;
            NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
            while (stack.count > 0) {
                UIViewController *vc = stack.lastObject;
                [stack removeLastObject];
                NSString *cn = NSStringFromClass([vc class]);
                if ([cn containsString:@"TextReadVC"] || [cn containsString:@"ReadVCBase"]) {
                    if (LBVCIsVisibleInWindow(vc)) {
                        LBInjectPendingContentIntoReader(vc, phase ?: @"flush");
                    }
                }
                for (UIViewController *c in vc.childViewControllers) [stack addObject:c];
                if (vc.presentedViewController) [stack addObject:vc.presentedViewController];
                if ([vc isKindOfClass:[UINavigationController class]]) {
                    for (UIViewController *c in [(UINavigationController *)vc viewControllers]) {
                        [stack addObject:c];
                    }
                }
            }
        }
        return;
    }
    NSDictionary *payload = [sPendingResetContent copy];
    void (^post)(void) = ^{
        // 仅 Bridge / 无原生阅读页时才发通知
        LBBridgeReaderApplyContent(payload);
        NSString *marker = [NSString stringWithFormat:@"flushResetContent bridgeOnly %@ ch=%@",
                            phase ?: @"", payload[@"chapterUrl"] ?: @""];
        [marker writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_content_flush.txt"]
                 atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    };
    if ([NSThread isMainThread]) post();
    else dispatch_async(dispatch_get_main_queue(), post);
}

void LBInstallReaderContentAppearFlush(void) {
    // 禁用对 TextRead/ReadVCBase 的 viewWill/DidAppear 链式替换：
    // 子类+基类各挂一次会在 appear 时递归 SIGABRT（sig=6，无 ips）。
    // 正文改走 delay flush / push 后主动 flush。
    if (sReaderContentAppearHooked) return;
    sReaderContentAppearHooked = YES;
    LBAppendOpenReaderTrace(@"appearFlush disabled (avoid recursive SIGABRT)");
}

static void LBInstallCatalogTableHooksOnClass(Class cls) {
    if (!cls) return;
    static NSMutableSet *sHookedOwners = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ sHookedOwners = [NSMutableSet set]; });

    SEL rowsSel = @selector(tableView:numberOfRowsInSection:);
    Class rowsOwner = LBClassOwningInstanceMethod(cls, rowsSel) ?: cls;
    Method rowsM = class_getInstanceMethod(rowsOwner, rowsSel);
    NSString *rowsKey = [NSString stringWithFormat:@"rows:%@", NSStringFromClass(rowsOwner)];
    if (rowsM && ![sHookedOwners containsObject:rowsKey]) {
        // 仅保留首个 orig 指针用于转发；多类共用同一 hooked IMP 时，用 pending/Legado 数组优先
        if (!sOrigCatalogNumberOfRows) {
            sOrigCatalogNumberOfRows = method_getImplementation(rowsM);
        }
        method_setImplementation(rowsM, (IMP)LBHookedCatalogNumberOfRows);
        [sHookedOwners addObject:rowsKey];
    }
    SEL cellSel = @selector(tableView:cellForRowAtIndexPath:);
    Class cellOwner = LBClassOwningInstanceMethod(cls, cellSel) ?: cls;
    Method cellM = class_getInstanceMethod(cellOwner, cellSel);
    NSString *cellKey = [NSString stringWithFormat:@"cell:%@", NSStringFromClass(cellOwner)];
    if (cellM && ![sHookedOwners containsObject:cellKey]) {
        if (!sOrigCatalogCellForRow) {
            sOrigCatalogCellForRow = method_getImplementation(cellM);
        }
        method_setImplementation(cellM, (IMP)LBHookedCatalogCellForRow);
        [sHookedOwners addObject:cellKey];
    }
    SEL selSel = @selector(tableView:didSelectRowAtIndexPath:);
    Class selOwner = LBClassOwningInstanceMethod(cls, selSel) ?: cls;
    Method selM = class_getInstanceMethod(selOwner, selSel);
    NSString *selKey = [NSString stringWithFormat:@"sel:%@", NSStringFromClass(selOwner)];
    if (selM && ![sHookedOwners containsObject:selKey]) {
        void (*prev)(id, SEL, UITableView *, NSIndexPath *) =
            (void (*)(id, SEL, UITableView *, NSIndexPath *))method_getImplementation(selM);
        if (!LBOrig_catalogDidSelect) {
            LBOrig_catalogDidSelect = prev;
        }
        IMP hook = imp_implementationWithBlock(^void(id selfObj, UITableView *tv, NSIndexPath *ip) {
            // 搜索/非目录上下文：Legado 书安全推详情；其它原样转发
            if (LBVCIsSearchTableContext(selfObj) || !LBVCIsCatalogTableContext(selfObj)) {
                if (LBVCIsSearchTableContext(selfObj) && ip) {
                    @try {
                        id b = [selfObj valueForKey:@"arrBaseData"];
                        if ([b isKindOfClass:[NSArray class]] &&
                            ip.row >= 0 && ip.row < (NSInteger)[(NSArray *)b count]) {
                            id item = ((NSArray *)b)[(NSUInteger)ip.row];
                            BOOL legadoBook = NO;
                            if ([item isKindOfClass:[NSDictionary class]]) {
                                NSDictionary *d = (NSDictionary *)item;
                                legadoBook = (d[@"legadoBridge"] != nil || d[@"fromLegadoBridge"] != nil) &&
                                             !LBItemLooksLikeChapter(item);
                            }
                            if (legadoBook && LBPushLegadoBookDetailFromSearch(selfObj, item)) {
                                if (tv && ip) {
                                    @try { [tv deselectRowAtIndexPath:ip animated:YES]; } @catch (__unused NSException *e) {}
                                }
                                return;
                            }
                        }
                    } @catch (NSException *e) {
                        NSLog(@"[LegadoBridge] search select fail-open: %@", e);
                    }
                }
                if (prev) {
                    @try { prev(selfObj, selSel, tv, ip); } @catch (NSException *e) {
                        NSLog(@"[LegadoBridge] search/native didSelect fail-open: %@", e);
                    }
                }
                return;
            }
            NSArray *use = sPendingCatalogChapters;
            if (use.count == 0) {
                @try {
                    id b = [selfObj valueForKey:@"arrBaseData"];
                    if (LBArrayLooksLikeChapters(b)) use = b;
                } @catch (__unused NSException *e) {}
            }
            if (use.count == 0) {
                @try {
                    id c = [selfObj valueForKey:@"arrCatalog"];
                    if (LBArrayLooksLikeChapters(c)) use = c;
                } @catch (__unused NSException *e) {}
            }
            BOOL handled = NO;
            if (use.count > 0 && ip && ip.row >= 0 && ip.row < (NSInteger)use.count) {
                id rowItem = use[(NSUInteger)ip.row];
                if (!LBItemLooksLikeChapter(rowItem)) {
                    // 书行误入：交给原生
                    use = nil;
                }
            }
            if (use.count > 0 && ip && ip.row >= 0 && ip.row < (NSInteger)use.count) {
                if (sPendingCatalogChapters.count == 0) {
                    sPendingCatalogChapters = [use copy];
                }
                LBTrySetArrayKey(selfObj, @"arrCatalog", use);
                // Legado 点章：走受控原生 openReader（失败 Bridge），不调原生 didSelect
                LBOpenLegadoChapterAtIndex(ip.row);
                if (tv && ip) {
                    @try { [tv deselectRowAtIndexPath:ip animated:YES]; } @catch (__unused NSException *e) {}
                }
                handled = YES;
            }
            if (!handled && prev) {
                @try {
                    prev(selfObj, selSel, tv, ip);
                } @catch (NSException *e) {
                    NSLog(@"[LegadoBridge] catalog didSelect fail-open: %@", e);
                }
            }
        });
        method_setImplementation(selM, hook);
        [sHookedOwners addObject:selKey];
    }
}

/// 从沙盒 bridge 书库按 bookUrl / 书名匹配（详情页站点(0+) 时常丢 legado 标记）
static NSDictionary *LBBridgeBookRowMatching(NSString *bookUrl, NSString *name) {
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_bridge_books.json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data.length == 0) return nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![json isKindOfClass:[NSArray class]]) return nil;
    for (id row in (NSArray *)json) {
        if (![row isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *d = (NSDictionary *)row;
        NSString *bu = d[@"bookUrl"];
        NSString *nm = d[@"name"];
        if (bookUrl.length > 0 && [bu isKindOfClass:[NSString class]] && [bu isEqualToString:bookUrl]) {
            return d;
        }
        if (name.length > 0 && [nm isKindOfClass:[NSString class]] && [nm isEqualToString:name]) {
            return d;
        }
    }
    return nil;
}

/// Legado 书：短路原生 openReader / beginRead，强制 Bridge（点章硬保证）
static BOOL LBBookLooksLegadoForKillSwitch(id bookOrRecord, NSString **outBookUrl, NSString **outChUrl, NSString **outTitle) {
    NSDictionary *dic = LBReadingDicFromObject(bookOrRecord);
    if (![dic isKindOfClass:[NSDictionary class]]) dic = nil;
    NSString *bookUrl = LBReadingBookUrlFromDic(dic);
    NSString *bookName = nil;
    if (dic) {
        id nm = dic[@"name"] ?: dic[@"bookName"] ?: dic[@"title"];
        if ([nm isKindOfClass:[NSString class]]) bookName = nm;
    }
    if (bookUrl.length == 0 && sPendingCatalogBookUrl.length > 0) {
        bookUrl = sPendingCatalogBookUrl;
    }
    NSDictionary *bridgeRow = LBBridgeBookRowMatching(bookUrl, bookName);
    if (bridgeRow && bookUrl.length == 0) {
        id bu = bridgeRow[@"bookUrl"];
        if ([bu isKindOfClass:[NSString class]]) bookUrl = bu;
    }
    BOOL isLegado = LBReadingDicLooksLegado(dic) ||
                    (bookUrl.length > 0 && LBReadingSourceUrlForBookUrl(bookUrl).length > 0) ||
                    (bookUrl.length > 0 && sPendingCatalogBookUrl.length > 0 &&
                     [bookUrl isEqualToString:sPendingCatalogBookUrl]) ||
                    (sPendingCatalogChapters.count > 0 && sPendingCatalogBookUrl.length > 0 &&
                     (bookUrl.length == 0 || [bookUrl isEqualToString:sPendingCatalogBookUrl])) ||
                    (bridgeRow != nil);
    if (!isLegado) return NO;
    if (bookUrl.length > 0 && sPendingCatalogBookUrl.length == 0) {
        sPendingCatalogBookUrl = [bookUrl copy];
    }
    NSString *chUrl = nil;
    NSString *title = nil;
    if (dic) {
        id v = dic[@"chapterUrl"] ?: dic[@"cpUrl"] ?: dic[@"curChapterUrl"];
        if ([v isKindOfClass:[NSString class]]) chUrl = v;
        v = dic[@"cpTitle"] ?: dic[@"chapterName"];
        if ([v isKindOfClass:[NSString class]]) title = v;
    }
    if (chUrl.length == 0 && sPendingCatalogChapters.count > 0 &&
        (sPendingCatalogBookUrl.length == 0 || [sPendingCatalogBookUrl isEqualToString:bookUrl])) {
        NSInteger idx = 0;
        id idxObj = dic[@"cpIndex"] ?: dic[@"chapterIndex"];
        if ([idxObj respondsToSelector:@selector(integerValue)]) {
            idx = [idxObj integerValue];
        }
        if (idx < 0 || idx >= (NSInteger)sPendingCatalogChapters.count) idx = 0;
        id item = sPendingCatalogChapters[(NSUInteger)idx];
        if ([item isKindOfClass:[NSDictionary class]]) {
            NSDictionary *d = (NSDictionary *)item;
            chUrl = d[@"cpUrl"] ?: d[@"chapterUrl"] ?: d[@"url"];
            if (title.length == 0) {
                title = d[@"cpTitle"] ?: d[@"title"] ?: d[@"name"] ?: d[@"chapterName"];
            }
        }
    }
    if (outBookUrl) *outBookUrl = bookUrl;
    if (outChUrl) *outChUrl = chUrl;
    if (outTitle) *outTitle = title.length > 0 ? title : bookName;
    return YES;
}

static void __attribute__((unused)) LBKillSwitchPresentBridge(NSString *phase, NSString *bookUrl, NSString *chUrl, NSString *title) {
    NSString *marker = [NSString stringWithFormat:@"bridgeFallback %@ book=%@ ch=%@",
                        phase ?: @"?", bookUrl ?: @"", chUrl ?: @""];
    [marker writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_catalog_openreader.txt"]
             atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    if (bookUrl.length == 0) return;
    if (chUrl.length == 0) {
        NSString *su = LBReadingSourceUrlForBookUrl(bookUrl);
        sPendingCatalogBookUrl = [bookUrl copy];
        LBHandleCatalogRequest(bookUrl, su);
        NSString *buCopy = [bookUrl copy];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (sPendingCatalogBookUrl.length > 0 &&
                ![sPendingCatalogBookUrl isEqualToString:buCopy]) {
                return;
            }
            if (sPendingCatalogChapters.count > 0) {
                LBOpenLegadoChapterAtIndex(0);
            }
        });
        return;
    }
    NSString *titleCopy = title.length > 0 ? [title copy] : @"章节";
    NSString *chCopy = [chUrl copy];
    NSString *buCopy = [bookUrl copy];
    void (^go)(void) = ^{
        NSString *brMsg = nil;
        BOOL ok = LBPresentBridgeReader(titleCopy, chCopy, buCopy, &brMsg);
        NSString *line = [NSString stringWithFormat:
                          @"bridgeReader presented=%d | %@ || via=%@",
                          ok ? 1 : 0, brMsg ?: @"?", phase ?: @"fallback"];
        [line writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_catalog_openreader.txt"]
               atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        LBHandleContentRequest(chCopy, buCopy, nil);
    };
    if ([NSThread isMainThread]) go();
    else dispatch_async(dispatch_get_main_queue(), go);
}

static void LBOpenReader_KillIMP(id self, SEL _cmd, id book, id sourceName, id record) {
    NSString *bu = nil, *ch = nil, *title = nil;
    BOOL isLegado = LBBookLooksLegadoForKillSwitch(book, &bu, &ch, &title) ||
                    LBBookLooksLegadoForKillSwitch(record, &bu, &ch, &title);
    if (isLegado) {
        NSString *src = [sourceName isKindOfClass:[NSString class]] ? (NSString *)sourceName : nil;
        NSMutableDictionary *m = nil;
        if ([book isKindOfClass:[NSDictionary class]]) {
            m = [NSMutableDictionary dictionaryWithDictionary:(NSDictionary *)book];
        } else {
            m = [NSMutableDictionary dictionary];
        }
        NSInteger cpIdx = 0;
        id cpi = m[@"cpIndex"] ?: m[@"chapterIndex"];
        if ([cpi respondsToSelector:@selector(integerValue)]) {
            cpIdx = [cpi integerValue];
        }
        NSMutableDictionary *built = LBBookDictForOpenReader(bu, nil, cpIdx, ch, &src);
        [built addEntriesFromDictionary:m];
        if (bu.length > 0) {
            built[@"bookUrl"] = bu;
            built[@"url"] = bu;
        }
        if (ch.length > 0) {
            built[@"chapterUrl"] = ch;
            built[@"cpUrl"] = ch;
            built[@"curChapterUrl"] = ch;
        }
        if (title.length > 0) {
            id cpt = built[@"cpTitle"];
            if (![cpt isKindOfClass:[NSString class]] || [(NSString *)cpt length] == 0) {
                built[@"cpTitle"] = title;
            }
        }
        LBSanitizeBookDictForReader(built);
        NSString *marker = [NSString stringWithFormat:
                            @"nativeGuard openReader book=%@ ch=%@ src=%@",
                            bu ?: @"", ch ?: @"", src ?: @""];
        [marker writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_catalog_openreader.txt"]
                 atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        if (LBOrig_openReader) {
            LBOrig_openReader(self, _cmd, built, src.length > 0 ? src : (sourceName ?: @""), record);
        }
        return;
    }
    if (LBOrig_openReader) {
        LBOrig_openReader(self, _cmd, book, sourceName, record);
    }
}

static void (*LBOrig_onBeginReadEvent)(id, SEL, id) = NULL;
static void LBOnBeginReadEvent_KillIMP(id self, SEL _cmd, id note) {
    NSString *bu = nil, *ch = nil, *title = nil;
    id dicBook = nil;
    @try { dicBook = [self valueForKey:@"dicBook"]; } @catch (__unused NSException *e) {}
    BOOL isLegado = LBBookLooksLegadoForKillSwitch(dicBook, &bu, &ch, &title) ||
                    LBBookLooksLegadoForKillSwitch(note, &bu, &ch, &title) ||
                    (sPendingCatalogChapters.count > 0 && sPendingCatalogBookUrl.length > 0);
    if (isLegado) {
        @try {
            if ([dicBook isKindOfClass:[NSDictionary class]]) {
                NSMutableDictionary *m = [NSMutableDictionary dictionaryWithDictionary:(NSDictionary *)dicBook];
                LBSanitizeBookDictForReader(m);
                if ([self respondsToSelector:@selector(setDicBook:)]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(self, @selector(setDicBook:), m);
                } else {
                    [self setValue:m forKey:@"dicBook"];
                }
            }
        } @catch (__unused NSException *e) {}
        // 消毒后回原生；若仍崩，点章路径有 Bridge 兜底
        if (LBOrig_onBeginReadEvent) {
            LBOrig_onBeginReadEvent(self, _cmd, note);
        }
        return;
    }
    if (LBOrig_onBeginReadEvent) {
        LBOrig_onBeginReadEvent(self, _cmd, note);
    }
}

static void (*LBOrig_onBeginEvent)(id, SEL, id) = NULL;
static void LBOnBeginEvent_KillIMP(id self, SEL _cmd, id note) {
    NSString *bu = nil, *ch = nil, *title = nil;
    id dicBook = nil;
    @try { dicBook = [self valueForKey:@"dicBook"]; } @catch (__unused NSException *e) {}
    BOOL isLegado = LBBookLooksLegadoForKillSwitch(dicBook, &bu, &ch, &title) ||
                    LBBookLooksLegadoForKillSwitch(note, &bu, &ch, &title) ||
                    (sPendingCatalogChapters.count > 0 && sPendingCatalogBookUrl.length > 0);
    if (isLegado) {
        @try {
            if ([dicBook isKindOfClass:[NSDictionary class]]) {
                NSMutableDictionary *m = [NSMutableDictionary dictionaryWithDictionary:(NSDictionary *)dicBook];
                LBSanitizeBookDictForReader(m);
                if ([self respondsToSelector:@selector(setDicBook:)]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(self, @selector(setDicBook:), m);
                } else {
                    [self setValue:m forKey:@"dicBook"];
                }
            }
        } @catch (__unused NSException *e) {}
        if (LBOrig_onBeginEvent) {
            LBOrig_onBeginEvent(self, _cmd, note);
        }
        return;
    }
    if (LBOrig_onBeginEvent) {
        LBOrig_onBeginEvent(self, _cmd, note);
    }
}

static void LBTryOpenRecord_KillIMP(id self, SEL _cmd, id record, id sourceName) {
    NSString *bu = nil, *ch = nil, *title = nil;
    if (LBBookLooksLegadoForKillSwitch(record, &bu, &ch, &title)) {
        NSString *src = [sourceName isKindOfClass:[NSString class]] ? (NSString *)sourceName : nil;
        NSMutableDictionary *built = LBBookDictForOpenReader(bu, nil, 0, ch, &src);
        LBSanitizeBookDictForReader(built);
        @try {
            if ([self respondsToSelector:@selector(setDicBook:)]) {
                ((void (*)(id, SEL, id))objc_msgSend)(self, @selector(setDicBook:), built);
            }
        } @catch (__unused NSException *e) {}
        if (LBOrig_tryOpenRecord) {
            LBOrig_tryOpenRecord(self, _cmd, built, src.length > 0 ? src : sourceName);
        }
        return;
    }
    if (LBOrig_tryOpenRecord) {
        LBOrig_tryOpenRecord(self, _cmd, record, sourceName);
    }
}

void LBInstallLegadoReaderKillSwitch(void) {
    static BOOL sOnce = NO;
    if (sOnce) return;
    sOnce = YES;
    @try {
        // AppDelegate.openReader:sourceName:record: — Legado 消毒后走原生
        id appDel = [UIApplication sharedApplication].delegate;
        Class openCls = appDel ? object_getClass(appDel) : Nil;
        SEL openSel = NSSelectorFromString(@"openReader:sourceName:record:");
        if (!openCls || !class_getInstanceMethod(openCls, openSel)) {
            openCls = NSClassFromString(@"AppDelegate");
        }
        if (openCls) {
            Class owner = LBClassOwningInstanceMethod(openCls, openSel) ?: openCls;
            Method m = class_getInstanceMethod(owner, openSel);
            if (m && !LBOrig_openReader) {
                LBOrig_openReader = (void (*)(id, SEL, id, id, id))method_getImplementation(m);
                method_setImplementation(m, (IMP)LBOpenReader_KillIMP);
                NSLog(@"[LegadoBridge] nativeGuard hooked openReader @%@", NSStringFromClass(owner));
            }
        }
        for (NSString *cn in @[@"BookDetailController", @"BookDetailVCBase"]) {
            Class cls = NSClassFromString(cn);
            if (!cls) continue;
            SEL beginReadSel = NSSelectorFromString(@"onBeginReadEvent:");
            Class beginReadOwner = LBClassOwningInstanceMethod(cls, beginReadSel);
            if (beginReadOwner) {
                Method m = class_getInstanceMethod(beginReadOwner, beginReadSel);
                if (m && !LBOrig_onBeginReadEvent) {
                    LBOrig_onBeginReadEvent = (void (*)(id, SEL, id))method_getImplementation(m);
                    method_setImplementation(m, (IMP)LBOnBeginReadEvent_KillIMP);
                    NSLog(@"[LegadoBridge] nativeGuard hooked onBeginReadEvent: @%@",
                          NSStringFromClass(beginReadOwner));
                }
            }
            SEL beginSel = NSSelectorFromString(@"onBeginEvent:");
            Class beginOwner = LBClassOwningInstanceMethod(cls, beginSel);
            if (beginOwner) {
                Method m = class_getInstanceMethod(beginOwner, beginSel);
                if (m && !LBOrig_onBeginEvent) {
                    LBOrig_onBeginEvent = (void (*)(id, SEL, id))method_getImplementation(m);
                    method_setImplementation(m, (IMP)LBOnBeginEvent_KillIMP);
                    NSLog(@"[LegadoBridge] nativeGuard hooked onBeginEvent: @%@",
                          NSStringFromClass(beginOwner));
                }
            }
            SEL trySel = NSSelectorFromString(@"tryOpenRecord:sourceName:");
            Class tryOwner = LBClassOwningInstanceMethod(cls, trySel);
            if (tryOwner) {
                Method m = class_getInstanceMethod(tryOwner, trySel);
                if (m && !LBOrig_tryOpenRecord) {
                    LBOrig_tryOpenRecord = (void (*)(id, SEL, id, id))method_getImplementation(m);
                    method_setImplementation(m, (IMP)LBTryOpenRecord_KillIMP);
                    NSLog(@"[LegadoBridge] nativeGuard hooked tryOpenRecord @%@",
                          NSStringFromClass(tryOwner));
                }
            }
        }
        NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_reader_killswitch.txt"];
        [@"nativeGuard" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    } @catch (NSException *e) {
        NSLog(@"[LegadoBridge] nativeGuard install fail-open: %@", e);
    }
}

void LBInstallCatalogUIAppearFlush(void) {
    if (sCatalogUIAppearHooked) return;
    sCatalogUIAppearHooked = YES;
    LBInstallReaderContentAppearFlush();
    LBInstallLegadoReaderKillSwitch();
    // 搜索页常有独立 didSelect，不经 Catalog 公共基类 hook → 原生点书杀进程
    static NSMutableSet *sSearchSelHooked = nil;
    static dispatch_once_t onceSearchSel;
    dispatch_once(&onceSearchSel, ^{ sSearchSelHooked = [NSMutableSet set]; });
    SEL selSel = @selector(tableView:didSelectRowAtIndexPath:);
    for (NSString *cn in @[@"BookSearchController", @"BookSearchVCBase1", @"BookSearchVCBase2"]) {
        Class cls = NSClassFromString(cn);
        if (!cls) continue;
        Class owner = LBClassOwningInstanceMethod(cls, selSel) ?: cls;
        NSString *key = [NSString stringWithFormat:@"searchSel:%@", NSStringFromClass(owner)];
        if ([sSearchSelHooked containsObject:key]) continue;
        Method m = class_getInstanceMethod(owner, selSel);
        if (!m) continue;
        void (*prev)(id, SEL, UITableView *, NSIndexPath *) =
            (void (*)(id, SEL, UITableView *, NSIndexPath *))method_getImplementation(m);
        IMP hook = imp_implementationWithBlock(^void(id selfObj, UITableView *tv, NSIndexPath *ip) {
            [[NSString stringWithFormat:@"searchDidSelect hit class=%@ row=%ld",
              NSStringFromClass([selfObj class]), (long)(ip ? ip.row : -1)]
                writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_select.txt"]
                atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            BOOL handled = NO;
            @try {
                id b = [selfObj valueForKey:@"arrBaseData"];
                if ([b isKindOfClass:[NSArray class]] && ip &&
                    ip.row >= 0 && ip.row < (NSInteger)[(NSArray *)b count]) {
                    id item = ((NSArray *)b)[(NSUInteger)ip.row];
                    // 搜索页任意字典行：绝不回落原生 didSelect（无 bookUrl 也先旁路，避免回桌面）
                    if ([item isKindOfClass:[NSDictionary class]] && !LBItemLooksLikeChapter(item)) {
                        NSDictionary *d = (NSDictionary *)item;
                        id bu = d[@"bookUrl"] ?: d[@"url"];
                        BOOL hasBookUrl = [bu isKindOfClass:[NSString class]] && [(NSString *)bu length] > 0;
                        handled = YES;
                        if (hasBookUrl) {
                            if (LBPushLegadoBookDetailFromSearch(selfObj, item)) {
                                if (tv && ip) {
                                    @try { [tv deselectRowAtIndexPath:ip animated:YES]; } @catch (__unused NSException *e) {}
                                }
                                return;
                            }
                            NSString *su = d[@"sourceUrl"] ?: d[@"bookSourceUrl"];
                            sDeferredNativeOpenIdx = 0;
                            sDeferredNativeOpenBookUrl = [bu copy];
                            LBHandleCatalogRequest(bu, [su isKindOfClass:[NSString class]] ? su : nil);
                            [[NSString stringWithFormat:@"searchPush fail→catalog+defer book=%@", bu]
                                writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_select.txt"]
                                atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                        } else {
                            [[NSString stringWithFormat:@"searchSkip noBookUrl keys=%@",
                              [[d allKeys] componentsJoinedByString:@","]]
                                writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_select.txt"]
                                atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                        }
                        if (tv && ip) {
                            @try { [tv deselectRowAtIndexPath:ip animated:YES]; } @catch (__unused NSException *e) {}
                        }
                        return;
                    }
                }
            } @catch (NSException *e) {
                NSLog(@"[LegadoBridge] BookSearch didSelect fail-open: %@", e);
                [[NSString stringWithFormat:@"searchDidSelect exception: %@", e.reason ?: @""]
                    writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_select.txt"]
                    atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                handled = YES; // 异常也不回原生
            }
            // 搜索页默认不调原生（历史点书回桌面根因）；仅非字典/空行才兜底
            if (!handled) {
                [[NSString stringWithFormat:@"searchDidSelect noItem skipNative row=%ld",
                  (long)(ip ? ip.row : -1)]
                    writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_select.txt"]
                    atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                if (tv && ip) {
                    @try { [tv deselectRowAtIndexPath:ip animated:YES]; } @catch (__unused NSException *e) {}
                }
            }
            (void)prev;
        });
        method_setImplementation(m, hook);
        [sSearchSelHooked addObject:key];
        NSLog(@"[LegadoBridge] hooked BookSearch didSelect @%@", NSStringFromClass(owner));
    }
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
        LBReloadLegadoCatalogListIfVisible();
        // nativeRead 深链：目录一到立刻点章（不等固定延迟）
        if (sDeferredNativeOpenIdx >= 0 &&
            (sDeferredNativeOpenBookUrl.length == 0 ||
             [sDeferredNativeOpenBookUrl isEqualToString:bookUrl])) {
            NSInteger useIdx = sDeferredNativeOpenIdx;
            if (useIdx >= (NSInteger)chapters.count) useIdx = 0;
            sDeferredNativeOpenIdx = -1;
            dispatch_async(dispatch_get_main_queue(), ^{
                LBOpenLegadoChapterAtIndex(useIdx);
            });
        }
    } @catch (NSException *e) {
        NSLog(@"[LegadoBridge] LBApplyCatalogToUI fail-open: %@", e);
        LBCatalogWriteMarker([NSString stringWithFormat:@"uiInject fail: %@", e.reason ?: @""]);
    }
}

void LBHandleCatalogRequest(NSString *bookUrl, NSString *sourceUrl) {
    if (sourceUrl.length > 0) {
        sPendingCatalogSourceUrl = [sourceUrl copy];
    }
    if (sPendingCatalogSourceName.length == 0) {
        sPendingCatalogSourceName = @"本地静态测试源";
    }
    if (sPendingCatalogSourceUrl.length == 0) {
        sPendingCatalogSourceUrl = @"http://192.168.1.4:8765";
    }
    Class coreClass = NSClassFromString(@"LegadoBridge.LegadoBridgeCore");
    if (!coreClass) return;
    id core = [coreClass performSelector:@selector(shared)];
    ((void (*)(id, SEL, NSString *, NSString *))objc_msgSend)(
        core, @selector(handleCatalogRequestWithBookUrl:sourceUrl:), bookUrl ?: @"", sourceUrl
    );
}

void LBOpenNativeChapterAtIndex(NSString *bookUrl, NSString *sourceUrl, NSInteger idx) {
    if (bookUrl.length == 0) return;
    NSString *bu = [bookUrl copy];
    NSString *su = [sourceUrl copy];
    NSInteger wantIdx = idx < 0 ? 0 : idx;
    sDeferredNativeOpenIdx = wantIdx;
    sDeferredNativeOpenBookUrl = bu;
    [[NSString stringWithFormat:@"nativeOpenRequest book=%@ src=%@ idx=%ld",
      bu, su ?: @"", (long)wantIdx]
        writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_nativeread_request.txt"]
        atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    LBInstallCatalogUIAppearFlush();
    // 若目录已在 pending，立刻点章
    if (sPendingCatalogChapters.count > 0 &&
        (sPendingCatalogBookUrl.length == 0 || [sPendingCatalogBookUrl isEqualToString:bu])) {
        NSInteger useIdx = wantIdx;
        if (useIdx >= (NSInteger)sPendingCatalogChapters.count) useIdx = 0;
        sDeferredNativeOpenIdx = -1;
        LBOpenLegadoChapterAtIndex(useIdx);
        return;
    }
    LBHandleCatalogRequest(bu, su);
    // 目录异步返回后由 LBApplyCatalogToUI 触发；多档延迟兜底
    void (^tryOpen)(NSString *) = ^(NSString *phase) {
        if (sDeferredNativeOpenIdx < 0) return;
        if (sPendingCatalogChapters.count == 0) {
            NSString *miss = [NSString stringWithFormat:@"nativeOpen wait %@ pending=0 book=%@",
                              phase, bu];
            [miss writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_catalog_openreader.txt"]
                     atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            return;
        }
        if (sDeferredNativeOpenBookUrl.length > 0 &&
            sPendingCatalogBookUrl.length > 0 &&
            ![sDeferredNativeOpenBookUrl isEqualToString:sPendingCatalogBookUrl]) {
            return;
        }
        NSInteger useIdx = sDeferredNativeOpenIdx;
        if (useIdx >= (NSInteger)sPendingCatalogChapters.count) useIdx = 0;
        sDeferredNativeOpenIdx = -1;
        LBOpenLegadoChapterAtIndex(useIdx);
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ tryOpen(@"0.8"); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ tryOpen(@"2.0"); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ tryOpen(@"4.0"); });
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
