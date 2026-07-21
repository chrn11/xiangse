#import "LBForensics.h"
#import "fishhook.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <pthread.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <unistd.h>
#import <stdio.h>
#import <time.h>
#import <stdatomic.h>
#import <string.h>

extern NSString *LBForensicsPointer(id obj);
extern NSString *LBForensicsUTCNowString(void);
extern NSString *LBForensicsManifestSHAPrefix(void);
extern Class LBForensicsMethodOwnerClass(Class cls, SEL sel);
extern NSDictionary *LBForensicsBuildObjectGraph(void);
extern NSString *LBForensicsBuildObjectGraphText(NSDictionary *graph);
extern NSDictionary *LBForensicsBuildMethodOwners(void);
extern NSString *LBForensicsBuildMethodOwnersText(NSDictionary *methods);

static NSMutableArray<NSDictionary *> *g_observerEvents = nil;
static NSMutableDictionary<NSString *, NSDictionary *> *g_lifecycleSnapshots = nil;
static NSMutableDictionary<NSString *, NSValue *> *g_origIMPs = nil;
static NSMutableSet<NSString *> *g_installedKeys = nil;
static uint64_t g_eventSeq = 0;
static BOOL g_firstDrawSeen = NO;
static NSString *g_pendingDumpPhase = nil;
static pthread_mutex_t g_forensicsLock = PTHREAD_MUTEX_INITIALIZER;
static dispatch_queue_t g_autoDumpQueue = NULL;
static NSMutableDictionary<NSString *, NSValue *> *g_earlyNextIMPs = nil;
static NSMutableDictionary<NSString *, NSValue *> *g_earlyOrigIMPs = nil;
static IMP (*g_orig_method_setImplementation)(Method, IMP) = NULL;
static BOOL g_installingEarlyWrap = NO;
static _Thread_local int g_earlyWrapDepth = 0;

/// AO：LBFHook / early-wrap 在 QF→postQF 窗的命中与重入
static atomic_int g_aoLBFHit = 0;
static atomic_int g_aoLBFMaxDepth = 0;
static atomic_int g_aoLBFReenter = 0;
static atomic_int g_aoLBFQuietSkip = 0;
static atomic_int g_aoInQF = 0;
static atomic_int g_aoPostQF = 0;
static atomic_int g_aoRecordQuiet = 0;
static _Thread_local int g_aoLBFDepth = 0;

/// BC：forensics 侧 main runloop drain 探针全局。
/// baseline-debug 不带 LegadoBridge，main_drain/qf_enter 探针采不到。
/// 本探针装在 forensics debug dylib，baseline 也能采 main 排空证据，
/// 补齐 baseline-runtime-qf-main-diff §5.1 缺口（原版 main 排空 probable -> confirmed）。
static atomic_int g_bcMainDrainSeen = 0;
static atomic_int g_bcMainRlBeforeWaiting = 0;
static atomic_int g_bcMainRlBeforeSources = 0;
static atomic_int g_bcMainSamplerStarted = 0;
static CFRunLoopObserverRef g_bcMainRlObserver = NULL;

static void LBFEarlyWrap_viewDidLoad(id self, SEL _cmd);
static void LBFEarlyWrap_loadCurCp(id self, SEL _cmd);
static void LBFWriteHookPing(NSString *line);
static void LBFBCStartMainDrainSampler(void);

static void LBFInitObserverGlobals(void);
static BOOL LBFInstallHookOnMethod(Class owner, NSString *ownerName, NSString *selName);
static void LBFRecordEvent(NSString *when, id selfObj, SEL sel, NSArray<NSString *> *argShapes,
                           NSString *returnShape, NSString *ownerClassName);
static IMP LBFGetOrigIMP(NSString *owner, SEL sel);

static NSString *LBFOrigKey(NSString *owner, NSString *sel) {
    return [NSString stringWithFormat:@"%@|%@", owner, sel];
}

static NSString *LBFThreadLabel(void) {
    if ([NSThread isMainThread]) return @"main";
    return [NSString stringWithFormat:@"bg-%@", [NSThread currentThread].name ?: @"?"];
}

/// AI：forensics 侧短探针（与 legado_ab_probe 同行格式，便于验收扫）
static void LBFAISyncProbe(NSString *tag) {
    if (tag.length == 0) return;
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_ab_probe.txt"];
    const char *cpath = path.fileSystemRepresentation;
    if (!cpath) return;
    char buf[512];
    time_t now = time(NULL);
    struct tm tm;
    localtime_r(&now, &tm);
    int n = snprintf(buf, sizeof(buf),
                     "%04d-%02d-%02d %02d:%02d:%02d | hypothesis_AC %s main=%d\n",
                     tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
                     tm.tm_hour, tm.tm_min, tm.tm_sec,
                     tag.UTF8String ?: "?",
                     [NSThread isMainThread] ? 1 : 0);
    if (n <= 0) return;
    if (n >= (int)sizeof(buf)) n = (int)sizeof(buf) - 1;
    int fd = open(cpath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        (void)write(fd, buf, (size_t)n);
        (void)fsync(fd);
        close(fd);
    }
}

static NSString *LBFShapeOfObject(id obj) {
    if (!obj) return @"null";
    return NSStringFromClass(object_getClass(obj)) ?: @"?";
}

static BOOL LBFIsReadVCClassName(NSString *cn) {
    if (!cn.length) return NO;
    if ([cn isEqualToString:@"TextReadVC3"] || [cn hasPrefix:@"TextReadVC"]) return YES;
    if ([cn hasPrefix:@"ReadVCBase"]) return YES;
    return NO;
}

static NSString *LBFAutoDumpPhaseForSelector(NSString *selName) {
    if ([selName isEqualToString:@"viewDidLoad"]) return @"auto_after_viewDidLoad";
    if ([selName isEqualToString:@"loadCurCp"]) return @"auto_after_loadCurCp";
    return nil;
}

static NSString *LBFAutoBeforePhaseForSelector(NSString *selName) {
    if ([selName isEqualToString:@"viewDidLoad"]) return @"auto_before_viewDidLoad";
    if ([selName isEqualToString:@"loadCurCp"]) return @"auto_before_loadCurCp";
    return nil;
}

static UIViewController *LBFFrontmostPresentedVC(UIViewController *root) {
    if (!root) return nil;
    UIViewController *vc = root;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if ([vc isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)vc;
        return nav.viewControllers.lastObject ?: vc;
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        UITabBarController *tab = (UITabBarController *)vc;
        UIViewController *sel = tab.selectedViewController;
        return LBFFrontmostPresentedVC(sel) ?: vc;
    }
    return vc;
}

static BOOL LBFVCHierarchyContains(UIViewController *root, UIViewController *target,
                                   NSMutableSet<NSValue *> *seen) {
    if (!root || !target) return NO;
    NSValue *key = [NSValue valueWithNonretainedObject:root];
    if ([seen containsObject:key]) return NO;
    [seen addObject:key];
    if (root == target) return YES;
    if (root.presentedViewController &&
        LBFVCHierarchyContains(root.presentedViewController, target, seen)) return YES;
    for (UIViewController *ch in root.childViewControllers) {
        if (LBFVCHierarchyContains(ch, target, seen)) return YES;
    }
    if ([root isKindOfClass:[UINavigationController class]]) {
        for (UIViewController *n in ((UINavigationController *)root).viewControllers) {
            if (LBFVCHierarchyContains(n, target, seen)) return YES;
        }
    }
    if ([root isKindOfClass:[UITabBarController class]]) {
        for (UIViewController *t in ((UITabBarController *)root).viewControllers) {
            if (LBFVCHierarchyContains(t, target, seen)) return YES;
        }
    }
    return NO;
}

static NSDictionary *LBFGatherAutoDumpUIHints(id triggerVC) {
    NSMutableDictionary *hints = [NSMutableDictionary dictionary];
    NSString *triggerClass = LBFShapeOfObject(triggerVC);
    hints[@"triggerVC"] = @{
        @"address": LBForensicsPointer(triggerVC),
        @"class": triggerClass ?: @"?",
    };
    // AK：非主线程禁止任何 windows API
    if (![NSThread isMainThread]) {
        LBFAISyncProbe(@"hypothesis_AK ak_bg_windows_api_skip caller=LBFGatherAutoDumpUIHints");
        hints[@"windows"] = @[];
        hints[@"triggerOnAnyWindow"] = @NO;
        hints[@"ak_bg_windows_skipped"] = @YES;
        return hints;
    }
    UIApplication *app = UIApplication.sharedApplication;
    NSMutableArray *windows = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
        }
    }
    if (windows.count == 0 && app.keyWindow) [windows addObject:app.keyWindow];

    NSMutableArray *winRows = [NSMutableArray array];
    BOOL onAnyWindow = NO;
    for (UIWindow *win in windows) {
        UIViewController *root = win.rootViewController;
        UIViewController *front = LBFFrontmostPresentedVC(root);
        NSMutableSet<NSValue *> *seen = [NSMutableSet set];
        BOOL onWin = triggerVC && root &&
            LBFVCHierarchyContains(root, (UIViewController *)triggerVC, seen);
        if (onWin) onAnyWindow = YES;
        BOOL frontIsTrigger = (front == triggerVC);
        [winRows addObject:@{
            @"window": LBForensicsPointer(win),
            @"isKeyWindow": @(win.isKeyWindow),
            @"frontmostVC": front ? @{
                @"address": LBForensicsPointer(front),
                @"class": LBFShapeOfObject(front),
            } : [NSNull null],
            @"triggerOnWindow": @(onWin),
            @"triggerIsFrontmost": @(frontIsTrigger),
        }];
    }
    hints[@"windows"] = winRows;
    hints[@"triggerOnAnyWindow"] = @(onAnyWindow);
    return hints;
}

static void LBFScheduleAutoDumpPhase(id triggerVC, NSString *phase) {
    if (!phase.length || !triggerVC) return;
    if (![NSThread isMainThread]) {
        LBFWriteHookPing([NSString stringWithFormat:@"skip dump %@ (not main)", phase]);
        return;
    }
    if (!g_autoDumpQueue) {
        g_autoDumpQueue = dispatch_queue_create("com.legado.forensics.autodump", DISPATCH_QUEUE_SERIAL);
    }
    NSDictionary *uiHints = LBFGatherAutoDumpUIHints(triggerVC);
    NSDictionary *dump = nil;
    @try {
        dump = LBForensicsPerformDump(phase);
    } @catch (__unused NSException *e) {
        dump = nil;
    }
    if (!dump) return;
    NSMutableDictionary *merged = [dump mutableCopy];
    merged[@"autoDumpHints"] = uiHints;
    merged[@"liveCapture"] = @{
        @"triggerClass": LBFShapeOfObject(triggerVC),
        @"triggerAddress": LBForensicsPointer(triggerVC),
        @"capturedOnMain": @YES,
        @"phase": phase ?: @"?",
    };
    NSDictionary *finalDump = [merged copy];
    dispatch_async(g_autoDumpQueue, ^{
        @try {
            LBForensicsWriteDumpFiles(finalDump);
        } @catch (__unused NSException *e) {}
    });
}

static void LBFScheduleAutoDump(id triggerVC, NSString *phase) {
    LBFScheduleAutoDumpPhase(triggerVC, phase);
}

static void LBFMaybeScheduleBeforeDump(id selfObj, SEL sel) {
    NSString *phase = LBFAutoBeforePhaseForSelector(NSStringFromSelector(sel));
    if (!phase) return;
    if (!LBFIsReadVCClassName(LBFShapeOfObject(selfObj))) return;
    LBFScheduleAutoDumpPhase(selfObj, phase);
}

static void LBFMaybeScheduleAutoDump(id selfObj, SEL sel, NSString *ownerClassName) {
    NSString *selName = NSStringFromSelector(sel);
    NSString *phase = LBFAutoDumpPhaseForSelector(selName);
    if (!phase) return;
    NSString *objClass = LBFShapeOfObject(selfObj);
    if (!LBFIsReadVCClassName(objClass)) return;
    (void)ownerClassName;
    LBFScheduleAutoDumpPhase(selfObj, phase);
}

static IMP LBFEarlyWrapperForSelectorName(NSString *selName) {
    if ([selName isEqualToString:@"viewDidLoad"]) return (IMP)LBFEarlyWrap_viewDidLoad;
    if ([selName isEqualToString:@"loadCurCp"]) return (IMP)LBFEarlyWrap_loadCurCp;
    return NULL;
}

static void LBFEnsureOrigMethodSetIMP(void) {
    if (!g_orig_method_setImplementation) {
        g_orig_method_setImplementation =
            (IMP (*)(Method, IMP))dlsym(RTLD_NEXT, "method_setImplementation");
    }
}

static NSString *LBFEarlyWrapKey(NSString *clsName, NSString *selName) {
    return [NSString stringWithFormat:@"early|%@|%@", clsName, selName];
}

static void LBFInitEarlyWrapGlobals(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!g_earlyNextIMPs) g_earlyNextIMPs = [NSMutableDictionary dictionary];
        if (!g_earlyOrigIMPs) g_earlyOrigIMPs = [NSMutableDictionary dictionary];
    });
}

static Class LBFClassForInstanceMethod(Method m, SEL sel) {
    if (!m) return Nil;
    NSArray<NSString *> *names = @[
        @"TextReadVC3", @"TextReadVC2", @"TextReadVC1",
        @"ReadVCBase2", @"ReadVCBase1", @"ReadVCBase",
    ];
    for (NSString *cn in names) {
        Class cls = objc_getClass(cn.UTF8String);
        if (!cls) cls = NSClassFromString(cn);
        if (cls && class_getInstanceMethod(cls, sel) == m) return cls;
    }
    int n = objc_getClassList(NULL, 0);
    if (n <= 0) return Nil;
    Class *buf = (Class *)calloc((size_t)n, sizeof(Class));
    if (!buf) return Nil;
    objc_getClassList(buf, n);
    Class found = Nil;
    for (int i = 0; i < n; i++) {
        const char *name = class_getName(buf[i]);
        if (!name) continue;
        if (strstr(name, "TextReadVC") == NULL && strstr(name, "ReadVCBase") == NULL) continue;
        if (class_getInstanceMethod(buf[i], sel) == m) {
            found = buf[i];
            break;
        }
    }
    free(buf);
    return found;
}

/// 拦截生产 Bridge 的 method_setImplementation，在 viewDidLoad/loadCurCp 安装时同步套上 forensics wrapper
static IMP LBFReplaced_method_setImplementation(Method m, IMP imp) {
    LBFEnsureOrigMethodSetIMP();
    if (!g_installingEarlyWrap && m && imp) {
        SEL sel = method_getName(m);
        NSString *selName = NSStringFromSelector(sel);
        IMP wrapper = LBFEarlyWrapperForSelectorName(selName);
        if (wrapper && imp != wrapper) {
            Class cls = LBFClassForInstanceMethod(m, sel);
            NSString *cn = cls ? NSStringFromClass(cls) : @"";
            if (LBFIsReadVCClassName(cn)) {
                LBFInitEarlyWrapGlobals();
                NSString *key = LBFEarlyWrapKey(cn, selName);
                g_earlyNextIMPs[key] = [NSValue valueWithPointer:imp];
                imp = wrapper;
                LBFWriteHookPing([NSString stringWithFormat:@"intercept wrap %@ %@", cn, selName]);
            }
        }
    }
    return g_orig_method_setImplementation(m, imp);
}

static void LBFEnsureMethodSetHook(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        struct rebinding rebind = {
            .name = "method_setImplementation",
            .replacement = (void *)LBFReplaced_method_setImplementation,
            .replaced = (void **)&g_orig_method_setImplementation,
        };
        rebind_symbols(&rebind, 1);
        LBFWriteHookPing(@"fishhook method_setImplementation");
    });
}

static IMP LBFEarlyNextIMP(id self, SEL sel) {
    NSString *selName = NSStringFromSelector(sel);
    Class cls = object_getClass(self);
    while (cls) {
        NSString *key = LBFEarlyWrapKey(NSStringFromClass(cls), selName);
        NSValue *v = g_earlyNextIMPs[key];
        if (v) return (IMP)v.pointerValue;
        cls = class_getSuperclass(cls);
    }
    return NULL;
}

static BOOL LBFEnsureEarlyWrap(Class cls, NSString *selName) {
    if (!cls || !selName.length) return NO;
    LBFInitEarlyWrapGlobals();
    LBFInitObserverGlobals();

    SEL sel = NSSelectorFromString(selName);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;

    IMP wrapper = LBFEarlyWrapperForSelectorName(selName);
    if (!wrapper) return NO;

    NSString *clsName = NSStringFromClass(cls);
    NSString *key = LBFEarlyWrapKey(clsName, selName);
    IMP current = method_getImplementation(m);
    if (current == wrapper) return YES;

    g_earlyNextIMPs[key] = [NSValue valueWithPointer:current];
    if (!g_earlyOrigIMPs[key]) {
        g_earlyOrigIMPs[key] = [NSValue valueWithPointer:current];
    }
    LBFEnsureOrigMethodSetIMP();
    g_installingEarlyWrap = YES;
    g_orig_method_setImplementation(m, wrapper);
    g_installingEarlyWrap = NO;
    return YES;
}

static void LBFEarlyWrapDiscoverAndInstall(void) {
    LBFInitEarlyWrapGlobals();
    /// BC：loadCurCp 实现在 ReadPageContainer（见 baseline-runtime-qf-main-diff §2），
    /// 不在 TextReadVC* 上。early wrap 必须覆盖 ReadPageContainer 才能拦到 loadCurCp，
    /// BC main drain 探针才能在 baseline 路径触发。
    NSArray<NSString *> *names = @[
        @"TextReadVC3", @"TextReadVC2", @"TextReadVC1",
        @"ReadVCBase2", @"ReadVCBase1", @"ReadVCBase",
        @"ReadPageContainer", @"TextRPageContainer", @"TextRPageContainerPage",
    ];
    for (NSString *cn in names) {
        Class cls = objc_getClass(cn.UTF8String);
        if (!cls) cls = NSClassFromString(cn);
        if (!cls) continue;
        LBFEnsureEarlyWrap(cls, @"viewDidLoad");
        LBFEnsureEarlyWrap(cls, @"loadCurCp");
    }
    int n = objc_getClassList(NULL, 0);
    if (n <= 0) return;
    Class *buf = (Class *)calloc((size_t)n, sizeof(Class));
    if (!buf) return;
    objc_getClassList(buf, n);
    for (int i = 0; i < n; i++) {
        const char *name = class_getName(buf[i]);
        if (!name) continue;
        /// BC：补 ReadPageContainer/TextRPageContainer，匹配 loadCurCp 实现类。
        if (strstr(name, "TextReadVC") == NULL
            && strstr(name, "ReadVCBase") == NULL
            && strstr(name, "ReadPageContainer") == NULL
            && strstr(name, "TextRPageContainer") == NULL) continue;
        LBFEnsureEarlyWrap(buf[i], @"viewDidLoad");
        LBFEnsureEarlyWrap(buf[i], @"loadCurCp");
    }
    free(buf);
}

static void LBFEarlyWrap_viewDidLoad(id self, SEL _cmd) {
    if (g_earlyWrapDepth > 0) {
        IMP next = LBFEarlyNextIMP(self, _cmd);
        if (next) ((void (*)(id, SEL))next)(self, _cmd);
        return;
    }
    g_earlyWrapDepth++;
    NSString *owner = NSStringFromClass(object_getClass(self));
    LBFWriteHookPing([NSString stringWithFormat:@"early before viewDidLoad %@", owner]);
    LBFRecordEvent(@"before", self, _cmd, @[], @"void", owner);
    LBFMaybeScheduleBeforeDump(self, _cmd);
    IMP next = LBFEarlyNextIMP(self, _cmd);
    @try {
        if (next) ((void (*)(id, SEL))next)(self, _cmd);
    } @catch (NSException *ex) {
        LBFRecordEvent(@"after", self, _cmd, @[], @"void", owner);
        LBFMaybeScheduleAutoDump(self, _cmd, owner);
        g_earlyWrapDepth--;
        @throw ex;
    }
    LBFRecordEvent(@"after", self, _cmd, @[], @"void", owner);
    LBFMaybeScheduleAutoDump(self, _cmd, owner);
    g_earlyWrapDepth--;
}

static void LBFEarlyWrap_loadCurCp(id self, SEL _cmd) {
    if (g_earlyWrapDepth > 0) {
        IMP next = LBFEarlyNextIMP(self, _cmd);
        if (next) ((void (*)(id, SEL))next)(self, _cmd);
        return;
    }
    g_earlyWrapDepth++;
    NSString *owner = NSStringFromClass(object_getClass(self));
    LBFWriteHookPing([NSString stringWithFormat:@"early before loadCurCp %@", owner]);
    LBFRecordEvent(@"before", self, _cmd, @[], @"void", owner);
    LBFMaybeScheduleBeforeDump(self, _cmd);
    IMP next = LBFEarlyNextIMP(self, _cmd);
    @try {
        if (next) ((void (*)(id, SEL))next)(self, _cmd);
    } @catch (NSException *ex) {
        LBFRecordEvent(@"after", self, _cmd, @[], @"void", owner);
        LBFMaybeScheduleAutoDump(self, _cmd, owner);
        g_earlyWrapDepth--;
        @throw ex;
    }
    LBFRecordEvent(@"after", self, _cmd, @[], @"void", owner);
    LBFMaybeScheduleAutoDump(self, _cmd, owner);
    /// BC：loadCurCp 返回后启动 main drain 采样。
    /// 原版正常阅读：loadCurCp 异步发起 queryCpFileByBook 后立即返回，main RunLoop 活跃，
    /// dispatch_async(main) 的 QF 块会被调度 -> drain=1 wait>0 src>0。
    /// Legado 路径：invoke orig 返回后 main 不排空 -> drain=0 wait=0 src=0（AF/AI/AJ confirmed）。
    /// 本探针在 forensics 层，baseline 也能采，直接对照。
    if ([NSThread isMainThread]) {
        LBFBCStartMainDrainSampler();
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            LBFBCStartMainDrainSampler();
        });
    }
    g_earlyWrapDepth--;
}

/// BC：main runloop drain 采样器（forensics 层，baseline 也可用）。
/// 设计：
/// 1. CFRunLoopObserver 监听 main runloop BeforeWaiting/BeforeSources，计数 wait/src。
/// 2. dispatch_async(main) 投 drain slot，若 main 排空则 slot 执行 -> drain=1。
/// 3. bg 线程轮询 2.5s，每 100ms 写一次 watch 行；slot 执行后提前结束。
/// 对照 baseline（原版正常阅读，drain=1 wait>0 src>0）vs legado（drain=0 wait=0 src=0）。
static void LBFBCMainRlObserverCallback(CFRunLoopObserverRef observer,
                                        CFRunLoopActivity activity, void *info) {
    (void)observer; (void)info;
    if (activity & kCFRunLoopBeforeWaiting) {
        atomic_store(&g_bcMainRlBeforeWaiting, atomic_load(&g_bcMainRlBeforeWaiting) + 1);
    }
    if (activity & kCFRunLoopBeforeSources) {
        atomic_store(&g_bcMainRlBeforeSources, atomic_load(&g_bcMainRlBeforeSources) + 1);
    }
}

static void LBFBCEnsureMainRlObserver(void) {
    if (g_bcMainRlObserver) return;
    CFRunLoopObserverContext ctx = {0, NULL, NULL, NULL, NULL};
    CFRunLoopObserverRef obs = CFRunLoopObserverCreate(
        kCFAllocatorDefault,
        kCFRunLoopBeforeSources | kCFRunLoopBeforeWaiting,
        1, // repeats
        0, // order
        LBFBCMainRlObserverCallback,
        &ctx);
    if (!obs) return;
    CFRunLoopAddObserver(CFRunLoopGetMain(), obs, kCFRunLoopCommonModes);
    g_bcMainRlObserver = obs;
}

static void LBFBCStartMainDrainSampler(void) {
    int expected = 0;
    if (!atomic_compare_exchange_strong(&g_bcMainSamplerStarted, &expected, 1)) {
        // 已在采样，不重复启动；但重置 drain slot 以便新一轮观察。
        atomic_store(&g_bcMainDrainSeen, 0);
        LBFAISyncProbe(@"bc_main_drain_restart");
        return;
    }
    LBFBCEnsureMainRlObserver();
    atomic_store(&g_bcMainDrainSeen, 0);
    LBFAISyncProbe(@"bc_main_drain_start");
    /// 投 drain slot：若 main runloop 排空则执行 -> drain=1。
    dispatch_async(dispatch_get_main_queue(), ^{
        atomic_store(&g_bcMainDrainSeen, 1);
        LBFAISyncProbe([NSString stringWithFormat:
                        @"bc_main_drain_slot wait=%d src=%d",
                        atomic_load(&g_bcMainRlBeforeWaiting),
                        atomic_load(&g_bcMainRlBeforeSources)]);
    });
    /// bg 轮询 2.5s，每 100ms 写 watch 行。
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        for (int i = 0; i < 25; i++) {
            usleep(100000); // 100ms
            int drained = atomic_load(&g_bcMainDrainSeen);
            int waitN = atomic_load(&g_bcMainRlBeforeWaiting);
            int srcN = atomic_load(&g_bcMainRlBeforeSources);
            LBFAISyncProbe([NSString stringWithFormat:
                            @"bc_main_drain_watch i=%d drain=%d wait=%d src=%d",
                            i, drained, waitN, srcN]);
            if (drained && waitN > 0) {
                LBFAISyncProbe([NSString stringWithFormat:
                                @"bc_main_drain_done i=%d", i]);
                break;
            }
        }
        LBFAISyncProbe([NSString stringWithFormat:
                        @"bc_main_drain_end drain=%d wait=%d src=%d",
                        atomic_load(&g_bcMainDrainSeen),
                        atomic_load(&g_bcMainRlBeforeWaiting),
                        atomic_load(&g_bcMainRlBeforeSources)]);
    });
}

/// AQ：撤 LBFScheduleEarlyWrapRetry 的 50ms 无限递归。
/// 该递归每次跑 objc_getClassList 全表 + dispatch_sync(main) 隐患，是 main 阻塞最高候选。
/// 本刀仅保留首次安装（DiscoverAndInstall + InstallObservers），不再 dispatch_after 自递归。
static void LBFScheduleEarlyWrapRetry(void) {
    LBFEarlyWrapDiscoverAndInstall();
    LBForensicsInstallObservers();
    LBFWriteHookPing(@"aq_early_wrap_retry_disabled no_recursion");
}

static void LBFWriteHookPing(NSString *line) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *doc = paths.firstObject ?: NSTemporaryDirectory();
    NSString *path = [doc stringByAppendingPathComponent:@"forensics_hook_ping.txt"];
    NSString *body = [NSString stringWithFormat:@"%@ | %@\n", LBForensicsUTCNowString(), line ?: @""];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[body dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } else {
        [body writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

static NSString *LBFPhaseHintForSelector(NSString *selName, NSString *when) {
    if ([selName isEqualToString:@"viewDidLoad"]) {
        return [when isEqualToString:@"before"] ? @"before_viewDidLoad" : @"after_viewDidLoad";
    }
    if ([selName isEqualToString:@"viewWillAppear:"]) {
        return [when isEqualToString:@"before"] ? @"before_viewWillAppear" : @"after_viewWillAppear";
    }
    if ([selName isEqualToString:@"loadCurCp"]) {
        return [when isEqualToString:@"before"] ? @"before_loadCurCp" : @"after_loadCurCp";
    }
    if ([selName containsString:@"ResetContent"] || [selName containsString:@"resetContentNotify"]) {
        return [when isEqualToString:@"before"] ? @"before_ResetContent" : @"after_ResetContent";
    }
    if ([selName hasPrefix:@"division"] || [selName hasPrefix:@"onDivisionTextFinish"]) {
        return [when isEqualToString:@"before"] ? @"before_pagination" : @"after_pagination";
    }
    if ([selName isEqualToString:@"drawRect:"]) {
        if (!g_firstDrawSeen && [when isEqualToString:@"before"]) {
            return @"before_first_draw";
        }
        if ([when isEqualToString:@"after"]) {
            return g_firstDrawSeen ? @"after_draw" : @"after_first_draw";
        }
    }
    return [NSString stringWithFormat:@"%@_%@", when, selName];
}

static void LBFRawAOHookMark(const char *line) {
    if (!line || !line[0]) return;
    size_t n = strlen(line);
    int fd = open("/tmp/legado_ao_lbf.txt", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        (void)write(fd, line, n);
        (void)write(fd, "\n", 1);
        (void)fsync(fd);
        close(fd);
    }
    const char *home = getenv("HOME");
    if (home && home[0]) {
        char path[512];
        snprintf(path, sizeof(path), "%s/Documents/legado_ao_lbf.txt", home);
        fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) {
            (void)write(fd, line, n);
            (void)write(fd, "\n", 1);
            (void)fsync(fd);
            close(fd);
        }
    }
}

static void LBFRecordEvent(NSString *when, id selfObj, SEL sel, NSArray<NSString *> *argShapes,
                           NSString *returnShape, NSString *ownerClassName) {
    BOOL isBefore = [when isEqualToString:@"before"];
    BOOL isAfter = [when isEqualToString:@"after"];
    int inWin = atomic_load(&g_aoInQF) || atomic_load(&g_aoPostQF);
    // AR：QF/postQF 窗 depth 守卫 -- before 先增 depth（保证 after 能对称减），
    // depth > 阈值则 short-circuit 不写事件/不记 hit，
    // 避免深递归下 NSDictionary/LBForensicsUTCNowString 触发 CFRetain 风暴（AO depth=4864 SIGSEGV@CFRetain）。
    // 这不是盲静默（AO quiet 已试过失败）：quiet 砍写事件但仍进 trampoline 记 hit；
    // AR 砍的是 depth 增长后的 forensics 写事件开销，trampoline 仍调 orig 保留功能。
    // after 始终减 depth（对称），depth > 阈值则不写事件。
    int depthNow = g_aoLBFDepth;
    if (isBefore) {
        depthNow = ++g_aoLBFDepth;
    }
    BOOL depthGuard = inWin && depthNow > 8;
    if (isBefore && inWin) {
        if (!depthGuard) {
            int hit = atomic_fetch_add(&g_aoLBFHit, 1) + 1;
            if (depthNow > 1) atomic_fetch_add(&g_aoLBFReenter, 1);
            int curMax = atomic_load(&g_aoLBFMaxDepth);
            while (depthNow > curMax &&
                   !atomic_compare_exchange_weak(&g_aoLBFMaxDepth, &curMax, depthNow)) {
            }
            // 每 64 次 before 打一拍，避免刷屏
            if ((hit & 63) == 0) {
                char mark[224];
                snprintf(mark, sizeof(mark),
                         "ao_lbf_hook hit=%d depth=%d maxDepth=%d reenter=%d "
                         "inQF=%d postQF=%d quiet=%d arDepthGuardSkip=%d",
                         hit, depthNow, atomic_load(&g_aoLBFMaxDepth),
                         atomic_load(&g_aoLBFReenter),
                         atomic_load(&g_aoInQF), atomic_load(&g_aoPostQF),
                         atomic_load(&g_aoRecordQuiet),
                         atomic_load(&g_aoLBFQuietSkip));
                char raw[244];
                snprintf(raw, sizeof(raw), "hypothesis_AC %s", mark);
                LBFRawAOHookMark(raw);
                LBFAISyncProbe([NSString stringWithUTF8String:mark]);
            }
        } else {
            atomic_fetch_add(&g_aoLBFQuietSkip, 1);
        }
    }

    if (depthGuard) {
        // depth 守卫：不写事件，但 after 仍减 depth 保持对称
        if (isAfter && g_aoLBFDepth > 0) g_aoLBFDepth--;
        return;
    }

    if (atomic_load(&g_aoRecordQuiet) && inWin) {
        atomic_fetch_add(&g_aoLBFQuietSkip, 1);
        if (isAfter && g_aoLBFDepth > 0) g_aoLBFDepth--;
        return;
    }

    pthread_mutex_lock(&g_forensicsLock);
    if (!g_observerEvents) g_observerEvents = [NSMutableArray array];
    g_eventSeq++;
    NSString *selName = NSStringFromSelector(sel);
    NSString *phaseHint = LBFPhaseHintForSelector(selName, when);
    NSDictionary *ev = @{
        @"seq": @(g_eventSeq),
        @"when": when ?: @"?",
        @"phaseHint": phaseHint,
        @"thread": LBFThreadLabel(),
        @"timestampUtc": LBForensicsUTCNowString(),
        @"objectAddress": LBForensicsPointer(selfObj),
        @"objectClass": LBFShapeOfObject(selfObj),
        @"ownerClass": ownerClassName ?: @"?",
        @"selector": selName,
        @"argumentShapes": argShapes ?: @[],
        @"returnShape": returnShape ?: @"void",
    };
    [g_observerEvents addObject:ev];

    if (g_lifecycleSnapshots && phaseHint.length) {
        if ([phaseHint hasPrefix:@"after_"] || [phaseHint isEqualToString:@"after_first_draw"]) {
            g_lifecycleSnapshots[phaseHint] = @{
                @"eventSeq": @(g_eventSeq),
                @"recordedAt": LBForensicsUTCNowString(),
            };
        }
    }
    pthread_mutex_unlock(&g_forensicsLock);

    if (isAfter && g_aoLBFDepth > 0) g_aoLBFDepth--;
}

void LBForensicsSetQFWindow(int inQF, int postQF) {
    atomic_store(&g_aoInQF, inQF ? 1 : 0);
    atomic_store(&g_aoPostQF, postQF ? 1 : 0);
}

void LBForensicsSetRecordQuiet(int quiet) {
    atomic_store(&g_aoRecordQuiet, quiet ? 1 : 0);
}

void LBForensicsEmitHookStats(const char *why) {
    char mark[256];
    snprintf(mark, sizeof(mark),
             "ao_lbf_stats why=%s hit=%d maxDepth=%d reenter=%d quietSkip=%d "
             "inQF=%d postQF=%d quiet=%d events=%llu",
             why && why[0] ? why : "?",
             atomic_load(&g_aoLBFHit),
             atomic_load(&g_aoLBFMaxDepth),
             atomic_load(&g_aoLBFReenter),
             atomic_load(&g_aoLBFQuietSkip),
             atomic_load(&g_aoInQF),
             atomic_load(&g_aoPostQF),
             atomic_load(&g_aoRecordQuiet),
             (unsigned long long)g_eventSeq);
    char raw[280];
    snprintf(raw, sizeof(raw), "hypothesis_AC %s", mark);
    LBFRawAOHookMark(raw);
    LBFAISyncProbe([NSString stringWithUTF8String:mark]);
}

static IMP LBFGetOrigIMP(NSString *owner, SEL sel) {
    NSString *key = LBFOrigKey(owner, NSStringFromSelector(sel));
    NSValue *v = g_origIMPs[key];
    return v ? (IMP)v.pointerValue : NULL;
}

#pragma mark - Hook trampolines (只记录 + 调原 IMP)

/// AY：postQF 窗短路标志--trampoline 开头检查，若 postQF 窗则直接调 orig 不做任何 forensics 逻辑。
/// AX 二分法证伪：禁所有后台 forensics 后仍崩在 pc=CoreFoundation postQF=1 tid=259。
/// 根因：main 线程 QF 块执行时触发 Observer trampoline（drawRect/showContent/divisionResponse），
/// trampoline 即使 LBFRecordEvent 被 quiet 跳过，仍做 NSStringFromClass + @[] + LBFGetOrigIMP
/// （NSDictionary 查找）等 CFString 操作，与 callback 后台线程（tid=259）的栈残留冲突。
/// AY：postQF 窗 trampoline 直接调 orig IMP 并 return，跳过所有 CFString 操作。
static inline BOOL LBForensicsShouldBypassInPostQF(void) {
    return atomic_load(&g_aoPostQF) != 0;
}

/// AY：postQF 窗短路 trampoline--直接调 orig IMP，不做任何 forensics 逻辑。
/// 返回 YES 表示已调用 orig，调用方应直接 return。
static BOOL LBForensicsBypassTrampolineIfPostQF(id self, SEL _cmd) {
    if (!LBForensicsShouldBypassInPostQF()) return NO;
    NSString *owner = NSStringFromClass(LBForensicsMethodOwnerClass(object_getClass(self), _cmd));
    IMP imp = LBFGetOrigIMP(owner, _cmd);
    if (imp) ((void (*)(id, SEL))imp)(self, _cmd);
    return YES;
}

#define LBF_DEFINE_HOOK0(NAME) \
static void LBFHook_##NAME(id self, SEL _cmd) { \
    if (LBForensicsShouldBypassInPostQF()) { \
        NSString *_owner = NSStringFromClass(LBForensicsMethodOwnerClass(object_getClass(self), _cmd)); \
        IMP _imp = LBFGetOrigIMP(_owner, _cmd); \
        if (_imp) ((void (*)(id, SEL))_imp)(self, _cmd); \
        return; \
    } \
    NSString *owner = NSStringFromClass(LBForensicsMethodOwnerClass(object_getClass(self), _cmd)); \
    LBFRecordEvent(@"before", self, _cmd, @[], @"void", owner); \
    @try { \
        IMP imp = LBFGetOrigIMP(owner, _cmd); \
        if (imp) ((void (*)(id, SEL))imp)(self, _cmd); \
    } @catch (NSException *ex) { \
        LBFRecordEvent(@"after", self, _cmd, @[], @"void", owner); \
        LBFMaybeScheduleAutoDump(self, _cmd, owner); \
        @throw ex; \
    } \
    LBFRecordEvent(@"after", self, _cmd, @[], @"void", owner); \
    LBFMaybeScheduleAutoDump(self, _cmd, owner); \
}

#define LBF_DEFINE_HOOK1(NAME, T1, A1) \
static void LBFHook_##NAME(id self, SEL _cmd, T1 a1) { \
    if (LBForensicsShouldBypassInPostQF()) { \
        NSString *_owner = NSStringFromClass(LBForensicsMethodOwnerClass(object_getClass(self), _cmd)); \
        IMP _imp = LBFGetOrigIMP(_owner, _cmd); \
        if (_imp) ((void (*)(id, SEL, T1))_imp)(self, _cmd, a1); \
        return; \
    } \
    NSString *owner = NSStringFromClass(LBForensicsMethodOwnerClass(object_getClass(self), _cmd)); \
    LBFRecordEvent(@"before", self, _cmd, @[A1(a1)], @"void", owner); \
    IMP imp = LBFGetOrigIMP(owner, _cmd); \
    if (imp) ((void (*)(id, SEL, T1))imp)(self, _cmd, a1); \
    LBFRecordEvent(@"after", self, _cmd, @[A1(a1)], @"void", owner); \
}

#define LBF_SHAPE_OBJ(x) LBFShapeOfObject((id)(x))
#define LBF_SHAPE_BOOL(x) ((x) ? @"BOOL:YES" : @"BOOL:NO")
#define LBF_SHAPE_SIZE(x) ([NSString stringWithFormat:@"CGSize:%@", NSStringFromCGSize(x)])

LBF_DEFINE_HOOK0(v_at)
LBF_DEFINE_HOOK1(v_at_B, BOOL, LBF_SHAPE_BOOL)
LBF_DEFINE_HOOK1(v_at_id, id, LBF_SHAPE_OBJ)
LBF_DEFINE_HOOK1(v_at_CGSize, CGSize, LBF_SHAPE_SIZE)

static void LBFHook_v_at_id_id(id self, SEL _cmd, id a1, id a2) {
    if (LBForensicsShouldBypassInPostQF()) {
        NSString *_owner = NSStringFromClass(LBForensicsMethodOwnerClass(object_getClass(self), _cmd));
        IMP _imp = LBFGetOrigIMP(_owner, _cmd);
        if (_imp) ((void (*)(id, SEL, id, id))_imp)(self, _cmd, a1, a2);
        return;
    }
    NSString *owner = NSStringFromClass(LBForensicsMethodOwnerClass(object_getClass(self), _cmd));
    NSArray *args = @[LBF_SHAPE_OBJ(a1), LBF_SHAPE_OBJ(a2)];
    LBFRecordEvent(@"before", self, _cmd, args, @"void", owner);
    IMP imp = LBFGetOrigIMP(owner, _cmd);
    if (imp) ((void (*)(id, SEL, id, id))imp)(self, _cmd, a1, a2);
    LBFRecordEvent(@"after", self, _cmd, args, @"void", owner);
}

static void LBFHook_v_at_id_q(id self, SEL _cmd, id a1, NSInteger a2) {
    if (LBForensicsShouldBypassInPostQF()) {
        NSString *_owner = NSStringFromClass(LBForensicsMethodOwnerClass(object_getClass(self), _cmd));
        IMP _imp = LBFGetOrigIMP(_owner, _cmd);
        if (_imp) ((void (*)(id, SEL, id, NSInteger))_imp)(self, _cmd, a1, a2);
        return;
    }
    NSString *owner = NSStringFromClass(LBForensicsMethodOwnerClass(object_getClass(self), _cmd));
    NSArray *args = @[LBF_SHAPE_OBJ(a1),
                      [NSString stringWithFormat:@"NSInteger:%ld", (long)a2]];
    LBFRecordEvent(@"before", self, _cmd, args, @"void", owner);
    IMP imp = LBFGetOrigIMP(owner, _cmd);
    if (imp) ((void (*)(id, SEL, id, NSInteger))imp)(self, _cmd, a1, a2);
    LBFRecordEvent(@"after", self, _cmd, args, @"void", owner);
}

static void LBFHook_v_at_id_id_q(id self, SEL _cmd, id a1, id a2, NSInteger a3) {
    if (LBForensicsShouldBypassInPostQF()) {
        NSString *_owner = NSStringFromClass(LBForensicsMethodOwnerClass(object_getClass(self), _cmd));
        IMP _imp = LBFGetOrigIMP(_owner, _cmd);
        if (_imp) ((void (*)(id, SEL, id, id, NSInteger))_imp)(self, _cmd, a1, a2, a3);
        return;
    }
    NSString *owner = NSStringFromClass(LBForensicsMethodOwnerClass(object_getClass(self), _cmd));
    NSArray *args = @[LBF_SHAPE_OBJ(a1), LBF_SHAPE_OBJ(a2),
                      [NSString stringWithFormat:@"NSInteger:%ld", (long)a3]];
    LBFRecordEvent(@"before", self, _cmd, args, @"void", owner);
    IMP imp = LBFGetOrigIMP(owner, _cmd);
    if (imp) ((void (*)(id, SEL, id, id, NSInteger))imp)(self, _cmd, a1, a2, a3);
    LBFRecordEvent(@"after", self, _cmd, args, @"void", owner);
}

static void LBFHook_v_at_id_id_q_id(id self, SEL _cmd, id a1, id a2, NSInteger a3, id a4) {
    if (LBForensicsShouldBypassInPostQF()) {
        NSString *_owner = NSStringFromClass(LBForensicsMethodOwnerClass(object_getClass(self), _cmd));
        IMP _imp = LBFGetOrigIMP(_owner, _cmd);
        if (_imp) ((void (*)(id, SEL, id, id, NSInteger, id))_imp)(self, _cmd, a1, a2, a3, a4);
        return;
    }
    NSString *owner = NSStringFromClass(LBForensicsMethodOwnerClass(object_getClass(self), _cmd));
    NSArray *args = @[LBF_SHAPE_OBJ(a1), LBF_SHAPE_OBJ(a2),
                      [NSString stringWithFormat:@"NSInteger:%ld", (long)a3],
                      LBF_SHAPE_OBJ(a4)];
    LBFRecordEvent(@"before", self, _cmd, args, @"void", owner);
    IMP imp = LBFGetOrigIMP(owner, _cmd);
    if (imp) ((void (*)(id, SEL, id, id, NSInteger, id))imp)(self, _cmd, a1, a2, a3, a4);
    LBFRecordEvent(@"after", self, _cmd, args, @"void", owner);
}

static void LBFHook_v_at_id_id_id(id self, SEL _cmd, id a1, id a2, id a3) {
    if (LBForensicsShouldBypassInPostQF()) {
        NSString *_owner = NSStringFromClass(LBForensicsMethodOwnerClass(object_getClass(self), _cmd));
        IMP _imp = LBFGetOrigIMP(_owner, _cmd);
        if (_imp) ((void (*)(id, SEL, id, id, id))_imp)(self, _cmd, a1, a2, a3);
        return;
    }
    NSString *owner = NSStringFromClass(LBForensicsMethodOwnerClass(object_getClass(self), _cmd));
    NSArray *args = @[LBF_SHAPE_OBJ(a1), LBF_SHAPE_OBJ(a2), LBF_SHAPE_OBJ(a3)];
    LBFRecordEvent(@"before", self, _cmd, args, @"void", owner);
    IMP imp = LBFGetOrigIMP(owner, _cmd);
    if (imp) ((void (*)(id, SEL, id, id, id))imp)(self, _cmd, a1, a2, a3);
    LBFRecordEvent(@"after", self, _cmd, args, @"void", owner);
}

static void LBFHook_v_at_id_id_id_id(id self, SEL _cmd, id a1, id a2, id a3, id a4) {
    if (LBForensicsShouldBypassInPostQF()) {
        NSString *_owner = NSStringFromClass(LBForensicsMethodOwnerClass(object_getClass(self), _cmd));
        IMP _imp = LBFGetOrigIMP(_owner, _cmd);
        if (_imp) ((void (*)(id, SEL, id, id, id, id))_imp)(self, _cmd, a1, a2, a3, a4);
        return;
    }
    NSString *owner = NSStringFromClass(LBForensicsMethodOwnerClass(object_getClass(self), _cmd));
    NSArray *args = @[LBF_SHAPE_OBJ(a1), LBF_SHAPE_OBJ(a2), LBF_SHAPE_OBJ(a3), LBF_SHAPE_OBJ(a4)];
    LBFRecordEvent(@"before", self, _cmd, args, @"void", owner);
    IMP imp = LBFGetOrigIMP(owner, _cmd);
    if (imp) ((void (*)(id, SEL, id, id, id, id))imp)(self, _cmd, a1, a2, a3, a4);
    LBFRecordEvent(@"after", self, _cmd, args, @"void", owner);
}

static void LBFHook_v_at_id_id_id_id_id(id self, SEL _cmd, id a1, id a2, id a3, id a4, id a5) {
    if (LBForensicsShouldBypassInPostQF()) {
        NSString *_owner = NSStringFromClass(LBForensicsMethodOwnerClass(object_getClass(self), _cmd));
        IMP _imp = LBFGetOrigIMP(_owner, _cmd);
        if (_imp) ((void (*)(id, SEL, id, id, id, id, id))_imp)(self, _cmd, a1, a2, a3, a4, a5);
        return;
    }
    NSString *owner = NSStringFromClass(LBForensicsMethodOwnerClass(object_getClass(self), _cmd));
    NSArray *args = @[LBF_SHAPE_OBJ(a1), LBF_SHAPE_OBJ(a2), LBF_SHAPE_OBJ(a3),
                      LBF_SHAPE_OBJ(a4), LBF_SHAPE_OBJ(a5)];
    LBFRecordEvent(@"before", self, _cmd, args, @"void", owner);
    IMP imp = LBFGetOrigIMP(owner, _cmd);
    if (imp) ((void (*)(id, SEL, id, id, id, id, id))imp)(self, _cmd, a1, a2, a3, a4, a5);
    LBFRecordEvent(@"after", self, _cmd, args, @"void", owner);
}

static void LBFHook_v_at_id_id_id_id_id_id(id self, SEL _cmd, id a1, id a2, id a3, id a4, id a5, id a6) {
    if (LBForensicsShouldBypassInPostQF()) {
        NSString *_owner = NSStringFromClass(LBForensicsMethodOwnerClass(object_getClass(self), _cmd));
        IMP _imp = LBFGetOrigIMP(_owner, _cmd);
        if (_imp) ((void (*)(id, SEL, id, id, id, id, id, id))_imp)(self, _cmd, a1, a2, a3, a4, a5, a6);
        return;
    }
    NSString *owner = NSStringFromClass(LBForensicsMethodOwnerClass(object_getClass(self), _cmd));
    NSArray *args = @[LBF_SHAPE_OBJ(a1), LBF_SHAPE_OBJ(a2), LBF_SHAPE_OBJ(a3),
                      LBF_SHAPE_OBJ(a4), LBF_SHAPE_OBJ(a5), LBF_SHAPE_OBJ(a6)];
    LBFRecordEvent(@"before", self, _cmd, args, @"void", owner);
    IMP imp = LBFGetOrigIMP(owner, _cmd);
    if (imp) ((void (*)(id, SEL, id, id, id, id, id, id))imp)(self, _cmd, a1, a2, a3, a4, a5, a6);
    LBFRecordEvent(@"after", self, _cmd, args, @"void", owner);
}

static void LBFHook_v_at_id_id_id_id_id_id_id(id self, SEL _cmd, id a1, id a2, id a3, id a4, id a5, id a6, id a7) {
    if (LBForensicsShouldBypassInPostQF()) {
        NSString *_owner = NSStringFromClass(LBForensicsMethodOwnerClass(object_getClass(self), _cmd));
        IMP _imp = LBFGetOrigIMP(_owner, _cmd);
        if (_imp) ((void (*)(id, SEL, id, id, id, id, id, id, id))_imp)(self, _cmd, a1, a2, a3, a4, a5, a6, a7);
        return;
    }
    NSString *owner = NSStringFromClass(LBForensicsMethodOwnerClass(object_getClass(self), _cmd));
    NSArray *args = @[LBF_SHAPE_OBJ(a1), LBF_SHAPE_OBJ(a2), LBF_SHAPE_OBJ(a3),
                      LBF_SHAPE_OBJ(a4), LBF_SHAPE_OBJ(a5), LBF_SHAPE_OBJ(a6), LBF_SHAPE_OBJ(a7)];
    LBFRecordEvent(@"before", self, _cmd, args, @"void", owner);
    IMP imp = LBFGetOrigIMP(owner, _cmd);
    if (imp) ((void (*)(id, SEL, id, id, id, id, id, id, id))imp)(self, _cmd, a1, a2, a3, a4, a5, a6, a7);
    LBFRecordEvent(@"after", self, _cmd, args, @"void", owner);
}

static void LBFHook_drawRect(id self, SEL _cmd, CGRect rect) {
    if (LBForensicsShouldBypassInPostQF()) {
        NSString *_owner = NSStringFromClass(LBForensicsMethodOwnerClass(object_getClass(self), _cmd));
        IMP _imp = LBFGetOrigIMP(_owner, _cmd);
        if (_imp) ((void (*)(id, SEL, CGRect))_imp)(self, _cmd, rect);
        return;
    }
    NSString *owner = NSStringFromClass(LBForensicsMethodOwnerClass(object_getClass(self), _cmd));
    NSArray *args = @[[NSString stringWithFormat:@"CGRect:%@", NSStringFromCGRect(rect)]];
    LBFRecordEvent(@"before", self, _cmd, args, @"void", owner);
    IMP imp = LBFGetOrigIMP(owner, _cmd);
    if (imp) ((void (*)(id, SEL, CGRect))imp)(self, _cmd, rect);
    if (!g_firstDrawSeen) g_firstDrawSeen = YES;
    LBFRecordEvent(@"after", self, _cmd, args, @"void", owner);
}

/// 假设 P：只读探针 — queryCpFile 编码未在 method-map 落盘，暂不挂钩以免签名猜错崩机。
/// 以 lpNetWorkDelegateQueryFinish（encoding 已 confirmed）作为原生链命中证据。

static IMP LBFHookIMPForSelector(NSString *selName) {
    if ([selName isEqualToString:@"viewDidLoad"] || [selName isEqualToString:@"loadCurCp"] ||
        [selName isEqualToString:@"onResetContentNotify"] ||
        [selName isEqualToString:@"reloadContent"] || [selName isEqualToString:@"reloadView"] ||
        [selName isEqualToString:@"refreshView"]) {
        return (IMP)LBFHook_v_at;
    }
    if ([selName isEqualToString:@"viewWillAppear:"] ||
        [selName isEqualToString:@"resetLoadCpTip:"]) {
        return (IMP)LBFHook_v_at_B;
    }
    if ([selName isEqualToString:@"onResetContentNotify:"] || [selName isEqualToString:@"onResetContent:"] ||
        [selName isEqualToString:@"resetContentNotify:"] || [selName isEqualToString:@"handleResetContent:"] ||
        [selName isEqualToString:@"showContent:"] || [selName isEqualToString:@"setPageModel:"]) {
        return (IMP)LBFHook_v_at_id;
    }
    if ([selName isEqualToString:@"resetContentPosByScreenSize:"]) return (IMP)LBFHook_v_at_CGSize;
    if ([selName isEqualToString:@"showContent:title:"]) return (IMP)LBFHook_v_at_id_id;
    if ([selName isEqualToString:@"onDivisionTextFinish:cpIndex:"]) return (IMP)LBFHook_v_at_id_q;
    if ([selName isEqualToString:@"divisionResponse:cpTitle:cpIndex:"]) return (IMP)LBFHook_v_at_id_id_q;
    if ([selName isEqualToString:@"divisionResponse:cpTitle:cpIndex:heights:"]) return (IMP)LBFHook_v_at_id_id_q_id;
    if ([selName isEqualToString:@"lpNetWorkDelegateQueryFinish:config:userInfo:"] ||
        [selName isEqualToString:@"callBackResponse:config:userInfo:"]) {
        return (IMP)LBFHook_v_at_id_id_id;
    }
    if ([selName isEqualToString:@"divisionText:cpTitle:cpIndex:tvSize:doubleCol:backHeights:"]) {
        return (IMP)LBFHook_v_at_id_id_id_id_id;
    }
    if ([selName isEqualToString:@"divisionText:cpTitle:cpIndex:tvSize:doubleCol:backHeights:paibanInfo:"]) {
        return (IMP)LBFHook_v_at_id_id_id_id_id_id;
    }
    if ([selName isEqualToString:@"drawRect:"]) return (IMP)LBFHook_drawRect;
    return NULL;
}

static NSArray<NSString *> *LBFObserverSelectors(void) {
    return @[
        @"viewDidLoad", @"viewWillAppear:", @"loadCurCp",
        @"onResetContentNotify", @"onResetContentNotify:", @"onResetContent:",
        @"resetContentNotify:", @"handleResetContent:",
        @"divisionText:cpTitle:cpIndex:tvSize:doubleCol:backHeights:",
        @"divisionText:cpTitle:cpIndex:tvSize:doubleCol:backHeights:paibanInfo:",
        @"divisionResponse:cpTitle:cpIndex:", @"divisionResponse:cpTitle:cpIndex:heights:",
        @"onDivisionTextFinish:cpIndex:",
        // AV：CB/QF 两 selector 移出 Observer 清单——Observer tramp 与 Bridge LBAB/LBAE 钩在 CB→QF 链互套，postQF 窗 tid=259 栈溢出（depth 2495、fault=fp-0x178、pc-lr=0x7a80；diff §8.5）
        @"resetLoadCpTip:",
        @"drawRect:", @"resetContentPosByScreenSize:",
        @"showContent:", @"showContent:title:", @"setPageModel:",
        @"reloadContent", @"reloadView", @"refreshView",
    ];
}

static NSArray<NSString *> *LBFObserverProbeClasses(void) {
    return @[
        @"TextReadVC3", @"TextReadVC2", @"TextReadVC1",
        @"ReadVCBase2", @"ReadVCBase1",
        @"TextRPageContainer", @"TextRPageContainerPage", @"TextRScrollContainer",
        @"ReadPageContainer", @"ReadScrollContainer",
        @"TextReadTV", @"TextReadTVBase",
        @"ReadPageModel",
        @"BookDbManager", @"BookQueryManager", @"CacherManager",
        @"LPNetWork2", @"LPNetWork1",
    ];
}

static void LBFInitObserverGlobals(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_origIMPs = [NSMutableDictionary dictionary];
        g_installedKeys = [NSMutableSet set];
        g_lifecycleSnapshots = [NSMutableDictionary dictionary];
        g_observerEvents = [NSMutableArray array];
    });
}

static BOOL LBFInstallHookOnMethod(Class owner, NSString *ownerName, NSString *selName) {
    SEL sel = NSSelectorFromString(selName);
    Method m = class_getInstanceMethod(owner, sel);
    if (!m) return NO;
    IMP hook = LBFHookIMPForSelector(selName);
    if (!hook) return NO;

    NSString *key = LBFOrigKey(ownerName, selName);
    IMP current = method_getImplementation(m);
    if ([g_installedKeys containsObject:key]) {
        // 已装过则不再抢回：50ms retry 若把 Bridge AC/AB 钩写进 g_orig 再盖回 forensics，
        // 会形成 forensics→AB→forensics 环（真机 cb_enter 风暴、无 check/format）。
        return YES;
    }

    g_origIMPs[key] = [NSValue valueWithPointer:current];
    method_setImplementation(m, hook);
    [g_installedKeys addObject:key];
    return YES;
}

static void LBFInstallObserverHooks(void) {
    LBFInitObserverGlobals();
    for (NSString *cn in LBFObserverProbeClasses()) {
        Class probe = NSClassFromString(cn);
        if (!probe) continue;
        for (NSString *selName in LBFObserverSelectors()) {
            if ([selName isEqualToString:@"viewDidLoad"] || [selName isEqualToString:@"loadCurCp"]) {
                continue;
            }
            SEL sel = NSSelectorFromString(selName);
            Class owner = LBForensicsMethodOwnerClass(probe, sel);
            if (!owner) continue;
            LBFInstallHookOnMethod(owner, NSStringFromClass(owner), selName);
        }
    }
    // viewDidLoad/loadCurCp 由 LBFEarlyWrap 专责，observer 不再重复挂钩
}

IMP LBForensicsResolveOrigIMP(Class cls, SEL sel) {
    if (!cls) return NULL;
    LBFInitEarlyWrapGlobals();
    NSString *selName = NSStringFromSelector(sel);
    Class walk = cls;
    while (walk) {
        NSString *key = LBFEarlyWrapKey(NSStringFromClass(walk), selName);
        NSValue *orig = g_earlyOrigIMPs[key];
        if (orig) return (IMP)orig.pointerValue;
        walk = class_getSuperclass(walk);
    }
    Method m = class_getInstanceMethod(cls, sel);
    return m ? method_getImplementation(m) : NULL;
}

IMP LBForensicsResolveObserverOrigIMP(Class cls, SEL sel) {
    if (!cls) return NULL;
    LBFInitObserverGlobals();
    Class owner = LBForensicsMethodOwnerClass(cls, sel);
    if (!owner) owner = cls;
    NSString *key = LBFOrigKey(NSStringFromClass(owner), NSStringFromSelector(sel));
    NSValue *v = g_origIMPs[key];
    return v ? (IMP)v.pointerValue : NULL;
}

IMP LBForensicsHookIMPForSelectorName(NSString *selName) {
    return LBFHookIMPForSelector(selName ?: @"");
}

IMP LBForensicsEarlyWrapIMPForSelectorName(NSString *selName) {
    return LBFEarlyWrapperForSelectorName(selName);
}

void LBForensicsInstallEarlyWrap(void) {
    LBFEnsureMethodSetHook();
    LBFEarlyWrapDiscoverAndInstall();
}

void LBForensicsInstallObservers(void) {
    if (![NSThread isMainThread]) {
        // AI：此路径会 dispatch_sync(main)，若 main 正等本线程则死锁
        LBFAISyncProbe(@"ai_bg_tag=ForensicsInstallObservers_sync_main");
        dispatch_sync(dispatch_get_main_queue(), ^{
            LBFInstallObserverHooks();
        });
        return;
    }
    LBFInstallObserverHooks();
}

__attribute__((constructor))
static void LBFInstallObserversAtLoad(void) {
    LBFEnsureMethodSetHook();
    LBFWriteHookPing(@"early wrap constructor");
    LBFEarlyWrapDiscoverAndInstall();
    dispatch_async(dispatch_get_main_queue(), ^{
        LBFScheduleEarlyWrapRetry();
    });
}

NSArray<NSDictionary *> *LBForensicsCopyObserverEvents(void) {
    pthread_mutex_lock(&g_forensicsLock);
    NSArray *copy = g_observerEvents ? [g_observerEvents copy] : @[];
    pthread_mutex_unlock(&g_forensicsLock);
    return copy;
}

NSDictionary *LBForensicsCopyLifecycleSnapshots(void) {
    pthread_mutex_lock(&g_forensicsLock);
    NSDictionary *copy = g_lifecycleSnapshots ? [g_lifecycleSnapshots copy] : @{};
    pthread_mutex_unlock(&g_forensicsLock);
    return copy;
}

void LBForensicsSetPendingDumpPhase(NSString *phase) {
    pthread_mutex_lock(&g_forensicsLock);
    g_pendingDumpPhase = [phase copy];
    pthread_mutex_unlock(&g_forensicsLock);
}

NSString *LBForensicsConsumePendingDumpPhase(void) {
    pthread_mutex_lock(&g_forensicsLock);
    NSString *p = g_pendingDumpPhase;
    g_pendingDumpPhase = nil;
    pthread_mutex_unlock(&g_forensicsLock);
    return p.length ? p : @"manual";
}

NSDictionary *LBForensicsPerformDump(NSString *phase) {
    NSString *usePhase = phase.length ? phase : @"manual";
    NSDictionary *objectGraph = LBForensicsBuildObjectGraph();
    NSDictionary *methodOwners = LBForensicsBuildMethodOwners();
    NSArray *events = LBForensicsCopyObserverEvents();
    NSDictionary *snapshots = LBForensicsCopyLifecycleSnapshots();

    NSMutableString *text = [NSMutableString string];
    [text appendFormat:@"=== legado forensics dump v%ld phase=%@ ===\n",
     (long)LBForensicsDumpSchemaVersion, usePhase];
    [text appendString:LBForensicsBuildObjectGraphText(objectGraph)];
    [text appendString:@"\n"];
    [text appendString:LBForensicsBuildMethodOwnersText(methodOwners)];
    [text appendFormat:@"\n=== observer events count=%lu ===\n", (unsigned long)events.count];
    for (NSDictionary *ev in events) {
        [text appendFormat:@"#%@ %@ %@ %@ %@ args=%@\n",
         ev[@"seq"], ev[@"phaseHint"], ev[@"thread"], ev[@"ownerClass"], ev[@"selector"], ev[@"argumentShapes"]];
    }

    NSMutableArray *unknown = [NSMutableArray array];
    for (NSString *c in LBForensicsCandidateClassNames()) {
        NSDictionary *b = objectGraph[c];
        if (![b isKindOfClass:[NSDictionary class]] || [b[@"count"] unsignedIntegerValue] == 0) {
            [unknown addObject:c];
        }
    }
    for (NSString *s in methodOwners[@"unresolvedSelectors"]) {
        [unknown addObject:[NSString stringWithFormat:@"sel:%@", s]];
    }

    return @{
        @"schema_version": @(LBForensicsDumpSchemaVersion),
        @"forensics_dump_version": @"2.0",
        @"phase": usePhase,
        @"timestamp_utc": LBForensicsUTCNowString(),
        @"manifest_sha_prefix": LBForensicsManifestSHAPrefix(),
        @"objectGraph": objectGraph,
        @"methodOwners": methodOwners,
        @"observerEvents": events,
        @"lifecycleSnapshots": snapshots,
        @"unknown": unknown,
        @"textSummary": text,
    };
}
