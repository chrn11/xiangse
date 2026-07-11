#import <UIKit/UIKit.h>
#import <objc/message.h>
#import "LegadoBridge.h"

/// Legado 书源管理页：列表、启停、删除、结构化+JSON 编辑、订阅刷新、分组筛选、发现入口
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
@property (nonatomic, strong) UITextField *groupField;
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
    self.title = @"Legado 书源管理";
    if (!self.groupFilter) self.groupFilter = @"__all__";
    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                      target:self
                                                      action:@selector(onAddTapped)],
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                      target:self
                                                      action:@selector(onSubscribeRefreshTapped)],
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
                                                                   message:@"筛选后列表仅显示该组书源；发现入口也会尊重当前筛选。"
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

- (void)onExploreTapped {
    id core = LBLegadoManagerCore();
    if (!core || ![core respondsToSelector:@selector(handleExploreRequestWithSourceUrl:exploreUrl:page:)]) {
        [self showMessage:@"发现 API 未就绪"];
        return;
    }
    // 当前筛选列表中优先挑第一个带发现能力的源；否则交给 Core 扫全部可发现源
    NSString *sourceUrl = nil;
    for (NSDictionary *dict in self.sources) {
        id flag = dict[@"exploreSupported"];
        BOOL ok = [flag isKindOfClass:[NSNumber class]] ? [(NSNumber *)flag boolValue] : NO;
        if (ok) {
            sourceUrl = [self sourceUrlFromDict:dict];
            break;
        }
    }
    ((void (*)(id, SEL, NSString *, NSString *, NSInteger))objc_msgSend)(
        core,
        @selector(handleExploreRequestWithSourceUrl:exploreUrl:page:),
        sourceUrl,
        nil,
        1
    );
    [self showMessage:sourceUrl.length > 0
        ? [NSString stringWithFormat:@"已触发发现：%@", sourceUrl]
        : @"已触发发现（全部可发现源）；结果走搜索通知"];
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
        : @"暂无 Legado 书源，点右上角 + 导入（亦支持 legado:// / yuedu://）";
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

    self.nameField = [self makeField:@"书源名称"];
    self.urlField = [self makeField:@"bookSourceUrl"];
    self.urlField.enabled = NO;
    self.urlField.textColor = [UIColor secondaryLabelColor];
    self.searchField = [self makeField:@"searchUrl"];
    self.groupField = [self makeField:@"分组 bookSourceGroup"];

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

- (id)core {
    Class coreClass = NSClassFromString(@"LegadoBridge.LegadoBridgeCore");
    if (!coreClass) return nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    return [coreClass performSelector:@selector(shared)];
#pragma clang diagnostic pop
}

- (void)loadFromCore {
    id core = [self core];
    if (!core) return;
    NSString *json = nil;
    if ([core respondsToSelector:@selector(sourceJSON:)]) {
        json = ((NSString * (*)(id, SEL, NSString *))objc_msgSend)(core, @selector(sourceJSON:), self.sourceUrl);
    }
    self.jsonView.text = json.length > 0 ? json : @"{}";

    NSArray *info = nil;
    if ([core respondsToSelector:@selector(allSourcesInfo)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        info = [core performSelector:@selector(allSourcesInfo)];
#pragma clang diagnostic pop
    }
    for (NSDictionary *dict in info) {
        if (![dict isKindOfClass:[NSDictionary class]]) continue;
        NSString *url = dict[@"bookSourceUrl"];
        if (![url isEqualToString:self.sourceUrl]) continue;
        self.nameField.text = [dict[@"bookSourceName"] isKindOfClass:[NSString class]] ? dict[@"bookSourceName"] : @"";
        self.urlField.text = url;
        self.searchField.text = [dict[@"searchUrl"] isKindOfClass:[NSString class]] ? dict[@"searchUrl"] : @"";
        self.groupField.text = [dict[@"bookSourceGroup"] isKindOfClass:[NSString class]] ? dict[@"bookSourceGroup"] : @"";
        break;
    }
    if (self.urlField.text.length == 0) {
        self.urlField.text = self.sourceUrl;
    }
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
        if ([core respondsToSelector:@selector(updateStructuredFieldsForUrl:name:searchUrl:group:error:)]) {
            ok = ((BOOL (*)(id, SEL, NSString *, NSString *, NSString *, NSString *, NSError **))objc_msgSend)(
                core,
                @selector(updateStructuredFieldsForUrl:name:searchUrl:group:error:),
                self.sourceUrl,
                self.nameField.text ?: @"",
                self.searchField.text ?: @"",
                self.groupField.text ?: @"",
                &error
            );
        }
    } else {
        NSData *data = [self.jsonView.text dataUsingEncoding:NSUTF8StringEncoding];
        if (data.length == 0) {
            [self showMessage:@"JSON 为空"];
            return;
        }
        // 保存前校验
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
            [self showMessage:@"不是合法 Legado 书源 JSON"];
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
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.mode == 0 ? 4 : 1;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.mode == 1) return 360;
    return 52;
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

    static NSString *fieldId = @"LBFieldCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:fieldId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:fieldId];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    for (UIView *v in cell.contentView.subviews) {
        if ([v isKindOfClass:[UITextField class]]) [v removeFromSuperview];
    }
    UITextField *field = nil;
    switch (indexPath.row) {
        case 0: field = self.nameField; break;
        case 1: field = self.urlField; break;
        case 2: field = self.searchField; break;
        default: field = self.groupField; break;
    }
    field.frame = CGRectInset(cell.contentView.bounds, 16, 8);
    field.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [cell.contentView addSubview:field];
    return cell;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return self.mode == 0
        ? @"保存前会写回 SourceRegistry 并同步原生站点列表。bookSourceUrl 不可在此改。"
        : @"保存前校验 JSON 与 Legado 格式；通过后覆盖该源并保留本地启停。";
}

@end
