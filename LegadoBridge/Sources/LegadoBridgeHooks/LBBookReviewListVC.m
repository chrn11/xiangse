#import <UIKit/UIKit.h>

/// B7：书评列表 — 接近香色阅读附属列表（分组、行距、无系统 Subtitle 默认感）
@interface LBBookReviewListVC : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSString *bookUrl;
@property (nonatomic, copy) NSArray<NSDictionary *> *reviews;
@end

@implementation LBBookReviewListVC {
    UITableView *_table;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // 宣纸感浅底，避免纯 systemBackground 的「系统设置页」观感
    self.view.backgroundColor = [UIColor colorWithRed:0.96 green:0.94 blue:0.90 alpha:1.0];
    self.title = @"书评";
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"关闭"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(lb_close)];

    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    _table.translatesAutoresizingMaskIntoConstraints = NO;
    _table.dataSource = self;
    _table.delegate = self;
    _table.rowHeight = UITableViewAutomaticDimension;
    _table.estimatedRowHeight = 88;
    _table.backgroundColor = [UIColor clearColor];
    _table.separatorInset = UIEdgeInsetsMake(0, 16, 0, 16);
    _table.tableFooterView = [[UIView alloc] initWithFrame:CGRectZero];
    if (@available(iOS 15.0, *)) {
        _table.sectionHeaderTopPadding = 8;
    }
    [self.view addSubview:_table];

    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_table.topAnchor constraintEqualToAnchor:g.topAnchor],
        [_table.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [_table.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
        [_table.bottomAnchor constraintEqualToAnchor:g.bottomAnchor],
    ]];

    [[NSString stringWithFormat:@"reviewVC styled n=%lu ttsHidden=1\n",
      (unsigned long)self.reviews.count]
        writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_b7_review_ui.txt"]
        atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

- (void)lb_close {
    if (self.presentingViewController) {
        [self dismissViewControllerAnimated:YES completion:nil];
    } else if (self.navigationController) {
        [self.navigationController popViewControllerAnimated:YES];
    }
}

#pragma mark - UITableView

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return [NSString stringWithFormat:@"共 %lu 条", (unsigned long)self.reviews.count];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return (NSInteger)self.reviews.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"LBReviewCell.v2";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.numberOfLines = 0;
        cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
        cell.textLabel.textColor = [UIColor colorWithRed:0.18 green:0.16 blue:0.14 alpha:1.0];
        cell.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.92];
    }
    NSDictionary *item = self.reviews[(NSUInteger)indexPath.row];
    NSString *content = item[@"content"];
    if (![content isKindOfClass:[NSString class]]) content = @"";
    NSString *avatar = item[@"avatar"];
    if (![avatar isKindOfClass:[NSString class]]) avatar = @"";
    if (content.length == 0) content = @"(无内容)";
    if (avatar.length > 0) {
        cell.textLabel.text = [NSString stringWithFormat:@"%@\n%@", content, avatar];
    } else {
        cell.textLabel.text = content;
    }
    return cell;
}

@end

/// 从 JSON 字符串解析并展示书评
void LBPresentBookReviewsJSON(NSString *bookUrl, NSString *json) {
    if (bookUrl.length == 0) return;
    NSString *raw = json.length > 0 ? json : @"[]";
    NSData *data = [raw dataUsingEncoding:NSUTF8StringEncoding];
    id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    if (![obj isKindOfClass:[NSArray class]]) {
        obj = @[ @{ @"content" : raw, @"avatar" : @"", @"raw" : @"" } ];
    }
    NSArray *rows = (NSArray *)obj;
    dispatch_async(dispatch_get_main_queue(), ^{
        LBBookReviewListVC *vc = [LBBookReviewListVC new];
        vc.bookUrl = bookUrl;
        vc.reviews = rows;
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
        UIWindow *win = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            if (ws.activationState != UISceneActivationStateForegroundActive &&
                ws.activationState != UISceneActivationStateForegroundInactive) {
                continue;
            }
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow || w.rootViewController) {
                    win = w;
                    if (w.isKeyWindow) break;
                }
            }
            if (win) break;
        }
        if (!win) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            win = [UIApplication sharedApplication].windows.firstObject;
#pragma clang diagnostic pop
        }
        UIViewController *root = win.rootViewController;
        if (!root) {
            [@"FAIL: no rootVC" writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_reviews_present.txt"]
                                 atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            return;
        }
        while (root.presentedViewController) root = root.presentedViewController;
        [root presentViewController:nav animated:YES completion:^{
            [[NSString stringWithFormat:@"OK present reviews n=%lu styled=1", (unsigned long)rows.count]
                writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_reviews_present.txt"]
                atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        }];
    });
}
