#import <UIKit/UIKit.h>

/// 书评列表（简易 UITableView）
@interface LBBookReviewListVC : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSString *bookUrl;
@property (nonatomic, copy) NSArray<NSDictionary *> *reviews;
@end

@implementation LBBookReviewListVC {
    UITableView *_table;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = @"书评";
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"关闭"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(lb_close)];

    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _table.translatesAutoresizingMaskIntoConstraints = NO;
    _table.dataSource = self;
    _table.delegate = self;
    _table.rowHeight = UITableViewAutomaticDimension;
    _table.estimatedRowHeight = 72;
    [self.view addSubview:_table];

    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_table.topAnchor constraintEqualToAnchor:g.topAnchor],
        [_table.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [_table.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
        [_table.bottomAnchor constraintEqualToAnchor:g.bottomAnchor],
    ]];
}

- (void)lb_close {
    if (self.presentingViewController) {
        [self dismissViewControllerAnimated:YES completion:nil];
    } else if (self.navigationController) {
        [self.navigationController popViewControllerAnimated:YES];
    }
}

#pragma mark - UITableView

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.reviews.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"LBReviewCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    NSDictionary *item = self.reviews[(NSUInteger)indexPath.row];
    NSString *content = item[@"content"];
    if (![content isKindOfClass:[NSString class]]) content = @"";
    NSString *avatar = item[@"avatar"];
    if (![avatar isKindOfClass:[NSString class]]) avatar = @"";
    cell.textLabel.text = content.length > 0 ? content : @"(无内容)";
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.text = avatar.length > 0 ? avatar : @"";
    cell.detailTextLabel.numberOfLines = 1;
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
        nav.modalPresentationStyle = UIModalPresentationFormSheet;
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
            win = [UIApplication sharedApplication].windows.firstObject;
        }
        UIViewController *root = win.rootViewController;
        if (!root) {
            [@"FAIL: no rootVC" writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_reviews_present.txt"]
                                 atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            return;
        }
        while (root.presentedViewController) root = root.presentedViewController;
        [root presentViewController:nav animated:YES completion:^{
            [[NSString stringWithFormat:@"OK present reviews n=%lu", (unsigned long)rows.count]
                writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_reviews_present.txt"]
                atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        }];
    });
}
