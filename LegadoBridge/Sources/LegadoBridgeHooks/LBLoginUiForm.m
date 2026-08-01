#import "LBInternal.h"
#import <objc/message.h>

/// 真 loginUi 原生表单（对齐 Android SourceLoginDialog：字段 + 按钮 action 跑 JS）

@interface LBLoginUiFormVC : UIViewController
@property (nonatomic, copy) NSString *sourceUrl;
@property (nonatomic, strong) NSArray<NSDictionary *> *rows;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UITextField *> *fields;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIScrollView *scroll;
@end

@implementation LBLoginUiFormVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = @"书源登录";
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"关闭"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(onClose)];

    self.fields = [NSMutableDictionary dictionary];
    self.scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.scroll];

    CGFloat y = 16, w = self.view.bounds.size.width - 32;
    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(16, y, w, 40)];
    hint.numberOfLines = 0;
    hint.font = [UIFont systemFontOfSize:13];
    hint.textColor = [UIColor secondaryLabelColor];
    hint.text = @"按书源 loginUi 生成；按钮会执行 loginUrl 中的 JS（如 login()）。";
    [self.scroll addSubview:hint];
    y += 48;

    for (NSDictionary *row in self.rows) {
        NSString *name = [NSString stringWithFormat:@"%@", row[@"name"] ?: @""];
        NSString *type = [[NSString stringWithFormat:@"%@", row[@"type"] ?: @"text"] lowercaseString];
        NSString *action = [NSString stringWithFormat:@"%@", row[@"action"] ?: @""];
        if (name.length == 0) continue;

        if ([type isEqualToString:@"button"]) {
            UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
            btn.frame = CGRectMake(16, y, w, 44);
            [btn setTitle:name forState:UIControlStateNormal];
            btn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
            btn.backgroundColor = [UIColor secondarySystemBackgroundColor];
            btn.layer.cornerRadius = 8;
            objc_setAssociatedObject(btn, "lb_action", action, OBJC_ASSOCIATION_COPY_NONATOMIC);
            [btn addTarget:self action:@selector(onButton:) forControlEvents:UIControlEventTouchUpInside];
            [self.scroll addSubview:btn];
            y += 52;
        } else {
            UILabel *lab = [[UILabel alloc] initWithFrame:CGRectMake(16, y, w, 22)];
            lab.text = name;
            lab.font = [UIFont systemFontOfSize:14];
            [self.scroll addSubview:lab];
            y += 24;
            UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(16, y, w, 40)];
            tf.borderStyle = UITextBorderStyleRoundedRect;
            tf.placeholder = name;
            tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
            tf.autocorrectionType = UITextAutocorrectionTypeNo;
            if ([type isEqualToString:@"password"]) {
                tf.secureTextEntry = YES;
            }
            self.fields[name] = tf;
            [self.scroll addSubview:tf];
            y += 48;
        }
    }

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, y, w, 60)];
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.font = [UIFont systemFontOfSize:13];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    self.statusLabel.text = @"就绪";
    [self.scroll addSubview:self.statusLabel];
    y += 72;
    self.scroll.contentSize = CGSizeMake(self.view.bounds.size.width, y + 40);

    // 预填
    id core = LBLegadoCoreIfReady();
    if (core && [core respondsToSelector:@selector(loginInfoJSONForSourceUrl:)]) {
        NSString *info = ((NSString * (*)(id, SEL, NSString *))objc_msgSend)(
            core, @selector(loginInfoJSONForSourceUrl:), self.sourceUrl);
        if (info.length > 0) {
            NSData *data = [info dataUsingEncoding:NSUTF8StringEncoding];
            id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
            if ([obj isKindOfClass:[NSDictionary class]]) {
                for (NSString *k in self.fields) {
                    id v = obj[k];
                    if (v) self.fields[k].text = [NSString stringWithFormat:@"%@", v];
                }
            }
        }
    }
}

- (void)onClose {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSString *)collectFormJSON {
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    for (NSString *k in self.fields) {
        map[k] = self.fields[k].text ?: @"";
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:map options:0 error:NULL];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{}";
}

- (void)onButton:(UIButton *)sender {
    NSString *action = objc_getAssociatedObject(sender, "lb_action");
    if (action.length == 0) {
        // Android ✓：无 action 的按钮少见；「账号登录」有 login()
        action = @"login()";
    }
    NSString *form = [self collectFormJSON];
    self.statusLabel.text = [NSString stringWithFormat:@"执行中：%@ …", action];
    NSString *src = [self.sourceUrl copy];
    NSString *act = [action copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        id core = LBLegadoCoreIfReady();
        NSString *msg = @"Core 不可用";
        if (core && [core respondsToSelector:@selector(runLoginUiActionForSourceUrl:action:formJSON:)]) {
            msg = ((NSString * (*)(id, SEL, NSString *, NSString *, NSString *))objc_msgSend)(
                core, @selector(runLoginUiActionForSourceUrl:action:formJSON:), src, act, form);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.statusLabel.text = [NSString stringWithFormat:@"结果：%@", msg ?: @""];
        });
    });
}

@end

void LBPresentLoginUiFormForSource(NSString *sourceUrl) {
    if (sourceUrl.length == 0) return;
    id core = LBLegadoCoreIfReady();
    NSString *rowsJSON = @"[]";
    if (core && [core respondsToSelector:@selector(loginUiRowsJSONForSourceUrl:)]) {
        rowsJSON = ((NSString * (*)(id, SEL, NSString *))objc_msgSend)(
            core, @selector(loginUiRowsJSONForSourceUrl:), sourceUrl) ?: @"[]";
    }
    NSData *data = [rowsJSON dataUsingEncoding:NSUTF8StringEncoding];
    NSArray *rows = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    if (![rows isKindOfClass:[NSArray class]] || rows.count == 0) {
        NSString *miss = [NSString stringWithFormat:@"loginUi form empty rows src=%@", sourceUrl ?: @""];
        [miss writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_login_ui_probe.txt"]
                atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return;
    }

    void (^presentBlock)(void) = ^{
        LBLoginUiFormVC *vc = [[LBLoginUiFormVC alloc] init];
        vc.sourceUrl = sourceUrl;
        vc.rows = rows;
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
        UIWindow *win = LBLegadoKeyWindow();
        UIViewController *root = win.rootViewController;
        while (root.presentedViewController) root = root.presentedViewController;
        [root presentViewController:nav animated:YES completion:nil];
        NSString *probe = [NSString stringWithFormat:
                           @"loginUi native form src=%@ rows=%lu",
                           sourceUrl, (unsigned long)rows.count];
        [probe writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_login_ui_probe.txt"]
                 atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        NSString *open = [NSString stringWithFormat:@"open loginUiForm src=%@ rows=%lu",
                          sourceUrl, (unsigned long)rows.count];
        [open writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_visible_webview_open.txt"]
                atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    };

    if ([NSThread isMainThread]) presentBlock();
    else dispatch_async(dispatch_get_main_queue(), presentBlock);
}
