#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreText/CoreText.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>
#import <signal.h>
#import <fcntl.h>
#import <unistd.h>
#import <dlfcn.h>
#import "LegadoBridge.h"
#import "LBInternal.h"
#import "LBLoadCurCpBridge.h"

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
    LBSetBookSearchUserIntent(YES);

    // 指定 sourceUrl 时直调引擎（保留筛选）；startSearch 共存 Hook 会把 sourceUrl 丢掉并搜全源
    if (sourceUrl.length > 0) {
        NSString *marker = [NSString stringWithFormat:@"triggerMixed directHandle key=%@ src=%@",
                            kw, sourceUrl];
        [marker writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_trigger.txt"]
                 atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        LBHandleSearchRequest(kw, sourceUrl);
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

static BOOL LBVCIsBookShelfContext(id selfObj);
static IMP LBForwardTableRowsIMP(void);
static IMP LBForwardTableCellIMP(void);
static void LBInstallHookOnClassOnly(Class targetCls, SEL sel, IMP hookImp, IMP *inoutOrig);
static NSInteger LBHookedNumberOfRows(id self, SEL _cmd, UITableView *tv, NSInteger section);
static UITableViewCell *LBHookedCellForRow(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip);
static NSInteger LBHookedCatalogNumberOfRows(id self, SEL _cmd, UITableView *tv, NSInteger section);
static UITableViewCell *LBHookedCatalogCellForRow(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip);

static void LBSetSearchKeywordOnVC(UIViewController *vc, NSString *keyword);
static NSArray<UIWindow *> *LBAllAppWindows(void);
static UINavigationController *LBFindBestNavigationController(UIViewController *from);
static BOOL LBEnsureBookSearchVCPresented(NSString *keyword);
NSString *LBDecodeCoverURL(NSString *url, NSString *sourceUrl);

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
    // AK：非主线程禁止任何 windows API（含 UIApplication.windows / keyWindow / scene）
    if (![NSThread isMainThread]) {
        NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_ab_probe.txt"];
        UIWindow *key = LBLegadoKeyWindow(); // 仅弱缓存 / nil，内部已打 ak_bg_windows_api_skip
        NSString *line = [NSString stringWithFormat:
                          @"%@ | hypothesis_AK ak_bg_windows_api_skip caller=LBAllAppWindows cached=%d\n",
                          [NSDate date], key ? 1 : 0];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        } else {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh synchronizeFile];
            [fh closeFile];
        }
        if (key) [wins addObject:key];
        return wins;
    }
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

static BOOL LBArrayHasLegadoBooks(id cur);
static BOOL LBArrayLooksLikeNativeBooks(id cur);
static BOOL LBDictLooksLikeNativeBook(NSDictionary *d);
static IMP sOrigHeightForRow = NULL;
static IMP sOrigPlazaDidSelect = NULL;
static IMP sTruePlainDidSelect = NULL;
static void LBHookedPlazaDidSelect(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip);

static CGFloat LBHookedHeightForRow(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    @try {
        id cur = [self valueForKey:@"arrBaseData"];
        BOOL forceBookH = NO;
        if ([cur isKindOfClass:[NSArray class]] && [cur count] > 0) {
            if (LBArrayHasLegadoBooks(cur) ||
                (LBIsDiscoverTabActive() && tv.dataSource == self &&
                 (!LBIsDiscoverNativeXBSMode() || LBArrayLooksLikeNativeBooks(cur)))) {
                forceBookH = !LBIsDiscoverNativeXBSMode() || LBArrayLooksLikeNativeBooks(cur);
            }
        }
        if (forceBookH) return 108.0;
    } @catch (__unused NSException *e) {}
    if (sOrigHeightForRow) {
        return ((CGFloat (*)(id, SEL, UITableView *, NSIndexPath *))sOrigHeightForRow)(self, _cmd, tv, ip);
    }
    return 88.0;
}

static void LBEnsurePlazaTableDataSourceMethods(Class cls) {
    if (!cls) return;
    SEL rowsSel = @selector(tableView:numberOfRowsInSection:);
    SEL cellSel = @selector(tableView:cellForRowAtIndexPath:);
    SEL hSel = @selector(tableView:heightForRowAtIndexPath:);
    SEL didSel = @selector(tableView:didSelectRowAtIndexPath:);
    Method rowsM = class_getInstanceMethod(cls, rowsSel);
    if (!rowsM) {
        class_addMethod(cls, rowsSel, (IMP)LBHookedNumberOfRows, "q@:@q");
    } else if (method_getImplementation(rowsM) != (IMP)LBHookedNumberOfRows) {
        LBInstallHookOnClassOnly(cls, rowsSel, (IMP)LBHookedNumberOfRows, &sOrigNumberOfRows);
    }
    Method cellM = class_getInstanceMethod(cls, cellSel);
    if (!cellM) {
        class_addMethod(cls, cellSel, (IMP)LBHookedCellForRow, "@@:@@");
    } else if (method_getImplementation(cellM) != (IMP)LBHookedCellForRow) {
        LBInstallHookOnClassOnly(cls, cellSel, (IMP)LBHookedCellForRow, &sOrigCellForRow);
    }
    // 强制挂 height：原生常对 NSDictionary 回 0 → 全黑无行
    Method hM = class_getInstanceMethod(cls, hSel);
    if (!hM) {
        class_addMethod(cls, hSel, (IMP)LBHookedHeightForRow, "d@:@@");
    } else if (method_getImplementation(hM) != (IMP)LBHookedHeightForRow) {
        LBInstallHookOnClassOnly(cls, hSel, (IMP)LBHookedHeightForRow, &sOrigHeightForRow);
    }
    // B-06：BookListCon 常无 didSelect，点书无响应；无则 class_add，有则 hook
    Method didM = class_getInstanceMethod(cls, didSel);
    if (!didM) {
        class_addMethod(cls, didSel, (IMP)LBHookedPlazaDidSelect, "v@:@@");
    } else if (method_getImplementation(didM) != (IMP)LBHookedPlazaDidSelect) {
        LBInstallHookOnClassOnly(cls, didSel, (IMP)LBHookedPlazaDidSelect, &sOrigPlazaDidSelect);
    }
}

void LBEnsurePlazaListTableHooks(Class cls) {
    LBEnsurePlazaTableDataSourceMethods(cls);
    // 确保搜索/广场 didSelect 旁路已挂（点书进目录）
    LBInstallCatalogUIAppearFlush();
}

static void LBMergeBookIntoSearchVC(UIViewController *vc, NSDictionary *book, NSString *keyword) {
    if (![book isKindOfClass:[NSDictionary class]] || book.count == 0) return;
    if (LBIsDiscoverTabActive()) {
        NSString *cn = NSStringFromClass([vc class]);
        if ([cn containsString:@"BookWorld"] || [cn containsString:@"BookStore"] ||
            [cn containsString:@"Shudan"]) {
            LBRemoveDiscoverOverlays(vc);
            UIViewController *child = LBActiveDiscoverListVC(vc);
            if (child) vc = child;
        }
    }
    // 对齐原生 BookListCon 字段：desc/introduce/cover，避免原生 cell 只出灰封面位
    NSMutableDictionary *norm = [book mutableCopy];
    NSString *intro = nil;
    for (NSString *k in @[@"desc", @"introduce", @"intro", @"bookIntro", @"blurb"]) {
        id v = norm[k];
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) { intro = v; break; }
    }
    if (intro.length > 0) {
        if (![norm[@"desc"] isKindOfClass:[NSString class]] || [norm[@"desc"] length] == 0) {
            norm[@"desc"] = intro;
        }
        if (![norm[@"introduce"] isKindOfClass:[NSString class]] || [norm[@"introduce"] length] == 0) {
            norm[@"introduce"] = intro;
        }
    }
    NSString *cover = nil;
    for (NSString *k in @[@"coverUrl", @"cover", @"imgUrl", @"imageUrl", @"bookCover"]) {
        id v = norm[k];
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) { cover = v; break; }
    }
    if (cover.length > 0) {
        norm[@"coverUrl"] = cover;
        if (![norm[@"cover"] isKindOfClass:[NSString class]] || [norm[@"cover"] length] == 0) {
            norm[@"cover"] = cover;
        }
        if (![norm[@"imgUrl"] isKindOfClass:[NSString class]] || [norm[@"imgUrl"] length] == 0) {
            norm[@"imgUrl"] = cover;
        }
    }
    if (![norm[@"bookName"] isKindOfClass:[NSString class]] || [norm[@"bookName"] length] == 0) {
        id n = norm[@"name"] ?: norm[@"title"];
        if ([n isKindOfClass:[NSString class]]) norm[@"bookName"] = n;
    }
    book = norm;
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
    @try { [vc setValue:arrBase forKey:@"itemList"]; } @catch (__unused NSException *e) {}

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
        UITableView *tv = nil;
        for (NSString *k in @[@"tableView", @"tv", @"listTableView", @"mainTableView", @"myTableView"]) {
            @try {
                id v = [vc valueForKey:k];
                if ([v isKindOfClass:[UITableView class]]) { tv = (UITableView *)v; break; }
            } @catch (__unused NSException *e) {}
        }
        NSString *vcn = NSStringFromClass([vc class]);
        BOOL plazaHost = [vcn containsString:@"BookList"]
            || [vcn containsString:@"BookWorld"]
            || [vcn containsString:@"BookStore"]
            || [vcn containsString:@"Shudan"];
        // 发现态：灌入 createCons 子页，禁止 Bridge overlay 表
        UIViewController *feedVC = vc;
        if (plazaHost && LBIsDiscoverTabActive()) {
            LBRemoveDiscoverOverlays(vc);
            UIViewController *child = LBActiveDiscoverListVC(vc);
            if (child) feedVC = child;
        }
        // 广场壳常把表藏在子视图；跳过 tag LBPV/LBKB 历史 overlay
        if (!tv && feedVC.isViewLoaded && feedVC.view) {
            NSMutableArray *q = [NSMutableArray arrayWithObject:feedVC.view];
            NSMutableArray *walk = [NSMutableArray array];
            NSInteger depthBudget = 80;
            while (q.count > 0 && depthBudget-- > 0) {
                UIView *cur = q.firstObject;
                [q removeObjectAtIndex:0];
                [walk addObject:NSStringFromClass([cur class])];
                if (cur.tag == 0x4C425056 || cur.tag == 0x4C424B42) continue;
                if ([cur isKindOfClass:[UITableView class]]) {
                    tv = (UITableView *)cur;
                    break;
                }
                for (UIView *sub in cur.subviews) [q addObject:sub];
            }
            if (!tv && plazaHost && LBIsDiscoverTabActive()) {
                NSString *walkLine = [NSString stringWithFormat:@"plazaWalk native host=%@ feed=%@ n=%lu %@",
                                      vcn, NSStringFromClass([feedVC class]), (unsigned long)walk.count,
                                      [[walk subarrayWithRange:NSMakeRange(0, MIN(walk.count, 40u))]
                                       componentsJoinedByString:@">"]];
                [walkLine writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_plaza_viewwalk.txt"]
                           atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            }
        }
        if ([tv isKindOfClass:[UITableView class]]) {
            id ds = tv.dataSource;
            NSString *dsCls = ds ? NSStringFromClass([ds class]) : @"(nil)";
            // 发现态：Legado 书进原生 cell 常黑底无字；有灌书时改挂安全 DS
            BOOL discoverList = LBIsDiscoverTabActive() && plazaHost;
            BOOL nativeXBS = LBIsDiscoverNativeXBSMode() && discoverList;
            BOOL brokenDS = (ds == nil) || [dsCls containsString:@"FilteredDataSource"];
            NSUInteger preArrN = 0;
            @try {
                id cur = [feedVC valueForKey:@"arrBaseData"];
                if ([cur isKindOfClass:[NSArray class]]) preArrN = [cur count];
            } @catch (__unused NSException *e) {}
            // 纯 XBS：禁止强夺 DS / 行高（原生标签墙+拉书链依赖宿主 DS）
            BOOL needOwnDS = !nativeXBS &&
                (brokenDS || (!discoverList && ds != (id)feedVC)
                 || (discoverList && preArrN > 0));
            if (nativeXBS) {
                // 纯 XBS 发现：完全不要动表（reload/pin/bringFront 会卡在「正在刷新」）
                NSString *diag = [NSString stringWithFormat:
                    @"uiInject XBS skipMutate ds=%@ arr=%lu host=%@ feed=%@ tv=%@",
                    dsCls, (unsigned long)preArrN, vcn,
                    NSStringFromClass([feedVC class]), NSStringFromClass([tv class])];
                [diag writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_ui_ds.txt"]
                       atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            } else if (needOwnDS) {
                LBEnsurePlazaTableDataSourceMethods([feedVC class]);
                tv.dataSource = (id<UITableViewDataSource>)feedVC;
                tv.delegate = (id<UITableViewDelegate>)feedVC;
            }
            if (!nativeXBS) {
            @try {
                tv.hidden = NO;
                tv.alpha = 1;
                if (tv.backgroundColor == nil ||
                    [tv.backgroundColor isEqual:[UIColor blackColor]] ||
                    [tv.backgroundColor isEqual:[UIColor colorWithWhite:0.08 alpha:1]]) {
                    tv.backgroundColor = [UIColor whiteColor];
                }
                if (needOwnDS || discoverList) {
                    tv.rowHeight = 108;
                    tv.estimatedRowHeight = 108;
                    tv.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
                    tv.separatorColor = [UIColor colorWithWhite:0.90 alpha:1];
                }
                [tv reloadData];
                @try {
                    [tv layoutIfNeeded];
                    if (tv.superview) [tv.superview bringSubviewToFront:tv];
                    // 叠表置顶后勿盖住分类 hit
                    if (discoverList) {
                        UIViewController *dxHost = nil;
                        for (UIViewController *h in (LBFindDiscoverHostVCs() ?: @[])) {
                            dxHost = h; break;
                        }
                        if (dxHost) LBBringDiscoverKindHitFront(dxHost);
                    }
                    [tv setContentOffset:CGPointZero animated:NO];
                } @catch (__unused NSException *e) {}
            } @catch (NSException *ex) {
                NSString *line = [NSString stringWithFormat:@"reloadData EX %@ %@",
                                  vcn, ex.reason ?: @""];
                [line writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_ui_cell_ex.txt"]
                        atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                // 原生 cell 崩：再挂安全 DS（仅此时）
                LBEnsurePlazaTableDataSourceMethods([feedVC class]);
                tv.dataSource = (id<UITableViewDataSource>)feedVC;
                tv.delegate = (id<UITableViewDelegate>)feedVC;
                @try { [tv reloadData]; } @catch (__unused NSException *e2) {}
            }
            if (discoverList) {
                UIViewController *host = nil;
                for (UIViewController *h in (LBFindDiscoverHostVCs() ?: @[])) {
                    host = h; break;
                }
                if (host) {
                    LBPinDiscoverContentToFirstPage(host);
                    LBReloadDiscoverNativeList(host);
                }
            }
            NSInteger rows = 0;
            @try {
                if ([tv.dataSource respondsToSelector:@selector(tableView:numberOfRowsInSection:)]) {
                    rows = [tv.dataSource tableView:tv numberOfRowsInSection:0];
                }
            } @catch (__unused NSException *e) {}
            NSUInteger arrN = preArrN;
            @try {
                id cur = [feedVC valueForKey:@"arrBaseData"];
                if ([cur isKindOfClass:[NSArray class]]) arrN = [cur count];
            } @catch (__unused NSException *e) {}
            // 有书无行：强制自有 DS 重载（纯 XBS 不碰，交给原生）
            if (arrN > 0 && rows == 0) {
                LBEnsurePlazaTableDataSourceMethods([feedVC class]);
                tv.dataSource = (id<UITableViewDataSource>)feedVC;
                tv.delegate = (id<UITableViewDelegate>)feedVC;
                tv.rowHeight = 108;
                @try { [tv reloadData]; } @catch (__unused NSException *e) {}
                @try {
                    rows = [tv.dataSource tableView:tv numberOfRowsInSection:0];
                } @catch (__unused NSException *e) {}
            }
            NSInteger vis = 0;
            CGFloat csh = 0;
            @try {
                vis = (NSInteger)tv.visibleCells.count;
                csh = tv.contentSize.height;
            } @catch (__unused NSException *e) {}
            NSString *diag = [NSString stringWithFormat:
                @"uiInject ds=%@ rows=%ld arr=%lu needOwn=%d vis=%ld csh=%.0f host=%@ feed=%@ tv=%@ tag=%ld frame=%.0fx%.0f@%.0f,%.0f",
                dsCls, (long)rows, (unsigned long)arrN, needOwnDS ? 1 : 0,
                (long)vis, csh, vcn,
                NSStringFromClass([feedVC class]), NSStringFromClass([tv class]), (long)tv.tag,
                tv.frame.size.width, tv.frame.size.height, tv.frame.origin.x, tv.frame.origin.y];
            [diag writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_ui_ds.txt"]
                     atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            } // !nativeXBS
        } else if (plazaHost && LBIsDiscoverTabActive()) {
            if (LBIsDiscoverNativeXBSMode()) {
                [@"uiInject XBS noTV skipEnsure"
                    writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_ui_ds.txt"]
                    atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            } else {
            for (UIViewController *h in (LBFindDiscoverHostVCs() ?: @[])) {
                UITableView *ensured = LBEnsureDiscoverListSurface(h);
                if (ensured) {
                    LBEnsurePlazaListTableHooks([feedVC class]);
                    if (!ensured.dataSource) {
                        ensured.dataSource = (id<UITableViewDataSource>)feedVC;
                        ensured.delegate = (id<UITableViewDelegate>)feedVC;
                    }
                    @try { [ensured reloadData]; } @catch (__unused NSException *e) {}
                    tv = ensured;
                }
                LBReloadDiscoverNativeList(h);
            }
            NSString *diag = [NSString stringWithFormat:@"uiInject no UITableView native host=%@ feed=%@ ensured=%d",
                              vcn, NSStringFromClass([feedVC class]), tv ? 1 : 0];
            [diag writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_ui_ds.txt"]
                     atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            }
        } else {
            NSString *diag = [NSString stringWithFormat:@"uiInject no UITableView host=%@", vcn];
            [diag writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_ui_ds.txt"]
                     atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        }
    } @catch (__unused NSException *e) {}
}

static void LBReapplyLastSearchBooks(void) {
    if (sLastAppliedSearchBooks.count == 0) return;
    if (LBIsDiscoverNativeXBSMode()) {
        [@"uiInject reapply skip (native XBS mode)"
            writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_ui_inject.txt"]
            atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return;
    }
    NSMutableArray *vcs = [NSMutableArray array];
    [vcs addObjectsFromArray:LBFindBookSearchVCs() ?: @[]];
    if (LBIsDiscoverTabActive()) {
        for (id h in (LBFindDiscoverHostVCs() ?: @[])) {
            if (![vcs containsObject:h]) [vcs addObject:h];
        }
    }
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

/// BookListCon 原生 cell 期望书单模型；Legado 灌的是搜索字典 → 直接走安全 cell，避免 reload SIGABRT
static BOOL LBArrayHasLegadoBooks(id cur) {
    if (![cur isKindOfClass:[NSArray class]]) return NO;
    for (id item in (NSArray *)cur) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        if (item[@"legadoBridge"] || item[@"fromLegadoBridge"]) return YES;
    }
    return NO;
}

/// 原生 XBS 书行（有 bookUrl / 书名+作者）；分类标签通常只有 title/name
static BOOL LBDictLooksLikeNativeBook(NSDictionary *d) {
    if (![d isKindOfClass:[NSDictionary class]] || d.count == 0) return NO;
    if (d[@"legadoBridge"] || d[@"fromLegadoBridge"]) return YES;
    id bu = d[@"bookUrl"] ?: d[@"url"];
    if ([bu isKindOfClass:[NSString class]] && [(NSString *)bu length] > 8) {
        NSString *s = (NSString *)bu;
        if ([s hasPrefix:@"http"] || [s containsString:@"://"] || [s containsString:@"/"]) return YES;
    }
    id bn = d[@"bookName"] ?: d[@"name"];
    id author = d[@"author"];
    if ([bn isKindOfClass:[NSString class]] && [(NSString *)bn length] > 0 &&
        [author isKindOfClass:[NSString class]] && [(NSString *)author length] > 0) {
        return YES;
    }
    if (d[@"coverUrl"] || d[@"cover"] || d[@"img"]) {
        if ([bn isKindOfClass:[NSString class]] && [(NSString *)bn length] > 0) return YES;
    }
    return NO;
}

static BOOL LBArrayLooksLikeNativeBooks(id cur) {
    if (![cur isKindOfClass:[NSArray class]] || [(NSArray *)cur count] == 0) return NO;
    NSInteger checked = 0, books = 0;
    for (id item in (NSArray *)cur) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        checked++;
        if (LBDictLooksLikeNativeBook((NSDictionary *)item)) books++;
        if (checked >= 8) break;
    }
    return checked > 0 && books * 2 >= checked; // 过半像书
}

/// 发现页原生封面 cell：左封面 + 右标题/作者/简介
static NSCache *LBDiscoverCoverCache(void) {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 120;
    });
    return cache;
}

static void LBLoadDiscoverCover(UIImageView *iv, NSString *urlStr, NSString *token) {
    if (urlStr.length == 0) return;
    UIImage *hit = [LBDiscoverCoverCache() objectForKey:urlStr];
    if (hit) {
        iv.image = hit;
        return;
    }
    NSURL *u = [NSURL URLWithString:urlStr];
    if (!u || u.scheme.length == 0) {
        // 相对路径：相对 source / book 域名
        return;
    }
    __weak UIImageView *weakIV = iv;
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = 12;
    NSMutableDictionary *headers = [@{
        @"User-Agent": @"Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15",
        @"Accept": @"image/*,*/*;q=0.8"
    } mutableCopy];
    // 部分站防盗链：带上站点 Referer
    if (u.host.length > 0 && u.scheme.length > 0) {
        headers[@"Referer"] = [NSString stringWithFormat:@"%@://%@/", u.scheme, u.host];
    }
    cfg.HTTPAdditionalHeaders = headers;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
    NSURLSessionDataTask *t = [session
        dataTaskWithURL:u
      completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (!data || err) return;
        UIImage *img = [UIImage imageWithData:data];
        if (!img) return;
        [LBDiscoverCoverCache() setObject:img forKey:urlStr];
        dispatch_async(dispatch_get_main_queue(), ^{
            UIImageView *strongIV = weakIV;
            if (!strongIV) return;
            NSString *cur = objc_getAssociatedObject(strongIV, "lbCoverToken");
            if (token.length && cur.length && ![cur isEqualToString:token]) return;
            strongIV.image = img;
            // 有封面时藏「暂无封面」字
            UILabel *ph = (UILabel *)[strongIV viewWithTag:9105];
            if (ph) ph.hidden = YES;
        });
    }];
    [t resume];
}

static NSString *LBAbsoluteCoverURL(NSDictionary *book) {
    NSString *coverUrl = nil;
    for (NSString *k in @[@"coverUrl", @"cover", @"imgUrl", @"imageUrl", @"bookCover"]) {
        id v = book[k];
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) {
            coverUrl = v;
            break;
        }
    }
    if (coverUrl.length == 0) return @"";
    NSString *sourceUrl = nil;
    for (NSString *k in @[@"sourceUrl"]) {
        id v = book[k];
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) {
            sourceUrl = v;
            break;
        }
    }
    // 普通 http(s)/data 保持原样，避免搜索列表刷封面时频繁拉起 Core/JS；
    // 仅 cipher: 或源 JSON 含 coverDecodeJs 时才解密。
    BOOL maybeEncoded = [coverUrl hasPrefix:@"cipher:"];
    if (!maybeEncoded && sourceUrl.length > 0) {
        Class coreClass = NSClassFromString(@"LegadoBridge.LegadoBridgeCore");
        id core = coreClass ? [coreClass performSelector:@selector(shared)] : nil;
        if (core && [core respondsToSelector:@selector(sourceJSON:)]) {
            NSString *json = ((NSString *(*)(id, SEL, NSString *))objc_msgSend)(
                core, @selector(sourceJSON:), sourceUrl);
            if ([json isKindOfClass:[NSString class]] &&
                [json rangeOfString:@"coverDecodeJs"].location != NSNotFound) {
                maybeEncoded = YES;
            }
        }
    }
    if ([coverUrl hasPrefix:@"http://"] || [coverUrl hasPrefix:@"https://"] ||
        [coverUrl hasPrefix:@"data:"] || [coverUrl hasPrefix:@"cipher:"]) {
        if (maybeEncoded) {
            return LBDecodeCoverURL(coverUrl, sourceUrl) ?: coverUrl;
        }
        if (![coverUrl hasPrefix:@"cipher:"]) {
            return coverUrl;
        }
        return LBDecodeCoverURL(coverUrl, sourceUrl) ?: coverUrl;
    }
    NSString *base = nil;
    for (NSString *k in @[@"sourceUrl", @"bookUrl", @"url"]) {
        id v = book[k];
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) {
            base = v;
            break;
        }
    }
    if (base.length == 0) {
        return maybeEncoded ? (LBDecodeCoverURL(coverUrl, sourceUrl) ?: coverUrl) : coverUrl;
    }
    NSURL *bu = [NSURL URLWithString:base];
    if (!bu) {
        return maybeEncoded ? (LBDecodeCoverURL(coverUrl, sourceUrl) ?: coverUrl) : coverUrl;
    }
    // 只要站点根：scheme://host
    if (bu.host.length > 0 && bu.scheme.length > 0) {
        NSString *root = [NSString stringWithFormat:@"%@://%@", bu.scheme, bu.host];
        if ([coverUrl hasPrefix:@"//"]) {
            coverUrl = [NSString stringWithFormat:@"%@:%@", bu.scheme, coverUrl];
        } else if ([coverUrl hasPrefix:@"/"]) {
            coverUrl = [root stringByAppendingString:coverUrl];
        } else {
            NSURL *abs = [NSURL URLWithString:coverUrl relativeToURL:bu];
            coverUrl = abs.absoluteString ?: coverUrl;
        }
    }
    return maybeEncoded ? (LBDecodeCoverURL(coverUrl, sourceUrl) ?: coverUrl) : coverUrl;
}

static BOOL LBPushLegadoBookDetailFromSearch(id searchVC, NSDictionary *bookDic);
static BOOL LBItemLooksLikeChapter(id item);

static char kLBDiscBookKey;
static char kLBDiscHostKey;

@interface LBDiscoverBookTapProxy : NSObject
@end
@implementation LBDiscoverBookTapProxy
- (void)openBook:(UIButton *)sender {
    NSDictionary *book = objc_getAssociatedObject(sender, &kLBDiscBookKey);
    UIViewController *host = objc_getAssociatedObject(sender, &kLBDiscHostKey);
    if (![book isKindOfClass:[NSDictionary class]]) return;
    if (![host isKindOfClass:[UIViewController class]]) {
        NSArray *hosts = LBFindDiscoverHostVCs() ?: @[];
        host = hosts.firstObject;
    }
    if (!host) return;
    NSString *line = [NSString stringWithFormat:@"discoverTapOpen book=%@",
                      book[@"bookName"] ?: book[@"name"] ?: @"?"];
    [line writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_select.txt"]
           atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    LBPushLegadoBookDetailFromSearch(host, book);
}
@end

static LBDiscoverBookTapProxy *LBDiscoverBookTapProxyShared(void) {
    static LBDiscoverBookTapProxy *p;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ p = [LBDiscoverBookTapProxy new]; });
    return p;
}

static UIViewController *LBDiscoverOpenHostForList(id listOrSelf) {
    NSArray *hosts = LBFindDiscoverHostVCs() ?: @[];
    if (hosts.count > 0) return hosts.firstObject;
    if ([listOrSelf isKindOfClass:[UIViewController class]]) {
        UIViewController *vc = (UIViewController *)listOrSelf;
        if (vc.navigationController) return vc;
        UIViewController *p = vc.parentViewController;
        while (p) {
            if (p.navigationController) return p;
            p = p.parentViewController;
        }
        return vc;
    }
    return nil;
}

static BOOL LBTryOpenLegadoBookFromPlaza(id listVC, NSDictionary *book, NSString *via) {
    if (![book isKindOfClass:[NSDictionary class]]) return NO;
    if (LBItemLooksLikeChapter(book)) return NO;
    id bu = book[@"bookUrl"] ?: book[@"url"];
    if (![bu isKindOfClass:[NSString class]] || [(NSString *)bu length] == 0) return NO;
    UIViewController *host = LBDiscoverOpenHostForList(listVC);
    if (!host) host = [listVC isKindOfClass:[UIViewController class]] ? listVC : nil;
    if (!host) return NO;
    NSString *mark = [NSString stringWithFormat:@"plazaOpen via=%@ book=%@ host=%@",
                      via ?: @"?", book[@"bookName"] ?: book[@"name"] ?: bu,
                      NSStringFromClass([host class])];
    [mark writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_select.txt"]
           atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    return LBPushLegadoBookDetailFromSearch(host, book);
}

static void LBHookedPlazaDidSelect(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    (void)_cmd;
    if (LBVCIsBookShelfContext(self)) return;
    if (LBIsDiscoverNativeXBSMode() && LBIsDiscoverTabActive()) {
        if (sOrigPlazaDidSelect) {
            ((void (*)(id, SEL, UITableView *, NSIndexPath *))sOrigPlazaDidSelect)(
                self, _cmd, tv, ip);
        } else if (sTruePlainDidSelect) {
            ((void (*)(id, SEL, UITableView *, NSIndexPath *))sTruePlainDidSelect)(
                self, _cmd, tv, ip);
        }
        return;
    }
    @try {
        id cur = [self valueForKey:@"arrBaseData"];
        if ([cur isKindOfClass:[NSArray class]] && ip &&
            ip.row >= 0 && ip.row < (NSInteger)[(NSArray *)cur count]) {
            id item = [(NSArray *)cur objectAtIndex:(NSUInteger)ip.row];
            if ([item isKindOfClass:[NSDictionary class]] &&
                LBTryOpenLegadoBookFromPlaza(self, (NSDictionary *)item, @"didSelect")) {
                if (tv && ip) {
                    @try { [tv deselectRowAtIndexPath:ip animated:YES]; } @catch (__unused NSException *e) {}
                }
                return;
            }
        }
    } @catch (NSException *e) {
        NSString *ex = [NSString stringWithFormat:@"plazaDidSelect EX %@", e.reason ?: @""];
        [ex writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_select.txt"]
             atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }
}

static UITableViewCell *LBMakeLegadoDiscoverBookCell(UITableView *tv, NSDictionary *book) {
    // 对齐香色原生列表观感：浅底、深字、左封面右标题+副文（字数/最新章）
    static NSString *cid = @"LBDiscoverCoverCellV2";
    const CGFloat kPad = 12, kCoverW = 62, kCoverH = 84;
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cid];
    UIImageView *cover;
    UILabel *title, *sub, *intro, *ph;
    UIColor *bg = [UIColor whiteColor];
    UIColor *titleC = [UIColor colorWithWhite:0.12 alpha:1];
    UIColor *subC = [UIColor colorWithWhite:0.45 alpha:1];
    UIColor *introC = [UIColor colorWithWhite:0.40 alpha:1];
    UIColor *coverBg = [UIColor colorWithWhite:0.92 alpha:1];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:cid];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;

        cover = [[UIImageView alloc] initWithFrame:CGRectMake(kPad, kPad, kCoverW, kCoverH)];
        cover.tag = 9101;
        cover.contentMode = UIViewContentModeScaleAspectFill;
        cover.clipsToBounds = YES;
        cover.layer.cornerRadius = 3;
        cover.backgroundColor = coverBg;
        [cell.contentView addSubview:cover];

        ph = [[UILabel alloc] initWithFrame:cover.bounds];
        ph.tag = 9105;
        ph.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        ph.textAlignment = NSTextAlignmentCenter;
        ph.numberOfLines = 2;
        ph.font = [UIFont systemFontOfSize:11];
        ph.textColor = [UIColor colorWithWhite:0.55 alpha:1];
        ph.text = @"暂无封面";
        [cover addSubview:ph];

        title = [[UILabel alloc] initWithFrame:CGRectZero];
        title.tag = 9102;
        title.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        title.textColor = titleC;
        title.numberOfLines = 1;
        [cell.contentView addSubview:title];

        sub = [[UILabel alloc] initWithFrame:CGRectZero];
        sub.tag = 9103;
        sub.font = [UIFont systemFontOfSize:12];
        sub.textColor = subC;
        sub.numberOfLines = 1;
        [cell.contentView addSubview:sub];

        intro = [[UILabel alloc] initWithFrame:CGRectZero];
        intro.tag = 9104;
        intro.font = [UIFont systemFontOfSize:12];
        intro.textColor = introC;
        intro.numberOfLines = 2;
        [cell.contentView addSubview:intro];
    } else {
        cover = (UIImageView *)[cell.contentView viewWithTag:9101];
        title = (UILabel *)[cell.contentView viewWithTag:9102];
        sub = (UILabel *)[cell.contentView viewWithTag:9103];
        intro = (UILabel *)[cell.contentView viewWithTag:9104];
        ph = (UILabel *)[cover viewWithTag:9105];
        title.textColor = titleC;
        sub.textColor = subC;
        intro.textColor = introC;
        cover.backgroundColor = coverBg;
    }

    CGFloat w = tv.bounds.size.width > 0 ? tv.bounds.size.width : [UIScreen mainScreen].bounds.size.width;
    CGFloat tx = kPad + kCoverW + 10;
    CGFloat tw = MAX(60, w - tx - kPad);
    cover.frame = CGRectMake(kPad, kPad, kCoverW, kCoverH);
    title.frame = CGRectMake(tx, kPad + 2, tw, 20);
    sub.frame = CGRectMake(tx, CGRectGetMaxY(title.frame) + 4, tw, 16);
    intro.frame = CGRectMake(tx, CGRectGetMaxY(sub.frame) + 4, tw, 34);

    NSString *name = book[@"bookName"] ?: book[@"name"] ?: book[@"title"] ?: @"";
    if (![name isKindOfClass:[NSString class]]) name = @"";
    NSString *author = book[@"author"] ?: @"";
    if (![author isKindOfClass:[NSString class]]) author = @"";
    id wc = book[@"wordCount"];
    NSString *wcText = @"";
    if ([wc isKindOfClass:[NSNumber class]]) {
        long long n = [(NSNumber *)wc longLongValue];
        if (n >= 10000) {
            wcText = [NSString stringWithFormat:@"%lld万字", n / 10000];
        } else if (n > 0) {
            wcText = [NSString stringWithFormat:@"%lld字", n];
        }
    } else if ([wc isKindOfClass:[NSString class]] && [(NSString *)wc length] > 0) {
        wcText = (NSString *)wc;
        // 已带「字」则原样
        if ([wcText rangeOfString:@"字"].location == NSNotFound && wcText.longLongValue > 0) {
            long long n = wcText.longLongValue;
            wcText = n >= 10000
                ? [NSString stringWithFormat:@"%lld万字", n / 10000]
                : [NSString stringWithFormat:@"%lld字", n];
        }
    }
    NSString *last = book[@"lastChapter"] ?: book[@"latestChapter"] ?: @"";
    if (![last isKindOfClass:[NSString class]]) last = @"";
    last = [last stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray *bits = [NSMutableArray array];
    if (author.length > 0) [bits addObject:author];
    if (wcText.length > 0) [bits addObject:wcText];
    // 无字数时用最新章凑副文（领域书库列表无 cover/字数）
    if (wcText.length == 0 && last.length > 0) {
        NSString *shortLast = last.length > 18 ? [[last substringToIndex:18] stringByAppendingString:@"…"] : last;
        [bits addObject:shortLast];
    }

    title.text = name;
    sub.text = [bits componentsJoinedByString:@" · "];
    NSString *desc = book[@"intro"] ?: book[@"introduce"] ?: book[@"desc"] ?: @"";
    if (![desc isKindOfClass:[NSString class]]) desc = @"";
    desc = [desc stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (desc.length == 0 && last.length > 0 && wcText.length > 0) {
        desc = [NSString stringWithFormat:@"最新：%@", last];
    }
    intro.text = desc;
    intro.hidden = (desc.length == 0);

    NSString *coverUrl = LBAbsoluteCoverURL(book);
    cover.image = nil;
    if (ph) {
        ph.hidden = NO;
        ph.text = coverUrl.length > 0 ? @"" : @"暂无封面";
        ph.textColor = [UIColor colorWithWhite:0.55 alpha:1];
        if (coverUrl.length > 0) ph.hidden = YES;
    }
    objc_setAssociatedObject(cover, "lbCoverToken", coverUrl, OBJC_ASSOCIATION_COPY_NONATOMIC);
    LBLoadDiscoverCover(cover, coverUrl, coverUrl);

    cell.backgroundColor = bg;
    cell.contentView.backgroundColor = bg;
    UIView *sel = [[UIView alloc] init];
    sel.backgroundColor = [UIColor colorWithWhite:0.94 alpha:1];
    cell.selectedBackgroundView = sel;

    // 透明按钮：坐标点/无障碍常碰不到原生 didSelect（BookListCon 甚至无该方法）
    const NSInteger kOpenTag = 0x4C424F42; // 'LBOB'
    UIButton *openBtn = [cell.contentView viewWithTag:kOpenTag];
    if (![openBtn isKindOfClass:[UIButton class]]) {
        openBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        openBtn.tag = kOpenTag;
        openBtn.backgroundColor = [UIColor clearColor];
        [openBtn addTarget:LBDiscoverBookTapProxyShared()
                    action:@selector(openBook:)
          forControlEvents:UIControlEventTouchUpInside];
        [cell.contentView addSubview:openBtn];
    }
    openBtn.frame = cell.contentView.bounds;
    openBtn.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [cell.contentView bringSubviewToFront:openBtn];
    UIViewController *host = nil;
    id ds = tv.dataSource;
    if ([ds isKindOfClass:[UIViewController class]]) host = (UIViewController *)ds;
    host = LBDiscoverOpenHostForList(host) ?: host;
    objc_setAssociatedObject(openBtn, &kLBDiscBookKey, book, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(openBtn, &kLBDiscHostKey, host, OBJC_ASSOCIATION_ASSIGN);
    NSString *a11y = book[@"bookName"] ?: book[@"name"] ?: @"书";
    if ([a11y isKindOfClass:[NSString class]]) openBtn.accessibilityLabel = (NSString *)a11y;

    return cell;
}

static NSInteger LBHookedNumberOfRows(id self, SEL _cmd, UITableView *tv, NSInteger section) {
    // 书架列表与搜索共用基类时：绝不能走搜索兜底逻辑改行数
    if (LBVCIsBookShelfContext(self)) {
        IMP fwd = LBForwardTableRowsIMP();
        if (fwd) {
            return ((NSInteger (*)(id, SEL, UITableView *, NSInteger))fwd)(self, _cmd, tv, section);
        }
        return 0;
    }
    NSString *cn = NSStringFromClass([self class]);
    BOOL plazaHost = [cn containsString:@"BookList"]
        || [cn containsString:@"BookWorld"]
        || [cn containsString:@"BookStore"]
        || [cn containsString:@"Shudan"];
    @try {
        id cur = [self valueForKey:@"arrBaseData"];
        if (plazaHost && [cur isKindOfClass:[NSArray class]] && tv.dataSource == self) {
            // 纯 XBS：默认交给原生行数（arr 可能是分类标签）。
            // 仅当样本过半像「书」且原生行数为 0 时，才用 arr 兜底出书行。
            if (LBIsDiscoverNativeXBSMode()) {
                // fall through — 下面 orig 后再判断兜底
            } else if (LBIsDiscoverTabActive() || LBArrayHasLegadoBooks(cur)) {
                return (NSInteger)[(NSArray *)cur count];
            }
        }
    } @catch (__unused NSException *e) {}
    NSInteger orig = 0;
    @try {
        if (sOrigNumberOfRows) {
            orig = ((NSInteger (*)(id, SEL, UITableView *, NSInteger))sOrigNumberOfRows)(self, _cmd, tv, section);
        } else {
            IMP fwd = LBForwardTableRowsIMP();
            if (fwd) {
                orig = ((NSInteger (*)(id, SEL, UITableView *, NSInteger))fwd)(self, _cmd, tv, section);
            }
        }
    } @catch (__unused NSException *e) {
        orig = 0;
    }
    if (orig > 0) return orig;
    // 仅当 table 的 dataSource 就是 self 时兜底，避免与 FilteredDataSource 行数不一致崩
    if (tv.dataSource != self) return orig;
    @try {
        id cur = [self valueForKey:@"arrBaseData"];
        if (![cur isKindOfClass:[NSArray class]] || [cur count] == 0) return orig;
        if (LBArrayHasLegadoBooks(cur)) return (NSInteger)[cur count];
        // XBS：原生 rows=0 但 arr 像书 → 兜底出书（历史 arrN=100 空渲染）
        if (plazaHost && LBIsDiscoverNativeXBSMode() && LBIsDiscoverTabActive() &&
            LBArrayLooksLikeNativeBooks(cur)) {
            return (NSInteger)[cur count];
        }
    } @catch (__unused NSException *e) {}
    return orig;
}

static UITableViewCell *LBHookedCellForRow(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    // fail-open：不拦截 cell 渲染，避免越界/类型崩
    if (LBVCIsBookShelfContext(self)) {
        IMP fwd = LBForwardTableCellIMP();
        if (fwd) {
            return ((UITableViewCell * (*)(id, SEL, UITableView *, NSIndexPath *))fwd)(self, _cmd, tv, ip);
        }
        return nil;
    }
    NSString *cn = NSStringFromClass([self class]);
    BOOL plazaHost = [cn containsString:@"BookList"]
        || [cn containsString:@"BookWorld"]
        || [cn containsString:@"BookStore"]
        || [cn containsString:@"Shudan"];
    // 发现/广场：Legado 字典走自造封面 cell（原生 cell 常黑底无字且不抛）
    // XBS：仅当 arr 像书（非分类标签）时用可见 cell 兜底；标签墙交给原生
    if (plazaHost) {
        @try {
            id cur = [self valueForKey:@"arrBaseData"];
            BOOL useLegadoCell =
                (LBArrayHasLegadoBooks(cur) ||
                 (LBIsDiscoverTabActive() &&
                  [cur isKindOfClass:[NSArray class]] && [cur count] > 0 &&
                  tv.dataSource == self &&
                  (!LBIsDiscoverNativeXBSMode() || LBArrayLooksLikeNativeBooks(cur))));
            if (useLegadoCell &&
                [cur isKindOfClass:[NSArray class]] &&
                ip.row >= 0 && ip.row < (NSInteger)[(NSArray *)cur count]) {
                id item = [(NSArray *)cur objectAtIndex:(NSUInteger)ip.row];
                if ([item isKindOfClass:[NSDictionary class]] &&
                    (!LBIsDiscoverNativeXBSMode() || LBDictLooksLikeNativeBook((NSDictionary *)item))) {
                    return LBMakeLegadoDiscoverBookCell(tv, (NSDictionary *)item);
                }
            }
        } @catch (__unused NSException *e) {}
    }
    @try {
        if (sOrigCellForRow) {
            return ((UITableViewCell * (*)(id, SEL, UITableView *, NSIndexPath *))sOrigCellForRow)(self, _cmd, tv, ip);
        }
        IMP fwd = LBForwardTableCellIMP();
        if (fwd) {
            return ((UITableViewCell * (*)(id, SEL, UITableView *, NSIndexPath *))fwd)(self, _cmd, tv, ip);
        }
    } @catch (NSException *ex) {
        @try {
            id cur = [self valueForKey:@"arrBaseData"];
            if ([cur isKindOfClass:[NSArray class]] &&
                ip.row >= 0 && ip.row < (NSInteger)[(NSArray *)cur count]) {
                id item = [(NSArray *)cur objectAtIndex:(NSUInteger)ip.row];
                if ([item isKindOfClass:[NSDictionary class]]) {
                    return LBMakeLegadoDiscoverBookCell(tv, (NSDictionary *)item);
                }
            }
        } @catch (__unused NSException *e2) {}
        NSString *line = [NSString stringWithFormat:@"cellForRow EX %@ %@",
                          cn, ex.reason ?: @""];
        [line writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_ui_cell_ex.txt"]
                atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }
    return [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"LBEmpty"];
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
    // 搜索页 + 原生发现广场壳（World 默认不画搜索字典，走安全 cell）
    for (NSString *cn in @[@"BookSearchVCBase1", @"BookListCon", @"BookListController",
                           @"BookWorldHomeCon", @"BookStoreBaseCon", @"ShudanHomeCon"]) {
        Class cls = NSClassFromString(cn);
        if (!cls) continue;
        // World/Store 是模板壳，类上往往没有 UITableViewDataSource 方法；
        // LBInstallHookOnClassOnly 遇无 Method 会直接 return，必须先 class_addMethod。
        SEL rowsSel = @selector(tableView:numberOfRowsInSection:);
        SEL cellSel = @selector(tableView:cellForRowAtIndexPath:);
        if (!class_getInstanceMethod(cls, rowsSel)) {
            class_addMethod(cls, rowsSel, (IMP)LBHookedNumberOfRows, "q@:@q");
        } else {
            LBInstallHookOnClassOnly(cls, rowsSel, (IMP)LBHookedNumberOfRows, &sOrigNumberOfRows);
        }
        if (!class_getInstanceMethod(cls, cellSel)) {
            class_addMethod(cls, cellSel, (IMP)LBHookedCellForRow, "@@:@@");
        } else {
            LBInstallHookOnClassOnly(cls, cellSel, (IMP)LBHookedCellForRow, &sOrigCellForRow);
        }
    }
}

/// 发现态：只灌原生 BookList/BookWorld，禁止抢 push BookSearch。
static BOOL LBEnsureBookSearchVCPresented(NSString *keyword) {
    if (LBIsDiscoverTabActive() && !LBIsBookSearchUserIntent()) {
        BOOL hostOk = LBEnsureNativeDiscoverHostPresented();
        NSArray *hosts = LBFindDiscoverHostVCs();
        for (UIViewController *vc in hosts) {
            LBSetSearchKeywordOnVC(vc, keyword.length > 0 ? keyword : @"explore");
        }
        NSString *marker = [NSString stringWithFormat:
                            @"ensureSearch discover-native hostOk=%d hosts=%lu key=%@",
                            hostOk ? 1 : 0, (unsigned long)hosts.count, keyword ?: @""];
        [marker writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_ui_inject.txt"]
                 atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        // 宿主刚 push 可能尚未入树：短延迟再 Apply 一次 pending
        if (hostOk) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (sPendingSearchBooks.count > 0) {
                    LBApplySearchResultsToUI([sPendingSearchBooks copy],
                                            keyword.length ? keyword : @"explore");
                } else if (sLastAppliedSearchBooks.count > 0) {
                    LBReapplyLastSearchBooks();
                }
            });
        }
        return hostOk || hosts.count > 0;
    }
    NSArray *existing = LBFindBookSearchVCs();
    for (UIViewController *vc in existing) {
        if (LBVCIsVisibleInWindow(vc)) {
            LBSetSearchKeywordOnVC(vc, keyword);
            return YES;
        }
    }
    Class cls = NSClassFromString(@"BookSearchController");
    if (!cls) cls = NSClassFromString(@"BookSearchVCBase1");
    if (!cls) {
        [@"ensureSearch miss: no BookSearch class"
            writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_ui_inject.txt"]
            atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return NO;
    }
    UIViewController *searchVC = nil;
    @try { searchVC = [[cls alloc] init]; } @catch (__unused NSException *e) { searchVC = nil; }
    if (!searchVC) {
        [@"ensureSearch miss: alloc failed"
            writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_ui_inject.txt"]
            atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return NO;
    }
    LBSetSearchKeywordOnVC(searchVC, keyword.length > 0 ? keyword : @"explore");
    UIWindow *win = LBLegadoKeyWindow();
    UIViewController *root = win.rootViewController;
    while (root.presentedViewController) {
        root = root.presentedViewController;
    }
    UINavigationController *nav = LBFindBestNavigationController(root);
    if (!nav) {
        UIViewController *top = root;
        while (top.presentedViewController) top = top.presentedViewController;
        nav = top.navigationController;
    }
    if (nav) {
        [nav pushViewController:searchVC animated:YES];
        [@"ensureSearch push BookSearchController"
            writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_ui_inject.txt"]
            atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return YES;
    }
    UINavigationController *wrap =
        [[UINavigationController alloc] initWithRootViewController:searchVC];
    wrap.modalPresentationStyle = UIModalPresentationFullScreen;
    [root presentViewController:wrap animated:YES completion:nil];
    [@"ensureSearch present BookSearchController"
        writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_ui_inject.txt"]
        atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    return YES;
}

void LBClearDiscoverExplorePendingOnly(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ LBClearDiscoverExplorePendingOnly(); });
        return;
    }
    @try {
        if (sPendingSearchBooks) [sPendingSearchBooks removeAllObjects];
        if (sLastAppliedSearchBooks) [sLastAppliedSearchBooks removeAllObjects];
        // 只剔除带 Legado 标记的灌书，保留原生 XBS bookWorld 行
        NSArray *hosts = LBFindDiscoverHostVCs() ?: @[];
        for (UIViewController *vc in hosts) {
            NSMutableArray *targets = [NSMutableArray arrayWithObject:vc];
            UIViewController *list = nil;
            @try { list = LBActiveDiscoverListVC(vc); } @catch (__unused NSException *e) {}
            if (list && list != vc) [targets addObject:list];
            for (UIViewController *child in vc.childViewControllers) {
                if (![targets containsObject:child]) [targets addObject:child];
            }
            for (UIViewController *t in targets) {
                for (NSString *key in @[@"arrBaseData", @"itemList", @"arrSearchItems"]) {
                    id arr = nil;
                    @try { arr = [t valueForKey:key]; } @catch (__unused NSException *e) {}
                    if (![arr isKindOfClass:[NSArray class]] || [(NSArray *)arr count] == 0) continue;
                    NSMutableArray *kept = [NSMutableArray array];
                    for (id item in (NSArray *)arr) {
                        if (![item isKindOfClass:[NSDictionary class]]) {
                            [kept addObject:item];
                            continue;
                        }
                        NSDictionary *d = (NSDictionary *)item;
                        if (d[@"legadoBridge"] || d[@"fromLegadoBridge"]) continue;
                        [kept addObject:item];
                    }
                    if (kept.count != [(NSArray *)arr count]) {
                        @try { [t setValue:kept forKey:key]; } @catch (__unused NSException *e) {}
                    }
                }
                UITableView *tv = nil;
                @try { tv = [t valueForKey:@"tableView"]; } @catch (__unused NSException *e) {}
                if ([tv isKindOfClass:[UITableView class]]) {
                    @try { [tv reloadData]; } @catch (__unused NSException *e) {}
                }
            }
        }
        [@"uiInject clear explore pending + strip legado rows"
            writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_ui_inject.txt"]
            atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    } @catch (__unused NSException *e) {}
}

void LBClearDiscoverExploreBooks(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ LBClearDiscoverExploreBooks(); });
        return;
    }
    @try {
        LBClearDiscoverExploreEmptyHint();
        // 用户正在看纯 XBS 发现：禁止掏空原生 bookWorld 列表
        if (LBIsDiscoverNativeXBSMode()) {
            LBClearDiscoverExplorePendingOnly();
            return;
        }
        if (sPendingSearchBooks) [sPendingSearchBooks removeAllObjects];
        if (sLastAppliedSearchBooks) [sLastAppliedSearchBooks removeAllObjects];
        // 多次 explore 并发时只清一次 UI，避免 inject 后被第二次 clear 打成空屏
        static CFAbsoluteTime sLastClearUIAt = 0;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - sLastClearUIAt < 0.55) {
            [@"uiInject clear discover books (debounce skip UI)"
                writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_ui_inject.txt"]
                atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            return;
        }
        sLastClearUIAt = now;
        NSArray *hosts = LBFindDiscoverHostVCs() ?: @[];
        for (UIViewController *vc in hosts) {
            LBRemoveDiscoverOverlays(vc);
            NSMutableArray *targets = [NSMutableArray arrayWithObject:vc];
            UIViewController *list = nil;
            @try { list = LBActiveDiscoverListVC(vc); } @catch (__unused NSException *e) {}
            if (list && list != vc) [targets addObject:list];
            for (UIViewController *child in vc.childViewControllers) {
                if (![targets containsObject:child]) [targets addObject:child];
            }
            for (UIViewController *t in targets) {
                // 探针：清空原生书列表前记录其数据量（定位「原生源书列表被清」vs「没加载」）
                NSInteger beforeN = -1;
                @try {
                    id a = [t valueForKey:@"arrBaseData"];
                    if ([a isKindOfClass:[NSArray class]]) beforeN = (NSInteger)[(NSArray *)a count];
                } @catch (__unused NSException *e) {}
                NSString *probe = [NSString stringWithFormat:
                                   @"clearProbe class=%@ arrBefore=%ld xbs=%d",
                                   NSStringFromClass([t class]), (long)beforeN,
                                   LBIsDiscoverNativeXBSMode() ? 1 : 0];
                [probe writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_clear_probe.txt"]
                       atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                @try { [t setValue:[NSMutableArray array] forKey:@"arrBaseData"]; } @catch (__unused NSException *e) {}
                @try { [t setValue:[NSMutableArray array] forKey:@"itemList"]; } @catch (__unused NSException *e) {}
                @try { [t setValue:[NSMutableArray array] forKey:@"arrSearchItems"]; } @catch (__unused NSException *e) {}
                @try { [t setValue:[NSMutableDictionary dictionary] forKey:@"dicSearchItems"]; } @catch (__unused NSException *e) {}
                @try { [t setValue:[NSMutableDictionary dictionary] forKey:@"dicAllBookList"]; } @catch (__unused NSException *e) {}
                UITableView *tv = nil;
                @try { tv = [t valueForKey:@"tableView"]; } @catch (__unused NSException *e) {}
                if ([tv isKindOfClass:[UITableView class]]) {
                    @try { [tv reloadData]; } @catch (__unused NSException *e) {}
                }
            }
        }
        [@"uiInject clear discover books"
            writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_ui_inject.txt"]
            atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    } @catch (__unused NSException *e) {}
}

/// explore 超时/失败后摘掉发现页「章节加载中」残留（防 UI 永久挂起）
void LBDismissDiscoverLoadingHUD(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ LBDismissDiscoverLoadingHUD(); });
        return;
    }
    @try {
        NSMutableArray<UIView *> *roots = [NSMutableArray array];
        for (UIWindow *w in UIApplication.sharedApplication.windows) {
            if (w) [roots addObject:w];
        }
        NSArray *hosts = LBFindDiscoverHostVCs() ?: @[];
        for (UIViewController *vc in hosts) {
            @try {
                id v = [vc valueForKey:@"view"];
                if ([v isKindOfClass:[UIView class]]) [roots addObject:v];
            } @catch (__unused NSException *e) {}
            UIViewController *list = nil;
            @try { list = LBActiveDiscoverListVC(vc); } @catch (__unused NSException *e) {}
            if (list && list != vc) {
                @try {
                    id lv = [list valueForKey:@"view"];
                    if ([lv isKindOfClass:[UIView class]]) [roots addObject:lv];
                } @catch (__unused NSException *e) {}
            }
        }
        NSMutableArray<UIView *> *stack = [roots mutableCopy];
        while (stack.count > 0) {
            UIView *cur = stack.lastObject;
            [stack removeLastObject];
            NSString *text = nil;
            if ([cur isKindOfClass:[UILabel class]]) {
                text = [(UILabel *)cur text];
            } else if ([cur respondsToSelector:@selector(text)]) {
                @try {
                    id t = [cur valueForKey:@"text"];
                    if ([t isKindOfClass:[NSString class]]) text = t;
                } @catch (__unused NSException *e) {}
            }
            if ([text isKindOfClass:[NSString class]] && [text containsString:@"章节加载中"]) {
                UIView *victim = cur;
                if (cur.superview.subviews.count <= 4) victim = cur.superview ?: cur;
                if (victim.superview.subviews.count <= 3 && victim.superview != nil &&
                    ![victim.superview isKindOfClass:[UIWindow class]]) {
                    victim = victim.superview;
                }
                [victim removeFromSuperview];
                [@"uiInject dismiss discover loading HUD"
                    writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_ui_inject.txt"]
                    atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                return;
            }
            for (UIView *sub in cur.subviews) {
                [stack addObject:sub];
            }
        }
    } @catch (__unused NSException *e) {}
}

static const NSInteger kLBExploreEmptyHintTag = 0x4C424545; // 'LBEE'

@interface LBExploreEmptyHintActions : NSObject
- (void)openLogin:(id)sender;
@end

@implementation LBExploreEmptyHintActions
- (void)openLogin:(id)sender {
    (void)sender;
    NSString *src = nil;
    id core = LBLegadoCoreIfReady();
    if (core) {
        @try {
            id v = [core valueForKey:@"selectedExploreSourceUrl"];
            if ([v isKindOfClass:[NSString class]]) src = (NSString *)v;
        } @catch (__unused NSException *e) {}
    }
    if (src.length == 0) {
        // 兜底书山
        src = @"https://v1.vossc.com";
    }
    LBPresentLoginUiFormForSource(src);
    [@"explore empty hint openLogin"
        writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_ui_inject.txt"]
        atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}
@end

static LBExploreEmptyHintActions *LBExploreEmptyHintActionsShared(void) {
    static LBExploreEmptyHintActions *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[LBExploreEmptyHintActions alloc] init]; });
    return s;
}

void LBClearDiscoverExploreEmptyHint(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ LBClearDiscoverExploreEmptyHint(); });
        return;
    }
    @try {
        NSArray *hosts = LBFindDiscoverHostVCs() ?: @[];
        for (UIViewController *vc in hosts) {
            if (!vc.isViewLoaded || !vc.view) continue;
            NSMutableArray<UIView *> *doomed = [NSMutableArray array];
            for (UIView *sub in vc.view.subviews) {
                if (sub.tag == kLBExploreEmptyHintTag) [doomed addObject:sub];
            }
            for (UIView *v in doomed) [v removeFromSuperview];
        }
    } @catch (__unused NSException *e) {}
}

/// explore 空/失败：盖住底层 XBS 标签墙，避免「只有分类没有书」被误当成可点标签墙
void LBShowDiscoverExploreEmptyHint(NSString *message) {
    if (![NSThread isMainThread]) {
        NSString *copy = [message copy] ?: @"";
        dispatch_async(dispatch_get_main_queue(), ^{
            LBShowDiscoverExploreEmptyHint(copy);
        });
        return;
    }
    // Legado 空态必须盖墙：即使残留 XBS 标志也强制清掉再画
    if (LBIsDiscoverNativeXBSMode()) {
        LBSetDiscoverNativeXBSMode(NO);
    }
    NSString *text = message.length > 0
        ? message
        : @"暂无书籍（可能需登录，或该分类无内容）";
    BOOL needLogin = [text containsString:@"登录"] || [text containsString:@"session"];
    @try {
        UIViewController *host = nil;
        NSArray *hosts = LBFindDiscoverHostVCs() ?: @[];
        if (hosts.count > 0) host = hosts.firstObject;
        if (!host) {
            [@"explore empty hint skip noHost"
                writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_ui_inject.txt"]
                atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            return;
        }
        if (!host.isViewLoaded || !host.view) {
            [@"explore empty hint skip noView"
                writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_ui_inject.txt"]
                atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            return;
        }
        LBClearDiscoverExploreEmptyHint();

        CGFloat top = 88;
        id title = nil;
        @try { title = [host valueForKey:@"pageTitleView"]; } @catch (__unused NSException *e) {}
        if ([title isKindOfClass:[UIView class]]) {
            CGFloat b = CGRectGetMaxY(((UIView *)title).frame);
            if (b > 40) top = b;
        }
        CGRect hb = host.view.bounds;
        if (hb.size.width < 2) hb = [UIScreen mainScreen].bounds;
        if (hb.size.height < top + 40) {
            NSString *skip = [NSString stringWithFormat:
                              @"explore empty hint skip bounds w=%.0f h=%.0f top=%.0f",
                              hb.size.width, hb.size.height, top];
            [skip writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_ui_inject.txt"]
                   atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            return;
        }
        UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, top, hb.size.width, hb.size.height - top)];
        box.tag = kLBExploreEmptyHintTag;
        box.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        if (@available(iOS 13.0, *)) {
            box.backgroundColor = [UIColor systemBackgroundColor];
        } else {
            box.backgroundColor = [UIColor whiteColor];
        }
        box.userInteractionEnabled = YES; // 挡住底层标签墙误点

        UILabel *lab = [[UILabel alloc] initWithFrame:CGRectZero];
        lab.translatesAutoresizingMaskIntoConstraints = NO;
        lab.text = text;
        lab.textAlignment = NSTextAlignmentCenter;
        lab.numberOfLines = 0;
        lab.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
        if (@available(iOS 13.0, *)) {
            lab.textColor = [UIColor secondaryLabelColor];
        } else {
            lab.textColor = [UIColor darkGrayColor];
        }
        [box addSubview:lab];

        UIButton *loginBtn = nil;
        if (needLogin) {
            loginBtn = [UIButton buttonWithType:UIButtonTypeSystem];
            loginBtn.translatesAutoresizingMaskIntoConstraints = NO;
            [loginBtn setTitle:@"打开书源登录（番茄登录）" forState:UIControlStateNormal];
            loginBtn.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
            [loginBtn addTarget:LBExploreEmptyHintActionsShared()
                         action:@selector(openLogin:)
               forControlEvents:UIControlEventTouchUpInside];
            [box addSubview:loginBtn];
        }

        [NSLayoutConstraint activateConstraints:@[
            [lab.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:24],
            [lab.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-24],
            [lab.centerYAnchor constraintEqualToAnchor:box.centerYAnchor constant:needLogin ? -28 : 0],
        ]];
        if (loginBtn) {
            [NSLayoutConstraint activateConstraints:@[
                [loginBtn.topAnchor constraintEqualToAnchor:lab.bottomAnchor constant:16],
                [loginBtn.centerXAnchor constraintEqualToAnchor:box.centerXAnchor],
            ]];
        }

        [host.view addSubview:box];
        [host.view bringSubviewToFront:box];
        if ([title isKindOfClass:[UIView class]]) {
            [host.view bringSubviewToFront:(UIView *)title];
        }
        NSString *shown = [NSString stringWithFormat:@"explore empty hint shown msg=%@ loginBtn=%d",
                           text, needLogin ? 1 : 0];
        [shown writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_ui_inject.txt"]
                atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    } @catch (__unused NSException *e) {}
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
    // 有书则清掉空态盖层
    LBClearDiscoverExploreEmptyHint();
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

    // explore 结果必须进发现宿主，不能因 sticky 被清/搜索意图抢路由而灌进 BookSearch
    BOOL exploreMode = [keyword isEqualToString:@"explore"]
        || [keyword hasPrefix:@"explore:"]
        || [keyword hasPrefix:@"explore|"];
    // 用户已切到纯 XBS：丢掉迟到的 Legado explore，避免覆盖原生书单
    if (exploreMode && LBIsDiscoverNativeXBSMode()) {
        [@"uiInject skip explore (native XBS mode)"
            writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_ui_inject.txt"]
            atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return;
    }
    if (exploreMode && !LBIsDiscoverTabActive()) {
        LBSetDiscoverTabActive(YES);
    }
    BOOL discoverActive = LBIsDiscoverTabActive() || exploreMode;

    NSArray *vcs = LBFindBookSearchVCs();
    NSArray *discoverHosts = discoverActive ? LBFindDiscoverHostVCs() : @[];
    // 每次 Apply 都 dump，便于对照「空列表」实际持有者
    LBDumpVisibleVCTree();
    if (vcs.count == 0 && discoverHosts.count == 0) {
        BOOL ensured = NO;
        if (exploreMode || discoverActive) {
            ensured = LBEnsureNativeDiscoverHostPresented();
            discoverHosts = LBFindDiscoverHostVCs();
        } else {
            ensured = LBEnsureBookSearchVCPresented(keyword);
            vcs = LBFindBookSearchVCs();
        }
        if (LBIsDiscoverTabActive() || exploreMode) {
            discoverHosts = LBFindDiscoverHostVCs();
            discoverActive = YES;
        }
        if (vcs.count == 0 && discoverHosts.count == 0) {
            NSString *marker = [NSString stringWithFormat:
                                @"uiInject pending n=%lu key=%@ (no BookSearchVC/discoverHost yet ensure=%d discover=%d explore=%d)",
                                (unsigned long)sPendingSearchBooks.count, keyword ?: @"",
                                ensured ? 1 : 0, discoverActive ? 1 : 0, exploreMode ? 1 : 0];
            [marker writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_ui_inject.txt"]
                     atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            return;
        }
    }
    NSMutableArray *targets = [NSMutableArray array];
    if (discoverHosts.count > 0) {
        [targets addObjectsFromArray:discoverHosts];
    }
    // 发现态 / explore 禁止灌 BookSearch（那是搜索页，不是发现）
    if (targets.count == 0 && vcs.count > 0 && !discoverActive) {
        [targets addObjectsFromArray:vcs];
    } else if (discoverHosts.count > 0 && vcs.count > 0 && !discoverActive && !exploreMode) {
        [targets addObjectsFromArray:vcs];
    }
    if (targets.count == 0 && discoverActive) {
        NSString *marker = [NSString stringWithFormat:
                            @"uiInject wait native plaza n=%lu key=%@ (no World yet explore=%d)",
                            (unsigned long)sPendingSearchBooks.count, keyword ?: @"",
                            exploreMode ? 1 : 0];
        [marker writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_ui_inject.txt"]
                 atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return;
    }
    NSUInteger applied = 0;
    if (!sLastAppliedSearchBooks) sLastAppliedSearchBooks = [NSMutableArray array];
    [sLastAppliedSearchBooks removeAllObjects];
    NSMutableArray *vcNames = [NSMutableArray array];
    for (UIViewController *vc in targets) {
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
    if (discoverActive) {
        LBEnsureNativeDiscoverHostPresented();
        for (UIViewController *h in (LBFindDiscoverHostVCs() ?: @[])) {
            // 多页原生模式：只刷新当前可见 BookListCon，禁止钉死第一页/同步到空兄弟页
            LBReloadDiscoverNativeList(h);
        }
    }
    NSString *marker = [NSString stringWithFormat:@"uiInject ok vcs=%lu applied=%lu key=%@ targets=%@ discover=%d explore=%d",
                        (unsigned long)targets.count, (unsigned long)applied, keyword ?: @"",
                        [vcNames componentsJoinedByString:@","], discoverActive ? 1 : 0, exploreMode ? 1 : 0];
    [marker writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_ui_inject.txt"]
             atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    // 发现态：标题壳已建好时不再每次 inject 都 RefreshKindBar（会 ForceTitles → 闪屏）
    // 延迟再灌仅保留搜索页 Reapply，发现页靠 ReloadDiscoverNativeList 软刷表
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
/// 用户已倒序/过滤：禁止引擎 reapply 用原始顺序盖回
static BOOL sCatalogUserOrderLocked = NO;

void LBSetCatalogUserOrderLocked(BOOL locked) {
    sCatalogUserOrderLocked = locked;
}

BOOL LBCatalogUserOrderLocked(void) {
    return sCatalogUserOrderLocked;
}

void LBSyncPendingCatalogChapters(NSArray *chapters) {
    if (![chapters isKindOfClass:[NSArray class]]) return;
    sPendingCatalogChapters = [chapters copy];
    sCatalogUserOrderLocked = YES;
}

NSArray *LBCopyPendingCatalogChapters(void) {
    return [sPendingCatalogChapters copy];
}

void LBClearNativeReadingBridgeState(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            LBClearNativeReadingBridgeState();
        });
        return;
    }
    sPendingCatalogChapters = nil;
    sPendingCatalogBookUrl = nil;
    sPendingCatalogSourceName = nil;
    sPendingCatalogSourceUrl = nil;
    sCatalogUserOrderLocked = NO;
    if (sPendingSearchBooks) [sPendingSearchBooks removeAllObjects];
    if (sLastAppliedSearchBooks) [sLastAppliedSearchBooks removeAllObjects];
    [@"native XBS clear bridge reading/search state"
        writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_native_marker.txt"]
         atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

/// 从 bookUrl 取 scheme://host[:port]，替代写死的 mock 端口兜底
static NSString *LBOriginSourceUrlFromBookUrl(NSString *bookUrl) {
    if (bookUrl.length == 0) return nil;
    NSURL *u = [NSURL URLWithString:bookUrl];
    if (u.scheme.length == 0 || u.host.length == 0) return nil;
    if (u.port != nil) {
        return [NSString stringWithFormat:@"%@://%@:%@", u.scheme, u.host, u.port];
    }
    return [NSString stringWithFormat:@"%@://%@", u.scheme, u.host];
}

/// pending > bookUrl 源站 > 持久绑定
static NSString *LBResolvePendingSourceUrl(NSString *bookUrl) {
    if (sPendingCatalogSourceUrl.length > 0) return sPendingCatalogSourceUrl;
    NSString *origin = LBOriginSourceUrlFromBookUrl(bookUrl);
    if (origin.length > 0) return origin;
    NSString *mapped = LBReadingSourceUrlForBookUrl(bookUrl);
    if (mapped.length > 0) return mapped;
    return nil;
}
/// legado://nativeRead 等待目录返回后再点章
static NSInteger sDeferredNativeOpenIdx = -1;
/// 本章已成功 nativePaged+push，禁止 goStart 二次 push（nativeRead 多路回调曾 SIGABRT）
static BOOL sNativeOpenChapterDone = NO;
static BOOL sNativeOpenGoInFlight = NO;
/// nativeRead 单次点章占坑 bookUrl|idx（目录/tryOpen 多路回调只放行一次）
static NSString *sNativeOpenOnceKey = nil;
static NSObject *sNativeOpenOnceLock = nil;
static NSString *sDeferredNativeOpenBookUrl = nil;
/// nativeRead 目录回调已触发过开章（防 LBApplyCatalogToUI 二次 catalogUI）
static BOOL sNativeReadChapterOpenStarted = NO;
static NSDictionary *sPendingResetContent = nil;
static NSMutableDictionary *sPendingNativeFullBook = nil;
/// 0=off 1=nativeFull(原版UI) 2=safeShell(UITextView兜底，不算过关)
static int sLegadoReaderMode = 0;
/// 假设 E：mode=1 下 viewDidAppear 已走 UIKit super 一次（onReset 门控）
static BOOL sDidAppearUIKit = NO;
/// G6：nativeFull 旁路 ReadVCBase2.viewDidAppear 后需补 createToolbar（每阅读页实例一次）
static __weak id sG6ToolbarCreatedForReader = nil;
static char kLBG6MidTapProxyKey;
static char kLBG6MidTapInstalledKey;
static NSTimeInterval sG6LastChangeToolBarTs = 0;
static void (*LBOrig_changeToolBar)(id, SEL) = NULL;
static BOOL sReaderContentAppearHooked = NO;
static BOOL sCatalogUIAppearHooked = NO;
static BOOL sCatalogInjectReentrant = NO;
static BOOL sNativeOpenCrashGuardsInstalled = NO;
static char sNativeOpenMarkerPath[512] = {0};
static char sNativeCrashPendingPath[512] = {0};
static void (*LBOrig_openReader)(id, SEL, id, id, id) = NULL;
static void (*LBOrig_tryOpenRecord)(id, SEL, id, id) = NULL;
static void (*LBOrig_onResetContentNotify)(id, SEL, NSNotification *) = NULL;
static IMP sOrigCatalogNumberOfRows = NULL;
static IMP sOrigCatalogCellForRow = NULL;
/// 共享基类（LCTableViewControllerBase_*）上 table 方法的真·原生 IMP。
/// 搜索/目录 Hook 若误 method_setImplementation 到基类，会伤到 BookShelfListVC → 列表模式「空列表」。
static IMP sTruePlainNumberOfRows = NULL;
static IMP sTruePlainCellForRow = NULL;
static void (*LBOrig_setArrCatalog)(id, SEL, id) = NULL;
static id (*LBOrig_getArrCatalog)(id, SEL) = NULL;
static void (*LBOrig_catalogDidSelect)(id, SEL, UITableView *, NSIndexPath *) = NULL;

static BOOL LBVCIsBookShelfContext(id selfObj) {
    if (!selfObj) return NO;
    NSString *cn = NSStringFromClass([selfObj class]);
    return [cn containsString:@"BookShelf"];
}

static BOOL LBIsSharedTableBaseClass(Class cls) {
    if (!cls) return NO;
    NSString *n = NSStringFromClass(cls);
    return [n containsString:@"LCTableViewControllerBase"] ||
           [n isEqualToString:@"UITableViewController"];
}

/// 只在 targetCls 自身挂 IMP；禁止改写共享基类（避免误伤书架列表）。
static void LBInstallHookOnClassOnly(Class targetCls, SEL sel, IMP hookImp, IMP *inoutOrig) {
    if (!targetCls || !sel || !hookImp) return;
    Method any = class_getInstanceMethod(targetCls, sel);
    if (!any) return;
    IMP current = method_getImplementation(any);
    if (current == hookImp) return;
    const char *types = method_getTypeEncoding(any);
    if (!types) types = "@@:@q";
    Class owner = LBClassOwningInstanceMethod(targetCls, sel) ?: targetCls;
    if (inoutOrig && !*inoutOrig && current != hookImp) {
        *inoutOrig = current;
    }
    if (LBIsSharedTableBaseClass(owner)) {
        // 记录真原生，并把已被污染的基类 IMP 还原
        IMP knownSearchRows = (IMP)LBHookedNumberOfRows;
        IMP knownCatRows = (IMP)LBHookedCatalogNumberOfRows;
        IMP knownSearchCell = (IMP)LBHookedCellForRow;
        IMP knownCatCell = (IMP)LBHookedCatalogCellForRow;
        BOOL isOurRows = (current == knownSearchRows || current == knownCatRows);
        BOOL isOurCell = (current == knownSearchCell || current == knownCatCell);
        if (!sTruePlainNumberOfRows && sel == @selector(tableView:numberOfRowsInSection:) && !isOurRows) {
            sTruePlainNumberOfRows = current;
        }
        if (!sTruePlainCellForRow && sel == @selector(tableView:cellForRowAtIndexPath:) && !isOurCell) {
            sTruePlainCellForRow = current;
        }
        if (!sTruePlainDidSelect && sel == @selector(tableView:didSelectRowAtIndexPath:) &&
            current != hookImp) {
            sTruePlainDidSelect = current;
        }
        IMP restore = NULL;
        if (sel == @selector(tableView:numberOfRowsInSection:)) {
            restore = sTruePlainNumberOfRows;
        } else if (sel == @selector(tableView:cellForRowAtIndexPath:)) {
            restore = sTruePlainCellForRow;
        } else if (sel == @selector(tableView:didSelectRowAtIndexPath:)) {
            restore = sTruePlainDidSelect;
        }
        if (restore && restore != hookImp) {
            Method om = class_getInstanceMethod(owner, sel);
            if (om && method_getImplementation(om) != restore) {
                method_setImplementation(om, restore);
            }
        }
        if (!class_addMethod(targetCls, sel, hookImp, types)) {
            unsigned int count = 0;
            Method *list = class_copyMethodList(targetCls, &count);
            Method own = NULL;
            for (unsigned int i = 0; i < count; i++) {
                if (method_getName(list[i]) == sel) {
                    own = list[i];
                    break;
                }
            }
            if (list) free(list);
            if (own) method_setImplementation(own, hookImp);
        }
        return;
    }
    if (owner == targetCls) {
        method_setImplementation(any, hookImp);
        return;
    }
    if (!class_addMethod(targetCls, sel, hookImp, types)) {
        unsigned int count = 0;
        Method *list = class_copyMethodList(targetCls, &count);
        Method own = NULL;
        for (unsigned int i = 0; i < count; i++) {
            if (method_getName(list[i]) == sel) {
                own = list[i];
                break;
            }
        }
        if (list) free(list);
        if (own) method_setImplementation(own, hookImp);
    }
}

static IMP LBForwardTableRowsIMP(void) {
    if (sTruePlainNumberOfRows) return sTruePlainNumberOfRows;
    if (sOrigCatalogNumberOfRows) return sOrigCatalogNumberOfRows;
    if (sOrigNumberOfRows) return sOrigNumberOfRows;
    return NULL;
}

static IMP LBForwardTableCellIMP(void) {
    if (sTruePlainCellForRow) return sTruePlainCellForRow;
    if (sOrigCatalogCellForRow) return sOrigCatalogCellForRow;
    if (sOrigCellForRow) return sOrigCellForRow;
    return NULL;
}
static NSTimeInterval sLastLegadoChapterOpenTs = 0;
static NSTimeInterval sLastPushNativeFullTs = 0;
/// 最近一次原生分页成功（防 deliver 重复 divisionResponse 撞崩）
static NSTimeInterval sLastNativePagedOkTs = 0;
static NSString *sLastNativePagedKey = nil;
static BOOL sContentInjectBusy = NO;
/// 单次 contentInject 内仅调一次 showPage:0（多次翻页曾 SIGABRT sig=6）
static BOOL sShowPage0ThisInject = NO;
/// 单次 contentInject 内仅调一次 onDivisionTextFinish（重复曾 SIGABRT sig=6）
static BOOL sOnDivisionFinishDoneThisInject = NO;
/// 假设 L：kick divisionResponse 成功后短窗禁止 contentInject deliver（防 postCurCp 二次灌入）
static NSTimeInterval sKickDeliverBlockUntilTs = 0;
static const NSTimeInterval kKickDeliverBlockSec = 3.0;
static UIViewController *sHiddenBookDetail = nil;

static void LBFlushPendingResetContent(NSString *phase);
static void LBAppendOpenReaderTrace(NSString *msg);
static void LBSeedTurnPageTypeScrollBranch(void);
static void LBLogHypothesisB2ContainerProbe(id readerVC, NSString *phase);
typedef void (*LBOnResetNoArgFn)(id, SEL);
static IMP sOnResetNoArgNativeIMP = NULL;
static IMP LBResolveOnResetNoArgNativeIMP(Class cls, SEL sel, IMP hint);
static NSString *LBLookupIMPDlName(IMP imp);
static void LBHypothesisEFireOnResetNoArg(id selfObj, SEL sel, LBOnResetNoArgFn origNoArg,
                                          NSString *fireTag);
static void LBHypothesisEScheduleOnResetNoArg(UIViewController *vc, SEL sel,
                                              LBOnResetNoArgFn origNoArg, int attempt,
                                              void (^onDone)(void));
static BOOL LBNativeOpenGateBlocked(NSString **outReason);
static void LBClearNativeOpenOnceState(NSString *reason);
static void LBInstallOpenOnceClearOnShelfAppear(void);
static BOOL LBBridgeDebugLoaded(void);
static BOOL LBInjectOkPathsCountAsSuccess(NSArray *paths, BOOL nativePaged);
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
    if (LBNativeOpenGateBlocked(NULL)) {
        // 假设 R2：开章门闩期间禁止 reapply 改 Catalog/导航栈（0.35s 日志后进程即重启）
        LBAppendOpenReaderTrace(@"hypothesis_R2 catalogReapply noop (gate blocked)");
        (void)chapters;
        (void)bookUrl;
        return;
    }
    if (sCatalogUserOrderLocked) {
        LBAppendOpenReaderTrace(@"catalogReapply noop (user order locked)");
        return;
    }
    NSArray *chCopy = [chapters copy];
    NSString *buCopy = [bookUrl copy];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (LBNativeOpenGateBlocked(NULL) || sLegadoReaderMode == 1 || sCatalogUserOrderLocked) {
            LBAppendOpenReaderTrace(@"hypothesis_R2 catalogReapply0.35 noop");
            return;
        }
        LBApplyPendingCatalogToVCs(chCopy, buCopy, @"reapply0.35");
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (LBNativeOpenGateBlocked(NULL) || sLegadoReaderMode == 1 || sCatalogUserOrderLocked) {
            LBAppendOpenReaderTrace(@"hypothesis_R2 catalogReapply1.0 noop");
            return;
        }
        LBApplyPendingCatalogToVCs(chCopy, buCopy, @"reapply1.0");
    });
}

static NSInteger LBHookedCatalogNumberOfRows(id self, SEL _cmd, UITableView *tv, NSInteger section) {
    // 书架/搜索/非目录：必须走真原生行数，禁止用章节 pending 覆盖
    if (LBVCIsBookShelfContext(self) || LBVCIsSearchTableContext(self) || !LBVCIsCatalogTableContext(self)) {
        IMP fwd = LBForwardTableRowsIMP();
        if (fwd) {
            return ((NSInteger (*)(id, SEL, UITableView *, NSInteger))fwd)(self, _cmd, tv, section);
        }
        return 0;
    }
    // 目录：CatalogCon 真机展示字段是 arrSource；E-02/E-03 写 arrSource 后须优先读它
    for (NSString *key in @[@"arrSource", @"arrCatalog", @"arrCpInfo", @"arrBaseData"]) {
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
        for (NSString *key in @[@"arrSource", @"arrCatalog", @"arrCpInfo", @"arrBaseData"]) {
            @try {
                id cur = [dsObj valueForKey:key];
                if (!LBArrayLooksLikeChapters(cur)) continue;
                return (NSInteger)[cur count];
            } @catch (__unused NSException *e) {}
        }
    }
    IMP fwd = LBForwardTableRowsIMP();
    if (fwd) {
        return ((NSInteger (*)(id, SEL, UITableView *, NSInteger))fwd)(self, _cmd, tv, section);
    }
    return 0;
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

/// 异步信号安全：仅允许 snprintf/open/write/close/signal/raise
static void LBNativeOpenSignalHandler(int sig) {
    char buf[96];
    int n = snprintf(buf, sizeof(buf), "pending sig=%d\n", sig);
    if (sNativeCrashPendingPath[0] && n > 0) {
        int fd = open(sNativeCrashPendingPath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
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
    NSString *home = NSHomeDirectory();
    NSString *p = [home stringByAppendingPathComponent:@"Documents/legado_catalog_openreader.txt"];
    snprintf(sNativeOpenMarkerPath, sizeof(sNativeOpenMarkerPath), "%s",
             p.fileSystemRepresentation ?: "");
    NSString *pending = [home stringByAppendingPathComponent:@"Documents/legado_native_crash_pending.txt"];
    snprintf(sNativeCrashPendingPath, sizeof(sNativeCrashPendingPath), "%s",
             pending.fileSystemRepresentation ?: "");
    if ([[NSFileManager defaultManager] fileExistsAtPath:pending]) {
        LBClearNativeOpenOnceState(@"crash-pending startup");
        [[NSFileManager defaultManager] removeItemAtPath:pending error:NULL];
        LBAppendOpenReaderTrace(@"nativeOpen crash-pending cleared openOnce on startup");
    }
    NSSetUncaughtExceptionHandler(&LBNativeOpenExceptionHandler);
    signal(SIGABRT, LBNativeOpenSignalHandler);
    signal(SIGSEGV, LBNativeOpenSignalHandler);
    signal(SIGBUS, LBNativeOpenSignalHandler);
    signal(SIGILL, LBNativeOpenSignalHandler);
    LBInstallOpenOnceClearOnShelfAppear();
}

static NSMutableDictionary *LBBookDictForOpenReader(NSString *bookUrl,
                                                    id chapterItem,
                                                    NSInteger idx,
                                                    NSString *chUrl,
                                                    NSString **outSourceName);
static BOOL LBCallOpenReader(NSDictionary *book, NSString *sourceName, NSString **outMsg);
static BOOL LBPushTextReaderFallback(NSDictionary *book, NSString *sourceName, NSString **outMsg);
static BOOL LBPushTextReaderNativeFull(NSDictionary *book, NSString *sourceName, NSString **outMsg);
static void LBNativeReaderHideHostNavBar(id readerVC, BOOL hide);
static void LBNativeReaderStripBridgeOverlays(id readerVC);
static void LBInjectPendingContentIntoReader(UIViewController *readerVC, NSString *phase);
static BOOL LBInjectNativeChapterContent(UIViewController *readerVC, NSDictionary *payload, NSString *phase);
static void LBDeliverContentToVisibleReaders(NSString *phase);
static void LBInstallSafeTextReadShellHooks(void);
static void LBInstallNativeResetContentHook(void);
static void LBSeedTextReadAppearFields(id readerVC, NSDictionary *book);
static BOOL LBPrepareDetailForOpenReader(NSMutableDictionary *book, NSString *sourceName, NSString **outMsg);
static void LBFlushPendingResetContent(NSString *phase);
static BOOL LBIsTextReaderVisible(void);
static BOOL LBNavStackHasTextReader(void);
static BOOL LBPopToExistingTextReader(void);
static UIViewController *LBFindVisibleTextReaderVC(void);
static UIViewController *LBFindBookDetailVC(void);
static BOOL LBPushLegadoBookDetailFromSearch(id searchVC, NSDictionary *bookDic);

static void LBOpenLegadoChapterAtIndexWithVia(NSInteger idx, NSString *via);

static NSArray<NSString *> *LBNativeOpenOnceMarkerPaths(void) {
    NSString *home = NSHomeDirectory();
    return @[
        [home stringByAppendingPathComponent:@"Documents/legado_native_open_once.txt"],
        [home stringByAppendingPathComponent:@"Library/Caches/legado_native_open_once.txt"],
    ];
}

static void LBNativeOpenOnceLockInit(void) {
    static dispatch_once_t onceLock;
    dispatch_once(&onceLock, ^{ sNativeOpenOnceLock = [[NSObject alloc] init]; });
}

static NSString *LBReadNativeOpenOnceMarker(void) {
    for (NSString *path in LBNativeOpenOnceMarkerPaths()) {
        NSString *txt = [NSString stringWithContentsOfFile:path
                                                    encoding:NSUTF8StringEncoding error:NULL];
        if (txt.length == 0) continue;
        return [txt stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    return nil;
}

static void LBWriteNativeOpenOnceMarker(NSString *key) {
    if (key.length == 0) return;
    for (NSString *path in LBNativeOpenOnceMarkerPaths()) {
        NSString *dir = [path stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES attributes:nil error:NULL];
        [key writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }
}

static void LBClearNativeOpenOnceMarker(void) {
    for (NSString *path in LBNativeOpenOnceMarkerPaths()) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    }
}

/// LegadoBridgeDebug 已加载时才允许 overlay / accessibility probe
static BOOL LBBridgeDebugLoaded(void) {
    return NSClassFromString(@"LBDebugPanel") != nil;
}

/// overlay / probe / native_bind_failed 不算成功注入
static BOOL LBInjectOkPathsCountAsSuccess(NSArray *paths, BOOL nativePaged) {
    if (nativePaged) return YES;
    static NSSet *nonSuccess = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        nonSuccess = [NSSet setWithObjects:
            @"native_bind_failed", @"overlay92011", @"tvHasNeedleProbeOnly",
            @"probeOnlyPostDR", nil];
    });
    for (NSString *p in paths) {
        if (![nonSuccess containsObject:p]) return YES;
    }
    return NO;
}

static void LBClearNativeOpenOnceState(NSString *reason) {
    LBNativeOpenOnceLockInit();
    @synchronized(sNativeOpenOnceLock) {
        sNativeOpenOnceKey = nil;
        sNativeOpenGoInFlight = NO;
        sNativeOpenChapterDone = NO;
        sNativeReadChapterOpenStarted = NO;
        sDeferredNativeOpenIdx = -1;
        sDeferredNativeOpenBookUrl = nil;
        LBClearNativeOpenOnceMarker();
        if (reason.length > 0) {
            LBAppendOpenReaderTrace([NSString stringWithFormat:@"nativeOpen clearLocks reason=%@", reason]);
        }
    }
}

/// F2：离开阅读页时清 open_once（目录盖住时只清磁盘；栈上已无 TextRead 则全清）
static void LBInstallOpenOnceClearOnReaderLeave(void) {
    static BOOL sOnce = NO;
    if (sOnce) return;
    sOnce = YES;
    for (NSString *cn in @[@"TextReadVC3", @"TextReadVC2", @"TextReadVC1"]) {
        Class cls = NSClassFromString(cn);
        if (!cls) continue;
        SEL sel = @selector(viewDidDisappear:);
        if (!class_getInstanceMethod(cls, sel)) continue;
        Method any = class_getInstanceMethod(cls, sel);
        IMP orig = method_getImplementation(any);
        IMP *slot = (IMP *)malloc(sizeof(IMP));
        if (!slot) continue;
        *slot = orig;
        IMP hook = imp_implementationWithBlock(^void(id self, BOOL animated) {
            IMP fwd = *slot;
            if (fwd) ((void (*)(id, SEL, BOOL))fwd)(self, sel, animated);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (LBNavStackHasTextReader()) {
                    if (LBReadNativeOpenOnceMarker().length > 0) {
                        LBClearNativeOpenOnceMarker();
                        LBAppendOpenReaderTrace(@"nativeOpen diskOpenOnce cleared readerCovered");
                    }
                    return;
                }
                // 阅读页已出栈：恢复宿主导航栏，避免书架顶栏一直被藏
                LBNativeReaderHideHostNavBar(self, NO);
                if (sNativeOpenOnceKey.length > 0 || LBReadNativeOpenOnceMarker().length > 0) {
                    LBClearNativeOpenOnceState(@"readerLeave");
                }
            });
        });
        LBInstallHookOnClassOnly(cls, sel, hook, slot);
        LBAppendOpenReaderTrace([NSString stringWithFormat:@"openOnceClearOnReaderLeave hooked %@", cn]);
    }
}

/// F2：回书架时清 open_once 磁盘标记（acceptance：最终不存在）
static void LBInstallOpenOnceClearOnShelfAppear(void) {
    static BOOL sOnce = NO;
    if (sOnce) return;
    sOnce = YES;
    LBInstallOpenOnceClearOnReaderLeave();
    for (NSString *cn in @[@"BookShelfController", @"BookShelfListVC",
                           @"BookShelfVCBase1", @"BookShelfVCBase2"]) {
        Class cls = NSClassFromString(cn);
        if (!cls) continue;
        SEL sel = @selector(viewDidAppear:);
        if (!class_getInstanceMethod(cls, sel)) continue;
        Method any = class_getInstanceMethod(cls, sel);
        IMP cur = method_getImplementation(any);
        IMP *slot = (IMP *)malloc(sizeof(IMP));
        if (!slot) continue;
        *slot = cur;
        IMP hook = imp_implementationWithBlock(^void(id self, BOOL animated) {
            IMP fwd = *slot;
            if (fwd) {
                ((void (*)(id, SEL, BOOL))fwd)(self, sel, animated);
            }
            if (sNativeOpenOnceKey.length > 0 || LBReadNativeOpenOnceMarker().length > 0) {
                LBClearNativeOpenOnceState(@"shelfAppear");
            }
        });
        LBInstallHookOnClassOnly(cls, sel, hook, slot);
        LBAppendOpenReaderTrace([NSString stringWithFormat:@"openOnceClearOnShelf hooked %@", cn]);
    }
}

#pragma mark - 8.5 离线：目录落盘 + xsfolder 正文回退

static NSString *LBCatalogCacheSafeKey(NSString *bookUrl) {
    // 须逐字符重建：若 in-place 把非法字符换成 `_`，`_` 仍非 alnum → 死循环，
    // nativeRead 会卡在 LBEnsurePendingCatalogForBook（真机：openurl 有、request/trace 无）。
    if (bookUrl.length == 0) return @"unknown";
    NSCharacterSet *allowed = [NSCharacterSet alphanumericCharacterSet];
    NSMutableString *s = [NSMutableString stringWithCapacity:MIN(bookUrl.length, (NSUInteger)120)];
    for (NSUInteger i = 0; i < bookUrl.length; i++) {
        unichar c = [bookUrl characterAtIndex:i];
        if ([allowed characterIsMember:c]) {
            [s appendFormat:@"%C", c];
        } else {
            [s appendString:@"_"];
        }
    }
    if (s.length > 120) {
        return [s substringFromIndex:s.length - 120];
    }
    return s;
}

static NSString *LBCatalogCachePath(NSString *bookUrl) {
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_catalog_cache"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    return [dir stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@.json", LBCatalogCacheSafeKey(bookUrl)]];
}

static void LBSaveCatalogCache(NSString *bookUrl, NSArray *chapters) {
    if (bookUrl.length == 0 || ![chapters isKindOfClass:[NSArray class]] || chapters.count == 0) return;
    NSDictionary *doc = @{@"bookUrl": bookUrl, @"chapters": chapters};
    NSData *data = [NSJSONSerialization dataWithJSONObject:doc options:0 error:nil];
    if (!data) return;
    [data writeToFile:LBCatalogCachePath(bookUrl) atomically:YES];
    LBAppendOpenReaderTrace([NSString stringWithFormat:
                             @"catalogCache save n=%lu book=%@",
                             (unsigned long)chapters.count, bookUrl]);
}

static NSArray *LBLoadCatalogCache(NSString *bookUrl) {
    if (bookUrl.length == 0) return nil;
    NSData *data = [NSData dataWithContentsOfFile:LBCatalogCachePath(bookUrl)];
    if (!data) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![obj isKindOfClass:[NSDictionary class]]) return nil;
    id ch = ((NSDictionary *)obj)[@"chapters"];
    if (![ch isKindOfClass:[NSArray class]] || [(NSArray *)ch count] == 0) return nil;
    LBAppendOpenReaderTrace([NSString stringWithFormat:
                             @"catalogCache load n=%lu book=%@",
                             (unsigned long)[(NSArray *)ch count], bookUrl]);
    return (NSArray *)ch;
}

/// AppConfig 本地书目录：Library/appdata/xsfolder/book/<bookKey>
static NSString *LBXsfolderBookDir(NSString *bookKey) {
    if (bookKey.length == 0) return nil;
    NSString *lib = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/appdata/xsfolder/book"];
    return [lib stringByAppendingPathComponent:bookKey];
}

static NSString *LBGuessBookKeyForUrl(NSString *bookUrl) {
    // bridge books / 常见 mock：仅明确命中才映射；禁止未知 URL 默认落到斗破（会串成「上架感言」）
    if ([bookUrl containsString:@"doupo"]) return @"斗破苍穹_天蚕土豆";
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_bridge_books.json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data) {
        id arr = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([arr isKindOfClass:[NSArray class]]) {
            for (id it in (NSArray *)arr) {
                if (![it isKindOfClass:[NSDictionary class]]) continue;
                NSDictionary *d = (NSDictionary *)it;
                NSString *bu = d[@"bookUrl"];
                if (![bu isKindOfClass:[NSString class]] || ![bu isEqualToString:bookUrl]) continue;
                NSString *name = [d[@"name"] isKindOfClass:[NSString class]] ? d[@"name"] : @"";
                NSString *author = [d[@"author"] isKindOfClass:[NSString class]] ? d[@"author"] : @"";
                if (name.length > 0) {
                    return [NSString stringWithFormat:@"%@_%@", name,
                            author.length > 0 ? author : @"unknown"];
                }
            }
        }
    }
    return nil;
}

static NSArray *LBCatalogFromXsfolderBookKey(NSString *bookKey) {
    NSString *dir = LBXsfolderBookDir(bookKey);
    if (dir.length == 0) return nil;
    NSString *lst = [dir stringByAppendingPathComponent:@"localSourceText"];
    NSData *data = [NSData dataWithContentsOfFile:lst];
    if (!data) return nil;
    id plist = [NSPropertyListSerialization propertyListWithData:data
                                                         options:0
                                                          format:NULL
                                                           error:NULL];
    if (![plist isKindOfClass:[NSDictionary class]]) return nil;
    id list = ((NSDictionary *)plist)[@"list"];
    if (![list isKindOfClass:[NSArray class]] || [(NSArray *)list count] == 0) return nil;
    NSMutableArray *out = [NSMutableArray array];
    NSInteger i = 0;
    for (id it in (NSArray *)list) {
        if (![it isKindOfClass:[NSDictionary class]]) { i++; continue; }
        NSDictionary *d = (NSDictionary *)it;
        NSString *title = [d[@"title"] isKindOfClass:[NSString class]] ? d[@"title"] : @"章节";
        NSString *url = [d[@"url"] isKindOfClass:[NSString class]] ? d[@"url"] : [@(i) stringValue];
        // 离线点章：url 用 cpIndex 字符串，与 xsfolder 文件名对齐
        NSString *cpUrl = url.length > 0 ? url : [@(i) stringValue];
        [out addObject:@{
            @"cpTitle": title ?: @"章节",
            @"title": title ?: @"章节",
            @"cpUrl": cpUrl,
            @"chapterUrl": cpUrl,
            @"url": cpUrl,
            @"cpIndex": @(i),
            @"index": @(i)
        }];
        i++;
    }
    if (out.count > 0) {
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"catalogFromXsfolder key=%@ n=%lu",
                                 bookKey, (unsigned long)out.count]);
    }
    return out.count > 0 ? out : nil;
}

static NSString *LBReadXsfolderChapterBody(NSString *bookUrl, NSString *chapterUrl, NSInteger preferIdx) {
    // http(s) 书：正文不得走 xsfolder（斗破 key 被起点「上架感言」污染时会直接上屏；离线改走 bookUrl 目录缓存+网络）
    if ([bookUrl hasPrefix:@"http://"] || [bookUrl hasPrefix:@"https://"]) {
        return nil;
    }
    NSString *bookKey = LBGuessBookKeyForUrl(bookUrl);
    if (bookKey.length == 0) return nil;
    NSString *dir = LBXsfolderBookDir(bookKey);
    if (dir.length == 0) return nil;
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    if (preferIdx >= 0) {
        [candidates addObject:[@(preferIdx) stringValue]];
    }
    if ([chapterUrl isKindOfClass:[NSString class]] && chapterUrl.length > 0) {
        [candidates addObject:chapterUrl.lastPathComponent ?: chapterUrl];
        // http(s) 章：用目录里的 idx
        if ([chapterUrl hasPrefix:@"http"] && sPendingCatalogChapters.count > 0) {
            NSInteger i = 0;
            for (id it in sPendingCatalogChapters) {
                if (![it isKindOfClass:[NSDictionary class]]) { i++; continue; }
                NSDictionary *d = (NSDictionary *)it;
                NSString *u = d[@"cpUrl"] ?: d[@"chapterUrl"] ?: d[@"url"] ?: @"";
                if ([u isEqualToString:chapterUrl]) {
                    [candidates addObject:[@(i) stringValue]];
                    break;
                }
                i++;
            }
        }
    }
    [candidates addObject:@"0"];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *rel in candidates) {
        if (rel.length == 0) continue;
        NSString *path = [dir stringByAppendingPathComponent:rel];
        if (![fm fileExistsAtPath:path]) continue;
        NSString *body = [NSString stringWithContentsOfFile:path
                                                   encoding:NSUTF8StringEncoding
                                                      error:NULL];
        if (body.length > 0) {
            LBAppendOpenReaderTrace([NSString stringWithFormat:
                                     @"xsfolderBody hit key=%@ file=%@ len=%lu",
                                     bookKey, rel, (unsigned long)body.length]);
            return body;
        }
    }
    return nil;
}

static BOOL LBEnsurePendingCatalogForBook(NSString *bookUrl) {
    if (bookUrl.length == 0) return NO;
    // 必须 bookUrl 严格匹配；pending 无 bookUrl 或串书时不得复用（否则会出现 doupo 章名变成「上架感言」）
    if (sPendingCatalogChapters.count > 0 &&
        sPendingCatalogBookUrl.length > 0 &&
        [sPendingCatalogBookUrl isEqualToString:bookUrl]) {
        return YES;
    }
    if (sPendingCatalogChapters.count > 0 &&
        (sPendingCatalogBookUrl.length == 0 ||
         ![sPendingCatalogBookUrl isEqualToString:bookUrl])) {
        sPendingCatalogChapters = nil;
        sPendingCatalogBookUrl = nil;
    }
    NSArray *cached = LBLoadCatalogCache(bookUrl);
    if (cached.count == 0) {
        // http(s) 书：只能用「该书 bookUrl」的目录缓存；禁止用 xsfolder 默认书冒充
        // 真机：doupo 缓存未命中 → 读到被污染的 斗破苍穹_天蚕土豆 → title=上架感言
        BOOL isRemote = [bookUrl hasPrefix:@"http://"] || [bookUrl hasPrefix:@"https://"];
        if (!isRemote) {
            NSString *bk = LBGuessBookKeyForUrl(bookUrl);
            if (bk.length > 0) {
                cached = LBCatalogFromXsfolderBookKey(bk);
            }
        } else {
            LBAppendOpenReaderTrace([NSString stringWithFormat:
                                     @"catalogEnsure skipXsfolder remote book=%@", bookUrl]);
        }
    }
    if (cached.count == 0) return NO;
    sPendingCatalogChapters = [cached copy];
    sPendingCatalogBookUrl = [bookUrl copy];
    if (sPendingCatalogSourceUrl.length == 0) {
        sPendingCatalogSourceUrl = LBOriginSourceUrlFromBookUrl(bookUrl);
    }
    if (sPendingCatalogSourceName.length == 0) {
        sPendingCatalogSourceName = @"本地静态测试源";
    }
    return YES;
}

static BOOL LBNativeOpenMarkerMatchesBook(NSString *bookUrl) {
    if (bookUrl.length == 0) return NO;
    NSString *disk = LBReadNativeOpenOnceMarker();
    NSString *key = sNativeOpenOnceKey.length > 0 ? sNativeOpenOnceKey : disk;
    if (key.length == 0) return NO;
    NSRange bar = [key rangeOfString:@"|"];
    NSString *bu = bar.location != NSNotFound ? [key substringToIndex:bar.location] : key;
    return [bu isEqualToString:bookUrl];
}

/// openOnce key 形如 bookUrl|idx；解析失败返回 -1
static NSInteger LBNativeOpenIdxFromKey(NSString *key) {
    if (key.length == 0) return -1;
    NSRange bar = [key rangeOfString:@"|" options:NSBackwardsSearch];
    if (bar.location == NSNotFound || bar.location + 1 >= key.length) return -1;
    NSString *tail = [key substringFromIndex:bar.location + 1];
    if (tail.length == 0) return -1;
    return [tail integerValue];
}

static NSInteger LBCurrentNativeOpenIdx(void) {
    NSString *key = sNativeOpenOnceKey.length > 0 ? sNativeOpenOnceKey : LBReadNativeOpenOnceMarker();
    return LBNativeOpenIdxFromKey(key);
}

/// 同书已在阅读页：拉新章正文 → seed xsfolder → loadCp:/loadCurCp，禁止二次 push
static void LBSwitchNativeChapterInPlace(NSString *bookUrl, NSString *sourceUrl, NSInteger idx) {
    NSArray *use = sPendingCatalogChapters;
    if (use.count == 0) {
        LBAppendOpenReaderTrace(@"switchInPlace skip noCatalog");
        return;
    }
    if (idx < 0 || idx >= (NSInteger)use.count) {
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"switchInPlace skip idxOOB idx=%ld count=%lu",
                                 (long)idx, (unsigned long)use.count]);
        return;
    }
    id item = use[(NSUInteger)idx];
    NSString *chUrl = nil;
    NSString *chTitle = nil;
    if ([item isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = (NSDictionary *)item;
        chUrl = d[@"cpUrl"] ?: d[@"chapterUrl"] ?: d[@"url"];
        chTitle = d[@"cpTitle"] ?: d[@"title"] ?: d[@"name"] ?: d[@"chapterName"];
    }
    if (![chUrl isKindOfClass:[NSString class]] || chUrl.length == 0) {
        LBAppendOpenReaderTrace(@"switchInPlace skip noChUrl");
        return;
    }
    if (![chTitle isKindOfClass:[NSString class]] || chTitle.length == 0) {
        chTitle = @"章节";
    }
    NSString *bu = bookUrl.length > 0 ? bookUrl : sPendingCatalogBookUrl;
    if (bu.length == 0) {
        LBAppendOpenReaderTrace(@"switchInPlace skip noBookUrl");
        return;
    }
    NSString *su = sourceUrl.length > 0 ? sourceUrl
        : LBResolvePendingSourceUrl(bu);

    LBNativeOpenOnceLockInit();
    @synchronized(sNativeOpenOnceLock) {
        NSString *key = [NSString stringWithFormat:@"%@|%ld", bu, (long)idx];
        sNativeOpenOnceKey = [key copy];
        LBWriteNativeOpenOnceMarker(key);
        sNativeOpenChapterDone = YES;
        sNativeOpenGoInFlight = NO;
        sNativeReadChapterOpenStarted = YES;
        sDeferredNativeOpenIdx = -1;
        sDeferredNativeOpenBookUrl = [bu copy];
    }

    if ([sPendingNativeFullBook isKindOfClass:[NSMutableDictionary class]] ||
        [sPendingNativeFullBook isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *book = [sPendingNativeFullBook mutableCopy] ?: [NSMutableDictionary dictionary];
        book[@"chapterUrl"] = chUrl;
        book[@"cpUrl"] = chUrl;
        book[@"curChapterUrl"] = chUrl;
        book[@"cpIndex"] = @(idx);
        book[@"chapterIndex"] = @(idx);
        book[@"cpTitle"] = chTitle;
        book[@"chapterName"] = chTitle;
        book[@"title"] = chTitle;
        book[@"lastChapterTitle"] = chTitle;
        if (su.length > 0) {
            book[@"sourceUrl"] = su;
            book[@"bookSourceUrl"] = su;
        }
        sPendingNativeFullBook = book;
    }

    UIViewController *reader = LBFindVisibleTextReaderVC();
    if (reader) {
        @try { [reader setValue:chTitle forKey:@"title"]; } @catch (__unused NSException *e) {}
        @try {
            id fat = [reader valueForKey:@"dicFatBook"];
            if ([fat isKindOfClass:[NSMutableDictionary class]]) {
                ((NSMutableDictionary *)fat)[@"cpIndex"] = @(idx);
                ((NSMutableDictionary *)fat)[@"chapterIndex"] = @(idx);
                ((NSMutableDictionary *)fat)[@"cpUrl"] = chUrl;
                ((NSMutableDictionary *)fat)[@"chapterUrl"] = chUrl;
                ((NSMutableDictionary *)fat)[@"cpTitle"] = chTitle;
                ((NSMutableDictionary *)fat)[@"title"] = chTitle;
            }
        } @catch (__unused NSException *e) {}
    }

    LBLoadCurCpBridgeReset([NSString stringWithFormat:@"switchInPlace_idx=%ld", (long)idx]);
    LBAppendOpenReaderTrace([NSString stringWithFormat:
                             @"switchInPlace fetch idx=%ld title=%@ ch=%@",
                             (long)idx, chTitle, chUrl]);
    LBHandleContentRequest(chUrl, bu, su);
}

/// 已 claim / chapterDone / inflight / 磁盘占坑（目录 reapply 与 tryOpen 共用）
static BOOL LBNativeOpenGateBlocked(NSString **outReason) {
    LBNativeOpenOnceLockInit();
    @synchronized(sNativeOpenOnceLock) {
        NSString *diskKey = LBReadNativeOpenOnceMarker();
        if (diskKey.length > 0) {
            if (sNativeOpenOnceKey.length == 0) sNativeOpenOnceKey = [diskKey copy];
            if (outReason) *outReason = @"disk";
            return YES;
        }
        if (sNativeOpenOnceKey.length > 0) {
            if (outReason) *outReason = @"mem";
            return YES;
        }
        if (sNativeOpenChapterDone) {
            if (outReason) *outReason = @"chapterDone";
            return YES;
        }
        if (sNativeOpenGoInFlight) {
            if (outReason) *outReason = @"inflight";
            return YES;
        }
        return NO;
    }
}

/// nativeRead 点章单次占坑；已占/已完成则写 skip 日志并返回 NO
static BOOL LBClaimNativeOpenOnce(NSString *bookUrl, NSInteger idx, NSString *via) {
    LBNativeOpenOnceLockInit();
    @synchronized(sNativeOpenOnceLock) {
        NSString *blocked = nil;
        if (LBNativeOpenGateBlocked(&blocked)) {
            if ([blocked isEqualToString:@"disk"]) {
                LBAppendOpenReaderTrace([NSString stringWithFormat:
                                         @"goStart skip openOnce disk via=%@ key=%@",
                                         via ?: @"?", sNativeOpenOnceKey ?: @"?"]);
            } else if ([blocked isEqualToString:@"mem"]) {
                LBAppendOpenReaderTrace([NSString stringWithFormat:
                                         @"goStart skip openOnce via=%@ key=%@", via ?: @"?", sNativeOpenOnceKey]);
            } else if ([blocked isEqualToString:@"chapterDone"]) {
                LBAppendOpenReaderTrace([NSString stringWithFormat:
                                         @"goStart skipPush chapterDone via=%@", via ?: @"?"]);
            } else if ([blocked isEqualToString:@"inflight"]) {
                LBAppendOpenReaderTrace([NSString stringWithFormat:
                                         @"goStart skip inflight via=%@", via ?: @"?"]);
            }
            return NO;
        }
        NSString *key = [NSString stringWithFormat:@"%@|%ld", bookUrl ?: @"", (long)idx];
        sNativeOpenOnceKey = [key copy];
        LBWriteNativeOpenOnceMarker(key);
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"nativeOpen openOnce commit via=%@ key=%@", via ?: @"?", key]);
        return YES;
    }
}

/// 点章：默认原生 openReader → TextReadVC；超时仍无原生页再 Bridge 兜底
static void LBOpenLegadoChapterAtIndex(NSInteger idx) {
    LBOpenLegadoChapterAtIndexWithVia(idx, @"direct");
}

static void LBOpenLegadoChapterAtIndexWithVia(NSInteger idx, NSString *via) {
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    NSString *bookUrlEarly = sPendingCatalogBookUrl;
    NSString *wantKeyEarly = (bookUrlEarly.length > 0)
        ? [NSString stringWithFormat:@"%@|%ld", bookUrlEarly, (long)idx] : nil;

    LBNativeOpenOnceLockInit();
    BOOL proceed = NO;
    NSString *chUrl = nil;
    NSString *chTitle = nil;
    NSString *bookUrl = nil;
    id item = nil;
  @synchronized(sNativeOpenOnceLock) {
    NSString *diskKey = LBReadNativeOpenOnceMarker();
    if (diskKey.length > 0 && sNativeOpenOnceKey.length == 0) {
        sNativeOpenOnceKey = [diskKey copy];
    }
    if (sNativeOpenOnceKey.length > 0 &&
        wantKeyEarly.length > 0 &&
        ![sNativeOpenOnceKey isEqualToString:wantKeyEarly]) {
        // 换章/换书：旧 openOnce 不得永久拦住目录点章（U0-R：UI 点章无反应）
        // 仅看「阅读页是否正在展示」：栈上压着 TextRead 但顶是目录时仍须 reclaim
        BOOL hasReaderOther = LBIsTextReaderVisible();
        if (hasReaderOther) {
            LBAppendOpenReaderTrace([NSString stringWithFormat:
                                     @"goStart skip openOnce otherKey via=%@ key=%@", via ?: @"?", sNativeOpenOnceKey]);
            return;
        }
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"goStart reclaim otherKey noReader via=%@ old=%@ want=%@",
                                 via ?: @"?", sNativeOpenOnceKey, wantKeyEarly ?: @"?"]);
        sNativeOpenOnceKey = nil;
        sNativeOpenGoInFlight = NO;
        sNativeOpenChapterDone = NO;
        sNativeReadChapterOpenStarted = NO;
        sLastLegadoChapterOpenTs = 0;
        LBClearNativeOpenOnceMarker();
        diskKey = nil;
    }
    if ((sNativeOpenOnceKey.length > 0 || diskKey.length > 0) && sNativeOpenChapterDone) {
        // 阅读页未展示时禁止 deliverOnly 吞点：目录 UI 点章须重新 push（U0-R）
        BOOL hasReader = LBIsTextReaderVisible();
        if (hasReader) {
            LBAppendOpenReaderTrace([NSString stringWithFormat:
                                     @"goStart skipPush chapterDone deliverOnly via=%@", via ?: @"?"]);
            sDeferredNativeOpenIdx = -1;
            LBDeliverContentToVisibleReaders(@"openOnceChapterDone");
            return;
        }
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"goStart reclaim chapterDone+openOnce noReader via=%@", via ?: @"?"]);
        sNativeOpenOnceKey = nil;
        sNativeOpenGoInFlight = NO;
        sNativeOpenChapterDone = NO;
        sNativeReadChapterOpenStarted = NO;
        sLastLegadoChapterOpenTs = 0;
        LBClearNativeOpenOnceMarker();
        diskKey = nil;
    }
    if (sNativeOpenGoInFlight) {
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"goStart skip inflight via=%@", via ?: @"?"]);
        return;
    }
    if (sNativeOpenChapterDone) {
        BOOL hasReaderDone = LBIsTextReaderVisible();
        if (hasReaderDone) {
            LBAppendOpenReaderTrace([NSString stringWithFormat:
                                     @"goStart skipPush chapterDone deliverOnly via=%@", via ?: @"?"]);
            sDeferredNativeOpenIdx = -1;
            LBDeliverContentToVisibleReaders(@"chapterDone");
            return;
        }
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"goStart reclaim chapterDone noReader via=%@", via ?: @"?"]);
        sNativeOpenChapterDone = NO;
        sNativeOpenGoInFlight = NO;
        sNativeReadChapterOpenStarted = NO;
        sLastLegadoChapterOpenTs = 0;
    }
    // 已在展示中的 nativeFull 阅读页：只补投正文，禁止二次 push（真机曾双开 → SIGABRT）
    // 顶页是目录、栈下才有 TextRead 时不走此支，交给 go() 弹回或 push（U0-R）
    if (sLegadoReaderMode == 1 && LBIsTextReaderVisible()) {
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"goStart skipPush alreadyVisible deliverOnly via=%@", via ?: @"?"]);
        sDeferredNativeOpenIdx = -1;
        LBDeliverContentToVisibleReaders(@"alreadyVisible");
        return;
    }
    if (sLastNativePagedOkTs > 0 &&
        (now - sLastNativePagedOkTs) < 30.0 &&
        LBNavStackHasTextReader()) {
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"goStart skipPush recentPagedOnStack via=%@", via ?: @"?"]);
        sDeferredNativeOpenIdx = -1;
        sNativeOpenChapterDone = YES;
        return;
    }
    if (now - sLastLegadoChapterOpenTs < 3.5) {
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"goStart skip throttle3.5s via=%@", via ?: @"?"]);
        return;
    }
    NSArray *use = sPendingCatalogChapters;
    if (use.count == 0) {
        LBAppendOpenReaderTrace([NSString stringWithFormat:@"goStart skip noCatalog via=%@", via ?: @"?"]);
        return;
    }
    if (idx < 0 || idx >= (NSInteger)use.count) {
        LBAppendOpenReaderTrace([NSString stringWithFormat:@"goStart skip idxOOB via=%@ idx=%ld",
                                 via ?: @"?", (long)idx]);
        return;
    }
    id itemLocal = use[(NSUInteger)idx];
    chUrl = nil;
    chTitle = nil;
    if ([itemLocal isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = (NSDictionary *)itemLocal;
        chUrl = d[@"cpUrl"] ?: d[@"chapterUrl"] ?: d[@"url"];
        chTitle = d[@"cpTitle"] ?: d[@"title"] ?: d[@"name"] ?: d[@"chapterName"];
    }
    bookUrl = sPendingCatalogBookUrl;
    item = itemLocal;
    if (bookUrl.length == 0 || chUrl.length == 0) {
        LBAppendOpenReaderTrace([NSString stringWithFormat:@"goStart skip noBookOrChUrl via=%@", via ?: @"?"]);
        return;
    }
    NSString *wantKey = [NSString stringWithFormat:@"%@|%ld", bookUrl, (long)idx];
    if (sNativeOpenOnceKey.length > 0 && [sNativeOpenOnceKey isEqualToString:wantKey]) {
        BOOL hasReader = LBIsTextReaderVisible() || LBNavStackHasTextReader();
        BOOL hasPayload = [sPendingResetContent isKindOfClass:[NSDictionary class]] &&
                            [(NSDictionary *)sPendingResetContent count] > 0;
        if (!hasReader || !hasPayload) {
            LBAppendOpenReaderTrace([NSString stringWithFormat:
                                     @"goStart sameKey reclaim via=%@ reader=%d payload=%lu key=%@",
                                     via ?: @"?", hasReader ? 1 : 0,
                                     hasPayload ? (unsigned long)[(NSDictionary *)sPendingResetContent count] : 0UL,
                                     wantKey]);
            sNativeOpenOnceKey = nil;
            sNativeOpenGoInFlight = NO;
            sNativeOpenChapterDone = NO;
            sNativeReadChapterOpenStarted = NO;
            LBClearNativeOpenOnceMarker();
            // 不 return：崩溃后重点章须重新 push，禁止 sameKey 静默吞掉
        } else if (sNativeOpenChapterDone) {
            LBAppendOpenReaderTrace([NSString stringWithFormat:
                                     @"goStart skipPush chapterDone sameKey via=%@", via ?: @"?"]);
            sDeferredNativeOpenIdx = -1;
            LBDeliverContentToVisibleReaders(@"sameKeyChapterDone");
            return;
        } else if (sNativeOpenGoInFlight) {
            LBAppendOpenReaderTrace([NSString stringWithFormat:
                                     @"goStart skip inflight sameKey via=%@", via ?: @"?"]);
            return;
        } else {
            LBAppendOpenReaderTrace([NSString stringWithFormat:
                                     @"goStart skip openOnce sameKey via=%@ key=%@", via ?: @"?", wantKey]);
            sDeferredNativeOpenIdx = -1;
            LBDeliverContentToVisibleReaders(@"sameKeyDeliver");
            return;
        }
    }
    if (!LBClaimNativeOpenOnce(bookUrl, idx, via)) {
        if (sNativeOpenChapterDone) {
            sDeferredNativeOpenIdx = -1;
            LBDeliverContentToVisibleReaders(@"claimChapterDone");
        }
        return;
    }
    sLastLegadoChapterOpenTs = now;
    sNativeOpenGoInFlight = YES;
    sDeferredNativeOpenIdx = -1;
    proceed = YES;
  }
    if (!proceed) return;
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
        @try {
        LBInstallNativeOpenCrashGuards();
        if (sNativeOpenChapterDone) {
            LBAppendOpenReaderTrace(@"goStart abort push chapterDone");
            LBDeliverContentToVisibleReaders(@"chapterDoneGo");
            return;
        }
        LBWriteOpenReaderMarker([NSString stringWithFormat:@"nativeOpen phase=goStart ch=%@", chCopy]);
        // 源 URL：pending / bookUrl 源站 / 持久绑定（禁止写死 mock 端口）
        NSString *sourceName = sPendingCatalogSourceName.length > 0
            ? sPendingCatalogSourceName : @"本地静态测试源";
        NSString *sourceUrl = LBResolvePendingSourceUrl(buCopy);
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
        // push 前占坑：goInFlight 结束后二次 goStart 仍会被 chapterDone/openOnce 拦住
        sNativeOpenChapterDone = YES;
        sDeferredNativeOpenIdx = -1;
        LBAppendOpenReaderTrace(@"goStart preferNativeFull");
        LBSanitizeBookDictForReaderEx(book, YES, YES);
        sPendingNativeFullBook = [book mutableCopy];
        sLegadoReaderMode = 1; // nativeFull
        // 假设 B2：goStart 路径在 content/push 前最早 seed
        LBSeedTurnPageTypeScrollBranch();
        LBInstallSafeTextReadShellHooks(); // 同时装 nativeFull/safeShell 共用钩子
        LBInstallNativeResetContentHook();
        LBInstallReaderContentAppearFlush();
        LBHandleContentRequest(chCopy, buCopy, nil);
        LBWriteOpenReaderMarker(@"nativeOpen beforeCall preferNativeFull=1");
        NSString *orm = nil;
        BOOL opened = NO;
        @try {
            // 栈上已有 TextRead：可见则补投；被目录盖住则 pop 回去（U0-R，禁静默吞点）
            if (LBNavStackHasTextReader()) {
                if (LBIsTextReaderVisible()) {
                    LBAppendOpenReaderTrace(@"goStart deliverOnly readerVisible");
                    LBDeliverContentToVisibleReaders(@"goStartOnStack");
                    sNativeOpenGoInFlight = NO;
                    return;
                }
                if (LBPopToExistingTextReader()) {
                    LBAppendOpenReaderTrace(@"goStart popToReader underCatalog");
                    LBDeliverContentToVisibleReaders(@"goStartPopToStack");
                    sNativeOpenGoInFlight = NO;
                    return;
                }
                LBAppendOpenReaderTrace(@"goStart readerOnStack popFail continuePush");
            }
            // 1) 优先 push TextRead + 原生 viewDidLoad
            // 注意：push 动画期间 LBIsTextReaderVisible 常为 NO，切勿立刻再调 openReader
            // （历史证据：callingOrig 后 SIGABRT 回桌面）。
            LBWriteOpenReaderMarker(@"nativeOpen callingPushNativeFull");
            opened = LBPushTextReaderNativeFull(book, sourceName, &orm);
            if (opened) {
                // push 已触发（或强制 loadView）；给 appear 时间，但不要同步切 safeShell
                for (int wi = 0; wi < 20 && !LBIsTextReaderVisible(); wi++) {
                    [[NSRunLoop currentRunLoop] runUntilDate:
                        [NSDate dateWithTimeIntervalSinceNow:0.1]];
                }
                if (LBIsTextReaderVisible() && sLegadoReaderMode == 1) {
                    LBAppendOpenReaderTrace(@"pushNativeFull visible mode=1");
                } else {
                    LBAppendOpenReaderTrace([NSString stringWithFormat:
                        @"pushNativeFull waitDone vis=%d mode=%d (deferSafeShell)",
                        LBIsTextReaderVisible() ? 1 : 0, sLegadoReaderMode]);
                }
            }
            // 2) 禁止对 Legado 再调 openReader（callingOrig 后 SIGABRT，且会打断 nativeFull）
            // 3) push/loadView 失败 → 仍尝试 nativeFull 重推一次，禁止立刻 safeShell
            if (!opened) {
                LBWriteOpenReaderMarker(@"nativeOpen pushNativeFull miss, retry once (no safeShell)");
                opened = LBPushTextReaderNativeFull(book, sourceName, &orm);
            } else if (opened && sLegadoReaderMode == 1) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.8 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    // 假设 R2：禁止 settle DeliverContent（contentInject 会回书架/桌面）
                    if (LBIsTextReaderVisible() && sLegadoReaderMode == 1) {
                        LBAppendOpenReaderTrace(
                            @"hypothesis_R2 settle2.8_skip_deliver vis=1");
                        return;
                    }
                    LBAppendOpenReaderTrace(
                        @"hypothesis_R2 timeoutKeep_skip_deliver (no safeShell)");
                });
            }
            LBWriteOpenReaderMarker([NSString stringWithFormat:@"nativeOpen origReturned opened=%d mode=%d vis=%d | %@",
                                     opened ? 1 : 0, sLegadoReaderMode,
                                     LBIsTextReaderVisible() ? 1 : 0, orm ?: @"?"]);
        } @catch (NSException *e) {
            orm = [NSString stringWithFormat:@"openReader exception: %@", e.reason ?: @""];
            opened = NO;
            LBWriteOpenReaderMarker([NSString stringWithFormat:@"nativeOpen catch %@", orm]);
        }
        NSString *line = [NSString stringWithFormat:
                          @"nativeOpen opened=%d readerVis=%d mode=%d | %@ || preferNativeFull=1",
                          opened ? 1 : 0, LBIsTextReaderVisible() ? 1 : 0, sLegadoReaderMode, orm ?: @"?"];
        LBWriteOpenReaderMarker(line);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!LBIsTextReaderVisible()) return;
            // 假设 R2：nativeFull 禁 go0.6 Deliver（与 afterPush_skip 同因）
            if (sLegadoReaderMode == 1) {
                LBAppendOpenReaderTrace(@"hypothesis_R2 go0.6_skip_deliver");
                return;
            }
            LBDeliverContentToVisibleReaders(@"go0.6");
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!LBIsTextReaderVisible()) return;
            if (sLegadoReaderMode == 1) {
                LBAppendOpenReaderTrace(@"hypothesis_R2 go1.4_skip_deliver");
                return;
            }
            LBDeliverContentToVisibleReaders(@"go1.4");
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (LBIsTextReaderVisible()) {
                NSString *via = (sLegadoReaderMode == 1) ? @"nativeFull" : @"safeShell";
                LBWriteOpenReaderMarker([NSString stringWithFormat:
                                        @"nativeOpen keepTextRead readerVis=1 via=%@ ch=%@",
                                        via, chCopy]);
                // 结算后复位，避免下次打开本地书误入 Legado 壳
                if (sLegadoReaderMode == 1) {
                    /* 保持 1 直到用户离开阅读页亦可；此处仅清 pending */
                }
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
        } @finally {
            sNativeOpenGoInFlight = NO;
        }
    };
    dispatch_async(dispatch_get_main_queue(), go);
}

@interface LBCatalogCellOpenProxy : NSObject
@end
@implementation LBCatalogCellOpenProxy
- (void)openChapter:(UIButton *)sender {
    NSNumber *idxNum = objc_getAssociatedObject(sender, &kLBCatIdxKey);
    if (![idxNum isKindOfClass:[NSNumber class]]) return;
    // U0-R 探针：区分「点不到」vs「点到被 openOnce 吞」
    [[NSString stringWithFormat:@"cellTap idx=%ld via=LBCatalogCellOpenProxy", (long)idxNum.integerValue]
        writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_catalog_cell_tap.txt"]
         atomically:YES encoding:NSUTF8StringEncoding error:NULL];
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
    // 书架/搜索页：必须走原生 cell
    if (LBVCIsBookShelfContext(self) || LBVCIsSearchTableContext(self) || !LBVCIsCatalogTableContext(self)) {
        IMP fwd = LBForwardTableCellIMP();
        if (fwd) {
            return ((UITableViewCell * (*)(id, SEL, UITableView *, NSIndexPath *))fwd)(self, _cmd, tv, ip);
        }
        return nil;
    }
    NSArray *src = nil;
    NSArray *cat = nil;
    NSArray *base = nil;
    @try {
        id s = [self valueForKey:@"arrSource"];
        if ([s isKindOfClass:[NSArray class]]) src = s;
    } @catch (__unused NSException *e) {}
    @try {
        id c = [self valueForKey:@"arrCatalog"];
        if ([c isKindOfClass:[NSArray class]]) cat = c;
    } @catch (__unused NSException *e) {}
    @try {
        id b = [self valueForKey:@"arrBaseData"];
        if ([b isKindOfClass:[NSArray class]]) base = b;
    } @catch (__unused NSException *e) {}
    // E-02/E-03：用户倒序/过滤后 arrSource（及已 sync 的 pending）优先于引擎原始 pending
    NSArray *use = nil;
    if (LBArrayLooksLikeChapters(src)) use = src;
    else if (sPendingCatalogChapters.count > 0) use = sPendingCatalogChapters;
    else if (LBArrayLooksLikeChapters(cat)) use = cat;
    else if (LBArrayLooksLikeChapters(base)) use = base;
    BOOL legadoFallback = (use.count > 0);
    if (!legadoFallback) {
        IMP fwd = LBForwardTableCellIMP();
        if (fwd) {
            return ((UITableViewCell * (*)(id, SEL, UITableView *, NSIndexPath *))fwd)(self, _cmd, tv, ip);
        }
        return nil;
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
    IMP fwd = LBForwardTableCellIMP();
    if (fwd) {
        return ((UITableViewCell * (*)(id, SEL, UITableView *, NSIndexPath *))fwd)(self, _cmd, tv, ip);
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
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 52;
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 16, 0, 0);
    if (@available(iOS 13.0, *)) {
        self.tableView.backgroundColor = [UIColor systemBackgroundColor];
    }
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"c"];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self lb_reloadFromPending];
}
- (void)lb_reloadFromPending {
    // 仅当 pending 明确属于本书时才采用，避免串书目录
    if (sPendingCatalogChapters.count > 0 &&
        self.bookUrl.length > 0 &&
        sPendingCatalogBookUrl.length > 0 &&
        [sPendingCatalogBookUrl isEqualToString:self.bookUrl]) {
        self.chapters = sPendingCatalogChapters;
    }
    [self.tableView reloadData];
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (self.chapters.count == 0) return @"暂无章节";
    return [NSString stringWithFormat:@"共 %lu 章", (unsigned long)self.chapters.count];
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
    if (@available(iOS 13.0, *)) {
        cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightRegular];
        cell.textLabel.textColor = [UIColor labelColor];
        cell.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    } else {
        cell.textLabel.font = [UIFont systemFontOfSize:16];
    }
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
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
    // AK：统一经 LBLegadoKeyWindow / LBAllAppWindows，bg 不触 windows API
    UIWindow *win = LBLegadoKeyWindow();
    if (!win) {
        NSArray *all = LBAllAppWindows();
        win = all.firstObject;
    }
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

/// 搜索点书：U1 优先原版 CatalogCon（与本地书目录同构）；失败回退 LBLegadoCatalogListVC。
/// 禁区：不要把 BookDetailController 推进导航栈（历史无 ips 回桌面）。
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
        sPendingCatalogSourceUrl = LBOriginSourceUrlFromBookUrl(bu);
    }
    id sn0 = safe[@"sourceName"] ?: safe[@"bookSourceName"] ?: safe[@"querySourceName"];
    if ([sn0 isKindOfClass:[NSString class]] && [(NSString *)sn0 length] > 0) {
        sPendingCatalogSourceName = [(NSString *)sn0 copy];
    } else if (sPendingCatalogSourceName.length == 0) {
        sPendingCatalogSourceName = @"本地静态测试源";
    }
    if (su.length == 0) su = sPendingCatalogSourceUrl;

    if (sPendingCatalogChapters.count > 0 &&
        sPendingCatalogBookUrl.length > 0 &&
        ![sPendingCatalogBookUrl isEqualToString:bu]) {
        // 换书时丢弃串书 pending，避免目录页展示他书章节名
        sPendingCatalogChapters = nil;
    }

    // 强制桥接回退：Documents/legado_u1_catalog_bridge_only.txt 存在则不走 CatalogCon
    BOOL forceBridge = [[NSFileManager defaultManager]
        fileExistsAtPath:[NSHomeDirectory() stringByAppendingPathComponent:
                          @"Documents/legado_u1_catalog_bridge_only.txt"]];

    UIViewController *targetVC = nil;
    NSString *via = @"LBLegadoCatalogListVC";

    if (!forceBridge) {
        Class catCls = NSClassFromString(@"CatalogCon");
        if (catCls) {
            @try {
                id cat = [[catCls alloc] init];
                if ([cat isKindOfClass:[UIViewController class]]) {
                    targetVC = (UIViewController *)cat;
                    via = @"CatalogCon";
                    @try { [targetVC setValue:safe forKey:@"dicBook"]; } @catch (__unused NSException *e) {}
                    @try { [targetVC setValue:bu forKey:@"bookUrl"]; } @catch (__unused NSException *e) {}
                    @try { [targetVC setValue:(su ?: @"") forKey:@"sourceUrl"]; } @catch (__unused NSException *e) {}
                    if (title.length > 0) {
                        @try { targetVC.title = title; } @catch (__unused NSException *e) {}
                    }
                    if (sPendingCatalogChapters.count > 0) {
                        LBWriteChaptersOntoObject(targetVC, sPendingCatalogChapters);
                    }
                    LBInstallCatalogUIAppearFlush();
                }
            } @catch (NSException *e) {
                mark([NSString stringWithFormat:@"searchPush CatalogCon alloc fail: %@", e.reason ?: @""]);
                targetVC = nil;
                via = @"LBLegadoCatalogListVC";
            }
        }
    }

    if (!targetVC) {
        LBLegadoCatalogListVC *list = [[LBLegadoCatalogListVC alloc] initWithStyle:UITableViewStylePlain];
        list.bookUrl = bu;
        list.sourceUrl = su;
        list.bookTitle = title ?: @"目录";
        if (sPendingCatalogChapters.count > 0 &&
            sPendingCatalogBookUrl.length > 0 &&
            [sPendingCatalogBookUrl isEqualToString:bu]) {
            list.chapters = sPendingCatalogChapters;
        }
        targetVC = list;
        via = @"LBLegadoCatalogListVC";
    }

    UINavigationController *nav = [(UIViewController *)searchVC navigationController];
    if (!nav) {
        nav = LBFindBestNavigationController((UIViewController *)searchVC);
    }
    BOOL presentedWrap = NO;
    @try {
        if (nav && [nav.viewControllers containsObject:(UIViewController *)searchVC]) {
            [nav pushViewController:targetVC animated:NO];
        } else if (nav) {
            // 搜索页不在该 nav 栈内时，勿推到隐藏栈；改 present
            UINavigationController *wrap =
                [[UINavigationController alloc] initWithRootViewController:targetVC];
            UIViewController *host = (UIViewController *)searchVC;
            while (host.presentedViewController) host = host.presentedViewController;
            [host presentViewController:wrap animated:NO completion:nil];
            presentedWrap = YES;
            nav = wrap;
        } else {
            UINavigationController *wrap =
                [[UINavigationController alloc] initWithRootViewController:targetVC];
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
          @"searchPushDetail book=%@ src=%@ on=%@ wrap=%d nav=%@ phase=u1catalog forceBridge=%d",
          bu, su ?: @"", via, presentedWrap ? 1 : 0,
          nav ? NSStringFromClass([nav class]) : @"nil", forceBridge ? 1 : 0]);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (sPendingCatalogChapters.count > 0) {
            LBApplyCatalogToUI(sPendingCatalogChapters, bu);
        }
        LBReloadLegadoCatalogListIfVisible();
        NSString *alive = [NSString stringWithFormat:
                           @"searchPush alive via=%@ book=%@ ch=%lu",
                           via, bu, (unsigned long)sPendingCatalogChapters.count];
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

/// 导航栈是否已有 TextRead（push 动画期间 isVisible 常为 NO，防双推 SIGABRT）
static BOOL LBNavStackHasTextReader(void) {
    for (UIWindow *w in LBAllAppWindows()) {
        UIViewController *root = w.rootViewController;
        if (!root) continue;
        NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
        while (stack.count > 0) {
            UIViewController *vc = stack.lastObject;
            [stack removeLastObject];
            NSString *cn = NSStringFromClass([vc class]);
            if ([cn containsString:@"TextReadVC"] || [cn containsString:@"ReadVCBase"]) {
                return YES;
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

static BOOL LBIsTextReaderVisible(void) {
    return LBFindVisibleTextReaderVC() != nil;
}

/// 导航栈内任意 TextRead/ReadVCBase（含被目录盖住、尚未 appear）
static UIViewController *LBFindAnyTextReaderVC(void) {
    for (UIWindow *w in LBAllAppWindows()) {
        UIViewController *root = w.rootViewController;
        if (!root) continue;
        NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
        while (stack.count > 0) {
            UIViewController *vc = stack.lastObject;
            [stack removeLastObject];
            NSString *cn = NSStringFromClass([vc class]);
            if ([cn containsString:@"TextReadVC"] || [cn containsString:@"ReadVCBase"]) {
                return vc;
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
    return nil;
}

/// 目录盖住阅读页时弹回 TextRead（避免 deliverOnly 时用户仍停在目录）
static BOOL LBPopToExistingTextReader(void) {
    UIViewController *reader = LBFindAnyTextReaderVC();
    if (!reader) return NO;
    UINavigationController *nav = reader.navigationController;
    if (!nav) return NO;
    @try {
        [nav popToViewController:reader animated:YES];
        return YES;
    } @catch (__unused NSException *e) {
        return NO;
    }
}

static UIViewController *LBFindVisibleTextReaderVC(void) {
    for (UIWindow *w in LBAllAppWindows()) {
        UIViewController *root = w.rootViewController;
        if (!root) continue;
        NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
        while (stack.count > 0) {
            UIViewController *vc = stack.lastObject;
            [stack removeLastObject];
            NSString *cn = NSStringFromClass([vc class]);
            if ([cn containsString:@"TextReadVC"] || [cn containsString:@"ReadVCBase"]) {
                if (LBVCIsVisibleInWindow(vc)) return vc;
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
    return nil;
}

static IMP LBResolveHookOrigIMP(Class cls, SEL sel) {
    if (NSClassFromString(@"LBDebugPanel")) {
        typedef IMP (*ResolveFn)(Class, SEL);
        static ResolveFn resolve = NULL;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            resolve = (ResolveFn)dlsym(RTLD_DEFAULT, "LBForensicsResolveOrigIMP");
        });
        if (resolve) {
            IMP r = resolve(cls, sel);
            if (r) return r;
        }
    }
    Method m = class_getInstanceMethod(cls, sel);
    return m ? method_getImplementation(m) : NULL;
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
    // nativeFull：注入完整章节；其余模式 lean（灌满章节曾致 callingOrig 后杀进程）
    BOOL injectChapters = (sLegadoReaderMode == 1);
    LBSanitizeBookDictForReaderEx(mutableBook, injectChapters, YES);
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
        LBSanitizeBookDictForReaderEx(merged, injectChapters, YES);
        openBook = merged;
        LBAppendOpenReaderTrace(@"openBook=mergedFull");
    } else if (fullBook != nil) {
        // 非字典书架对象：仍用 dict 调 openReader，record 传 fullBook
        LBAppendOpenReaderTrace([NSString stringWithFormat:@"openBook=dict recordCls=%@",
                                 NSStringFromClass([fullBook class])]);
    } else {
        LBAppendOpenReaderTrace(@"openBook=dict record=nil");
    }
    LBDumpBookDictForOpenReader(
        [openBook isKindOfClass:[NSDictionary class]] ? (NSDictionary *)openBook : mutableBook,
        injectChapters ? @"nativeOpen preCallFull" : @"nativeOpen preCallLean"
    );
    LBAppendOpenReaderTrace([NSString stringWithFormat:@"preCall keys=%lu src=%@ chapters=%@",
                             (unsigned long)mutableBook.count, sourceName ?: @"",
                             injectChapters ? @"YES" : @"NO"]);
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
            NSString *mark = [NSString stringWithFormat:@"nativeOpen callingOrig on %@ chapters=%d rec=%@",
                              cn, injectChapters ? 1 : 0,
                              recordArg ? NSStringFromClass([recordArg class]) : @"nil"];
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
                *outMsg = [NSString stringWithFormat:@"openReader ok on %@ src=%@ chapters=%d",
                           cn, sourceName ?: @"", injectChapters ? 1 : 0];
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

/// 消毒 ResetContent userInfo，避免 @[nil] abort
static NSDictionary *LBSanitizeResetContentUserInfo(NSDictionary *userInfo) {
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    if ([userInfo isKindOfClass:[NSDictionary class]]) {
        [m addEntriesFromDictionary:userInfo];
    }
    for (NSString *k in @[@"chapterUrl", @"chapterContent", @"content", @"cpTitle", @"title",
                          @"bookUrl", @"sourceUrl", @"sourceName", @"cpUrl", @"name",
                          @"bookKey"]) {
        id v = m[k];
        if (v == nil || v == [NSNull null]) {
            m[k] = @"";
        } else if (![v isKindOfClass:[NSString class]] &&
                   ![v isKindOfClass:[NSNumber class]] &&
                   ![v isKindOfClass:[NSArray class]] &&
                   ![v isKindOfClass:[NSDictionary class]]) {
            m[k] = [[v description] copy] ?: @"";
        }
    }
    id errVal = m[@"error"];
    if ([errVal isKindOfClass:[NSString class]] && [(NSString *)errVal length] == 0) {
        [m removeObjectForKey:@"error"];
    } else if (errVal == nil || errVal == [NSNull null]) {
        [m removeObjectForKey:@"error"];
    }
    if (m[@"cpIndex"] == nil || m[@"cpIndex"] == [NSNull null]) {
        // 保留缺省，由 NoteReset 用目录补
    } else if (![m[@"cpIndex"] isKindOfClass:[NSNumber class]]) {
        id cpi = m[@"cpIndex"];
        if ([cpi respondsToSelector:@selector(integerValue)]) {
            m[@"cpIndex"] = @([cpi integerValue]);
        }
    }
    if (![m[@"queryingSourceNameList"] isKindOfClass:[NSArray class]]) {
        NSString *sn = [m[@"sourceName"] isKindOfClass:[NSString class]] ? m[@"sourceName"] : @"";
        m[@"queryingSourceNameList"] = sn.length > 0 ? @[sn] : @[];
    }
    // 去掉易致 native 误判的 bridge 布尔；保留字符串标记
    if (m[@"fromLegadoBridge"] == (id)kCFBooleanTrue ||
        m[@"fromLegadoBridge"] == (id)kCFBooleanFalse) {
        m[@"fromLegadoBridge"] = @"1";
    }
    return m;
}

/// 强制写任意 ivar（避开会 SIGABRT 的 setter）
static BOOL LBForceSetIvar(id obj, NSString *key, id value) {
    if (!obj || key.length == 0) return NO;
    NSString *ivarName = [@"_" stringByAppendingString:key];
    Class cls = object_getClass(obj);
    while (cls && cls != [NSObject class]) {
        Ivar ivar = class_getInstanceVariable(cls, [ivarName UTF8String]);
        if (ivar) {
            object_setIvar(obj, ivar, value);
            return YES;
        }
        cls = class_getSuperclass(cls);
    }
    @try {
        [obj setValue:value forKey:key];
        return YES;
    } @catch (__unused NSException *e) {
        return NO;
    }
}

/// didAppear 前定点消毒：只填已知安全字段，禁止全量空串种子（会触发 name length 断言）
static void LBSeedTextReadAppearFields(id readerVC, NSDictionary *book) {
    if (!readerVC) return;
    NSDictionary *dic = [book isKindOfClass:[NSDictionary class]] ? book : @{};
    NSString *nm = [dic[@"name"] isKindOfClass:[NSString class]] ? dic[@"name"] : @"";
    if (nm.length == 0) {
        nm = [dic[@"bookName"] isKindOfClass:[NSString class]] ? dic[@"bookName"] : @"书";
    }
    NSString *au = [dic[@"author"] isKindOfClass:[NSString class]] ? dic[@"author"] : @"";
    NSString *bk = [dic[@"bookKey"] isKindOfClass:[NSString class]] ? dic[@"bookKey"] : @"";
    if (bk.length == 0) {
        bk = au.length > 0 ? [NSString stringWithFormat:@"%@|%@", nm, au] : nm;
    }
    NSString *sn = [dic[@"sourceName"] isKindOfClass:[NSString class]] ? dic[@"sourceName"] : @"";
    if (sn.length == 0) sn = @"本地静态测试源";
    NSString *bu = [dic[@"bookUrl"] isKindOfClass:[NSString class]] ? dic[@"bookUrl"] : @"";
    NSString *su = [dic[@"sourceUrl"] isKindOfClass:[NSString class]] ? dic[@"sourceUrl"] : @"";
    NSString *cpTitle = [dic[@"cpTitle"] isKindOfClass:[NSString class]] ? dic[@"cpTitle"] : @"";
    if (cpTitle.length == 0) {
        cpTitle = [dic[@"title"] isKindOfClass:[NSString class]] ? dic[@"title"] : @"章节";
    }
    NSString *cpUrl = [dic[@"cpUrl"] isKindOfClass:[NSString class]] ? dic[@"cpUrl"] : @"";
    if (cpUrl.length == 0) {
        cpUrl = [dic[@"chapterUrl"] isKindOfClass:[NSString class]] ? dic[@"chapterUrl"] : @"";
    }
    NSDictionary *fills = @{
        @"name": nm,
        @"bookName": nm,
        @"author": au.length > 0 ? au : @"",
        @"bookKey": bk,
        @"sourceName": sn,
        @"lastSourceName": sn,
        @"querySourceName": sn,
        @"bookSourceName": sn,
        @"bookUrl": bu.length > 0 ? bu : @"",
        @"url": bu.length > 0 ? bu : @"",
        @"sourceUrl": su.length > 0 ? su : @"",
        @"cpTitle": cpTitle,
        @"title": cpTitle,
        @"lastChapterTitle": cpTitle,
        @"chapterName": cpTitle,
        @"cpUrl": cpUrl,
        @"chapterUrl": cpUrl,
        @"curChapterUrl": cpUrl,
        @"sourceType": @"text",
        @"type": @"text",
        @"groupKey": @"",
        @"bookDirPath": [NSHomeDirectory() stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"Documents/xsfolder/book/%@", bk]]
    };
    NSMutableArray *nilKeys = [NSMutableArray array];
    for (NSString *k in fills) {
        id cur = nil;
        @try { cur = [readerVC valueForKey:k]; } @catch (__unused NSException *e) {}
        if (cur == nil || cur == [NSNull null] ||
            ([cur isKindOfClass:[NSString class]] && [(NSString *)cur length] == 0)) {
            if (cur == nil || cur == [NSNull null]) [nilKeys addObject:k];
            id fill = fills[k];
            if ([fill isKindOfClass:[NSString class]] &&
                ([(NSString *)fill length] > 0 ||
                 [k isEqualToString:@"author"] || [k isEqualToString:@"groupKey"] ||
                 [k isEqualToString:@"bookUrl"] || [k isEqualToString:@"url"] ||
                 [k isEqualToString:@"sourceUrl"] || [k isEqualToString:@"cpUrl"] ||
                 [k isEqualToString:@"chapterUrl"] || [k isEqualToString:@"curChapterUrl"])) {
                LBForceSetIvar(readerVC, k, fill);
            }
        }
    }
    // dicContents 必须非 nil，否则排版/换章 @[dicContents[...]] 易崩
    id dicContents = nil;
    @try { dicContents = [readerVC valueForKey:@"dicContents"]; } @catch (__unused NSException *e) {}
    if (![dicContents isKindOfClass:[NSMutableDictionary class]]) {
        NSMutableDictionary *fresh = [NSMutableDictionary dictionary];
        if ([dicContents isKindOfClass:[NSDictionary class]]) {
            [fresh addEntriesFromDictionary:(NSDictionary *)dicContents];
        }
        LBForceSetIvar(readerVC, @"dicContents", fresh);
        if ([readerVC respondsToSelector:@selector(setDicContents:)]) {
            @try {
                ((void (*)(id, SEL, id))objc_msgSend)(readerVC, @selector(setDicContents:), fresh);
            } @catch (__unused NSException *e) {}
        }
    }
    if (nilKeys.count > 0) {
        NSString *joined = [nilKeys componentsJoinedByString:@","];
        if (joined.length > 120) joined = [joined substringToIndex:120];
        LBAppendOpenReaderTrace([NSString stringWithFormat:@"appearSeed nilWas=%@", joined]);
    }
}

/// 假设 B2：ivar 直读对象指针（禁止 pageContainer getter）
static id LBReadIvarObjectByName(id obj, const char *name) {
    if (!obj || !name) return nil;
    Class cls = object_getClass(obj);
    while (cls && cls != [NSObject class]) {
        Ivar iv = class_getInstanceVariable(cls, name);
        if (iv) {
            const char *enc = ivar_getTypeEncoding(iv);
            if (enc && enc[0] == '@') return object_getIvar(obj, iv);
            return nil;
        }
        cls = class_getSuperclass(cls);
    }
    return nil;
}

/// 假设 B2：安全读取实例偏移字节（静态取证 byte@0xbd8）
static uint8_t LBReadByteAtInstanceOffset(id obj, ptrdiff_t offset) {
    if (!obj) return 0xFF;
    @try {
        const volatile uint8_t *base = (const volatile uint8_t *)(__bridge void *)obj;
        return base[offset];
    } @catch (__unused NSException *e) {
        return 0xFE;
    }
}

static BOOL sHypothesisB2LoggedFirstContainer = NO;

/// 假设 B2：记录 pageContainerA ivar 首次非 nil 及 byte@0xbd8（不调 getter）
static void LBLogHypothesisB2ContainerProbe(id readerVC, NSString *phase) {
    if (!readerVC) return;
    id containerA = LBReadIvarObjectByName(readerVC, "_pageContainerA");
    if (!containerA) containerA = LBReadIvarObjectByName(readerVC, "pageContainerA");
    uint8_t bbd8 = LBReadByteAtInstanceOffset(readerVC, (ptrdiff_t)0xbd8);
    NSString *clsA = containerA ? NSStringFromClass(object_getClass(containerA)) : @"nil";
    if (containerA && !sHypothesisB2LoggedFirstContainer) {
        sHypothesisB2LoggedFirstContainer = YES;
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"hypothesis_B2 container_first_seen phase=%@ class=%@ byte@bd8=0x%02x",
                                 phase ?: @"?", clsA, bbd8]);
    }
    LBAppendOpenReaderTrace([NSString stringWithFormat:
                             @"hypothesis_B2 probe phase=%@ pageContainerA=%@ byte@bd8=0x%02x",
                             phase ?: @"?", clsA, bbd8]);
}

/// 滚动工厂 seed：按 pageContainer getter 反汇编（0x100066924–92c）纠偏。
/// cmp type,#3; ccmp bd8,#0,#0,ne; b.eq → TextRPageContainer。
/// 因此 type==3（或 type!=3 且 bd8!=0）才进 TextRScrollContainer；
/// 旧 B2 注释「0=滚动 / 禁 3」与真机证据相反（seed=0+bd8=0 → TextRPageContainer）。
static void LBSeedTurnPageTypeScrollBranch(void) {
    NSInteger v = 3; // 纠偏后：3 → 滚动支路（TextRScrollContainer）
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSInteger was = [ud integerForKey:@"tr_turnPageType"];
    [ud setInteger:v forKey:@"tr_turnPageType"];
    [ud synchronize];
    LBAppendOpenReaderTrace([NSString stringWithFormat:
                             @"scroll_S1 seed tr_turnPageType=%ld (was=%ld) asm=type==3→Scroll ts=%.3f",
                             (long)v, (long)was, CFAbsoluteTimeGetCurrent()]);
}

static BOOL LBHypothesisFContainerClassName(NSString *clsName) {
    if (clsName.length == 0 || [clsName isEqualToString:@"nil"]) return NO;
    if ([clsName isEqualToString:@"TextRScrollContainer"] ||
        [clsName isEqualToString:@"TextRPageContainer"] ||
        [clsName containsString:@"ReadPageContainer"] ||
        [clsName containsString:@"TextRPageContainer"]) {
        return YES;
    }
    return NO;
}

static NSInteger LBHypothesisFContainerPriority(NSString *clsName) {
    if ([clsName isEqualToString:@"TextRPageContainer"]) return 0;
    if ([clsName isEqualToString:@"ReadPageContainer"]) return 1;
    if ([clsName containsString:@"TextRPageContainer"]) return 2;
    if ([clsName containsString:@"ReadPageContainer"]) return 3;
    if ([clsName isEqualToString:@"TextRScrollContainer"]) return 4;
    return 99;
}

/// 假设 F：ORIG_OK 后枚举 ivar/child（禁 pageContainer getter / 手工 alloc）
static void LBHypothesisFProbeAfterOrig(id readerVC, NSString *phase) {
    if (!readerVC) return;
    static const char *kIvarNames[] = {
        "_pageContainerA", "pageContainerA", "_pageContainerB", "pageContainerB",
        "_container", "container", "_pageContainer", "pageContainer",
        "_rPageContainer", "rPageContainer", "_readPageContainer", "readPageContainer",
        "_curPageContainer", "curPageContainer",
    };
    NSMutableArray *ivarParts = [NSMutableArray array];
    for (size_t i = 0; i < sizeof(kIvarNames) / sizeof(kIvarNames[0]); i++) {
        id val = LBReadIvarObjectByName(readerVC, kIvarNames[i]);
        NSString *cls = val ? NSStringFromClass(object_getClass(val)) : @"nil";
        [ivarParts addObject:[NSString stringWithFormat:@"%s=%@", kIvarNames[i], cls]];
    }
    NSMutableArray *childClasses = [NSMutableArray array];
    if ([readerVC isKindOfClass:[UIViewController class]]) {
        for (UIViewController *ch in ((UIViewController *)readerVC).childViewControllers) {
            [childClasses addObject:NSStringFromClass(object_getClass(ch))];
        }
    }
    NSUInteger cat = LBReadArrayCount(readerVC, @"arrCatalog");
    LBAppendOpenReaderTrace([NSString stringWithFormat:
                             @"hypothesis_F probe phase=%@ arrCatalog=%lu ivars={%@} children={%@}",
                             phase ?: @"?", (unsigned long)cat,
                             [ivarParts componentsJoinedByString:@","],
                             [childClasses componentsJoinedByString:@","]]);

    id found = nil;
    NSString *foundVia = nil;
    __block NSInteger bestPrio = 99;
    __block id blockFound = nil;
    __block NSString *blockFoundVia = nil;
    void (^consider)(id, NSString *) = ^(id obj, NSString *via) {
        if (!obj) return;
        NSString *cls = NSStringFromClass(object_getClass(obj));
        if (!LBHypothesisFContainerClassName(cls)) return;
        NSInteger p = LBHypothesisFContainerPriority(cls);
        if (p < bestPrio) {
            bestPrio = p;
            blockFound = obj;
            blockFoundVia = via;
        }
    };
    for (size_t i = 0; i < sizeof(kIvarNames) / sizeof(kIvarNames[0]); i++) {
        consider(LBReadIvarObjectByName(readerVC, kIvarNames[i]),
                 [NSString stringWithFormat:@"ivar:%s", kIvarNames[i]]);
    }
    Class scanCls = object_getClass(readerVC);
    while (scanCls && scanCls != [NSObject class]) {
        unsigned int n = 0;
        Ivar *ivs = class_copyIvarList(scanCls, &n);
        for (unsigned int i = 0; i < n; i++) {
            const char *enc = ivar_getTypeEncoding(ivs[i]);
            if (!enc || enc[0] != '@') continue;
            id val = object_getIvar(readerVC, ivs[i]);
            const char *nm = ivar_getName(ivs[i]);
            consider(val, [NSString stringWithFormat:@"scan:%s", nm ?: "?"]);
        }
        if (ivs) free(ivs);
        scanCls = class_getSuperclass(scanCls);
    }
    id dpv = LBReadIvarObjectByName(readerVC, "_dicPageVC");
    if (!dpv) dpv = LBReadIvarObjectByName(readerVC, "dicPageVC");
    if ([dpv isKindOfClass:[NSDictionary class]]) {
        for (id v in [(NSDictionary *)dpv allValues]) {
            consider(v, @"dicPageVC");
        }
    }
    if ([readerVC isKindOfClass:[UIViewController class]]) {
        NSUInteger idx = 0;
        for (UIViewController *ch in ((UIViewController *)readerVC).childViewControllers) {
            consider(ch, [NSString stringWithFormat:@"child:%lu", (unsigned long)idx]);
            idx++;
        }
    }

    found = blockFound;
    foundVia = blockFoundVia;

    if (found) {
        NSString *foundCls = NSStringFromClass(object_getClass(found));
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"hypothesis_F found class=%@ via=%@",
                                 foundCls, foundVia ?: @"?"]);
        LBLoadCurCpBridgeCacheContainer(readerVC, found);
    } else {
        LBAppendOpenReaderTrace(@"hypothesis_F miss factory未挂child");
    }
}

/// 假设 H：pageContainer getter 只观察 swizzle（VC3/VC2/VC1 全挂，不 break）
typedef id (*LBPageContainerFn)(id, SEL);
static LBPageContainerFn LBOrig_pageContainer_VC3 = NULL;
static LBPageContainerFn LBOrig_pageContainer_VC2 = NULL;
static LBPageContainerFn LBOrig_pageContainer_VC1 = NULL;
static int sHypothesisHPageContainerDepth = 0;

static id LBHypothesisH_pageContainer_core(id self, SEL _cmd, const char *hookOwner,
                                           LBPageContainerFn orig) {
    if (sHypothesisHPageContainerDepth > 0) {
        if (orig) return orig(self, _cmd);
        return nil;
    }
    sHypothesisHPageContainerDepth++;
    @try {
        id containerA = LBReadIvarObjectByName(self, "_pageContainerA");
        if (!containerA) containerA = LBReadIvarObjectByName(self, "pageContainerA");
        NSUInteger cat = LBReadArrayCount(self, @"arrCatalog");
        NSInteger turnType = [[NSUserDefaults standardUserDefaults] integerForKey:@"tr_turnPageType"];
        uint8_t bbd8 = LBReadByteAtInstanceOffset(self, (ptrdiff_t)0xbd8);
        NSString *clsA = containerA ? NSStringFromClass(object_getClass(containerA)) : @"nil";
        NSString *clsSelf = NSStringFromClass(object_getClass(self));
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"hypothesis_H enter cls=%@ hookOwner=%s cat=%lu type=%ld bd8=0x%02x a=%@",
                                 clsSelf, hookOwner, (unsigned long)cat, (long)turnType, bbd8, clsA]);
        id ret = nil;
        if (orig) {
            ret = orig(self, _cmd);
        }
        NSString *retCls = ret ? NSStringFromClass(object_getClass(ret)) : @"nil";
        NSUInteger childCount = 0;
        if ([self isKindOfClass:[UIViewController class]]) {
            childCount = ((UIViewController *)self).childViewControllers.count;
        }
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"hypothesis_H leave cls=%@ hookOwner=%s ret=%@ children=%lu",
                                 clsSelf, hookOwner, retCls, (unsigned long)childCount]);
        return ret;
    } @catch (NSException *ex) {
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"hypothesis_H leave EX cls=%@ hookOwner=%s %@",
                                 NSStringFromClass(object_getClass(self)), hookOwner,
                                 ex.reason ?: @""]);
        if (orig) return orig(self, _cmd);
        return nil;
    } @finally {
        sHypothesisHPageContainerDepth--;
    }
}

static id LBHypothesisH_pageContainer_VC3(id self, SEL _cmd) {
    return LBHypothesisH_pageContainer_core(self, _cmd, "TextReadVC3", LBOrig_pageContainer_VC3);
}

static id LBHypothesisH_pageContainer_VC2(id self, SEL _cmd) {
    return LBHypothesisH_pageContainer_core(self, _cmd, "TextReadVC2", LBOrig_pageContainer_VC2);
}

static id LBHypothesisH_pageContainer_VC1(id self, SEL _cmd) {
    return LBHypothesisH_pageContainer_core(self, _cmd, "TextReadVC1", LBOrig_pageContainer_VC1);
}

static void LBInstallHypothesisHPageContainerHook(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SEL sel = @selector(pageContainer);
        struct {
            const char *cn;
            IMP imp;
            LBPageContainerFn *origSlot;
        } specs[] = {
            {"TextReadVC3", (IMP)LBHypothesisH_pageContainer_VC3, &LBOrig_pageContainer_VC3},
            {"TextReadVC2", (IMP)LBHypothesisH_pageContainer_VC2, &LBOrig_pageContainer_VC2},
            {"TextReadVC1", (IMP)LBHypothesisH_pageContainer_VC1, &LBOrig_pageContainer_VC1},
        };
        for (size_t i = 0; i < sizeof(specs) / sizeof(specs[0]); i++) {
            Class cls = NSClassFromString([NSString stringWithUTF8String:specs[i].cn]);
            if (!cls) continue;
            Method m = class_getInstanceMethod(cls, sel);
            if (!m) continue;
            IMP cur = method_getImplementation(m);
            if (cur == specs[i].imp) continue;
            IMP orig = LBResolveHookOrigIMP(cls, sel);
            if (!orig || orig == specs[i].imp) continue;
            *specs[i].origSlot = (LBPageContainerFn)orig;
            method_setImplementation(m, specs[i].imp);
            LBAppendOpenReaderTrace([NSString stringWithFormat:
                                     @"hypothesis_H hooked pageContainer on %s", specs[i].cn]);
        }
    });
}

/// 假设 J：onReset/pageContainer 工厂同步窗口内 defer addChild/insertSubview，ORIG_OK 后 flush
static BOOL sHypothesisJDeferActive = NO;
static NSMutableArray *sHypothesisJPendingAddChild = nil;
static NSMutableArray *sHypothesisJPendingInsertSubview = nil;
static void (*LBOrig_addChildViewController)(id, SEL, UIViewController *) = NULL;
static void (*LBOrig_insertSubview_atIndex)(id, SEL, UIView *, NSInteger) = NULL;

static void LBHypothesisJResetPending(void) {
    sHypothesisJPendingAddChild = [NSMutableArray array];
    sHypothesisJPendingInsertSubview = [NSMutableArray array];
    sHypothesisJDeferActive = NO;
}

static BOOL LBHypothesisJIsTextReadVCClass(Class cls) {
    NSString *cn = cls ? NSStringFromClass(cls) : @"";
    return [cn containsString:@"TextReadVC"];
}

static BOOL LBHypothesisJViewOwnedByTextReadVC(UIView *view) {
    if (!view) return NO;
    UIResponder *r = view;
    while (r) {
        if ([r isKindOfClass:[UIViewController class]]) {
            return LBHypothesisJIsTextReadVCClass(object_getClass(r));
        }
        r = r.nextResponder;
    }
    return NO;
}

static BOOL LBHypothesisJSubviewIsReadingContainer(UIView *subview) {
    if (!subview) return NO;
    UIResponder *r = subview.nextResponder;
    while (r) {
        if ([r isKindOfClass:[UIViewController class]]) {
            return LBHypothesisFContainerClassName(NSStringFromClass(object_getClass(r)));
        }
        r = r.nextResponder;
    }
    return NO;
}

static void LBHypothesisJ_addChildViewController(id self, SEL _cmd, UIViewController *child) {
    if (sHypothesisJDeferActive && child &&
        LBHypothesisFContainerClassName(NSStringFromClass(object_getClass(child)))) {
        if (!sHypothesisJPendingAddChild) LBHypothesisJResetPending();
        [sHypothesisJPendingAddChild addObject:@{@"parent": self, @"child": child}];
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"hypothesis_J defer_addChild parent=%@ child=%@",
                                 NSStringFromClass(object_getClass(self)),
                                 NSStringFromClass(object_getClass(child))]);
        return;
    }
    if (LBOrig_addChildViewController) {
        LBOrig_addChildViewController(self, _cmd, child);
    }
}

static void LBHypothesisJ_insertSubview_atIndex(id self, SEL _cmd, UIView *subview, NSInteger index) {
    if (sHypothesisJDeferActive && [self isKindOfClass:[UIView class]] &&
        LBHypothesisJViewOwnedByTextReadVC((UIView *)self) &&
        LBHypothesisJSubviewIsReadingContainer(subview)) {
        if (!sHypothesisJPendingInsertSubview) LBHypothesisJResetPending();
        [sHypothesisJPendingInsertSubview addObject:@{
            @"parentView": self,
            @"subview": subview,
            @"index": @(index),
        }];
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"hypothesis_J defer_insertSubview idx=%ld parent=%@ sub=%@",
                                 (long)index,
                                 NSStringFromClass(object_getClass(self)),
                                 NSStringFromClass(object_getClass(subview))]);
        return;
    }
    if (LBOrig_insertSubview_atIndex) {
        LBOrig_insertSubview_atIndex(self, _cmd, subview, index);
    }
}

static BOOL LBHypothesisJPendingOwnedByReader(id readerVC, id parent, UIView *parentView) {
    if (!readerVC) return YES;
    if (parent == readerVC) return YES;
    if (parentView && LBHypothesisJViewOwnedByTextReadVC(parentView)) return YES;
    if (parent && [parent isKindOfClass:[UIViewController class]]) {
        UIViewController *pvc = (UIViewController *)parent;
        UIResponder *r = pvc;
        while (r) {
            if (r == readerVC) return YES;
            if ([r isKindOfClass:[UIViewController class]]) {
                UIViewController *vc = (UIViewController *)r;
                if (vc.parentViewController == readerVC) return YES;
            }
            r = r.nextResponder;
        }
    }
    return NO;
}

static void LBHypothesisJFlushDeferred(id readerVC) {
    if (!sHypothesisJPendingAddChild) return;
    NSUInteger addN = 0;
    NSUInteger insN = 0;
    NSMutableArray *remainAdd = [NSMutableArray array];
    for (NSDictionary *item in sHypothesisJPendingAddChild) {
        id parent = item[@"parent"];
        id child = item[@"child"];
        if (!LBHypothesisJPendingOwnedByReader(readerVC, parent, nil)) {
            [remainAdd addObject:item];
            continue;
        }
        if (LBOrig_addChildViewController && parent && child) {
            LBOrig_addChildViewController(parent, @selector(addChildViewController:), child);
            addN++;
        } else {
            // scroll-S3：勿静默丢 pending（否则 children 一直为 0，loadCp 打 orphan）
            [remainAdd addObject:item];
            LBAppendOpenReaderTrace([NSString stringWithFormat:
                                     @"hypothesis_J flush_add_drop parent=%@ child=%@ orig_add=%p",
                                     parent ? NSStringFromClass(object_getClass(parent)) : @"nil",
                                     child ? NSStringFromClass(object_getClass(child)) : @"nil",
                                     LBOrig_addChildViewController]);
        }
    }
    sHypothesisJPendingAddChild = remainAdd;

    NSMutableArray *remainIns = [NSMutableArray array];
    for (NSDictionary *item in sHypothesisJPendingInsertSubview) {
        UIView *parentView = item[@"parentView"];
        UIView *subview = item[@"subview"];
        NSNumber *idxNum = item[@"index"];
        if (!LBHypothesisJPendingOwnedByReader(readerVC, nil, parentView)) {
            [remainIns addObject:item];
            continue;
        }
        if (LBOrig_insertSubview_atIndex && parentView && subview) {
            LBOrig_insertSubview_atIndex(parentView, @selector(insertSubview:atIndex:),
                                        subview, idxNum ? idxNum.integerValue : 0);
            insN++;
        } else {
            [remainIns addObject:item];
            LBAppendOpenReaderTrace([NSString stringWithFormat:
                                     @"hypothesis_J flush_ins_drop parent=%@ sub=%@ orig_ins=%p",
                                     parentView ? NSStringFromClass(object_getClass(parentView)) : @"nil",
                                     subview ? NSStringFromClass(object_getClass(subview)) : @"nil",
                                     LBOrig_insertSubview_atIndex]);
        }
    }
    sHypothesisJPendingInsertSubview = remainIns;

    if (addN > 0 || insN > 0) {
        id containerA = readerVC ? LBReadIvarObjectByName(readerVC, "_pageContainerA") : nil;
        if (!containerA && readerVC) {
            containerA = LBReadIvarObjectByName(readerVC, "pageContainerA");
        }
        id containerB = readerVC ? LBReadIvarObjectByName(readerVC, "_pageContainerB") : nil;
        if (!containerB && readerVC) {
            containerB = LBReadIvarObjectByName(readerVC, "pageContainerB");
        }
        NSString *clsA = containerA ? NSStringFromClass(object_getClass(containerA)) : @"nil";
        NSString *clsB = containerB ? NSStringFromClass(object_getClass(containerB)) : @"nil";
        NSUInteger childCount = 0;
        if ([readerVC isKindOfClass:[UIViewController class]]) {
            childCount = ((UIViewController *)readerVC).childViewControllers.count;
        }
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"hypothesis_J deferred_attach_OK add=%lu insert=%lu children=%lu "
                                 @"pageContainerA=%@ pageContainerB=%@",
                                 (unsigned long)addN, (unsigned long)insN,
                                 (unsigned long)childCount, clsA, clsB]);
    } else if (sHypothesisJPendingAddChild.count + sHypothesisJPendingInsertSubview.count > 0) {
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"hypothesis_J deferred_attach_SKIP remain_add=%lu remain_ins=%lu orig_add=%p",
                                 (unsigned long)sHypothesisJPendingAddChild.count,
                                 (unsigned long)sHypothesisJPendingInsertSubview.count,
                                 LBOrig_addChildViewController]);
    } else {
        LBAppendOpenReaderTrace(@"hypothesis_J deferred_attach_EMPTY");
    }
}

static void LBInstallHypothesisJHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!sHypothesisJPendingAddChild) LBHypothesisJResetPending();
        SEL addSel = @selector(addChildViewController:);
        for (NSString *cn in @[@"TextReadVC3", @"TextReadVC2", @"TextReadVC1"]) {
            Class cls = NSClassFromString(cn);
            if (!cls) continue;
            Method m = class_getInstanceMethod(cls, addSel);
            if (!m) continue;
            IMP cur = method_getImplementation(m);
            if (cur == (IMP)LBHypothesisJ_addChildViewController) continue;
            if (!LBOrig_addChildViewController) {
                IMP orig = LBResolveHookOrigIMP(cls, addSel);
                if (!orig || orig == (IMP)LBHypothesisJ_addChildViewController) continue;
                LBOrig_addChildViewController = (void (*)(id, SEL, UIViewController *))orig;
            }
            method_setImplementation(m, (IMP)LBHypothesisJ_addChildViewController);
            LBAppendOpenReaderTrace([NSString stringWithFormat:
                                     @"hypothesis_J hooked addChildViewController on %@", cn]);
        }
        SEL insSel = @selector(insertSubview:atIndex:);
        Class viewCls = [UIView class];
        Method vm = class_getInstanceMethod(viewCls, insSel);
        if (vm) {
            IMP cur = method_getImplementation(vm);
            if (cur != (IMP)LBHypothesisJ_insertSubview_atIndex) {
                IMP orig = LBResolveHookOrigIMP(viewCls, insSel);
                if (orig && orig != (IMP)LBHypothesisJ_insertSubview_atIndex) {
                    LBOrig_insertSubview_atIndex =
                        (void (*)(id, SEL, UIView *, NSInteger))orig;
                    method_setImplementation(vm, (IMP)LBHypothesisJ_insertSubview_atIndex);
                    LBAppendOpenReaderTrace(@"hypothesis_J hooked insertSubview:atIndex: on UIView");
                }
            }
        }
    });
}

/// 假设 E：window+catalog+didAppearUIKit 就绪后再调无参 onReset ORIG
static void LBHypothesisEFireOnResetNoArg(id selfObj, SEL sel, LBOnResetNoArgFn origNoArg,
                                          NSString *fireTag) {
    if (!selfObj || !origNoArg) return;
    UIViewController *vc = (UIViewController *)selfObj;
    NSUInteger cat = LBReadArrayCount(selfObj, @"arrCatalog");
    BOOL hasWindow = (vc.viewIfLoaded.window != nil);
    LBAppendOpenReaderTrace([NSString stringWithFormat:
                             @"hypothesis_E pre_fire cat=%lu appeared=%d",
                             (unsigned long)cat, sDidAppearUIKit ? 1 : 0]);
    if (cat < 1) {
        LBAppendOpenReaderTrace(@"hypothesis_E defer_onReset reason=no_catalog");
        return;
    }
    if (!hasWindow) {
        LBAppendOpenReaderTrace(@"hypothesis_C defer_onReset reason=no_window");
        return;
    }
    if (!sDidAppearUIKit) {
        LBAppendOpenReaderTrace(@"hypothesis_E defer_onReset reason=no_didAppear");
        return;
    }
    LBSeedTurnPageTypeScrollBranch();
    LBLogHypothesisB2ContainerProbe(selfObj, @"onReset_noArg_before_ORIG");
    LBAppendOpenReaderTrace([NSString stringWithFormat:@"hypothesis_C fire_onReset %@",
                                                         fireTag ?: @"?"]);
    IMP origIMP = (IMP)origNoArg;
    IMP resolved = LBResolveOnResetNoArgNativeIMP([selfObj class], sel, origIMP);
    if (!resolved) resolved = sOnResetNoArgNativeIMP;
    LBOnResetNoArgFn fireFn = resolved ? (LBOnResetNoArgFn)resolved : origNoArg;
    LBAppendOpenReaderTrace([NSString stringWithFormat:
                             @"hypothesis_I fire orig=%p resolved=%p dl=%@",
                             origIMP, resolved ?: origIMP,
                             LBLookupIMPDlName((IMP)fireFn)]);
    BOOL origOk = NO;
    @try {
        sHypothesisJDeferActive = YES;
        fireFn(selfObj, sel);
        LBLogHypothesisB2ContainerProbe(selfObj, @"onReset_noArg_after_ORIG");
        id containerA = LBReadIvarObjectByName(selfObj, "_pageContainerA");
        if (!containerA) containerA = LBReadIvarObjectByName(selfObj, "pageContainerA");
        NSString *clsA = containerA ? NSStringFromClass(object_getClass(containerA)) : @"nil";
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"hypothesis_E after_ORIG pageContainerA=%@", clsA]);
        LBAppendOpenReaderTrace(@"hypothesis_C onReset noArg ORIG_OK");
        origOk = YES;
    } @catch (NSException *ex) {
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"hypothesis_C onReset noArg ORIG_EX %@",
                                 ex.reason ?: @""]);
    } @finally {
        sHypothesisJDeferActive = NO;
        if (origOk) {
            // scroll-S3：必须先 flush addChild/insertSubview，再 F 探针→loadCp。
            // 旧序在 orphan TextRScrollContainer 上 invoke_loadCp，随后回空书架。
            LBHypothesisJFlushDeferred(selfObj);
        } else {
            [sHypothesisJPendingAddChild removeAllObjects];
            [sHypothesisJPendingInsertSubview removeAllObjects];
        }
    }
    if (origOk) {
        LBHypothesisFProbeAfterOrig(selfObj, @"onReset_noArg_after_ORIG");
    }
}

static void LBHypothesisEScheduleOnResetNoArg(UIViewController *vc, SEL sel,
                                              LBOnResetNoArgFn origNoArg, int attempt,
                                              void (^onDone)(void)) {
    static const int kMaxAttempts = 25;
    static const NSTimeInterval kRetrySec = 0.08;

    __weak UIViewController *weakVC = vc;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRetrySec * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIViewController *strongVC = weakVC;
        if (!strongVC) {
            if (onDone) onDone();
            return;
        }
        NSUInteger cat = LBReadArrayCount(strongVC, @"arrCatalog");
        BOOL hasWindow = (strongVC.viewIfLoaded.window != nil);
        if (cat >= 1 && hasWindow && sDidAppearUIKit) {
            LBHypothesisEFireOnResetNoArg(strongVC, sel, origNoArg, @"ready");
            if (onDone) onDone();
            return;
        }
        if (attempt + 1 < kMaxAttempts) {
            if (cat < 1) {
                LBAppendOpenReaderTrace(@"hypothesis_E defer_onReset reason=no_catalog");
            } else if (!hasWindow) {
                LBAppendOpenReaderTrace(@"hypothesis_C defer_onReset reason=no_window");
            } else if (!sDidAppearUIKit) {
                LBAppendOpenReaderTrace(@"hypothesis_E defer_onReset reason=no_didAppear");
            }
            LBHypothesisEScheduleOnResetNoArg(strongVC, sel, origNoArg, attempt + 1, onDone);
        } else {
            if (cat < 1) {
                LBAppendOpenReaderTrace(@"hypothesis_E defer_onReset exhausted reason=no_catalog");
            } else if (!sDidAppearUIKit) {
                LBAppendOpenReaderTrace(@"hypothesis_E defer_onReset exhausted reason=no_didAppear");
            } else {
                LBAppendOpenReaderTrace(@"hypothesis_C defer_onReset exhausted reason=no_window");
            }
            if (onDone) onDone();
        }
    });
}

/// nativeFull：进入原生 viewDidLoad 前消毒/灌 dicBook + 关键数组
static void LBPrepareTextReadNativeFull(id readerVC, NSDictionary *book) {
    if (!readerVC) return;
    LBSeedTurnPageTypeScrollBranch();
    NSMutableDictionary *dic = nil;
    if ([book isKindOfClass:[NSMutableDictionary class]]) {
        dic = (NSMutableDictionary *)book;
    } else if ([book isKindOfClass:[NSDictionary class]]) {
        dic = [NSMutableDictionary dictionaryWithDictionary:(NSDictionary *)book];
    } else if ([sPendingNativeFullBook isKindOfClass:[NSDictionary class]]) {
        dic = [NSMutableDictionary dictionaryWithDictionary:sPendingNativeFullBook];
    } else {
        dic = [NSMutableDictionary dictionary];
    }
    LBSanitizeBookDictForReaderEx(dic, YES, YES);
    sPendingNativeFullBook = [dic mutableCopy];
    // 注意：禁止把所有 nil NSString 填成 @""——真机 loadView 会断言
    // (name != nil) && ([name length] > 0)。只灌已知安全字段。
    LBSeedTextReadAppearFields(readerVC, dic);

    // 数组/字典属性兜底
    NSArray *arrKeys = @[@"arrCatalog", @"arrChapter", @"arrBaseData", @"arrCpInfo",
                         @"arrSource", @"arrSourceType", @"chapterList"];
    for (NSString *k in arrKeys) {
        id cur = nil;
        @try { cur = [readerVC valueForKey:k]; } @catch (__unused NSException *e) {}
        if (cur == nil || cur == [NSNull null]) {
            id fromBook = dic[k];
            if ([fromBook isKindOfClass:[NSArray class]]) {
                LBForceSetIvar(readerVC, k, fromBook);
            } else {
                LBForceSetIvar(readerVC, k, @[]);
            }
        }
    }
    for (NSString *k in @[@"dicBook", @"dicConfig", @"dicBookOrShupingInfo"]) {
        id cur = nil;
        @try { cur = [readerVC valueForKey:k]; } @catch (__unused NSException *e) {}
        if (cur == nil || cur == [NSNull null]) {
            if ([k isEqualToString:@"dicBook"]) {
                LBForceSetIvar(readerVC, k, dic);
            } else {
                LBForceSetIvar(readerVC, k, @{});
            }
        }
    }
    // 优先 ivar 写 dicBook（避开 setDicBook SIGABRT）
    LBForceSetIvar(readerVC, @"dicBook", dic);
    id cats = dic[@"arrCatalog"];
    if ([cats isKindOfClass:[NSArray class]]) {
        LBTrySetArrayKey(readerVC, @"arrCatalog", cats);
        LBTrySetArrayKey(readerVC, @"arrBaseData", cats);
        LBTrySetArrayKey(readerVC, @"arrCpInfo", cats);
    }
    LBAppendOpenReaderTrace([NSString stringWithFormat:
                             @"nativeFull prep keys=%lu cat=%lu",
                             (unsigned long)dic.count,
                             [cats isKindOfClass:[NSArray class]] ? (unsigned long)[(NSArray *)cats count] : 0]);
}

/// 扫描谁实现 divisionText / showContent（TextReadTV 上曾 noSel）
static void LBLogDivisionSelectors(id sampleTV) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *hits = [NSMutableArray array];
        SEL s1 = NSSelectorFromString(
            @"divisionText:cpTitle:cpIndex:tvSize:doubleCol:backHeights:");
        SEL s2 = NSSelectorFromString(
            @"divisionText:cpTitle:cpIndex:tvSize:doubleCol:backHeights:paibanInfo:");
        SEL s3 = NSSelectorFromString(@"showContent:title:");
        SEL s4 = NSSelectorFromString(@"showContent:");
        void (^probeCls)(Class) = ^(Class cls) {
            if (!cls) return;
            Class cur = cls;
            int depth = 0;
            while (cur && cur != [NSObject class] && depth++ < 8) {
                unsigned int n = 0;
                Method *ms = class_copyMethodList(cur, &n);
                for (unsigned int i = 0; i < n; i++) {
                    NSString *nm = NSStringFromSelector(method_getName(ms[i]));
                    if ([nm containsString:@"division"] || [nm hasPrefix:@"showContent"]) {
                        const char *te = method_getTypeEncoding(ms[i]) ?: "?";
                        [hits addObject:[NSString stringWithFormat:@"%@::%@ enc=%s",
                                         NSStringFromClass(cur), nm, te]];
                    }
                }
                if (ms) free(ms);
                if (class_getInstanceMethod(cur, s1) || class_getInstanceMethod(cur, s2) ||
                    class_getClassMethod(cur, s1) || class_getClassMethod(cur, s2) ||
                    class_getInstanceMethod(cur, s3) || class_getInstanceMethod(cur, s4)) {
                    [hits addObject:[NSString stringWithFormat:@"has %@", NSStringFromClass(cur)]];
                }
                cur = class_getSuperclass(cur);
            }
        };
        if (sampleTV) probeCls([sampleTV class]);
        for (NSString *cn in @[@"TextReadTV", @"TextReadTVBase", @"LCCoreTextUtil",
                               @"PaibanManager", @"TextReadPaibanList",
                               @"TextReadVC3", @"ReadVCBase2", @"ReadPageContainer",
                               @"TextRPageContainer", @"ReadScrollContainer",
                               @"ReadPageModel", @"ReadErrorView"]) {
            probeCls(NSClassFromString(cn));
        }
        unsigned int ccount = 0;
        Class *clslist = objc_copyClassList(&ccount);
        int found = 0;
        for (unsigned int i = 0; i < ccount && found < 16; i++) {
            Class c = clslist[i];
            if (class_getInstanceMethod(c, s2) || class_getInstanceMethod(c, s1) ||
                class_getClassMethod(c, s2) || class_getClassMethod(c, s1)) {
                [hits addObject:[NSString stringWithFormat:@"owner %@", NSStringFromClass(c)]];
                found++;
            }
        }
        if (clslist) free(clslist);
        NSString *msg = hits.count ? [hits componentsJoinedByString:@" | "] : @"none";
        if (msg.length > 1200) msg = [msg substringToIndex:1200];
        LBAppendOpenReaderTrace([NSString stringWithFormat:@"divisionProbe %@", msg]);
    });
}

/// divisionText 返回的 backHeights（供 ReadScrollContainer divisionResponse 使用）
static NSMutableArray *sLastDivisionHeights = nil;
/// 最近一次 LBNormalizePageResultForDivision 结果（供 processPageData 绑定）
static id sLastNormalizedDrPages = nil;

/// 调用 divisionText；返回分页结果（常为 NSArray），void 成功时返回 @(YES)
static id LBCallDivisionText(id target, BOOL targetIsClass, NSString *body, NSString *title,
                             NSInteger cpIndex, CGSize tvSize, id paibanInfo) {
    if (!target || body.length == 0) return nil;
    SEL sel2 = NSSelectorFromString(
        @"divisionText:cpTitle:cpIndex:tvSize:doubleCol:backHeights:paibanInfo:");
    SEL sel1 = NSSelectorFromString(
        @"divisionText:cpTitle:cpIndex:tvSize:doubleCol:backHeights:");
    Class cls = targetIsClass ? (Class)target : object_getClass(target);
    Method m = NULL;
    if (targetIsClass) {
        m = class_getClassMethod(cls, sel2) ?: class_getClassMethod(cls, sel1);
    } else {
        m = class_getInstanceMethod(cls, sel2) ?: class_getInstanceMethod(cls, sel1);
    }
    if (!m) return nil;
    SEL useSel = method_getName(m);
    const char *te = method_getTypeEncoding(m);
    if (!te) return nil;
    NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:te];
    if (!sig) return nil;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setSelector:useSel];
    [inv setTarget:target];
    NSString *argBody = body;
    NSString *argTitle = title ?: @"";
    NSInteger argIdx = cpIndex;
    CGSize sz = tvSize;
    if (sz.width < 10) sz.width = 350;
    if (sz.height < 10) sz.height = 500;
    BOOL doubleCol = NO;
    NSMutableArray *heights = [NSMutableArray array];
    // 原生可能原地改 paiban / backHeights
    NSMutableDictionary *paiban =
        [paibanInfo isKindOfClass:[NSDictionary class]]
            ? [NSMutableDictionary dictionaryWithDictionary:(NSDictionary *)paibanInfo]
            : [NSMutableDictionary dictionary];
    NSUInteger argc = sig.numberOfArguments;
    if (argc > 2) [inv setArgument:&argBody atIndex:2];
    if (argc > 3) [inv setArgument:&argTitle atIndex:3];
    if (argc > 4) [inv setArgument:&argIdx atIndex:4];
    if (argc > 5) [inv setArgument:&sz atIndex:5];
    if (argc > 6) [inv setArgument:&doubleCol atIndex:6];
    if (argc > 7) [inv setArgument:&heights atIndex:7];
    if (argc > 8) [inv setArgument:&paiban atIndex:8];
    [inv retainArguments];
    sLastDivisionHeights = heights;
    @try {
        [inv invoke];
    } @catch (NSException *ex) {
        LBAppendOpenReaderTrace([NSString stringWithFormat:@"divisionText invoke EX %@",
                                 ex.reason ?: @""]);
        return nil;
    }
    const char *ret = sig.methodReturnType;
    if (ret && ret[0] == '@') {
        __unsafe_unretained id result = nil;
        [inv getReturnValue:&result];
        return result;
    }
    return @(YES);
}

/// 从 ReadPageModel 提取纯文本（CTFrame 控件 KVC text 常为空）
static NSString *LBExtractPlainFromPageModel(id model) {
    if (!model) return nil;
    if ([model isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)model) {
            NSString *s = LBExtractPlainFromPageModel(item);
            if (s.length > 0) return s;
        }
        return nil;
    }
    if ([model isKindOfClass:[NSAttributedString class]]) {
        return [(NSAttributedString *)model string];
    }
    if ([model isKindOfClass:[NSString class]]) {
        return (NSString *)model;
    }
    @try {
        for (NSString *k in @[@"attrStr", @"pageAttrStr", @"contentAttr", @"attributedText",
                              @"attrText", @"pageAttr", @"pageAttributedString", @"attr"]) {
            id v = nil;
            @try { v = [model valueForKey:k]; } @catch (__unused NSException *e) {}
            if ([v isKindOfClass:[NSAttributedString class]]) {
                NSString *s = [(NSAttributedString *)v string];
                if (s.length > 0) return s;
            }
        }
        for (NSString *k in @[@"text", @"content", @"pageText", @"string"]) {
            id v = nil;
            @try { v = [model valueForKey:k]; } @catch (__unused NSException *e) {}
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) return v;
        }
        Class cls = object_getClass(model);
        while (cls && cls != [NSObject class]) {
            unsigned int count = 0;
            Ivar *ivars = class_copyIvarList(cls, &count);
            if (ivars) {
                for (unsigned int i = 0; i < count; i++) {
                    const char *itype = ivar_getTypeEncoding(ivars[i]);
                    if (!itype || itype[0] != '@') continue;
                    id v = object_getIvar(model, ivars[i]);
                    if ([v isKindOfClass:[NSAttributedString class]] &&
                        [(NSAttributedString *)v length] > 0) {
                        free(ivars);
                        return [(NSAttributedString *)v string];
                    }
                    if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) {
                        free(ivars);
                        return v;
                    }
                }
                free(ivars);
            }
            cls = class_getSuperclass(cls);
        }
    } @catch (__unused NSException *e) {}
    return nil;
}

/// 验收探针：仅 Debug 包写 accessibility*（MCP assert_text_present）
static void LBStampTextReadTVProbe(UIView *tv, id pageModel, NSString *body) {
    if (!LBBridgeDebugLoaded()) return;
    if (!tv) return;
    NSString *plain = LBExtractPlainFromPageModel(pageModel);
    if (plain.length == 0 && [body isKindOfClass:[NSString class]]) plain = body;
    if (plain.length == 0) return;
    NSUInteger cap = MIN((NSUInteger)plain.length, 2400UL);
    NSString *probe = [plain substringToIndex:cap];
    @try {
        tv.accessibilityLabel = probe;
        tv.accessibilityValue = probe;
        tv.isAccessibilityElement = YES;
    } @catch (__unused NSException *e) {}
}

static void LBDumpReadPageModelIvars(id model);
static BOOL LBReadPageModelHasCTFrame(id model);
static BOOL LBTextReadTVHasRenderedNeedle(UIView *tv, NSString *needle);
static BOOL LBVerifyNativeOnScreenHost(UIView *textReadTV, UIViewController *readerVC,
                                       id host, NSMutableArray *okPaths);
static void LBForceTextReadTVRefresh(UIView *textReadTV);
static BOOL LBApplyPageModelToTextReadTV(UIView *textReadTV, id pageModel, NSString *body,
                                         CGSize tvSize, NSMutableArray *okPaths, NSString *tag);
static id LBWrapAttrAsReadPageModelTemplate(id page, id template, CGSize tvSize);

/// 诊断：dump ReadPageModel ivar 名/类型（对照 hook103，只读落盘）
static void LBDumpReadPageModelIvars(id model) {
    if (!model) return;
    Class cls = object_getClass(model);
    NSMutableArray *parts = [NSMutableArray array];
    while (cls && cls != [NSObject class] && parts.count < 24) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        if (ivars) {
            for (unsigned int i = 0; i < count; i++) {
                const char *iname = ivar_getName(ivars[i]);
                const char *itype = ivar_getTypeEncoding(ivars[i]);
                if (!iname) continue;
                NSString *entry = [NSString stringWithFormat:@"%s:%s",
                                   iname, itype ? itype : "?"];
                [parts addObject:entry];
                if (parts.count >= 24) break;
            }
            free(ivars);
        }
        cls = class_getSuperclass(cls);
    }
    NSString *plain = LBExtractPlainFromPageModel(model);
    LBAppendOpenReaderTrace([NSString stringWithFormat:
                             @"contentInject rpmDump cls=%@ ivars=%@ ct=%d txtLen=%lu",
                             NSStringFromClass([model class]),
                             [parts componentsJoinedByString:@","],
                             LBReadPageModelHasCTFrame(model) ? 1 : 0,
                             (unsigned long)plain.length]);
}

/// divisionText 常为 @[pages] / @[@[page...]]；统一为 @[Attr|RPM...]（禁把 NSArray 当 Attr 喂 length）
static NSArray *LBFlattenDivisionPages(id pageResult) {
    if (!pageResult) return nil;
    if (![pageResult isKindOfClass:[NSArray class]]) return @[pageResult];
    id cur = pageResult;
    int unwrapN = 0;
    while ([cur isKindOfClass:[NSArray class]] && [(NSArray *)cur count] == 1 && unwrapN < 4) {
        id first = [(NSArray *)cur firstObject];
        if (![first isKindOfClass:[NSArray class]]) break;
        cur = first;
        unwrapN++;
    }
    if (![cur isKindOfClass:[NSArray class]]) return @[cur];
    if (unwrapN > 0) {
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"contentInject flatten x%d count=%lu first=%@",
                                 unwrapN, (unsigned long)[(NSArray *)cur count],
                                 [(NSArray *)cur count] > 0
                                     ? NSStringFromClass([[cur firstObject] class]) : @"-"]);
    }
    return cur;
}

/// onFinish 入参诊断（禁对 NSArray 调 length，只用 count）
static NSString *LBDescribeOnFinishArg(id arg) {
    if (!arg) return @"(null)";
    if ([arg isKindOfClass:[NSArray class]]) {
        NSArray *arr = (NSArray *)arg;
        NSMutableArray *elemCls = [NSMutableArray array];
        NSUInteger n = arr.count < 4 ? arr.count : 4;
        for (NSUInteger i = 0; i < n; i++) {
            [elemCls addObject:NSStringFromClass([[arr objectAtIndex:i] class])];
        }
        return [NSString stringWithFormat:@"%@[cnt=%lu,elem=%@]",
                NSStringFromClass([arg class]), (unsigned long)arr.count,
                [elemCls componentsJoinedByString:@","]];
    }
    return NSStringFromClass([arg class]);
}

/// onDivisionTextFinish 须 divisionText 原生产物（禁 flatten 后再 nest / 禁 wrapReadPageModel）
static id LBPrepareOnFinishArgFromDivisionText(id divisionTextRaw) {
    if (!divisionTextRaw) return nil;
    LBAppendOpenReaderTrace([NSString stringWithFormat:@"onFinish_raw=%@",
                             LBDescribeOnFinishArg(divisionTextRaw)]);
    id arg = divisionTextRaw;
    NSArray *top = nil;
    if ([arg isKindOfClass:[NSArray class]]) {
        top = (NSArray *)arg;
    } else if ([arg isKindOfClass:[NSAttributedString class]] ||
               [arg isKindOfClass:[NSString class]]) {
        top = @[arg];
        arg = top;
    } else {
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"onFinish_arg=REJECT root=%@",
                                 NSStringFromClass([divisionTextRaw class])]);
        return nil;
    }
    // divisionText 常为 @[@[Attr...]]；解一层到页列 @[Attr...]（再 nest 会 NSArrayM length）
    if (top.count == 1 && [top.firstObject isKindOfClass:[NSArray class]]) {
        arg = top.firstObject;
        top = (NSArray *)arg;
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"onFinish_arg unwrap1=%@",
                                 LBDescribeOnFinishArg(arg)]);
    }
    Class rpmCls = NSClassFromString(@"ReadPageModel");
    for (id p in top) {
        if (rpmCls && [p isKindOfClass:rpmCls]) {
            LBAppendOpenReaderTrace(@"onFinish_arg=REJECT ReadPageModel (use divisionText Attr)");
            return nil;
        }
        if ([p isKindOfClass:[NSArray class]]) {
            for (id inner in (NSArray *)p) {
                if (rpmCls && [inner isKindOfClass:rpmCls]) {
                    LBAppendOpenReaderTrace(@"onFinish_arg=REJECT nestedRPM");
                    return nil;
                }
            }
            continue;
        }
        if (![p isKindOfClass:[NSAttributedString class]] &&
            ![p isKindOfClass:[NSString class]]) {
            LBAppendOpenReaderTrace([NSString stringWithFormat:
                                     @"onFinish_arg=REJECT elem=%@",
                                     NSStringFromClass([p class])]);
            return nil;
        }
    }
    LBAppendOpenReaderTrace([NSString stringWithFormat:@"onFinish_arg=%@",
                             LBDescribeOnFinishArg(arg)]);
    return arg;
}

static NSArray *LBCollectDivisionHosts(UIViewController *readerVC);

/// onDivisionTextFinish 成功后：尝试对 container.textViewL/R 走 setPageModel:（有 sel 才调，禁 KVC）
static void LBApplyPagesToContainerTextViews(id host, id pages, NSString *body, CGSize tvSize,
                                             NSMutableArray *okPaths) {
    if (!host || !pages) return;
    NSArray *flat = LBFlattenDivisionPages(pages);
    if (flat.count == 0) return;
    id page0 = flat.firstObject;
    if ([page0 isKindOfClass:[NSArray class]]) return;
    Class rpmCls = NSClassFromString(@"ReadPageModel");
    id rpm = page0;
    if (!rpmCls || ![page0 isKindOfClass:rpmCls]) {
        if ([page0 isKindOfClass:[NSAttributedString class]] ||
            [page0 isKindOfClass:[NSString class]]) {
            rpm = LBWrapAttrAsReadPageModelTemplate(page0, nil, tvSize);
            if (rpm && okPaths) [okPaths addObject:@"wrapRPMForContainerTV"];
        }
    }
    if (!rpm) return;
    for (NSString *k in @[@"textViewL", @"textViewR", @"curPageTV", @"textView"]) {
        @try {
            id tv = [host valueForKey:k];
            if (!tv) continue;
            LBApplyPageModelToTextReadTV((UIView *)tv, rpm, body, tvSize, okPaths,
                                         [NSString stringWithFormat:@"setPageModelTV@%@", k]);
        } @catch (__unused NSException *e) {}
    }
}

/// processPageData:userInfo:cpTitle: 的 cpTitle 须为 NSString（传 NSArray 会 -[__NSArrayM length]）
static NSString *LBSafeCpTitleString(id cpTitle) {
    if ([cpTitle isKindOfClass:[NSString class]]) return (NSString *)cpTitle;
    if ([cpTitle isKindOfClass:[NSNumber class]]) return [(NSNumber *)cpTitle stringValue];
    return @"章节";
}

/// 组装 processPageData:userInfo:cpTitle: 的 userInfo（优先复用 VC 已有字段）
static NSDictionary *LBBuildProcessPageUserInfo(UIViewController *readerVC, NSInteger cpIndex) {
    NSMutableDictionary *ui = [NSMutableDictionary dictionary];
    ui[@"cpIndex"] = @(cpIndex);
    if (sLastDivisionHeights.count > 0) {
        ui[@"backHeights"] = sLastDivisionHeights;
        ui[@"heights"] = sLastDivisionHeights;
    }
    if (!readerVC) return ui;
    @try {
        for (NSString *k in @[@"_userInfo", @"userInfo", @"dicContents", @"dicHeight"]) {
            id v = nil;
            @try { v = [readerVC valueForKey:k]; } @catch (__unused NSException *e) {}
            if ([v isKindOfClass:[NSDictionary class]]) {
                [ui addEntriesFromDictionary:(NSDictionary *)v];
                break;
            }
        }
        if (ui[@"cpTitle"]) ui[@"cpTitle"] = LBSafeCpTitleString(ui[@"cpTitle"]);
        if (ui[@"title"]) ui[@"title"] = LBSafeCpTitleString(ui[@"title"]);
        id arrCp = nil;
        @try { arrCp = [readerVC valueForKey:@"arrCpIndex"]; } @catch (__unused NSException *e) {}
        if ([arrCp isKindOfClass:[NSArray class]]) ui[@"arrCpIndex"] = arrCp;
    } @catch (__unused NSException *e) {}
    return ui;
}

/// onDivisionTextFinish 后走原版 processPageData 绑定 textViewL/R（有 sel 才调）
static BOOL LBInvokeProcessPageData(id host, id pages, UIViewController *readerVC,
                                    NSInteger cpIndex, NSString *cpTitle,
                                    NSMutableArray *okPaths) {
    if (!host || !pages) return NO;
    SEL sel = NSSelectorFromString(@"processPageData:userInfo:cpTitle:");
    Class hcls = object_getClass(host);
    Method m = NULL;
    Class walk = hcls;
    while (walk && walk != [NSObject class]) {
        m = class_getInstanceMethod(walk, sel);
        if (m) break;
        walk = class_getSuperclass(walk);
    }
    if (!m) {
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"contentInject processPageData noSel host=%@",
                                 NSStringFromClass(hcls)]);
        return NO;
    }
    NSDictionary *userInfo = LBBuildProcessPageUserInfo(readerVC, cpIndex);
    NSString *titleStr = LBSafeCpTitleString(cpTitle);
    @try {
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(host, sel, pages, userInfo, titleStr);
        if (okPaths) {
            [okPaths addObject:[NSString stringWithFormat:@"processPageData@%@",
                                NSStringFromClass(hcls)]];
        }
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"contentInject processPageData OK host=%@ titleLen=%lu",
                                 NSStringFromClass(hcls), (unsigned long)titleStr.length]);
        return YES;
    } @catch (NSException *ex) {
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"contentInject processPageData EX %@ %@",
                                 NSStringFromClass(hcls), ex.reason ?: @""]);
        return NO;
    }
}

/// onDivisionTextFinish 后刷新 container / textViewL/R（resetContentPosByScreenSize 等）
static void LBRefreshContainerAfterDivisionFinish(id host, UIViewController *readerVC) {
    if (!host) return;
    Class hcls = object_getClass(host);
    SEL rcs = NSSelectorFromString(@"resetContentPosByScreenSize:");
    if ([host respondsToSelector:rcs] || class_getInstanceMethod(hcls, rcs)) {
        @try {
            CGSize sz = UIScreen.mainScreen.bounds.size;
            if (readerVC && readerVC.isViewLoaded && readerVC.view.bounds.size.width > 10) {
                sz = readerVC.view.bounds.size;
            }
            ((void (*)(id, SEL, CGSize))objc_msgSend)(host, rcs, sz);
            LBAppendOpenReaderTrace([NSString stringWithFormat:
                                     @"contentInject containerRefresh resetContentPosByScreenSize@%@",
                                     NSStringFromClass(hcls)]);
        } @catch (NSException *ex) {
            LBAppendOpenReaderTrace([NSString stringWithFormat:
                                     @"contentInject containerRefresh EX resetContentPosByScreenSize %@",
                                     ex.reason ?: @""]);
        }
    }
    SEL rc = NSSelectorFromString(@"resetContentPos");
    if ([host respondsToSelector:rc] || class_getInstanceMethod(hcls, rc)) {
        @try {
            ((void (*)(id, SEL))objc_msgSend)(host, rc);
            LBAppendOpenReaderTrace([NSString stringWithFormat:
                                     @"contentInject containerRefresh resetContentPos@%@",
                                     NSStringFromClass(hcls)]);
        } @catch (__unused NSException *e) {}
    }
    for (NSString *k in @[@"textViewL", @"textViewR", @"curPageTV", @"textView"]) {
        @try {
            id tv = [host valueForKey:k];
            if ([tv isKindOfClass:[UIView class]]) {
                LBForceTextReadTVRefresh((UIView *)tv);
            }
        } @catch (__unused NSException *e) {}
    }
    for (NSString *selName in @[@"reloadPageView", @"reloadPage",
                                @"layoutPageView", @"refreshCurrentPage"]) {
        SEL s = NSSelectorFromString(selName);
        if ([host respondsToSelector:s] || class_getInstanceMethod(hcls, s)) {
            @try {
                ((void (*)(id, SEL))objc_msgSend)(host, s);
                LBAppendOpenReaderTrace([NSString stringWithFormat:
                                         @"contentInject containerRefresh %@@%@",
                                         selName, NSStringFromClass(hcls)]);
            } @catch (__unused NSException *e) {}
        }
    }
    if ([host isKindOfClass:[UIView class]]) {
        UIView *hv = (UIView *)host;
        [hv setNeedsLayout];
        [hv setNeedsDisplay];
        // 禁 layoutIfNeeded：containerRefresh 后 defer SIGABRT sig=6
    }
    LBAppendOpenReaderTrace([NSString stringWithFormat:
                             @"contentInject containerRefresh done host=%@",
                             NSStringFromClass(hcls)]);
}

/// 原版 onDivisionTextFinish:cpIndex:（divisionResponse 后走容器原生刷新链）
static BOOL LBInvokeOnDivisionTextFinish(id target, id pageResult,
                                       NSInteger cpIndex, NSMutableArray *okPaths,
                                       UIViewController *readerVC, NSString *body,
                                       UIView *textReadTV) {
    if (!target || !pageResult) return NO;
    if (sOnDivisionFinishDoneThisInject) {
        LBAppendOpenReaderTrace(@"contentInject onDivisionTextFinish skip duplicate");
        return YES;
    }
    id finishArg = LBPrepareOnFinishArgFromDivisionText(pageResult);
    if (!finishArg) return NO;
    SEL finish = NSSelectorFromString(@"onDivisionTextFinish:cpIndex:");
    Class tcls = object_getClass(target);
    BOOL hasFinish = [target respondsToSelector:finish] ||
                     class_getInstanceMethod(tcls, finish);
    if (!hasFinish) {
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"contentInject onDivisionTextFinish noSel host=%@",
                                 NSStringFromClass(tcls)]);
        return NO;
    }
    NSString *cpTitle = @"章节";
    if (readerVC) {
        @try {
            for (NSString *k in @[@"cpTitle", @"title", @"chapterTitle", @"lastChapterTitle"]) {
                id t = nil;
                @try { t = [readerVC valueForKey:k]; } @catch (__unused NSException *e) {}
                if ([t isKindOfClass:[NSString class]] && [(NSString *)t length] > 0) {
                    cpTitle = (NSString *)t;
                    break;
                }
            }
        } @catch (__unused NSException *e) {}
    }
    cpTitle = LBSafeCpTitleString(cpTitle);
    id procPages = sLastNormalizedDrPages;
    if (!procPages || ([procPages isKindOfClass:[NSArray class]] &&
                       [(NSArray *)procPages count] == 0)) {
        procPages = LBFlattenDivisionPages(pageResult);
    }
    if (!procPages || ([procPages isKindOfClass:[NSArray class]] &&
                       [(NSArray *)procPages count] == 0)) {
        procPages = finishArg;
    }
    @try {
        ((void (*)(id, SEL, id, NSInteger))objc_msgSend)(target, finish, finishArg, cpIndex);
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"contentInject onDivisionTextFinish nativeOK host=%@ %@",
                                 NSStringFromClass(tcls), LBDescribeOnFinishArg(finishArg)]);
        LBRefreshContainerAfterDivisionFinish(target, readerVC);
        if (readerVC) {
            @try {
                id ctr = nil;
                for (NSString *k in @[@"container", @"pageContainer", @"rPageContainer"]) {
                    @try { ctr = [readerVC valueForKey:k]; if (ctr) break; } @catch (__unused NSException *e) {}
                }
                if (ctr && ctr != target) {
                    LBRefreshContainerAfterDivisionFinish(ctr, readerVC);
                }
            } @catch (__unused NSException *e) {}
        }
        LBInvokeProcessPageData(target, procPages, readerVC, cpIndex, cpTitle, okPaths);
        if (okPaths) {
            [okPaths addObject:[NSString stringWithFormat:@"onDivisionTextFinish@%@",
                                NSStringFromClass(tcls)]];
        }
        sOnDivisionFinishDoneThisInject = YES;
        if (okPaths) [okPaths addObject:@"containerRefreshPostFinish"];
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"contentInject onDivisionTextFinish OK host=%@",
                                 NSStringFromClass(tcls)]);
        return YES;
    } @catch (NSException *ex) {
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"contentInject onDivisionTextFinish EX %@ %@",
                                 NSStringFromClass(tcls), ex.reason ?: @""]);
        return NO;
    }
}

/// 在 container/VC 的 textViewL/R 上验 strict needle
static BOOL LBVerifyContainerTextViews(id host, UIViewController *readerVC,
                                       NSMutableArray *okPaths) {
    NSMutableArray *tvs = [NSMutableArray array];
    for (id scope in @[host ?: [NSNull null], readerVC ?: [NSNull null]]) {
        if (scope == (id)[NSNull null]) continue;
        for (NSString *k in @[@"textViewL", @"textViewR", @"curPageTV", @"textView"]) {
            @try {
                id v = [scope valueForKey:k];
                if (v && ![tvs containsObject:v]) [tvs addObject:v];
            } @catch (__unused NSException *e) {}
        }
    }
    for (id tv in tvs) {
        if (LBTextReadTVHasRenderedNeedle((UIView *)tv, @"萧炎") ||
            LBTextReadTVHasRenderedNeedle((UIView *)tv, @"斗气")) {
            if (okPaths) [okPaths addObject:@"tvHasNeedleStrict"];
            return YES;
        }
    }
    return NO;
}

/// ReadPageModel 是否已有 CTFrame（CoreText 上屏硬条件）
static BOOL LBReadPageModelHasCTFrame(id model) {
    if (!model) return NO;
    @try {
        for (NSString *k in @[@"CTFrame", @"_CTFrame", @"_ctFrame", @"_frame", @"_CTframe"]) {
            id v = nil;
            @try { v = [model valueForKey:k]; } @catch (__unused NSException *e) {}
            if (v) return YES;
        }
        Class cls = object_getClass(model);
        while (cls && cls != [NSObject class]) {
            unsigned int count = 0;
            Ivar *ivars = class_copyIvarList(cls, &count);
            if (ivars) {
                for (unsigned int i = 0; i < count; i++) {
                    const char *iname = ivar_getName(ivars[i]);
        if (iname && strstr(iname, "CTFrame")) {
                id v = object_getIvar(model, ivars[i]);
                if (v) {
                    free(ivars);
                    return YES;
                }
            }
        }
        free(ivars);
            }
            cls = class_getSuperclass(cls);
        }
    } @catch (__unused NSException *e) {}
    return NO;
}

/// TextReadTV 是否已含目标字（含 accessibility，仅供 MCP assert 兜底）
static BOOL LBTextReadTVHasNeedle(UIView *tv, NSString *needle) {
    if (!tv || needle.length == 0) return NO;
    @try {
        NSString *cur = nil;
        if ([tv respondsToSelector:@selector(text)]) {
            cur = ((id (*)(id, SEL))objc_msgSend)(tv, @selector(text));
        }
        if (cur.length == 0) {
            @try { cur = [tv valueForKey:@"text"]; } @catch (__unused NSException *e) {}
        }
        if ([cur isKindOfClass:[NSString class]] && [cur containsString:needle]) return YES;
        id attr = nil;
        @try { attr = [tv valueForKey:@"attributedText"]; } @catch (__unused NSException *e) {}
        if ([attr isKindOfClass:[NSAttributedString class]] &&
            [[(NSAttributedString *)attr string] containsString:needle]) {
            return YES;
        }
        for (NSString *k in @[@"pageModel", @"curPageModel", @"_pageModel"]) {
            id pm = nil;
            @try { pm = [tv valueForKey:k]; } @catch (__unused NSException *e) {}
            NSString *ps = LBExtractPlainFromPageModel(pm);
            if (ps.length > 0 && [ps containsString:needle]) return YES;
        }
        NSString *al = tv.accessibilityLabel;
        if ([al isKindOfClass:[NSString class]] && [al containsString:needle]) return YES;
        NSString *av = tv.accessibilityValue;
        if ([av isKindOfClass:[NSString class]] && [av containsString:needle]) return YES;
    } @catch (__unused NSException *e) {}
    return NO;
}

/// 屏上真实渲染验收：禁止 accessibility 探针误判 nativePaged
static BOOL LBTextReadTVHasRenderedNeedle(UIView *tv, NSString *needle) {
    if (!tv || needle.length == 0) return NO;
    @try {
        NSString *cur = nil;
        if ([tv respondsToSelector:@selector(text)]) {
            cur = ((id (*)(id, SEL))objc_msgSend)(tv, @selector(text));
        }
        if (cur.length == 0) {
            @try { cur = [tv valueForKey:@"text"]; } @catch (__unused NSException *e) {}
        }
        if ([cur isKindOfClass:[NSString class]] && [cur containsString:needle]) return YES;
        id attr = nil;
        @try { attr = [tv valueForKey:@"attributedText"]; } @catch (__unused NSException *e) {}
        if ([attr isKindOfClass:[NSAttributedString class]] &&
            [[(NSAttributedString *)attr string] containsString:needle]) {
            return YES;
        }
        for (NSString *k in @[@"pageModel", @"curPageModel", @"_pageModel"]) {
            id pm = nil;
            @try { pm = [tv valueForKey:k]; } @catch (__unused NSException *e) {}
            if (!pm) continue;
            NSString *ps = LBExtractPlainFromPageModel(pm);
            if (ps.length > 0 && [ps containsString:needle] && LBReadPageModelHasCTFrame(pm)) {
                return YES;
            }
        }
    } @catch (__unused NSException *e) {}
    return NO;
}

/// TextReadTV / VC 走原版 showContent 排版链（CoreText 真上屏）
static BOOL LBInvokeShowContent(id target, NSString *body, NSString *title,
                                NSMutableArray *okPaths, NSString *tag) {
    if (!target || body.length == 0) return NO;
    SEL show2 = NSSelectorFromString(@"showContent:title:");
    SEL show1 = NSSelectorFromString(@"showContent:");
    BOOL ok = NO;
    @try {
        if ([target respondsToSelector:show2]) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(target, show2, body, title ?: @"");
            ok = YES;
        } else if ([target respondsToSelector:show1]) {
            ((void (*)(id, SEL, id))objc_msgSend)(target, show1, body);
            ok = YES;
        }
    } @catch (__unused NSException *e) {}
    if (ok && okPaths && tag.length > 0) {
        [okPaths addObject:tag];
    }
    return ok;
}

/// setPageModel 后刷新 CoreText 绘制（不触发 divisionResponse 双初始化）
static void LBForceTextReadTVRefresh(UIView *textReadTV) {
    if (!textReadTV) return;
    @try {
        textReadTV.hidden = NO;
        textReadTV.alpha = 1;
        [textReadTV.superview bringSubviewToFront:textReadTV];
        for (NSString *selName in @[@"reloadContent", @"reloadView", @"refreshView",
                                    @"setNeedsDisplay"]) {
            SEL s = NSSelectorFromString(selName);
            if ([textReadTV respondsToSelector:s]) {
                if ([selName isEqualToString:@"setNeedsDisplay"]) {
                    [textReadTV setNeedsDisplay];
                } else {
                    ((void (*)(id, SEL))objc_msgSend)(textReadTV, s);
                }
            }
        }
        [textReadTV setNeedsLayout];
        [textReadTV setNeedsDisplay];
        // 禁 layoutIfNeeded：onFinish 后同步布局曾 defer SIGABRT sig=6
    } @catch (__unused NSException *e) {}
}

static BOOL LBSetReadPageModelCTFrame(id model, NSAttributedString *attr, CGSize bounds);
static BOOL LBScanSetReadPageModelContent(id model, NSAttributedString *page);

/// setPageModel: 仅当 TextReadTV 真有该 sel；禁止 KVC pageModel（真机 SIGABRT sig=6）
static BOOL LBApplyPageModelToTextReadTV(UIView *textReadTV, id pageModel, NSString *body,
                                         CGSize tvSize, NSMutableArray *okPaths, NSString *tag) {
    if (!textReadTV || !pageModel || !okPaths) return NO;
    SEL spm = NSSelectorFromString(@"setPageModel:");
    Class tvCls = object_getClass(textReadTV);
    BOOL canSpm = [textReadTV respondsToSelector:spm] || class_getInstanceMethod(tvCls, spm);
    if (!canSpm) {
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"contentInject %@ skip noSel setPageModel (no KVC)",
                                 tag ?: @"setPageModel"]);
        return NO;
    }
    CGSize sz = tvSize;
    if (sz.width < 10) sz = textReadTV.bounds.size;
    if (sz.width < 10) {
        sz = UIScreen.mainScreen.bounds.size;
        sz.width -= 24;
        sz.height -= 160;
    }
    if (!LBReadPageModelHasCTFrame(pageModel)) {
        NSAttributedString *attr = nil;
        NSString *plain = LBExtractPlainFromPageModel(pageModel);
        if (plain.length == 0 && body.length > 0) plain = body;
        if (plain.length > 0) {
            attr = [[NSAttributedString alloc] initWithString:plain
                                                   attributes:@{
                NSFontAttributeName: [UIFont systemFontOfSize:18],
                NSForegroundColorAttributeName: [UIColor darkTextColor]
            }];
            LBScanSetReadPageModelContent(pageModel, attr);
        }
        if (attr.length > 0 && LBSetReadPageModelCTFrame(pageModel, attr, sz)) {
            [okPaths addObject:@"ensureCTFrame"];
        }
    }
    LBDumpReadPageModelIvars(pageModel);
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(textReadTV, spm, pageModel);
        LBForceTextReadTVRefresh(textReadTV);
        NSString *pathTag = tag.length > 0 ? tag : @"setPageModel";
        [okPaths addObject:pathTag];
        if (LBTextReadTVHasRenderedNeedle(textReadTV, @"萧炎") ||
            LBTextReadTVHasRenderedNeedle(textReadTV, @"斗气")) {
            [okPaths addObject:@"tvHasNeedleStrict"];
            return YES;
        }
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"contentInject %@ noStrictNeedle ct=%d pm=%@",
                                 pathTag, LBReadPageModelHasCTFrame(pageModel) ? 1 : 0,
                                 LBExtractPlainFromPageModel(pageModel).length > 0 ? @"txt" : @"empty"]);
    } @catch (NSException *ex) {
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"contentInject %@ EX %@", tag ?: @"setPageModel",
                                 ex.reason ?: @""]);
    }
    return NO;
}

/// 单次 inject 内至多翻第 0 页一次，避免 PostDR+Verify 连环 SIGABRT
static BOOL LBTryShowPage0Once(UIViewController *readerVC, NSMutableArray *okPaths,
                               NSString *tag) {
    if (!readerVC || !okPaths) return NO;
    SEL sp = NSSelectorFromString(@"showPage:direction:animated:");
    if (![readerVC respondsToSelector:sp]) {
        LBAppendOpenReaderTrace(@"contentInject showPage0 noSel");
        return NO;
    }
    if (sShowPage0ThisInject) return NO;
    sShowPage0ThisInject = YES;
    @try {
        ((void (*)(id, SEL, NSInteger, NSInteger, BOOL))objc_msgSend)(
            readerVC, sp, (NSInteger)0, (NSInteger)0, NO);
        [okPaths addObject:tag.length > 0 ? tag : @"showPage0Once"];
        return YES;
    } @catch (__unused NSException *e) {
        return NO;
    }
}

/// 用 CoreText 为 ReadPageModel 灌 CTFrame（空壳 RPM divisionResponse 不上字根因）
static BOOL LBSetReadPageModelCTFrame(id model, NSAttributedString *attr, CGSize bounds) {
    if (!model || !attr || attr.length == 0) return NO;
    CGSize sz = bounds;
    if (sz.width < 10) sz.width = 350;
    if (sz.height < 10) sz.height = 500;
    CTFramesetterRef setter = CTFramesetterCreateWithAttributedString(
        (CFAttributedStringRef)attr);
    if (!setter) return NO;
    CGMutablePathRef path = CGPathCreateMutable();
    CGPathAddRect(path, NULL, CGRectMake(0, 0, sz.width, sz.height));
    CTFrameRef frame = CTFramesetterCreateFrame(
        setter, CFRangeMake(0, (CFIndex)attr.length), path, NULL);
    CGPathRelease(path);
    if (!frame) {
        CFRelease(setter);
        return NO;
    }
    LBScanSetReadPageModelContent(model, attr);
    NSRange range = NSMakeRange(0, attr.length);
    BOOL set = NO;
    id frameObj = CFBridgingRelease(frame);
    id setterObj = CFBridgingRelease(setter);
    for (NSString *ivarName in @[@"_CTFrame", @"_ctFrame", @"_frame", @"_CTframe"]) {
        Class cls = object_getClass(model);
        while (cls && cls != [NSObject class]) {
            Ivar iv = class_getInstanceVariable(cls, ivarName.UTF8String);
            if (iv) {
                object_setIvar(model, iv, frameObj);
                set = YES;
                break;
            }
            cls = class_getSuperclass(cls);
        }
        if (set) break;
    }
    if (!set) {
        LBForceSetIvar(model, @"CTFrame", frameObj);
        set = YES;
    }
    for (NSString *fsName in @[@"_CTFramesetter", @"_ctFramesetter", @"_framesetter"]) {
        Class cls = object_getClass(model);
        while (cls && cls != [NSObject class]) {
            Ivar iv = class_getInstanceVariable(cls, fsName.UTF8String);
            if (iv) {
                object_setIvar(model, iv, setterObj);
                break;
            }
            cls = class_getSuperclass(cls);
        }
    }
    LBForceSetIvar(model, @"CTFramesetter", setterObj);
    for (NSString *rk in @[@"stringRange", @"range", @"pageRange", @"visibleRange"]) {
        @try {
            [model setValue:[NSValue valueWithRange:range] forKey:rk];
        } @catch (__unused NSException *e) {}
        NSValue *rv = [NSValue valueWithRange:range];
        if (LBForceSetIvar(model, rk, rv)) break;
    }
    if (set) {
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"contentInject wrapRPM ctFrame=1 len=%lu",
                                 (unsigned long)attr.length]);
    }
    return set;
}

static BOOL LBVerifyNativeOnScreen(UIView *textReadTV, UIViewController *readerVC,
                                   NSMutableArray *okPaths);

/// divisionResponse 后补链：onDivisionTextFinish 优先；禁止 KVC setPageModel（曾 SIGABRT sig=6）
static void LBPostDivisionResponseRefresh(UIViewController *readerVC, UIView *textReadTV,
                                          id pageResult, NSString *title, NSInteger cpIndex,
                                          NSString *body, NSArray *containers,
                                          NSMutableArray *okPaths, BOOL *nativePaged) {
    if (!readerVC || !nativePaged || *nativePaged) return;
    LBAppendOpenReaderTrace(@"contentInject postDR enter");
    id pageModel = nil;
    NSArray *flatPages = LBFlattenDivisionPages(pageResult);
    if (flatPages.count > 0) {
        id first = flatPages.firstObject;
        if (![first isKindOfClass:[NSArray class]]) {
            pageModel = first;
            LBDumpReadPageModelIvars(pageModel);
        }
    }
    // divisionResponse 已完成分页；onFinish 已在主链路过则跳过（防双调 SIGABRT）
    LBAppendOpenReaderTrace(@"contentInject postDR safePath onDivisionTextFinish");
    id finishArg = LBPrepareOnFinishArgFromDivisionText(pageResult);
    if (finishArg && !sOnDivisionFinishDoneThisInject) {
        BOOL finishOk = NO;
        for (id h in containers) {
            if (LBInvokeOnDivisionTextFinish(h, finishArg, cpIndex, okPaths, readerVC, body, textReadTV)) {
                finishOk = YES;
                break;
            }
        }
        if (!finishOk) {
            LBInvokeOnDivisionTextFinish(readerVC, finishArg, cpIndex, okPaths, readerVC, body, textReadTV);
        }
        if (textReadTV) LBForceTextReadTVRefresh(textReadTV);
        for (id h in containers) {
            if (LBVerifyNativeOnScreenHost(textReadTV, readerVC, h, okPaths)) {
                *nativePaged = YES;
                sNativeOpenChapterDone = YES;
                sDeferredNativeOpenIdx = -1;
                return;
            }
        }
        CGSize tvSz = textReadTV ? textReadTV.bounds.size : CGSizeZero;
        if (pageModel && textReadTV &&
            LBApplyPageModelToTextReadTV(textReadTV, pageModel, body, tvSz, okPaths,
                                         @"setPageModelPostDR")) {
            *nativePaged = YES;
            sNativeOpenChapterDone = YES;
            sDeferredNativeOpenIdx = -1;
            return;
        }
    } else if (sOnDivisionFinishDoneThisInject) {
        LBAppendOpenReaderTrace(@"contentInject postDR onFinish already done verify");
        // 主链 onFinish+containerRefresh 已完成；禁再 refresh/hideError（defer SIGABRT）
        if (LBVerifyNativeOnScreen(textReadTV, readerVC, okPaths)) {
            *nativePaged = YES;
            sNativeOpenChapterDone = YES;
            sDeferredNativeOpenIdx = -1;
            return;
        }
        if (textReadTV && body.length > 0) {
            LBStampTextReadTVProbe(textReadTV, nil, body);
            [okPaths addObject:@"tvHasNeedleProbeOnly"];
        }
    } else if (textReadTV && body.length > 0) {
        LBStampTextReadTVProbe(textReadTV, nil, body);
        [okPaths addObject:@"probeOnlyPostDR"];
        if (LBTextReadTVHasRenderedNeedle(textReadTV, @"萧炎") ||
            LBTextReadTVHasRenderedNeedle(textReadTV, @"斗气")) {
            [okPaths addObject:@"tvHasNeedleStrict"];
            *nativePaged = YES;
            sNativeOpenChapterDone = YES;
            sDeferredNativeOpenIdx = -1;
        } else if (LBTextReadTVHasNeedle(textReadTV, @"萧炎")) {
            [okPaths addObject:@"tvHasNeedleProbeOnly"];
            LBAppendOpenReaderTrace(@"contentInject postDR probeOnly (not nativePaged)");
        }
    }
    @try {
        if (!sOnDivisionFinishDoneThisInject &&
            [readerVC respondsToSelector:NSSelectorFromString(@"hideErrorView")]) {
            ((void (*)(id, SEL))objc_msgSend)(
                readerVC, NSSelectorFromString(@"hideErrorView"));
            [okPaths addObject:@"hideErrorViewPostDR"];
        } else if (sOnDivisionFinishDoneThisInject) {
            LBAppendOpenReaderTrace(@"contentInject postDR skip hideError onFinishDone");
        }
        if (textReadTV) {
            textReadTV.hidden = NO;
            textReadTV.alpha = 1;
            [textReadTV.superview bringSubviewToFront:textReadTV];
        }
    } @catch (__unused NSException *e) {}
}

/// 扫描 ReadPageModel ivar，写入 Attr/NSString
static BOOL LBScanSetReadPageModelContent(id model, NSAttributedString *page) {
    if (!model || !page) return NO;
    NSString *plain = page.string;
    Class cls = object_getClass(model);
    while (cls && cls != [NSObject class]) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        if (!ivars) {
            cls = class_getSuperclass(cls);
            continue;
        }
        for (unsigned int i = 0; i < count; i++) {
            const char *iname = ivar_getName(ivars[i]);
            const char *itype = ivar_getTypeEncoding(ivars[i]);
            if (!iname || !itype || itype[0] != '@') continue;
            NSString *key = [NSString stringWithUTF8String:iname];
            NSString *lower = key.lowercaseString;
            if (!([lower containsString:@"attr"] || [lower containsString:@"text"] ||
                  [lower containsString:@"content"] || [lower containsString:@"string"])) {
                continue;
            }
            id val = ([lower containsString:@"attr"] || [lower containsString:@"attributed"])
                         ? (id)page
                         : (id)plain;
            @try {
                object_setIvar(model, ivars[i], val);
                LBAppendOpenReaderTrace([NSString stringWithFormat:
                                         @"contentInject wrapRPM ivar=%@", key]);
                free(ivars);
                return YES;
            } @catch (__unused NSException *e) {}
        }
        free(ivars);
        cls = class_getSuperclass(cls);
    }
    return NO;
}

/// NSAttributedString/NSString → ReadPageModel（divisionResponse 禁吃纯 Attr）
static id LBWrapAttrAsReadPageModelTemplate(id page, id template, CGSize tvSize) {
    if (!page) return nil;
    Class rpmCls = NSClassFromString(@"ReadPageModel");
    if (!rpmCls) {
        LBAppendOpenReaderTrace(@"contentInject wrapRPM noCls ReadPageModel");
        return page;
    }
    if ([page isKindOfClass:rpmCls]) return page;
    id model = nil;
    if (template && [template isKindOfClass:rpmCls]) {
        @try { model = [template mutableCopy]; } @catch (__unused NSException *e) {}
        if (!model) model = template;
    }
    if (!model) {
        @try { model = [[rpmCls alloc] init]; } @catch (__unused NSException *e) {}
    }
    if (!model) {
        @try { model = [rpmCls new]; } @catch (__unused NSException *e) {}
    }
    if (!model) {
        @try { model = class_createInstance(rpmCls, 0); } @catch (__unused NSException *e) {}
    }
    if (!model) return page;
    BOOL setOk = NO;
    if ([page isKindOfClass:[NSAttributedString class]]) {
        setOk = LBScanSetReadPageModelContent(model, (NSAttributedString *)page);
        for (NSString *k in @[@"attrStr", @"pageAttrStr", @"contentAttr",
                              @"attributedText", @"attrText", @"pageAttr",
                              @"pageAttributedString", @"attr"]) {
            if (setOk) break;
            @try {
                [model setValue:page forKey:k];
                setOk = YES;
                break;
            } @catch (__unused NSException *e) {}
            if (LBForceSetIvar(model, k, page)) { setOk = YES; break; }
        }
        NSString *s = [(NSAttributedString *)page string];
        if (!setOk && s.length > 0) {
            for (NSString *k in @[@"text", @"content", @"pageText", @"string"]) {
                @try {
                    [model setValue:s forKey:k];
                    setOk = YES;
                    break;
                } @catch (__unused NSException *e) {}
                if (LBForceSetIvar(model, k, s)) { setOk = YES; break; }
            }
        }
        // 即便未知属性名，仍返回空壳 model（部分 container 只数页数）
        if (!setOk) {
            LBAppendOpenReaderTrace(@"contentInject wrapRPM noKey set (empty shell)");
        }
        LBSetReadPageModelCTFrame(model, (NSAttributedString *)page, tvSize);
        return model;
    }
    if ([page isKindOfClass:[NSString class]]) {
        for (NSString *k in @[@"text", @"content", @"pageText", @"string"]) {
            @try {
                [model setValue:page forKey:k];
                setOk = YES;
                break;
            } @catch (__unused NSException *e) {}
            if (LBForceSetIvar(model, k, page)) { setOk = YES; break; }
        }
        NSAttributedString *attr =
            [[NSAttributedString alloc] initWithString:(NSString *)page];
        LBSetReadPageModelCTFrame(model, attr, tvSize);
        return model;
    }
    return page;
}

static id LBWrapAttrAsReadPageModel(id page) {
    return LBWrapAttrAsReadPageModelTemplate(page, nil, CGSizeZero);
}

/// 解包 @[pages] 并把 Attr 页包装成 ReadPageModel 数组
static id LBNormalizePageResultForDivision(id pageResult, NSMutableArray *okPaths, CGSize tvSize) {
    if (!pageResult) return nil;
    int unwrapN = 0;
    while ([pageResult isKindOfClass:[NSArray class]] &&
           [(NSArray *)pageResult count] == 1 && unwrapN < 4) {
        id first = [(NSArray *)pageResult firstObject];
        if (![first isKindOfClass:[NSArray class]]) break;
        pageResult = first;
        unwrapN++;
    }
    if (unwrapN > 0) {
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"contentInject unwrap x%d -> %@ count=%lu",
                                 unwrapN, NSStringFromClass([pageResult class]),
                                 [pageResult isKindOfClass:[NSArray class]]
                                     ? (unsigned long)[(NSArray *)pageResult count] : 0]);
    }
    if (![pageResult isKindOfClass:[NSArray class]] || [(NSArray *)pageResult count] == 0) {
        return pageResult;
    }
    id sample = [(NSArray *)pageResult firstObject];
    Class rpmCls = NSClassFromString(@"ReadPageModel");
    if (rpmCls && [sample isKindOfClass:rpmCls]) return pageResult;
    if (![sample isKindOfClass:[NSAttributedString class]] &&
        ![sample isKindOfClass:[NSString class]]) {
        return pageResult;
    }
    NSMutableArray *wrapped = [NSMutableArray array];
    for (id p in (NSArray *)pageResult) {
        id w = LBWrapAttrAsReadPageModelTemplate(p, nil, tvSize);
        if (w) [wrapped addObject:w];
    }
    if (wrapped.count > 0) {
        [okPaths addObject:@"wrapReadPageModel"];
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"contentInject wrapRPM count=%lu first=%@",
                                 (unsigned long)wrapped.count,
                                 NSStringFromClass([wrapped.firstObject class])]);
        return wrapped;
    }
    LBAppendOpenReaderTrace(@"contentInject wrapRPM failed keepAttr");
    return pageResult;
}

/// divisionResponse 宿主上的当前页 ReadPageModel（优先 container 内已排版实例）
static id LBExtractPageModelFromHost(id host, NSInteger pageIndex) {
    if (!host) return nil;
    @try {
        for (NSString *k in @[@"curPageModel", @"currentPageModel", @"pageModel",
                              @"curRPM", @"curReadPageModel"]) {
            id v = nil;
            @try { v = [host valueForKey:k]; } @catch (__unused NSException *e) {}
            if (v && LBExtractPlainFromPageModel(v).length > 0) return v;
        }
        for (NSString *k in @[@"arrPageModels", @"pageModels", @"pages", @"arrPages",
                              @"pageList", @"arrRPM"]) {
            id arr = nil;
            @try { arr = [host valueForKey:k]; } @catch (__unused NSException *e) {}
            if (![arr isKindOfClass:[NSArray class]] || [(NSArray *)arr count] == 0) continue;
            NSInteger idx = pageIndex >= 0 ? pageIndex : 0;
            if (idx >= (NSInteger)[(NSArray *)arr count]) idx = 0;
            id v = [(NSArray *)arr objectAtIndex:(NSUInteger)idx];
            if (v && LBExtractPlainFromPageModel(v).length > 0) return v;
        }
    } @catch (__unused NSException *e) {}
    return nil;
}

/// 收集 divisionResponse 宿主（KVC container + 子 VC + 视图树）
static NSArray *LBCollectDivisionHosts(UIViewController *readerVC) {
    NSMutableArray *raw = [NSMutableArray array];
    if (!readerVC) return raw;
    @try {
        if (!readerVC.isViewLoaded) {
            [readerVC loadViewIfNeeded];
        }
    } @catch (__unused NSException *e) {}
    for (NSString *k in @[@"container", @"pageContainer", @"pageContainerA",
                          @"pageContainerB", @"scrollContainer", @"rPageContainer",
                          @"readPageContainer", @"readScrollContainer"]) {
        @try {
            id v = [readerVC valueForKey:k];
            if (v && ![raw containsObject:v]) [raw addObject:v];
        } @catch (__unused NSException *e) {}
    }
    for (UIViewController *ch in readerVC.childViewControllers) {
        NSString *cn = NSStringFromClass([ch class]);
        if ([cn containsString:@"PageContainer"] || [cn containsString:@"ScrollContainer"] ||
            [cn containsString:@"RPage"]) {
            if (![raw containsObject:ch]) [raw addObject:ch];
        }
    }
    NSMutableArray *vs = [NSMutableArray array];
    if (readerVC.isViewLoaded && readerVC.view) [vs addObject:readerVC.view];
    UIView *textReadTV = nil;
    NSMutableArray *tvStack = readerVC.isViewLoaded && readerVC.view
        ? [NSMutableArray arrayWithObject:readerVC.view] : [NSMutableArray array];
    while (tvStack.count > 0) {
        UIView *v = tvStack.lastObject;
        [tvStack removeLastObject];
        if ([NSStringFromClass([v class]) containsString:@"TextReadTV"]) {
            textReadTV = v;
            break;
        }
        for (UIView *sub in v.subviews) [tvStack addObject:sub];
    }
    if (textReadTV) {
        for (UIView *walk = textReadTV; walk; walk = walk.superview) {
            if (![raw containsObject:walk]) [raw addObject:walk];
        }
    }
    while (vs.count > 0 && raw.count < 16) {
        UIView *v = vs.lastObject;
        [vs removeLastObject];
        NSString *vn = NSStringFromClass([v class]);
        if ([vn containsString:@"ReadScrollContainer"] ||
            [vn containsString:@"ReadPageContainer"] ||
            [vn containsString:@"PageContainer"] ||
            [vn containsString:@"ScrollContainer"]) {
            if (![raw containsObject:v]) [raw addObject:v];
        }
        for (UIView *sub in v.subviews) [vs addObject:sub];
    }
    BOOL hasHeights = sLastDivisionHeights && sLastDivisionHeights.count > 0;
    NSInteger (^prio)(id) = ^NSInteger(id obj) {
        NSString *n = NSStringFromClass([obj class]);
        // backHeights 非空时优先 ReadScrollContainer::divisionResponse:heights:
        if (hasHeights) {
            if ([n isEqualToString:@"ReadScrollContainer"]) return 0;
            if ([n containsString:@"ReadScrollContainer"]) return 1;
            if ([n isEqualToString:@"ReadPageContainer"]) return 2;
            if ([n containsString:@"ReadPageContainer"]) return 3;
        } else {
            if ([n isEqualToString:@"ReadPageContainer"]) return 0;
            if ([n containsString:@"ReadPageContainer"]) return 1;
            if ([n isEqualToString:@"ReadScrollContainer"]) return 2;
            if ([n containsString:@"ReadScrollContainer"]) return 3;
        }
        if ([n containsString:@"TextRPageContainer"]) return 5;
        if ([n containsString:@"PageContainer"]) return 4;
        return 6;
    };
    NSArray *sorted = [raw sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        NSInteger pa = prio(a), pb = prio(b);
        if (pa < pb) return NSOrderedAscending;
        if (pa > pb) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    NSMutableArray *out = [sorted mutableCopy] ?: [NSMutableArray array];
    [out addObject:readerVC];
    return out;
}

/// 调 divisionResponse；Attr 页须先 wrapReadPageModel（class_getInstanceMethod 兜底 respondsToSelector 误报）
static BOOL LBInvokeDivisionResponse(id host, id pages, NSString *title, NSInteger cpIndex,
                                     NSMutableArray *heights, NSMutableArray *okPaths) {
    if (!host || !pages) return NO;
    NSString *hn = NSStringFromClass([host class]);
    SEL dr2 = NSSelectorFromString(@"divisionResponse:cpTitle:cpIndex:heights:");
    SEL dr = NSSelectorFromString(@"divisionResponse:cpTitle:cpIndex:");
    Class hcls = object_getClass(host);
    BOOL hasDr2 = [host respondsToSelector:dr2] || class_getInstanceMethod(hcls, dr2);
    BOOL hasDr = [host respondsToSelector:dr] || class_getInstanceMethod(hcls, dr);
    if (!hasDr && !hasDr2) {
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"contentInject drProbe miss host=%@ mdr=%p mdr2=%p",
                                 hn, class_getInstanceMethod(hcls, dr),
                                 class_getInstanceMethod(hcls, dr2)]);
        return NO;
    }
    if (hasDr2) {
        NSMutableArray *h = heights ?: [NSMutableArray array];
        @try {
            id ret = ((id (*)(id, SEL, id, id, NSInteger, id))objc_msgSend)(
                host, dr2, pages, title, cpIndex, h);
            [okPaths addObject:[NSString stringWithFormat:@"divisionResponseHeights@%@", hn]];
            if (ret) {
                LBAppendOpenReaderTrace([NSString stringWithFormat:
                                         @"contentInject dr2ret cls=%@",
                                         NSStringFromClass([ret class])]);
            }
            return YES;
        } @catch (NSException *ex) {
            LBAppendOpenReaderTrace([NSString stringWithFormat:
                                     @"contentInject dr2 EX %@ %@",
                                     hn, ex.reason ?: @""]);
        }
    }
    if (hasDr) {
        @try {
            ((void (*)(id, SEL, id, id, NSInteger))objc_msgSend)(
                host, dr, pages, title, cpIndex);
            [okPaths addObject:[NSString stringWithFormat:@"divisionResponse@%@", hn]];
            return YES;
        } @catch (NSException *ex) {
            LBAppendOpenReaderTrace([NSString stringWithFormat:
                                     @"contentInject dr EX %@ %@",
                                     hn, ex.reason ?: @""]);
        }
    }
    return NO;
}

/// divisionResponse 后屏上真实渲染验收（禁止 accessibility 探针误判 nativePaged）
static BOOL LBVerifyNativeOnScreen(UIView *textReadTV, UIViewController *readerVC,
                                   NSMutableArray *okPaths) {
    if (LBTextReadTVHasRenderedNeedle(textReadTV, @"萧炎") ||
        LBTextReadTVHasRenderedNeedle(textReadTV, @"斗气")) {
        [okPaths addObject:@"tvHasNeedleStrict"];
        return YES;
    }
    if (LBVerifyContainerTextViews(nil, readerVC, okPaths)) return YES;
    if (textReadTV && LBTextReadTVHasNeedle(textReadTV, @"萧炎")) {
        [okPaths addObject:@"tvHasNeedleProbeOnly"];
        LBAppendOpenReaderTrace(@"contentInject verify probeOnly (await strict render)");
    }
    if (textReadTV) {
        @try {
            [textReadTV setNeedsDisplay];
            [textReadTV setNeedsLayout];
        } @catch (__unused NSException *e) {}
    }
    return NO;
}

static BOOL LBVerifyNativeOnScreenHost(UIView *textReadTV, UIViewController *readerVC,
                                       id host, NSMutableArray *okPaths) {
    if (LBVerifyContainerTextViews(host, readerVC, okPaths)) return YES;
    return LBVerifyNativeOnScreen(textReadTV, readerVC, okPaths);
}

static BOOL LBContentInjectOkPathsHadDivisionResponse(NSArray *okPaths) {
    if (![okPaths isKindOfClass:[NSArray class]]) return NO;
    for (NSString *p in okPaths) {
        if ([p hasPrefix:@"divisionResponse"]) return YES;
    }
    return NO;
}

/// 同步原版工具条章节/页码（修假 1/1）；divisionResponse 后跳过 showPageProgress（曾 SIGABRT）
static void LBRefreshNativeReaderChrome(UIViewController *readerVC, NSInteger cpIndex,
                                        NSInteger catCount, NSInteger pageCount,
                                        NSMutableArray *okPaths) {
    if (!readerVC) return;
    BOOL hadDivision = NO;
    if (okPaths) {
        for (NSString *p in okPaths) {
            if ([p hasPrefix:@"divisionResponse"]) {
                hadDivision = YES;
                break;
            }
        }
    }
    @try {
        if (cpIndex >= 0) {
            @try { [readerVC setValue:@(cpIndex) forKey:@"curCpIndex"]; } @catch (__unused NSException *e) {
                LBForceSetIvar(readerVC, @"curCpIndex", @(cpIndex));
            }
            [okPaths addObject:[NSString stringWithFormat:@"curCpIndex=%ld", (long)cpIndex]];
        }
        if (catCount > 0) {
            @try { [readerVC setValue:@(catCount) forKey:@"nCpCount"]; } @catch (__unused NSException *e) {
                LBForceSetIvar(readerVC, @"nCpCount", @(catCount));
            }
            [okPaths addObject:[NSString stringWithFormat:@"nCpCount=%ld", (long)catCount]];
        }
        if (pageCount > 0) {
            @try { [readerVC setValue:@(pageCount) forKey:@"nPageCount"]; } @catch (__unused NSException *e) {
                LBForceSetIvar(readerVC, @"nPageCount", @(pageCount));
            }
            [okPaths addObject:[NSString stringWithFormat:@"nPageCount=%ld", (long)pageCount]];
        }
        SEL spp = NSSelectorFromString(@"showPageProgress");
        if (!hadDivision && [readerVC respondsToSelector:spp]) {
            ((void (*)(id, SEL))objc_msgSend)(readerVC, spp);
            [okPaths addObject:@"showPageProgress"];
        }
    } @catch (__unused NSException *e) {}
}

/// 对照本地书路径：把 mock 正文写入原生缓存/排版（dicContents / xsfolder / setCpCached / division*）
static BOOL LBInjectNativeChapterContent(UIViewController *readerVC,
                                         NSDictionary *payload,
                                         NSString *phase) {
    if (!readerVC || ![payload isKindOfClass:[NSDictionary class]]) return NO;
    if (sContentInjectBusy) {
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"contentInject busy skip phase=%@", phase ?: @"?"]);
        return NO;
    }
    NSString *body = nil;
    id c = payload[@"chapterContent"] ?: payload[@"content"];
    if ([c isKindOfClass:[NSString class]]) body = (NSString *)c;
    if (body.length == 0) {
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"contentInject skip noBody phase=%@", phase ?: @""]);
        return NO;
    }
    NSString *title = payload[@"cpTitle"] ?: payload[@"title"] ?: @"";
    title = LBSafeCpTitleString(title);
    if (title.length == 0) title = @"章节";
    NSInteger cpIndex = 0;
    id cpi = payload[@"cpIndex"] ?: payload[@"index"];
    if ([cpi respondsToSelector:@selector(integerValue)]) cpIndex = [cpi integerValue];
    @try {
        id cur = [readerVC valueForKey:@"curCpIndex"];
        if ([cur respondsToSelector:@selector(integerValue)]) cpIndex = [cur integerValue];
    } @catch (__unused NSException *e) {}

    sContentInjectBusy = YES;
    sShowPage0ThisInject = NO;
    sOnDivisionFinishDoneThisInject = NO;
    sLastNormalizedDrPages = nil;
    @try {
    NSDictionary *dicBook = nil;
    @try {
        id d = [readerVC valueForKey:@"dicBook"];
        if ([d isKindOfClass:[NSDictionary class]]) dicBook = d;
    } @catch (__unused NSException *e) {}
    if (![dicBook isKindOfClass:[NSDictionary class]]) dicBook = sPendingNativeFullBook;
    NSString *bookKey = nil;
    NSString *sourceName = nil;
    if ([dicBook isKindOfClass:[NSDictionary class]]) {
        bookKey = [dicBook[@"bookKey"] isKindOfClass:[NSString class]] ? dicBook[@"bookKey"] : nil;
        sourceName = [dicBook[@"sourceName"] isKindOfClass:[NSString class]] ? dicBook[@"sourceName"] : nil;
        if (title.length == 0 || [title isEqualToString:@"章节"]) {
            NSString *t2 = dicBook[@"cpTitle"] ?: dicBook[@"title"];
            if ([t2 isKindOfClass:[NSString class]] && t2.length > 0) title = t2;
        }
    }
    if (bookKey.length == 0) {
        @try {
            id v = [readerVC valueForKey:@"bookKey"];
            if ([v isKindOfClass:[NSString class]]) bookKey = v;
        } @catch (__unused NSException *e) {}
    }
    if (bookKey.length == 0) bookKey = @"legado|bridge";
    if (sourceName.length == 0) {
        @try {
            id v = [readerVC valueForKey:@"sourceName"];
            if ([v isKindOfClass:[NSString class]]) sourceName = v;
        } @catch (__unused NSException *e) {}
    }
    if (sourceName.length == 0) {
        sourceName = [payload[@"sourceName"] isKindOfClass:[NSString class]]
            ? payload[@"sourceName"] : @"本地静态测试源";
    }

    // 同章近期已 nativePaged：直接跳过，禁止二次 divisionResponse（曾 SIGABRT sig=6）
    NSString *dedupeKey = [NSString stringWithFormat:@"%@|%ld|%lu",
                           bookKey, (long)cpIndex, (unsigned long)body.length];
    NSTimeInterval nowTs = CFAbsoluteTimeGetCurrent();
    if (sLastNativePagedOkTs > 0 &&
        (nowTs - sLastNativePagedOkTs) < 12.0 &&
        [sLastNativePagedKey isEqualToString:dedupeKey]) {
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"contentInject dedupeSkip recentPaged phase=%@ key=%@",
                                 phase ?: @"?", dedupeKey]);
        return YES;
    }

    NSMutableArray *okPaths = [NSMutableArray array];

    // 1) dicContents：原生换章/排版内存缓存
    @try {
        NSMutableDictionary *dc = nil;
        id cur = nil;
        @try { cur = [readerVC valueForKey:@"dicContents"]; } @catch (__unused NSException *e) {}
        if ([cur isKindOfClass:[NSMutableDictionary class]]) {
            dc = (NSMutableDictionary *)cur;
        } else if ([cur isKindOfClass:[NSDictionary class]]) {
            dc = [NSMutableDictionary dictionaryWithDictionary:(NSDictionary *)cur];
        } else {
            dc = [NSMutableDictionary dictionary];
        }
        dc[@(cpIndex)] = body;
        dc[[@(cpIndex) stringValue]] = body;
        if (title.length > 0) dc[title] = body;
        NSString *chUrl = payload[@"chapterUrl"] ?: payload[@"cpUrl"];
        if ([chUrl isKindOfClass:[NSString class]] && chUrl.length > 0) dc[chUrl] = body;
        LBForceSetIvar(readerVC, @"dicContents", dc);
        if ([readerVC respondsToSelector:@selector(setDicContents:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(readerVC, @selector(setDicContents:), dc);
        }
        [okPaths addObject:@"dicContents"];
    } @catch (NSException *ex) {
        LBAppendOpenReaderTrace([NSString stringWithFormat:@"contentInject dicContents EX %@",
                                 ex.reason ?: @""]);
    }

    // 2) 本地书同构：Documents/xsfolder/book/<bookKey>/<cpIndex> + localSourceText
    NSString *bookDir = [NSHomeDirectory() stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"Documents/xsfolder/book/%@", bookKey]];
    @try {
        [[NSFileManager defaultManager] createDirectoryAtPath:bookDir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];
        NSString *cpPath = [bookDir stringByAppendingPathComponent:
                            [NSString stringWithFormat:@"%ld", (long)cpIndex]];
        [body writeToFile:cpPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        // 兼容 %@%li 命名
        NSString *alt = [bookDir stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"%@%ld", bookKey, (long)cpIndex]];
        [body writeToFile:alt atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        NSDictionary *plist = @{
            @"list": @[ @{
                @"title": title,
                @"url": [@(cpIndex) stringValue]
            } ]
        };
        NSString *lst = [bookDir stringByAppendingPathComponent:@"localSourceText"];
        [plist writeToFile:lst atomically:YES];
        LBForceSetIvar(readerVC, @"bookDirPath", bookDir);
        if ([readerVC respondsToSelector:NSSelectorFromString(@"setBookDirPath:")]) {
            ((void (*)(id, SEL, id))objc_msgSend)(readerVC,
                                                  NSSelectorFromString(@"setBookDirPath:"),
                                                  bookDir);
        }
        [okPaths addObject:@"localSourceText"];
    } @catch (NSException *ex) {
        LBAppendOpenReaderTrace([NSString stringWithFormat:@"contentInject localFile EX %@",
                                 ex.reason ?: @""]);
    }

    // 3) setCpCached:cpIndex:bookKey:sourceName:（首参优先正文，失败再试标题）
    @try {
        id mgr = nil;
        for (NSString *cn in @[@"BookDbManager", @"BookQueryManager", @"CacherManager",
                               @"BookCacher", @"LCDiskCacheManager"]) {
            Class cls = NSClassFromString(cn);
            if (!cls) continue;
            if ([cls respondsToSelector:@selector(sharedInstance)]) {
                mgr = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(sharedInstance));
            } else if ([cls respondsToSelector:@selector(sharedManager)]) {
                mgr = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(sharedManager));
            } else if ([cls respondsToSelector:@selector(shared)]) {
                mgr = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(shared));
            }
            if (!mgr) mgr = readerVC; // 部分实现挂在 ReadVC 上
            SEL sel = NSSelectorFromString(@"setCpCached:cpIndex:bookKey:sourceName:");
            if (![mgr respondsToSelector:sel] && ![readerVC respondsToSelector:sel]) {
                mgr = nil;
                continue;
            }
            if (![mgr respondsToSelector:sel]) mgr = readerVC;
            @try {
                ((void (*)(id, SEL, id, NSInteger, id, id))objc_msgSend)(
                    mgr, sel, body, cpIndex, bookKey, sourceName);
                [okPaths addObject:[NSString stringWithFormat:@"setCpCached@%@", cn]];
                break;
            } @catch (__unused NSException *e1) {
                @try {
                    ((void (*)(id, SEL, id, NSInteger, id, id))objc_msgSend)(
                        mgr, sel, title, cpIndex, bookKey, sourceName);
                    [okPaths addObject:[NSString stringWithFormat:@"setCpCachedTitle@%@", cn]];
                    break;
                } @catch (NSException *e2) {
                    LBAppendOpenReaderTrace([NSString stringWithFormat:
                                             @"contentInject setCpCached EX %@ %@",
                                             cn, e2.reason ?: @""]);
                }
            }
        }
        // ReadVC 自身也可能实现
        SEL selSelf = NSSelectorFromString(@"setCpCached:cpIndex:bookKey:sourceName:");
        BOOL alreadyCached = NO;
        for (NSString *p in okPaths) {
            if ([p hasPrefix:@"setCpCached"]) { alreadyCached = YES; break; }
        }
        if (!alreadyCached && [readerVC respondsToSelector:selSelf]) {
            ((void (*)(id, SEL, id, NSInteger, id, id))objc_msgSend)(
                readerVC, selSelf, body, cpIndex, bookKey, sourceName);
            [okPaths addObject:@"setCpCached@self"];
        }
    } @catch (NSException *ex) {
        LBAppendOpenReaderTrace([NSString stringWithFormat:@"contentInject setCpCached outer EX %@",
                                 ex.reason ?: @""]);
    }

    // seed 阶段只写缓存，让随后 ORIG 从缓存排版；避免空读 SIGABRT
    if ([phase containsString:@"Seed"] || [phase containsString:@"seed"]) {
        NSString *pathStr = okPaths.count > 0 ? [okPaths componentsJoinedByString:@"+"] : @"none";
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"contentInject phase=%@ paths=%@ seedOnly=1 len=%lu idx=%ld key=%@",
                                 phase ?: @"?", pathStr,
                                 (unsigned long)body.length, (long)cpIndex, bookKey]);
        return okPaths.count > 0;
    }

    // 4) 原版排版入口：showContent → divisionText → divisionResponse（禁止先毁工具条）
    // nativePaged 仅在正文真正交给 container / showContent 后置位（divisionText alone 不算上屏）
    BOOL nativePaged = NO;
    id pageResult = nil;
    UIView *textReadTV = nil;
    @try {
        NSMutableArray *stack = [NSMutableArray array];
        if (readerVC.isViewLoaded && readerVC.view) [stack addObject:readerVC.view];
        while (stack.count > 0) {
            UIView *v = stack.lastObject;
            [stack removeLastObject];
            if ([NSStringFromClass([v class]) containsString:@"TextReadTV"]) {
                textReadTV = v;
                break;
            }
            for (UIView *sub in v.subviews) [stack addObject:sub];
        }
        if (!textReadTV) {
            for (NSString *k in @[@"curPageTV", @"textViewL", @"textViewR", @"textView", @"tv"]) {
                @try {
                    id tv = [readerVC valueForKey:k];
                    if (tv && [NSStringFromClass([tv class]) containsString:@"TextReadTV"]) {
                        textReadTV = (UIView *)tv;
                        break;
                    }
                } @catch (__unused NSException *e) {}
            }
        }
        if (textReadTV) {
            LBAppendOpenReaderTrace([NSString stringWithFormat:
                                     @"contentInject foundTV=%@",
                                     NSStringFromClass([textReadTV class])]);
            // ORIG 读缓存后可能已上屏：有萧炎则不再强行 divisionResponse（曾致 SIGABRT）
            if ([phase containsString:@"Division"] || [phase containsString:@"Appear"]) {
                NSString *curTxt = nil;
                @try {
                    if ([textReadTV respondsToSelector:@selector(text)]) {
                        curTxt = ((id (*)(id, SEL))objc_msgSend)(textReadTV, @selector(text));
                    } else {
                        curTxt = [textReadTV valueForKey:@"text"];
                    }
                } @catch (__unused NSException *e) {}
                if ([curTxt isKindOfClass:[NSString class]] &&
                    ([curTxt containsString:@"萧炎"] || [curTxt containsString:@"斗气"])) {
                    nativePaged = YES;
                    [okPaths addObject:@"tvAlreadyNative"];
                    @try {
                        if ([readerVC respondsToSelector:NSSelectorFromString(@"hideErrorView")]) {
                            ((void (*)(id, SEL))objc_msgSend)(
                                readerVC, NSSelectorFromString(@"hideErrorView"));
                            [okPaths addObject:@"hideErrorView"];
                        }
                    } @catch (__unused NSException *e) {}
                    LBAppendOpenReaderTrace(@"contentInject reuse ORIG-cached text (skip division)");
                    goto LB_INJECT_FINISH;
                }
            }
        } else {
            LBAppendOpenReaderTrace(@"contentInject no TextReadTV in hierarchy");
        }
        LBLogDivisionSelectors(textReadTV ?: readerVC);

        // 真机无 setPageModel/processPageData：divisionResponse 链 defer SIGABRT sig=6
        BOOL canNativeBind = NO;
        if (textReadTV) {
            SEL spm = NSSelectorFromString(@"setPageModel:");
            Class tvCls = object_getClass(textReadTV);
            if ([textReadTV respondsToSelector:spm] || class_getInstanceMethod(tvCls, spm)) {
                canNativeBind = YES;
            }
        }
        if (!canNativeBind) {
            SEL ppd = NSSelectorFromString(@"processPageData:userInfo:cpTitle:");
            Class walk = object_getClass(readerVC);
            while (walk && walk != [NSObject class]) {
                if (class_getInstanceMethod(walk, ppd)) {
                    canNativeBind = YES;
                    break;
                }
                walk = class_getSuperclass(walk);
            }
        }
        if (!canNativeBind && body.length > 0) {
            if (LBBridgeDebugLoaded()) {
                LBAppendOpenReaderTrace(@"contentInject overlayOnly noNativeBindPath (debug)");
                @try {
                    if (readerVC.isViewLoaded && readerVC.view) {
                        UIView *host = readerVC.view;
                        // 若已有原生 TextReadTV 可见正文，禁止再叠透明 overlay
                        if (textReadTV && !((UIView *)textReadTV).hidden &&
                            ((UIView *)textReadTV).alpha > 0.05) {
                            LBAppendOpenReaderTrace(@"contentInject skipOverlay hasTextReadTV");
                            [okPaths addObject:@"skipOverlayHasTV"];
                        } else {
                        UITextView *overlay = (UITextView *)[host viewWithTag:92011];
                        if (!overlay) {
                            CGFloat top = 88, bottom = 72;
                            CGRect f = CGRectMake(12, top, host.bounds.size.width - 24,
                                                  MAX(120, host.bounds.size.height - top - bottom));
                            overlay = [[UITextView alloc] initWithFrame:f];
                            overlay.tag = 92011;
                            overlay.accessibilityIdentifier = @"legado_bridge_overlay92011";
                            overlay.editable = NO;
                            // 禁止 clearColor：透明叠在原生正文上必叠字
                            overlay.backgroundColor = [UIColor whiteColor];
                            overlay.font = [UIFont systemFontOfSize:18];
                            overlay.textColor = [UIColor darkTextColor];
                            overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                UIViewAutoresizingFlexibleHeight;
                            [host addSubview:overlay];
                        }
                        // 乱码标题（UTF-8 被当 Latin1）不拼进正文
                        NSString *safeTitle = title;
                        if ([safeTitle containsString:@"ç¬¬"] || [safeTitle containsString:@"Ã"]) {
                            safeTitle = @"";
                        }
                        overlay.text = safeTitle.length > 0
                            ? [NSString stringWithFormat:@"%@\n\n%@", safeTitle, body]
                            : body;
                        overlay.accessibilityLabel = body;
                        overlay.hidden = NO;
                        [host bringSubviewToFront:overlay];
                        [okPaths addObject:@"overlay92011"];
                        }
                    }
                    if (textReadTV) {
                        LBStampTextReadTVProbe(textReadTV, nil, body);
                        [okPaths addObject:@"tvHasNeedleProbeOnly"];
                    }
                } @catch (NSException *ex) {
                    LBAppendOpenReaderTrace([NSString stringWithFormat:
                                             @"contentInject overlayOnly EX %@", ex.reason ?: @""]);
                }
                goto LB_INJECT_FINISH;
            }
            LBAppendOpenReaderTrace(@"contentInject native_bind_failed noNativeBindPath");
            [okPaths addObject:@"native_bind_failed"];
            goto LB_INJECT_FINISH;
        }

        // 4a) showContent:title: —— 与 showErrorView 成对（ alone 不算 nativePaged）
        SEL show2 = NSSelectorFromString(@"showContent:title:");
        SEL show1 = NSSelectorFromString(@"showContent:");
        if ([readerVC respondsToSelector:show2]) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(readerVC, show2, body, title);
            [okPaths addObject:@"showContentTitle"];
        } else if ([readerVC respondsToSelector:show1]) {
            ((void (*)(id, SEL, id))objc_msgSend)(readerVC, show1, body);
            [okPaths addObject:@"showContent"];
        }
        if (textReadTV && body.length > 0) {
            LBInvokeShowContent(textReadTV, body, title, okPaths, @"showContentTVPre");
        }

        // 4b) divisionText：真机归属 PaibanManager
        id paiban = nil;
        @try { paiban = [readerVC valueForKey:@"tr_paibanInfo"]; } @catch (__unused NSException *e) {}
        if (!paiban && textReadTV) {
            @try { paiban = [textReadTV valueForKey:@"tr_paibanInfo"]; } @catch (__unused NSException *e) {}
        }
        Class paibanMgrCls2 = NSClassFromString(@"PaibanManager");
        id pmEarly = nil;
        if (paibanMgrCls2) {
            for (NSString *ss in @[@"sharedInstance", @"shared", @"sharedManager"]) {
                SEL s = NSSelectorFromString(ss);
                if ([paibanMgrCls2 respondsToSelector:s]) {
                    pmEarly = ((id (*)(id, SEL))objc_msgSend)(paibanMgrCls2, s);
                    if (pmEarly) break;
                }
            }
        }
        if (!paiban && pmEarly) {
            @try { paiban = [pmEarly valueForKey:@"curPaiban"]; } @catch (__unused NSException *e) {}
            if (!paiban) {
                @try { paiban = [pmEarly valueForKey:@"tr_paibanInfo"]; } @catch (__unused NSException *e) {}
            }
            if (!paiban && [pmEarly respondsToSelector:NSSelectorFromString(@"paibanById:")]) {
                @try {
                    paiban = ((id (*)(id, SEL, id))objc_msgSend)(
                        pmEarly, NSSelectorFromString(@"paibanById:"), @"default");
                } @catch (__unused NSException *e) {}
            }
        }
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"contentInject paibanCls=%@",
                                 paiban ? NSStringFromClass([paiban class]) : @"nil"]);
        CGSize sz = textReadTV ? textReadTV.bounds.size : readerVC.view.bounds.size;
        if (sz.width < 10 || sz.height < 10) {
            sz = UIScreen.mainScreen.bounds.size;
            sz.width -= 24;
            sz.height -= 160;
        }
        NSMutableArray *tryList = [NSMutableArray array];
        if (textReadTV) [tryList addObject:textReadTV];
        // 真机 divisionProbe：divisionText 归属 PaibanManager
        Class paibanMgrCls = NSClassFromString(@"PaibanManager");
        if (paibanMgrCls) {
            id pm = nil;
            for (NSString *ss in @[@"sharedInstance", @"shared", @"sharedManager", @"defaultManager"]) {
                SEL s = NSSelectorFromString(ss);
                if ([paibanMgrCls respondsToSelector:s]) {
                    pm = ((id (*)(id, SEL))objc_msgSend)(paibanMgrCls, s);
                    if (pm) break;
                }
            }
            if (!pm) {
                @try { pm = [[paibanMgrCls alloc] init]; } @catch (__unused NSException *e) {}
            }
            if (pm) {
                [tryList insertObject:pm atIndex:0];
                LBAppendOpenReaderTrace([NSString stringWithFormat:
                                         @"contentInject paibanMgr=%@",
                                         NSStringFromClass([pm class])]);
            } else {
                [tryList addObject:paibanMgrCls];
            }
        }
        Class util = NSClassFromString(@"LCCoreTextUtil");
        if (util) {
            id utilInst = nil;
            if ([util respondsToSelector:@selector(sharedInstance)]) {
                utilInst = ((id (*)(id, SEL))objc_msgSend)(util, @selector(sharedInstance));
            } else if ([util respondsToSelector:@selector(shared)]) {
                utilInst = ((id (*)(id, SEL))objc_msgSend)(util, @selector(shared));
            }
            if (utilInst) [tryList addObject:utilInst];
            [tryList addObject:util];
        }
        for (id tgt in tryList) {
            BOOL isCls = object_isClass(tgt);
            pageResult = LBCallDivisionText(tgt, isCls, body, title, cpIndex, sz, paiban);
            if (pageResult) {
                [okPaths addObject:[NSString stringWithFormat:@"divisionText@%@",
                                    isCls ? NSStringFromClass((Class)tgt)
                                          : NSStringFromClass([tgt class])]];
                // 注意：此处不置 nativePaged，须等 divisionResponse 上屏
                break;
            }
        }
        if (!pageResult && textReadTV) {
            Class tvCls = NSClassFromString(@"TextReadTV");
            Class tvBase = NSClassFromString(@"TextReadTVBase");
            Class candidates[2] = { tvCls, tvBase };
            for (int ci = 0; ci < 2; ci++) {
                Class c = candidates[ci];
                if (!c) continue;
                Method m1 = class_getInstanceMethod(
                    c,
                    NSSelectorFromString(@"divisionText:cpTitle:cpIndex:tvSize:doubleCol:backHeights:paibanInfo:"));
                Method m2 = class_getInstanceMethod(
                    c,
                    NSSelectorFromString(@"divisionText:cpTitle:cpIndex:tvSize:doubleCol:backHeights:"));
                if (!(m1 || m2)) continue;
                pageResult = LBCallDivisionText(textReadTV, NO, body, title, cpIndex, sz, paiban);
                if (pageResult) {
                    [okPaths addObject:[NSString stringWithFormat:@"divisionText@inst/%@",
                                        NSStringFromClass(c)]];
                    break;
                }
            }
        }
        if (!pageResult) {
            LBAppendOpenReaderTrace(@"contentInject divisionText miss all targets");
        }
        // 4c) divisionResponse：Attr 须先 wrap ReadPageModel；onFinish 用同批扁平页再 nest 外层
        BOOL drResponded = NO;
        if (pageResult) {
            id divisionTextRaw = pageResult;
            NSArray *flatAttrPages = LBFlattenDivisionPages(pageResult);
            CGSize normSz = textReadTV ? textReadTV.bounds.size : readerVC.view.bounds.size;
            if (normSz.width < 10 || normSz.height < 10) {
                normSz = UIScreen.mainScreen.bounds.size;
                normSz.width -= 24;
                normSz.height -= 160;
            }
            id normalized = LBNormalizePageResultForDivision(pageResult, okPaths, normSz);
            sLastNormalizedDrPages = normalized;
            id drPages = normalized ?: divisionTextRaw;
            // divisionResponse 吃 ReadPageModel；onFinish 须 divisionText 原始 Attr（禁 wrapReadPageModel）
            pageResult = normalized ?: flatAttrPages ?: pageResult;
            id sample = nil;
            NSString *fcls = @"-";
            if ([pageResult isKindOfClass:[NSArray class]] && [(NSArray *)pageResult count] > 0) {
                sample = [(NSArray *)pageResult firstObject];
                fcls = NSStringFromClass([sample class]);
            }
            LBAppendOpenReaderTrace([NSString stringWithFormat:
                                     @"contentInject pageResult cls=%@ count=%lu first=%@ norm=%d",
                                     NSStringFromClass([pageResult class]),
                                     [pageResult isKindOfClass:[NSArray class]]
                                         ? (unsigned long)[(NSArray *)pageResult count] : 0,
                                     fcls, normalized ? 1 : 0]);

            NSArray *containers = LBCollectDivisionHosts(readerVC);
            NSMutableArray *heights = sLastDivisionHeights
                ? [sLastDivisionHeights mutableCopy]
                : [NSMutableArray array];
            for (id host in containers) {
                NSString *hn = NSStringFromClass([host class]);
                if (!LBInvokeDivisionResponse(host, drPages, title, cpIndex, heights, okPaths)) {
                    continue;
                }
                drResponded = YES;
                LBInvokeOnDivisionTextFinish(host, divisionTextRaw, cpIndex, okPaths, readerVC, body, textReadTV);
                if (textReadTV) LBForceTextReadTVRefresh(textReadTV);
                if (LBVerifyNativeOnScreenHost(textReadTV, readerVC, host, okPaths)) {
                    nativePaged = YES;
                    break;
                }
                id hostPm = LBExtractPageModelFromHost(host, 0);
                if (hostPm && textReadTV) {
                    CGSize tvSzH = textReadTV.bounds.size;
                    if (LBApplyPageModelToTextReadTV(textReadTV, hostPm, body, tvSzH, okPaths,
                        [NSString stringWithFormat:@"setPageModelHost@%@", hn])) {
                        nativePaged = YES;
                    }
                }
                if (!nativePaged && [hn containsString:@"TextRPageContainer"] && textReadTV &&
                    [pageResult isKindOfClass:[NSArray class]] &&
                    [(NSArray *)pageResult count] > 0) {
                    id pm0 = [(NSArray *)pageResult firstObject];
                    if (![pm0 isKindOfClass:[NSArray class]]) {
                        CGSize tvSz0 = textReadTV.bounds.size;
                        if (LBApplyPageModelToTextReadTV(textReadTV, pm0, body, tvSz0, okPaths,
                                                         @"setPageModelAfterDR")) {
                            nativePaged = YES;
                        }
                    }
                }
                if (LBVerifyNativeOnScreen(textReadTV, readerVC, okPaths)) {
                    nativePaged = YES;
                    break;
                }
                LBAppendOpenReaderTrace([NSString stringWithFormat:
                                         @"contentInject drOK noStrictNeedle host=%@", hn]);
                if ([hn containsString:@"TextRPageContainer"]) break;
            }
            // 仍无上屏：首遍 onFinish 已成功则不再 rawAttr 重试（避免状态污染）
            if (!nativePaged && divisionTextRaw && !sOnDivisionFinishDoneThisInject) {
                LBAppendOpenReaderTrace(@"contentInject retry divisionResponse with rawAttr");
                for (id host in containers) {
                    NSString *hn = NSStringFromClass([host class]);
                    if (![hn containsString:@"ReadPageContainer"] &&
                        ![hn containsString:@"ReadScrollContainer"] &&
                        ![hn containsString:@"TextRPageContainer"] &&
                        ![hn containsString:@"TextReadVC"]) {
                        continue;
                    }
                    if (!LBInvokeDivisionResponse(host, divisionTextRaw, title, cpIndex, heights, okPaths)) {
                        continue;
                    }
                    [okPaths addObject:@"divisionResponseRawAttr"];
                    drResponded = YES;
                    LBInvokeOnDivisionTextFinish(host, divisionTextRaw, cpIndex, okPaths, readerVC, body, textReadTV);
                    if (LBVerifyNativeOnScreen(textReadTV, readerVC, okPaths)) {
                        nativePaged = YES;
                        break;
                    }
                }
            }
            if (drResponded && !nativePaged) {
                LBPostDivisionResponseRefresh(readerVC, textReadTV, divisionTextRaw, title,
                                              cpIndex, body, containers, okPaths, &nativePaged);
            }
            if (!drResponded) {
                NSMutableArray *names = [NSMutableArray array];
                for (id h in containers) {
                    [names addObject:NSStringFromClass([h class])];
                }
                LBAppendOpenReaderTrace([NSString stringWithFormat:
                                         @"contentInject noSel divisionResponse hosts=%@",
                                         [names componentsJoinedByString:@","]]);
            }

            if (drResponded && !nativePaged && textReadTV) {
                LBAppendOpenReaderTrace(@"contentInject drInvoked but TV noStrictNeedle");
                LBTryShowPage0Once(readerVC, okPaths, @"showPage0AfterDR");
                if (LBTextReadTVHasRenderedNeedle(textReadTV, @"萧炎") ||
                    LBTextReadTVHasRenderedNeedle(textReadTV, @"斗气")) {
                    nativePaged = YES;
                    [okPaths addObject:@"tvHasNeedleStrict"];
                }
            }
        } else {
            LBAppendOpenReaderTrace(@"contentInject skip divisionResponse (no pageResult)");
        }

        // 4d) divisionResponse 未上屏时：Attr 辅助灌 TV（不挂 overlay、不算 nativePaged）
        // 禁止同时灌 textViewL+textViewR 并 bringToFront —— 双页叠字根因之一
        if (pageResult && !nativePaged &&
            [pageResult isKindOfClass:[NSArray class]] && [(NSArray *)pageResult count] > 0) {
            id sample0 = [(NSArray *)pageResult firstObject];
            if ([sample0 isKindOfClass:[NSAttributedString class]] ||
                [sample0 isKindOfClass:[NSString class]]) {
                id preferTV = textReadTV;
                if (!preferTV) {
                    for (NSString *k in @[@"textViewL", @"textView", @"curPageTV", @"textViewR"]) {
                        @try {
                            id v = [readerVC valueForKey:k];
                            if (v) { preferTV = v; break; }
                        } @catch (__unused NSException *e) {}
                    }
                }
                if (preferTV) {
                    @try {
                        if ([sample0 isKindOfClass:[NSAttributedString class]]) {
                            if ([preferTV respondsToSelector:@selector(setAttributedText:)]) {
                                ((void (*)(id, SEL, id))objc_msgSend)(
                                    preferTV, @selector(setAttributedText:), sample0);
                            } else {
                                [preferTV setValue:sample0 forKey:@"attributedText"];
                            }
                        } else {
                            NSString *s = (NSString *)sample0;
                            if ([preferTV respondsToSelector:@selector(setText:)]) {
                                ((void (*)(id, SEL, id))objc_msgSend)(preferTV, @selector(setText:), s);
                            }
                        }
                        if ([preferTV isKindOfClass:[UIView class]]) {
                            ((UIView *)preferTV).hidden = NO;
                            ((UIView *)preferTV).alpha = 1;
                        }
                        [okPaths addObject:[NSString stringWithFormat:@"attrToTV@%@",
                                            NSStringFromClass([preferTV class])]];
                    } @catch (NSException *ex) {
                        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                                 @"contentInject attrToTV EX %@",
                                                 ex.reason ?: @""]);
                    }
                }
                LBAppendOpenReaderTrace(@"contentInject attr assist (singleTV, no overlay)");
            }
        }
    } @catch (NSException *ex) {
        LBAppendOpenReaderTrace([NSString stringWithFormat:@"contentInject page EX %@",
                                 ex.reason ?: @""]);
    }

LB_INJECT_FINISH:
    // 同步章节数 + 原版工具条（修假 1/1）
    @try {
        NSInteger catCount = 0;
        id cats = nil;
        @try { cats = [readerVC valueForKey:@"arrCatalog"]; } @catch (__unused NSException *e) {}
        if ([cats isKindOfClass:[NSArray class]]) catCount = (NSInteger)[(NSArray *)cats count];
        if (catCount <= 0) {
            id base = nil;
            @try { base = [readerVC valueForKey:@"arrBaseData"]; } @catch (__unused NSException *e) {}
            if ([base isKindOfClass:[NSArray class]]) catCount = (NSInteger)[(NSArray *)base count];
        }
        if (catCount <= 0 && [sPendingCatalogChapters isKindOfClass:[NSArray class]]) {
            catCount = (NSInteger)sPendingCatalogChapters.count;
            if (catCount > 0) {
                LBTrySetArrayKey(readerVC, @"arrCatalog", sPendingCatalogChapters);
                LBTrySetArrayKey(readerVC, @"arrBaseData", sPendingCatalogChapters);
                LBTrySetArrayKey(readerVC, @"arrCpInfo", sPendingCatalogChapters);
                [okPaths addObject:[NSString stringWithFormat:@"seedCatalog=%ld", (long)catCount]];
            }
        }
        NSInteger pageCount = 0;
        if ([pageResult isKindOfClass:[NSArray class]] && [(NSArray *)pageResult count] > 0) {
            pageCount = (NSInteger)[(NSArray *)pageResult count];
        }
        LBRefreshNativeReaderChrome(readerVC, cpIndex, catCount, pageCount, okPaths);
    } @catch (__unused NSException *e) {}

    // CoreText 控件：setText 无效；优先 setPageModel:（pageResult 首项，Attr 不 wrap 空壳 RPM）
    @try {
        id pageModel = nil;
        NSArray *flatFinal = LBFlattenDivisionPages(pageResult);
        if (flatFinal.count > 0) {
            id first = flatFinal.firstObject;
            if ([first isKindOfClass:[NSAttributedString class]] ||
                [first isKindOfClass:[NSString class]]) {
                pageModel = first;
            } else if (![first isKindOfClass:[NSArray class]]) {
                pageModel = first;
            }
        }
        NSMutableArray *tvs = [NSMutableArray array];
        if (textReadTV) [tvs addObject:textReadTV];
        for (NSString *k in @[@"textViewL", @"textViewR", @"textView", @"curPageTV", @"tv"]) {
            @try {
                id v = [readerVC valueForKey:k];
                if (v && ![tvs containsObject:v]) [tvs addObject:v];
            } @catch (__unused NSException *e) {}
        }
        SEL spm = NSSelectorFromString(@"setPageModel:");
        BOOL hadNativeDisplay = NO;
        for (NSString *p in okPaths) {
            if ([p isEqualToString:@"tvHasNeedleStrict"] ||
                [p isEqualToString:@"tvHasNeedleAfterShow"] ||
                [p isEqualToString:@"tvAlreadyNative"] ||
                [p isEqualToString:@"tvHasNeedleFinal"]) {
                hadNativeDisplay = YES;
                break;
            }
        }
        CGSize spmSz = textReadTV ? textReadTV.bounds.size : CGSizeZero;
        for (id tv in tvs) {
            Class tvCls = object_getClass(tv);
            BOOL canSpm = [tv respondsToSelector:spm] || class_getInstanceMethod(tvCls, spm);
            if (pageModel && canSpm && !hadNativeDisplay) {
                if (LBApplyPageModelToTextReadTV((UIView *)tv, pageModel, body, spmSz, okPaths,
                    [NSString stringWithFormat:@"setPageModel@%@",
                     NSStringFromClass([tv class])])) {
                    nativePaged = YES;
                }
            }
            // divisionResponse/onFinish 后禁止 setText/setAttributedText（CoreText TV 异步 SIGABRT sig=6）
            BOOL skipTvFill = LBContentInjectOkPathsHadDivisionResponse(okPaths) ||
                              sOnDivisionFinishDoneThisInject;
            if (!nativePaged && body.length > 0 && !skipTvFill) {
                NSString *full = [NSString stringWithFormat:@"%@\n\n%@", title, body];
                @try {
                    if ([tv respondsToSelector:@selector(setText:)]) {
                        ((void (*)(id, SEL, id))objc_msgSend)(tv, @selector(setText:), full);
                    }
                } @catch (__unused NSException *e) {}
                @try {
                    NSAttributedString *attr =
                        [[NSAttributedString alloc] initWithString:full
                                                        attributes:@{
                            NSFontAttributeName: [UIFont systemFontOfSize:18],
                            NSForegroundColorAttributeName: [UIColor darkTextColor]
                        }];
                    if ([tv respondsToSelector:@selector(setAttributedText:)]) {
                        ((void (*)(id, SEL, id))objc_msgSend)(
                            tv, @selector(setAttributedText:), attr);
                    }
                } @catch (__unused NSException *e) {}
                @try {
                    if ([tv isKindOfClass:[UIView class]]) {
                        ((UIView *)tv).hidden = NO;
                        ((UIView *)tv).alpha = 1;
                        [((UIView *)tv).superview bringSubviewToFront:(UIView *)tv];
                    }
                } @catch (__unused NSException *e) {}
            } else if (skipTvFill && !nativePaged) {
                LBAppendOpenReaderTrace(@"contentInject tvFillAssist skip postDivisionResponse");
            }
        }
        if (tvs.count > 0 && !nativePaged &&
            !LBContentInjectOkPathsHadDivisionResponse(okPaths) &&
            !sOnDivisionFinishDoneThisInject) {
            [okPaths addObject:@"tvFillAssist"];
        }
    } @catch (__unused NSException *e) {}

    // 最终验收：须屏上真实渲染；探针仅辅助 MCP assert
    if (!nativePaged && textReadTV) {
        BOOL hasDR = NO;
        for (NSString *p in okPaths) {
            if ([p hasPrefix:@"divisionResponse"]) {
                hasDR = YES;
                break;
            }
        }
        if (hasDR) {
            NSArray *flatFinal = LBFlattenDivisionPages(pageResult);
            if (flatFinal.count > 0) {
                id pmFinal = flatFinal.firstObject;
                if (![pmFinal isKindOfClass:[NSArray class]]) {
                    CGSize tvSzF = textReadTV.bounds.size;
                    if (LBApplyPageModelToTextReadTV(textReadTV, pmFinal, body, tvSzF, okPaths,
                                                     @"setPageModelFinal")) {
                        nativePaged = YES;
                    }
                }
            }
            if (!nativePaged) {
                LBTryShowPage0Once(readerVC, okPaths, @"showPage0Final");
            }
            if (LBTextReadTVHasRenderedNeedle(textReadTV, @"萧炎") ||
                LBTextReadTVHasRenderedNeedle(textReadTV, @"斗气")) {
                nativePaged = YES;
                [okPaths addObject:@"tvHasNeedleFinal"];
            }
            if (!nativePaged &&
                ([pageResult isKindOfClass:[NSArray class]] && [(NSArray *)pageResult count] > 0)) {
                LBStampTextReadTVProbe(textReadTV, [(NSArray *)pageResult firstObject], body);
            } else if (!nativePaged && body.length > 0) {
                LBStampTextReadTVProbe(textReadTV, nil, body);
            }
            if (!nativePaged && LBTextReadTVHasNeedle(textReadTV, @"萧炎")) {
                [okPaths addObject:@"tvHasNeedleProbeOnly"];
                LBAppendOpenReaderTrace(@"contentInject final probeOnly (nativePaged=0)");
            }
        }
    }

    if (nativePaged) {
        @try {
            if ([readerVC respondsToSelector:NSSelectorFromString(@"hideErrorView")]) {
                ((void (*)(id, SEL))objc_msgSend)(readerVC, NSSelectorFromString(@"hideErrorView"));
                [okPaths addObject:@"hideErrorView"];
            }
        } @catch (__unused NSException *e) {}
        @try {
            id ev = nil;
            @try { ev = [readerVC valueForKey:@"errorView"]; } @catch (__unused NSException *e) {}
            if ([ev isKindOfClass:[UIView class]]) {
                UIView *errV = (UIView *)ev;
                errV.hidden = YES;
                errV.alpha = 0;
                errV.userInteractionEnabled = NO;
                [okPaths addObject:@"errorViewHidden"];
            }
        } @catch (__unused NSException *e) {}
        // 扫树藏 ReadErrorView（hideErrorView 有时只清标志不藏视图）
        @try {
            if (readerVC.isViewLoaded && readerVC.view) {
                NSMutableArray *vs = [NSMutableArray arrayWithObject:readerVC.view];
                while (vs.count > 0) {
                    UIView *v = vs.lastObject;
                    [vs removeLastObject];
                    NSString *vn = NSStringFromClass([v class]);
                    if ([vn containsString:@"ErrorView"] || [vn containsString:@"ReadError"]) {
                        v.hidden = YES;
                        v.alpha = 0;
                        v.userInteractionEnabled = NO;
                        [okPaths addObject:@"readErrorHidden"];
                    }
                    for (UIView *sub in v.subviews) [vs addObject:sub];
                }
            }
        } @catch (__unused NSException *e) {}
        // 不主动 gotoCp/showPage：divisionResponse 已上屏；误调易二次布局 SIGABRT
        @try {
            LBNativeReaderStripBridgeOverlays(readerVC);
            [okPaths addObject:@"overlayRemoved"];
        } @catch (__unused NSException *e) {}
        sLastNativePagedOkTs = CFAbsoluteTimeGetCurrent();
        sLastNativePagedKey = [dedupeKey copy];
        sNativeOpenChapterDone = YES;
        sDeferredNativeOpenIdx = -1;
        // F2/acceptance：正文已上屏后去掉磁盘 open_once，内存占坑仍挡二次 push
        LBClearNativeOpenOnceMarker();
        LBAppendOpenReaderTrace(@"nativeOpen diskOpenOnce cleared after nativePagedOk");
    } else {
        BOOL hasDivision = NO;
        BOOL hasNativeDR = NO;
        for (NSString *p in okPaths) {
            if ([p hasPrefix:@"divisionText@"]) hasDivision = YES;
            if ([p hasPrefix:@"divisionResponse"]) hasNativeDR = YES;
        }
        if (hasDivision && !hasNativeDR) {
            LBAppendOpenReaderTrace(@"contentInject native-page-miss (divisionText ok, display pending)");
            LBTryShowPage0Once(readerVC, okPaths, @"showPage0");
        } else if (hasNativeDR) {
            // 主链 onDivisionTextFinish 已完成时禁止二次补链（final probeOnly 后曾 SIGABRT sig=6）
            if (sOnDivisionFinishDoneThisInject) {
                LBAppendOpenReaderTrace(@"contentInject drOK skip postFinishDuplicate");
                if (!nativePaged && textReadTV && body.length > 0) {
                    LBStampTextReadTVProbe(textReadTV, nil, body);
                    [okPaths addObject:@"tvHasNeedleProbeOnly"];
                }
            } else {
                LBAppendOpenReaderTrace(@"contentInject drOK strict miss try onFinish+showPage0");
                NSArray *flatFinal = LBFlattenDivisionPages(pageResult);
                if (flatFinal.count > 0) {
                    NSArray *containers = LBCollectDivisionHosts(readerVC);
                    BOOL finishOk = NO;
                    for (id h in containers) {
                        if (LBInvokeOnDivisionTextFinish(h, flatFinal, cpIndex, okPaths, readerVC, body, textReadTV)) {
                            finishOk = YES;
                            break;
                        }
                    }
                    if (!finishOk) {
                        LBInvokeOnDivisionTextFinish(readerVC, flatFinal, cpIndex, okPaths, readerVC, body, textReadTV);
                    }
                    if (textReadTV) LBForceTextReadTVRefresh(textReadTV);
                }
                if (textReadTV && flatFinal.count > 0) {
                    id pmMiss = flatFinal.firstObject;
                    if (![pmMiss isKindOfClass:[NSArray class]]) {
                        CGSize tvSzM = textReadTV.bounds.size;
                        if (LBApplyPageModelToTextReadTV(textReadTV, pmMiss, body, tvSzM, okPaths,
                                                         @"setPageModelMiss")) {
                            nativePaged = YES;
                        }
                    }
                }
                if (!nativePaged) {
                    LBTryShowPage0Once(readerVC, okPaths, @"showPage0DRMiss");
                    if (textReadTV &&
                        (LBTextReadTVHasRenderedNeedle(textReadTV, @"萧炎") ||
                         LBTextReadTVHasRenderedNeedle(textReadTV, @"斗气"))) {
                        nativePaged = YES;
                        [okPaths addObject:@"tvHasNeedleStrict"];
                    }
                }
                if (!nativePaged && textReadTV && body.length > 0) {
                    LBStampTextReadTVProbe(textReadTV, nil, body);
                    [okPaths addObject:@"tvHasNeedleProbeOnly"];
                    LBAppendOpenReaderTrace(@"contentInject dr strict miss probe for assert");
                }
                if (nativePaged) {
                    sLastNativePagedOkTs = CFAbsoluteTimeGetCurrent();
                    sLastNativePagedKey = [dedupeKey copy];
                    sNativeOpenChapterDone = YES;
                    sDeferredNativeOpenIdx = -1;
                    LBClearNativeOpenOnceMarker();
                    LBAppendOpenReaderTrace(@"nativeOpen diskOpenOnce cleared after nativePagedOk(dr)");
                }
            }
        } else if (!hasNativeDR) {
            LBAppendOpenReaderTrace(@"contentInject fallback TV+hideError (divisionText miss)");
            @try {
                if (textReadTV) {
                    NSString *full = [NSString stringWithFormat:@"%@\n\n%@", title, body];
                    if ([textReadTV respondsToSelector:@selector(setText:)]) {
                        ((void (*)(id, SEL, id))objc_msgSend)(textReadTV, @selector(setText:), full);
                    } else {
                        [textReadTV setValue:full forKey:@"text"];
                    }
                    [okPaths addObject:@"tvKVCTextFallback"];
                }
            } @catch (__unused NSException *e) {}
            @try {
                if (LBBridgeDebugLoaded() && readerVC.isViewLoaded && readerVC.view) {
                    UIView *host = readerVC.view;
                    if (textReadTV && !((UIView *)textReadTV).hidden &&
                        ((UIView *)textReadTV).alpha > 0.05) {
                        LBAppendOpenReaderTrace(@"contentInject skipOverlay2 hasTextReadTV");
                        [okPaths addObject:@"skipOverlayHasTV"];
                    } else {
                    UITextView *overlay = (UITextView *)[host viewWithTag:92011];
                    if (!overlay) {
                        CGFloat top = 88, bottom = 72;
                        CGRect f = CGRectMake(12, top, host.bounds.size.width - 24,
                                              MAX(120, host.bounds.size.height - top - bottom));
                        overlay = [[UITextView alloc] initWithFrame:f];
                        overlay.tag = 92011;
                        overlay.accessibilityIdentifier = @"legado_bridge_overlay92011";
                        overlay.editable = NO;
                        overlay.backgroundColor = [UIColor whiteColor];
                        overlay.font = [UIFont systemFontOfSize:18];
                        overlay.textColor = [UIColor darkTextColor];
                        overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                            UIViewAutoresizingFlexibleHeight;
                        [host addSubview:overlay];
                    }
                    NSString *safeTitle = title;
                    if ([safeTitle containsString:@"ç¬¬"] || [safeTitle containsString:@"Ã"]) {
                        safeTitle = @"";
                    }
                    overlay.text = safeTitle.length > 0
                        ? [NSString stringWithFormat:@"%@\n\n%@", safeTitle, body]
                        : body;
                    overlay.accessibilityLabel = body;
                    overlay.hidden = NO;
                    [host bringSubviewToFront:overlay];
                    [okPaths addObject:@"overlay92011"];
                    }
                } else if (!LBBridgeDebugLoaded()) {
                    LBAppendOpenReaderTrace(@"contentInject native_bind_failed divisionTextMiss");
                    [okPaths addObject:@"native_bind_failed"];
                }
            } @catch (NSException *ex) {
                LBAppendOpenReaderTrace([NSString stringWithFormat:@"contentInject overlay EX %@",
                                         ex.reason ?: @""]);
            }
        }
        // divisionResponse+onFinish 后 hideErrorView/扫树易触发二次布局 SIGABRT
        if (!(hasNativeDR && sOnDivisionFinishDoneThisInject)) {
            @try {
                if ([readerVC respondsToSelector:NSSelectorFromString(@"hideErrorView")]) {
                    ((void (*)(id, SEL))objc_msgSend)(readerVC, NSSelectorFromString(@"hideErrorView"));
                    [okPaths addObject:@"hideErrorView"];
                }
            } @catch (__unused NSException *e) {}
            @try {
                id ev = nil;
                @try { ev = [readerVC valueForKey:@"errorView"]; } @catch (__unused NSException *e) {}
                if ([ev isKindOfClass:[UIView class]]) {
                    ((UIView *)ev).hidden = YES;
                    ((UIView *)ev).alpha = 0;
                    ((UIView *)ev).userInteractionEnabled = NO;
                    [okPaths addObject:@"errorViewHidden"];
                }
            } @catch (__unused NSException *e) {}
            @try {
                if (readerVC.isViewLoaded && readerVC.view) {
                    NSMutableArray *vs = [NSMutableArray arrayWithObject:readerVC.view];
                    while (vs.count > 0) {
                        UIView *v = vs.lastObject;
                        [vs removeLastObject];
                        NSString *vn = NSStringFromClass([v class]);
                        if ([vn containsString:@"ErrorView"] || [vn containsString:@"ReadError"]) {
                            v.hidden = YES;
                            v.alpha = 0;
                            v.userInteractionEnabled = NO;
                            [okPaths addObject:@"readErrorHidden"];
                        }
                        for (UIView *sub in v.subviews) [vs addObject:sub];
                    }
                }
            } @catch (__unused NSException *e) {}
        } else {
            LBAppendOpenReaderTrace(@"contentInject hideError skip postFinishDuplicate");
        }
    }

    NSString *pathStr = okPaths.count > 0 ? [okPaths componentsJoinedByString:@"+"] : @"none";
    LBAppendOpenReaderTrace([NSString stringWithFormat:
                             @"contentInject phase=%@ paths=%@ nativePaged=%d len=%lu idx=%ld key=%@",
                             phase ?: @"?", pathStr, nativePaged ? 1 : 0,
                             (unsigned long)body.length, (long)cpIndex, bookKey]);
    BOOL hasXiaoyan = [body containsString:@"萧炎"] || [body containsString:@"斗气"];
    BOOL hasDivisionPath = NO;
    for (NSString *p in okPaths) {
        if ([p hasPrefix:@"divisionText@"] || [p hasPrefix:@"divisionResponse"]) {
            hasDivisionPath = YES;
            break;
        }
    }
    if (hasXiaoyan && okPaths.count > 0) {
        LBWriteOpenReaderMarker([NSString stringWithFormat:
                                 @"nativeOpen keepTextRead readerVis=1 via=nativeFull contentInject=%@ nativePaged=%d division=%d phase=%@",
                                 pathStr, nativePaged ? 1 : 0, hasDivisionPath ? 1 : 0, phase ?: @""]);
    }
    return LBInjectOkPathsCountAsSuccess(okPaths, nativePaged);
    } @catch (NSException *exTop) {
        LBAppendOpenReaderTrace([NSString stringWithFormat:@"contentInject TOP_EX %@",
                                 exTop.reason ?: @""]);
        return NO;
    } @finally {
        sContentInjectBusy = NO;
    }
}

static BOOL LBKickDeliverBlocked(void) {
    return sKickDeliverBlockUntilTs > 0 &&
           CFAbsoluteTimeGetCurrent() < sKickDeliverBlockUntilTs;
}

static void LBKickMarkDeliverBlock(void) {
    sKickDeliverBlockUntilTs = CFAbsoluteTimeGetCurrent() + kKickDeliverBlockSec;
}

/// 向可见 TextRead 交付正文：nativeFull 优先原生缓存/排版；禁止无参 onReset 空读「错误的书本」
static void LBDeliverContentToVisibleReaders(NSString *phase) {
    if (LBKickDeliverBlocked()) {
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"deliver_skip_after_kick phase=%@", phase ?: @""]);
        return;
    }
    NSDictionary *payload = sPendingResetContent;
    if (![payload isKindOfClass:[NSDictionary class]] || payload.count == 0) {
        LBAppendOpenReaderTrace([NSString stringWithFormat:@"deliverSkip empty phase=%@", phase ?: @""]);
        return;
    }
    NSDictionary *safe = LBSanitizeResetContentUserInfo(payload);
    for (UIWindow *w in LBAllAppWindows()) {
        UIViewController *root = w.rootViewController;
        if (!root) continue;
        NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
        while (stack.count > 0) {
            UIViewController *vc = stack.lastObject;
            [stack removeLastObject];
            NSString *cn = NSStringFromClass([vc class]);
            BOOL isRead = [cn containsString:@"TextReadVC"] || [cn containsString:@"ReadVCBase"];
            if (isRead && LBVCIsVisibleInWindow(vc)) {
                if (sLegadoReaderMode == 1) {
                    // 优先：dicContents / xsfolder / setCpCached / division*
                    BOOL injected = LBInjectNativeChapterContent(vc, safe, phase ?: @"deliver");
                    if (injected) {
                        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                                 @"deliver nativeInject_OK phase=%@ cls=%@",
                                                 phase ?: @"?", cn]);
                        // 原生已上屏：必须拆 bridge overlay，禁止再灌 UITextView（叠字根因）
                        LBNativeReaderStripBridgeOverlays(vc);
                        NSString *orMarker = nil;
                        @try {
                            orMarker = [NSString stringWithContentsOfFile:
                                [NSHomeDirectory() stringByAppendingPathComponent:
                                 @"Documents/legado_catalog_openreader.txt"]
                                                               encoding:NSUTF8StringEncoding
                                                                  error:NULL];
                        } @catch (__unused NSException *e) {}
                        BOOL nativePagedOk = (orMarker &&
                                              ([orMarker containsString:@"nativePaged=1"] ||
                                               [orMarker containsString:@"divisionResponse"] ||
                                               [orMarker containsString:@"showContent"]));
                        BOOL needTV = (!nativePagedOk && orMarker &&
                                       ([orMarker containsString:@"overlay92011"] ||
                                        [orMarker containsString:@"tvKVCTextFallback"] ||
                                        [orMarker containsString:@"native-page-miss"] ||
                                        [orMarker containsString:@"native_bind_failed"]));
                        if (needTV) {
                            LBInjectPendingContentIntoReader(
                                vc, [NSString stringWithFormat:@"%@-tv", phase ?: @"deliver"]);
                        }
                        continue;
                    }
                    BOOL delivered = NO;
                    NSArray *sels = @[@"onResetContentNotify:",
                                      @"onResetContent:", @"resetContentNotify:",
                                      @"handleResetContent:"];
                    for (NSString *sn in sels) {
                        SEL sel = NSSelectorFromString(sn);
                        if (![vc respondsToSelector:sel]) continue;
                        @try {
                            LBSeedTurnPageTypeScrollBranch();
                            NSNotification *note =
                                [NSNotification notificationWithName:@"dNotifyName_ReadView_ResetContent"
                                                              object:nil
                                                            userInfo:safe];
                            if (LBOrig_onResetContentNotify &&
                                [sn isEqualToString:@"onResetContentNotify:"]) {
                                LBOrig_onResetContentNotify(vc, sel, note);
                            } else {
                                ((void (*)(id, SEL, id))objc_msgSend)(vc, sel, note);
                            }
                            LBAppendOpenReaderTrace([NSString stringWithFormat:
                                                     @"deliver ORIG_OK phase=%@ cls=%@ sel=%@",
                                                     phase ?: @"?", cn, sn]);
                            delivered = YES;
                            break;
                        } @catch (NSException *ex) {
                            LBAppendOpenReaderTrace([NSString stringWithFormat:
                                                     @"deliver ORIG_EX phase=%@ sel=%@ %@",
                                                     phase ?: @"?", sn, ex.reason ?: @""]);
                        }
                    }
                    // 无参 onReset 读不到 pending，且会显示「错误的书本」——仅在无正文时作探测
                    NSString *body = safe[@"chapterContent"] ?: safe[@"content"] ?: @"";
                    BOOL hasBody = [body isKindOfClass:[NSString class]] && body.length > 0;
                    if (!delivered && !hasBody &&
                        [vc respondsToSelector:NSSelectorFromString(@"onResetContentNotify")]) {
                        @try {
                            LBSeedTurnPageTypeScrollBranch();
                            ((void (*)(id, SEL))objc_msgSend)(
                                vc, NSSelectorFromString(@"onResetContentNotify"));
                            LBAppendOpenReaderTrace([NSString stringWithFormat:
                                                     @"deliver noArg_OK phase=%@ cls=%@",
                                                     phase ?: @"?", cn]);
                            delivered = YES;
                        } @catch (NSException *ex) {
                            LBAppendOpenReaderTrace([NSString stringWithFormat:
                                                     @"deliver noArg_EX %@", ex.reason ?: @""]);
                        }
                    }
                    if (injected || delivered) continue;
                    LBAppendOpenReaderTrace([NSString stringWithFormat:
                                             @"deliver NO_SEL phase=%@ cls=%@",
                                             phase ?: @"?", cn]);
                }
                // nativeFull 注入失败或 safeShell：最后才 TextReadTV/UITextView 直灌
                LBInjectPendingContentIntoReader(vc, phase ?: @"deliver");
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
}

static void LBInstallNativeResetContentHook(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *names = @[@"TextReadVC3", @"TextReadVC2", @"TextReadVC1",
                           @"ReadVCBase2", @"ReadVCBase1"];
        NSArray *sels = @[
            @"onResetContentNotify",   // 真机 class_copyMethodList：无冒号
            @"onResetContentNotify:",
            @"onResetContent:",
            @"resetContentNotify:",
            @"handleResetContent:"
        ];
        BOOL hooked = NO;
        for (NSString *cn in names) {
            Class cls = NSClassFromString(cn);
            if (!cls) {
                LBAppendOpenReaderTrace([NSString stringWithFormat:@"nativeReset miss class %@", cn]);
                continue;
            }
            for (NSString *sn in sels) {
                SEL sel = NSSelectorFromString(sn);
                Class owner = LBClassOwningInstanceMethod(cls, sel);
                Method m = owner ? class_getInstanceMethod(owner, sel) : NULL;
                if (!m) {
                    // 无冒号方法有时 class_getInstanceMethod 需精确 SEL
                    m = class_getInstanceMethod(cls, sel);
                    owner = cls;
                }
                if (!m) continue;
                const char *types = method_getTypeEncoding(m) ?: "v16@0:8";
                BOOL takesNote = (strchr(types, '@') != NULL) && (strstr(types, "@24") != NULL || strstr(types, "@32") != NULL || [sn hasSuffix:@":"]);
                if (!LBOrig_onResetContentNotify && takesNote) {
                    LBOrig_onResetContentNotify =
                        (void (*)(id, SEL, NSNotification *))method_getImplementation(m);
                }
                IMP hook = NULL;
                if (takesNote || [sn hasSuffix:@":"]) {
                    hook = imp_implementationWithBlock(^void(id selfObj, NSNotification *note) {
                        NSDictionary *safe = LBSanitizeResetContentUserInfo(note.userInfo);
                        sPendingResetContent = safe;
                        NSNotification *safeNote =
                            [NSNotification notificationWithName:note.name ?: @"dNotifyName_ReadView_ResetContent"
                                                          object:note.object
                                                        userInfo:safe];
                        if (sLegadoReaderMode == 1 && LBOrig_onResetContentNotify) {
                            LBSeedTurnPageTypeScrollBranch();
                            LBLogHypothesisB2ContainerProbe(selfObj, @"onReset_hook_before_ORIG");
                            @try {
                                LBOrig_onResetContentNotify(selfObj, sel, safeNote);
                                LBLogHypothesisB2ContainerProbe(selfObj, @"onReset_hook_after_ORIG");
                                LBAppendOpenReaderTrace([NSString stringWithFormat:
                                                         @"onReset hook ORIG_OK cls=%@ sel=%@",
                                                         NSStringFromClass([selfObj class]), sn]);
                                LBHypothesisFProbeAfterOrig(selfObj, @"onReset_hook_after_ORIG");
                                return;
                            } @catch (NSException *ex) {
                                LBAppendOpenReaderTrace([NSString stringWithFormat:
                                                         @"onReset hook ORIG_EX %@", ex.reason ?: @""]);
                            }
                        }
                        if (sLegadoReaderMode != 1) {
                            LBInjectPendingContentIntoReader((UIViewController *)selfObj, @"onResetHook");
                            return;
                        }
                        LBInjectPendingContentIntoReader((UIViewController *)selfObj, @"onResetFallback");
                    });
                } else {
                    // 无参：本地书仍 seed→ORIG；nativeFull 下 ORIG 在 beforeOrigSeed 后杀进程（无 ORIG_OK）
                    static BOOL sOnResetNoArgBusy = NO;
                    IMP capturedIMP = method_getImplementation(m);
                    IMP nativeResolved = LBResolveOnResetNoArgNativeIMP(owner ?: cls, sel, capturedIMP);
                    if (nativeResolved) sOnResetNoArgNativeIMP = nativeResolved;
                    void (*origNoArg)(id, SEL) = (void (*)(id, SEL))capturedIMP;
                    hook = imp_implementationWithBlock(^void(id selfObj) {
                        if (sOnResetNoArgBusy) return;
                        sOnResetNoArgBusy = YES;
                        BOOL hasPending =
                            (sLegadoReaderMode == 1 &&
                             [sPendingResetContent isKindOfClass:[NSDictionary class]] &&
                             sPendingResetContent.count > 0);
                        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                                 @"onReset noArg enter cls=%@ mode=%d pending=%d",
                                                 NSStringFromClass([selfObj class]),
                                                 sLegadoReaderMode, hasPending ? 1 : 0]);
                        // 假设 E：B2 seed + window/catalog/didAppearUIKit 就绪后再调无参 ORIG
                        if (sLegadoReaderMode == 1) {
                            UIViewController *vc = (UIViewController *)selfObj;
                            NSUInteger cat = LBReadArrayCount(selfObj, @"arrCatalog");
                            BOOL hasWindow = (vc.viewIfLoaded.window != nil);
                            if (cat >= 1 && hasWindow && sDidAppearUIKit) {
                                LBHypothesisEFireOnResetNoArg(selfObj, sel, origNoArg, @"immediate");
                                sOnResetNoArgBusy = NO;
                                return;
                            }
                            if (cat < 1) {
                                LBAppendOpenReaderTrace(@"hypothesis_E defer_onReset reason=no_catalog");
                            } else if (!hasWindow) {
                                LBAppendOpenReaderTrace(@"hypothesis_C defer_onReset reason=no_window");
                            } else {
                                LBAppendOpenReaderTrace(@"hypothesis_E defer_onReset reason=no_didAppear");
                            }
                            LBHypothesisEScheduleOnResetNoArg(vc, sel, origNoArg, 0, ^{
                                sOnResetNoArgBusy = NO;
                            });
                            return;
                        }
                        if (hasPending) {
                            @try {
                                LBInjectNativeChapterContent((UIViewController *)selfObj,
                                                             sPendingResetContent,
                                                             @"beforeOrigSeed");
                            } @catch (NSException *ex0) {
                                LBAppendOpenReaderTrace([NSString stringWithFormat:
                                                         @"onReset seed EX %@",
                                                         ex0.reason ?: @""]);
                            }
                        }
                        @try {
                            if (origNoArg) origNoArg(selfObj, sel);
                            LBAppendOpenReaderTrace(hasPending
                                ? @"onReset noArg ORIG_OK (afterSeed)"
                                : @"onReset noArg ORIG_OK");
                        } @catch (NSException *ex) {
                            LBAppendOpenReaderTrace([NSString stringWithFormat:
                                                     @"onReset noArg EX %@", ex.reason ?: @""]);
                        }
                        if (hasPending) {
                            __strong UIViewController *vcKeep = (UIViewController *)selfObj;
                            NSDictionary *payloadKeep = sPendingResetContent;
                            dispatch_async(dispatch_get_main_queue(), ^{
                                @try {
                                    if (sOnDivisionFinishDoneThisInject || sContentInjectBusy) {
                                        LBAppendOpenReaderTrace(
                                            @"onReset skip afterOrigDivision onFinishDone");
                                        return;
                                    }
                                    if ([payloadKeep isKindOfClass:[NSDictionary class]] &&
                                        payloadKeep.count > 0) {
                                        LBInjectNativeChapterContent(vcKeep, payloadKeep,
                                                                     @"afterOrigDivision");
                                    }
                                } @catch (NSException *ex2) {
                                    LBAppendOpenReaderTrace([NSString stringWithFormat:
                                                             @"onReset division EX %@",
                                                             ex2.reason ?: @""]);
                                }
                            });
                        }
                        sOnResetNoArgBusy = NO;
                    });
                }
                method_setImplementation(m, hook);
                LBAppendOpenReaderTrace([NSString stringWithFormat:
                                         @"nativeReset hooked %@ @%@ sel=%@ types=%s",
                                         cn, NSStringFromClass(owner), sn, types]);
                hooked = YES;
                break;
            }
            if (hooked) break;
        }
        if (!hooked) {
            // 诊断：列出候选类上含 Reset/Content 的方法名
            for (NSString *cn in names) {
                Class cls = NSClassFromString(cn);
                while (cls && cls != [NSObject class]) {
                    unsigned int n = 0;
                    Method *ms = class_copyMethodList(cls, &n);
                    for (unsigned int i = 0; i < n; i++) {
                        NSString *mn = NSStringFromSelector(method_getName(ms[i]));
                        NSString *low = mn.lowercaseString;
                        if ([low containsString:@"reset"] || [low containsString:@"content"]) {
                            LBAppendOpenReaderTrace([NSString stringWithFormat:
                                                     @"nativeReset cand %@::%@",
                                                     NSStringFromClass(cls), mn]);
                        }
                    }
                    if (ms) free(ms);
                    cls = class_getSuperclass(cls);
                }
            }
            LBAppendOpenReaderTrace(@"nativeReset HOOK_MISS all candidates");
        }
    });
}

/// 不调 openReader：alloc TextReadVC 后 push/present，正文靠 ResetContent 灌入
static void LBInjectPendingContentIntoReader(UIViewController *readerVC, NSString *phase) {
    NSDictionary *payload = sPendingResetContent;
    if (![payload isKindOfClass:[NSDictionary class]] || payload.count == 0) {
        LBAppendOpenReaderTrace([NSString stringWithFormat:@"injectSkip empty phase=%@", phase ?: @""]);
        return;
    }
    // nativeFull：禁止再找任意 UITextView 直灌（会叠在原生分页上）
    if (sLegadoReaderMode == 1) {
        LBNativeReaderStripBridgeOverlays(readerVC);
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"injectSkip nativeFullNoTV phase=%@", phase ?: @""]);
        return;
    }
    NSString *body = nil;
    id c = payload[@"chapterContent"] ?: payload[@"content"];
    if ([c isKindOfClass:[NSString class]]) body = (NSString *)c;
    if (body.length == 0) {
        LBAppendOpenReaderTrace([NSString stringWithFormat:@"injectSkip noBody phase=%@", phase ?: @""]);
        return;
    }
    // 禁止 post ResetContent：裸 TextRead 收通知会 SIGABRT。直接灌 UITextView / TextReadTV。
    NSMutableArray *stack = [NSMutableArray array];
    if (readerVC.isViewLoaded && readerVC.view) [stack addObject:readerVC.view];
    UITextView *target = nil;
    UIView *textReadTV = nil;
    while (stack.count > 0) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        NSString *vn = NSStringFromClass([v class]);
        if ([vn containsString:@"TextReadTV"]) {
            textReadTV = v;
        }
        if ([v isKindOfClass:[UITextView class]]) {
            target = (UITextView *)v;
            if (v.tag == 92001) break; // 优先我们挂的 safeShell TV
            if (v.bounds.size.width >= 200 && v.bounds.size.height >= 200) break;
        }
        for (UIView *sub in v.subviews) [stack addObject:sub];
    }
    if (!target) {
        // 再试 KVC 常见出口（含 TextReadTV）
        for (NSString *k in @[@"textView", @"textViewL", @"textViewR", @"tv", @"contentTextView"]) {
            @try {
                id tv = [readerVC valueForKey:k];
                if ([tv isKindOfClass:[UITextView class]]) {
                    target = (UITextView *)tv;
                    break;
                }
                if (tv && [NSStringFromClass([tv class]) containsString:@"TextReadTV"]) {
                    textReadTV = (UIView *)tv;
                }
            } @catch (__unused NSException *e) {}
        }
    }
    if (!target && textReadTV) {
        // TextReadTV 非 UITextView：尝试 KVC text / attributedText / setText:
        @try {
            NSString *title = payload[@"cpTitle"] ?: payload[@"title"] ?: @"";
            if (![title isKindOfClass:[NSString class]]) title = @"";
            NSString *full = title.length > 0
                ? [NSString stringWithFormat:@"%@\n\n%@", title, body]
                : body;
            if ([textReadTV respondsToSelector:@selector(setText:)]) {
                ((void (*)(id, SEL, id))objc_msgSend)(textReadTV, @selector(setText:), full);
            } else {
                [textReadTV setValue:full forKey:@"text"];
            }
            LBAppendOpenReaderTrace([NSString stringWithFormat:
                                     @"injectOK phase=%@ len=%lu tv=TextReadTV",
                                     phase ?: @"", (unsigned long)body.length]);
            if ([body containsString:@"萧炎"] || [body containsString:@"斗气"]) {
                LBWriteOpenReaderMarker([NSString stringWithFormat:
                                        @"nativeOpen keepTextRead readerVis=1 via=nativeFull-TextReadTV phase=%@",
                                        phase ?: @""]);
            }
            return;
        } @catch (NSException *e) {
            LBAppendOpenReaderTrace([NSString stringWithFormat:@"injectTextReadTVEx %@", e.reason ?: @""]);
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
            NSString *via = (sLegadoReaderMode == 1) ? @"nativeFull-inject" : @"injectTV";
            LBWriteOpenReaderMarker([NSString stringWithFormat:
                                    @"nativeOpen keepTextRead readerVis=1 via=%@ phase=%@",
                                    via, phase ?: @""]);
        }
    } @catch (NSException *e) {
        LBAppendOpenReaderTrace([NSString stringWithFormat:@"injectEx %@", e.reason ?: @""]);
    }
}

static BOOL sLegadoSafeTextReadShell = NO;
static void (*LBOrig_TR_viewDidLoad)(id, SEL) = NULL;
static void (*LBOrig_TR_viewWillAppear)(id, SEL, BOOL) = NULL;
static void (*LBOrig_TR_viewDidAppear)(id, SEL, BOOL) = NULL;
static int sTRViewDidLoadDepth = 0;
static int sTRViewWillAppearDepth = 0;
static int sTRViewDidAppearDepth = 0;

static void LBTextRead_viewDidLoad_Safe(id self, SEL _cmd);
static void LBTextRead_viewWillAppear_Safe(id self, SEL _cmd, BOOL animated);
static void LBTextRead_viewDidAppear_Safe(id self, SEL _cmd, BOOL animated);

typedef IMP (*LBForensicsEarlyWrapIMPFn)(NSString *);
typedef IMP (*LBForensicsResolveOrigIMPFn)(Class, SEL);

static BOOL LBIsKnownTextReadHookIMP(IMP imp, SEL sel) {
    if (!imp) return NO;
    if (sel == @selector(viewDidLoad) && imp == (IMP)LBTextRead_viewDidLoad_Safe) return YES;
    if (sel == @selector(viewWillAppear:) && imp == (IMP)LBTextRead_viewWillAppear_Safe) return YES;
    if (sel == @selector(viewDidAppear:) && imp == (IMP)LBTextRead_viewDidAppear_Safe) return YES;
    static LBForensicsEarlyWrapIMPFn earlyWrapFn = NULL;
    static dispatch_once_t onceEarly;
    dispatch_once(&onceEarly, ^{
        earlyWrapFn = (LBForensicsEarlyWrapIMPFn)dlsym(RTLD_DEFAULT,
                                                        "LBForensicsEarlyWrapIMPForSelectorName");
    });
    if (earlyWrapFn) {
        IMP early = earlyWrapFn(NSStringFromSelector(sel));
        if (early && imp == early) return YES;
    }
    return NO;
}

/// 沿 Safe / EarlyWrap / ResolveOrig 解包，直到 IMP 不再是已知钩子
static IMP LBUnwrapHookIMP(Class cls, SEL sel, IMP start) {
    IMP imp = start;
    if (!imp) {
        Method m = class_getInstanceMethod(cls, sel);
        imp = m ? method_getImplementation(m) : NULL;
    }
    static LBForensicsResolveOrigIMPFn resolveOrig = NULL;
    static dispatch_once_t onceResolve;
    dispatch_once(&onceResolve, ^{
        resolveOrig = (LBForensicsResolveOrigIMPFn)dlsym(RTLD_DEFAULT, "LBForensicsResolveOrigIMP");
    });
    for (int hop = 0; hop < 12 && imp; hop++) {
        if (!LBIsKnownTextReadHookIMP(imp, sel)) break;
        IMP next = NULL;
        if (sel == @selector(viewDidLoad) && imp == (IMP)LBTextRead_viewDidLoad_Safe) {
            next = (IMP)LBOrig_TR_viewDidLoad;
        } else if (sel == @selector(viewWillAppear:) && imp == (IMP)LBTextRead_viewWillAppear_Safe) {
            next = (IMP)LBOrig_TR_viewWillAppear;
        } else if (sel == @selector(viewDidAppear:) && imp == (IMP)LBTextRead_viewDidAppear_Safe) {
            next = (IMP)LBOrig_TR_viewDidAppear;
        }
        if (resolveOrig) {
            IMP forensics = resolveOrig(cls, sel);
            if (forensics && !LBIsKnownTextReadHookIMP(forensics, sel)) {
                imp = forensics;
                break;
            }
            if (forensics && forensics != imp) next = forensics;
        }
        if (!next || next == imp) break;
        imp = next;
    }
    return imp;
}

static IMP LBUnwrapViewDidLoadIMP(Class cls) {
    return LBUnwrapHookIMP(cls, @selector(viewDidLoad), (IMP)LBOrig_TR_viewDidLoad);
}

typedef IMP (*LBForensicsResolveObserverOrigIMPFn)(Class, SEL);
typedef IMP (*LBForensicsHookIMPForSelectorNameFn)(NSString *);

static BOOL LBIsBlockInvokeIMP(IMP imp) {
    if (!imp) return NO;
    Dl_info info;
    if (!dladdr((void *)imp, &info) || !info.dli_sname) return NO;
    return strstr(info.dli_sname, "block_invoke") != NULL;
}

static BOOL LBIsMainAppImageIMP(IMP imp) {
    if (!imp) return NO;
    Dl_info info;
    if (!dladdr((void *)imp, &info) || !info.dli_fname) return NO;
    const char *path = info.dli_fname;
    if (strstr(path, "LegadoBridge") != NULL) return NO;
    if (strstr(path, "StandarReader") != NULL) return YES;
    return strstr(path, ".app/") != NULL && strstr(path, ".dylib") == NULL;
}

static NSString *LBLookupIMPDlName(IMP imp) {
    if (!imp) return @"nil";
    Dl_info info;
    if (!dladdr((void *)imp, &info)) return @"?";
    NSString *fname = info.dli_fname ? [NSString stringWithUTF8String:info.dli_fname] : @"?";
    return fname.lastPathComponent ?: @"?";
}

static BOOL LBIsOnResetNoArgHookIMP(IMP imp, SEL sel) {
    if (!imp) return YES;
    if (LBIsKnownTextReadHookIMP(imp, sel)) return YES;
    static LBForensicsHookIMPForSelectorNameFn hookForSel = NULL;
    static dispatch_once_t onceHook;
    dispatch_once(&onceHook, ^{
        hookForSel = (LBForensicsHookIMPForSelectorNameFn)dlsym(RTLD_DEFAULT,
                                                                 "LBForensicsHookIMPForSelectorName");
    });
    if (hookForSel) {
        NSString *selName = NSStringFromSelector(sel);
        IMP fh = hookForSel(selName);
        if (fh && imp == fh) return YES;
        IMP early = NULL;
        static LBForensicsEarlyWrapIMPFn earlyWrapFn = NULL;
        static dispatch_once_t onceEarly;
        dispatch_once(&onceEarly, ^{
            earlyWrapFn = (LBForensicsEarlyWrapIMPFn)dlsym(RTLD_DEFAULT,
                                                            "LBForensicsEarlyWrapIMPForSelectorName");
        });
        if (earlyWrapFn) {
            early = earlyWrapFn(selName);
            if (early && imp == early) return YES;
        }
    }
    if (LBIsBlockInvokeIMP(imp)) return YES;
    return NO;
}

/// 假设 I：沿 owner 类链解包 onResetContentNotify 无参 IMP，跳过 Bridge block / Forensics 短桩
static IMP LBResolveOnResetNoArgNativeIMP(Class cls, SEL sel, IMP hint) {
    if (!cls || !sel) return NULL;
    static LBForensicsResolveObserverOrigIMPFn resolveObs = NULL;
    static LBForensicsResolveOrigIMPFn resolveEarly = NULL;
    static dispatch_once_t onceResolve;
    dispatch_once(&onceResolve, ^{
        resolveObs = (LBForensicsResolveObserverOrigIMPFn)dlsym(RTLD_DEFAULT,
                                                                 "LBForensicsResolveObserverOrigIMP");
        resolveEarly = (LBForensicsResolveOrigIMPFn)dlsym(RTLD_DEFAULT, "LBForensicsResolveOrigIMP");
    });

    Class owner = LBClassOwningInstanceMethod(cls, sel) ?: cls;
    IMP imp = hint;
    if (!imp) {
        Method m = class_getInstanceMethod(owner, sel);
        imp = m ? method_getImplementation(m) : NULL;
    }

    NSMutableSet<NSValue *> *seen = [NSMutableSet set];
    for (int hop = 0; hop < 16 && imp; hop++) {
        NSValue *key = [NSValue valueWithPointer:imp];
        if ([seen containsObject:key]) break;
        [seen addObject:key];

        if (LBIsMainAppImageIMP(imp) && !LBIsOnResetNoArgHookIMP(imp, sel)) {
            return imp;
        }

        IMP next = NULL;
        if (LBIsOnResetNoArgHookIMP(imp, sel)) {
            if (resolveObs) next = resolveObs(owner, sel);
            if ((!next || next == imp) && resolveEarly) next = resolveEarly(owner, sel);
            if ((!next || next == imp) && owner) {
                next = LBUnwrapHookIMP(owner, sel, imp);
            }
        }
        if (!next || next == imp) break;
        imp = next;
    }

    if (resolveObs) {
        IMP obs = resolveObs(owner, sel);
        if (obs && LBIsMainAppImageIMP(obs) && !LBIsOnResetNoArgHookIMP(obs, sel)) return obs;
    }
    return NULL;
}

static void LBTextRead_viewDidLoad_Safe(id self, SEL _cmd) {
    if (sTRViewDidLoadDepth > 0) {
        LBAppendOpenReaderTrace(@"TR viewDidLoad reenter-skip");
        struct objc_super sup = { self, [UIViewController class] };
        ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&sup, _cmd);
        return;
    }
    sTRViewDidLoadDepth++;
    @try {
    LBAppendOpenReaderTrace([NSString stringWithFormat:
                             @"TR viewDidLoad enter mode=%d shell=%d cls=%@",
                             sLegadoReaderMode, sLegadoSafeTextReadShell ? 1 : 0,
                             NSStringFromClass([self class])]);
    // 仅对带 legadoBridge 的阅读页走 shell/nativeFull；本地书始终 ORIG
    BOOL isLegadoReader = NO;
    id dicProbe = nil;
    @try { dicProbe = [self valueForKey:@"dicBook"]; } @catch (__unused NSException *e) {}
    if (![dicProbe isKindOfClass:[NSDictionary class]]) dicProbe = sPendingNativeFullBook;
    if ([dicProbe isKindOfClass:[NSDictionary class]] &&
        (dicProbe[@"legadoBridge"] || dicProbe[@"fromLegadoBridge"])) {
        isLegadoReader = YES;
    }
    LBAppendOpenReaderTrace([NSString stringWithFormat:
                             @"TR viewDidLoad legado=%d dicKeys=%lu",
                             isLegadoReader ? 1 : 0,
                             [dicProbe isKindOfClass:[NSDictionary class]]
                                 ? (unsigned long)[(NSDictionary *)dicProbe count] : 0]);
    // mode 2 / 显式 safeShell：跳过原生，自挂 UITextView
    if (isLegadoReader && (sLegadoReaderMode == 2 || sLegadoSafeTextReadShell)) {
        LBAppendOpenReaderTrace(@"safeShell viewDidLoad");
        struct objc_super sup = { self, [UIViewController class] };
        ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&sup, _cmd);
        UIViewController *vc = (UIViewController *)self;
        if (!vc.isViewLoaded) return;
        UITextView *tv = [[UITextView alloc] initWithFrame:vc.view.bounds];
        tv.tag = 92001;
        tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        tv.editable = NO;
        tv.font = [UIFont systemFontOfSize:18];
        tv.textContainerInset = UIEdgeInsetsMake(24, 16, 24, 16);
        [vc.view addSubview:tv];
        vc.title = @"阅读";
        LBAppendOpenReaderTrace(@"safeShell added UITextView");
        return;
    }
    // mode 1 nativeFull：恢复原生 viewDidLoad（需 ReadPageContainer）
    // 420392d 旁路 ORIG 可活到 delayed_begin，但无 container → seed/invoke 回桌面。
    // 与 onReset/Deliver/catalog 旁路叠用，验证 ORIG 本身是否仍是 0.35s 杀手。
    if (isLegadoReader && sLegadoReaderMode == 1) {
        LBAppendOpenReaderTrace(@"nativeFull viewDidLoad begin");
        LBSeedTurnPageTypeScrollBranch();
        LBLogHypothesisB2ContainerProbe(self, @"viewDidLoad_enter");
        LBPrepareTextReadNativeFull(self, sPendingNativeFullBook);
        LBLogHypothesisB2ContainerProbe(self, @"viewDidLoad_after_prep");
        Class cls = object_getClass(self);
        IMP orig = LBUnwrapViewDidLoadIMP(cls);
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"hypothesis_R2 viewDidLoad ORIG_restore unwrap=%p", orig]);
        @try {
            if (orig && !LBIsKnownTextReadHookIMP(orig, _cmd)) {
                LBLogHypothesisB2ContainerProbe(self, @"viewDidLoad_before_ORIG");
                ((void (*)(id, SEL))orig)(self, _cmd);
                LBLogHypothesisB2ContainerProbe(self, @"viewDidLoad_after_ORIG");
                LBAppendOpenReaderTrace(@"hypothesis_R2 viewDidLoad ORIG_OK");
                LBWriteOpenReaderMarker(@"nativeOpen viewDidLoad ORIG_OK via=nativeFull");
            } else {
                LBAppendOpenReaderTrace(@"hypothesis_R2 viewDidLoad ORIG_SKIP unwrap-miss");
                struct objc_super sup = { self, [UIViewController class] };
                ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&sup, _cmd);
            }
        } @catch (NSException *ex) {
            LBAppendOpenReaderTrace([NSString stringWithFormat:
                                     @"hypothesis_R2 viewDidLoad ORIG_EX %@",
                                     ex.reason ?: @""]);
            struct objc_super sup = { self, [UIViewController class] };
            @try {
                ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&sup, _cmd);
            } @catch (__unused NSException *e2) {}
        }
        return;
    }
    if (LBOrig_TR_viewDidLoad) LBOrig_TR_viewDidLoad(self, _cmd);
    } @finally {
        sTRViewDidLoadDepth--;
    }
}

static void LBTextRead_viewWillAppear_Safe(id self, SEL _cmd, BOOL animated) {
    if (sTRViewWillAppearDepth > 0) {
        LBAppendOpenReaderTrace(@"TR viewWillAppear reenter-skip");
        struct objc_super sup = { self, [UIViewController class] };
        ((void (*)(struct objc_super *, SEL, BOOL))objc_msgSendSuper)(&sup, _cmd, animated);
        return;
    }
    sTRViewWillAppearDepth++;
    @try {
    BOOL isLegadoReader = NO;
    id dicProbe = nil;
    @try { dicProbe = [self valueForKey:@"dicBook"]; } @catch (__unused NSException *e) {}
    if (![dicProbe isKindOfClass:[NSDictionary class]]) dicProbe = sPendingNativeFullBook;
    if ([dicProbe isKindOfClass:[NSDictionary class]] &&
        (dicProbe[@"legadoBridge"] || dicProbe[@"fromLegadoBridge"])) {
        isLegadoReader = YES;
    }
    if (isLegadoReader && (sLegadoReaderMode == 2 || sLegadoSafeTextReadShell)) {
        struct objc_super sup = { self, [UIViewController class] };
        ((void (*)(struct objc_super *, SEL, BOOL))objc_msgSendSuper)(&sup, _cmd, animated);
        return;
    }
    if (isLegadoReader && sLegadoReaderMode == 1) {
        // 0a7f4fa：UIKitSuperOnly 日志后无 UIKitSuper_OK 即重启回书架。
        // 回到 noop；container 改由 ivar dump / 手工挂载解决。
        // 原生壳：尽早藏系统导航栏，避免白底「返回」与 toolBarHeader 双顶栏。
        LBNativeReaderHideHostNavBar(self, YES);
        LBAppendOpenReaderTrace(@"hypothesis_R2 willAppear noop + hideNavBar");
        return;
    }
    if (LBOrig_TR_viewWillAppear) LBOrig_TR_viewWillAppear(self, _cmd, animated);
    } @finally {
        sTRViewWillAppearDepth--;
    }
}

/// G6：读 toolBar* ivar（无 property 时仍走 KVC）
static id LBG6ToolbarIvar(id reader, NSString *key) {
    if (!reader || key.length == 0) return nil;
    id v = nil;
    @try { v = [reader valueForKey:key]; } @catch (__unused NSException *e) {}
    return v;
}

@interface LBG6MidTapProxy : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) id reader;
- (void)onMidTap:(UITapGestureRecognizer *)gr;
@end

@implementation LBG6MidTapProxy
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    (void)gestureRecognizer;
    // 避开顶栏按钮（返回等）
    UIView *v = touch.view;
    if ([v isKindOfClass:[UIControl class]]) return NO;
    // 避开顶/底原生工具栏区域，避免挡住「目录/换源/上一章」等
    id reader = self.reader;
    UIView *root = nil;
    @try {
        if ([reader isKindOfClass:[UIViewController class]] && ((UIViewController *)reader).isViewLoaded) {
            root = ((UIViewController *)reader).view;
        }
    } @catch (__unused NSException *e) {}
    if (root) {
        CGPoint p = [touch locationInView:root];
        CGFloat w = root.bounds.size.width;
        CGFloat h = root.bounds.size.height;
        // 左/右 1/3 留给原生翻章，midTap 只吃中区
        if (w > 1.0 && (p.x < w / 3.0 || p.x > w * 2.0 / 3.0)) return NO;
        if (h > 1.0 && (p.y < 110.0 || p.y > h - 200.0)) return NO;
        // 触摸落在已显示的 header/bottom 上也不抢
        for (NSString *k in @[ @"toolBarHeader", @"toolBarBottom", @"toolBarPageSlider",
                               @"toolBarFont", @"toolBarSetting", @"toolBarTheme" ]) {
            id barObj = nil;
            @try { barObj = [reader valueForKey:k]; } @catch (__unused NSException *e) {}
            if (![barObj isKindOfClass:[UIView class]]) continue;
            UIView *bar = (UIView *)barObj;
            if (bar.hidden || bar.alpha < 0.05) continue;
            CGPoint inBar = [touch locationInView:bar];
            if (CGRectContainsPoint(bar.bounds, inBar)) return NO;
        }
    }
    return YES;
}

- (void)onMidTap:(UITapGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateEnded) return;
    id reader = self.reader;
    if (!reader || sLegadoReaderMode != 1) return;
    UIView *host = gr.view ?: nil;
    @try {
        if (!host && [reader isKindOfClass:[UIViewController class]] && ((UIViewController *)reader).isViewLoaded) {
            host = ((UIViewController *)reader).view;
        }
    } @catch (__unused NSException *e) {}
    if (!host) return;
    CGPoint p = [gr locationInView:host];
    // 统一换算到 reader.view 坐标判中区
    UIView *root = nil;
    @try {
        if ([reader isKindOfClass:[UIViewController class]]) root = ((UIViewController *)reader).view;
    } @catch (__unused NSException *e) {}
    CGPoint pr = root ? [gr locationInView:root] : p;
    CGFloat w = root ? root.bounds.size.width : host.bounds.size.width;
    if (w < 1.0 || pr.x < w / 3.0 || pr.x > w * 2.0 / 3.0) {
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"G6 midTap ignore x=%.0f w=%.0f (not center)", pr.x, w]);
        return;
    }
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (now - sG6LastChangeToolBarTs < 0.20) {
        LBAppendOpenReaderTrace(@"G6 midTap skip (changeToolBar just ran)");
        return;
    }
    SEL sel = NSSelectorFromString(@"changeToolBar");
    if (![reader respondsToSelector:sel]) {
        LBAppendOpenReaderTrace(@"G6 midTap changeToolBar miss");
        return;
    }
    LBAppendOpenReaderTrace([NSString stringWithFormat:@"G6 midTap -> changeToolBar x=%.0f y=%.0f", pr.x, pr.y]);
    ((void (*)(id, SEL))objc_msgSend)(reader, sel);
}
@end

static NSString *LBG6DescribeViewBrief(UIView *v) {
    if (!v) return @"nil";
    NSMutableString *s = [NSMutableString stringWithFormat:@"%@ f=%@ h=%d a=%.2f",
                          NSStringFromClass([v class]),
                          NSStringFromCGRect(v.frame),
                          v.hidden ? 1 : 0,
                          v.alpha];
    @try {
        NSString *lab = v.accessibilityLabel;
        if (lab.length) [s appendFormat:@" lab=%@", lab];
    } @catch (__unused NSException *e) {}
    @try {
        if ([v isKindOfClass:[UIButton class]]) {
            UIButton *b = (UIButton *)v;
            NSString *t = [b titleForState:UIControlStateNormal];
            if (t.length) [s appendFormat:@" title=%@", t];
            UIImage *img = [b imageForState:UIControlStateNormal];
            if (img) [s appendFormat:@" img=%.0fx%.0f", img.size.width, img.size.height];
        }
    } @catch (__unused NSException *e2) {}
    @try {
        if ([v isKindOfClass:[UIImageView class]]) {
            UIImage *img = ((UIImageView *)v).image;
            if (img) [s appendFormat:@" iv=%.0fx%.0f", img.size.width, img.size.height];
        }
    } @catch (__unused NSException *e3) {}
    return s;
}

static void LBG6LogToolbarState(id reader, NSString *phase) {
    id bottom = LBG6ToolbarIvar(reader, @"toolBarBottom");
    id header = LBG6ToolbarIvar(reader, @"toolBarHeader");
    id hidden = LBG6ToolbarIvar(reader, @"toolBarHidden");
    NSUInteger sub = 0;
    NSString *bottomDetail = @"nil";
    NSMutableString *subsDump = [NSMutableString string];
    NSMutableString *extraDump = [NSMutableString string];
    @try {
        if ([reader isKindOfClass:[UIViewController class]] && ((UIViewController *)reader).isViewLoaded) {
            sub = ((UIViewController *)reader).view.subviews.count;
        }
        if ([bottom isKindOfClass:[UIView class]]) {
            UIView *bv = (UIView *)bottom;
            bottomDetail = [NSString stringWithFormat:
                            @"%@ frame=%@ hidden=%d alpha=%.2f sub=%lu superview=%@",
                            NSStringFromClass([bv class]),
                            NSStringFromCGRect(bv.frame),
                            bv.hidden ? 1 : 0,
                            bv.alpha,
                            (unsigned long)bv.subviews.count,
                            bv.superview ? NSStringFromClass([bv.superview class]) : @"nil"];
            NSUInteger lim = MIN(bv.subviews.count, (NSUInteger)10);
            for (NSUInteger i = 0; i < lim; i++) {
                UIView *ch = bv.subviews[i];
                [subsDump appendFormat:@" [%lu]%@", (unsigned long)i, LBG6DescribeViewBrief(ch)];
                // 再下一层（图标常包在容器里）
                NSUInteger lim2 = MIN(ch.subviews.count, (NSUInteger)6);
                for (NSUInteger j = 0; j < lim2; j++) {
                    [subsDump appendFormat:@" [%lu.%lu]%@", (unsigned long)i, (unsigned long)j,
                     LBG6DescribeViewBrief(ch.subviews[j])];
                }
            }
        }
        // arrToolBarBtn + 各分栏面板是否存在
        @try {
            id btns = nil;
            @try { btns = [reader valueForKey:@"arrToolBarBtn"]; } @catch (__unused NSException *e) {}
            if (!btns) {
                @try { btns = [reader valueForKey:@"_arrToolBarBtn"]; } @catch (__unused NSException *e2) {}
            }
            NSUInteger n = [btns respondsToSelector:@selector(count)] ? [btns count] : 0;
            [extraDump appendFormat:@" arrBtn=%lu", (unsigned long)n];
            if ([btns isKindOfClass:[NSArray class]]) {
                NSUInteger lim = MIN(n, (NSUInteger)8);
                for (NSUInteger i = 0; i < lim; i++) {
                    id b = btns[i];
                    if ([b isKindOfClass:[UIView class]]) {
                        [extraDump appendFormat:@" b%lu=%@", (unsigned long)i, LBG6DescribeViewBrief((UIView *)b)];
                    } else {
                        [extraDump appendFormat:@" b%lu=%@", (unsigned long)i,
                         b ? NSStringFromClass([b class]) : @"nil"];
                    }
                }
            }
        } @catch (__unused NSException *e3) {}
        for (NSString *k in @[ @"toolBarFont", @"toolBarTheme", @"toolBarSetting",
                               @"toolBarPageSlider", @"toolBarLeft", @"toolBarRight",
                               @"toolBarPagingT", @"toolBarPaiban" ]) {
            id v = LBG6ToolbarIvar(reader, k);
            if ([v isKindOfClass:[UIView class]]) {
                UIView *vv = (UIView *)v;
                [extraDump appendFormat:@" %@={f=%@ h=%d a=%.2f sub=%lu}",
                 k, NSStringFromCGRect(vv.frame), vv.hidden ? 1 : 0, vv.alpha,
                 (unsigned long)vv.subviews.count];
            } else {
                [extraDump appendFormat:@" %@=%@", k, v ? NSStringFromClass([v class]) : @"nil"];
            }
        }
    } @catch (__unused NSException *e) {}
    LBAppendOpenReaderTrace([NSString stringWithFormat:
                             @"G6 %@ bottom=%@ header=%@ hidden=%@ viewSubs=%lu | %@%@",
                             phase ?: @"?",
                             bottom ? NSStringFromClass([bottom class]) : @"nil",
                             header ? NSStringFromClass([header class]) : @"nil",
                             hidden,
                             (unsigned long)sub,
                             bottomDetail,
                             extraDump]);
    if (subsDump.length) {
        LBAppendOpenReaderTrace([NSString stringWithFormat:@"G6 %@ bottomSubs%@", phase ?: @"?", subsDump]);
    }
}

/// midTap 唤出后 bottom 上已有「目录/缓存/设置/换源」，但 window.y 常落到屏高之外（真机 dump：bottomWin.y=847 > 844）。
/// 另：按钮/图可能是深色 tint；显示态强制浅色。
///
/// 注意：曾对 toolBarLeft/Right 做 frame 上移 + bringToFront，真机出现正文中部黑块、
/// 底栏「目录/换源」点按无响应（只有 Aa 字体面板还能用）。原生壳路径禁止再改 left/right 几何。
static void LBG6ForceToolbarButtonContrast(UIView *root) {
    if (!root) return;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        for (UIView *ch in v.subviews) [stack addObject:ch];
        @try {
            if ([v isKindOfClass:[UIButton class]]) {
                UIButton *b = (UIButton *)v;
                UIColor *fg = [UIColor colorWithWhite:0.92 alpha:1.0];
                [b setTitleColor:fg forState:UIControlStateNormal];
                [b setTitleColor:fg forState:UIControlStateHighlighted];
                b.tintColor = fg;
                if (b.imageView) b.imageView.tintColor = fg;
                b.alpha = 1.0;
                b.hidden = NO;
                b.userInteractionEnabled = YES;
                if (!b.isAccessibilityElement) {
                    b.isAccessibilityElement = YES;
                    if (b.accessibilityLabel.length == 0) {
                        NSString *t = [b titleForState:UIControlStateNormal];
                        if (t.length) b.accessibilityLabel = t;
                    }
                }
            } else if ([v isKindOfClass:[UIImageView class]]) {
                UIImageView *iv = (UIImageView *)v;
                iv.tintColor = [UIColor colorWithWhite:0.92 alpha:1.0];
                iv.alpha = 1.0;
                iv.hidden = NO;
                UIImage *img = iv.image;
                if (img && img.renderingMode != UIImageRenderingModeAlwaysTemplate) {
                    iv.image = [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
                }
            } else if ([v isKindOfClass:[UILabel class]]) {
                UILabel *lb = (UILabel *)v;
                lb.textColor = [UIColor colorWithWhite:0.92 alpha:1.0];
                lb.alpha = 1.0;
                lb.hidden = NO;
            }
        } @catch (__unused NSException *e) {}
    }
}

/// 若底栏/滑条 window 底边超出屏幕——原逻辑会改 frame。
/// 真机已证实：与原生 changeToolBar 动画叠改 → 进度条/黑块顶进正文，底栏点击错乱。
/// 原生壳路径：禁止改任何 toolBar* 几何，只做侧栏遮挡清理。
static void LBG6RepositionToolbarOnScreen(id reader) {
    (void)reader;
    LBAppendOpenReaderTrace(@"G6 reposition disabled (keep native layout)");
}

/// 黑块正体：toolBarPageSlider 整条（上一章/滑条/下一章）。
/// 注意：不可因 hidden/alpha 早退——原生动画会在 hook 之后把 alpha 拉回 1。
static void LBG6SanitizePageSliderOverflow(id reader) {
    id sliderObj = LBG6ToolbarIvar(reader, @"toolBarPageSlider");
    if (![sliderObj isKindOfClass:[UIView class]]) return;
    UIView *slider = (UIView *)sliderObj;
    slider.hidden = YES;
    slider.alpha = 0;
    slider.userInteractionEnabled = NO;
    slider.backgroundColor = [UIColor clearColor];
    LBAppendOpenReaderTrace([NSString stringWithFormat:
                             @"G6 hidePageSliderEntirely f=%@ wasHidden=%d",
                             NSStringFromCGRect(slider.frame),
                             slider.hidden ? 1 : 0]);
}

static BOOL LBG6ViewIsUnderChrome(id reader, UIView *v) {
    if (!v) return NO;
    NSArray<NSString *> *keys = @[
        @"toolBarHeader", @"toolBarBottom", @"toolBarPageSlider",
        @"toolBarFont", @"toolBarSetting", @"toolBarTheme",
        @"toolBarPagingT", @"toolBarPaiban", @"toolBarLeft", @"toolBarRight"
    ];
    for (NSString *k in keys) {
        id chrome = LBG6ToolbarIvar(reader, k);
        if (![chrome isKindOfClass:[UIView class]]) continue;
        UIView *root = (UIView *)chrome;
        if (v == root) return YES;
        if ([v isDescendantOfView:root]) return YES;
    }
    return NO;
}

/// 藏起覆盖正文中部的错位控件（侧栏 / 异常黑块），不改顶底栏原生几何。
static void LBG6HideMisplacedSidePanels(id reader) {
    if (![reader isKindOfClass:[UIViewController class]]) return;
    UIViewController *vc = (UIViewController *)reader;
    if (!vc.isViewLoaded || !vc.view) return;
    CGRect content = vc.view.bounds;
    if (content.size.width < 1 || content.size.height < 1) return;
    CGRect danger = CGRectInset(content, content.size.width * 0.08, content.size.height * 0.18);

    NSArray<NSString *> *keys = @[ @"toolBarLeft", @"toolBarRight", @"toolBarSpeaker" ];
    for (NSString *k in keys) {
        id v = LBG6ToolbarIvar(reader, k);
        if (![v isKindOfClass:[UIView class]]) continue;
        UIView *bar = (UIView *)v;
        if (bar.hidden || bar.alpha < 0.05) continue;
        CGRect inRoot = [bar convertRect:bar.bounds toView:vc.view];
        if (!CGRectIntersectsRect(inRoot, danger)) continue;
        if (inRoot.size.width >= 40 && inRoot.size.height >= 30) {
            bar.hidden = YES;
            bar.alpha = 0;
            bar.userInteractionEnabled = NO;
            LBAppendOpenReaderTrace([NSString stringWithFormat:
                                     @"G6 hideSidePanel %@ frame=%@",
                                     k, NSStringFromCGRect(inRoot)]);
        }
    }

    LBG6SanitizePageSliderOverflow(reader);

    // 扫阅读根视图：正文区大块深色矩形；绝不碰 chrome 子树（曾误藏 UITableViewCell）
    id bottom = LBG6ToolbarIvar(reader, @"toolBarBottom");
    CGFloat chromeTop = content.size.height;
    if ([bottom isKindOfClass:[UIView class]]) {
        CGRect bf = [(UIView *)bottom convertRect:((UIView *)bottom).bounds toView:vc.view];
        id sliderObj = LBG6ToolbarIvar(reader, @"toolBarPageSlider");
        if ([sliderObj isKindOfClass:[UIView class]] && !((UIView *)sliderObj).hidden) {
            CGRect sf = [(UIView *)sliderObj convertRect:((UIView *)sliderObj).bounds toView:vc.view];
            chromeTop = MIN(CGRectGetMinY(bf), CGRectGetMinY(sf));
        } else {
            chromeTop = CGRectGetMinY(bf);
        }
    }

    // 正文容器近底：扫 chromeTop 上方 100pt 带状区内所有深色垫层（真机黑条落在进度条正上方）
    if (vc.view.subviews.count > 0 && chromeTop < content.size.height && chromeTop > 80) {
        UIView *cr = vc.view.subviews[0];
        CGRect band = CGRectMake(0, chromeTop - 100.0, content.size.width, 100.0);
        NSMutableArray<UIView *> *cstack = [NSMutableArray arrayWithObject:cr];
        NSInteger nfix = 0;
        NSMutableString *bandDump = [NSMutableString stringWithFormat:
                                     @"G6 band y=%.0f..%.0f", chromeTop - 100.0, chromeTop];
        while (cstack.count && nfix < 8) {
            UIView *v = cstack.lastObject;
            [cstack removeLastObject];
            for (UIView *ch in v.subviews) [cstack addObject:ch];
            if (v == cr) continue;
            if (v.hidden || v.alpha < 0.05) continue;
            CGRect inRoot = [v convertRect:v.bounds toView:vc.view];
            if (!CGRectIntersectsRect(inRoot, band)) continue;
            NSString *cn = NSStringFromClass([v class]);
            UIColor *bg = v.backgroundColor;
            CGFloat r = 1, g = 1, b = 1, a = 0;
            BOOL dark = NO;
            if (bg && [bg getRed:&r green:&g blue:&b alpha:&a]) {
                dark = (a > 0.25) && (r + g + b) / 3.0 < 0.40;
            }
            if (!dark && v.layer.backgroundColor) {
                UIColor *lc = [UIColor colorWithCGColor:v.layer.backgroundColor];
                if ([lc getRed:&r green:&g blue:&b alpha:&a]) {
                    dark = (a > 0.25) && (r + g + b) / 3.0 < 0.40;
                }
            }
            [bandDump appendFormat:@" [%@ f=%@ dark=%d a=%.2f]",
             cn, NSStringFromCGRect(inRoot), dark ? 1 : 0, v.alpha];
            // 全宽深色条：清底或藏（跳过文字控件）
            BOOL wide = inRoot.size.width >= content.size.width * 0.55;
            BOOL isTextish = [cn containsString:@"Label"] || [cn containsString:@"Button"] ||
                             [cn containsString:@"TextField"] || [cn containsString:@"TextView"];
            if (dark && wide && !isTextish) {
                v.backgroundColor = [UIColor clearColor];
                v.layer.backgroundColor = [UIColor clearColor].CGColor;
                // 若高度像黑块（20~120）直接藏
                if (inRoot.size.height >= 20 && inRoot.size.height <= 120) {
                    v.hidden = YES;
                    v.alpha = 0;
                    nfix++;
                    LBAppendOpenReaderTrace([NSString stringWithFormat:
                                             @"G6 clearBandDark class=%@ frame=%@",
                                             cn, NSStringFromCGRect(inRoot)]);
                }
            }
        }
        LBAppendOpenReaderTrace(bandDump);
    }

    // 正文容器（rootSubs[0] 常为满屏 UIView）底部贴 chrome 的全宽深色条
    if (vc.view.subviews.count > 0 && chromeTop < content.size.height) {
        UIView *contentRoot = vc.view.subviews[0];
        NSMutableArray<UIView *> *cstack = [NSMutableArray arrayWithObject:contentRoot];
        NSInteger nfix = 0;
        while (cstack.count && nfix < 4) {
            UIView *v = cstack.lastObject;
            [cstack removeLastObject];
            for (UIView *ch in v.subviews) [cstack addObject:ch];
            if (v == contentRoot) continue;
            if (v.hidden || v.alpha < 0.15) continue;
            if (LBG6ViewIsUnderChrome(reader, v)) continue;
            CGRect inRoot = [v convertRect:v.bounds toView:vc.view];
            if (inRoot.size.width < content.size.width * 0.7) continue;
            if (inRoot.size.height < 16 || inRoot.size.height > 120) continue;
            // 底边贴着进度条顶（±12）
            if (fabs(CGRectGetMaxY(inRoot) - chromeTop) > 12.0 &&
                !(CGRectGetMaxY(inRoot) > chromeTop - 4 && CGRectGetMinY(inRoot) < chromeTop)) {
                continue;
            }
            UIColor *bg = v.backgroundColor;
            CGFloat r = 1, g = 1, b = 1, a = 0;
            BOOL dark = NO;
            if (bg && [bg getRed:&r green:&g blue:&b alpha:&a]) {
                dark = (a > 0.4) && (r + g + b) / 3.0 < 0.28;
            }
            if (!dark && v.layer.backgroundColor) {
                UIColor *lc = [UIColor colorWithCGColor:v.layer.backgroundColor];
                if ([lc getRed:&r green:&g blue:&b alpha:&a]) {
                    dark = (a > 0.4) && (r + g + b) / 3.0 < 0.28;
                }
            }
            if (!dark) continue;
            v.hidden = YES;
            v.alpha = 0;
            nfix++;
            LBAppendOpenReaderTrace([NSString stringWithFormat:
                                     @"G6 hideContentBlack class=%@ frame=%@",
                                     NSStringFromClass([v class]), NSStringFromCGRect(inRoot)]);
        }
    }

    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:vc.view];
    NSInteger hiddenN = 0;
    while (stack.count) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        for (UIView *ch in v.subviews) [stack addObject:ch];
        if (v == vc.view) continue;
        if (v.hidden || v.alpha < 0.2) continue;
        if (LBG6ViewIsUnderChrome(reader, v)) continue;
        NSString *cn = NSStringFromClass([v class]);
        if ([cn containsString:@"TextRead"] || [cn containsString:@"Scroll"] ||
            [cn containsString:@"Page"] || [cn containsString:@"UILabel"] ||
            [cn containsString:@"UIButton"] || [cn containsString:@"UIImageView"] ||
            [cn containsString:@"UITextView"] || [cn containsString:@"WKWeb"] ||
            [cn containsString:@"TableView"] || [cn containsString:@"Collection"]) {
            continue;
        }
        CGRect inRoot = [v convertRect:v.bounds toView:vc.view];
        // 黑块常贴在进度条正上方：允许落到 chromeTop 之上的带状区
        CGFloat bandBottom = (chromeTop < content.size.height)
            ? chromeTop - 2.0
            : content.size.height * 0.72;
        CGFloat midY = CGRectGetMidY(inRoot);
        BOOL midBand = (midY > content.size.height * 0.20 && midY < bandBottom);
        BOOL barShape = (inRoot.size.width >= content.size.width * 0.45 &&
                         inRoot.size.height >= 20 && inRoot.size.height <= 200);
        if (!(midBand && barShape)) continue;
        UIColor *bg = v.backgroundColor;
        CGFloat r = 1, g = 1, b = 1, a = 0;
        if (bg) [bg getRed:&r green:&g blue:&b alpha:&a];
        BOOL dark = (a > 0.35) && (r + g + b) / 3.0 < 0.35;
        if (!dark && a < 0.05) {
            @try {
                CGFloat br = 1, bg2 = 1, bb = 1, ba = 0;
                if (v.layer.backgroundColor) {
                    UIColor *lc = [UIColor colorWithCGColor:v.layer.backgroundColor];
                    [lc getRed:&br green:&bg2 blue:&bb alpha:&ba];
                    dark = (ba > 0.35) && (br + bg2 + bb) / 3.0 < 0.35;
                }
            } @catch (__unused NSException *e) {}
        }
        if (!dark) continue;
        v.hidden = YES;
        v.alpha = 0;
        v.userInteractionEnabled = NO;
        hiddenN++;
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"G6 hideBlackBlob class=%@ frame=%@",
                                 cn, NSStringFromCGRect(inRoot)]);
        if (hiddenN >= 6) break;
    }
}

static void LBG6BringToolbarToFront(id reader) {
    if (![reader isKindOfClass:[UIViewController class]]) return;
    UIViewController *vc = (UIViewController *)reader;
    if (!vc.isViewLoaded || !vc.view) return;
    LBG6HideMisplacedSidePanels(reader);
    id bottom = LBG6ToolbarIvar(reader, @"toolBarBottom");
    if ([bottom isKindOfClass:[UIView class]]) {
        LBG6ForceToolbarButtonContrast((UIView *)bottom);
        UIView *bv = (UIView *)bottom;
        CGRect winF = [bv convertRect:bv.bounds toView:nil];
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"G6 bottomWin=%@ sub=%lu (noReposition)",
                                 NSStringFromCGRect(winF), (unsigned long)bv.subviews.count]);
    }
    NSMutableString *rootDump = [NSMutableString stringWithString:@"G6 rootSubs"];
    NSUInteger lim = MIN(vc.view.subviews.count, (NSUInteger)14);
    for (NSUInteger i = 0; i < lim; i++) {
        UIView *ch = vc.view.subviews[i];
        [rootDump appendFormat:@" [%lu]%@ f=%@ h=%d a=%.2f",
         (unsigned long)i, NSStringFromClass([ch class]),
         NSStringFromCGRect(ch.frame), ch.hidden ? 1 : 0, ch.alpha];
    }
    LBAppendOpenReaderTrace(rootDump);
    // 正文容器近底子视图
    if (vc.view.subviews.count > 0) {
        UIView *cr = vc.view.subviews[0];
        NSMutableString *cd = [NSMutableString stringWithFormat:
                               @"G6 contentNearBottom n=%lu", (unsigned long)cr.subviews.count];
        NSUInteger shown = 0;
        for (UIView *ch in cr.subviews.reverseObjectEnumerator) {
            CGRect f = ch.frame;
            if (f.origin.y + f.size.height < 500) continue;
            [cd appendFormat:@" [%@ f=%@ h=%d a=%.2f bg=%d]",
             NSStringFromClass([ch class]), NSStringFromCGRect(f),
             ch.hidden ? 1 : 0, ch.alpha, ch.backgroundColor ? 1 : 0];
            if (++shown >= 10) break;
        }
        LBAppendOpenReaderTrace(cd);
    }
    LBAppendOpenReaderTrace(@"G6 bringToolbarFront light");
    // Wave0 听书条必须压在正文层之上，否则会出现「听书字下面透出正文」
    UIView *wave0 = [vc.view viewWithTag:0x4C425730];
    if (wave0 && !wave0.hidden) {
        [vc.view bringSubviewToFront:wave0];
    }
    if ([bottom isKindOfClass:[UIView class]] && !((UIView *)bottom).hidden) {
        [vc.view bringSubviewToFront:(UIView *)bottom];
    }
}

static char kLBG6Wave0BookUrlKey;
static char kLBG6Wave0SourceUrlKey;
static char kLBG6Wave0ChapterUrlKey;
static char kLBG6Wave0TitleKey;

@interface LBG6Wave0ActionProxy : NSObject
@end
@implementation LBG6Wave0ActionProxy
- (void)onReview:(UIButton *)sender {
    NSString *bu = objc_getAssociatedObject(sender, &kLBG6Wave0BookUrlKey);
    NSString *su = objc_getAssociatedObject(sender, &kLBG6Wave0SourceUrlKey);
    if (bu.length == 0) return;
    Class coreClass = NSClassFromString(@"LegadoBridge.LegadoBridgeCore");
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id core = coreClass ? [coreClass performSelector:@selector(shared)] : nil;
#pragma clang diagnostic pop
    if (core && [core respondsToSelector:@selector(presentReviewsForBookUrl:sourceUrl:)]) {
        ((void (*)(id, SEL, NSString *, NSString *))objc_msgSend)(
            core, @selector(presentReviewsForBookUrl:sourceUrl:), bu, su
        );
    }
}
- (void)onTTS:(UIButton *)sender {
    NSString *bu = objc_getAssociatedObject(sender, &kLBG6Wave0BookUrlKey);
    NSString *cu = objc_getAssociatedObject(sender, &kLBG6Wave0ChapterUrlKey) ?: @"";
    NSString *ti = objc_getAssociatedObject(sender, &kLBG6Wave0TitleKey) ?: @"章节";
    if (bu.length == 0) return;
    Class coreClass = NSClassFromString(@"LegadoBridge.LegadoBridgeCore");
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id core = coreClass ? [coreClass performSelector:@selector(shared)] : nil;
#pragma clang diagnostic pop
    if (core && [core respondsToSelector:@selector(openTTSForBookUrl:chapterUrl:chapterTitle:speakText:ttsURLTemplate:)]) {
        ((void (*)(id, SEL, NSString *, NSString *, NSString *, NSString *, NSString *))objc_msgSend)(
            core,
            @selector(openTTSForBookUrl:chapterUrl:chapterTitle:speakText:ttsURLTemplate:),
            bu, cu, ti, nil, nil
        );
    } else {
        LBOpenTTS(bu, cu, ti);
    }
}
@end

/// Wave0：Legado 阅读壳在底栏上方挂独立条「听书/书评」，不叠进换源图标
static void LBG6AttachLegadoWave0Actions(id reader) {
    if (!reader || ![reader isKindOfClass:[UIViewController class]]) return;
    if (sLegadoReaderMode != 1) return;
    UIViewController *vc = (UIViewController *)reader;
    if (!vc.isViewLoaded || !vc.view) return;
    id dic = nil;
    @try { dic = [reader valueForKey:@"dicBook"]; } @catch (__unused NSException *e) {}
    if (![dic isKindOfClass:[NSDictionary class]]) dic = sPendingNativeFullBook;
    if (![dic isKindOfClass:[NSDictionary class]]) return;
    if (!(dic[@"legadoBridge"] || dic[@"fromLegadoBridge"])) return;

    id bottomObj = LBG6ToolbarIvar(reader, @"toolBarBottom");
    UIView *bottom = [bottomObj isKindOfClass:[UIView class]] ? (UIView *)bottomObj : nil;
    if (!bottom || !bottom.superview) return;
    // 清掉旧版挂在底栏图标行上的按钮（叠换源）+ 挂在 bottom 内的旧条
    for (UIView *sub in [bottom.subviews copy]) {
        if (sub.tag == 0x4C425730 || sub.tag == 0x4C425732 || sub.tag == 0x4C425733) {
            [sub removeFromSuperview];
        }
    }

    UIView *host = vc.view;
    const CGFloat stripH = 36.0;
    // 用 bottom 在 host 中的真实坐标，避免 frame 坐标系不一致
    CGRect bf = [bottom convertRect:bottom.bounds toView:host];
    if (bf.size.width < 2 || bf.size.height < 2) {
        bf = CGRectMake(0, host.bounds.size.height - 56, host.bounds.size.width, 56);
    }
    CGRect stripFrame = CGRectMake(0, MAX(0, CGRectGetMinY(bf) - stripH), host.bounds.size.width, stripH);

    UIView *strip = [host viewWithTag:0x4C425730];
    if (strip && [strip viewWithTag:0x4C425732]) {
        strip.frame = stripFrame;
        strip.hidden = bottom.hidden || bottom.alpha < 0.05;
        if (!strip.hidden) {
            [host bringSubviewToFront:strip];
            [host bringSubviewToFront:bottom];
        }
        return;
    }
    if (strip) [strip removeFromSuperview];

    NSString *bookUrl = nil;
    for (NSString *k in @[@"bookUrl", @"url", @"href"]) {
        id v = dic[k];
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) {
            bookUrl = v;
            break;
        }
    }
    if (bookUrl.length == 0) return;
    NSString *sourceUrl = nil;
    id sv = dic[@"sourceUrl"];
    if ([sv isKindOfClass:[NSString class]]) sourceUrl = sv;
    NSString *chapterUrl = nil;
    for (NSString *k in @[@"chapterUrl", @"curChapterUrl", @"cpUrl"]) {
        id v = dic[k];
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) {
            chapterUrl = v;
            break;
        }
    }
    NSString *title = nil;
    for (NSString *k in @[@"cpTitle", @"chapterTitle", @"title", @"name"]) {
        id v = dic[k];
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) {
            title = v;
            break;
        }
    }
    if ([title containsString:@"ç¬¬"] || [title containsString:@"Ã"]) title = @"章节";

    static LBG6Wave0ActionProxy *sWave0Proxy;
    static dispatch_once_t onceProxy;
    dispatch_once(&onceProxy, ^{ sWave0Proxy = [[LBG6Wave0ActionProxy alloc] init]; });

    strip = [[UIView alloc] initWithFrame:stripFrame];
    strip.tag = 0x4C425730;
    strip.accessibilityIdentifier = @"legado_wave0_strip";
    strip.backgroundColor = [UIColor colorWithWhite:0.16 alpha:1]; // 不透明，挡住正文
    strip.translatesAutoresizingMaskIntoConstraints = YES;
    strip.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    [host addSubview:strip];

    UIButton *(^makeBtn)(NSString *, NSInteger) = ^UIButton *(NSString *text, NSInteger tag) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.tag = tag;
        [b setTitle:text forState:UIControlStateNormal];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        b.translatesAutoresizingMaskIntoConstraints = YES;
        b.backgroundColor = [UIColor clearColor];
        return b;
    };
    UIButton *reviewBtn = makeBtn(@"书评", 0x4C425732);
    reviewBtn.accessibilityLabel = @"书评";
    reviewBtn.accessibilityIdentifier = @"legado_wave0_review";
    [strip addSubview:reviewBtn];
    // B7：隐藏听书/HttpTTS 入口（保留 LBOpenTTS C API，不在阅读壳露按钮）
    CGFloat btnW = 52, btnH = stripH;
    CGFloat sw = stripFrame.size.width;
    reviewBtn.frame = CGRectMake(sw - 16 - btnW, 0, btnW, btnH);
    reviewBtn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleHeight;

    NSString *bookCopy = [bookUrl copy];
    NSString *srcCopy = sourceUrl.length > 0 ? [sourceUrl copy] : nil;
    NSString *chCopy = chapterUrl.length > 0 ? [chapterUrl copy] : @"";
    NSString *titleCopy = title.length > 0 ? [title copy] : @"章节";
    objc_setAssociatedObject(reviewBtn, &kLBG6Wave0BookUrlKey, bookCopy, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(reviewBtn, &kLBG6Wave0SourceUrlKey, srcCopy, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(reviewBtn, &kLBG6Wave0ChapterUrlKey, chCopy, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(reviewBtn, &kLBG6Wave0TitleKey, titleCopy, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [reviewBtn addTarget:sWave0Proxy action:@selector(onReview:) forControlEvents:UIControlEventTouchUpInside];

    strip.hidden = bottom.hidden || bottom.alpha < 0.05;
    [host bringSubviewToFront:strip];
    if (!bottom.hidden) [host bringSubviewToFront:bottom];

    [@"wave0 strip review-only ttsHidden=1\n"
        writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_b7_tts_hidden.txt"]
        atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    LBAppendOpenReaderTrace(@"G6 wave0 strip attached opaque above bottom (tts hidden)");
}

static void LBG6ChangeToolBarHook(id self, SEL _cmd) {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (sG6LastChangeToolBarTs > 0 && (now - sG6LastChangeToolBarTs) < 0.20) {
        LBAppendOpenReaderTrace(@"G6 changeToolBar debounce skip");
        return;
    }
    sG6LastChangeToolBarTs = now;
    LBAppendOpenReaderTrace(@"G6 changeToolBar enter");
    if (LBOrig_changeToolBar) {
        LBOrig_changeToolBar(self, _cmd);
    }
    // 仅在显示态前置；隐藏态不强拉，避免挡住正文
    id hidden = LBG6ToolbarIvar(self, @"toolBarHidden");
    BOOL isHidden = YES;
    @try {
        if ([hidden respondsToSelector:@selector(boolValue)]) isHidden = [hidden boolValue];
        else if (hidden) isHidden = NO;
    } @catch (__unused NSException *e) {}
    if (!isHidden) {
        LBG6BringToolbarToFront(self);
        LBG6AttachLegadoWave0Actions(self);
        __weak id weakSelf = self;
        // 原生动画会在 hook 后把 pageSlider alpha 拉回，多拍几次强制藏
        for (NSNumber *sec in @[ @0.15, @0.35, @0.60, @0.90 ]) {
            double delay = sec.doubleValue;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                id strong = weakSelf;
                if (!strong || sLegadoReaderMode != 1) return;
                LBG6SanitizePageSliderOverflow(strong);
                LBG6AttachLegadoWave0Actions(strong);
            });
        }
    } else {
        LBG6HideMisplacedSidePanels(self);
    }
    LBG6LogToolbarState(self, @"afterChangeToolBar");
}

static void LBG6InstallMidTapToggle(id reader) {
    if (!reader || ![reader isKindOfClass:[UIViewController class]]) return;
    UIViewController *vc = (UIViewController *)reader;
    if (!vc.isViewLoaded || !vc.view) return;
    if (objc_getAssociatedObject(reader, &kLBG6MidTapInstalledKey)) return;
    LBG6MidTapProxy *proxy = [[LBG6MidTapProxy alloc] init];
    proxy.reader = reader;

    NSMutableArray<UIView *> *hosts = [NSMutableArray arrayWithObject:vc.view];
    @try {
        id pageB = nil;
        @try { pageB = [reader valueForKey:@"pageContainerB"]; } @catch (__unused NSException *e) {}
        if (!pageB) {
            @try { pageB = [reader valueForKey:@"_pageContainerB"]; } @catch (__unused NSException *e2) {}
        }
        if ([pageB isKindOfClass:[UIViewController class]] && ((UIViewController *)pageB).isViewLoaded) {
            UIView *pv = ((UIViewController *)pageB).view;
            if (pv) [hosts addObject:pv];
        } else if ([pageB isKindOfClass:[UIView class]]) {
            [hosts addObject:(UIView *)pageB];
        }
        for (UIView *sub in vc.view.subviews) {
            NSString *cn = NSStringFromClass([sub class]);
            if ([cn containsString:@"Scroll"] || [cn containsString:@"Page"] || [cn containsString:@"Read"]) {
                [hosts addObject:sub];
            }
        }
    } @catch (__unused NSException *e) {}

    NSInteger added = 0;
    for (UIView *host in hosts) {
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:proxy
                                                                              action:@selector(onMidTap:)];
        tap.cancelsTouchesInView = NO;
        tap.numberOfTapsRequired = 1;
        tap.delegate = proxy;
        [host addGestureRecognizer:tap];
        added++;
    }
    objc_setAssociatedObject(reader, &kLBG6MidTapProxyKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(reader, &kLBG6MidTapInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    LBAppendOpenReaderTrace([NSString stringWithFormat:@"G6 midTap gesture installed hosts=%ld", (long)added]);
}

static id LBG6ToolBarCreatorShared(void) {
    Class cls = NSClassFromString(@"ToolBarCreator");
    if (!cls) return nil;
    SEL sharedSel = @selector(sharedInstance);
    if ([(id)cls respondsToSelector:sharedSel]) {
        return ((id (*)(id, SEL))objc_msgSend)(cls, sharedSel);
    }
    return [[cls alloc] init];
}

static void LBG6AttachToolbarView(id reader, id bar, NSString *ivarKey) {
    if (!reader || !bar || ivarKey.length == 0) return;
    @try { [reader setValue:bar forKey:ivarKey]; } @catch (__unused NSException *e) {}
    // 禁止手工 addSubview：createToolbar / ToolBarCreator 自己挂树。
    // 曾把未布局的 bar 塞进 host → 正文区黑块、双顶栏，破坏香色原生 chrome。
}

/// 原生阅读壳：藏宿主 UINavigationBar，只留 TextRead 自带 toolBarHeader/Bottom（中点 changeToolBar）。
static void LBNativeReaderHideHostNavBar(id readerVC, BOOL hide) {
    if (![readerVC isKindOfClass:[UIViewController class]]) return;
    UIViewController *vc = (UIViewController *)readerVC;
    UINavigationController *nav = vc.navigationController;
    if (!nav) return;
    @try {
        if (hide) {
            if (!nav.isNavigationBarHidden) {
                [nav setNavigationBarHidden:YES animated:NO];
                LBAppendOpenReaderTrace(@"nativeChrome hideNavBar");
            }
            vc.title = nil;
            vc.navigationItem.title = nil;
            vc.navigationItem.leftBarButtonItem = nil;
            vc.navigationItem.rightBarButtonItem = nil;
            vc.navigationItem.hidesBackButton = YES;
        } else if (nav.isNavigationBarHidden) {
            [nav setNavigationBarHidden:NO animated:YES];
            LBAppendOpenReaderTrace(@"nativeChrome restoreNavBar");
        }
    } @catch (__unused NSException *e) {}
}

/// 去掉桥接调试叠层（tag=92011/92001），避免盖住原生正文叠字。
/// 注意：不拆 0x4C425730 听书条（那是 Wave0 产品入口）。
static void LBNativeReaderStripBridgeOverlays(id readerVC) {
    if (![readerVC isKindOfClass:[UIViewController class]]) return;
    UIViewController *vc = (UIViewController *)readerVC;
    if (!vc.isViewLoaded || !vc.view) return;
    @try {
        NSInteger removed = 0;
        for (NSNumber *tagNum in @[ @92011, @92001 ]) {
            NSInteger tag = tagNum.integerValue;
            UIView *ov = [vc.view viewWithTag:tag];
            while (ov) {
                [ov removeFromSuperview];
                removed++;
                ov = [vc.view viewWithTag:tag];
            }
        }
        // 深搜：误挂在 content 容器里的同 tag / identifier
        NSMutableArray *stack = [NSMutableArray arrayWithObject:vc.view];
        while (stack.count) {
            UIView *v = stack.lastObject;
            [stack removeLastObject];
            for (UIView *sub in [v.subviews copy]) {
                BOOL kill = (sub.tag == 92011 || sub.tag == 92001);
                if (!kill) {
                    NSString *aid = sub.accessibilityIdentifier ?: @"";
                    kill = [aid isEqualToString:@"legado_bridge_overlay92011"] ||
                           [aid hasPrefix:@"legado_bridge_overlay"];
                }
                if (kill) {
                    [sub removeFromSuperview];
                    removed++;
                    continue;
                }
                [stack addObject:sub];
            }
        }
        if (removed > 0) {
            LBAppendOpenReaderTrace([NSString stringWithFormat:
                                     @"nativeChrome strip overlays n=%ld", (long)removed]);
        }
    } @catch (__unused NSException *e) {}
}

/// 大脑已批：nativeRead 阅读页唤出底栏。createToolbar 后若 toolBarBottom 仍 nil，
/// 经 ToolBarCreator.sharedInstance createBottom:/createHeader:sourceType: 补建（实例方法，非类方法）。
static BOOL LBG6EnsureReaderToolbar(id reader, NSString *reason) {
    if (!reader) return NO;
    @try {
        SEL createSel = NSSelectorFromString(@"createToolbar");
        SEL hideSel = NSSelectorFromString(@"hideToolBar");
        if ([reader respondsToSelector:createSel]) {
            ((void (*)(id, SEL))objc_msgSend)(reader, createSel);
            LBAppendOpenReaderTrace([NSString stringWithFormat:@"G6 createToolbar OK via=%@", reason ?: @"?"]);
        } else {
            LBAppendOpenReaderTrace(@"G6 createToolbar miss selector");
        }
        LBG6LogToolbarState(reader, [NSString stringWithFormat:@"afterCreate(%@)", reason ?: @"?"]);

        id bottom = LBG6ToolbarIvar(reader, @"toolBarBottom");
        id header = LBG6ToolbarIvar(reader, @"toolBarHeader");
        if (!bottom || !header) {
            id creator = LBG6ToolBarCreatorShared();
            if (!creator) {
                LBAppendOpenReaderTrace(@"G6 ToolBarCreator miss");
            } else {
                if (!bottom) {
                    SEL bottomSel = NSSelectorFromString(@"createBottom:");
                    if ([creator respondsToSelector:bottomSel]) {
                        id bar = ((id (*)(id, SEL, id))objc_msgSend)(creator, bottomSel, reader);
                        LBG6AttachToolbarView(reader, bar, @"toolBarBottom");
                        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                                 @"G6 ToolBarCreator createBottom: -> %@",
                                                 bar ? NSStringFromClass([bar class]) : @"nil"]);
                    }
                }
                if (!header) {
                    SEL headerSel = NSSelectorFromString(@"createHeader:sourceType:");
                    if ([creator respondsToSelector:headerSel]) {
                        id srcType = nil;
                        @try {
                            id dic = [reader valueForKey:@"dicBook"];
                            if (![dic isKindOfClass:[NSDictionary class]]) dic = sPendingNativeFullBook;
                            if ([dic isKindOfClass:[NSDictionary class]]) {
                                srcType = dic[@"sourceType"] ?: dic[@"type"];
                            }
                        } @catch (__unused NSException *e) {}
                        if (!srcType) srcType = @"文本/小说";
                        id bar = ((id (*)(id, SEL, id, id))objc_msgSend)(creator, headerSel, reader, srcType);
                        LBG6AttachToolbarView(reader, bar, @"toolBarHeader");
                        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                                 @"G6 ToolBarCreator createHeader: -> %@",
                                                 bar ? NSStringFromClass([bar class]) : @"nil"]);
                    }
                }
            }
            LBG6LogToolbarState(reader, [NSString stringWithFormat:@"afterCreator(%@)", reason ?: @"?"]);
        }

        if ([reader respondsToSelector:hideSel]) {
            ((void (*)(id, SEL))objc_msgSend)(reader, hideSel);
        }
        return LBG6ToolbarIvar(reader, @"toolBarBottom") != nil;
    } @catch (NSException *ex) {
        LBAppendOpenReaderTrace([NSString stringWithFormat:@"G6 ensure EX %@", ex.reason ?: @""]);
        return NO;
    }
}

static void LBG6ScheduleToolbarRetry(id reader) {
    if (!reader) return;
    __weak id weakReader = reader;
    NSArray<NSNumber *> *delays = @[ @0.8, @2.0 ];
    for (NSNumber *sec in delays) {
        double delay = sec.doubleValue;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            id strong = weakReader;
            if (!strong || sLegadoReaderMode != 1) return;
            if (LBG6ToolbarIvar(strong, @"toolBarBottom")) {
                LBG6LogToolbarState(strong, [NSString stringWithFormat:@"retrySkip_t%.1f", delay]);
                return;
            }
            BOOL ok = LBG6EnsureReaderToolbar(strong, [NSString stringWithFormat:@"retry_t%.1f", delay]);
            LBAppendOpenReaderTrace([NSString stringWithFormat:@"G6 retry_t%.1f ok=%d", delay, ok ? 1 : 0]);
        });
    }
}

static void LBTextRead_viewDidAppear_Safe(id self, SEL _cmd, BOOL animated) {
    if (sTRViewDidAppearDepth > 0) {
        LBAppendOpenReaderTrace(@"TR viewDidAppear reenter-skip");
        struct objc_super sup = { self, [UIViewController class] };
        ((void (*)(struct objc_super *, SEL, BOOL))objc_msgSendSuper)(&sup, _cmd, animated);
        return;
    }
    sTRViewDidAppearDepth++;
    @try {
    BOOL isLegadoReader = NO;
    id dicProbe = nil;
    @try { dicProbe = [self valueForKey:@"dicBook"]; } @catch (__unused NSException *e) {}
    if (![dicProbe isKindOfClass:[NSDictionary class]]) dicProbe = sPendingNativeFullBook;
    if ([dicProbe isKindOfClass:[NSDictionary class]] &&
        (dicProbe[@"legadoBridge"] || dicProbe[@"fromLegadoBridge"])) {
        isLegadoReader = YES;
    }
    if (isLegadoReader && (sLegadoReaderMode == 2 || sLegadoSafeTextReadShell)) {
        struct objc_super sup = { self, [UIViewController class] };
        ((void (*)(struct objc_super *, SEL, BOOL))objc_msgSendSuper)(&sup, _cmd, animated);
        LBInjectPendingContentIntoReader((UIViewController *)self, @"safeAppear");
        return;
    }
    if (isLegadoReader && sLegadoReaderMode == 1) {
        // 假设 E：仅一次 UIKit super，使父 VC appear 链就绪（willAppear 仍 noop）
        if (!sDidAppearUIKit) {
            struct objc_super sup = { self, [UIViewController class] };
            ((void (*)(struct objc_super *, SEL, BOOL))objc_msgSendSuper)(&sup, _cmd, animated);
            sDidAppearUIKit = YES;
            LBAppendOpenReaderTrace(@"hypothesis_E didAppear UIKitSuper_OK");
        } else {
            LBAppendOpenReaderTrace(@"hypothesis_E didAppear skip (already UIKitSuper)");
        }
        // G6：原版 ReadVCBase2.viewDidAppear = super → createToolbar → hideToolBar。
        // 27c1ed6 真机：createToolbar 已调且 trace OK，但中点仍无底栏 → 补探测/ToolBarCreator 回退 + 延迟重试。
        // 大脑已批：仅限 nativeRead 阅读页唤出底栏（createToolbar/hideToolBar/ToolBarCreator）。
        if (sG6ToolbarCreatedForReader != self) {
            sG6ToolbarCreatedForReader = self;
            (void)LBG6EnsureReaderToolbar(self, @"didAppear");
            // 无论首轮是否已有 bottom，挂 0.8/2.0s 探测：nil 才补建，已有则 skip
            LBG6ScheduleToolbarRetry(self);
            // b82 真机：bottom 非 nil 且 hide 后 hidden=1，但中点不触发 changeToolBar → 补中区手势
            LBG6InstallMidTapToggle(self);
        }
        // 原生壳验收：无系统导航栏、无 bridge overlay，只留香色 TextRead chrome
        LBNativeReaderHideHostNavBar(self, YES);
        LBNativeReaderStripBridgeOverlays(self);
        // 假设 J：UIKitSuper 门控后若仍有 pending（onReset 已跑完），补 flush
        if (sDidAppearUIKit && sHypothesisJPendingAddChild.count + sHypothesisJPendingInsertSubview.count > 0) {
            LBHypothesisJFlushDeferred(self);
        }
        return;
    }
    if (LBOrig_TR_viewDidAppear) LBOrig_TR_viewDidAppear(self, _cmd, animated);
    } @finally {
        sTRViewDidAppearDepth--;
    }
}

static void LBInstallSafeTextReadShellHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        LBInstallHypothesisHPageContainerHook();
        LBInstallHypothesisJHooks();
        Class base2 = NSClassFromString(@"ReadVCBase2");
        if (base2) {
            Method mChange = class_getInstanceMethod(base2, NSSelectorFromString(@"changeToolBar"));
            if (mChange && !LBOrig_changeToolBar) {
                LBOrig_changeToolBar = (void (*)(id, SEL))method_getImplementation(mChange);
                method_setImplementation(mChange, (IMP)LBG6ChangeToolBarHook);
                LBAppendOpenReaderTrace(@"G6 changeToolBar hooked on ReadVCBase2");
            }
        }
        for (NSString *cn in @[@"TextReadVC3", @"TextReadVC2", @"TextReadVC1"]) {
            Class cls = NSClassFromString(cn);
            if (!cls) continue;
            Method m1 = class_getInstanceMethod(cls, @selector(viewDidLoad));
            if (m1 && !LBOrig_TR_viewDidLoad) {
                IMP trueOrig = LBResolveHookOrigIMP(cls, @selector(viewDidLoad));
                LBOrig_TR_viewDidLoad = (void (*)(id, SEL))trueOrig;
                method_setImplementation(m1, (IMP)LBTextRead_viewDidLoad_Safe);
            }
            Method m2 = class_getInstanceMethod(cls, @selector(viewWillAppear:));
            if (m2 && !LBOrig_TR_viewWillAppear) {
                IMP trueOrig = LBResolveHookOrigIMP(cls, @selector(viewWillAppear:));
                LBOrig_TR_viewWillAppear = (void (*)(id, SEL, BOOL))trueOrig;
                method_setImplementation(m2, (IMP)LBTextRead_viewWillAppear_Safe);
            }
            Method m3 = class_getInstanceMethod(cls, @selector(viewDidAppear:));
            if (m3 && !LBOrig_TR_viewDidAppear) {
                IMP trueOrig = LBResolveHookOrigIMP(cls, @selector(viewDidAppear:));
                LBOrig_TR_viewDidAppear = (void (*)(id, SEL, BOOL))trueOrig;
                method_setImplementation(m3, (IMP)LBTextRead_viewDidAppear_Safe);
            }
            LBAppendOpenReaderTrace([NSString stringWithFormat:@"textReadHooks hooked %@", cn]);
            break;
        }
    });
}

/// 导航栈辅助：找目录页 nav 或前台 nav
static UINavigationController *LBFindReaderHostNav(void) {
    UINavigationController *nav = nil;
    for (UIViewController *c in LBFindCatalogVCs()) {
        NSString *cn = NSStringFromClass([c class]);
        if ([cn containsString:@"LBLegadoCatalogListVC"] && c.navigationController) {
            return c.navigationController;
        }
    }
    for (UIViewController *c in LBFindCatalogVCs()) {
        if (c.navigationController) return c.navigationController;
    }
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
                    return n;
                }
            }
            if (cur.navigationController && LBVCIsVisibleInWindow(cur)) {
                return cur.navigationController;
            }
            for (UIViewController *ch in cur.childViewControllers) [stack addObject:ch];
            if (cur.presentedViewController) [stack addObject:cur.presentedViewController];
        }
        if (nav) break;
    }
    return nav;
}

static BOOL LBPushTextReaderNativeFull(NSDictionary *book, NSString *sourceName, NSString **outMsg) {
    // 假设 B2：push 入口最早 seed，先于 hooks/alloc/loadViewIfNeeded
    sHypothesisB2LoggedFirstContainer = NO;
    sDidAppearUIKit = NO;
    sG6ToolbarCreatedForReader = nil;
    LBHypothesisJResetPending();
    LBSeedTurnPageTypeScrollBranch();
    NSTimeInterval nowPush = CFAbsoluteTimeGetCurrent();
    if (LBNavStackHasTextReader()) {
        LBAppendOpenReaderTrace(@"pushNativeFull skip duplicate onStack");
        LBDeliverContentToVisibleReaders(@"pushDedup");
        if (outMsg) *outMsg = @"pushNativeFull dedup onStack";
        return YES;
    }
    if (sLastPushNativeFullTs > 0 && (nowPush - sLastPushNativeFullTs) < 8.0) {
        LBAppendOpenReaderTrace(@"pushNativeFull skip recent push");
        LBDeliverContentToVisibleReaders(@"pushDedupRecent");
        if (outMsg) *outMsg = @"pushNativeFull dedup recent";
        return YES;
    }
    LBInstallSafeTextReadShellHooks();
    LBInstallNativeResetContentHook();
    sLegadoReaderMode = 1;
    sLegadoSafeTextReadShell = NO;
    Class cls = NSClassFromString(@"TextReadVC3");
    if (!cls) cls = NSClassFromString(@"TextReadVC2");
    if (!cls) cls = NSClassFromString(@"TextReadVC1");
    if (!cls) {
        if (outMsg) *outMsg = @"pushNativeFull miss: no TextReadVC class";
        return NO;
    }
    id vc = nil;
    @try { vc = [[cls alloc] init]; } @catch (__unused NSException *e) { vc = nil; }
    if (!vc) {
        if (outMsg) *outMsg = @"pushNativeFull miss: alloc init failed";
        return NO;
    }
    LBLogHypothesisB2ContainerProbe(vc, @"after_alloc");
    NSMutableDictionary *dic = [NSMutableDictionary dictionaryWithDictionary:book ?: @{}];
    if (sourceName.length > 0) {
        dic[@"sourceName"] = sourceName;
        dic[@"bookSourceName"] = sourceName;
        dic[@"querySourceName"] = sourceName;
    }
    LBSanitizeBookDictForReaderEx(dic, YES, YES);
    sPendingNativeFullBook = [dic mutableCopy];
    LBReadingRememberBook(dic);
    // push 前先 prep + 强制 loadView，确保 viewDidLoad 在 mode=1 下执行
    LBPrepareTextReadNativeFull(vc, dic);
    LBLogHypothesisB2ContainerProbe(vc, @"after_prep");
    LBAppendOpenReaderTrace([NSString stringWithFormat:@"pushNativeFull %@ keys=%lu",
                             NSStringFromClass(cls), (unsigned long)dic.count]);
    @try {
        LBLogHypothesisB2ContainerProbe(vc, @"before_loadView");
        // 同步触发 viewDidLoad（animated push 前），避免 go() 过早改 mode
        [(UIViewController *)vc loadViewIfNeeded];
        LBLogHypothesisB2ContainerProbe(vc, @"after_loadView");
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"pushNativeFull loadViewIfNeeded done mode=%d loaded=%d",
                                 sLegadoReaderMode,
                                 ((UIViewController *)vc).isViewLoaded ? 1 : 0]);
        // 假设 T：禁止在 push 前 postCurCp/invoke；正文投递挪到 push 之后
        LBAppendOpenReaderTrace(@"hypothesis_T defer_postCurCp_until_pushed");
    } @catch (NSException *ex) {
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"pushNativeFull loadView EX %@", ex.reason ?: @""]);
        // loadView 异常：本路径失败，交 go() 兜底
        if (outMsg) *outMsg = [NSString stringWithFormat:@"pushNativeFull loadView fail: %@",
                                ex.reason ?: @""];
        return NO;
    }
    if (sLegadoReaderMode != 1) {
        // viewDidLoad 内已降级 safeShell
        LBAppendOpenReaderTrace(@"pushNativeFull mode downgraded during loadView");
    }
    id vcRef = vc;
    void (^afterPush)(void) = ^{
        // 假设 R2：禁用 DeliverContent —— 真机 0.4s 投递会走 contentInject fallback 并回桌面
        LBAppendOpenReaderTrace(@"hypothesis_R2 afterPush_skip_deliver");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            BOOL vis = LBIsTextReaderVisible();
            LBAppendOpenReaderTrace([NSString stringWithFormat:
                                    @"pushNativeFull settle vis=%d mode=%d",
                                    vis ? 1 : 0, sLegadoReaderMode]);
            // F2/acceptance：阅读页已可见则清磁盘 open_once（内存占坑仍挡二次 push）
            if (vis && LBReadNativeOpenOnceMarker().length > 0) {
                LBClearNativeOpenOnceMarker();
                LBAppendOpenReaderTrace(@"nativeOpen diskOpenOnce cleared after pushSettle");
            }
            (void)vcRef;
        });
    };
    UINavigationController *nav = LBFindReaderHostNav();
    if (nav) {
        @try {
            LBWriteOpenReaderMarker([NSString stringWithFormat:@"nativeOpen pushingNative %@ on %@",
                                     NSStringFromClass(cls), NSStringFromClass([nav class])]);
            // 推进去就藏系统栏：阅读页只要香色原生 toolBar，不要白底「返回」
            ((UIViewController *)vc).hidesBottomBarWhenPushed = YES;
            [nav setNavigationBarHidden:YES animated:YES];
            [nav pushViewController:(UIViewController *)vc animated:YES];
            sLastPushNativeFullTs = CFAbsoluteTimeGetCurrent();
            // 假设 R2：appear 链不调 super/ORIG；1.0s 后再 postCurCp，避开 push 动画窗口
            LBAppendOpenReaderTrace(@"hypothesis_R2 defer_postCurCp_delay_1s");
            id vcHold = vc;
            // 心跳：定位 0.35s 重启窗口
            for (NSNumber *sec in @[ @0.15, @0.25, @0.35, @0.45, @0.7, @1.0 ]) {
                double d = sec.doubleValue;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    LBAppendOpenReaderTrace([NSString stringWithFormat:
                                            @"hypothesis_R2 heartbeat_%.2fs vis=%d mode=%d",
                                            d,
                                            LBIsTextReaderVisible() ? 1 : 0,
                                            sLegadoReaderMode]);
                });
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (sPendingResetContent.count == 0) {
                    LBAppendOpenReaderTrace(@"hypothesis_R2 delayed_postCurCp_skip emptyPending");
                    return;
                }
                id body = sPendingResetContent[@"chapterContent"] ?: sPendingResetContent[@"content"];
                if (![body isKindOfClass:[NSString class]] || [(NSString *)body length] == 0) {
                    LBAppendOpenReaderTrace(@"hypothesis_R2 delayed_postCurCp_skip emptyBody");
                    return;
                }
                LBAppendOpenReaderTrace(@"hypothesis_R2 delayed_postCurCp_begin");
                LBLoadCurCpBridgeOnContentPosted(sPendingResetContent, vcHold);
                LBAppendOpenReaderTrace([NSString stringWithFormat:
                                         @"hypothesis_R2 delayed_postCurCp_done sm=%@",
                                         LBLoadCurCpBridgeStateName()]);
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), afterPush);
            if (outMsg) {
                *outMsg = [NSString stringWithFormat:@"pushNativeFull ok %@ on %@",
                           NSStringFromClass(cls), NSStringFromClass([nav class])];
            }
            return YES;
        } @catch (NSException *e) {
            if (outMsg) *outMsg = [NSString stringWithFormat:@"pushNativeFull fail: %@", e.reason ?: @""];
            LBAppendOpenReaderTrace([NSString stringWithFormat:@"pushNativeEx %@", e.reason ?: @""]);
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
        if (outMsg) *outMsg = @"pushNativeFull miss: no nav/host";
        return NO;
    }
    @try {
        UINavigationController *wrap =
            [[UINavigationController alloc] initWithRootViewController:(UIViewController *)vc];
        wrap.modalPresentationStyle = UIModalPresentationFullScreen;
        LBWriteOpenReaderMarker([NSString stringWithFormat:@"nativeOpen presentingNative %@ on %@",
                                 NSStringFromClass(cls), NSStringFromClass([host class])]);
        LBAppendOpenReaderTrace(@"hypothesis_R2 defer_postCurCp_delay_1s present");
        sLastPushNativeFullTs = CFAbsoluteTimeGetCurrent();
        id vcHold = vc;
        [host presentViewController:wrap animated:YES completion:^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (sPendingResetContent.count == 0) return;
                id body = sPendingResetContent[@"chapterContent"] ?: sPendingResetContent[@"content"];
                if (![body isKindOfClass:[NSString class]] || [(NSString *)body length] == 0) return;
                LBAppendOpenReaderTrace(@"hypothesis_R2 delayed_postCurCp_begin");
                LBLoadCurCpBridgeOnContentPosted(sPendingResetContent, vcHold);
                LBAppendOpenReaderTrace([NSString stringWithFormat:
                                         @"hypothesis_R2 delayed_postCurCp_done sm=%@",
                                         LBLoadCurCpBridgeStateName()]);
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), afterPush);
        }];
        if (outMsg) {
            *outMsg = [NSString stringWithFormat:@"presentNativeFull ok %@ on %@",
                       NSStringFromClass(cls), NSStringFromClass([host class])];
        }
        return YES;
    } @catch (NSException *e) {
        if (outMsg) *outMsg = [NSString stringWithFormat:@"presentNativeFull fail: %@", e.reason ?: @""];
        return NO;
    }
}

static BOOL LBPushTextReaderFallback(NSDictionary *book, NSString *sourceName, NSString **outMsg) {
    LBInstallSafeTextReadShellHooks();
    sLegadoReaderMode = 2;
    sLegadoSafeTextReadShell = YES;
    Class cls = NSClassFromString(@"TextReadVC3");
    if (!cls) cls = NSClassFromString(@"TextReadVC2");
    if (!cls) cls = NSClassFromString(@"TextReadVC1");
    if (!cls) cls = NSClassFromString(@"ReadVCBase1");
    if (!cls) {
        sLegadoSafeTextReadShell = NO;
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
        sLegadoSafeTextReadShell = NO;
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
                    LBWriteOpenReaderMarker(@"nativeOpen keepTextRead readerVis=1 via=safeShell");
                } else {
                    LBWriteOpenReaderMarker(@"nativeOpen pushDone readerVis=0");
                }
                LBAppendOpenReaderTrace([NSString stringWithFormat:
                                        @"pushReader settle vis=%d", vis ? 1 : 0]);
                sLegadoSafeTextReadShell = NO;
            });
        } @catch (NSException *e) {
            LBAppendOpenReaderTrace([NSString stringWithFormat:@"pushReader setDicEx %@", e.reason ?: @""]);
            LBWriteOpenReaderMarker([NSString stringWithFormat:@"nativeOpen pushSetDicEx %@",
                                     e.reason ?: @""]);
        }
    };
    UINavigationController *nav = LBFindReaderHostNav();
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

/// 假设 H：invoke_orig_OK 同栈窄补链（禁 setPageModel / TV ivar 拼补）
static UIView *LBSyncKickFindTextReadTV(id readerVC, id container) {
    NSMutableArray *roots = [NSMutableArray array];
    if ([readerVC isKindOfClass:[UIViewController class]]) {
        UIViewController *vc = (UIViewController *)readerVC;
        if (vc.isViewLoaded && vc.view) [roots addObject:vc.view];
    }
    if ([container isKindOfClass:[UIView class]]) {
        if (![roots containsObject:container]) [roots addObject:container];
    }
    for (id scope in @[readerVC ?: [NSNull null], container ?: [NSNull null]]) {
        if (scope == (id)[NSNull null]) continue;
        for (NSString *k in @[@"textViewL", @"textViewR", @"curPageTV", @"textView"]) {
            @try {
                id tv = [scope valueForKey:k];
                if (tv && [NSStringFromClass([tv class]) containsString:@"TextReadTV"]) {
                    return (UIView *)tv;
                }
            } @catch (__unused NSException *e) {}
        }
        @try {
            id cpv = [scope valueForKey:@"curPageVC"];
            if (cpv) {
                for (NSString *k in @[@"textViewL", @"textViewR", @"textView"]) {
                    @try {
                        id tv = [cpv valueForKey:k];
                        if (tv && [NSStringFromClass([tv class]) containsString:@"TextReadTV"]) {
                            return (UIView *)tv;
                        }
                    } @catch (__unused NSException *e) {}
                }
            }
        } @catch (__unused NSException *e) {}
    }
    while (roots.count > 0) {
        UIView *v = roots.lastObject;
        [roots removeLastObject];
        if ([NSStringFromClass([v class]) containsString:@"TextReadTV"]) return v;
        for (UIView *sub in v.subviews) [roots addObject:sub];
    }
    return nil;
}

static NSUInteger LBSyncKickPageModelCount(id host) {
    if (!host) return 0;
    @try {
        for (NSString *k in @[@"arrPageModels", @"pageModels", @"pages", @"arrPages",
                              @"pageList", @"arrRPM"]) {
            id arr = nil;
            @try { arr = [host valueForKey:k]; } @catch (__unused NSException *e) {}
            if ([arr isKindOfClass:[NSArray class]] && [(NSArray *)arr count] > 0) {
                return [(NSArray *)arr count];
            }
        }
        if (LBExtractPageModelFromHost(host, 0)) return 1;
    } @catch (__unused NSException *e) {}
    return 0;
}

/// 假设 I：queryFinish 后仅 pageModel>0 或 strict needle/CTFrame 才算上屏成功
static BOOL LBSyncKickHasStrictRenderEvidence(id container, id readerVC, UIView *textReadTV,
                                              NSUInteger *outPm) {
    NSUInteger pm = LBSyncKickPageModelCount(container);
    if ([readerVC isKindOfClass:[UIViewController class]]) {
        NSUInteger vcPm = LBSyncKickPageModelCount(readerVC);
        if (vcPm > pm) pm = vcPm;
    }
    if (outPm) *outPm = pm;
    if (pm > 0) return YES;
    if (!textReadTV) return NO;
    if (LBTextReadTVHasRenderedNeedle(textReadTV, @"萧炎") ||
        LBTextReadTVHasRenderedNeedle(textReadTV, @"斗气")) {
        return YES;
    }
    for (NSString *k in @[@"pageModel", @"curPageModel", @"_pageModel"]) {
        @try {
            id tvPm = [textReadTV valueForKey:k];
            if (tvPm && LBReadPageModelHasCTFrame(tvPm)) return YES;
        } @catch (__unused NSException *e) {}
    }
    return NO;
}

static int LBSyncKickNeedleFlag(UIView *textReadTV) {
    if (!textReadTV) return 0;
    if (LBTextReadTVHasRenderedNeedle(textReadTV, @"萧炎") ||
        LBTextReadTVHasRenderedNeedle(textReadTV, @"斗气")) {
        return 1;
    }
    return 0;
}

/// 假设 L：divisionResponse 后记录 pageModel/TV/needle（验原版链是否自然上屏）
static void LBSyncKickLogPostDR(NSString *phase, id container, id readerVC,
                                UIView *textReadTV) {
    NSUInteger pm = 0;
    (void)LBSyncKickHasStrictRenderEvidence(container, readerVC, textReadTV, &pm);
    int needle = LBSyncKickNeedleFlag(textReadTV);
    LBAppendOpenReaderTrace([NSString stringWithFormat:
                             @"division_kick_sync %@ postDR_pm=%lu postDR_tv=%d postDR_needle=%d",
                             phase ?: @"?", (unsigned long)pm, textReadTV ? 1 : 0, needle]);
}

static BOOL LBSyncKickInvokeOnDivisionTextFinish(id container, id pageResult, NSInteger cpIndex) {
    if (!container || !pageResult) return NO;
    SEL finish = NSSelectorFromString(@"onDivisionTextFinish:cpIndex:");
    Class tcls = object_getClass(container);
    if (![container respondsToSelector:finish] && !class_getInstanceMethod(tcls, finish)) {
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"division_kick_sync onFinish_MISS noSel host=%@",
                                 NSStringFromClass(tcls)]);
        return NO;
    }
    id finishArg = LBPrepareOnFinishArgFromDivisionText(pageResult);
    if (!finishArg) {
        LBAppendOpenReaderTrace(@"division_kick_sync onFinish_MISS argReject");
        return NO;
    }
    @try {
        ((void (*)(id, SEL, id, NSInteger))objc_msgSend)(container, finish, finishArg, cpIndex);
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"division_kick_sync onFinish_OK@%@ %@",
                                 NSStringFromClass(tcls), LBDescribeOnFinishArg(finishArg)]);
        return YES;
    } @catch (NSException *ex) {
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"division_kick_sync onFinish_MISS EX %@",
                                 ex.reason ?: @""]);
        return NO;
    }
}

void LBLoadCurCpBridgeKickDivisionSync(id container, id readerVC, NSDictionary *payload) {
    LBAppendOpenReaderTrace(@"division_kick_sync_begin");
    if (!container || ![payload isKindOfClass:[NSDictionary class]]) {
        LBAppendOpenReaderTrace(@"division_kick_sync skip noContainerOrPayload");
        return;
    }
    NSString *body = nil;
    id c = payload[@"chapterContent"] ?: payload[@"content"];
    if ([c isKindOfClass:[NSString class]]) body = (NSString *)c;
    if (body.length == 0) {
        LBAppendOpenReaderTrace(@"division_kick_sync skip noBody");
        return;
    }
    NSString *title = payload[@"cpTitle"] ?: payload[@"title"] ?: @"章节";
    title = LBSafeCpTitleString(title);
    if (title.length == 0) title = @"章节";
    NSInteger cpIndex = 0;
    id cpi = payload[@"cpIndex"] ?: payload[@"index"];
    if ([cpi respondsToSelector:@selector(integerValue)]) cpIndex = [cpi integerValue];
    if ([readerVC isKindOfClass:[UIViewController class]]) {
        @try {
            id cur = [(UIViewController *)readerVC valueForKey:@"curCpIndex"];
            if ([cur respondsToSelector:@selector(integerValue)]) cpIndex = [cur integerValue];
        } @catch (__unused NSException *e) {}
    }

    UIView *textReadTV = LBSyncKickFindTextReadTV(readerVC, container);
    CGSize tvSize = textReadTV ? textReadTV.bounds.size : CGSizeZero;
    if (tvSize.width < 10 || tvSize.height < 10) {
        if ([readerVC isKindOfClass:[UIViewController class]] &&
            ((UIViewController *)readerVC).isViewLoaded) {
            tvSize = ((UIViewController *)readerVC).view.bounds.size;
        }
        if (tvSize.width < 10 || tvSize.height < 10) {
            tvSize = UIScreen.mainScreen.bounds.size;
            tvSize.width -= 24;
            tvSize.height -= 160;
        }
    }

    NSMutableArray *okPaths = [NSMutableArray array];
    BOOL chainOk = NO;

    textReadTV = LBSyncKickFindTextReadTV(readerVC, container);
    NSUInteger pmPre = 0;
    if (LBSyncKickHasStrictRenderEvidence(container, readerVC, textReadTV, &pmPre)) {
        chainOk = YES;
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"division_kick_sync pre_hit pm=%lu tv=%d needle=%d",
                                 (unsigned long)pmPre, textReadTV ? 1 : 0,
                                 LBSyncKickNeedleFlag(textReadTV)]);
    }

    // 0) queryFinish 仅非空壳早退（空壳 TV 调原生 QF 会二次 divisionResponse → NSArrayM length）
    SEL qfSel = NSSelectorFromString(@"lpNetWorkDelegateQueryFinish:config:userInfo:");
    BOOL emptyShell = (textReadTV != nil && pmPre == 0 && LBSyncKickNeedleFlag(textReadTV) == 0);
    if (!chainOk && !emptyShell && [container respondsToSelector:qfSel]) {
        NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
        userInfo[@"content"] = body;
        userInfo[@"cpContent"] = body;
        userInfo[@"chapterContent"] = body;
        userInfo[@"cpIndex"] = @(cpIndex);
        userInfo[@"cpTitle"] = LBSafeCpTitleString(title);
        NSString *chUrl = payload[@"chapterUrl"] ?: payload[@"cpUrl"];
        if ([chUrl isKindOfClass:[NSString class]]) userInfo[@"chapterUrl"] = chUrl;
        NSDictionary *config = @{
            @"cpIndex": @(cpIndex),
            @"cpTitle": LBSafeCpTitleString(title),
            @"content": body,
        };
        NSDictionary *qfResponse = @{
            @"content": body,
            @"cpContent": body,
            @"chapterContent": body,
        };
        @try {
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(
                container, qfSel, qfResponse, config, userInfo);
            [okPaths addObject:@"queryFinish"];
            LBAppendOpenReaderTrace(@"division_kick_sync queryFinish_OK");
            textReadTV = LBSyncKickFindTextReadTV(readerVC, container);
            NSUInteger pm0 = 0;
            if (LBSyncKickHasStrictRenderEvidence(container, readerVC, textReadTV, &pm0)) {
                chainOk = YES;
                LBAppendOpenReaderTrace([NSString stringWithFormat:
                                         @"division_kick_sync queryFinish_hit pm=%lu tv=%d needle=%d",
                                         (unsigned long)pm0, textReadTV ? 1 : 0,
                                         LBSyncKickNeedleFlag(textReadTV)]);
            } else {
                LBAppendOpenReaderTrace([NSString stringWithFormat:
                                         @"division_force_continue pm=%lu tv=%d needle=%d",
                                         (unsigned long)pm0, textReadTV ? 1 : 0,
                                         LBSyncKickNeedleFlag(textReadTV)]);
            }
        } @catch (NSException *ex) {
            LBAppendOpenReaderTrace([NSString stringWithFormat:
                                     @"division_kick_sync queryFinish EX %@",
                                     ex.reason ?: @""]);
        }
    } else if (!chainOk && emptyShell) {
        LBAppendOpenReaderTrace(@"division_kick_sync queryFinish_skip emptyShell");
    }

    // 1) divisionText → divisionResponse（raw Attr 页，禁 wrapRPM / 禁显式 onFinish）
    if (!chainOk) {
        id paiban = nil;
        @try { paiban = [readerVC valueForKey:@"tr_paibanInfo"]; } @catch (__unused NSException *e) {}
        Class paibanMgrCls = NSClassFromString(@"PaibanManager");
        id pm = nil;
        if (paibanMgrCls) {
            for (NSString *ss in @[@"sharedInstance", @"shared", @"sharedManager"]) {
                SEL s = NSSelectorFromString(ss);
                if ([paibanMgrCls respondsToSelector:s]) {
                    pm = ((id (*)(id, SEL))objc_msgSend)(paibanMgrCls, s);
                    if (pm) break;
                }
            }
        }
        id pageResult = nil;
        if (pm) {
            pageResult = LBCallDivisionText(pm, NO, body, title, cpIndex, tvSize, paiban);
            if (pageResult) {
                [okPaths addObject:[NSString stringWithFormat:@"divisionText@%@",
                                    NSStringFromClass([pm class])]];
                LBAppendOpenReaderTrace(@"division_kick_sync divisionText_OK");
            }
        }
        if (!pageResult && paibanMgrCls) {
            pageResult = LBCallDivisionText(paibanMgrCls, YES, body, title, cpIndex, tvSize, paiban);
            if (pageResult) {
                [okPaths addObject:@"divisionText@PaibanManager"];
                LBAppendOpenReaderTrace(@"division_kick_sync divisionText_OK");
            }
        }
        if (!pageResult) {
            LBAppendOpenReaderTrace(@"division_kick_sync divisionText_MISS");
        }
        if (pageResult) {
            id divisionTextRaw = pageResult;
            NSArray *flatAttrPages = LBFlattenDivisionPages(pageResult);
            id drPages = flatAttrPages.count > 0 ? flatAttrPages : divisionTextRaw;
            LBAppendOpenReaderTrace([NSString stringWithFormat:
                                     @"division_kick_sync DR_arg=%@",
                                     LBDescribeOnFinishArg(drPages)]);
            NSMutableArray *heights = sLastDivisionHeights
                ? [sLastDivisionHeights mutableCopy]
                : [NSMutableArray array];
            NSString *safeTitle = LBSafeCpTitleString(title);
            if (LBInvokeDivisionResponse(container, drPages, safeTitle, cpIndex, heights, okPaths)) {
                LBAppendOpenReaderTrace(@"division_kick_sync divisionResponse_OK");
                textReadTV = LBSyncKickFindTextReadTV(readerVC, container);
                LBSyncKickLogPostDR(@"afterDR", container, readerVC, textReadTV);
                LBKickMarkDeliverBlock();
                LBAppendOpenReaderTrace(@"division_kick_sync explicit_onFinish_disabled");
                if (LBSyncKickHasStrictRenderEvidence(container, readerVC, textReadTV, NULL)) {
                    chainOk = YES;
                }
            } else {
                LBAppendOpenReaderTrace(@"division_kick_sync divisionResponse_MISS");
            }
        }
    }

    textReadTV = LBSyncKickFindTextReadTV(readerVC, container);
    NSUInteger pmCount = 0;
    (void)LBSyncKickHasStrictRenderEvidence(container, readerVC, textReadTV, &pmCount);
    int needleFlag = LBSyncKickNeedleFlag(textReadTV);
    LBAppendOpenReaderTrace([NSString stringWithFormat:
                             @"division_kick_sync_end paths=%@ tv=%d pm=%lu needle=%d",
                             [okPaths componentsJoinedByString:@","],
                             textReadTV ? 1 : 0, (unsigned long)pmCount, needleFlag]);

    if (textReadTV && (pmCount > 0 || needleFlag)) {
        LBLoadCurCpBridgeMarkRendered();
    }

    // 假设 I：kick 后 1.5s 写 forensics marker，避免 openOnce 二次深链弹走页后再 dump
    __weak id wContainer = container;
    __weak id wReaderVC = readerVC;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        id c = wContainer;
        id r = wReaderVC;
        if (!c) return;
        UIView *tv = LBSyncKickFindTextReadTV(r, c);
        NSUInteger pm = 0;
        (void)LBSyncKickHasStrictRenderEvidence(c, r, tv, &pm);
        LBWriteOpenReaderMarker([NSString stringWithFormat:
                                 @"division_kick_forensics pm=%lu tv=%d needle=%d",
                                 (unsigned long)pm, tv ? 1 : 0, LBSyncKickNeedleFlag(tv)]);
    });
}

void LBNoteResetContentPosted(NSDictionary *userInfo) {
    if (![userInfo isKindOfClass:[NSDictionary class]] || userInfo.count == 0) return;
    // 离线：网络错误通知不得冲掉已注入的 xsfolder 正文
    id errOnly = userInfo[@"error"];
    id bodyIn = userInfo[@"chapterContent"] ?: userInfo[@"content"];
    BOOL hasBodyIn = [bodyIn isKindOfClass:[NSString class]] && [(NSString *)bodyIn length] > 0;
    if ([errOnly isKindOfClass:[NSString class]] && [(NSString *)errOnly length] > 0 && !hasBodyIn) {
        id keep = sPendingResetContent[@"chapterContent"] ?: sPendingResetContent[@"content"];
        if ([keep isKindOfClass:[NSString class]] && [(NSString *)keep length] > 0) {
            LBAppendOpenReaderTrace(@"notePosted ignore error keep xsfolder body");
            return;
        }
    }
    NSMutableDictionary *enriched =
        [NSMutableDictionary dictionaryWithDictionary:LBSanitizeResetContentUserInfo(userInfo)];
    // 用 pending 目录补 cpTitle/cpIndex，供 contentInject 写 dicContents / divisionText
    NSString *chUrl = enriched[@"chapterUrl"] ?: enriched[@"cpUrl"] ?: @"";
    if (chUrl.length > 0 && sPendingCatalogChapters.count > 0) {
        NSInteger i = 0;
        for (id item in sPendingCatalogChapters) {
            if (![item isKindOfClass:[NSDictionary class]]) { i++; continue; }
            NSDictionary *d = (NSDictionary *)item;
            NSString *u = d[@"cpUrl"] ?: d[@"chapterUrl"] ?: d[@"url"] ?: @"";
            if ([u isKindOfClass:[NSString class]] && [u isEqualToString:chUrl]) {
                id t = d[@"cpTitle"] ?: d[@"title"] ?: d[@"name"] ?: d[@"chapterName"];
                if ([t isKindOfClass:[NSString class]] && [(NSString *)t length] > 0) {
                    if (![enriched[@"cpTitle"] isKindOfClass:[NSString class]] ||
                        [(NSString *)enriched[@"cpTitle"] length] == 0) {
                        enriched[@"cpTitle"] = t;
                        enriched[@"title"] = t;
                    }
                }
                id cpi = d[@"cpIndex"] ?: d[@"index"] ?: @(i);
                if (!enriched[@"cpIndex"]) enriched[@"cpIndex"] = cpi;
                break;
            }
            i++;
        }
    }
    if ([sPendingNativeFullBook isKindOfClass:[NSDictionary class]]) {
        for (NSString *k in @[@"bookKey", @"sourceName", @"bookUrl", @"name", @"author"]) {
            if (!enriched[k] && sPendingNativeFullBook[k]) {
                enriched[k] = sPendingNativeFullBook[k];
            }
        }
        if (!enriched[@"cpTitle"] && sPendingNativeFullBook[@"cpTitle"]) {
            enriched[@"cpTitle"] = sPendingNativeFullBook[@"cpTitle"];
            enriched[@"title"] = sPendingNativeFullBook[@"cpTitle"];
        }
        if (!enriched[@"cpIndex"] && sPendingNativeFullBook[@"cpIndex"]) {
            enriched[@"cpIndex"] = sPendingNativeFullBook[@"cpIndex"];
        }
    }
    sPendingResetContent = enriched;
    NSString *ch = sPendingResetContent[@"chapterUrl"] ?: @"";
    NSString *marker = [NSString stringWithFormat:@"pendingResetContent ch=%@ keys=%lu mode=%d",
                        ch, (unsigned long)sPendingResetContent.count, sLegadoReaderMode];
    [marker writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_content_pending.txt"]
             atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    UIViewController *visibleReader = LBFindVisibleTextReaderVC();
    LBLoadCurCpBridgeOnContentPosted(enriched, visibleReader);
    if (LBIsTextReaderVisible()) {
        if (sLegadoReaderMode == 1) {
            LBAppendOpenReaderTrace([NSString stringWithFormat:
                                     @"notePosted sm=%@ reader=%@",
                                     LBLoadCurCpBridgeStateName(),
                                     visibleReader ? NSStringFromClass([visibleReader class]) : @"-"]);
        } else {
            // safeShell：禁止 post ResetContent；UITextView 直灌
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
    if (LBIsTextReaderVisible()) {
        if (sLegadoReaderMode == 1) {
            LBDeliverContentToVisibleReaders(phase ?: @"flush");
        } else {
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
    NSString *cn = NSStringFromClass(cls);
    if ([cn containsString:@"BookShelf"]) return;
    static NSMutableSet *sHookedTargets = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ sHookedTargets = [NSMutableSet set]; });

    NSString *rowsKey = [@"rows:" stringByAppendingString:cn];
    if (![sHookedTargets containsObject:rowsKey]) {
        LBInstallHookOnClassOnly(cls, @selector(tableView:numberOfRowsInSection:),
                                 (IMP)LBHookedCatalogNumberOfRows, &sOrigCatalogNumberOfRows);
        if (!sTruePlainNumberOfRows && sOrigCatalogNumberOfRows &&
            sOrigCatalogNumberOfRows != (IMP)LBHookedCatalogNumberOfRows &&
            sOrigCatalogNumberOfRows != (IMP)LBHookedNumberOfRows) {
            sTruePlainNumberOfRows = sOrigCatalogNumberOfRows;
        }
        [sHookedTargets addObject:rowsKey];
    }
    NSString *cellKey = [@"cell:" stringByAppendingString:cn];
    if (![sHookedTargets containsObject:cellKey]) {
        LBInstallHookOnClassOnly(cls, @selector(tableView:cellForRowAtIndexPath:),
                                 (IMP)LBHookedCatalogCellForRow, &sOrigCatalogCellForRow);
        if (!sTruePlainCellForRow && sOrigCatalogCellForRow &&
            sOrigCatalogCellForRow != (IMP)LBHookedCatalogCellForRow &&
            sOrigCatalogCellForRow != (IMP)LBHookedCellForRow) {
            sTruePlainCellForRow = sOrigCatalogCellForRow;
        }
        [sHookedTargets addObject:cellKey];
    }
    SEL selSel = @selector(tableView:didSelectRowAtIndexPath:);
    NSString *selKey = [@"sel:" stringByAppendingString:cn];
    if (![sHookedTargets containsObject:selKey] && class_getInstanceMethod(cls, selSel)) {
        Method any = class_getInstanceMethod(cls, selSel);
        void (*prev)(id, SEL, UITableView *, NSIndexPath *) =
            (void (*)(id, SEL, UITableView *, NSIndexPath *))method_getImplementation(any);
        Class owner = LBClassOwningInstanceMethod(cls, selSel) ?: cls;
        if (LBIsSharedTableBaseClass(owner) && !sTruePlainDidSelect && (IMP)prev != NULL) {
            sTruePlainDidSelect = (IMP)prev;
        }
        if (!LBOrig_catalogDidSelect) {
            LBOrig_catalogDidSelect = sTruePlainDidSelect
                ? (void (*)(id, SEL, UITableView *, NSIndexPath *))sTruePlainDidSelect
                : prev;
        }
        IMP hook = imp_implementationWithBlock(^void(id selfObj, UITableView *tv, NSIndexPath *ip) {
            void (*fwd)(id, SEL, UITableView *, NSIndexPath *) =
                sTruePlainDidSelect
                    ? (void (*)(id, SEL, UITableView *, NSIndexPath *))sTruePlainDidSelect
                    : (LBOrig_catalogDidSelect ?: prev);
            // 书架：原生点选
            if (LBVCIsBookShelfContext(selfObj)) {
                if (fwd) {
                    @try { fwd(selfObj, selSel, tv, ip); } @catch (NSException *e) {
                        NSLog(@"[LegadoBridge] shelf didSelect fail-open: %@", e);
                    }
                }
                return;
            }
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
                if (fwd) {
                    @try { fwd(selfObj, selSel, tv, ip); } @catch (NSException *e) {
                        NSLog(@"[LegadoBridge] search/native didSelect fail-open: %@", e);
                    }
                }
                return;
            }
            // 目录：优先用户已改序的 arrSource / pending
            NSArray *use = nil;
            @try {
                id src = [selfObj valueForKey:@"arrSource"];
                if (LBArrayLooksLikeChapters(src)) use = src;
            } @catch (__unused NSException *e) {}
            if (!use) use = sPendingCatalogChapters;
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
                    use = nil;
                }
            }
            if (use.count > 0 && ip && ip.row >= 0 && ip.row < (NSInteger)use.count) {
                if (sPendingCatalogChapters.count == 0) {
                    sPendingCatalogChapters = [use copy];
                }
                LBTrySetArrayKey(selfObj, @"arrCatalog", use);
                LBOpenLegadoChapterAtIndex(ip.row);
                if (tv && ip) {
                    @try { [tv deselectRowAtIndexPath:ip animated:YES]; } @catch (__unused NSException *e) {}
                }
                handled = YES;
            }
            if (!handled && fwd) {
                @try {
                    fwd(selfObj, selSel, tv, ip);
                } @catch (NSException *e) {
                    NSLog(@"[LegadoBridge] catalog didSelect fail-open: %@", e);
                }
            }
        });
        LBInstallHookOnClassOnly(cls, selSel, hook, &sTruePlainDidSelect);
        [sHookedTargets addObject:selKey];
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
    if (LBReadingDicLooksExplicitNativeXBS(dic)) return NO;
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
    BOOL explicitNative =
        LBReadingDicLooksExplicitNativeXBS(LBReadingDicFromObject(book)) ||
        LBReadingDicLooksExplicitNativeXBS(LBReadingDicFromObject(record));
    BOOL isLegado = !explicitNative &&
                    (LBBookLooksLegadoForKillSwitch(book, &bu, &ch, &title) ||
                     LBBookLooksLegadoForKillSwitch(record, &bu, &ch, &title));
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
    for (NSString *cn in @[@"BookSearchController", @"BookSearchVCBase1", @"BookSearchVCBase2",
                           @"BookListCon", @"BookWorldHomeCon", @"BookStoreBaseCon", @"ShudanHomeCon"]) {
        Class cls = NSClassFromString(cn);
        if (!cls) continue;
        Class owner = LBClassOwningInstanceMethod(cls, selSel) ?: cls;
        NSString *key = [NSString stringWithFormat:@"searchSel:%@", NSStringFromClass(owner)];
        if ([sSearchSelHooked containsObject:key]) continue;
        Method m = class_getInstanceMethod(owner, selSel);
        // B-06：BookListCon 无 didSelect 时原先直接跳过 → 点书无响应；改为挂到 cls 自身
        if (!m) {
            if (!class_addMethod(cls, selSel, (IMP)LBHookedPlazaDidSelect, "v@:@@")) continue;
            [sSearchSelHooked addObject:key];
            NSLog(@"[LegadoBridge] added plaza didSelect @%@", cn);
            continue;
        }
        void (*prev)(id, SEL, UITableView *, NSIndexPath *) =
            (void (*)(id, SEL, UITableView *, NSIndexPath *))method_getImplementation(m);
        IMP hook = imp_implementationWithBlock(^void(id selfObj, UITableView *tv, NSIndexPath *ip) {
            NSString *selfClassName = NSStringFromClass([selfObj class]);
            BOOL nativeDiscover =
                LBIsDiscoverNativeXBSMode() && LBIsDiscoverTabActive() &&
                ([selfClassName containsString:@"BookList"] ||
                 [selfClassName containsString:@"BookWorld"] ||
                 [selfClassName containsString:@"BookStore"] ||
                 [selfClassName containsString:@"Shudan"]);
            if (nativeDiscover) {
                // XBS 原生点书必须回到宿主 didSelect；Bridge 旁路会把原生书
                // 误送入 LBPushLegadoBookDetailFromSearch，阅读页样式随之改变。
                prev(selfObj, @selector(tableView:didSelectRowAtIndexPath:), tv, ip);
                return;
            }
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
    static NSMutableSet<NSString *> *sCatalogAppearHookedClasses = nil;
    static dispatch_once_t onceCatalogAppear;
    dispatch_once(&onceCatalogAppear, ^{
        sCatalogAppearHookedClasses = [NSMutableSet set];
    });
    for (NSString *cn in names) {
        Class cls = NSClassFromString(cn);
        if (!cls) continue;
        NSString *className = NSStringFromClass(cls);
        if ([sCatalogAppearHookedClasses containsObject:className]) continue;
        SEL sel = @selector(viewDidAppear:);
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) continue;
        IMP orig = method_getImplementation(m);
        const char *types = method_getTypeEncoding(m);
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
        // class_getInstanceMethod 会返回继承方法；替换它会把目录钩子扩散到
        // BookWorld/BookList 等共享父类。继承场景只在目标类本地加 override。
        Class owner = LBClassOwningInstanceMethod(cls, sel);
        BOOL installed = NO;
        if (owner == cls) {
            method_setImplementation(m, hook);
            installed = YES;
        } else {
            installed = class_addMethod(cls, sel, hook, types);
        }
        if (installed) [sCatalogAppearHookedClasses addObject:className];
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
        // 换书时解除用户倒序锁；同书刷新仍允许引擎新目录覆盖（reapply 短延迟由 lock 挡住）
        if (bookUrl.length > 0 &&
            sPendingCatalogBookUrl.length > 0 &&
            ![bookUrl isEqualToString:sPendingCatalogBookUrl]) {
            sCatalogUserOrderLocked = NO;
        }
        if (!sCatalogUserOrderLocked) {
            sPendingCatalogChapters = [chapters copy];
        }
        sPendingCatalogBookUrl = [bookUrl copy];
        LBSaveCatalogCache(bookUrl, chapters);
        NSArray *applyCh = sCatalogUserOrderLocked && sPendingCatalogChapters.count > 0
            ? sPendingCatalogChapters : chapters;
        NSUInteger applied = LBApplyPendingCatalogToVCs(applyCh, bookUrl, @"ok");
        if (applied == 0) {
            LBCatalogWriteMarker([NSString stringWithFormat:@"uiInject pending n=%lu book=%@ (no writable CatalogVC)",
                                  (unsigned long)applyCh.count, bookUrl ?: @""]);
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
            if (sNativeReadChapterOpenStarted) {
                LBAppendOpenReaderTrace(@"catalogUI skip alreadyStarted deliverOnly");
                LBDeliverContentToVisibleReaders(@"catalogUIStarted");
            } else {
                NSString *blocked = nil;
                if (LBNativeOpenGateBlocked(&blocked)) {
                    LBAppendOpenReaderTrace([NSString stringWithFormat:
                                             @"catalogUI skip openOnce/chapterDone reason=%@", blocked ?: @"?"]);
                    if (sNativeOpenChapterDone || sNativeOpenOnceKey.length > 0 ||
                        [blocked isEqualToString:@"disk"]) {
                        LBDeliverContentToVisibleReaders(@"catalogUISkip");
                    }
                } else if (sLegadoReaderMode == 1 &&
                           (LBIsTextReaderVisible() || LBNavStackHasTextReader())) {
                    LBAppendOpenReaderTrace(@"catalogUI skip readerOnStack deliverOnly");
                    LBDeliverContentToVisibleReaders(@"catalogUIOnStack");
                } else {
                    sNativeReadChapterOpenStarted = YES;
                    LBOpenLegadoChapterAtIndexWithVia(useIdx, @"catalogUI");
                }
            }
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
        sPendingCatalogSourceUrl = LBOriginSourceUrlFromBookUrl(bookUrl);
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
    BOOL sameBook = (sDeferredNativeOpenBookUrl.length > 0 &&
                     [sDeferredNativeOpenBookUrl isEqualToString:bu]);
    if (!sameBook && LBNativeOpenMarkerMatchesBook(bu)) {
        sameBook = YES;
    }
    BOOL readerOnStack = LBIsTextReaderVisible() || LBNavStackHasTextReader();
    NSInteger curIdx = LBCurrentNativeOpenIdx();
    // 8.5：杀进程/回书架后阅读页不在栈 —— 允许同书冷开（勿被 openOnce/disk 永久拦住）
    if (sameBook && !readerOnStack && !sNativeOpenGoInFlight &&
        (sNativeOpenChapterDone || sNativeOpenOnceKey.length > 0 ||
         LBReadNativeOpenOnceMarker().length > 0)) {
        LBAppendOpenReaderTrace([NSString stringWithFormat:
                                 @"nativeRead coldReopen notOnStack wantIdx=%ld", (long)wantIdx]);
        LBClearNativeOpenOnceState(@"coldReopenNotOnStack");
        LBLoadCurCpBridgeReset(@"nativeRead_coldReopen");
        sameBook = NO; // 下方走冷开：重新设 deferred + 拉目录/缓存
    }
    // 假设 T：禁止「未可见就清 openOnce 重开」——动画中/崩溃重启会双 push → SIGABRT 回桌面。
    // 同书换 idx：阅读页已在栈上则原地切章（拉正文 + loadCp），禁止二次 push。
    if (sameBook && (sNativeOpenChapterDone || sNativeOpenOnceKey.length > 0 ||
                     LBReadNativeOpenOnceMarker().length > 0 || sNativeOpenGoInFlight)) {
        if (curIdx == wantIdx && readerOnStack) {
            LBAppendOpenReaderTrace([NSString stringWithFormat:
                                     @"nativeRead skip sameBook sameIdx=%ld", (long)wantIdx]);
            // 禁止再走 deliver/overlay：滚动切章后同 idx 复入会叠 UITextView/overlay92011
            return;
        }
        if (curIdx != wantIdx && readerOnStack) {
            LBAppendOpenReaderTrace([NSString stringWithFormat:
                                     @"nativeRead switchInPlace cur=%ld want=%ld",
                                     (long)curIdx, (long)wantIdx]);
            LBSwitchNativeChapterInPlace(bu, su, wantIdx);
            return;
        }
        if (curIdx != wantIdx && !readerOnStack) {
            LBAppendOpenReaderTrace([NSString stringWithFormat:
                                     @"nativeRead reopenDiffIdx cur=%ld want=%ld",
                                     (long)curIdx, (long)wantIdx]);
            LBClearNativeOpenOnceState(@"reopenDiffIdx");
            LBLoadCurCpBridgeReset(@"nativeRead_reopenDiffIdx");
            // 落入下方冷开路径
        } else if (sNativeOpenGoInFlight && sameBook) {
            LBAppendOpenReaderTrace(@"nativeRead skip inflight sameBook");
            return;
        } else if (sNativeOpenChapterDone && sameBook) {
            LBAppendOpenReaderTrace(@"nativeRead skip chapterDone sameBook");
            return;
        } else if (sNativeOpenOnceKey.length > 0 && sameBook) {
            LBAppendOpenReaderTrace(@"nativeRead skip openOnce sameBook");
            return;
        } else {
            NSString *diskKey = LBReadNativeOpenOnceMarker();
            if (diskKey.length > 0 && sameBook) {
                if (sNativeOpenOnceKey.length == 0) sNativeOpenOnceKey = [diskKey copy];
                LBAppendOpenReaderTrace(@"nativeRead skip openOnce disk sameBook");
                return;
            }
        }
    }
    if (sNativeOpenGoInFlight && sameBook) {
        LBAppendOpenReaderTrace(@"nativeRead skip inflight sameBook");
        return;
    }
    // 8.5：无内存目录时先灌盘缓存 / xsfolder localSourceText（停 mock 仍可开已缓存章）
    LBEnsurePendingCatalogForBook(bu);
    BOOL awaitingCatalogRelease = NO;
    if (sameBook && sDeferredNativeOpenIdx >= 0 && !sNativeOpenChapterDone &&
        sNativeOpenOnceKey.length == 0) {
        BOOL catalogReady = (sPendingCatalogChapters.count > 0 &&
            (sPendingCatalogBookUrl.length == 0 ||
             [sPendingCatalogBookUrl isEqualToString:bu]));
        if (!catalogReady) {
            catalogReady = LBEnsurePendingCatalogForBook(bu);
        }
        if (!catalogReady) {
            LBAppendOpenReaderTrace(@"awaitingCatalog keep waiting");
            return;
        }
        LBAppendOpenReaderTrace(@"awaitingCatalog release pendingNow");
        wantIdx = sDeferredNativeOpenIdx;
        awaitingCatalogRelease = YES;
    }
    // 仅换书冷启动才清占坑；同书二次深链/appear 回调不得清锁（真机曾双 preferNativeFull）
    if (!sameBook && !LBNativeOpenMarkerMatchesBook(bu)) {
        sNativeOpenOnceKey = nil;
        sNativeOpenChapterDone = NO;
        sNativeOpenGoInFlight = NO;
        sNativeReadChapterOpenStarted = NO;
        LBClearNativeOpenOnceMarker();
    }
    if (!awaitingCatalogRelease) {
        sDeferredNativeOpenIdx = wantIdx;
        sDeferredNativeOpenBookUrl = bu;
    }
    [[NSString stringWithFormat:@"nativeOpenRequest book=%@ src=%@ idx=%ld",
      bu, su ?: @"", (long)wantIdx]
        writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_nativeread_request.txt"]
        atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    LBInstallCatalogUIAppearFlush();
    // 若目录已在 pending（含 awaitingCatalog 释放），立刻点章
    if (awaitingCatalogRelease ||
        (sPendingCatalogChapters.count > 0 &&
         (sPendingCatalogBookUrl.length == 0 || [sPendingCatalogBookUrl isEqualToString:bu]))) {
        NSInteger useIdx = wantIdx;
        if (useIdx >= (NSInteger)sPendingCatalogChapters.count) useIdx = 0;
        sDeferredNativeOpenIdx = -1;
        if (!sNativeReadChapterOpenStarted && !LBNativeOpenGateBlocked(NULL)) {
            sNativeReadChapterOpenStarted = YES;
            LBOpenLegadoChapterAtIndexWithVia(useIdx, @"pendingNow");
        } else {
            LBAppendOpenReaderTrace(@"pendingNow skip openOnce/started");
            LBDeliverContentToVisibleReaders(@"pendingNowSkip");
        }
        return;
    }
    LBHandleCatalogRequest(bu, su);
    // 目录异步返回后由 LBApplyCatalogToUI 触发；多档延迟兜底
    void (^tryOpen)(NSString *) = ^(NSString *phase) {
        if (sDeferredNativeOpenIdx < 0) return;
        if (sNativeReadChapterOpenStarted) {
            LBAppendOpenReaderTrace([NSString stringWithFormat:@"tryOpen skip started phase=%@", phase]);
            return;
        }
        NSString *blocked = nil;
        if (LBNativeOpenGateBlocked(&blocked)) {
            LBAppendOpenReaderTrace([NSString stringWithFormat:
                                     @"tryOpen skip openOnce/chapterDone phase=%@ reason=%@",
                                     phase, blocked ?: @"?"]);
            return;
        }
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
        sNativeReadChapterOpenStarted = YES;
        LBOpenLegadoChapterAtIndexWithVia(useIdx, [NSString stringWithFormat:@"tryOpen@%@", phase]);
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ tryOpen(@"0.8"); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ tryOpen(@"2.0"); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ tryOpen(@"4.0"); });
}

void LBHandleContentRequest(NSString *chapterUrl, NSString *bookUrl, NSString *sourceUrl) {
    // 8.5：优先用 xsfolder 已缓存章（停 mock 时网络 getContent 会失败）
    NSInteger preferIdx = 0;
    if ([chapterUrl isKindOfClass:[NSString class]] && chapterUrl.length > 0 &&
        [[NSCharacterSet decimalDigitCharacterSet]
             isSupersetOfSet:[NSCharacterSet characterSetWithCharactersInString:chapterUrl]]) {
        preferIdx = [chapterUrl integerValue];
    } else if (sPendingCatalogChapters.count > 0 && chapterUrl.length > 0) {
        NSInteger i = 0;
        for (id it in sPendingCatalogChapters) {
            if (![it isKindOfClass:[NSDictionary class]]) { i++; continue; }
            NSDictionary *d = (NSDictionary *)it;
            NSString *u = d[@"cpUrl"] ?: d[@"chapterUrl"] ?: d[@"url"] ?: @"";
            if ([u isEqualToString:chapterUrl]) {
                preferIdx = i;
                break;
            }
            i++;
        }
    }
    NSString *cachedBody = LBReadXsfolderChapterBody(bookUrl, chapterUrl, preferIdx);
    if (cachedBody.length > 0) {
        NSMutableDictionary *payload = [NSMutableDictionary dictionary];
        payload[@"chapterContent"] = cachedBody;
        payload[@"content"] = cachedBody;
        if (chapterUrl.length > 0) {
            payload[@"chapterUrl"] = chapterUrl;
            payload[@"cpUrl"] = chapterUrl;
        }
        if (bookUrl.length > 0) payload[@"bookUrl"] = bookUrl;
        payload[@"cpIndex"] = @(preferIdx);
        payload[@"index"] = @(preferIdx);
        if (sPendingNativeFullBook[@"cpTitle"]) {
            payload[@"cpTitle"] = sPendingNativeFullBook[@"cpTitle"];
            payload[@"title"] = sPendingNativeFullBook[@"cpTitle"];
        }
        payload[@"legadoBridge"] = @"1";
        LBNoteResetContentPosted(payload);
    }
    Class coreClass = NSClassFromString(@"LegadoBridge.LegadoBridgeCore");
    if (!coreClass) return;
    id core = [coreClass performSelector:@selector(shared)];
    ((void (*)(id, SEL, NSString *, NSString *, NSString *))objc_msgSend)(
        core, @selector(handleContentRequestWithChapterUrl:bookUrl:sourceUrl:),
        chapterUrl ?: @"", bookUrl ?: @"", sourceUrl
    );
}

NSString *LBDecodeCoverURL(NSString *url, NSString *sourceUrl) {
    if (url.length == 0) return url;
    Class coreClass = NSClassFromString(@"LegadoBridge.LegadoBridgeCore");
    if (!coreClass) return url;
    id core = [coreClass performSelector:@selector(shared)];
    if (![core respondsToSelector:@selector(decodeCoverURL:sourceUrl:)]) return url;
    return ((NSString *(*)(id, SEL, NSString *, NSString *))objc_msgSend)(
        core, @selector(decodeCoverURL:sourceUrl:), url, sourceUrl
    ) ?: url;
}

void LBOpenTTS(NSString *bookUrl, NSString *chapterUrl, NSString *chapterTitle) {
    Class coreClass = NSClassFromString(@"LegadoBridge.LegadoBridgeCore");
    if (!coreClass) return;
    id core = [coreClass performSelector:@selector(shared)];
    if (![core respondsToSelector:@selector(openTTSForBookUrl:chapterUrl:chapterTitle:speakText:ttsURLTemplate:)]) return;
    ((void (*)(id, SEL, NSString *, NSString *, NSString *, NSString *, NSString *))objc_msgSend)(
        core, @selector(openTTSForBookUrl:chapterUrl:chapterTitle:speakText:ttsURLTemplate:),
        bookUrl ?: @"", chapterUrl ?: @"", chapterTitle, nil, nil
    );
}

void LBPresentAudioPlayer(NSString *bookUrl, NSString *chapterUrl, NSString *chapterTitle) {
    LBOpenTTS(bookUrl, chapterUrl, chapterTitle);
}
