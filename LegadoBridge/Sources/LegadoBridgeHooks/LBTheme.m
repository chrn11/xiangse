#import "LBInternal.h"

/// 香色自有深色模式探测 + 发现页动态配色。
/// 香色 2.56.1 的深色模式不走 iOS 系统外观（ThemeManager.darkModel / NSUserDefaults tr_darkModel），
/// 因此 UIColor.systemBackgroundColor 等自适应色在 App 内深色下仍是浅色 —— 必须按 App 自身状态取色。

/// ThemeManager 单例（存在与否/访问器名均 fail-open；访问器解析结果缓存一次）
static id LBThemeManagerInstance(void) {
    static Class tmCls = nil;
    static SEL tmSel = NULL;
    static BOOL resolved = NO;
    if (!resolved) {
        resolved = YES;
        tmCls = NSClassFromString(@"ThemeManager");
        if (tmCls) {
            for (NSString *acc in @[@"shareInstance", @"sharedInstance", @"defaultManager",
                                    @"sharedManager", @"manager", @"sharedThemeManager"]) {
                SEL sel = NSSelectorFromString(acc);
                @try {
                    if ([tmCls respondsToSelector:sel]) { tmSel = sel; break; }
                } @catch (__unused NSException *e) {}
            }
        }
    }
    if (!tmCls || !tmSel) return nil;
    @try {
        id inst = ((id (*)(id, SEL))objc_msgSend)(tmCls, tmSel);
        return inst;
    } @catch (__unused NSException *e) {}
    return nil;
}

BOOL LBAppDarkModeEnabled(void) {
    // 1) ThemeManager 实时 darkModel（最权威，跟随 App 内切换立即生效）
    @try {
        id tm = LBThemeManagerInstance();
        if (tm) {
            id v = nil;
            @try { v = [tm valueForKey:@"darkModel"]; } @catch (__unused NSException *e) {}
            if ([v respondsToSelector:@selector(boolValue)]) {
                return [v boolValue];
            }
        }
    } @catch (__unused NSException *e) {}

    // 2) 持久化阅读深色开关 tr_darkModel
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    id darkVal = [ud objectForKey:@"tr_darkModel"];

    // 3) tr_autoDarkModel：跟随系统外观
    if ([ud boolForKey:@"tr_autoDarkModel"]) {
        BOOL sysDark = NO;
        if (@available(iOS 12.0, *)) {
            UITraitCollection *tc = nil;
            @try {
                UIWindow *win = LBLegadoKeyWindow();
                tc = win.traitCollection;
            } @catch (__unused NSException *e) {}
            if (!tc && [UITraitCollection respondsToSelector:@selector(currentTraitCollection)]) {
                tc = [UITraitCollection currentTraitCollection];
            }
            sysDark = (tc && tc.userInterfaceStyle == UIUserInterfaceStyleDark);
        }
        if (sysDark) return YES;
    }

    if (darkVal) return [darkVal boolValue];
    return NO;
}

UIColor *LBDiscoverPageColor(void) {
    return LBAppDarkModeEnabled()
        ? [UIColor colorWithWhite:0.10 alpha:1]
        : [UIColor whiteColor];
}

UIColor *LBDiscoverBarColor(void) {
    return LBAppDarkModeEnabled()
        ? [UIColor colorWithWhite:0.15 alpha:1]
        : [UIColor colorWithWhite:0.97 alpha:1];
}

UIColor *LBDiscoverPrimaryTextColor(void) {
    return LBAppDarkModeEnabled()
        ? [UIColor colorWithWhite:0.92 alpha:1]
        : [UIColor colorWithWhite:0.15 alpha:1];
}

UIColor *LBDiscoverSecondaryTextColor(void) {
    return LBAppDarkModeEnabled()
        ? [UIColor colorWithWhite:0.62 alpha:1]
        : [UIColor colorWithWhite:0.45 alpha:1];
}

UIColor *LBDiscoverTertiaryTextColor(void) {
    return LBAppDarkModeEnabled()
        ? [UIColor colorWithWhite:0.55 alpha:1]
        : [UIColor colorWithWhite:0.40 alpha:1];
}

UIColor *LBDiscoverCellSelectedColor(void) {
    return LBAppDarkModeEnabled()
        ? [UIColor colorWithWhite:0.22 alpha:1]
        : [UIColor colorWithWhite:0.94 alpha:1];
}

UIColor *LBDiscoverCoverBgColor(void) {
    return LBAppDarkModeEnabled()
        ? [UIColor colorWithWhite:0.20 alpha:1]
        : [UIColor colorWithWhite:0.92 alpha:1];
}

UIColor *LBDiscoverSeparatorColor(void) {
    return LBAppDarkModeEnabled()
        ? [UIColor colorWithWhite:0.24 alpha:1]
        : [UIColor colorWithWhite:0.90 alpha:1];
}
