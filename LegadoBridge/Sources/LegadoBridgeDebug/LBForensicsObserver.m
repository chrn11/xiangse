#import "LBForensics.h"
#import "fishhook.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <pthread.h>
#import <dlfcn.h>

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

static void LBFEarlyWrap_viewDidLoad(id self, SEL _cmd);
static void LBFEarlyWrap_loadCurCp(id self, SEL _cmd);
static void LBFWriteHookPing(NSString *line);

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
    NSArray<NSString *> *names = @[
        @"TextReadVC3", @"TextReadVC2", @"TextReadVC1",
        @"ReadVCBase2", @"ReadVCBase1", @"ReadVCBase",
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
        if (strstr(name, "TextReadVC") == NULL && strstr(name, "ReadVCBase") == NULL) continue;
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
    g_earlyWrapDepth--;
}

static void LBFScheduleEarlyWrapRetry(void) {
    LBFEarlyWrapDiscoverAndInstall();
    LBForensicsInstallObservers();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        LBFScheduleEarlyWrapRetry();
    });
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

static void LBFRecordEvent(NSString *when, id selfObj, SEL sel, NSArray<NSString *> *argShapes,
                           NSString *returnShape, NSString *ownerClassName) {
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
}

static IMP LBFGetOrigIMP(NSString *owner, SEL sel) {
    NSString *key = LBFOrigKey(owner, NSStringFromSelector(sel));
    NSValue *v = g_origIMPs[key];
    return v ? (IMP)v.pointerValue : NULL;
}

#pragma mark - Hook trampolines (只记录 + 调原 IMP)

#define LBF_DEFINE_HOOK0(NAME) \
static void LBFHook_##NAME(id self, SEL _cmd) { \
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
    NSString *owner = NSStringFromClass(LBForensicsMethodOwnerClass(object_getClass(self), _cmd));
    NSArray *args = @[LBF_SHAPE_OBJ(a1), LBF_SHAPE_OBJ(a2)];
    LBFRecordEvent(@"before", self, _cmd, args, @"void", owner);
    IMP imp = LBFGetOrigIMP(owner, _cmd);
    if (imp) ((void (*)(id, SEL, id, id))imp)(self, _cmd, a1, a2);
    LBFRecordEvent(@"after", self, _cmd, args, @"void", owner);
}

static void LBFHook_v_at_id_q(id self, SEL _cmd, id a1, NSInteger a2) {
    NSString *owner = NSStringFromClass(LBForensicsMethodOwnerClass(object_getClass(self), _cmd));
    NSArray *args = @[LBF_SHAPE_OBJ(a1),
                      [NSString stringWithFormat:@"NSInteger:%ld", (long)a2]];
    LBFRecordEvent(@"before", self, _cmd, args, @"void", owner);
    IMP imp = LBFGetOrigIMP(owner, _cmd);
    if (imp) ((void (*)(id, SEL, id, NSInteger))imp)(self, _cmd, a1, a2);
    LBFRecordEvent(@"after", self, _cmd, args, @"void", owner);
}

static void LBFHook_v_at_id_id_q(id self, SEL _cmd, id a1, id a2, NSInteger a3) {
    NSString *owner = NSStringFromClass(LBForensicsMethodOwnerClass(object_getClass(self), _cmd));
    NSArray *args = @[LBF_SHAPE_OBJ(a1), LBF_SHAPE_OBJ(a2),
                      [NSString stringWithFormat:@"NSInteger:%ld", (long)a3]];
    LBFRecordEvent(@"before", self, _cmd, args, @"void", owner);
    IMP imp = LBFGetOrigIMP(owner, _cmd);
    if (imp) ((void (*)(id, SEL, id, id, NSInteger))imp)(self, _cmd, a1, a2, a3);
    LBFRecordEvent(@"after", self, _cmd, args, @"void", owner);
}

static void LBFHook_v_at_id_id_q_id(id self, SEL _cmd, id a1, id a2, NSInteger a3, id a4) {
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
    NSString *owner = NSStringFromClass(LBForensicsMethodOwnerClass(object_getClass(self), _cmd));
    NSArray *args = @[LBF_SHAPE_OBJ(a1), LBF_SHAPE_OBJ(a2), LBF_SHAPE_OBJ(a3)];
    LBFRecordEvent(@"before", self, _cmd, args, @"void", owner);
    IMP imp = LBFGetOrigIMP(owner, _cmd);
    if (imp) ((void (*)(id, SEL, id, id, id))imp)(self, _cmd, a1, a2, a3);
    LBFRecordEvent(@"after", self, _cmd, args, @"void", owner);
}

static void LBFHook_v_at_id_id_id_id(id self, SEL _cmd, id a1, id a2, id a3, id a4) {
    NSString *owner = NSStringFromClass(LBForensicsMethodOwnerClass(object_getClass(self), _cmd));
    NSArray *args = @[LBF_SHAPE_OBJ(a1), LBF_SHAPE_OBJ(a2), LBF_SHAPE_OBJ(a3), LBF_SHAPE_OBJ(a4)];
    LBFRecordEvent(@"before", self, _cmd, args, @"void", owner);
    IMP imp = LBFGetOrigIMP(owner, _cmd);
    if (imp) ((void (*)(id, SEL, id, id, id, id))imp)(self, _cmd, a1, a2, a3, a4);
    LBFRecordEvent(@"after", self, _cmd, args, @"void", owner);
}

static void LBFHook_v_at_id_id_id_id_id(id self, SEL _cmd, id a1, id a2, id a3, id a4, id a5) {
    NSString *owner = NSStringFromClass(LBForensicsMethodOwnerClass(object_getClass(self), _cmd));
    NSArray *args = @[LBF_SHAPE_OBJ(a1), LBF_SHAPE_OBJ(a2), LBF_SHAPE_OBJ(a3),
                      LBF_SHAPE_OBJ(a4), LBF_SHAPE_OBJ(a5)];
    LBFRecordEvent(@"before", self, _cmd, args, @"void", owner);
    IMP imp = LBFGetOrigIMP(owner, _cmd);
    if (imp) ((void (*)(id, SEL, id, id, id, id, id))imp)(self, _cmd, a1, a2, a3, a4, a5);
    LBFRecordEvent(@"after", self, _cmd, args, @"void", owner);
}

static void LBFHook_v_at_id_id_id_id_id_id(id self, SEL _cmd, id a1, id a2, id a3, id a4, id a5, id a6) {
    NSString *owner = NSStringFromClass(LBForensicsMethodOwnerClass(object_getClass(self), _cmd));
    NSArray *args = @[LBF_SHAPE_OBJ(a1), LBF_SHAPE_OBJ(a2), LBF_SHAPE_OBJ(a3),
                      LBF_SHAPE_OBJ(a4), LBF_SHAPE_OBJ(a5), LBF_SHAPE_OBJ(a6)];
    LBFRecordEvent(@"before", self, _cmd, args, @"void", owner);
    IMP imp = LBFGetOrigIMP(owner, _cmd);
    if (imp) ((void (*)(id, SEL, id, id, id, id, id, id))imp)(self, _cmd, a1, a2, a3, a4, a5, a6);
    LBFRecordEvent(@"after", self, _cmd, args, @"void", owner);
}

static void LBFHook_v_at_id_id_id_id_id_id_id(id self, SEL _cmd, id a1, id a2, id a3, id a4, id a5, id a6, id a7) {
    NSString *owner = NSStringFromClass(LBForensicsMethodOwnerClass(object_getClass(self), _cmd));
    NSArray *args = @[LBF_SHAPE_OBJ(a1), LBF_SHAPE_OBJ(a2), LBF_SHAPE_OBJ(a3),
                      LBF_SHAPE_OBJ(a4), LBF_SHAPE_OBJ(a5), LBF_SHAPE_OBJ(a6), LBF_SHAPE_OBJ(a7)];
    LBFRecordEvent(@"before", self, _cmd, args, @"void", owner);
    IMP imp = LBFGetOrigIMP(owner, _cmd);
    if (imp) ((void (*)(id, SEL, id, id, id, id, id, id, id))imp)(self, _cmd, a1, a2, a3, a4, a5, a6, a7);
    LBFRecordEvent(@"after", self, _cmd, args, @"void", owner);
}

static void LBFHook_drawRect(id self, SEL _cmd, CGRect rect) {
    NSString *owner = NSStringFromClass(LBForensicsMethodOwnerClass(object_getClass(self), _cmd));
    NSArray *args = @[[NSString stringWithFormat:@"CGRect:%@", NSStringFromCGRect(rect)]];
    LBFRecordEvent(@"before", self, _cmd, args, @"void", owner);
    IMP imp = LBFGetOrigIMP(owner, _cmd);
    if (imp) ((void (*)(id, SEL, CGRect))imp)(self, _cmd, rect);
    if (!g_firstDrawSeen) g_firstDrawSeen = YES;
    LBFRecordEvent(@"after", self, _cmd, args, @"void", owner);
}

static IMP LBFHookIMPForSelector(NSString *selName) {
    if ([selName isEqualToString:@"viewDidLoad"] || [selName isEqualToString:@"loadCurCp"] ||
        [selName isEqualToString:@"onResetContentNotify"] ||
        [selName isEqualToString:@"reloadContent"] || [selName isEqualToString:@"reloadView"] ||
        [selName isEqualToString:@"refreshView"]) {
        return (IMP)LBFHook_v_at;
    }
    if ([selName isEqualToString:@"viewWillAppear:"]) return (IMP)LBFHook_v_at_B;
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
        @"TextReadTV", @"TextReadTVBase",
        @"ReadPageModel",
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
        if (current != hook) {
            g_origIMPs[key] = [NSValue valueWithPointer:current];
            method_setImplementation(m, hook);
        }
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

IMP LBForensicsEarlyWrapIMPForSelectorName(NSString *selName) {
    return LBFEarlyWrapperForSelectorName(selName);
}

void LBForensicsInstallEarlyWrap(void) {
    LBFEnsureMethodSetHook();
    LBFEarlyWrapDiscoverAndInstall();
}

void LBForensicsInstallObservers(void) {
    if (![NSThread isMainThread]) {
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
