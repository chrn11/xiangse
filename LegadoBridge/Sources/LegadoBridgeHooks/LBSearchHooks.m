#import "LBInternal.h"
#import "LegadoBridge.h"

/// 搜索组：原生 XBS 继续跑；Legado 全源有界并发增量回传（不短路原生、不只吃第一个源）

#pragma mark - Search Hooks

void LBInstallSearchHooks(void) {
    @try {
        NSMutableArray *installed = [NSMutableArray array];

        Class managerClass = NSClassFromString(@"BookSourceManager");
        if (!managerClass) {
            managerClass = NSClassFromString(@"BookSourceManagerBase");
        }

        if (managerClass) {
            // canSearch:fromShuping: — 有 Legado 源时放行，否则走原生
            SEL canSel = NSSelectorFromString(@"canSearch:fromShuping:");
            Method canMethod = class_getInstanceMethod(managerClass, canSel);
            if (canMethod) {
                IMP canOrigIMP = method_getImplementation(canMethod);
                const char *canTypes = method_getTypeEncoding(canMethod) ?: "B28@0:8@16B24";
                IMP canHookIMP = imp_implementationWithBlock(^BOOL(id self, id typeOrFlag, BOOL shuping) {
                    if (LBLegadoGetSourceNames().count > 0) {
                        return YES;
                    }
                    return ((BOOL (*)(id, SEL, id, BOOL))canOrigIMP)(self, canSel, typeOrFlag, shuping);
                });
                method_setImplementation(canMethod, canHookIMP);
                [installed addObject:@"canSearch"];
                NSLog(@"[LegadoBridge] hooked canSearch:fromShuping: on %@ types=%s",
                      NSStringFromClass(managerClass), canTypes);
            }

            SEL sortedPriSel = @selector(getSortedSourceNamesByPrioritySourceType:);
            Method sortedPriMethod = class_getInstanceMethod(managerClass, sortedPriSel);
            if (sortedPriMethod) {
                IMP priOrig = method_getImplementation(sortedPriMethod);
                IMP priHook = imp_implementationWithBlock(^NSArray *(id self, id priorityType) {
                    NSArray *orig = ((NSArray * (*)(id, SEL, id))priOrig)(self, sortedPriSel, priorityType) ?: @[];
                    return LBMergeLegadoNames(orig);
                });
                method_setImplementation(sortedPriMethod, priHook);
                [installed addObject:@"sortedByPri"];
            }

            // 关键：先原生，再并行踢 Legado 全源；绝不因有 Legado 而吞掉原生
            SEL searchSel = NSSelectorFromString(@"startSearch:prioritySourceType:fromShuping:quick:");
            Method searchMethod = class_getInstanceMethod(managerClass, searchSel);
            if (searchMethod) {
                IMP originalIMP = method_getImplementation(searchMethod);
                IMP hookIMP = imp_implementationWithBlock(^BOOL(id self, NSString *keyword, id type, BOOL shuping, BOOL quick) {
                    BOOL nativeOk = ((BOOL (*)(id, SEL, NSString *, id, BOOL, BOOL))originalIMP)(
                        self, searchSel, keyword, type, shuping, quick
                    );

                    id core = LBLegadoCoreIfReady();
                    NSArray *names = nil;
                    if ([core respondsToSelector:@selector(allLegadoSourceNames)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                        names = [core performSelector:@selector(allLegadoSourceNames)];
#pragma clang diagnostic pop
                    }
                    if (names.count > 0 &&
                        [core respondsToSelector:@selector(handleSearchRequestWithKeyword:sourceUrl:)]) {
                        NSString *marker = [NSString stringWithFormat:@"startSearch coexist native=%d legado=%lu key=%@",
                                            (int)nativeOk, (unsigned long)names.count, keyword ?: @""];
                        [marker writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_search_hook.txt"]
                                 atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                        // sourceUrl:nil → Core 侧搜索全部启用源（非仅第一个）
                        ((void (*)(id, SEL, NSString *, NSString *))objc_msgSend)(
                            core, @selector(handleSearchRequestWithKeyword:sourceUrl:), keyword ?: @"", nil
                        );
                        return YES;
                    }
                    return nativeOk;
                });
                method_setImplementation(searchMethod, hookIMP);
                [installed addObject:@"startSearch"];
                NSLog(@"[LegadoBridge] hooked startSearch coexist on %@", NSStringFromClass(managerClass));
            }
        }

        // searchWord: 有 Legado 时强制放行
        NSArray *searchVCNames = @[@"BookSearchVCBase1", @"BookSearchVCBase2", @"BookSearchController"];
        for (NSString *cn in searchVCNames) {
            Class vcCls = NSClassFromString(cn);
            if (!vcCls) continue;
            Method own = class_getInstanceMethod(vcCls, @selector(searchWord:));
            if (!own) continue;
            Method base = class_getInstanceMethod(class_getSuperclass(vcCls), @selector(searchWord:));
            if (base && method_getImplementation(own) == method_getImplementation(base) &&
                ![cn isEqualToString:@"BookSearchVCBase1"]) {
                continue;
            }
            IMP swOrig = method_getImplementation(own);
            IMP swHook = imp_implementationWithBlock(^BOOL(id self, NSString *word) {
                if (LBLegadoGetSourceNames().count > 0) {
                    ((BOOL (*)(id, SEL, NSString *))swOrig)(self, @selector(searchWord:), word);
                    return YES;
                }
                return ((BOOL (*)(id, SEL, NSString *))swOrig)(self, @selector(searchWord:), word);
            });
            method_setImplementation(own, swHook);
            [installed addObject:[NSString stringWithFormat:@"searchWord:%@", cn]];
        }

        // 有 Legado 时吞掉「无可用站点」Alert
        Class alertCls = NSClassFromString(@"UIAlertController");
        if (alertCls) {
            SEL presentSel = @selector(presentViewController:animated:completion:);
            Method presentMethod = class_getInstanceMethod([UIViewController class], presentSel);
            if (presentMethod) {
                IMP presentOrig = method_getImplementation(presentMethod);
                IMP presentHook = imp_implementationWithBlock(^void(id self, UIViewController *vc, BOOL animated, id completion) {
                    if ([vc isKindOfClass:[UIAlertController class]]) {
                        UIAlertController *alert = (UIAlertController *)vc;
                        NSString *t = alert.title ?: @"";
                        NSString *m = alert.message ?: @"";
                        BOOL isNoSite = [t containsString:@"无可用站点"] || [m containsString:@"无可用站点"] ||
                                        [m containsString:@"修改筛选类型"];
                        if (isNoSite && LBLegadoGetSourceNames().count > 0) {
                            if (completion) {
                                void (^comp)(void) = completion;
                                comp();
                            }
                            return;
                        }
                    }
                    ((void (*)(id, SEL, UIViewController *, BOOL, id))presentOrig)(
                        self, presentSel, vc, animated, completion
                    );
                });
                method_setImplementation(presentMethod, presentHook);
                [installed addObject:@"suppressNoSiteAlert"];
            }
        }

        if (installed.count == 0) {
            LBCapabilityMarkSkipped(LBHookGroupSearch, @"no search anchors");
        } else {
            LBCapabilityMarkEnabled(LBHookGroupSearch, [installed componentsJoinedByString:@","]);
        }
    } @catch (NSException *e) {
        LBCapabilityMarkFailed(LBHookGroupSearch, e.reason ?: @"exception");
        NSLog(@"[LegadoBridge] search hooks exception: %@", e);
    }
}
