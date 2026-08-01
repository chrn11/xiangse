#import <UIKit/UIKit.h>
#import <objc/message.h>
#import "LegadoBridge.h"

/// Legado 书源管理页：列表、启停、删除、结构化+JSON 编辑、订阅刷新、分组筛选；「发现」真切发现源
@interface LBLegadoSourceManagerVC : UITableViewController
@property (nonatomic, copy) NSArray<NSDictionary *> *sources;
@property (nonatomic, copy, nullable) NSString *focusSourceUrl;
@property (nonatomic, copy, nullable) NSString *groupFilter; // nil/__all__=全部；__ungrouped__=无分组
@end

@interface LBLegadoSourceEditorVC : UITableViewController <UITextViewDelegate>
@property (nonatomic, copy) NSString *sourceUrl;
@property (nonatomic, strong) UISegmentedControl *modeSeg;
@property (nonatomic, strong) UITextField *nameField;
@property (nonatomic, strong) UITextField *urlField;
@property (nonatomic, strong) UITextField *searchField;
@property (nonatomic, strong) UITextField *exploreField;
@property (nonatomic, strong) UITextField *groupField;
@property (nonatomic, strong) UITextView *ruleSearchView;
@property (nonatomic, strong) UITextView *ruleExploreView;
@property (nonatomic, strong) UITextView *ruleBookInfoView;
@property (nonatomic, strong) UITextView *ruleTocView;
@property (nonatomic, strong) UITextView *ruleContentView;
@property (nonatomic, strong) UITextView *jsonView;
@property (nonatomic, assign) NSInteger mode; // 0 结构化 1 JSON
@end

@implementation LBLegadoSourceManagerVC

#pragma mark - Core 桥接

static id LBLegadoManagerCore(void) {
    Class coreClass = NSClassFromString(@"LegadoBridge.LegadoBridgeCore");
    if (!coreClass) return nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    return [coreClass performSelector:@selector(shared)];
#pragma clang diagnostic pop
}

- (void)reloadSources {
    id core = LBLegadoManagerCore();
    NSArray *info = nil;
    if (core) {
        NSString *filter = self.groupFilter.length > 0 ? self.groupFilter : @"__all__";
        if ([core respondsToSelector:@selector(sourcesInfoFilteredByGroup:)]) {
            info = ((NSArray * (*)(id, SEL, NSString *))objc_msgSend)(
                core, @selector(sourcesInfoFilteredByGroup:), filter
            );
        } else if ([core respondsToSelector:@selector(allSourcesInfo)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            info = [core performSelector:@selector(allSourcesInfo)];
#pragma clang diagnostic pop
        }
    }
    self.sources = [info isKindOfClass:[NSArray class]] ? info : @[];
    [self.tableView reloadData];
}

#pragma mark - 生命周期

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"书源管理";
    if (!self.groupFilter) self.groupFilter = @"__all__";
    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                      target:self
                                                      action:@selector(onAddTapped)],
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                      target:self
                                                      action:@selector(onSubscribeRefreshTapped)],
        [[UIBarButtonItem alloc] initWithTitle:@"净化"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(onReplaceRulesTapped)],
        [[UIBarButtonItem alloc] initWithTitle:@"分组"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(onGroupFilterTapped)],
        [[UIBarButtonItem alloc] initWithTitle:@"发现"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(onExploreTapped)]
    ];
    if (self.navigationController.viewControllers.firstObject == self) {
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemClose
            target:self
            action:@selector(onCloseTapped)];
    }
    // 导入弹窗挂在 window root 上时，本页不会走 viewWillAppear；靠通知即时刷新
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(onSourceListUpdated:)
               name:@"dNotifyName_UpdateBookSourceModelList"
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(onSourceListUpdated:)
               name:@"dNotifyName_UpdateSourceList"
             object:nil];
    [self reloadSources];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)onSourceListUpdated:(NSNotification *)note {
    (void)note;
    [self reloadSources];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadSources];
    if (self.focusSourceUrl.length > 0) {
        NSString *focus = self.focusSourceUrl;
        self.focusSourceUrl = nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self openEditorForUrl:focus];
        });
    }
}

- (void)onCloseTapped {
    if (self.presentingViewController) {
        [self dismissViewControllerAnimated:YES completion:nil];
    } else {
        [self.navigationController popViewControllerAnimated:YES];
    }
}

#pragma mark - 操作

- (void)onAddTapped {
    LBShowLegadoImportAlert();
}

- (void)onReplaceRulesTapped {
    LBPresentLegadoReplaceRulesManager();
}

- (void)onGroupFilterTapped {
    id core = LBLegadoManagerCore();
    NSArray *groups = nil;
    if (core && [core respondsToSelector:@selector(allSourceGroups)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        groups = [core performSelector:@selector(allSourceGroups)];
#pragma clang diagnostic pop
    }
    if (![groups isKindOfClass:[NSArray class]]) groups = @[];

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"按分组筛选"
                                                                   message:@"筛选后列表仅显示该组书源。"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"全部" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        weakSelf.groupFilter = @"__all__";
        [weakSelf reloadSources];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"无分组" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        weakSelf.groupFilter = @"__ungrouped__";
        [weakSelf reloadSources];
    }]];
    for (id g in groups) {
        if (![g isKindOfClass:[NSString class]] || [(NSString *)g length] == 0) continue;
        NSString *name = (NSString *)g;
        [sheet addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            weakSelf.groupFilter = name;
            [weakSelf reloadSources];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *pop = sheet.popoverPresentationController;
    if (pop) {
        pop.barButtonItem = self.navigationItem.rightBarButtonItems.lastObject;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

/// T4：真正切发现源；禁止「已触发发现」Alert 冒充
- (void)onExploreTapped {
    NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
    for (NSDictionary *dict in self.sources) {
        if (![dict isKindOfClass:[NSDictionary class]]) continue;
        id flag = dict[@"exploreSupported"];
        BOOL ok = [flag isKindOfClass:[NSNumber class]] ? [(NSNumber *)flag boolValue] : NO;
        if (!ok) continue;
        NSString *name = dict[@"bookSourceName"];
        if (![name isKindOfClass:[NSString class]] || name.length == 0) continue;
        [candidates addObject:dict];
    }
    if (candidates.count == 0) {
        [self showMessage:@"当前筛选下没有可发现的书源"];
        return;
    }

    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:@"切换发现源"
                         message:@"选择后关闭本页，发现页标题与内容随所选源变化"
                  preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    for (NSDictionary *dict in candidates) {
        NSString *name = dict[@"bookSourceName"];
        [sheet addAction:[UIAlertAction actionWithTitle:name
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) {
            (void)a;
            [weakSelf applyDiscoverSourceNamed:name];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *pop = sheet.popoverPresentationController;
    if (pop) {
        pop.barButtonItem = self.navigationItem.rightBarButtonItems.lastObject;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)applyDiscoverSourceNamed:(NSString *)name {
    if (name.length == 0) return;
    NSString *target = [name copy];
    void (^go)(void) = ^{
        LBSwitchDiscoverToSourceName(target);
    };

    // 管理页常被 push 到现有导航（还可能叠多层）；选源后必须清掉管理/编辑页再切发现。
    UINavigationController *nav = self.navigationController;
    if (nav) {
        NSArray *stack = [nav.viewControllers copy];
        NSMutableArray *kept = [NSMutableArray array];
        for (UIViewController *vc in stack) {
            NSString *cn = NSStringFromClass([vc class]);
            if ([cn isEqualToString:@"LBLegadoSourceManagerVC"] ||
                [cn containsString:@"LBLegadoSourceEditor"]) {
                break;
            }
            [kept addObject:vc];
        }
        if (kept.count > 0 && kept.count < stack.count) {
            [nav setViewControllers:kept animated:YES];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), go);
            return;
        }
        if (nav.presentingViewController &&
            (kept.count == 0 || (stack.count == 1 && stack.firstObject == self))) {
            [nav.presentingViewController dismissViewControllerAnimated:YES completion:go];
            return;
        }
        if (nav.viewControllers.firstObject != self) {
            [nav popViewControllerAnimated:YES];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), go);
            return;
        }
    }
    if (self.presentingViewController) {
        [self.presentingViewController dismissViewControllerAnimated:YES completion:go];
        return;
    }
    go();
}

- (void)onSubscribeRefreshTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"订阅安全更新"
                                                                   message:@"填写订阅 URL。将按 bookSourceUrl 合并；保留本地启停；远端消失的源只标记不删除。"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"https://example.com/sources.json";
        textField.keyboardType = UIKeyboardTypeURL;
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"更新" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *urlText = alert.textFields.firstObject.text;
        [weakSelf fetchAndApplySubscription:urlText];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)fetchAndApplySubscription:(NSString *)urlText {
    if (urlText.length == 0) {
        [self showMessage:@"请填写订阅 URL"];
        return;
    }
    NSURL *url = [NSURL URLWithString:urlText];
    if (!url || url.scheme.length == 0) {
        [self showMessage:@"URL 无效"];
        return;
    }
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = 20;
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [[NSURLSession sessionWithConfiguration:cfg]
        dataTaskWithURL:url
      completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error || data.length == 0) {
                [weakSelf showMessage:error.localizedDescription ?: @"下载失败"];
                return;
            }
            id core = LBLegadoManagerCore();
            if (!core || ![core respondsToSelector:@selector(applySubscriptionJSONData:subscriptionURL:error:)]) {
                [weakSelf showMessage:@"Core 未就绪"];
                return;
            }
            NSError *applyError = nil;
            NSDictionary *result = ((NSDictionary * (*)(id, SEL, NSData *, NSString *, NSError **))objc_msgSend)(
                core, @selector(applySubscriptionJSONData:subscriptionURL:error:), data, urlText, &applyError
            );
            if (applyError || !result) {
                [weakSelf showMessage:applyError.localizedDescription ?: @"订阅更新失败"];
                return;
            }
            [weakSelf reloadSources];
            NSString *msg = [NSString stringWithFormat:@"新增 %@，更新 %@，标记缺失 %@，未变 %@",
                             result[@"added"] ?: @0,
                             result[@"updated"] ?: @0,
                             result[@"markedMissing"] ?: @0,
                             result[@"unchanged"] ?: @0];
            [weakSelf showMessage:msg];
        });
    }];
    [task resume];
}

- (void)showMessage:(NSString *)msg {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
                                                                   message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSString *)sourceNameFromDict:(NSDictionary *)dict {
    NSString *name = dict[@"bookSourceName"];
    if (![name isKindOfClass:[NSString class]] || name.length == 0) {
        name = dict[@"name"];
    }
    return [name isKindOfClass:[NSString class]] ? name : @"";
}

- (NSString *)sourceUrlFromDict:(NSDictionary *)dict {
    NSString *url = dict[@"bookSourceUrl"];
    if (![url isKindOfClass:[NSString class]] || url.length == 0) {
        url = dict[@"url"];
    }
    return [url isKindOfClass:[NSString class]] ? url : @"";
}

- (BOOL)isEnabledFromDict:(NSDictionary *)dict {
    id val = dict[@"enabled"];
    if ([val isKindOfClass:[NSNumber class]]) return [(NSNumber *)val boolValue];
    if ([val isKindOfClass:[NSString class]]) return [(NSString *)val boolValue];
    return YES;
}

- (void)setSourceEnabled:(BOOL)enabled forUrl:(NSString *)url {
    id core = LBLegadoManagerCore();
    if (!core || url.length == 0) return;
    SEL sel = @selector(setSourceEnabled:enabled:);
    if ([core respondsToSelector:sel]) {
        ((void (*)(id, SEL, NSString *, BOOL))objc_msgSend)(core, sel, url, enabled);
    }
}

- (void)removeSourceWithUrl:(NSString *)url {
    id core = LBLegadoManagerCore();
    if (!core || url.length == 0) return;
    SEL sel = @selector(removeSource:);
    if ([core respondsToSelector:sel]) {
        ((void (*)(id, SEL, NSString *))objc_msgSend)(core, sel, url);
    }
}

- (void)openEditorForUrl:(NSString *)url {
    if (url.length == 0) return;
    LBLegadoSourceEditorVC *editor = [[LBLegadoSourceEditorVC alloc] initWithStyle:UITableViewStyleInsetGrouped];
    editor.sourceUrl = url;
    [self.navigationController pushViewController:editor animated:YES];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) {
        return (NSInteger)LBHookCapabilityStatuses().count;
    }
    return (NSInteger)self.sources.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) {
        return @"Hook 能力（失败自动降级，不影响原生）";
    }
    NSString *filterHint = @"";
    if ([self.groupFilter isEqualToString:@"__ungrouped__"]) {
        filterHint = @" · 筛选:无分组";
    } else if (self.groupFilter.length > 0 && ![self.groupFilter isEqualToString:@"__all__"]) {
        filterHint = [NSString stringWithFormat:@" · 筛选:%@", self.groupFilter];
    }
    return self.sources.count > 0
        ? [NSString stringWithFormat:@"共 %lu 个%@（点行编辑；开关启停；右上角分组/发现）",
                                     (unsigned long)self.sources.count, filterHint]
        : @"暂无书源，点右上角 + 导入（亦支持 legado:// / yuedu://）";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        static NSString *capId = @"LBCapCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:capId];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:capId];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
        NSArray *caps = LBHookCapabilityStatuses();
        NSDictionary *row = (indexPath.row < (NSInteger)caps.count) ? caps[(NSUInteger)indexPath.row] : @{};
        NSString *status = [row[@"status"] isKindOfClass:[NSString class]] ? row[@"status"] : @"pending";
        cell.textLabel.text = [NSString stringWithFormat:@"%@ · %@", row[@"name"] ?: @"?", status];
        cell.detailTextLabel.text = [row[@"detail"] isKindOfClass:[NSString class]] ? row[@"detail"] : @"";
        cell.detailTextLabel.numberOfLines = 2;
        if ([status isEqualToString:@"enabled"]) {
            cell.textLabel.textColor = [UIColor labelColor];
        } else if ([status isEqualToString:@"failed"] || [status isEqualToString:@"skipped"]) {
            cell.textLabel.textColor = [UIColor systemOrangeColor];
        } else {
            cell.textLabel.textColor = [UIColor secondaryLabelColor];
        }
        return cell;
    }

    static NSString *cellId = @"LBLegadoSourceCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        UISwitch *toggle = [[UISwitch alloc] init];
        [toggle addTarget:self action:@selector(onSwitchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
    }

    NSDictionary *dict = (indexPath.row < (NSInteger)self.sources.count) ? self.sources[(NSUInteger)indexPath.row] : nil;
    NSString *name = [self sourceNameFromDict:dict];
    NSString *url = [self sourceUrlFromDict:dict];
    BOOL enabled = [self isEnabledFromDict:dict];
    BOOL missing = NO;
    id missingVal = dict[@"remoteMissing"];
    if ([missingVal isKindOfClass:[NSNumber class]]) missing = [(NSNumber *)missingVal boolValue];
    NSString *group = [dict[@"bookSourceGroup"] isKindOfClass:[NSString class]] ? dict[@"bookSourceGroup"] : @"";
    BOOL exploreOk = NO;
    id exploreVal = dict[@"exploreSupported"];
    if ([exploreVal isKindOfClass:[NSNumber class]]) exploreOk = [(NSNumber *)exploreVal boolValue];

    NSString *title = name.length > 0 ? name : @"(未命名)";
    if (missing) title = [title stringByAppendingString:@" · 远端缺失"];
    if (exploreOk) title = [title stringByAppendingString:@" · 发现"];
    cell.textLabel.text = title;
    cell.textLabel.textColor = [UIColor labelColor];
    if (group.length > 0) {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"[%@] %@", group, url];
    } else {
        cell.detailTextLabel.text = url;
    }
    cell.detailTextLabel.textColor = missing ? [UIColor systemOrangeColor] : [UIColor secondaryLabelColor];
    cell.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;

    UISwitch *toggle = (UISwitch *)cell.accessoryView;
    toggle.tag = indexPath.row;
    toggle.on = enabled;

    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 1;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != 1) return;
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    if (indexPath.row >= (NSInteger)self.sources.count) return;
    NSDictionary *dict = self.sources[(NSUInteger)indexPath.row];
    NSString *url = [self sourceUrlFromDict:dict];
    [self removeSourceWithUrl:url];
    [self reloadSources];
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 1) return;
    if (indexPath.row >= (NSInteger)self.sources.count) return;
    NSDictionary *dict = self.sources[(NSUInteger)indexPath.row];
    [self openEditorForUrl:[self sourceUrlFromDict:dict]];
}

- (void)onSwitchChanged:(UISwitch *)sender {
    NSInteger row = sender.tag;
    if (row < 0 || row >= (NSInteger)self.sources.count) return;
    NSDictionary *dict = self.sources[(NSUInteger)row];
    NSString *url = [self sourceUrlFromDict:dict];
    [self setSourceEnabled:sender.isOn forUrl:url];
}

@end

#pragma mark - Editor

@implementation LBLegadoSourceEditorVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"编辑书源";
    self.mode = 0;
    self.modeSeg = [[UISegmentedControl alloc] initWithItems:@[@"结构化", @"JSON"]];
    self.modeSeg.selectedSegmentIndex = 0;
    [self.modeSeg addTarget:self action:@selector(onModeChanged:) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = self.modeSeg;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"保存"
        style:UIBarButtonItemStyleDone
        target:self
        action:@selector(onSaveTapped)];

    self.nameField = [self makeField:@"书源名称 bookSourceName"];
    self.urlField = [self makeField:@"bookSourceUrl"];
    self.urlField.enabled = NO;
    self.urlField.textColor = [UIColor secondaryLabelColor];
    self.searchField = [self makeField:@"searchUrl"];
    self.exploreField = [self makeField:@"exploreUrl"];
    self.groupField = [self makeField:@"分组 bookSourceGroup"];

    self.ruleSearchView = [self makeRuleView];
    self.ruleExploreView = [self makeRuleView];
    self.ruleBookInfoView = [self makeRuleView];
    self.ruleTocView = [self makeRuleView];
    self.ruleContentView = [self makeRuleView];

    self.jsonView = [[UITextView alloc] initWithFrame:CGRectZero];
    self.jsonView.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    self.jsonView.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.jsonView.autocorrectionType = UITextAutocorrectionTypeNo;
    self.jsonView.delegate = self;
    self.jsonView.layer.borderColor = [UIColor separatorColor].CGColor;
    self.jsonView.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
    self.jsonView.layer.cornerRadius = 8;

    [self loadFromCore];
}

- (UITextField *)makeField:(NSString *)placeholder {
    UITextField *field = [[UITextField alloc] initWithFrame:CGRectZero];
    field.placeholder = placeholder;
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    return field;
}

- (UITextView *)makeRuleView {
    UITextView *tv = [[UITextView alloc] initWithFrame:CGRectZero];
    tv.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    tv.autocapitalizationType = UITextAutocapitalizationTypeNone;
    tv.autocorrectionType = UITextAutocorrectionTypeNo;
    tv.delegate = self;
    tv.layer.cornerRadius = 6;
    tv.backgroundColor = [UIColor secondarySystemBackgroundColor];
    return tv;
}

- (id)core {
    Class coreClass = NSClassFromString(@"LegadoBridge.LegadoBridgeCore");
    if (!coreClass) return nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    return [coreClass performSelector:@selector(shared)];
#pragma clang diagnostic pop
}

- (NSString *)prettyJSONObject:(id)obj {
    if (!obj || obj == [NSNull null]) return @"{}";
    NSError *err = nil;
    if (![NSJSONSerialization isValidJSONObject:obj]) return @"{}";
    NSData *data = [NSJSONSerialization dataWithJSONObject:obj
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:&err];
    if (!data || err) return @"{}";
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"{}";
}

- (id)parseJSONText:(NSString *)text error:(NSError **)outError {
    NSString *trim = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trim.length == 0) return @{};
    NSData *data = [trim dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"LegadoBridge" code:1
                                       userInfo:@{NSLocalizedDescriptionKey: @"编码失败"}];
        }
        return nil;
    }
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:outError];
}

- (void)loadFromCore {
    id core = [self core];
    if (!core) return;
    NSString *json = nil;
    if ([core respondsToSelector:@selector(sourceJSON:)]) {
        json = ((NSString * (*)(id, SEL, NSString *))objc_msgSend)(core, @selector(sourceJSON:), self.sourceUrl);
    }
    self.jsonView.text = json.length > 0 ? json : @"{}";

    NSDictionary *root = nil;
    if (json.length > 0) {
        NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
        id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        if ([obj isKindOfClass:[NSDictionary class]]) root = obj;
    }

    self.nameField.text = [root[@"bookSourceName"] isKindOfClass:[NSString class]] ? root[@"bookSourceName"] : @"";
    self.urlField.text = [root[@"bookSourceUrl"] isKindOfClass:[NSString class]] ? root[@"bookSourceUrl"] : (self.sourceUrl ?: @"");
    self.searchField.text = [root[@"searchUrl"] isKindOfClass:[NSString class]] ? root[@"searchUrl"] : @"";
    self.exploreField.text = [root[@"exploreUrl"] isKindOfClass:[NSString class]] ? root[@"exploreUrl"] : @"";
    self.groupField.text = [root[@"bookSourceGroup"] isKindOfClass:[NSString class]] ? root[@"bookSourceGroup"] : @"";
    self.ruleSearchView.text = [self prettyJSONObject:root[@"ruleSearch"]];
    self.ruleExploreView.text = [self prettyJSONObject:root[@"ruleExplore"]];
    self.ruleBookInfoView.text = [self prettyJSONObject:root[@"ruleBookInfo"]];
    self.ruleTocView.text = [self prettyJSONObject:root[@"ruleToc"]];
    self.ruleContentView.text = [self prettyJSONObject:root[@"ruleContent"]];
}

- (void)onModeChanged:(UISegmentedControl *)seg {
    self.mode = seg.selectedSegmentIndex;
    [self.tableView reloadData];
}

- (void)onSaveTapped {
    id core = [self core];
    if (!core) {
        [self showMessage:@"Core 未就绪"];
        return;
    }
    NSError *error = nil;
    BOOL ok = NO;
    if (self.mode == 0) {
        // 结构化：以完整 JSON 为底，写回基本字段 + 六大块规则
        NSMutableDictionary *root = nil;
        id parsed = [self parseJSONText:self.jsonView.text error:&error];
        if ([parsed isKindOfClass:[NSDictionary class]]) {
            root = [parsed mutableCopy];
        } else {
            root = [NSMutableDictionary dictionary];
        }
        root[@"bookSourceName"] = self.nameField.text ?: @"";
        root[@"bookSourceUrl"] = self.sourceUrl ?: (self.urlField.text ?: @"");
        root[@"searchUrl"] = self.searchField.text ?: @"";
        root[@"exploreUrl"] = self.exploreField.text ?: @"";
        root[@"bookSourceGroup"] = self.groupField.text ?: @"";

        NSArray *ruleKeys = @[@"ruleSearch", @"ruleExplore", @"ruleBookInfo", @"ruleToc", @"ruleContent"];
        NSArray *ruleViews = @[self.ruleSearchView, self.ruleExploreView, self.ruleBookInfoView, self.ruleTocView, self.ruleContentView];
        for (NSUInteger i = 0; i < ruleKeys.count; i++) {
            NSError *ruleErr = nil;
            id ruleObj = [self parseJSONText:((UITextView *)ruleViews[i]).text error:&ruleErr];
            if (ruleErr) {
                [self showMessage:[NSString stringWithFormat:@"%@ JSON 无效: %@", ruleKeys[i], ruleErr.localizedDescription]];
                return;
            }
            if (ruleObj) root[ruleKeys[i]] = ruleObj;
        }

        NSData *data = [NSJSONSerialization dataWithJSONObject:root options:0 error:&error];
        if (!data || error) {
            [self showMessage:error.localizedDescription ?: @"序列化失败"];
            return;
        }
        if ([core respondsToSelector:@selector(updateSourceJSON:forUrl:error:)]) {
            ok = ((BOOL (*)(id, SEL, NSData *, NSString *, NSError **))objc_msgSend)(
                core, @selector(updateSourceJSON:forUrl:error:), data, self.sourceUrl, &error
            );
        }
    } else {
        NSData *data = [self.jsonView.text dataUsingEncoding:NSUTF8StringEncoding];
        if (data.length == 0) {
            [self showMessage:@"JSON 为空"];
            return;
        }
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        if (!obj || error) {
            [self showMessage:error.localizedDescription ?: @"JSON 解析失败"];
            return;
        }
        Class coreClass = NSClassFromString(@"LegadoBridge.LegadoBridgeCore");
        BOOL isLegado = NO;
        if ([coreClass respondsToSelector:@selector(probeLegadoJSONData:)]) {
            isLegado = ((BOOL (*)(Class, SEL, NSData *))objc_msgSend)(coreClass, @selector(probeLegadoJSONData:), data);
        }
        if (!isLegado) {
            [self showMessage:@"不是合法书源 JSON"];
            return;
        }
        if ([core respondsToSelector:@selector(updateSourceJSON:forUrl:error:)]) {
            ok = ((BOOL (*)(id, SEL, NSData *, NSString *, NSError **))objc_msgSend)(
                core, @selector(updateSourceJSON:forUrl:error:), data, self.sourceUrl, &error
            );
        }
    }
    if (!ok) {
        [self showMessage:error.localizedDescription ?: @"保存失败"];
        return;
    }
    NSString *marker = [NSString stringWithFormat:@"M5 editor save ok mode=%ld url=%@", (long)self.mode, self.sourceUrl ?: @""];
    [marker writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_m5_editor_save.txt"]
              atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)showMessage:(NSString *)msg {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
                                                                   message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.mode == 0 ? 6 : 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (self.mode == 1) return 1;
    if (section == 0) return 5; // 基本：名/url/search/explore/group
    return 1; // 各大块规则 JSON
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (self.mode == 1) return @"完整 JSON";
    switch (section) {
        case 0: return @"基本";
        case 1: return @"搜索 ruleSearch";
        case 2: return @"发现 ruleExplore";
        case 3: return @"详情 ruleBookInfo";
        case 4: return @"目录 ruleToc";
        case 5: return @"正文 ruleContent";
        default: return nil;
    }
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.mode == 1) return 420;
    if (indexPath.section == 0) return 52;
    return 140;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.mode == 1) {
        static NSString *jsonId = @"LBJsonCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:jsonId];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:jsonId];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
        [self.jsonView removeFromSuperview];
        self.jsonView.frame = CGRectInset(cell.contentView.bounds, 12, 8);
        self.jsonView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [cell.contentView addSubview:self.jsonView];
        return cell;
    }

    if (indexPath.section == 0) {
        static NSString *fieldId = @"LBFieldCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:fieldId];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:fieldId];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
        for (UIView *v in [cell.contentView.subviews copy]) {
            if ([v isKindOfClass:[UITextField class]] || [v isKindOfClass:[UITextView class]]) {
                [v removeFromSuperview];
            }
        }
        UITextField *field = nil;
        switch (indexPath.row) {
            case 0: field = self.nameField; break;
            case 1: field = self.urlField; break;
            case 2: field = self.searchField; break;
            case 3: field = self.exploreField; break;
            default: field = self.groupField; break;
        }
        field.frame = CGRectInset(cell.contentView.bounds, 16, 8);
        field.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [cell.contentView addSubview:field];
        return cell;
    }

    static NSString *ruleId = @"LBRuleCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:ruleId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:ruleId];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    for (UIView *v in [cell.contentView.subviews copy]) {
        if ([v isKindOfClass:[UITextView class]]) [v removeFromSuperview];
    }
    UITextView *tv = nil;
    switch (indexPath.section) {
        case 1: tv = self.ruleSearchView; break;
        case 2: tv = self.ruleExploreView; break;
        case 3: tv = self.ruleBookInfoView; break;
        case 4: tv = self.ruleTocView; break;
        default: tv = self.ruleContentView; break;
    }
    tv.frame = CGRectInset(cell.contentView.bounds, 12, 6);
    tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [cell.contentView addSubview:tv];
    return cell;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (self.mode == 1) {
        return @"保存前校验 JSON 与 Legado 格式；通过后覆盖该源并保留本地启停。";
    }
    if (section == 5) {
        return @"六大块：基本 + 搜索/发现/详情/目录/正文。规则区填 JSON 对象。bookSourceUrl 不可改。";
    }
    return nil;
}

@end
