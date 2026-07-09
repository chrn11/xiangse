#import <UIKit/UIKit.h>
#import <objc/message.h>
#import "LegadoBridge.h"

/// Legado 书源管理页：列表展示、启用/禁用、删除、查看 JSON、继续导入
@interface LBLegadoSourceManagerVC : UITableViewController
@property (nonatomic, copy) NSArray<NSDictionary *> *sources;
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
    if (core && [core respondsToSelector:@selector(allSourcesInfo)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        info = [core performSelector:@selector(allSourcesInfo)];
#pragma clang diagnostic pop
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
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
        target:self
        action:@selector(onAddTapped)];
    [self reloadSources];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadSources];
}

#pragma mark - 操作

- (void)onAddTapped {
    LBShowLegadoImportAlert();
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

- (void)showJSONForUrl:(NSString *)url name:(NSString *)name {
    id core = LBLegadoManagerCore();
    if (!core || url.length == 0) return;
    NSString *json = nil;
    SEL sel = @selector(sourceJSON:);
    if ([core respondsToSelector:sel]) {
        json = ((NSString * (*)(id, SEL, NSString *))objc_msgSend)(core, sel, url);
    }
    if (json.length == 0) {
        json = @"(无 JSON 数据)";
    }
    NSString *title = name.length > 0 ? name : @"书源 JSON";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:json
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"复制" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        UIPasteboard.generalPasteboard.string = json;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.sources.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellId = @"LBLegadoSourceCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        UISwitch *toggle = [[UISwitch alloc] init];
        [toggle addTarget:self action:@selector(onSwitchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
    }

    NSDictionary *dict = (indexPath.row < (NSInteger)self.sources.count) ? self.sources[(NSUInteger)indexPath.row] : nil;
    NSString *name = [self sourceNameFromDict:dict];
    NSString *url = [self sourceUrlFromDict:dict];
    BOOL enabled = [self isEnabledFromDict:dict];

    cell.textLabel.text = name.length > 0 ? name : @"(未命名)";
    cell.detailTextLabel.text = url;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;

    UISwitch *toggle = (UISwitch *)cell.accessoryView;
    toggle.tag = indexPath.row;
    toggle.on = enabled;

    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
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
    if (indexPath.row >= (NSInteger)self.sources.count) return;
    NSDictionary *dict = self.sources[(NSUInteger)indexPath.row];
    NSString *url = [self sourceUrlFromDict:dict];
    NSString *name = [self sourceNameFromDict:dict];
    [self showJSONForUrl:url name:name];
}

- (void)onSwitchChanged:(UISwitch *)sender {
    NSInteger row = sender.tag;
    if (row < 0 || row >= (NSInteger)self.sources.count) return;
    NSDictionary *dict = self.sources[(NSUInteger)row];
    NSString *url = [self sourceUrlFromDict:dict];
    [self setSourceEnabled:sender.isOn forUrl:url];
}

@end
