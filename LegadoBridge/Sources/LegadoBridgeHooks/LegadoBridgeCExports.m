#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import "LegadoBridge.h"

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
static void LBCollectBookSearchVCs(UIViewController *vc, NSMutableArray *out) {
    if (!vc) return;
    NSString *cn = NSStringFromClass([vc class]);
    if ([cn containsString:@"BookSearch"]) {
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
        @try { [vc setValue:keyword forKey:@"searchTextOutSide"]; } @catch (__unused NSException *e) {}
        @try { [vc setValue:keyword forKey:@"searchText"]; } @catch (__unused NSException *e) {}
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
        UITableView *tv = [vc valueForKey:@"tableView"];
        if ([tv isKindOfClass:[UITableView class]]) {
            id ds = tv.dataSource;
            NSString *dsName = ds ? NSStringFromClass([ds class]) : @"";
            // 断裂的 _UIFilteredDataSource（内部 dataSource=nil）会永远 0 行
            if ([dsName containsString:@"Filtered"]) {
                id inner = nil;
                @try { inner = [ds valueForKey:@"dataSource"]; } @catch (__unused NSException *e) {}
                if (!inner) {
                    tv.dataSource = (id<UITableViewDataSource>)vc;
                }
            }
            [tv reloadData];
        }
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
    NSMutableArray *vcs = [NSMutableArray array];
    for (UIWindow *win in UIApplication.sharedApplication.windows) {
        LBCollectBookSearchVCs(win.rootViewController, vcs);
    }
    if (vcs.count == 0) {
        NSString *marker = [NSString stringWithFormat:@"uiInject skip no BookSearchVC n=%lu key=%@",
                            (unsigned long)books.count, keyword ?: @""];
        [marker writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_ui_inject.txt"]
                 atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return;
    }
    NSUInteger applied = 0;
    for (UIViewController *vc in vcs) {
        for (id b in books) {
            if (![b isKindOfClass:[NSDictionary class]]) continue;
            LBMergeBookIntoSearchVC(vc, b, keyword);
            applied++;
        }
    }
    NSString *marker = [NSString stringWithFormat:@"uiInject ok vcs=%lu books=%lu applied=%lu key=%@",
                        (unsigned long)vcs.count, (unsigned long)books.count,
                        (unsigned long)applied, keyword ?: @""];
    [marker writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_ui_inject.txt"]
             atomically:YES encoding:NSUTF8StringEncoding error:NULL];
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
