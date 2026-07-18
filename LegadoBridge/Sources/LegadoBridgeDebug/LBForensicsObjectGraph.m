#import "LBForensics.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

extern NSString *LBForensicsPointer(id obj);

static BOOL LBFIvarIsObject(Ivar iv) {
    const char *t = ivar_getTypeEncoding(iv);
    if (!t || !t[0]) return NO;
    return t[0] == '@' || t[0] == '#';
}

static id LBFSafeObjectIvar(id obj, Ivar iv) {
    if (!obj || !iv || !LBFIvarIsObject(iv)) return nil;
    @try { return object_getIvar(obj, iv); } @catch (__unused NSException *e) { return nil; }
}
extern NSDictionary *LBForensicsDumpIvars(id obj);
extern NSDictionary *LBForensicsDumpObjectRelations(id obj);
extern NSString *LBForensicsUTCNowString(void);

#pragma mark - Window / discovery

static UIWindow *LBFKeyWindow(void) {
    // AK：非主线程禁止任何 windows API
    if (![NSThread isMainThread]) return nil;
    UIApplication *app = UIApplication.sharedApplication;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow) return w;
            }
        }
    }
    return app.keyWindow;
}

static void LBFCollectAllWindows(NSMutableArray<UIWindow *> *out) {
    if (![NSThread isMainThread]) return;
    UIApplication *app = UIApplication.sharedApplication;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            [out addObjectsFromArray:((UIWindowScene *)scene).windows];
        }
    }
    if (out.count == 0 && app.keyWindow) [out addObject:app.keyWindow];
}

static BOOL LBFShouldSkipPanel(id obj) {
    Class panelCls = NSClassFromString(@"LBDebugPanel");
    (void)panelCls;
    return NO;
}

/// 避免对已释放/非对象指针做 object_getClass 导致 SIGSEGV
static BOOL LBFSafeIsReadableObject(id val) {
    if (!val) return NO;
    uintptr_t p = (uintptr_t)(__bridge void *)val;
    if (p < 0x1000) return NO;
    @try {
        Class c = object_getClass(val);
        if (!c) return NO;
        const char *name = class_getName(c);
        return name && name[0];
    } @catch (__unused NSException *e) {
        return NO;
    }
}

static NSString *LBFSafeClassNameOfObject(id val) {
    if (!LBFSafeIsReadableObject(val)) return @"?";
    @try {
        return NSStringFromClass(object_getClass(val)) ?: @"?";
    } @catch (__unused NSException *e) {
        return @"?";
    }
}

static void LBFCollectVCChain(UIViewController *vc, NSMutableArray<UIViewController *> *chain,
                              NSMutableSet<NSValue *> *seen) {
    if (!vc) return;
    NSValue *key = [NSValue valueWithNonretainedObject:vc];
    if ([seen containsObject:key]) return;
    [seen addObject:key];
    [chain addObject:vc];
    if ([vc isKindOfClass:[UINavigationController class]]) {
        for (UIViewController *n in ((UINavigationController *)vc).viewControllers) {
            LBFCollectVCChain(n, chain, seen);
        }
    } else if ([vc isKindOfClass:[UITabBarController class]]) {
        for (UIViewController *t in ((UITabBarController *)vc).viewControllers) {
            LBFCollectVCChain(t, chain, seen);
        }
    } else {
        for (UIViewController *ch in vc.childViewControllers) {
            LBFCollectVCChain(ch, chain, seen);
        }
    }
    if (vc.presentedViewController) LBFCollectVCChain(vc.presentedViewController, chain, seen);
}

static void LBFWalkViewTree(UIView *root, void (^block)(UIView *v)) {
    if (!root || !block) return;
    NSMutableArray<UIView *> *q = [NSMutableArray arrayWithObject:root];
    NSMutableSet<NSValue *> *seen = [NSMutableSet set];
    while (q.count) {
        UIView *v = q.firstObject;
        [q removeObjectAtIndex:0];
        NSValue *k = [NSValue valueWithNonretainedObject:v];
        if ([seen containsObject:k]) continue;
        [seen addObject:k];
        block(v);
        for (UIView *s in v.subviews) [q addObject:s];
    }
}

static BOOL LBFClassNameMatchesCandidate(NSString *className, NSString *candidate) {
    if (!className.length || !candidate.length) return NO;
    if ([className isEqualToString:candidate]) return YES;
    return [className hasPrefix:candidate];
}

static void LBFAddUniqueObject(id obj, NSMutableArray *bucket, NSMutableSet<NSString *> *seenPtrs) {
    if (!obj || LBFShouldSkipPanel(obj)) return;
    NSString *ptr = LBForensicsPointer(obj);
    if ([seenPtrs containsObject:ptr]) return;
    [seenPtrs addObject:ptr];
    [bucket addObject:obj];
}

static void LBFScanIvarsForClass(id root, NSString *targetClass, NSMutableArray *out,
                                 NSMutableSet<NSString *> *seenPtrs, NSMutableSet<NSString *> *visitedObjs,
                                 int depth) {
    if (!root || depth > 5) return;
    if (!LBFSafeIsReadableObject(root)) return;
    NSString *rootPtr = LBForensicsPointer(root);
    if ([visitedObjs containsObject:rootPtr]) return;
    [visitedObjs addObject:rootPtr];

    Class cls = object_getClass(root);
    while (cls && cls != [NSObject class]) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        if (ivars) {
            for (unsigned int i = 0; i < count; i++) {
                if (!LBFIvarIsObject(ivars[i])) continue;
                @try {
                    id val = LBFSafeObjectIvar(root, ivars[i]);
                    if (!LBFSafeIsReadableObject(val)) continue;
                    NSString *cn = LBFSafeClassNameOfObject(val);
                    if (LBFClassNameMatchesCandidate(cn, targetClass)) {
                        LBFAddUniqueObject(val, out, seenPtrs);
                    }
                    if ([val isKindOfClass:[NSArray class]]) {
                        NSUInteger n = [(NSArray *)val count];
                        if (n > 48) n = 48;
                        for (NSUInteger j = 0; j < n; j++) {
                            id el = [(NSArray *)val objectAtIndex:j];
                            if (!LBFSafeIsReadableObject(el)) continue;
                            NSString *ecn = LBFSafeClassNameOfObject(el);
                            if (LBFClassNameMatchesCandidate(ecn, targetClass)) {
                                LBFAddUniqueObject(el, out, seenPtrs);
                            }
                            if ([el isKindOfClass:[NSObject class]]) {
                                LBFScanIvarsForClass(el, targetClass, out, seenPtrs, visitedObjs, depth + 1);
                            }
                        }
                    } else if ([val isKindOfClass:[NSObject class]]) {
                        LBFScanIvarsForClass(val, targetClass, out, seenPtrs, visitedObjs, depth + 1);
                    }
                } @catch (__unused NSException *e) {}
            }
            free(ivars);
        }
        cls = class_getSuperclass(cls);
    }
}

static NSArray *LBFDiscoverCandidateObjects(NSString *candidate) {
    NSMutableArray *found = [NSMutableArray array];
    NSMutableSet<NSString *> *seenPtrs = [NSMutableSet set];
    NSMutableSet<NSString *> *visitedObjs = [NSMutableSet set];
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    LBFCollectAllWindows(windows);

    for (UIWindow *win in windows) {
        if (win.rootViewController) {
            NSMutableArray<UIViewController *> *vcs = [NSMutableArray array];
            NSMutableSet<NSValue *> *vcSeen = [NSMutableSet set];
            LBFCollectVCChain(win.rootViewController, vcs, vcSeen);
            for (UIViewController *vc in vcs) {
                if (!LBFSafeIsReadableObject(vc)) continue;
                NSString *cn = LBFSafeClassNameOfObject(vc);
                if (LBFClassNameMatchesCandidate(cn, candidate)) {
                    LBFAddUniqueObject(vc, found, seenPtrs);
                }
                LBFScanIvarsForClass(vc, candidate, found, seenPtrs, visitedObjs, 0);
                if (vc.isViewLoaded && vc.view) {
                    LBFWalkViewTree(vc.view, ^(UIView *v) {
                        if (!LBFSafeIsReadableObject(v)) return;
                        NSString *vn = LBFSafeClassNameOfObject(v);
                        if (LBFClassNameMatchesCandidate(vn, candidate)) {
                            LBFAddUniqueObject(v, found, seenPtrs);
                        }
                        LBFScanIvarsForClass(v, candidate, found, seenPtrs, visitedObjs, 0);
                    });
                }
            }
        }
        LBFWalkViewTree(win, ^(UIView *v) {
            if (!LBFSafeIsReadableObject(v)) return;
            NSString *vn = LBFSafeClassNameOfObject(v);
            if (LBFClassNameMatchesCandidate(vn, candidate)) {
                LBFAddUniqueObject(v, found, seenPtrs);
            }
            LBFScanIvarsForClass(v, candidate, found, seenPtrs, visitedObjs, 0);
        });
    }

    // KVC 常见键兜底（ReadPageModel 等）
    NSArray *kvcKeys = @[@"pageModel", @"curPageModel", @"container", @"pageContainer",
                         @"rPageContainer", @"readPageContainer", @"scrollContainer",
                         @"textViewL", @"textViewR", @"curPageTV", @"textView"];
    for (id obj in [found copy]) {
        for (NSString *k in kvcKeys) {
            @try {
                id v = [obj valueForKey:k];
                if (v && [v isKindOfClass:[NSObject class]]) {
                    NSString *cn = NSStringFromClass(object_getClass(v));
                    if (LBFClassNameMatchesCandidate(cn, candidate)) {
                        LBFAddUniqueObject(v, found, seenPtrs);
                    }
                }
            } @catch (__unused NSException *e) {}
        }
    }
    return found;
}

static NSDictionary *LBFDumpSingleObject(id obj) {
    NSMutableDictionary *entry = [LBForensicsDumpObjectRelations(obj) mutableCopy];
    NSDictionary *ivarInfo = LBForensicsDumpIvars(obj);
    entry[@"ivars"] = ivarInfo[@"ivars"];
    entry[@"ctFrameFields"] = ivarInfo[@"ctFrameFields"];
    return entry;
}

NSDictionary *LBForensicsBuildObjectGraph(void) {
    NSMutableDictionary *graph = [NSMutableDictionary dictionary];
    NSMutableArray *unknown = [NSMutableArray array];
    @try {
        for (NSString *candidate in LBForensicsCandidateClassNames()) {
            NSArray *objects = @[];
            @try {
                objects = LBFDiscoverCandidateObjects(candidate);
            } @catch (NSException *ex) {
                [unknown addObject:[NSString stringWithFormat:@"discover_err:%@:%@", candidate, ex.reason ?: @"?"]];
            }
            NSMutableArray *entries = [NSMutableArray array];
            for (id obj in objects) {
                @try {
                    [entries addObject:LBFDumpSingleObject(obj)];
                } @catch (__unused NSException *e) {}
            }
            graph[candidate] = @{
                @"count": @(entries.count),
                @"instances": entries,
            };
            if (entries.count == 0) {
                [unknown addObject:candidate];
            }
        }
    } @catch (NSException *ex) {
        graph[@"_build_error"] = ex.reason ?: @"objectGraph build failed";
    }
    graph[@"_unknown_empty_candidates"] = unknown;
    return graph;
}

NSString *LBForensicsBuildObjectGraphText(NSDictionary *graph) {
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"=== object graph %@ ===\n", LBForensicsUTCNowString()];
    for (NSString *candidate in LBForensicsCandidateClassNames()) {
        NSDictionary *block = graph[candidate];
        if (![block isKindOfClass:[NSDictionary class]]) continue;
        [out appendFormat:@"\n## %@ count=%@\n", candidate, block[@"count"]];
        for (NSDictionary *inst in block[@"instances"]) {
            [out appendFormat:@"  addr=%@ cls=%@ super=%@\n",
             inst[@"address"], inst[@"class"], inst[@"superclass"]];
            if (inst[@"frame"]) {
                [out appendFormat:@"    frame=%@ hidden=%@ alpha=%@\n",
                 inst[@"frame"], inst[@"hidden"], inst[@"alpha"]];
            }
            id ct = inst[@"ctFrameFields"];
            if ([ct isKindOfClass:[NSDictionary class]] && [(NSDictionary *)ct count] > 0) {
                [out appendFormat:@"    ctFrame=%@\n", ct];
            }
            for (NSDictionary *row in inst[@"ivars"]) {
                [out appendFormat:@"    ivar %@:%@ = %@\n",
                 row[@"name"], row[@"typeEncoding"], row[@"valueSummary"]];
            }
        }
    }
    NSArray *unk = graph[@"_unknown_empty_candidates"];
    if (unk.count) {
        [out appendFormat:@"\nempty candidates: %@\n", [unk componentsJoinedByString:@", "]];
    }
    return out;
}
