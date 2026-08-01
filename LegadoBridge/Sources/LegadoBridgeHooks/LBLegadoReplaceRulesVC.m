#import <UIKit/UIKit.h>
#import <objc/message.h>
#import "LegadoBridge.h"
#import "LBInternal.h"

/// B6：净化规则管理 — 列表 / 启停 / 导入 JSON / 分组筛选（global|book|chapter|全部）
@interface LBLegadoReplaceRulesVC : UITableViewController <UITextViewDelegate>
@property (nonatomic, copy) NSArray<NSDictionary *> *rules;
@property (nonatomic, copy, nullable) NSString *scopeFilter; // nil/__all__ / global / book / chapter
@end

@implementation LBLegadoReplaceRulesVC

static id LBReplaceCore(void) {
    Class coreClass = NSClassFromString(@"LegadoBridge.LegadoBridgeCore");
    if (!coreClass) return nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    return [coreClass performSelector:@selector(shared)];
#pragma clang diagnostic pop
}

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"净化规则";
    if (!self.scopeFilter) self.scopeFilter = @"__all__";
    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithTitle:@"导入"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(onImportTapped)],
        [[UIBarButtonItem alloc] initWithTitle:@"分组"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(onFilterTapped)]
    ];
    if (self.navigationController.viewControllers.firstObject == self) {
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                 target:self
                                 action:@selector(onCloseTapped)];
    }
    [self reloadRules];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadRules];
}

- (void)onCloseTapped {
    if (self.presentingViewController) {
        [self dismissViewControllerAnimated:YES completion:nil];
    } else {
        [self.navigationController popViewControllerAnimated:YES];
    }
}

- (void)reloadRules {
    id core = LBReplaceCore();
    NSArray *info = nil;
    if (core && [core respondsToSelector:@selector(allReplaceRulesInfo)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        info = [core performSelector:@selector(allReplaceRulesInfo)];
#pragma clang diagnostic pop
    }
    NSArray *all = [info isKindOfClass:[NSArray class]] ? info : @[];
    NSString *filter = self.scopeFilter ?: @"__all__";
    if ([filter isEqualToString:@"__all__"] || filter.length == 0) {
        self.rules = all;
    } else {
        NSMutableArray *filtered = [NSMutableArray array];
        for (NSDictionary *r in all) {
            if (![r isKindOfClass:[NSDictionary class]]) continue;
            NSString *scope = r[@"scope"];
            if (![scope isKindOfClass:[NSString class]] || scope.length == 0) scope = @"global";
            if ([scope isEqualToString:filter]) [filtered addObject:r];
        }
        self.rules = filtered;
    }
    NSString *scopeTitle = [filter isEqualToString:@"__all__"] ? @"全部" : filter;
    self.title = [NSString stringWithFormat:@"净化规则（%@ · %lu）",
                  scopeTitle, (unsigned long)self.rules.count];
    [self.tableView reloadData];

    // B6 证据：管理页已打开并完成刷新
    NSString *mark = [NSString stringWithFormat:@"open replaceVC filter=%@ count=%lu ts=%.0f\n",
                      filter, (unsigned long)self.rules.count, [[NSDate date] timeIntervalSince1970]];
    [mark writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_b6_replace_ui.txt"]
           atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

#pragma mark - Actions

- (void)onFilterTapped {
    UIAlertController *sheet =
        [UIAlertController alertControllerWithTitle:@"按作用域筛选"
                                            message:nil
                                     preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *opts = @[
        @[@"全部", @"__all__"],
        @[@"global", @"global"],
        @[@"book", @"book"],
        @[@"chapter", @"chapter"]
    ];
    for (NSArray *o in opts) {
        NSString *title = o[0];
        NSString *val = o[1];
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *a) {
            self.scopeFilter = val;
            [self reloadRules];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *pop = sheet.popoverPresentationController;
    if (pop) {
        pop.barButtonItem = self.navigationItem.rightBarButtonItems.lastObject;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)onImportTapped {
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"导入净化规则"
                                            message:@"粘贴 Legado 替换规则 JSON（数组或单条）"
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"[{pattern,replacement,...}]";
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"导入"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *a) {
        NSString *json = alert.textFields.firstObject.text ?: @"";
        [weakSelf importJSON:json];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)importJSON:(NSString *)json {
    id core = LBReplaceCore();
    if (!core || ![core respondsToSelector:@selector(importReplaceRulesJSON:error:)]) {
        LBLegadoShowResult(@"导入接口不可用");
        return;
    }
    NSError *err = nil;
    NSInteger n = ((NSInteger (*)(id, SEL, NSString *, NSError **))objc_msgSend)(
        core, @selector(importReplaceRulesJSON:error:), json, &err
    );
    if (n <= 0) {
        LBLegadoShowResult(err.localizedDescription.length ? err.localizedDescription : @"导入失败");
        return;
    }
    NSString *mark = [NSString stringWithFormat:@"import ok count=%ld ts=%.0f\n",
                      (long)n, [[NSDate date] timeIntervalSince1970]];
    [mark writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_b6_replace_import.txt"]
           atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    LBLegadoShowResult([NSString stringWithFormat:@"已导入 %ld 条", (long)n]);
    [self reloadRules];
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return (NSInteger)self.rules.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"lb.replace.cell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
    }
    NSDictionary *r = self.rules[(NSUInteger)indexPath.row];
    NSString *name = r[@"name"];
    if (![name isKindOfClass:[NSString class]] || name.length == 0) name = @"（未命名）";
    NSString *pattern = r[@"pattern"];
    if (![pattern isKindOfClass:[NSString class]]) pattern = @"";
    NSString *scope = r[@"scope"];
    if (![scope isKindOfClass:[NSString class]] || scope.length == 0) scope = @"global";
    BOOL enabled = YES;
    id en = r[@"enabled"];
    if ([en respondsToSelector:@selector(boolValue)]) enabled = [en boolValue];

    cell.textLabel.text = [NSString stringWithFormat:@"%@ · %@", enabled ? @"开" : @"关", name];
    cell.textLabel.numberOfLines = 1;
    NSString *patShort = pattern.length > 48 ? [[pattern substringToIndex:48] stringByAppendingString:@"…"] : pattern;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"[%@] %@", scope, patShort];
    cell.detailTextLabel.numberOfLines = 2;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.textLabel.textColor = enabled ? UIColor.labelColor : UIColor.secondaryLabelColor;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *r = self.rules[(NSUInteger)indexPath.row];
    NSString *rid = r[@"id"];
    if (![rid isKindOfClass:[NSString class]] || rid.length == 0) return;
    BOOL enabled = YES;
    id en = r[@"enabled"];
    if ([en respondsToSelector:@selector(boolValue)]) enabled = [en boolValue];
    NSString *name = [r[@"name"] isKindOfClass:[NSString class]] ? r[@"name"] : @"规则";

    UIAlertController *sheet =
        [UIAlertController alertControllerWithTitle:name
                                            message:r[@"pattern"]
                                     preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    NSString *toggleTitle = enabled ? @"停用" : @"启用";
    [sheet addAction:[UIAlertAction actionWithTitle:toggleTitle
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *a) {
        id core = LBReplaceCore();
        if (core && [core respondsToSelector:@selector(setReplaceRuleEnabledWithId:enabled:)]) {
            ((BOOL (*)(id, SEL, NSString *, BOOL))objc_msgSend)(
                core, @selector(setReplaceRuleEnabledWithId:enabled:), rid, !enabled
            );
        }
        [weakSelf reloadRules];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"删除"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *a) {
        id core = LBReplaceCore();
        if (core && [core respondsToSelector:@selector(removeReplaceRuleWithId:)]) {
            ((BOOL (*)(id, SEL, NSString *))objc_msgSend)(
                core, @selector(removeReplaceRuleWithId:), rid
            );
        }
        [weakSelf reloadRules];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *pop = sheet.popoverPresentationController;
    if (pop) {
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        pop.sourceView = cell;
        pop.sourceRect = cell.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    NSDictionary *r = self.rules[(NSUInteger)indexPath.row];
    NSString *rid = r[@"id"];
    __weak typeof(self) weakSelf = self;
    UIContextualAction *del =
        [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                title:@"删除"
                                              handler:^(__unused UIContextualAction *action,
                                                        __unused UIView *sourceView,
                                                        void (^completionHandler)(BOOL)) {
        id core = LBReplaceCore();
        if (core && [rid isKindOfClass:[NSString class]] &&
            [core respondsToSelector:@selector(removeReplaceRuleWithId:)]) {
            ((BOOL (*)(id, SEL, NSString *))objc_msgSend)(
                core, @selector(removeReplaceRuleWithId:), rid
            );
        }
        [weakSelf reloadRules];
        completionHandler(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}

@end

void LBPresentLegadoReplaceRulesManager(void) {
    void (^presentBlock)(void) = ^{
        UIWindow *win = LBLegadoKeyWindow();
        UIViewController *root = win.rootViewController;
        while (root.presentedViewController) root = root.presentedViewController;
        LBLegadoReplaceRulesVC *vc = [[LBLegadoReplaceRulesVC alloc] init];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        // 若当前已是导航栈（如书源管理页），直接 push
        if ([root isKindOfClass:[UINavigationController class]]) {
            [(UINavigationController *)root pushViewController:vc animated:YES];
            return;
        }
        UIViewController *top = root;
        if ([top isKindOfClass:[UITabBarController class]]) {
            top = ((UITabBarController *)top).selectedViewController;
        }
        if ([top isKindOfClass:[UINavigationController class]]) {
            [(UINavigationController *)top pushViewController:vc animated:YES];
            return;
        }
        if (top.navigationController) {
            [top.navigationController pushViewController:vc animated:YES];
            return;
        }
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
        [root presentViewController:nav animated:YES completion:nil];
    };
    if ([NSThread isMainThread]) {
        presentBlock();
    } else {
        dispatch_async(dispatch_get_main_queue(), presentBlock);
    }
}
