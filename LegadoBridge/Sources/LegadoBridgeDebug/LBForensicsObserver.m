#import "LBForensics.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <pthread.h>

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
    IMP imp = LBFGetOrigIMP(owner, _cmd); \
    if (imp) ((void (*)(id, SEL))imp)(self, _cmd); \
    LBFRecordEvent(@"after", self, _cmd, @[], @"void", owner); \
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
    if ([selName isEqualToString:@"showContent:title:"] || [selName isEqualToString:@"onDivisionTextFinish:cpIndex:"]) {
        return (IMP)LBFHook_v_at_id_id;
    }
    if ([selName isEqualToString:@"divisionResponse:cpTitle:cpIndex:"]) return (IMP)LBFHook_v_at_id_id_id;
    if ([selName isEqualToString:@"divisionResponse:cpTitle:cpIndex:heights:"]) return (IMP)LBFHook_v_at_id_id_id_id;
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
        @"TextRPageContainer", @"TextRPageContainerPage", @"TextRScrollContainer",
        @"TextReadTV", @"TextReadTVBase",
        @"ReadPageModel",
    ];
}

void LBForensicsInstallObservers(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_origIMPs = [NSMutableDictionary dictionary];
        g_installedKeys = [NSMutableSet set];
        g_lifecycleSnapshots = [NSMutableDictionary dictionary];
        g_observerEvents = [NSMutableArray array];

        for (NSString *cn in LBFObserverProbeClasses()) {
            Class probe = NSClassFromString(cn);
            if (!probe) continue;
            for (NSString *selName in LBFObserverSelectors()) {
                SEL sel = NSSelectorFromString(selName);
                Class owner = LBForensicsMethodOwnerClass(probe, sel);
                if (!owner) continue;
                NSString *ownerName = NSStringFromClass(owner);
                NSString *key = LBFOrigKey(ownerName, selName);
                if ([g_installedKeys containsObject:key]) continue;

                Method m = class_getInstanceMethod(owner, sel);
                if (!m) continue;
                IMP hook = LBFHookIMPForSelector(selName);
                if (!hook) continue;

                IMP orig = method_getImplementation(m);
                g_origIMPs[key] = [NSValue valueWithPointer:orig];
                method_setImplementation(m, hook);
                [g_installedKeys addObject:key];
            }
        }
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
