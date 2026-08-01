#import "LBInternal.h"
#import <objc/message.h>

/// 真 loginUi 原生表单：源名抬头 + 登录区置顶 + 其余折叠

@interface LBLoginUiFormVC : UIViewController
@property (nonatomic, copy) NSString *sourceUrl;
@property (nonatomic, copy) NSString *sourceName;
@property (nonatomic, strong) NSArray<NSDictionary *> *rows;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UITextField *> *fields;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIStackView *moreStack;
@property (nonatomic, strong) UIView *moreCard;
@property (nonatomic, strong) UIButton *moreToggle;
@property (nonatomic, assign) BOOL moreExpanded;
@end

@implementation LBLoginUiFormVC

#pragma mark - 分类

static BOOL LBLoginUiNameMatch(NSString *name, NSArray<NSString *> *keys) {
    NSString *n = name ?: @"";
    for (NSString *k in keys) {
        if ([n rangeOfString:k options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

static BOOL LBLoginUiIsCredentialField(NSDictionary *row) {
    NSString *type = [[NSString stringWithFormat:@"%@", row[@"type"] ?: @"text"] lowercaseString];
    NSString *name = [NSString stringWithFormat:@"%@", row[@"name"] ?: @""];
    if ([type isEqualToString:@"password"]) return YES;
    if (![type isEqualToString:@"text"] && ![type isEqualToString:@""] && ![type isEqualToString:@"textarea"]) {
        return NO;
    }
    static NSArray *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[ @"邮箱", @"邮件", @"账号", @"帐户", @"账户", @"用户名", @"用户", @"密码",
                  @"email", @"user", @"pass", @"phone", @"手机", @"验证码", @"token", @"cookie" ];
    });
    return LBLoginUiNameMatch(name, keys);
}

static BOOL LBLoginUiIsLoginButton(NSDictionary *row) {
    NSString *type = [[NSString stringWithFormat:@"%@", row[@"type"] ?: @""] lowercaseString];
    if (![type isEqualToString:@"button"]) return NO;
    NSString *name = [NSString stringWithFormat:@"%@", row[@"name"] ?: @""];
    static NSArray *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[ @"登录", @"登陆", @"login", @"注册", @"退出", @"登出", @"logout",
                  @"修改密码", @"清除登录", @"账号登录", @"保存账号", @"✓保存", @"✔️" ];
    });
    return LBLoginUiNameMatch(name, keys);
}

static BOOL LBLoginUiIsPrimaryLoginButton(NSDictionary *row) {
    if (!LBLoginUiIsLoginButton(row)) return NO;
    NSString *name = [NSString stringWithFormat:@"%@", row[@"name"] ?: @""];
    // 退出/清除不算主按钮
    if (LBLoginUiNameMatch(name, @[ @"退出", @"登出", @"logout", @"清除" ])) return NO;
    return LBLoginUiNameMatch(name, @[ @"登录", @"登陆", @"login", @"账号登录" ]);
}

static BOOL LBLoginUiLooksLikeSeparator(NSDictionary *row) {
    NSString *type = [[NSString stringWithFormat:@"%@", row[@"type"] ?: @""] lowercaseString];
    if (![type isEqualToString:@"button"]) return NO;
    NSString *name = [NSString stringWithFormat:@"%@", row[@"name"] ?: @""];
    if (name.length == 0) return YES;
    if ([name hasPrefix:@"↓"] || [name hasPrefix:@"="] || [name hasPrefix:@"—"] || [name hasPrefix:@"-"]) return YES;
    if ([name containsString:@"下方"] || [name containsString:@"仅在"] || [name containsString:@"切换/查询"]) return YES;
    if ([name containsString:@"专  属"] || [name containsString:@"免   费"]) return YES;
    return NO;
}

#pragma mark - UI

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.title = @"登录";
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"关闭"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(onClose)];
    self.fields = [NSMutableDictionary dictionary];
    self.moreExpanded = NO;

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:scroll];

    UIStackView *root = [[UIStackView alloc] init];
    root.axis = UILayoutConstraintAxisVertical;
    root.spacing = 14;
    root.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:root];

    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [root.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:12],
        [root.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:16],
        [root.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-16],
        [root.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [root.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-32],
    ]];

    // —— 书源抬头 ——
    UIView *header = [[UIView alloc] init];
    header.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    header.layer.cornerRadius = 12;
    header.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *headerStack = [[UIStackView alloc] init];
    headerStack.axis = UILayoutConstraintAxisVertical;
    headerStack.spacing = 4;
    headerStack.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:headerStack];
    [NSLayoutConstraint activateConstraints:@[
        [headerStack.topAnchor constraintEqualToAnchor:header.topAnchor constant:14],
        [headerStack.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:14],
        [headerStack.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-14],
        [headerStack.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-14],
    ]];

    UILabel *cap = [[UILabel alloc] init];
    cap.text = @"当前书源";
    cap.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    cap.textColor = [UIColor secondaryLabelColor];
    [headerStack addArrangedSubview:cap];

    UILabel *nameLab = [[UILabel alloc] init];
    nameLab.text = (self.sourceName.length > 0) ? self.sourceName : @"(未知书源)";
    nameLab.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
    nameLab.textColor = [UIColor labelColor];
    nameLab.numberOfLines = 2;
    [headerStack addArrangedSubview:nameLab];

    UILabel *urlLab = [[UILabel alloc] init];
    urlLab.text = self.sourceUrl ?: @"";
    urlLab.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    urlLab.textColor = [UIColor tertiaryLabelColor];
    urlLab.numberOfLines = 2;
    urlLab.lineBreakMode = NSLineBreakByCharWrapping;
    [headerStack addArrangedSubview:urlLab];
    [root addArrangedSubview:header];

    // 拆分：登录区 / 更多
    NSMutableArray *loginRows = [NSMutableArray array];
    NSMutableArray *moreRows = [NSMutableArray array];
    for (NSDictionary *row in self.rows) {
        NSString *name = [NSString stringWithFormat:@"%@", row[@"name"] ?: @""];
        if (name.length == 0) continue;
        if (LBLoginUiIsCredentialField(row) || LBLoginUiIsLoginButton(row)) {
            [loginRows addObject:row];
        } else {
            [moreRows addObject:row];
        }
    }
    // 兜底：没有任何凭据字段时，把首段连续 text/password 放进登录区
    if (loginRows.count == 0) {
        for (NSDictionary *row in self.rows) {
            NSString *type = [[NSString stringWithFormat:@"%@", row[@"type"] ?: @"text"] lowercaseString];
            NSString *name = [NSString stringWithFormat:@"%@", row[@"name"] ?: @""];
            if (name.length == 0) continue;
            if ([type isEqualToString:@"text"] || [type isEqualToString:@"password"] || [type isEqualToString:@"textarea"]) {
                [loginRows addObject:row];
            } else if ([type isEqualToString:@"button"] && loginRows.count > 0) {
                break;
            }
        }
        NSMutableSet *seen = [NSMutableSet set];
        for (NSDictionary *r in loginRows) [seen addObject:r];
        [moreRows removeAllObjects];
        for (NSDictionary *row in self.rows) {
            if (![seen containsObject:row]) [moreRows addObject:row];
        }
    }

    // —— 登录卡片 ——
    UIView *loginCard = [self cardContainer];
    UIStackView *loginStack = [self verticalStackInCard:loginCard];

    UILabel *loginTitle = [[UILabel alloc] init];
    loginTitle.text = @"账号登录";
    loginTitle.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [loginStack addArrangedSubview:loginTitle];

    UILabel *loginHint = [[UILabel alloc] init];
    loginHint.text = @"填写后点登录按钮；凭据按书源分别保存。";
    loginHint.font = [UIFont systemFontOfSize:12];
    loginHint.textColor = [UIColor secondaryLabelColor];
    loginHint.numberOfLines = 0;
    [loginStack addArrangedSubview:loginHint];

    NSInteger fieldCount = 0;
    NSInteger primaryCount = 0;
    for (NSDictionary *row in loginRows) {
        NSString *type = [[NSString stringWithFormat:@"%@", row[@"type"] ?: @"text"] lowercaseString];
        if ([type isEqualToString:@"button"]) {
            BOOL primary = LBLoginUiIsPrimaryLoginButton(row) && primaryCount == 0;
            [loginStack addArrangedSubview:[self makeButtonForRow:row primary:primary]];
            if (primary) primaryCount++;
        } else {
            [loginStack addArrangedSubview:[self makeFieldBlockForRow:row]];
            fieldCount++;
        }
    }
    if (fieldCount == 0 && primaryCount == 0) {
        UILabel *empty = [[UILabel alloc] init];
        empty.text = @"该书源未声明账号字段，可在下方「更多」操作。";
        empty.font = [UIFont systemFontOfSize:13];
        empty.textColor = [UIColor secondaryLabelColor];
        empty.numberOfLines = 0;
        [loginStack addArrangedSubview:empty];
    }

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.font = [UIFont systemFontOfSize:12];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    self.statusLabel.text = @"就绪";
    [loginStack addArrangedSubview:self.statusLabel];
    [root addArrangedSubview:loginCard];

    // —— 更多（默认折叠） ——
    if (moreRows.count > 0) {
        self.moreToggle = [UIButton buttonWithType:UIButtonTypeSystem];
        self.moreToggle.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        self.moreToggle.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        [self.moreToggle addTarget:self action:@selector(onToggleMore) forControlEvents:UIControlEventTouchUpInside];
        [self updateMoreToggleTitle:(NSInteger)moreRows.count];
        [root addArrangedSubview:self.moreToggle];

        UIView *moreCard = [self cardContainer];
        self.moreCard = moreCard;
        self.moreStack = [self verticalStackInCard:moreCard];
        for (NSDictionary *row in moreRows) {
            NSString *type = [[NSString stringWithFormat:@"%@", row[@"type"] ?: @"text"] lowercaseString];
            if ([type isEqualToString:@"button"]) {
                if (LBLoginUiLooksLikeSeparator(row)) {
                    [self.moreStack addArrangedSubview:[self makeSeparatorLabel:row]];
                } else {
                    [self.moreStack addArrangedSubview:[self makeButtonForRow:row primary:NO]];
                }
            } else {
                [self.moreStack addArrangedSubview:[self makeFieldBlockForRow:row]];
            }
        }
        moreCard.hidden = YES;
        [root addArrangedSubview:moreCard];
    }

    [self prefills];

    // 打开时就显示当前登录态证据（不依赖按钮文案）
    id coreStatus = LBLegadoCoreIfReady();
    if (coreStatus && [coreStatus respondsToSelector:@selector(loginStatusSummaryForSourceUrl:)]) {
        NSString *sum = ((NSString * (*)(id, SEL, NSString *))objc_msgSend)(
            coreStatus, @selector(loginStatusSummaryForSourceUrl:), self.sourceUrl);
        if (sum.length > 0) {
            BOOL real = [sum containsString:@"已登录痕迹"];
            self.statusLabel.textColor = real ? [UIColor systemGreenColor] : [UIColor secondaryLabelColor];
            self.statusLabel.text = [NSString stringWithFormat:@"当前：%@", sum];
        }
    }
}

- (UIView *)cardContainer {
    UIView *v = [[UIView alloc] init];
    v.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    v.layer.cornerRadius = 12;
    v.translatesAutoresizingMaskIntoConstraints = NO;
    return v;
}

- (UIStackView *)verticalStackInCard:(UIView *)card {
    UIStackView *s = [[UIStackView alloc] init];
    s.axis = UILayoutConstraintAxisVertical;
    s.spacing = 10;
    s.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:s];
    [NSLayoutConstraint activateConstraints:@[
        [s.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [s.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [s.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [s.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],
    ]];
    return s;
}

- (UIView *)makeFieldBlockForRow:(NSDictionary *)row {
    NSString *name = [NSString stringWithFormat:@"%@", row[@"name"] ?: @""];
    NSString *type = [[NSString stringWithFormat:@"%@", row[@"type"] ?: @"text"] lowercaseString];

    UIStackView *box = [[UIStackView alloc] init];
    box.axis = UILayoutConstraintAxisVertical;
    box.spacing = 6;

    UILabel *lab = [[UILabel alloc] init];
    lab.text = name;
    lab.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    lab.textColor = [UIColor secondaryLabelColor];
    [box addArrangedSubview:lab];

    UITextField *tf = [[UITextField alloc] init];
    tf.borderStyle = UITextBorderStyleNone;
    tf.backgroundColor = [UIColor tertiarySystemFillColor];
    tf.layer.cornerRadius = 10;
    tf.clipsToBounds = YES;
    tf.font = [UIFont systemFontOfSize:16];
    tf.placeholder = name;
    tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    tf.autocorrectionType = UITextAutocorrectionTypeNo;
    tf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 1)];
    tf.leftViewMode = UITextFieldViewModeAlways;
    tf.rightView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 1)];
    tf.rightViewMode = UITextFieldViewModeAlways;
    if ([type isEqualToString:@"password"]) {
        tf.secureTextEntry = YES;
        tf.textContentType = UITextContentTypePassword;
    } else if (LBLoginUiNameMatch(name, @[ @"邮箱", @"email" ])) {
        tf.keyboardType = UIKeyboardTypeEmailAddress;
        tf.textContentType = UITextContentTypeUsername;
    } else if (LBLoginUiNameMatch(name, @[ @"账号", @"用户" ])) {
        tf.textContentType = UITextContentTypeUsername;
    }
    [tf.heightAnchor constraintEqualToConstant:44].active = YES;
    self.fields[name] = tf;
    [box addArrangedSubview:tf];
    return box;
}

- (UIButton *)makeButtonForRow:(NSDictionary *)row primary:(BOOL)primary {
    NSString *name = [NSString stringWithFormat:@"%@", row[@"name"] ?: @""];
    NSString *action = [NSString stringWithFormat:@"%@", row[@"action"] ?: @""];

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    btn.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [btn setTitle:name forState:UIControlStateNormal];
    btn.layer.cornerRadius = 10;
    btn.clipsToBounds = YES;
    [btn.heightAnchor constraintEqualToConstant:46].active = YES;

    if (primary) {
        btn.backgroundColor = [UIColor systemBlueColor];
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    } else if (LBLoginUiNameMatch(name, @[ @"退出", @"登出", @"logout", @"清除" ])) {
        btn.backgroundColor = [UIColor tertiarySystemFillColor];
        [btn setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    } else {
        btn.backgroundColor = [UIColor tertiarySystemFillColor];
        [btn setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    }

    objc_setAssociatedObject(btn, "lb_action", action, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [btn addTarget:self action:@selector(onButton:) forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

- (UILabel *)makeSeparatorLabel:(NSDictionary *)row {
    UILabel *lab = [[UILabel alloc] init];
    lab.text = [NSString stringWithFormat:@"%@", row[@"name"] ?: @""];
    lab.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    lab.textColor = [UIColor tertiaryLabelColor];
    lab.textAlignment = NSTextAlignmentCenter;
    lab.numberOfLines = 2;
    return lab;
}

- (void)updateMoreToggleTitle:(NSInteger)count {
    NSString *arrow = self.moreExpanded ? @"▼" : @"▶";
    NSString *t = [NSString stringWithFormat:@"%@ 更多功能与设置（%ld）", arrow, (long)count];
    [self.moreToggle setTitle:t forState:UIControlStateNormal];
}

- (void)onToggleMore {
    self.moreExpanded = !self.moreExpanded;
    self.moreCard.hidden = !self.moreExpanded;
    [self updateMoreToggleTitle:(NSInteger)self.moreStack.arrangedSubviews.count];
}

- (void)prefills {
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
        action = @"login()";
    }
    NSString *form = [self collectFormJSON];
    NSString *btnTitle = [sender titleForState:UIControlStateNormal] ?: @"";
    self.statusLabel.text = [NSString stringWithFormat:@"执行中：%@ …", btnTitle];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    sender.enabled = NO;
    NSString *src = [self.sourceUrl copy];
    NSString *act = [action copy];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        id core = LBLegadoCoreIfReady();
        NSString *msg = @"Core 不可用";
        if (core && [core respondsToSelector:@selector(runLoginUiActionForSourceUrl:action:formJSON:)]) {
            msg = ((NSString * (*)(id, SEL, NSString *, NSString *, NSString *))objc_msgSend)(
                core, @selector(runLoginUiActionForSourceUrl:action:formJSON:), src, act, form);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            sender.enabled = YES;
            // 再读登录态摘要：loginHeader 才算真登录痕迹，不能只看 ok
            NSString *summary = @"";
            id core2 = LBLegadoCoreIfReady();
            if (core2 && [core2 respondsToSelector:@selector(loginStatusSummaryForSourceUrl:)]) {
                summary = ((NSString * (*)(id, SEL, NSString *))objc_msgSend)(
                    core2, @selector(loginStatusSummaryForSourceUrl:), src) ?: @"";
            }
            BOOL real = [summary containsString:@"已登录痕迹"];
            if (real) {
                self.statusLabel.textColor = [UIColor systemGreenColor];
                self.statusLabel.text = [NSString stringWithFormat:@"真登录证据：%@\n动作：%@", summary, msg ?: @""];
            } else {
                self.statusLabel.textColor = [UIColor systemOrangeColor];
                self.statusLabel.text = [NSString stringWithFormat:@"%@\n%@", msg ?: @"", summary];
            }
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
    NSString *sourceName = @"";
    if (core && [core respondsToSelector:@selector(sourceNameForSourceUrl:)]) {
        sourceName = ((NSString * (*)(id, SEL, NSString *))objc_msgSend)(
            core, @selector(sourceNameForSourceUrl:), sourceUrl) ?: @"";
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
        vc.sourceName = sourceName;
        vc.rows = rows;
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
        UIWindow *win = LBLegadoKeyWindow();
        UIViewController *root = win.rootViewController;
        while (root.presentedViewController) root = root.presentedViewController;
        [root presentViewController:nav animated:YES completion:nil];
        NSString *probe = [NSString stringWithFormat:
                           @"loginUi native form v2 src=%@ name=%@ rows=%lu",
                           sourceUrl, sourceName, (unsigned long)rows.count];
        [probe writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_login_ui_probe.txt"]
                 atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        NSString *open = [NSString stringWithFormat:@"open loginUiForm v2 src=%@ name=%@ rows=%lu",
                          sourceUrl, sourceName, (unsigned long)rows.count];
        [open writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_visible_webview_open.txt"]
                atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    };

    if ([NSThread isMainThread]) presentBlock();
    else dispatch_async(dispatch_get_main_queue(), presentBlock);
}
