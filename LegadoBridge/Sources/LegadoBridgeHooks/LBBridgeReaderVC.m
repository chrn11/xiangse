#import <UIKit/UIKit.h>
#import "LegadoBridge.h"
#import "LBInternal.h"

/// Bridge 阅读页：仅作原生 TextReadVC 失败时的兜底；主路径应走 openReader。
@interface LBBridgeReaderVC : UIViewController
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, copy) NSString *chapterUrl;
@property (nonatomic, copy) NSString *bookUrl;
@property (nonatomic, copy, nullable) NSString *chapterTitle;
@property (nonatomic, strong, nullable) id resetObserver;
- (void)applyContentUserInfo:(NSDictionary *)userInfo;
@end

static __weak LBBridgeReaderVC *sVisibleBridgeReader = nil;

@implementation LBBridgeReaderVC

- (void)dealloc {
    if (self.resetObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:self.resetObserver];
        self.resetObserver = nil;
    }
    if (sVisibleBridgeReader == self) {
        sVisibleBridgeReader = nil;
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = self.chapterTitle.length > 0 ? self.chapterTitle : @"阅读";
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"关闭"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(lb_close)];

    UITextView *tv = [[UITextView alloc] initWithFrame:CGRectZero];
    tv.translatesAutoresizingMaskIntoConstraints = NO;
    tv.editable = NO;
    tv.selectable = YES;
    tv.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    tv.textContainerInset = UIEdgeInsetsMake(16, 12, 24, 12);
    tv.accessibilityIdentifier = @"legado_bridge_reader_text";
    tv.text = @"正在加载正文…";
    [self.view addSubview:tv];
    self.textView = tv;

    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [tv.topAnchor constraintEqualToAnchor:g.topAnchor],
        [tv.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [tv.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
        [tv.bottomAnchor constraintEqualToAnchor:g.bottomAnchor],
    ]];

    __weak typeof(self) weakSelf = self;
    self.resetObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:@"dNotifyName_ReadView_ResetContent"
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
                    [weakSelf applyContentUserInfo:note.userInfo];
                }];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    sVisibleBridgeReader = self;
    // 正文常早于 present 完成；appear 时重灌 pending
    LBBridgeReaderApplyPendingOnAppear();
}

- (void)lb_close {
    if (self.presentingViewController) {
        [self dismissViewControllerAnimated:YES completion:nil];
    } else if (self.navigationController) {
        [self.navigationController popViewControllerAnimated:YES];
    }
}

- (void)applyContentUserInfo:(NSDictionary *)userInfo {
    if (![userInfo isKindOfClass:[NSDictionary class]]) return;
    NSString *ch = userInfo[@"chapterUrl"];
    NSString *err = userInfo[@"error"];
    if ([err isKindOfClass:[NSString class]] && err.length > 0) {
        self.textView.text = [NSString stringWithFormat:@"加载失败：%@", err];
        return;
    }
    NSString *body = userInfo[@"chapterContent"];
    if (![body isKindOfClass:[NSString class]] || body.length == 0) {
        body = userInfo[@"content"];
    }
    if (![body isKindOfClass:[NSString class]] || body.length == 0) {
        self.textView.text = @"正文为空";
        return;
    }
    if (ch.length > 0) {
        self.chapterUrl = ch;
    }
    NSString *title = self.chapterTitle.length > 0 ? self.chapterTitle : @"阅读";
    self.textView.text = [NSString stringWithFormat:@"%@\n\n%@", title, body];
    self.textView.accessibilityLabel = body;
    NSString *marker = [NSString stringWithFormat:@"bridgeReader show len=%lu ch=%@",
                        (unsigned long)body.length, self.chapterUrl ?: @""];
    [marker writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_bridge_reader.txt"]
             atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

@end

static UIViewController *LBBridgeReaderHost(void) {
    // AK：经 LBLegadoKeyWindow；bg 仅弱缓存/nil（本函数由 presentBlock 主线程调用）
    UIWindow *key = LBLegadoKeyWindow();
    UIViewController *host = key.rootViewController;
    while (host.presentedViewController) {
        host = host.presentedViewController;
    }
    return host;
}

BOOL LBPresentBridgeReader(NSString *title, NSString *chapterUrl, NSString *bookUrl, NSString **outMsg) {
    if (chapterUrl.length == 0 || bookUrl.length == 0) {
        if (outMsg) *outMsg = @"bridgeReader miss: empty chapter/book";
        return NO;
    }
    void (^presentBlock)(void) = ^{
        LBBridgeReaderVC *vc = [[LBBridgeReaderVC alloc] init];
        vc.chapterUrl = chapterUrl;
        vc.bookUrl = bookUrl;
        vc.chapterTitle = title.length > 0 ? title : @"章节";
        UINavigationController *wrap =
            [[UINavigationController alloc] initWithRootViewController:vc];
        wrap.modalPresentationStyle = UIModalPresentationFullScreen;
        UIViewController *host = LBBridgeReaderHost();
        if (!host) {
            if (outMsg) *outMsg = @"bridgeReader miss: no host";
            return;
        }
        // 若已有 Bridge 阅读页，先关掉再开，避免叠多层
        if ([host isKindOfClass:[UINavigationController class]]) {
            UIViewController *top = [(UINavigationController *)host topViewController];
            if ([top isKindOfClass:[LBBridgeReaderVC class]]) {
                [(UINavigationController *)host popViewControllerAnimated:NO];
                host = LBBridgeReaderHost();
            }
        }
        if ([host isKindOfClass:[LBBridgeReaderVC class]] ||
            [NSStringFromClass([host class]) containsString:@"LBBridgeReader"]) {
            [host dismissViewControllerAnimated:NO completion:^{
                UIViewController *h2 = LBBridgeReaderHost();
                [h2 presentViewController:wrap animated:YES completion:nil];
            }];
        } else {
            [host presentViewController:wrap animated:YES completion:nil];
        }
        sVisibleBridgeReader = vc;
        NSString *marker = [NSString stringWithFormat:@"bridgeReader present title=%@ ch=%@",
                            vc.chapterTitle ?: @"", chapterUrl];
        [marker writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_bridge_reader.txt"]
                 atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    };
    if ([NSThread isMainThread]) presentBlock();
    else dispatch_async(dispatch_get_main_queue(), presentBlock);
    if (outMsg) *outMsg = @"bridgeReader present ok";
    return YES;
}

void LBBridgeReaderApplyContent(NSDictionary *userInfo) {
    if (![userInfo isKindOfClass:[NSDictionary class]]) return;
    void (^apply)(void) = ^{
        LBBridgeReaderVC *vc = sVisibleBridgeReader;
        if (!vc) return;
        [vc applyContentUserInfo:userInfo];
    };
    if ([NSThread isMainThread]) apply();
    else dispatch_async(dispatch_get_main_queue(), apply);
}
