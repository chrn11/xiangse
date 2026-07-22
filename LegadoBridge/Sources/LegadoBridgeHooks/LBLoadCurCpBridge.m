#import "LBLoadCurCpBridge.h"
#import "LBInternal.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <unistd.h>
#import <signal.h>
#import <stdio.h>
#import <string.h>
#import <time.h>
#import <mach/mach.h>
#import <mach/task_info.h>
#import <mach/thread_act.h>
#import <pthread.h>
#import <stdlib.h>
#import <CoreFoundation/CoreFoundation.h>
#import <stdatomic.h>
#import <sys/ucontext.h>

static void (*sOrigLoadCurCp)(id, SEL) = NULL;
static LBLoadCurCpState sState = LBLoadCurCpStateIdle;
static NSString *sToken = nil;
static NSString *sChapterUrl = nil;
static NSString *sBookUrl = nil;
static NSInteger sCpIndex = 0;
static NSUInteger sInvokeCount = 0;
static NSDictionary *sPendingPayload = nil;
static __weak id sWeakReader = nil;
static __weak id sWeakHookReceiver = nil;
static BOOL sReentryGuard = NO;
static const void *kLBAssocFoundContainerKey = &kLBAssocFoundContainerKey;

/// 假设 AC/AD/AE：CB 透传链上 check/format/QF 派发取证（禁 bounce / 禁 dontFormat）
/// AB 真机：cb_enter×N 无 check/format/cb_exit；6b5ef8e 未清 openOnce 假阳性已 revert 回 swcf
/// AD：original CB 在 check 前仅 response==nil 门禁；runtime check/format 在 BookQueryManager 覆盖实现
/// AE：format 编码为返回 id（@40@0:8@16@24@32）；void 钩会丢掉返回值并破坏 format 后 QF 派发
static void (*sABNextCallBackResponse)(id, SEL, id, id, id) = NULL;
static id (*sABNextFormatCallBack)(id, SEL, id, id, id) = NULL;
static BOOL (*sABNextCheckCallBack)(id, SEL, id, id, id) = NULL;
static void (*sAENextQueryFinish)(id, SEL, id, id, id) = NULL;
static id (*sABNextStringWithContents)(id, SEL, id, NSUInteger, NSError **) = NULL;
static BOOL sABSignalInstalled = NO;
static BOOL sABHooksInstalled = NO;
static _Thread_local int sABInCallBack = 0;
static _Thread_local int sADCheckEntered = 0;

typedef IMP (*LBACForensicsResolveObserverOrigIMPFn)(Class, SEL);
typedef IMP (*LBACForensicsHookIMPForSelectorNameFn)(NSString *);

static void LBABSyncProbe(NSString *tag);
static void LBABInstallProbes(void);
static IMP LBACPeelObserverNext(Class cls, SEL sel, IMP cur);
static void LBAB_CallBackResponse(id self, SEL _cmd, id response, id config, id userInfo);
static id LBAB_FormatCallBack(id self, SEL _cmd, id response, id config, id userInfo);
static BOOL LBAB_CheckCallBack(id self, SEL _cmd, id response, id config, id userInfo);
static void LBAE_QueryFinish(id self, SEL _cmd, id response, id config, id userInfo);
static void LBAEProbeDispatchGates(id response, id config, id userInfo, NSString *phase);
static long LBAGFootprintMB(void);
static long LBAGUptimeMs(void);
static void LBAGStartBgHeartbeat(void);
static void LBAGInstallAtExit(void);
static void LBAIInstallWindowSceneHook(void);
static void LBAIStartMainBlockSampler(void);
static void LBAIWriteLong(NSString *line);
static void LBAICaptureMainMachThread(void);
static void LBAKSampleMainThreadPC(int round);
static void LBAKStartPostIdleMainBlockForensics(void);
static void LBALInstallQFUIKitHooks(void);
static void LBALStartPostCbThreadSample(void);
static void LBALInstallExceptionProbe(void);
static void LBAMStartPostCbHeartbeat(void);
static void LBAMInstallICUCallerHooks(void);
static void LBANClaimFaultHandlers(const char *why);
static void LBAOProbeFaultHandler(const char *why);
static void LBAONotifyForensicsWindow(int inQF, int postQF);
static void LBAOEmitLBFStats(const char *why);
static NSString *LBANSymbolStack(NSUInteger maxFrames);
static void LBANSampleMemPath(int i, long ms, long mem);
static void LBAPWriteFpStack(uint64_t fp, uint64_t pc, uint64_t lr);
static void LBAPLogDladdrAddr(const char *tag, uint64_t addr);
static void LBAPDumpPostQFStacks(const char *why);
static void LBAPLogCFAnchor(void);

/// AL：QF/死后窗标志（供 UIKit 钩与 fatal 栈标注）
static atomic_int sALInQF = 0;
static atomic_int sALPostQF = 0;
static atomic_int sALQFUIKitHit = 0;
static char sALAltStack[65536];

static void LBTraceLoadCurCp(NSString *msg) {
    if (msg.length == 0) return;
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_openreader_trace.txt"];
    NSString *line = [NSString stringWithFormat:@"%@ | %@\n", [NSDate date], msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return;
    }
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh synchronizeFile];
    [fh closeFile];
}

static void LBStateLog(NSString *msg) {
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_loadcurcp_state.txt"];
    NSString *line = [NSString stringWithFormat:@"%@ | %@ | state=%@ token=%@ ch=%@ inv=%lu\n",
                      [NSDate date], msg ?: @"",
                      LBLoadCurCpBridgeStateName(), sToken ?: @"-",
                      sChapterUrl ?: @"-", (unsigned long)sInvokeCount];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return;
    }
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh synchronizeFile];
    [fh closeFile];
    LBTraceLoadCurCp([NSString stringWithFormat:@"loadCurCp %@ sm=%@", msg ?: @"", LBLoadCurCpBridgeStateName()]);
}

/// AG：phys_footprint（MB）；失败返回 -1
static long LBAGFootprintMB(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count);
    if (kr != KERN_SUCCESS) return -1;
    return (long)(info.phys_footprint / (1024ull * 1024ull));
}

static long LBAGUptimeMs(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC_RAW, &ts) != 0) return -1;
    return (long)(ts.tv_sec * 1000L + ts.tv_nsec / 1000000L);
}

/// AG：POSIX append+fsync：SIGKILL 前尽量保住最后一条存活点；附 pid/uptime/mem
static void LBABSyncProbe(NSString *tag) {
    if (tag.length == 0) return;
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_ab_probe.txt"];
    const char *cpath = path.fileSystemRepresentation;
    if (!cpath) return;

    char buf[768];
    time_t now = time(NULL);
    struct tm tm;
    localtime_r(&now, &tm);
    int n = snprintf(buf, sizeof(buf),
                     "%04d-%02d-%02d %02d:%02d:%02d | hypothesis_AC %s main=%d inv=%lu pid=%d up=%ld mem=%ld\n",
                     tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
                     tm.tm_hour, tm.tm_min, tm.tm_sec,
                     tag.UTF8String ?: "?",
                     [NSThread isMainThread] ? 1 : 0,
                     (unsigned long)sInvokeCount,
                     (int)getpid(),
                     LBAGUptimeMs(),
                     LBAGFootprintMB());
    if (n <= 0) return;
    if (n >= (int)sizeof(buf)) n = (int)sizeof(buf) - 1;

    int fd = open(cpath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        (void)write(fd, buf, (size_t)n);
        (void)fsync(fd);
        close(fd);
    }
    // 同步进 state，便于现有验收扫尾
    NSString *statePath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_loadcurcp_state.txt"];
    NSString *line = [NSString stringWithFormat:@"%@ | hypothesis_AC %s | state=%@ token=%@ ch=%@ inv=%lu\n",
                      [NSDate date], tag.UTF8String ?: "?",
                      LBLoadCurCpBridgeStateName(), sToken ?: @"-",
                      sChapterUrl ?: @"-", (unsigned long)sInvokeCount];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:statePath];
    if (!fh) {
        [line writeToFile:statePath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    } else {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh synchronizeFile];
        [fh closeFile];
    }
}

/// AG：bg 心跳——主队列卡死时仍能写盘；停跳+pid 变 → 进程已死（非仅 main 饿死）
static void LBAGStartBgHeartbeat(void) {
    static int sStarted = 0;
    if (sStarted) return;
    sStarted = 1;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        for (int i = 0; i < 40; i++) {
            LBABSyncProbe([NSString stringWithFormat:@"ag_bg_hb i=%d", i]);
            usleep(200000);
        }
        LBABSyncProbe(@"ag_bg_hb_done");
    });
}

static void LBAGAtExitProbe(void) {
    char mark[96];
    int n = snprintf(mark, sizeof(mark), "hypothesis_AC ag_atexit pid=%d\n", (int)getpid());
    const char *home = getenv("HOME");
    char path[512];
    if (home && home[0]) {
        snprintf(path, sizeof(path), "%s/Documents/legado_ab_probe.txt", home);
    } else {
        snprintf(path, sizeof(path), "/tmp/legado_ab_probe.txt");
    }
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        if (n > 0) (void)write(fd, mark, (size_t)n);
        (void)fsync(fd);
        close(fd);
    }
}

static void LBAGInstallAtExit(void) {
    static int sOnce = 0;
    if (sOnce) return;
    sOnce = 1;
    (void)atexit(LBAGAtExitProbe);
}

/// AI：长栈写入 Documents/legado_ai_probe.txt（ab_probe 行宽不够）
static void LBAIWriteLong(NSString *line) {
    if (line.length == 0) return;
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_ai_probe.txt"];
    NSString *body = [NSString stringWithFormat:@"%@ | %@\n", [NSDate date], line];
    const char *cpath = path.fileSystemRepresentation;
    if (!cpath) return;
    NSData *data = [body dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length) return;
    int fd = open(cpath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    (void)write(fd, data.bytes, data.length);
    (void)fsync(fd);
    close(fd);
}

static NSString *LBAICompactStack(NSUInteger maxFrames) {
    NSArray *syms = [NSThread callStackSymbols];
    if (![syms isKindOfClass:[NSArray class]] || syms.count == 0) return @"-";
    NSMutableArray *keep = [NSMutableArray array];
    NSUInteger skip = 2; // 本函数 + 钩子
    for (NSUInteger i = skip; i < syms.count && keep.count < maxFrames; i++) {
        NSString *s = [syms[i] description];
        if (s.length == 0) continue;
        // 压缩：优先保留 -[Class sel] / +[Class sel] / 符号名尾
        NSRange r1 = [s rangeOfString:@"-["];
        NSRange r2 = [s rangeOfString:@"+["];
        NSRange r = (r1.location != NSNotFound) ? r1 : r2;
        if (r.location != NSNotFound) {
            NSString *tail = [s substringFromIndex:r.location];
            NSRange end = [tail rangeOfString:@"]"];
            if (end.location != NSNotFound) {
                [keep addObject:[tail substringToIndex:end.location + 1]];
                continue;
            }
        }
        if ([s containsString:@"LegadoBridge"] || [s containsString:@"StandarReader"] ||
            [s containsString:@"LB"] || [s containsString:@"UIKit"] ||
            [s containsString:@"UIWindowScene"]) {
            NSArray *parts = [s componentsSeparatedByCharactersInSet:
                              [NSCharacterSet whitespaceCharacterSet]];
            NSMutableArray *nz = [NSMutableArray array];
            for (NSString *p in parts) {
                if (p.length) [nz addObject:p];
            }
            if (nz.count >= 4) {
                [keep addObject:nz.lastObject];
            } else if (s.length > 80) {
                [keep addObject:[s substringFromIndex:s.length - 80]];
            } else {
                [keep addObject:s];
            }
        }
    }
    if (keep.count == 0) {
        // fallback：前 maxFrames 原始行截断
        for (NSUInteger i = skip; i < syms.count && keep.count < maxFrames; i++) {
            NSString *s = [syms[i] description];
            if (s.length > 100) s = [s substringToIndex:100];
            [keep addObject:s ?: @"?"];
        }
    }
    return [keep componentsJoinedByString:@" < "];
}

static NSArray *(*sAINextWindows)(id, SEL) = NULL;
static atomic_int sAIWindowsHooked = 0;
static atomic_int sAIBgWindowsHit = 0;
static atomic_int sAIMainDrainSeen = 0;
static atomic_int sAIMainRlBeforeWaiting = 0;
static atomic_int sAIMainRlBeforeSources = 0;
static atomic_int sAIMainSamplerStarted = 0;
static CFRunLoopObserverRef sAIRunLoopObs = NULL;
static mach_port_t sAIMainMachThread = MACH_PORT_NULL;

static void LBAICaptureMainMachThread(void) {
    if (![NSThread isMainThread]) return;
    sAIMainMachThread = pthread_mach_thread_np(pthread_self());
}

static NSArray *LBAI_Windows(id self, SEL _cmd) {
    if (![NSThread isMainThread]) {
        int n = atomic_fetch_add(&sAIBgWindowsHit, 1) + 1;
        if (n <= 12) {
            NSString *stack = LBAICompactStack(14);
            NSString *th = [NSThread currentThread].name ?: @"?";
            LBABSyncProbe([NSString stringWithFormat:
                           @"ai_bg_uikit sel=windows hit=%d th=%@", n, th]);
            LBAIWriteLong([NSString stringWithFormat:
                           @"ai_bg_uikit sel=windows hit=%d th=%@ stack=%@",
                           n, th, stack]);
        }
    }
    return sAINextWindows ? sAINextWindows(self, _cmd) : @[];
}

static void LBAIInstallWindowSceneHook(void) {
    int expected = 0;
    if (!atomic_compare_exchange_strong(&sAIWindowsHooked, &expected, 1)) return;
    Class cls = NSClassFromString(@"UIWindowScene");
    if (!cls) {
        LBABSyncProbe(@"ai_hook_windows_missing_class");
        atomic_store(&sAIWindowsHooked, 0);
        return;
    }
    SEL sel = @selector(windows);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        LBABSyncProbe(@"ai_hook_windows_missing_sel");
        atomic_store(&sAIWindowsHooked, 0);
        return;
    }
    IMP cur = method_getImplementation(m);
    if (cur == (IMP)LBAI_Windows) {
        LBABSyncProbe(@"ai_hook_windows_already");
        return;
    }
    sAINextWindows = (NSArray *(*)(id, SEL))cur;
    method_setImplementation(m, (IMP)LBAI_Windows);
    LBABSyncProbe(@"ai_hook_windows_ok");
}

static void LBAIRunLoopObserver(CFRunLoopObserverRef obs, CFRunLoopActivity activity, void *info) {
    (void)obs; (void)info;
    if (activity == kCFRunLoopBeforeWaiting) {
        atomic_fetch_add(&sAIMainRlBeforeWaiting, 1);
    } else if (activity == kCFRunLoopBeforeSources) {
        atomic_fetch_add(&sAIMainRlBeforeSources, 1);
    }
}

static void LBAIEnsureRunLoopObserver(void) {
    if (sAIRunLoopObs) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ LBAIEnsureRunLoopObserver(); });
        return;
    }
    LBAICaptureMainMachThread();
    if (sAIRunLoopObs) return;
    sAIRunLoopObs = CFRunLoopObserverCreate(kCFAllocatorDefault,
                                            kCFRunLoopBeforeWaiting | kCFRunLoopBeforeSources,
                                            true, 0, LBAIRunLoopObserver, NULL);
    if (sAIRunLoopObs) {
        CFRunLoopAddObserver(CFRunLoopGetMain(), sAIRunLoopObs, kCFRunLoopCommonModes);
        LBABSyncProbe(@"ai_main_rl_observer_ok");
    } else {
        LBABSyncProbe(@"ai_main_rl_observer_fail");
    }
}

/// AI：从 bg 看 main 是否排空；若未排空则尝试挂起主线程读 LR/PC（符号靠 ai_probe 关联）
static void LBAISampleMainThreadPC(int round) {
    if ([NSThread isMainThread]) return;
    mach_port_t mainTh = sAIMainMachThread;
    if (mainTh == MACH_PORT_NULL) return;
    if (thread_suspend(mainTh) != KERN_SUCCESS) {
        LBABSyncProbe([NSString stringWithFormat:@"ai_main_sample_suspend_fail r=%d", round]);
        return;
    }
#if defined(__aarch64__)
    arm_thread_state64_t state;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    kern_return_t kr = thread_get_state(mainTh, ARM_THREAD_STATE64,
                                        (thread_state_t)&state, &count);
    if (kr == KERN_SUCCESS) {
        uint64_t pc = arm_thread_state64_get_pc(state);
        uint64_t lr = arm_thread_state64_get_lr(state);
        uint64_t fp = arm_thread_state64_get_fp(state);
        Dl_info di = {0}, di2 = {0};
        const char *sym = "?";
        const char *sym2 = "?";
        if (dladdr((void *)(uintptr_t)pc, &di) && di.dli_sname) sym = di.dli_sname;
        if (dladdr((void *)(uintptr_t)lr, &di2) && di2.dli_sname) sym2 = di2.dli_sname;
        LBABSyncProbe([NSString stringWithFormat:
                       @"ai_main_block_pc r=%d pc=%llx lr=%llx",
                       round, (unsigned long long)pc, (unsigned long long)lr]);
        LBAIWriteLong([NSString stringWithFormat:
                       @"ai_main_block_pc r=%d pc=%llx(%s) lr=%llx(%s) fp=%llx wait=%d src=%d drain=%d",
                       round,
                       (unsigned long long)pc, sym,
                       (unsigned long long)lr, sym2,
                       (unsigned long long)fp,
                       atomic_load(&sAIMainRlBeforeWaiting),
                       atomic_load(&sAIMainRlBeforeSources),
                       atomic_load(&sAIMainDrainSeen)]);
    } else {
        LBABSyncProbe([NSString stringWithFormat:@"ai_main_sample_state_fail r=%d kr=%d", round, (int)kr]);
    }
#else
    LBABSyncProbe([NSString stringWithFormat:@"ai_main_sample_skip_arch r=%d", round]);
#endif
    (void)thread_resume(mainTh);
}

static void LBAIStartMainBlockSampler(void) {
    int expected = 0;
    if (!atomic_compare_exchange_strong(&sAIMainSamplerStarted, &expected, 1)) return;
    LBAIEnsureRunLoopObserver();
    atomic_store(&sAIMainDrainSeen, 0);
    dispatch_async(dispatch_get_main_queue(), ^{
        atomic_store(&sAIMainDrainSeen, 1);
        LBABSyncProbe([NSString stringWithFormat:
                       @"ai_main_drain_slot wait=%d src=%d",
                       atomic_load(&sAIMainRlBeforeWaiting),
                       atomic_load(&sAIMainRlBeforeSources)]);
    });
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (int i = 0; i < 25; i++) {
            usleep(100000); // 100ms
            int drained = atomic_load(&sAIMainDrainSeen);
            int waitN = atomic_load(&sAIMainRlBeforeWaiting);
            int srcN = atomic_load(&sAIMainRlBeforeSources);
            LBABSyncProbe([NSString stringWithFormat:
                           @"ai_main_watch i=%d drain=%d wait=%d src=%d bgWin=%d",
                           i, drained, waitN, srcN, atomic_load(&sAIBgWindowsHit)]);
            if (!drained && (i == 2 || i == 5 || i == 10 || i == 15)) {
                LBAISampleMainThreadPC(i);
            }
            if (drained && waitN > 0) {
                LBABSyncProbe([NSString stringWithFormat:@"ai_main_watch_done i=%d", i]);
                break;
            }
        }
        LBABSyncProbe([NSString stringWithFormat:
                       @"ai_main_watch_end drain=%d wait=%d src=%d bgWin=%d",
                       atomic_load(&sAIMainDrainSeen),
                       atomic_load(&sAIMainRlBeforeWaiting),
                       atomic_load(&sAIMainRlBeforeSources),
                       atomic_load(&sAIBgWindowsHit)]);
    });
}

/// AK：按符号粗分类主线程阻塞点（勿叠 WakeUp；仅取证）
/// AL：ICU/本地化单独打 al_icu_trigger（主忙因标签）
static NSString *LBAKClassifyMainBlock(const char *sym, const char *sym2) {
    NSString *a = sym ? [NSString stringWithUTF8String:sym] : @"";
    NSString *b = sym2 ? [NSString stringWithUTF8String:sym2] : @"";
    NSString *blob = [[NSString stringWithFormat:@"%@ %@", a, b] lowercaseString];
    if ([blob containsString:@"dispatch_sync"] || [blob containsString:@"_dispatch_barrier_sync"] ||
        [blob containsString:@"dispatch_lane_barrier"]) {
        return @"ak_main_block_dispatch_sync";
    }
    if ([blob containsString:@"mach_msg"] || [blob containsString:@"kevent"] ||
        [blob containsString:@"__psynch"] || [blob containsString:@"semaphore_wait"] ||
        [blob containsString:@"cfrunloop"] || [blob containsString:@"gsvent"]) {
        return @"ak_main_block_runloop_wait";
    }
    if ([blob containsString:@"legadobridge"] || [blob containsString:@"lbload"] ||
        [blob containsString:@"lbforensics"] || [blob containsString:@"lbab"] ||
        [blob containsString:@"lbai"]) {
        return @"ak_main_block_bridge";
    }
    if ([blob containsString:@"uikit"] || [blob containsString:@"uiwindow"] ||
        [blob containsString:@"uiview"]) {
        return @"ak_main_block_uikit";
    }
    // AL：ICU / CLDR / 货币本地化（AK 已见 DecimalFormatSymbols / ResourceArray）
    if ([blob containsString:@"icu"] || [blob containsString:@"ures_"] ||
        [blob containsString:@"ucurr"] || [blob containsString:@"resourcearray"] ||
        [blob containsString:@"res_gettable"] || [blob containsString:@"decimalformatsymbols"] ||
        [blob containsString:@"uloc_"]) {
        return @"al_icu_busy";
    }
    if (a.length == 0 || [a isEqualToString:@"?"]) {
        return @"ak_main_block_nosym";
    }
    return @"ak_main_block_other";
}

static atomic_int sAKIdleForensicsInFlight = 0;

static void LBAKSampleMainThreadPC(int round) {
    if ([NSThread isMainThread]) return;
    mach_port_t mainTh = sAIMainMachThread;
    if (mainTh == MACH_PORT_NULL) {
        LBABSyncProbe([NSString stringWithFormat:@"ak_main_block_no_port r=%d", round]);
        return;
    }
    if (thread_suspend(mainTh) != KERN_SUCCESS) {
        LBABSyncProbe([NSString stringWithFormat:@"ak_main_block_suspend_fail r=%d", round]);
        return;
    }
#if defined(__aarch64__)
    arm_thread_state64_t state;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    kern_return_t kr = thread_get_state(mainTh, ARM_THREAD_STATE64,
                                        (thread_state_t)&state, &count);
    if (kr == KERN_SUCCESS) {
        uint64_t pc = arm_thread_state64_get_pc(state);
        uint64_t lr = arm_thread_state64_get_lr(state);
        uint64_t fp = arm_thread_state64_get_fp(state);
        Dl_info di = {0}, di2 = {0};
        const char *sym = "?";
        const char *sym2 = "?";
        if (dladdr((void *)(uintptr_t)pc, &di) && di.dli_sname) sym = di.dli_sname;
        if (dladdr((void *)(uintptr_t)lr, &di2) && di2.dli_sname) sym2 = di2.dli_sname;
        NSString *cls = LBAKClassifyMainBlock(sym, sym2);
        if ([cls isEqualToString:@"al_icu_busy"]) {
            LBABSyncProbe([NSString stringWithFormat:
                           @"al_icu_trigger r=%d pc=%s lr=%s", round, sym, sym2]);
        }
        LBABSyncProbe([NSString stringWithFormat:
                       @"%@ r=%d pc=%llx(%s) lr=%llx(%s) wait=%d src=%d drain=%d",
                       cls, round,
                       (unsigned long long)pc, sym,
                       (unsigned long long)lr, sym2,
                       atomic_load(&sAIMainRlBeforeWaiting),
                       atomic_load(&sAIMainRlBeforeSources),
                       atomic_load(&sAIMainDrainSeen)]);
        LBAIWriteLong([NSString stringWithFormat:
                       @"ak_main_block_pc r=%d class=%@ pc=%llx(%s) lr=%llx(%s) fp=%llx wait=%d src=%d drain=%d",
                       round, cls,
                       (unsigned long long)pc, sym,
                       (unsigned long long)lr, sym2,
                       (unsigned long long)fp,
                       atomic_load(&sAIMainRlBeforeWaiting),
                       atomic_load(&sAIMainRlBeforeSources),
                       atomic_load(&sAIMainDrainSeen)]);
    } else {
        LBABSyncProbe([NSString stringWithFormat:@"ak_main_block_state_fail r=%d kr=%d", round, (int)kr]);
    }
#else
    LBABSyncProbe([NSString stringWithFormat:@"ak_main_block_skip_arch r=%d", round]);
#endif
    (void)thread_resume(mainTh);
}

/// AK：idle 后立即密集采 PC（禁 WakeUp / 禁 drain enqueue）
static void LBAKStartPostIdleMainBlockForensics(void) {
    // AW：postQF 窗禁 AK main PC 采样。
    // AV 真机证据：AV 拆 LBFHook↔LBAB 互套环 + AU RecordQuiet 后仍崩在同一点
    // pc=1cc50dfdc（CoreFoundation）postQF=1 tid=259，fault=栈地址 si_code=2（栈 guard page 写穿）。
    // 根因：AK 的 LBAKSampleMainThreadPC 在 postQF 窗后台线程调用 thread_suspend(mainTh) +
    // thread_get_state + dladdr + LBABSyncProbe([NSString stringWithFormat:])（CFString），
    // 与 post_cb_hb 后台线程并发；thread_suspend 挂起 main 时若 main 正持有 CFString 内部锁，
    // 后台线程 CFString 操作访问被锁保护的内存 -> SEGV_ACCERR@__CFStringAppendBytes 子函数。
    // 崩溃时间线印证：ak_main_idle_forensics_start 后 am_post_cb_hb i=1,2,3 即崩（两后台线程并发）。
    // AW：postQF 窗（sALPostQF=1）直接 return，禁 AK 采样，消除并发 thread_suspend + CFString 冲突。
    if (atomic_load(&sALPostQF)) {
        LBABSyncProbe(@"aw_postqf_ak_main_pc_sampling_disabled");
        return;
    }
    int expected = 0;
    if (!atomic_compare_exchange_strong(&sAKIdleForensicsInFlight, &expected, 1)) {
        LBABSyncProbe(@"ak_main_idle_forensics_busy");
        return;
    }
    if ([NSThread isMainThread]) {
        LBAICaptureMainMachThread();
    }
    LBABSyncProbe(@"ak_main_idle_forensics_start");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        const useconds_t delays[] = {0, 30000, 80000, 150000, 300000, 500000};
        useconds_t prev = 0;
        for (int i = 0; i < (int)(sizeof(delays) / sizeof(delays[0])); i++) {
            useconds_t d = delays[i];
            if (d > prev) usleep(d - prev);
            prev = d;
            LBAKSampleMainThreadPC(i);
        }
        LBABSyncProbe([NSString stringWithFormat:
                       @"ak_main_idle_forensics_end wait=%d src=%d drain=%d bgWin=%d",
                       atomic_load(&sAIMainRlBeforeWaiting),
                       atomic_load(&sAIMainRlBeforeSources),
                       atomic_load(&sAIMainDrainSeen),
                       atomic_load(&sAIBgWindowsHit)]);
        atomic_store(&sAKIdleForensicsInFlight, 0);
    });
}

/// AL/AN：async-signal-safe 致命栈（PC/LR/FP/tid + QF 窗标志）；禁 ObjC
/// AN 注：nativeOpen 的 signal() 与 DebugPanel 会覆盖本 handler → 须在 post-cb 窗 LBANClaimFaultHandlers 夺回
static void LBALFatalSignalHandler(int sig, siginfo_t *info, void *ctx) {
    uint64_t pc = 0, lr = 0, fp = 0;
#if defined(__aarch64__) || defined(__arm64__)
    ucontext_t *uc = (ucontext_t *)ctx;
    if (uc && uc->uc_mcontext) {
        pc = (uint64_t)uc->uc_mcontext->__ss.__pc;
        lr = (uint64_t)uc->uc_mcontext->__ss.__lr;
        fp = (uint64_t)uc->uc_mcontext->__ss.__fp;
    }
#else
    (void)ctx;
#endif
    uint64_t fault = info ? (uint64_t)(uintptr_t)info->si_addr : 0;
    int qf = atomic_load(&sALInQF);
    int post = atomic_load(&sALPostQF);
    char mark[384];
    int n = snprintf(mark, sizeof(mark),
                     "hypothesis_AC an_fault_signal SIG=%d si_code=%d fault=%llx "
                     "pc=%llx lr=%llx fp=%llx tid=%lu pid=%d inQF=%d postQF=%d\n",
                     sig,
                     info ? info->si_code : -1,
                     (unsigned long long)fault,
                     (unsigned long long)pc,
                     (unsigned long long)lr,
                     (unsigned long long)fp,
                     (unsigned long)pthread_mach_thread_np(pthread_self()),
                     (int)getpid(),
                     qf,
                     post);
    char markAl[384];
    int nAl = snprintf(markAl, sizeof(markAl),
                       "hypothesis_AC al_fatal_signal SIG=%d si_code=%d fault=%llx "
                       "pc=%llx lr=%llx fp=%llx tid=%lu pid=%d inQF=%d postQF=%d\n",
                       sig,
                       info ? info->si_code : -1,
                       (unsigned long long)fault,
                       (unsigned long long)pc,
                       (unsigned long long)lr,
                       (unsigned long long)fp,
                       (unsigned long)pthread_mach_thread_np(pthread_self()),
                       (int)getpid(),
                       qf,
                       post);
    // AO：独立标签，避免仅扫 an_ 时漏；与 an/al 同内容
    char markAo[384];
    int nAo = snprintf(markAo, sizeof(markAo),
                       "hypothesis_AC ao_fault_signal SIG=%d si_code=%d fault=%llx "
                       "pc=%llx lr=%llx fp=%llx tid=%lu pid=%d inQF=%d postQF=%d\n",
                       sig,
                       info ? info->si_code : -1,
                       (unsigned long long)fault,
                       (unsigned long long)pc,
                       (unsigned long long)lr,
                       (unsigned long long)fp,
                       (unsigned long)pthread_mach_thread_np(pthread_self()),
                       (int)getpid(),
                       qf,
                       post);
    const char *home = getenv("HOME");
    char path[512];
    if (home && home[0]) {
        snprintf(path, sizeof(path), "%s/Documents/legado_ab_probe.txt", home);
    } else {
        snprintf(path, sizeof(path), "/tmp/legado_ab_probe.txt");
    }
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        if (n > 0) (void)write(fd, mark, (size_t)n);
        if (nAl > 0) (void)write(fd, markAl, (size_t)nAl);
        if (nAo > 0) (void)write(fd, markAo, (size_t)nAo);
        (void)fsync(fd);
        close(fd);
    }
    // 同步写 /tmp，崩溃后 Documents 可能未刷盘时仍可捞
    fd = open("/tmp/legado_al_fatal.txt", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        if (nAl > 0) (void)write(fd, markAl, (size_t)nAl);
        if (n > 0) (void)write(fd, mark, (size_t)n);
        if (nAo > 0) (void)write(fd, markAo, (size_t)nAo);
        (void)fsync(fd);
        close(fd);
    }
    fd = open("/tmp/legado_an_fault.txt", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        if (n > 0) (void)write(fd, mark, (size_t)n);
        if (nAo > 0) (void)write(fd, markAo, (size_t)nAo);
        (void)fsync(fd);
        close(fd);
    }
    fd = open("/tmp/legado_ao_fault.txt", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        if (nAo > 0) (void)write(fd, markAo, (size_t)nAo);
        if (n > 0) (void)write(fd, mark, (size_t)n);
        (void)fsync(fd);
        close(fd);
    }
    if (home && home[0]) {
        snprintf(path, sizeof(path), "%s/Documents/legado_an_fault.txt", home);
        fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) {
            if (n > 0) (void)write(fd, mark, (size_t)n);
            if (nAo > 0) (void)write(fd, markAo, (size_t)nAo);
            (void)fsync(fd);
            close(fd);
        }
        snprintf(path, sizeof(path), "%s/Documents/legado_ao_fault.txt", home);
        fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) {
            if (nAo > 0) (void)write(fd, markAo, (size_t)nAo);
            (void)fsync(fd);
            close(fd);
        }
    }
    // AP：async-signal-safe FP 栈（仅原始址；禁 dladdr/ObjC）
    LBAPWriteFpStack(fp, pc, lr);
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = SIG_DFL;
    sigemptyset(&sa.sa_mask);
    sigaction(sig, &sa, NULL);
    raise(sig);
}

/// AP：故障线程 FP 链（arm64：*fp=prev，*(fp+8)=ret）
static void LBAPWriteFpStack(uint64_t fp, uint64_t pc, uint64_t lr) {
    char line[768];
    int pos = snprintf(line, sizeof(line),
                       "hypothesis_AC ap_fault_fpstack tid=%lu pc=%llx lr=%llx fp=%llx",
                       (unsigned long)pthread_mach_thread_np(pthread_self()),
                       (unsigned long long)pc,
                       (unsigned long long)lr,
                       (unsigned long long)fp);
    if (pos < 0) pos = 0;
    uint64_t cur = fp;
    for (int i = 0; i < 20 && pos < (int)sizeof(line) - 24; i++) {
        if (cur < 0x1000ULL || (cur & 0x7ULL) != 0) break;
        uint64_t *frame = (uint64_t *)(uintptr_t)cur;
        uint64_t next = frame[0];
        uint64_t ret = frame[1];
        int n = snprintf(line + pos, sizeof(line) - (size_t)pos,
                         " | f%d=%llx", i, (unsigned long long)ret);
        if (n <= 0) break;
        pos += n;
        if (next <= cur) break;
        cur = next;
    }
    if (pos < (int)sizeof(line) - 2) {
        line[pos++] = '\n';
        line[pos] = 0;
    }
    const char *home = getenv("HOME");
    char path[512];
    int fd = open("/tmp/legado_ap_fault_fp.txt", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        (void)write(fd, line, (size_t)pos);
        (void)fsync(fd);
        close(fd);
    }
    fd = open("/tmp/legado_ao_fault.txt", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        (void)write(fd, line, (size_t)pos);
        (void)fsync(fd);
        close(fd);
    }
    if (home && home[0]) {
        snprintf(path, sizeof(path), "%s/Documents/legado_ab_probe.txt", home);
        fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) {
            (void)write(fd, line, (size_t)pos);
            (void)fsync(fd);
            close(fd);
        }
        snprintf(path, sizeof(path), "%s/Documents/legado_ap_fault_fp.txt", home);
        fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) {
            (void)write(fd, line, (size_t)pos);
            (void)fsync(fd);
            close(fd);
        }
    }
}

/// AP：dladdr → img/fbase/off/sname（sname 可能为 `<redacted>`，off 可离线对照 DSC）
static void LBAPLogDladdrAddr(const char *tag, uint64_t addr) {
    Dl_info di;
    memset(&di, 0, sizeof(di));
    const char *img = "?";
    const char *sname = "-";
    uint64_t fbase = 0;
    uint64_t off = 0;
    if (addr && dladdr((void *)(uintptr_t)addr, &di)) {
        if (di.dli_fname) {
            const char *slash = strrchr(di.dli_fname, '/');
            img = slash ? slash + 1 : di.dli_fname;
        }
        if (di.dli_sname) sname = di.dli_sname;
        if (di.dli_fbase) {
            fbase = (uint64_t)(uintptr_t)di.dli_fbase;
            off = addr - fbase;
        }
    }
    char sbuf[72];
    snprintf(sbuf, sizeof(sbuf), "%.60s", sname);
    LBABSyncProbe([NSString stringWithFormat:
                   @"ap_fault_sym tag=%s addr=%llx img=%s fbase=%llx off=%llx sname=%s",
                   tag && tag[0] ? tag : "?",
                   (unsigned long long)addr, img,
                   (unsigned long long)fbase, (unsigned long long)off, sbuf]);
}

static void LBAPLogCFAnchor(void) {
    const char *names[] = {"CFRetain", "CFRelease", "CFArrayGetCount", "CFDictionaryGetValue", NULL};
    for (int i = 0; names[i]; i++) {
        void *p = dlsym(RTLD_DEFAULT, names[i]);
        if (!p) continue;
        LBAPLogDladdrAddr(names[i], (uint64_t)(uintptr_t)p);
    }
}

/// AP：postQF 窗采样当前线程符号化栈 + 各线程 PC 的 fbase/off
static void LBAPDumpPostQFStacks(const char *why) {
    NSString *stack = LBANSymbolStack(16);
    LBABSyncProbe([NSString stringWithFormat:
                   @"ap_postqf_stack why=%s main=%d stack=%@",
                   why && why[0] ? why : "?",
                   [NSThread isMainThread] ? 1 : 0, stack]);
    LBAIWriteLong([NSString stringWithFormat:
                   @"ap_postqf_stack why=%s main=%d stack=%@",
                   why && why[0] ? why : "?",
                   [NSThread isMainThread] ? 1 : 0, stack]);
#if defined(__aarch64__)
    // 先采寄存器再 resume，再 dladdr/写日志，避免挂起时拿锁死锁
    uint64_t pcs[10] = {0};
    uint64_t lrs[10] = {0};
    int got = 0;
    thread_act_array_t threads = NULL;
    mach_msg_type_number_t n = 0;
    if (task_threads(mach_task_self(), &threads, &n) == KERN_SUCCESS) {
        int lim = (int)n;
        if (lim > 10) lim = 10;
        for (int i = 0; i < lim; i++) {
            if (thread_suspend(threads[i]) != KERN_SUCCESS) continue;
            arm_thread_state64_t state;
            mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
            if (thread_get_state(threads[i], ARM_THREAD_STATE64,
                                 (thread_state_t)&state, &count) == KERN_SUCCESS) {
                pcs[got] = arm_thread_state64_get_pc(state);
                lrs[got] = arm_thread_state64_get_lr(state);
                got++;
            }
            (void)thread_resume(threads[i]);
        }
        for (mach_msg_type_number_t i = 0; i < n; i++) {
            mach_port_deallocate(mach_task_self(), threads[i]);
        }
        vm_deallocate(mach_task_self(), (vm_address_t)threads, n * sizeof(thread_t));
    }
    for (int i = 0; i < got; i++) {
        char tag[32];
        snprintf(tag, sizeof(tag), "t%d_pc", i);
        LBAPLogDladdrAddr(tag, pcs[i]);
        snprintf(tag, sizeof(tag), "t%d_lr", i);
        LBAPLogDladdrAddr(tag, lrs[i]);
    }
#endif
}

/// AN：夺回 SIGSEGV/BUS… handler（对抗 nativeOpen signal() / DebugPanel 覆盖）
static void LBANClaimFaultHandlers(const char *why) {
    stack_t ss;
    memset(&ss, 0, sizeof(ss));
    ss.ss_sp = sALAltStack;
    ss.ss_size = sizeof(sALAltStack);
    ss.ss_flags = 0;
    (void)sigaltstack(&ss, NULL);
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = LBALFatalSignalHandler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);
    sigaction(SIGTRAP, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);
    sABSignalInstalled = YES;
    LBALInstallExceptionProbe();
    LBABSyncProbe([NSString stringWithFormat:@"an_fault_claim why=%s",
                   why && why[0] ? why : "?"]);
    LBABSyncProbe([NSString stringWithFormat:@"ao_fault_claim why=%s",
                   why && why[0] ? why : "?"]);
}

/// AO：查 SIGSEGV handler 是否仍是我们的；被盖则立刻夺回
static void LBAOProbeFaultHandler(const char *why) {
    struct sigaction cur;
    memset(&cur, 0, sizeof(cur));
    sigaction(SIGSEGV, NULL, &cur);
    int ours = 0;
    if ((cur.sa_flags & SA_SIGINFO) != 0 &&
        cur.sa_sigaction == LBALFatalSignalHandler) {
        ours = 1;
    }
    LBABSyncProbe([NSString stringWithFormat:
                   @"ao_fault_handler ours=%d sa_flags=0x%x why=%s",
                   ours, (unsigned)cur.sa_flags,
                   why && why[0] ? why : "?"]);
    if (!ours) {
        LBANClaimFaultHandlers(why && why[0] ? why : "stolen");
    }
}

typedef void (*LBAOSetQFWindowFn)(int, int);
typedef void (*LBAOEmitHookStatsFn)(const char *);
typedef void (*LBAOSetRecordQuietFn)(int);

static void LBAONotifyForensicsWindow(int inQF, int postQF) {
    static LBAOSetQFWindowFn fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (LBAOSetQFWindowFn)dlsym(RTLD_DEFAULT, "LBForensicsSetQFWindow");
    });
    if (fn) fn(inQF, postQF);
}

/// AU：postQF 窗静默 LBFRecordEvent 写事件（dlsym 查 LBForensicsSetRecordQuiet）。
/// AT 真机证据：禁 post_cb_hb 内部采样后仍崩在 pc=__CFStringAppendBytes postQF=1 tid=bg。
/// 根因：AR depth 守卫是 _Thread_local，只防单线程深递归；postQF 窗 main 线程每次
/// UIView drawRect 都以 depth=1 进 LBFRecordEvent，守卫不触发，仍创建 NSDictionary/NSString
/// 大量 CFString。这些与 post_cb_hb 后台线程的 CFString 操作跨线程冲突，致 SEGV_ACCERR。
/// AU：postQF 窗开 RecordQuiet=1，LBFRecordEvent 直接 return 不做任何 CFString 操作，
/// 彻底消除 main↔bg 跨线程 CFString 冲突。trampoline 仍调 orig 保留功能。
static void LBAONotifyRecordQuiet(int quiet) {
    static LBAOSetRecordQuietFn fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (LBAOSetRecordQuietFn)dlsym(RTLD_DEFAULT, "LBForensicsSetRecordQuiet");
    });
    if (fn) fn(quiet ? 1 : 0);
}

static void LBAOEmitLBFStats(const char *why) {
    static LBAOEmitHookStatsFn fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (LBAOEmitHookStatsFn)dlsym(RTLD_DEFAULT, "LBForensicsEmitHookStats");
    });
    if (fn) fn(why && why[0] ? why : "?");
}

static void LBABInstallSignalProbes(void) {
    // 首次安装；夺回留给 post-cb / hb（nativeOpen signal() 在 open 路径覆盖）
    if (!sABSignalInstalled) {
        LBANClaimFaultHandlers("install");
    }
}

/// AN：符号化短栈（ObjC -[Class sel] 优先；否则 image!sym+off / image+off）
static NSString *LBANSymbolStack(NSUInteger maxFrames) {
    NSArray *addrs = [NSThread callStackReturnAddresses];
    NSArray *syms = [NSThread callStackSymbols];
    if (![addrs isKindOfClass:[NSArray class]] || addrs.count == 0) return @"-";
    NSMutableArray *keep = [NSMutableArray array];
    NSUInteger skip = 2; // 本函数 + 钩子
    for (NSUInteger i = skip; i < addrs.count && keep.count < maxFrames; i++) {
        NSString *label = nil;
        if ([syms isKindOfClass:[NSArray class]] && i < syms.count) {
            NSString *s = [syms[i] description];
            NSRange r1 = [s rangeOfString:@"-["];
            NSRange r2 = [s rangeOfString:@"+["];
            NSRange r = (r1.location != NSNotFound) ? r1 : r2;
            if (r.location != NSNotFound) {
                NSString *tail = [s substringFromIndex:r.location];
                NSRange end = [tail rangeOfString:@"]"];
                if (end.location != NSNotFound) {
                    label = [tail substringToIndex:end.location + 1];
                }
            }
        }
        if (!label) {
            uintptr_t addr = (uintptr_t)[addrs[i] unsignedIntegerValue];
            Dl_info di;
            memset(&di, 0, sizeof(di));
            if (dladdr((void *)addr, &di)) {
                const char *fname = di.dli_fname ? di.dli_fname : "?";
                const char *slash = strrchr(fname, '/');
                const char *img = slash ? slash + 1 : fname;
                if (di.dli_sname && di.dli_saddr) {
                    label = [NSString stringWithFormat:@"%s!%s+0x%lx",
                             img, di.dli_sname,
                             (unsigned long)(addr - (uintptr_t)di.dli_saddr)];
                } else if (di.dli_fbase) {
                    label = [NSString stringWithFormat:@"%s+0x%lx",
                             img, (unsigned long)(addr - (uintptr_t)di.dli_fbase)];
                }
            }
            if (!label) {
                label = [NSString stringWithFormat:@"0x%lx",
                         (unsigned long)[addrs[i] unsignedIntegerValue]];
            }
        }
        if (label.length > 96) label = [label substringToIndex:96];
        [keep addObject:label];
    }
    return keep.count ? [keep componentsJoinedByString:@" < "] : @"-";
}

/// AN：hb 窗 main PC 分类 → 对照 mem 陡升是否 ICU/分页同源（仅挂起主线程，禁全线程 suspend）
static const char *LBANClassifySym(const char *sym, const char *img) {
    if (!sym) sym = "";
    if (!img) img = "";
    if (strstr(sym, "icu") || strstr(sym, "DateFormat") || strstr(sym, "NumberFormat") ||
        strstr(sym, "ures_") || strstr(sym, "uchar_") || strstr(sym, "uhash_") ||
        strstr(sym, "uloc_") || strstr(sym, "DecimalFormat") ||
        strstr(img, "icucore") || strstr(img, "libicucore")) {
        return "icu";
    }
    if (strstr(sym, "CTFrame") || strstr(sym, "CTLine") || strstr(sym, "CTTypesetter") ||
        strstr(sym, "CTRun") || strstr(sym, "NSAttributed") || strstr(sym, "TextR") ||
        strstr(sym, "division") || strstr(sym, "PageContainer") || strstr(sym, "ReadPage") ||
        strstr(sym, "CoreText") || strstr(img, "CoreText")) {
        return "page";
    }
    if (strstr(sym, "CFString") || strstr(sym, "malloc") || strstr(sym, "calloc") ||
        strstr(sym, "objc_") || strstr(sym, "CFAllocator")) {
        return "alloc";
    }
    return "other";
}

static void LBANSampleMemPath(int i, long ms, long mem) {
    mach_port_t mainTh = sAIMainMachThread;
    if (mainTh == MACH_PORT_NULL) {
        LBABSyncProbe([NSString stringWithFormat:
                       @"an_mem_path i=%d ms=%ld mem=%ld class=nosample pc=- lr=-",
                       i, ms, mem]);
        return;
    }
    if (thread_suspend(mainTh) != KERN_SUCCESS) {
        LBABSyncProbe([NSString stringWithFormat:
                       @"an_mem_path i=%d ms=%ld mem=%ld class=suspend_fail pc=- lr=-",
                       i, ms, mem]);
        return;
    }
#if defined(__aarch64__)
    arm_thread_state64_t state;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    kern_return_t kr = thread_get_state(mainTh, ARM_THREAD_STATE64,
                                        (thread_state_t)&state, &count);
    if (kr == KERN_SUCCESS) {
        uint64_t pc = arm_thread_state64_get_pc(state);
        uint64_t lr = arm_thread_state64_get_lr(state);
        Dl_info di = {0}, di2 = {0};
        const char *sym = "?";
        const char *sym2 = "?";
        const char *img = "?";
        uint64_t fbase = 0, off = 0, fbase2 = 0, off2 = 0;
        if (dladdr((void *)(uintptr_t)pc, &di)) {
            if (di.dli_sname) sym = di.dli_sname;
            if (di.dli_fname) {
                const char *slash = strrchr(di.dli_fname, '/');
                img = slash ? slash + 1 : di.dli_fname;
            }
            if (di.dli_fbase) {
                fbase = (uint64_t)(uintptr_t)di.dli_fbase;
                off = pc - fbase;
            }
        }
        if (dladdr((void *)(uintptr_t)lr, &di2)) {
            if (di2.dli_sname) sym2 = di2.dli_sname;
            if (di2.dli_fbase) {
                fbase2 = (uint64_t)(uintptr_t)di2.dli_fbase;
                off2 = lr - fbase2;
            }
        }
        const char *cls = LBANClassifySym(sym, img);
        char symBuf[72];
        char lrBuf[72];
        snprintf(symBuf, sizeof(symBuf), "%.60s", sym);
        snprintf(lrBuf, sizeof(lrBuf), "%.60s", sym2);
        LBABSyncProbe([NSString stringWithFormat:
                       @"an_mem_path i=%d ms=%ld mem=%ld class=%s img=%s pc=%llx(%s) lr=%llx(%s) "
                       @"fbase=%llx off=%llx lr_fbase=%llx lr_off=%llx",
                       i, ms, mem, cls, img,
                       (unsigned long long)pc, symBuf,
                       (unsigned long long)lr, lrBuf,
                       (unsigned long long)fbase, (unsigned long long)off,
                       (unsigned long long)fbase2, (unsigned long long)off2]);
    } else {
        LBABSyncProbe([NSString stringWithFormat:
                       @"an_mem_path i=%d ms=%ld mem=%ld class=state_fail pc=- lr=-",
                       i, ms, mem]);
    }
#else
    LBABSyncProbe([NSString stringWithFormat:
                   @"an_mem_path i=%d ms=%ld mem=%ld class=skip_arch pc=- lr=-",
                   i, ms, mem]);
#endif
    (void)thread_resume(mainTh);
}

static void LBALUncaughtException(NSException *ex) {
    NSString *name = ex.name ?: @"?";
    NSString *reason = ex.reason ?: @"?";
    if (reason.length > 160) reason = [reason substringToIndex:160];
    NSString *stack = LBAICompactStack(16);
    LBABSyncProbe([NSString stringWithFormat:
                   @"al_uncaught_exception name=%@ reason=%@ inQF=%d postQF=%d",
                   name, reason,
                   atomic_load(&sALInQF), atomic_load(&sALPostQF)]);
    LBAIWriteLong([NSString stringWithFormat:
                   @"al_uncaught_exception name=%@ reason=%@ stack=%@",
                   name, reason, stack]);
}

static void LBALInstallExceptionProbe(void) {
    static int once = 0;
    if (once) return;
    once = 1;
    NSSetUncaughtExceptionHandler(&LBALUncaughtException);
}

/// AL：QF/死后窗内非主线程 UIKit 调用标签（不拦截，只打点）
static void (*sALNextSetNeedsLayout)(id, SEL) = NULL;
static void (*sALNextLayoutIfNeeded)(id, SEL) = NULL;
static void (*sALNextSetNeedsDisplay)(id, SEL) = NULL;
static atomic_int sALQFUIKitHooked = 0;

static void LBALLogQFUIKit(SEL sel, id selfObj) {
    if ([NSThread isMainThread]) return;
    if (!atomic_load(&sALInQF) && !atomic_load(&sALPostQF)) return;
    int n = atomic_fetch_add(&sALQFUIKitHit, 1) + 1;
    if (n > 24) return;
    NSString *cls = selfObj ? NSStringFromClass(object_getClass(selfObj)) : @"nil";
    NSString *stack = (n <= 8) ? LBAICompactStack(12) : @"-";
    LBABSyncProbe([NSString stringWithFormat:
                   @"al_qf_uikit sel=%@ cls=%@ hit=%d inQF=%d postQF=%d",
                   NSStringFromSelector(sel) ?: @"?",
                   cls, n,
                   atomic_load(&sALInQF), atomic_load(&sALPostQF)]);
    if (n <= 8) {
        LBAIWriteLong([NSString stringWithFormat:
                       @"al_qf_uikit sel=%@ cls=%@ hit=%d stack=%@",
                       NSStringFromSelector(sel) ?: @"?", cls, n, stack]);
    }
}

static void LBAL_SetNeedsLayout(id self, SEL _cmd) {
    LBALLogQFUIKit(_cmd, self);
    if (sALNextSetNeedsLayout) sALNextSetNeedsLayout(self, _cmd);
}

static void LBAL_LayoutIfNeeded(id self, SEL _cmd) {
    LBALLogQFUIKit(_cmd, self);
    if (sALNextLayoutIfNeeded) sALNextLayoutIfNeeded(self, _cmd);
}

static void LBAL_SetNeedsDisplay(id self, SEL _cmd) {
    LBALLogQFUIKit(_cmd, self);
    if (sALNextSetNeedsDisplay) sALNextSetNeedsDisplay(self, _cmd);
}

static void LBALInstallQFUIKitHooks(void) {
    int expected = 0;
    if (!atomic_compare_exchange_strong(&sALQFUIKitHooked, &expected, 1)) return;
    Class cls = [UIView class];
    if (!cls) {
        LBABSyncProbe(@"al_qf_uikit_hook_missing");
        atomic_store(&sALQFUIKitHooked, 0);
        return;
    }
    struct { SEL sel; IMP imp; void (**slot)(id, SEL); } specs[] = {
        { @selector(setNeedsLayout), (IMP)LBAL_SetNeedsLayout, &sALNextSetNeedsLayout },
        { @selector(layoutIfNeeded), (IMP)LBAL_LayoutIfNeeded, &sALNextLayoutIfNeeded },
        { @selector(setNeedsDisplay), (IMP)LBAL_SetNeedsDisplay, &sALNextSetNeedsDisplay },
    };
    for (size_t i = 0; i < sizeof(specs) / sizeof(specs[0]); i++) {
        Method m = class_getInstanceMethod(cls, specs[i].sel);
        if (!m) continue;
        IMP cur = method_getImplementation(m);
        if (cur == specs[i].imp) continue;
        *(specs[i].slot) = (void (*)(id, SEL))cur;
        method_setImplementation(m, specs[i].imp);
    }
    LBABSyncProbe(@"al_qf_uikit_hook_ok");
}

/// AL：cb 后采样非主线程 PC（杀因可能在 QF 完成后的旁路线程）
static void LBALSampleThreadPC(thread_t th, int idx) {
    if (th == MACH_PORT_NULL) return;
    if (thread_suspend(th) != KERN_SUCCESS) return;
#if defined(__aarch64__)
    arm_thread_state64_t state;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    kern_return_t kr = thread_get_state(th, ARM_THREAD_STATE64,
                                        (thread_state_t)&state, &count);
    if (kr == KERN_SUCCESS) {
        uint64_t pc = arm_thread_state64_get_pc(state);
        uint64_t lr = arm_thread_state64_get_lr(state);
        Dl_info di = {0}, di2 = {0};
        const char *sym = "?";
        const char *sym2 = "?";
        if (dladdr((void *)(uintptr_t)pc, &di) && di.dli_sname) sym = di.dli_sname;
        if (dladdr((void *)(uintptr_t)lr, &di2) && di2.dli_sname) sym2 = di2.dli_sname;
        BOOL isMain = (th == sAIMainMachThread);
        LBABSyncProbe([NSString stringWithFormat:
                       @"al_thr_pc i=%d main=%d pc=%llx(%s) lr=%llx(%s)",
                       idx, isMain ? 1 : 0,
                       (unsigned long long)pc, sym,
                       (unsigned long long)lr, sym2]);
    }
#endif
    (void)thread_resume(th);
}

static void LBALStartPostCbThreadSample(void) {
    static atomic_int sOnce = 0;
    int expected = 0;
    if (!atomic_compare_exchange_strong(&sOnce, &expected, 1)) return;
    atomic_store(&sALPostQF, 1);
    LBABSyncProbe(@"al_post_cb_sample_start");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (int round = 0; round < 6; round++) {
            if (round) usleep(40000);
            thread_act_array_t threads = NULL;
            mach_msg_type_number_t n = 0;
            if (task_threads(mach_task_self(), &threads, &n) != KERN_SUCCESS) continue;
            int lim = (int)n;
            if (lim > 12) lim = 12;
            for (int i = 0; i < lim; i++) {
                LBALSampleThreadPC(threads[i], round * 100 + i);
            }
            for (mach_msg_type_number_t i = 0; i < n; i++) {
                mach_port_deallocate(mach_task_self(), threads[i]);
            }
            vm_deallocate(mach_task_self(), (vm_address_t)threads, n * sizeof(thread_t));
        }
        LBABSyncProbe([NSString stringWithFormat:
                       @"al_post_cb_sample_end uikitHit=%d",
                       atomic_load(&sALQFUIKitHit)]);
    });
}

/// AM：cb_exit 后 0–200ms 轻量心跳（POSIX write+fsync；禁全线程 suspend）
/// 钉死窗终点；与 AL 全线程 suspend 采样解耦，避免取证副作用遮盖 exit reason
static void LBAMRawHb(int i, long ms) {
    char mark[192];
    int n = snprintf(mark, sizeof(mark),
                     "hypothesis_AC am_post_cb_hb i=%d ms=%ld pid=%d up=%ld mem=%ld main=%d\n",
                     i, ms, (int)getpid(), LBAGUptimeMs(), LBAGFootprintMB(),
                     pthread_main_np() ? 1 : 0);
    if (n <= 0) return;
    const char *home = getenv("HOME");
    char path[512];
    if (home && home[0]) {
        snprintf(path, sizeof(path), "%s/Documents/legado_ab_probe.txt", home);
    } else {
        snprintf(path, sizeof(path), "/tmp/legado_ab_probe.txt");
    }
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        (void)write(fd, mark, (size_t)n);
        (void)fsync(fd);
        close(fd);
    }
    fd = open("/tmp/legado_am_hb.txt", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        (void)write(fd, mark, (size_t)n);
        (void)fsync(fd);
        close(fd);
    }
}

static void LBAMStartPostCbHeartbeat(void) {
    static atomic_int sOnce = 0;
    int expected = 0;
    if (!atomic_compare_exchange_strong(&sOnce, &expected, 1)) return;
    atomic_store(&sALPostQF, 1);
    LBAONotifyForensicsWindow(0, 1);
    // AZ：postQF 窗逻辑整体 dispatch_async 到独立队列，释放 cb 线程栈。
    // AY 真机证据（决定性）：禁所有 forensics（trampoline hit=0 + 心跳循环禁 + AK 禁 + AT 采样禁）后，
    // 仍崩在 cb 线程（tid=259）从 LBAB_QFCallback 返回 BookQueryManager 时：
    //   [88] am_post_cb_hb_done -> [89] SIG=11 pc=CoreFoundation fault=fp-0x178 tid=259 postQF=1
    // 崩溃时间线：cb 线程执行 format + QF dispatch + LBAMStartPostCbHeartbeat（多个 LBABSyncProbe 栈帧）
    // 后返回 BookQueryManager，BookQueryManager 后续 CFString 操作触碰栈 guard page。
    // 根因：cb 线程 callback 链栈深度 + Bridge 注入的探针栈帧 + BookQueryManager 后续操作 = 栈溢出。
    // AZ：postQF 窗逻辑（RecordQuiet + fault handler 夺回 + 探针 + 心跳）整体 dispatch_async，
    // cb 线程只设 sALPostQF=1 后立即返回，不增加 cb 线程栈深度。
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        LBAONotifyRecordQuiet(1);
        LBANClaimFaultHandlers("post_cb_hb");
        LBAOProbeFaultHandler("post_cb_hb");
        LBAOEmitLBFStats("post_cb_hb");
        LBAMRawHb(0, 0);
        LBABSyncProbe(@"at_postqf_cfstring_sampling_disabled");
        LBABSyncProbe(@"au_postqf_record_quiet_enabled");
        LBABSyncProbe(@"am_post_cb_hb_start");
        LBABSyncProbe(@"ay_tramp_bypass_enabled");
        LBABSyncProbe(@"ax_postqf_hb_loop_disabled");
        LBABSyncProbe(@"am_post_cb_hb_done");
        LBABSyncProbe(@"az_postqf_offloaded_to_utility_queue");
    });
}

/// AM：Date/Currency ICU 上游——钩 NSDateFormatter / NSNumberFormatter / NSLocale（类+SEL+短栈）
static atomic_int sAMICUCallerHit = 0;
static atomic_int sAMICUHooked = 0;
static id (*sAMNextDFInit)(id, SEL) = NULL;
static id (*sAMNextDFStringFromDate)(id, SEL, id) = NULL;
static void (*sAMNextDFSetDateFormat)(id, SEL, id) = NULL;
static id (*sAMNextNFInit)(id, SEL) = NULL;
static id (*sAMNextNFStringFromNumber)(id, SEL, id) = NULL;
static void (*sAMNextNFSetNumberStyle)(id, SEL, NSUInteger) = NULL;
static id (*sAMNextLocaleCurrent)(id, SEL) = NULL;

static void LBAMLogICUCaller(NSString *cls, SEL sel, NSString *extra) {
    if (!atomic_load(&sALInQF) && !atomic_load(&sALPostQF)) return;
    int n = atomic_fetch_add(&sAMICUCallerHit, 1) + 1;
    if (n > 32) return;
    // AN：符号化栈（AM 的 LBAICompactStack 在无 ObjC 帧时只剩 +offset 数字）
    NSString *stack = (n <= 12) ? LBANSymbolStack(12) : @"-";
    LBABSyncProbe([NSString stringWithFormat:
                   @"am_icu_caller cls=%@ sel=%@ main=%d hit=%d inQF=%d postQF=%d%@",
                   cls ?: @"?",
                   NSStringFromSelector(sel) ?: @"?",
                   [NSThread isMainThread] ? 1 : 0,
                   n,
                   atomic_load(&sALInQF),
                   atomic_load(&sALPostQF),
                   extra.length ? [NSString stringWithFormat:@" %@", extra] : @""]);
    if (n <= 12) {
        LBAIWriteLong([NSString stringWithFormat:
                       @"am_icu_caller cls=%@ sel=%@ main=%d hit=%d stack=%@",
                       cls ?: @"?",
                       NSStringFromSelector(sel) ?: @"?",
                       [NSThread isMainThread] ? 1 : 0,
                       n, stack]);
        LBABSyncProbe([NSString stringWithFormat:
                       @"an_icu_stack hit=%d main=%d stack=%@",
                       n, [NSThread isMainThread] ? 1 : 0, stack]);
    }
}

static id LBAM_DFInit(id self, SEL _cmd) {
    LBAMLogICUCaller(@"NSDateFormatter", _cmd, nil);
    return sAMNextDFInit ? sAMNextDFInit(self, _cmd) : nil;
}

static id LBAM_DFStringFromDate(id self, SEL _cmd, id date) {
    LBAMLogICUCaller(@"NSDateFormatter", _cmd, nil);
    return sAMNextDFStringFromDate ? sAMNextDFStringFromDate(self, _cmd, date) : nil;
}

static void LBAM_DFSetDateFormat(id self, SEL _cmd, id fmt) {
    LBAMLogICUCaller(@"NSDateFormatter", _cmd, nil);
    if (sAMNextDFSetDateFormat) sAMNextDFSetDateFormat(self, _cmd, fmt);
}

static id LBAM_NFInit(id self, SEL _cmd) {
    LBAMLogICUCaller(@"NSNumberFormatter", _cmd, nil);
    return sAMNextNFInit ? sAMNextNFInit(self, _cmd) : nil;
}

static id LBAM_NFStringFromNumber(id self, SEL _cmd, id num) {
    LBAMLogICUCaller(@"NSNumberFormatter", _cmd, nil);
    return sAMNextNFStringFromNumber ? sAMNextNFStringFromNumber(self, _cmd, num) : nil;
}

static void LBAM_NFSetNumberStyle(id self, SEL _cmd, NSUInteger style) {
    LBAMLogICUCaller(@"NSNumberFormatter", _cmd,
                     [NSString stringWithFormat:@"style=%lu", (unsigned long)style]);
    if (sAMNextNFSetNumberStyle) sAMNextNFSetNumberStyle(self, _cmd, style);
}

static id LBAM_LocaleCurrent(id self, SEL _cmd) {
    LBAMLogICUCaller(@"NSLocale", _cmd, @"kind=currentLocale");
    return sAMNextLocaleCurrent ? sAMNextLocaleCurrent(self, _cmd) : nil;
}

static void LBAMInstallICUCallerHooks(void) {
    int expected = 0;
    if (!atomic_compare_exchange_strong(&sAMICUHooked, &expected, 1)) return;
    int ok = 0;
    Class df = [NSDateFormatter class];
    if (df) {
        Method m = class_getInstanceMethod(df, @selector(init));
        if (m && !sAMNextDFInit) {
            sAMNextDFInit = (id (*)(id, SEL))method_getImplementation(m);
            method_setImplementation(m, (IMP)LBAM_DFInit);
            ok++;
        }
        m = class_getInstanceMethod(df, @selector(stringFromDate:));
        if (m && !sAMNextDFStringFromDate) {
            sAMNextDFStringFromDate = (id (*)(id, SEL, id))method_getImplementation(m);
            method_setImplementation(m, (IMP)LBAM_DFStringFromDate);
            ok++;
        }
        m = class_getInstanceMethod(df, @selector(setDateFormat:));
        if (m && !sAMNextDFSetDateFormat) {
            sAMNextDFSetDateFormat = (void (*)(id, SEL, id))method_getImplementation(m);
            method_setImplementation(m, (IMP)LBAM_DFSetDateFormat);
            ok++;
        }
    }
    Class nf = [NSNumberFormatter class];
    if (nf) {
        Method m = class_getInstanceMethod(nf, @selector(init));
        if (m && !sAMNextNFInit) {
            sAMNextNFInit = (id (*)(id, SEL))method_getImplementation(m);
            method_setImplementation(m, (IMP)LBAM_NFInit);
            ok++;
        }
        m = class_getInstanceMethod(nf, @selector(stringFromNumber:));
        if (m && !sAMNextNFStringFromNumber) {
            sAMNextNFStringFromNumber = (id (*)(id, SEL, id))method_getImplementation(m);
            method_setImplementation(m, (IMP)LBAM_NFStringFromNumber);
            ok++;
        }
        m = class_getInstanceMethod(nf, @selector(setNumberStyle:));
        if (m && !sAMNextNFSetNumberStyle) {
            sAMNextNFSetNumberStyle = (void (*)(id, SEL, NSUInteger))method_getImplementation(m);
            method_setImplementation(m, (IMP)LBAM_NFSetNumberStyle);
            ok++;
        }
    }
    Class loc = [NSLocale class];
    if (loc) {
        Method m = class_getClassMethod(loc, @selector(currentLocale));
        if (m && !sAMNextLocaleCurrent) {
            sAMNextLocaleCurrent = (id (*)(id, SEL))method_getImplementation(m);
            method_setImplementation(m, (IMP)LBAM_LocaleCurrent);
            ok++;
        }
    }
    LBABSyncProbe([NSString stringWithFormat:@"am_icu_hook_ok n=%d", ok]);
}

/// AI：尽早挂 UIWindowScene.windows，覆盖 invoke 前窗口
__attribute__((constructor))
static void LBAIConstructor(void) {
    // UIKit 类可能尚未就绪；失败时 LBABInstallProbes 会重试
    @autoreleasepool {
        LBAIInstallWindowSceneHook();
    }
}

/// 若当前 IMP 是 forensics observer 桩，剥到其 orig，避免 next=forensics 且 orig=AB 成环
static IMP LBACPeelObserverNext(Class cls, SEL sel, IMP cur) {
    if (!cls || !sel || !cur) return cur;
    static LBACForensicsHookIMPForSelectorNameFn hookForSel = NULL;
    static LBACForensicsResolveObserverOrigIMPFn resolveObs = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        hookForSel = (LBACForensicsHookIMPForSelectorNameFn)dlsym(
            RTLD_DEFAULT, "LBForensicsHookIMPForSelectorName");
        resolveObs = (LBACForensicsResolveObserverOrigIMPFn)dlsym(
            RTLD_DEFAULT, "LBForensicsResolveObserverOrigIMP");
    });
    if (hookForSel) {
        IMP fh = hookForSel(NSStringFromSelector(sel));
        if (fh && cur == fh && resolveObs) {
            IMP peeled = resolveObs(cls, sel);
            if (peeled && peeled != cur && peeled != (IMP)LBAB_CallBackResponse &&
                peeled != (IMP)LBAB_FormatCallBack && peeled != (IMP)LBAB_CheckCallBack &&
                peeled != (IMP)LBAE_QueryFinish) {
                return peeled;
            }
        }
    }
    if (cur == (IMP)LBAB_CallBackResponse || cur == (IMP)LBAB_FormatCallBack ||
        cur == (IMP)LBAB_CheckCallBack || cur == (IMP)LBAE_QueryFinish) {
        return NULL;
    }
    return cur;
}

/// AE：只读标出 format 后 QF 派发门禁（对应 original @0x10008a4cc–0x10008a6ac）
static void LBAEProbeDispatchGates(id response, id config, id userInfo, NSString *phase) {
    id action = ([config isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)config)[@"actionID"] : nil);
    id target = ([userInfo isKindOfClass:[NSDictionary class]]
                 ? ((NSDictionary *)userInfo)[@"callback_target"] : nil);
    id notify = ([userInfo isKindOfClass:[NSDictionary class]]
                 ? ((NSDictionary *)userInfo)[@"callback_notify"] : nil);
    id inThread = ([userInfo isKindOfClass:[NSDictionary class]]
                   ? ((NSDictionary *)userInfo)[@"callback_inThread"] : nil);
    id dont = ([userInfo isKindOfClass:[NSDictionary class]]
               ? ((NSDictionary *)userInfo)[@"callback_dontFormatResponse"] : nil);
    SEL qfSel = NSSelectorFromString(@"lpNetWorkDelegateQueryFinish:config:userInfo:");
    BOOL isCls = target && object_isClass(target);
    BOOL responds = (target && !isCls && qfSel && [target respondsToSelector:qfSel]);
    NSUInteger respLen = 0;
    if ([response isKindOfClass:[NSString class]]) {
        respLen = [(NSString *)response length];
    } else if ([response isKindOfClass:[NSDictionary class]]) {
        id c = ((NSDictionary *)response)[@"content"] ?: ((NSDictionary *)response)[@"chapterContent"];
        if ([c isKindOfClass:[NSString class]]) respLen = [(NSString *)c length];
    }
    // path 估算：responds → (inThread? sync : async main)；!responds && !notify → skip
    const char *path = "skip_no_target_or_notify";
    if (responds) {
        path = inThread ? "sync_inThread" : "async_main";
    } else if (notify) {
        path = "notify_only_no_qf";
    }
    LBABSyncProbe([NSString stringWithFormat:
                   @"qf_dispatch_gates phase=%@ action=%@ target=%@ isClass=%d responds=%d notify=%d inThread=%d dont=%d respNil=%d respLen=%lu path=%s",
                   phase ?: @"-",
                   [action isKindOfClass:[NSString class]] ? action : @"-",
                   target ? NSStringFromClass(object_getClass(target)) : @"nil",
                   isCls ? 1 : 0,
                   responds ? 1 : 0,
                   notify ? 1 : 0,
                   inThread ? 1 : 0,
                   dont ? 1 : 0,
                   response ? 0 : 1,
                   (unsigned long)respLen,
                   path]);
}

static void LBAE_QueryFinish(id self, SEL _cmd, id response, id config, id userInfo) {
    NSUInteger respLen = [response isKindOfClass:[NSString class]] ? [(NSString *)response length] : 0;
    if (respLen == 0 && [response isKindOfClass:[NSDictionary class]]) {
        id c = ((NSDictionary *)response)[@"content"] ?: ((NSDictionary *)response)[@"chapterContent"];
        if ([c isKindOfClass:[NSString class]]) respLen = [(NSString *)c length];
    }
    id action = ([config isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)config)[@"actionID"] : nil);
    atomic_store(&sALInQF, 1);
    LBAONotifyForensicsWindow(1, 0);
    // AO：QF 入口先夺 handler（open 路径可能已用 signal() 盖掉）
    LBANClaimFaultHandlers("qf_enter");
    LBAOProbeFaultHandler("qf_enter");
    LBABSyncProbe([NSString stringWithFormat:
                   @"qf_enter self=%@ respLen=%lu action=%@ respCls=%@",
                   self ? NSStringFromClass(object_getClass(self)) : @"nil",
                   (unsigned long)respLen,
                   [action isKindOfClass:[NSString class]] ? action : @"-",
                   response ? NSStringFromClass(object_getClass(response)) : @"nil"]);
    {
        NSString *qfStack = LBANSymbolStack(14);
        LBAIWriteLong([NSString stringWithFormat:
                       @"al_qf_enter_stack main=%d stack=%@",
                       [NSThread isMainThread] ? 1 : 0, qfStack]);
        LBABSyncProbe([NSString stringWithFormat:
                       @"an_qf_enter_stack main=%d stack=%@",
                       [NSThread isMainThread] ? 1 : 0, qfStack]);
    }
    @try {
        if (sAENextQueryFinish) {
            sAENextQueryFinish(self, _cmd, response, config, userInfo);
        } else {
            LBABSyncProbe(@"qf_early_return reason=null_next");
        }
    } @catch (NSException *ex) {
        LBABSyncProbe([NSString stringWithFormat:
                       @"al_qf_exception name=%@ reason=%@",
                       ex.name ?: @"?", ex.reason ?: @"?"]);
        @throw;
    } @finally {
        atomic_store(&sALInQF, 0);
        atomic_store(&sALPostQF, 1);
        LBAONotifyForensicsWindow(0, 1);
        LBAOEmitLBFStats("qf_exit");
        LBAOProbeFaultHandler("qf_exit");
    }
    LBABSyncProbe(@"ag_post_qf");
    LBABSyncProbe([NSString stringWithFormat:
                   @"al_qf_uikit_summary hit=%d",
                   atomic_load(&sALQFUIKitHit)]);
    LBABSyncProbe(@"qf_exit");
}

static void LBAB_CallBackResponse(id self, SEL _cmd, id response, id config, id userInfo) {
    // 防 AB↔forensics 互套：重入只放行 next，禁改 userInfo / 禁 dontFormat
    if (sABInCallBack > 0) {
        if (sABInCallBack >= 3) {
            LBABSyncProbe(@"cb_reentry_depth_abort");
            return;
        }
        sABInCallBack++;
        if (sABNextCallBackResponse) {
            sABNextCallBackResponse(self, _cmd, response, config, userInfo);
        }
        sABInCallBack--;
        return;
    }

    NSUInteger respLen = [response isKindOfClass:[NSString class]] ? [(NSString *)response length] : 0;
    id action = ([config isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)config)[@"actionID"] : nil);
    id target = ([userInfo isKindOfClass:[NSDictionary class]]
                 ? ((NSDictionary *)userInfo)[@"callback_target"] : nil);
    id dont = ([userInfo isKindOfClass:[NSDictionary class]]
               ? ((NSDictionary *)userInfo)[@"callback_dontFormatResponse"] : nil);
    NSString *selfCls = self ? NSStringFromClass(object_getClass(self)) : @"nil";
    BOOL respNil = (response == nil);
    BOOL main = [NSThread isMainThread];
    // BB：cb 线程栈低水位保护。
    // BA 真机证据：cb_exit 时栈仅剩 596 字节（used=523KB/524KB），栈溢出确认。
    // BB：cb_enter 时检查栈剩余空间，若低于 8KB 则跳过所有 LBABSyncProbe 探针（减少 ObjC
    // stringWithFormat 栈帧），只保留 orig 调用 + 最小纯 C 标记。
    pthread_t _bbT = pthread_self();
    void *_bbBase = pthread_get_stackaddr_np(_bbT);
    size_t _bbSize = pthread_get_stacksize_np(_bbT);
    int _bbVar = 0;
    long _bbRemaining = (long)((char *)_bbBase - (char *)&_bbVar);
    BOOL _bbLowStack = (_bbRemaining < 8192);
    if (_bbLowStack) {
        // 低栈：只调 orig，跳过所有探针
        sADCheckEntered = 0;
        sABInCallBack = 1;
        @try {
            sABNextCallBackResponse(self, _cmd, response, config, userInfo);
        } @finally {
            sABInCallBack = 0;
        }
        return;
    }
    LBABSyncProbe([NSString stringWithFormat:
                   @"cb_enter respLen=%lu action=%@ target=%@ dontFormat=%d self=%@ stackRem=%ld",
                   (unsigned long)respLen,
                   [action isKindOfClass:[NSString class]] ? action : @"-",
                   target ? NSStringFromClass(object_getClass(target)) : @"nil",
                   dont ? 1 : 0,
                   selfCls,
                   _bbRemaining]);
    // AD：original @0x10008a234 仅 cbz response→跳过 check；无 config/action/dontFormat/主线程门禁
    LBABSyncProbe([NSString stringWithFormat:
                   @"cb_precheck_gate_resp nil=%d len=%lu self=%@ main=%d next=%p",
                   respNil ? 1 : 0,
                   (unsigned long)respLen,
                   selfCls,
                   main ? 1 : 0,
                   sABNextCallBackResponse]);
    if (!sABNextCallBackResponse) {
        LBABSyncProbe(@"cb_early_return reason=null_next");
        return;
    }
    // AS：撤 AE inThread 注入，回原版 dispatch_async(main) QF 路径。
    // AQ 真机证据：撤 inThread 后 postQF LBFHook 风暴 depth=4864 SIGSEGV@CFRetain。
    // AR 真机证据：depth 守卫(maxDepth>8 short-circuit)成功消除风暴。
    // AR 验收：inThread=YES 保留时，QF 在 bg 线程跑，原生 callBackResponse/format/division 链
    //   跨线程操作 mutable CFString(__NSCFString)，__CFStringAppendBytes 子函数
    //   pc=0x86fdc SEGV_ACCERR@栈附近(fault=16f3b3ff8)。根因=inThread 让 QF 跨线程访问 CFString。
    // AS：撤 inThread + 保留 AR 守卫 + 保留 AQ 探针，QF 回 main 线程，CFString 天然线程安全。
    id userInfoForOrig = userInfo;
    LBABSyncProbe([NSString stringWithFormat:
                   @"as_qf_path_no_inject action=%@ inThread=%@ dontFormat=%@",
                   [action isKindOfClass:[NSString class]] ? action : @"-",
                   ([userInfo isKindOfClass:[NSDictionary class]]
                    && ((NSDictionary *)userInfo)[@"callback_inThread"]) ? @"1" : @"0",
                   (dont ? @"1" : @"0")]);
    sADCheckEntered = 0;
    sABInCallBack = 1;
    @try {
        sABNextCallBackResponse(self, _cmd, response, config, userInfoForOrig);
    } @finally {
        sABInCallBack = 0;
    }
    // AE：original 在 format 后可能 dispatch_async(main) 派 QF；CB 返回后主队列脉冲确认可排空
    LBAEProbeDispatchGates(response, config, userInfoForOrig, @"after_cb");
    dispatch_async(dispatch_get_main_queue(), ^{
        LBABSyncProbe(@"qf_dispatch_main_pulse");
    });
    if (sADCheckEntered == 0) {
        if (respNil) {
            LBABSyncProbe(@"cb_precheck_gate_skip_check reason=resp_nil");
        } else {
            // 非 nil 却未见 check_enter：多半钩在 LPNetWork2 而 runtime 走 BQM 覆盖
            LBABSyncProbe([NSString stringWithFormat:
                           @"cb_precheck_gate_skip_check reason=no_check_enter self=%@",
                           selfCls]);
        }
    } else {
        LBABSyncProbe(@"cb_precheck_gate_check_seen");
    }
    LBABSyncProbe(@"cb_exit");
    // BA：cb 线程栈深度探针。
    // AZ 真机证据（决定性）：postQF 逻辑整体 dispatch_async 到 utility 队列（cb 线程零开销返回）后，
    // 仍崩在 cb 线程（tid=259）返回 BookQueryManager 时。崩溃源在原生 callback 链后续处理。
    // BA：记录 cb 线程栈剩余空间，验证是否栈溢出（fault=fp-0x178 恒定=栈 guard page 写穿）。
    {
        pthread_t t = pthread_self();
        void *stackBase = pthread_get_stackaddr_np(t);
        size_t stackSize = pthread_get_stacksize_np(t);
        int stackVar = 0;
        void *curSP = (void *)&stackVar;
        long remaining = (long)((char *)stackBase - (char *)curSP);
        long used = (long)stackSize - remaining;
        LBABSyncProbe([NSString stringWithFormat:
                       @"ba_cb_stack thread=%p base=%p size=%zu cur=%p used=%ld remaining=%ld main=%d",
                       (void *)t, stackBase, stackSize, curSP, used, remaining,
                       [NSThread isMainThread] ? 1 : 0]);
    }
    // AM：轻量心跳钉 0–200ms 死窗（禁全线程 suspend）；AL 全线程采样副作用大，本刀不叠
    LBAMStartPostCbHeartbeat();
}

static id LBAB_FormatCallBack(id self, SEL _cmd, id response, id config, id userInfo) {
    NSUInteger respLen = [response isKindOfClass:[NSString class]] ? [(NSString *)response length] : 0;
    id action = ([config isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)config)[@"actionID"] : nil);
    id dont = ([userInfo isKindOfClass:[NSDictionary class]]
               ? ((NSDictionary *)userInfo)[@"callback_dontFormatResponse"] : nil);
    LBABSyncProbe([NSString stringWithFormat:
                   @"format_enter respLen=%lu action=%@ dontFormat=%d",
                   (unsigned long)respLen,
                   [action isKindOfClass:[NSString class]] ? action : @"-",
                   dont ? 1 : 0]);
    /// BC6：采 format 调用栈，定位谁绕过 CB 直接调 format。
    /// BC5 证实 inv=1 周期 CB 未被调用，但 format 被直接调用。
    /// 本探针采前 12 帧符号，确认 format 的调用者。
    NSString *bc6Stack = LBANSymbolStack(12);
    LBABSyncProbe([NSString stringWithFormat:@"bc6_format_caller stack=%@", bc6Stack]);
    // AE：必须透传 id 返回值；void 钩会使 caller retain 到垃圾/nil，后续 QF 参数损坏
    id formatted = nil;
    if (sABNextFormatCallBack) {
        formatted = sABNextFormatCallBack(self, _cmd, response, config, userInfo);
    } else {
        LBABSyncProbe(@"format_early_return reason=null_next");
        formatted = response;
    }
    NSUInteger outLen = [formatted isKindOfClass:[NSString class]] ? [(NSString *)formatted length] : 0;
    if (outLen == 0 && [formatted isKindOfClass:[NSDictionary class]]) {
        id c = ((NSDictionary *)formatted)[@"content"] ?: ((NSDictionary *)formatted)[@"chapterContent"];
        if ([c isKindOfClass:[NSString class]]) outLen = [(NSString *)c length];
    }
    LBAEProbeDispatchGates(formatted, config, userInfo, @"post_format");
    LBABSyncProbe([NSString stringWithFormat:
                   @"format_exit outNil=%d outLen=%lu outCls=%@",
                   formatted ? 0 : 1,
                   (unsigned long)outLen,
                   formatted ? NSStringFromClass(object_getClass(formatted)) : @"nil"]);
    return formatted;
}

static BOOL LBAB_CheckCallBack(id self, SEL _cmd, id response, id config, id userInfo) {
    sADCheckEntered = 1;
    NSUInteger respLen = [response isKindOfClass:[NSString class]] ? [(NSString *)response length] : 0;
    if (respLen == 0 && [response isKindOfClass:[NSDictionary class]]) {
        id c = ((NSDictionary *)response)[@"content"] ?: ((NSDictionary *)response)[@"chapterContent"];
        if ([c isKindOfClass:[NSString class]]) respLen = [(NSString *)c length];
    }
    id action = ([config isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)config)[@"actionID"] : nil);
    id target = ([userInfo isKindOfClass:[NSDictionary class]]
                 ? ((NSDictionary *)userInfo)[@"callback_target"] : nil);
    id dont = ([userInfo isKindOfClass:[NSDictionary class]]
               ? ((NSDictionary *)userInfo)[@"callback_dontFormatResponse"] : nil);
    id qsrc = ([userInfo isKindOfClass:[NSDictionary class]]
               ? ((NSDictionary *)userInfo)[@"querySourceName"] : nil);
    BOOL hasCfg = [config isKindOfClass:[NSDictionary class]];
    BOOL hasUI = [userInfo isKindOfClass:[NSDictionary class]];
    NSString *selfCls = self ? NSStringFromClass(object_getClass(self)) : @"nil";
    LBABSyncProbe([NSString stringWithFormat:
                   @"check_enter respLen=%lu action=%@ target=%@ dontFormat=%d cfg=%d ui=%d self=%@ qsrc=%@ respCls=%@",
                   (unsigned long)respLen,
                   [action isKindOfClass:[NSString class]] ? action : @"-",
                   target ? NSStringFromClass(object_getClass(target)) : @"nil",
                   dont ? 1 : 0, hasCfg ? 1 : 0, hasUI ? 1 : 0,
                   selfCls,
                   [qsrc isKindOfClass:[NSString class]] ? qsrc : @"-",
                   response ? NSStringFromClass(object_getClass(response)) : @"nil"]);
    /// BC6：采 check 调用栈，定位谁绕过 CB 直接调 check。
    NSString *bc6CheckStack = LBANSymbolStack(12);
    LBABSyncProbe([NSString stringWithFormat:@"bc6_check_caller stack=%@", bc6CheckStack]);
    if (!sABNextCheckCallBack) {
        LBABSyncProbe(@"check_early_return reason=null_next ok=1");
        return YES;
    }
    BOOL ok = sABNextCheckCallBack(self, _cmd, response, config, userInfo);
    if (ok) {
        LBABSyncProbe(@"check_exit ok=1");
    } else {
        // original CB 在 check 失败时会早退、不进 format
        LBABSyncProbe([NSString stringWithFormat:
                       @"check_early_return reason=check_failed ok=0 respLen=%lu action=%@ target=%@ self=%@ qsrc=%@",
                       (unsigned long)respLen,
                       [action isKindOfClass:[NSString class]] ? action : @"-",
                       target ? NSStringFromClass(object_getClass(target)) : @"nil",
                       selfCls,
                       [qsrc isKindOfClass:[NSString class]] ? qsrc : @"-"]);
        LBABSyncProbe(@"check_exit ok=0");
    }
    return ok;
}

static id LBAB_StringWithContents(id self, SEL _cmd, id path, NSUInteger enc, NSError **err) {
    NSString *p = [path isKindOfClass:[NSString class]] ? (NSString *)path : nil;
    BOOL interesting = p.length > 0 &&
                       ([p containsString:@"xsfolder"] || [p containsString:@"/book/"]);
    if (interesting) {
        LBABSyncProbe([NSString stringWithFormat:@"swcf_enter leaf=%@", p.lastPathComponent ?: @"-"]);
    }
    id ret = sABNextStringWithContents
                 ? sABNextStringWithContents(self, _cmd, path, enc, err)
                 : nil;
    if (interesting) {
        NSUInteger len = [ret isKindOfClass:[NSString class]] ? [(NSString *)ret length] : 0;
        LBABSyncProbe([NSString stringWithFormat:
                       @"swcf_exit leaf=%@ len=%lu nil=%d",
                       p.lastPathComponent ?: @"-",
                       (unsigned long)len,
                       ret ? 0 : 1]);
    }
    return ret;
}

static void LBABInstallProbes(void) {
    LBABInstallSignalProbes();
    LBAGInstallAtExit();
    LBAIInstallWindowSceneHook();
    LBALInstallQFUIKitHooks();
    LBAMInstallICUCallerHooks();
    // 只装一次：invoke 前反复 setImplementation 会把 next 指到 forensics 桩并成环
    if (sABHooksInstalled) return;

    Class net = NSClassFromString(@"LPNetWork2");
    if (net) {
        SEL cbSel = NSSelectorFromString(@"callBackResponse:config:userInfo:");
        // BC5：BQM 覆盖 check/format（见 1831 注释），可能也覆盖 callBackResponse。
        // 原 install_cb 只装 LPNetWork2，若 BQM 覆盖 CB 则 hook 拦不到。
        // 优先装 BQM，fallback LPNetWork2（与 format/check 一致）。
        Class cbOwner = NSClassFromString(@"BookQueryManager") ?: net;
        Method cbmOnBqm = class_getInstanceMethod(cbOwner, cbSel);
        Method cbmOnNet = class_getInstanceMethod(net, cbSel);
        // 查 BQM 是否有自己的 CB 实现（IMP 不同于 LPNetWork2）
        IMP bqmCbImp = cbmOnBqm ? method_getImplementation(cbmOnBqm) : NULL;
        IMP netCbImp = cbmOnNet ? method_getImplementation(cbmOnNet) : NULL;
        LBABSyncProbe([NSString stringWithFormat:
                       @"bc5_cb_owner_probe bqm=%@ bqmImp=%p netImp=%p same=%d bqmOverrides=%d",
                       cbOwner ? NSStringFromClass(cbOwner) : @"nil",
                       bqmCbImp, netCbImp,
                       (bqmCbImp == netCbImp) ? 1 : 0,
                       (bqmCbImp && netCbImp && bqmCbImp != netCbImp) ? 1 : 0]);
        Method cbm = cbmOnBqm ?: cbmOnNet;
        Class cbInstallOwner = cbmOnBqm ? cbOwner : net;
        if (cbm) {
            IMP cur = method_getImplementation(cbm);
            if (cur == (IMP)LBAB_CallBackResponse) {
                LBABSyncProbe(@"install_cb_skip already_self");
            } else if (!sABNextCallBackResponse) {
                IMP next = LBACPeelObserverNext(cbInstallOwner, cbSel, cur);
                if (!next) {
                    LBABSyncProbe([NSString stringWithFormat:
                                   @"install_cb_pollute_blocked cur=%p owner=%@", cur, NSStringFromClass(cbInstallOwner)]);
                } else {
                    if (next != cur) {
                        LBABSyncProbe([NSString stringWithFormat:
                                       @"install_cb_peeled cur=%p next=%p owner=%@", cur, next, NSStringFromClass(cbInstallOwner)]);
                    }
                    sABNextCallBackResponse = (void (*)(id, SEL, id, id, id))next;
                    method_setImplementation(cbm, (IMP)LBAB_CallBackResponse);
                    LBABSyncProbe([NSString stringWithFormat:
                                   @"install_cb next=%p owner=%@", sABNextCallBackResponse, NSStringFromClass(cbInstallOwner)]);
                }
            } else {
                LBABSyncProbe([NSString stringWithFormat:
                               @"install_cb_skip next_frozen cur=%p owner=%@", cur, NSStringFromClass(cbInstallOwner)]);
            }
        }
        // AD：chapterContent 路径 self=BookQueryManager，其覆盖 check/format；
        // 只钩 LPNetWork2 会装到「response!=nil」短实现，runtime 永远看不到 check_enter。
        Class chkOwner = NSClassFromString(@"BookQueryManager") ?: net;
        SEL fmtSel = NSSelectorFromString(@"formatCallBackResponse:config:userInfo:");
        Method fmtm = class_getInstanceMethod(chkOwner, fmtSel);
        if (fmtm) {
            IMP cur = method_getImplementation(fmtm);
            if (cur != (IMP)LBAB_FormatCallBack && !sABNextFormatCallBack) {
                IMP next = LBACPeelObserverNext(chkOwner, fmtSel, cur);
                if (next) {
                    sABNextFormatCallBack = (id (*)(id, SEL, id, id, id))next;
                    method_setImplementation(fmtm, (IMP)LBAB_FormatCallBack);
                    LBABSyncProbe([NSString stringWithFormat:
                                   @"install_format owner=%@",
                                   NSStringFromClass(chkOwner)]);
                } else {
                    LBABSyncProbe(@"install_format_pollute_blocked");
                }
            }
        } else {
            LBABSyncProbe(@"install_format_missing");
        }
        SEL chkSel = NSSelectorFromString(@"checkCallBackResponse:config:userInfo:");
        Method chkm = class_getInstanceMethod(chkOwner, chkSel);
        if (chkm) {
            IMP cur = method_getImplementation(chkm);
            if (cur != (IMP)LBAB_CheckCallBack && !sABNextCheckCallBack) {
                IMP next = LBACPeelObserverNext(chkOwner, chkSel, cur);
                if (next) {
                    sABNextCheckCallBack = (BOOL (*)(id, SEL, id, id, id))next;
                    method_setImplementation(chkm, (IMP)LBAB_CheckCallBack);
                    LBABSyncProbe([NSString stringWithFormat:
                                   @"install_check owner=%@",
                                   NSStringFromClass(chkOwner)]);
                } else {
                    LBABSyncProbe(@"install_check_pollute_blocked");
                }
            }
        } else {
            LBABSyncProbe(@"install_check_missing");
        }
        // AE：QF 实现在 ReadPageContainer（TextRPageContainer 继承）
        Class qfOwner = NSClassFromString(@"ReadPageContainer");
        SEL qfSel = NSSelectorFromString(@"lpNetWorkDelegateQueryFinish:config:userInfo:");
        Method qfm = qfOwner ? class_getInstanceMethod(qfOwner, qfSel) : NULL;
        if (qfm) {
            IMP cur = method_getImplementation(qfm);
            if (cur != (IMP)LBAE_QueryFinish && !sAENextQueryFinish) {
                IMP next = LBACPeelObserverNext(qfOwner, qfSel, cur);
                if (next) {
                    sAENextQueryFinish = (void (*)(id, SEL, id, id, id))next;
                    method_setImplementation(qfm, (IMP)LBAE_QueryFinish);
                    LBABSyncProbe(@"install_qf owner=ReadPageContainer");
                } else {
                    LBABSyncProbe(@"install_qf_pollute_blocked");
                }
            }
        } else {
            LBABSyncProbe(@"install_qf_missing");
        }
    } else {
        LBABSyncProbe(@"install_skip no_LPNetWork2");
    }

    // 恢复 swcf：6b5ef8e 以「无 invoke」为由撤钩，但 903846e 验收已有 cb_enter，证据不完整
    Method sw = class_getClassMethod([NSString class],
                                     @selector(stringWithContentsOfFile:encoding:error:));
    if (sw) {
        IMP cur = method_getImplementation(sw);
        if (cur != (IMP)LBAB_StringWithContents && !sABNextStringWithContents) {
            sABNextStringWithContents = (id (*)(id, SEL, id, NSUInteger, NSError **))cur;
            method_setImplementation(sw, (IMP)LBAB_StringWithContents);
            LBABSyncProbe(@"install_swcf");
        }
    }

    sABHooksInstalled = YES;
    LBABSyncProbe(@"install_done");
    LBAPLogCFAnchor();
    LBABSyncProbe(@"as_inThread_removed=1");
    LBABSyncProbe(@"ag_keep_inThread=0_as_removed");
    LBABSyncProbe(@"ai_keep_inThread=0_as_removed");
    LBABSyncProbe(@"ak_keep_inThread=0_as_removed");
    LBABSyncProbe(@"al_keep_inThread=0_as_removed");
    LBABSyncProbe(@"am_keep_inThread=0_as_removed");
}

static void LBSetState(LBLoadCurCpState next, NSString *why) {
    sState = next;
    LBStateLog(why ?: @"transition");
}

NSString *LBLoadCurCpBridgeStateName(void) {
    switch (sState) {
        case LBLoadCurCpStateIdle: return @"idle";
        case LBLoadCurCpStateFetching: return @"fetching";
        case LBLoadCurCpStateContentReady: return @"contentReady";
        case LBLoadCurCpStateInvokingOriginal: return @"invokingOriginal";
        case LBLoadCurCpStateRendered: return @"rendered";
        case LBLoadCurCpStateFailed: return @"failed";
    }
    return @"?";
}

void LBLoadCurCpBridgeRegisterOrig(void (*orig)(id, SEL)) {
    if (!orig) return;
    sOrigLoadCurCp = orig;
    LBStateLog([NSString stringWithFormat:@"register_orig imp=%p", orig]);
    LBABInstallProbes();
}

static NSString *LBBodyFromPayload(NSDictionary *payload);
static void LBTryContentReadyAndInvoke(id reader, NSDictionary *payload);
static void LBScheduleContentReadyWhenReaderReady(NSInteger attempt);

void LBLoadCurCpBridgeCacheContainer(id readerVC, id container) {
    if (!readerVC || !container) return;
    objc_setAssociatedObject(readerVC, kLBAssocFoundContainerKey, container,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    LBStateLog([NSString stringWithFormat:@"hypothesis_F cache_container %@",
                NSStringFromClass(object_getClass(container))]);
    // 路 B：正文常先于 reader 可见到达（contentReady_no_reader_yet）。
    // F 探针在 onReset 后写入 pageContainerA 时立刻重试 invoke，不依赖 CExports 1s delayed_postCurCp。
    if (sPendingPayload && LBBodyFromPayload(sPendingPayload).length > 0 &&
        (sState == LBLoadCurCpStateContentReady || sState == LBLoadCurCpStateFetching)) {
        LBStateLog(@"routeB retry_on_cache_container");
        sWeakReader = readerVC;
        LBTryContentReadyAndInvoke(readerVC, sPendingPayload);
    }
}

BOOL LBLoadCurCpBridgePassThroughToNative(void) {
    return sReentryGuard || sState == LBLoadCurCpStateInvokingOriginal;
}

void LBLoadCurCpBridgeReset(NSString *reason) {
    sToken = nil;
    sChapterUrl = nil;
    sBookUrl = nil;
    sCpIndex = 0;
    sInvokeCount = 0;
    sPendingPayload = nil;
    sWeakReader = nil;
    sReentryGuard = NO;
    LBSetState(LBLoadCurCpStateIdle, reason ?: @"reset");
}

void LBLoadCurCpBridgeMarkRendered(void) {
    if (sState == LBLoadCurCpStateInvokingOriginal || sState == LBLoadCurCpStateContentReady) {
        LBSetState(LBLoadCurCpStateRendered, @"native_render_evidence");
    }
}

static NSString *LBBodyFromPayload(NSDictionary *payload) {
    id c = payload[@"chapterContent"] ?: payload[@"content"];
    return [c isKindOfClass:[NSString class]] ? (NSString *)c : nil;
}

static BOOL LBPayloadHasRealError(NSDictionary *payload) {
    id err = payload[@"error"];
    if (!err || err == [NSNull null]) return NO;
    if ([err isKindOfClass:[NSString class]]) return [(NSString *)err length] > 0;
    return YES;
}

static NSInteger LBCpIndexFromPayload(NSDictionary *payload, id reader) {
    id cpi = payload[@"cpIndex"] ?: payload[@"index"];
    if ([cpi respondsToSelector:@selector(integerValue)]) return [cpi integerValue];
    @try {
        id cur = [reader valueForKey:@"curCpIndex"];
        if ([cur respondsToSelector:@selector(integerValue)]) return [cur integerValue];
    } @catch (__unused NSException *e) {}
    return 0;
}

static BOOL LBObjectIsReadPageContainerLike(id obj) {
    if (!obj) return NO;
    NSString *n = NSStringFromClass(object_getClass(obj));
    if ([n containsString:@"ScrollContainer"]) return NO;
    if ([n isEqualToString:@"ReadPageContainer"] ||
        [n isEqualToString:@"TextRPageContainer"] ||
        [n containsString:@"ReadPageContainer"] ||
        [n containsString:@"TextRPageContainer"]) {
        return YES;
    }
    return [obj respondsToSelector:NSSelectorFromString(@"curPageVC")];
}

/// 假设 F：含 TextRScrollContainer（loadCurCp/division 可能挂在此类）
static BOOL LBObjectIsHypothesisFContainerLike(id obj) {
    if (!obj) return NO;
    NSString *n = NSStringFromClass(object_getClass(obj));
    if ([n isEqualToString:@"TextRScrollContainer"]) return YES;
    return LBObjectIsReadPageContainerLike(obj);
}

static NSInteger LBReadPageContainerPriority(id obj) {
    NSString *n = NSStringFromClass(object_getClass(obj));
    if ([n isEqualToString:@"TextRPageContainer"]) return 0;
    if ([n isEqualToString:@"ReadPageContainer"]) return 1;
    if ([n containsString:@"TextRPageContainer"]) return 2;
    if ([n containsString:@"ReadPageContainer"]) return 3;
    if ([n isEqualToString:@"TextRScrollContainer"]) return 4;
    if ([obj respondsToSelector:NSSelectorFromString(@"curPageVC")]) return 5;
    return 99;
}

/// 从 TextReadVC3 解析 loadCurCp IMP owner（ReadPageContainer，非 VC3 自身）
static id LBReadIvarObject(id obj, const char *name) {
    if (!obj || !name) return nil;
    Class cls = object_getClass(obj);
    while (cls && cls != [NSObject class]) {
        Ivar iv = class_getInstanceVariable(cls, name);
        if (iv) {
            const char *enc = ivar_getTypeEncoding(iv);
            if (enc && enc[0] == '@') {
                return object_getIvar(obj, iv);
            }
            return nil;
        }
        cls = class_getSuperclass(cls);
    }
    return nil;
}

static id LBFindReadPageContainerForReader(id readerVC) {
    if (!readerVC) return nil;
    id cached = objc_getAssociatedObject(readerVC, kLBAssocFoundContainerKey);
    if (cached && LBObjectIsHypothesisFContainerLike(cached)) {
        LBStateLog([NSString stringWithFormat:
                    @"hypothesis_F findContainer hit %@ via=assoc",
                    NSStringFromClass(object_getClass(cached))]);
        return cached;
    }
    // 假设 R2：禁止 valueForKey(@"container"…)（getter 杀进程）；
    // childVC 常为 0；改用 object_getIvar 直读 + 全量 ivar 扫描。
    NSMutableArray *raw = [NSMutableArray array];
    void (^add)(id) = ^(id v) {
        if (v && ![raw containsObject:v]) [raw addObject:v];
    };
    static const char *kNames[] = {
        "_container", "_pageContainer", "_pageContainerA", "_pageContainerB",
        "_rPageContainer", "_readPageContainer", "_curPageContainer",
        "container", "pageContainer", "pageContainerA", "pageContainerB",
        "rPageContainer", "readPageContainer", "curPageContainer",
    };
    for (size_t i = 0; i < sizeof(kNames) / sizeof(kNames[0]); i++) {
        add(LBReadIvarObject(readerVC, kNames[i]));
    }
    id dpv = LBReadIvarObject(readerVC, "_dicPageVC");
    if (!dpv) dpv = LBReadIvarObject(readerVC, "dicPageVC");
    if ([dpv isKindOfClass:[NSDictionary class]]) {
        for (id v in [(NSDictionary *)dpv allValues]) add(v);
    }
    // 扫描 VC 继承链全部对象 ivar，捕获未知命名的 container
    static BOOL sDumped = NO;
    Class cls = object_getClass(readerVC);
    while (cls && cls != [NSObject class]) {
        unsigned int n = 0;
        Ivar *ivs = class_copyIvarList(cls, &n);
        for (unsigned int i = 0; i < n; i++) {
            const char *enc = ivar_getTypeEncoding(ivs[i]);
            const char *nm = ivar_getName(ivs[i]);
            if (!enc || enc[0] != '@') continue;
            id val = object_getIvar(readerVC, ivs[i]);
            if (!sDumped) {
                LBStateLog([NSString stringWithFormat:
                            @"hypothesis_R2 ivar_dump %@::%s -> %@",
                            NSStringFromClass(cls), nm ?: "?",
                            val ? NSStringFromClass(object_getClass(val)) : @"nil"]);
            }
            if (val) add(val);
        }
        if (ivs) free(ivs);
        cls = class_getSuperclass(cls);
    }
    sDumped = YES;
    if ([readerVC isKindOfClass:[UIViewController class]]) {
        for (UIViewController *ch in ((UIViewController *)readerVC).childViewControllers) {
            add(ch);
        }
    }
    id best = nil;
    NSInteger bestPrio = 99;
    for (id c in raw) {
        if (!LBObjectIsHypothesisFContainerLike(c)) continue;
        NSInteger p = LBReadPageContainerPriority(c);
        if (p < bestPrio) {
            bestPrio = p;
            best = c;
        }
    }
    if (!best) {
        LBStateLog([NSString stringWithFormat:
                    @"hypothesis_R2 findContainer miss raw=%lu children=%lu",
                    (unsigned long)raw.count,
                    (unsigned long)([readerVC isKindOfClass:[UIViewController class]]
                        ? ((UIViewController *)readerVC).childViewControllers.count : 0)]);
    } else {
        LBStateLog([NSString stringWithFormat:
                    @"hypothesis_R2 findContainer hit %@ via=ivar",
                    NSStringFromClass(object_getClass(best))]);
    }
    return best;
}

/// 6A 门禁：按原版 loadCurCp 路径取值（container-attach §1.2 confirmed 指令序列：
/// curPageVC -> pageModel -> pageStatus；diff §8.3 禁以 container KVC 捷径替代）。只读，不 swizzle。
static id LBOrigPathMsgSendId(id obj, NSString *selName) {
    if (!obj || !selName) return nil;
    SEL sel = NSSelectorFromString(selName);
    if (!sel || ![obj respondsToSelector:sel]) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(obj, sel); }
    @catch (__unused NSException *e) { return nil; }
}

static NSNumber *LBOrigPathPageStatus(id container) {
    id curPageVC = LBOrigPathMsgSendId(container, @"curPageVC");
    id pageModel = LBOrigPathMsgSendId(curPageVC, @"pageModel");
    if (!pageModel) return nil;
    SEL sel = NSSelectorFromString(@"pageStatus");
    if (![pageModel respondsToSelector:sel]) return nil;
    @try { return @(((long (*)(id, SEL))objc_msgSend)(pageModel, sel)); }
    @catch (__unused NSException *e) { return nil; }
}

/// 路 B：解析 loadCurCp 的 receiver（优先 hook 捕获的 container，再 ivar pageContainerA）
static id LBRouteBResolveContainer(id reader) {
    id container = nil;
    if (sWeakHookReceiver && LBObjectIsHypothesisFContainerLike(sWeakHookReceiver)) {
        container = sWeakHookReceiver;
        LBStateLog([NSString stringWithFormat:@"routeB_resolve hit hookReceiver %@",
                    NSStringFromClass(object_getClass(container))]);
        return container;
    }
    container = LBFindReadPageContainerForReader(reader);
    if (container) {
        LBStateLog([NSString stringWithFormat:@"routeB_resolve hit find %@",
                    NSStringFromClass(object_getClass(container))]);
        return container;
    }
    if (reader) {
        static const char *kPageContainerIvars[] = {
            "_pageContainerA", "pageContainerA", "_pageContainer", "pageContainer",
            "_pageContainerB", "pageContainerB",
        };
        for (size_t i = 0; i < sizeof(kPageContainerIvars) / sizeof(kPageContainerIvars[0]); i++) {
            id v = LBReadIvarObject(reader, kPageContainerIvars[i]);
            if (v && LBObjectIsHypothesisFContainerLike(v)) {
                LBStateLog([NSString stringWithFormat:
                            @"routeB_resolve hit ivar %s -> %@",
                            kPageContainerIvars[i],
                            NSStringFromClass(object_getClass(v))]);
                return v;
            }
        }
    }
    LBStateLog(@"routeB_resolve miss");
    return nil;
}

static id LBReaderVCFromContext(id obj) {
    if (!obj) return nil;
    if ([obj isKindOfClass:[UIViewController class]]) return obj;
    if (LBObjectIsReadPageContainerLike(obj)) {
        @try {
            id r = [obj valueForKey:@"reader"];
            if ([r isKindOfClass:[UIViewController class]]) return r;
        } @catch (__unused NSException *e) {}
    }
    return obj;
}

static void LBApplyDicContents(id target, NSMutableDictionary *dc, NSMutableArray *paths, NSString *tag) {
    if (!target || !dc || dc.count == 0) return;
    @try {
        if ([target respondsToSelector:@selector(setDicContents:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(target, @selector(setDicContents:), dc);
        } else {
            @try { [target setValue:dc forKey:@"dicContents"]; } @catch (__unused NSException *e) {}
        }
        if (tag.length > 0) [paths addObject:tag];
    } @catch (__unused NSException *e) {}
}

/// 假设 Z：本地异步块 @0x10006171c 用 AppConfig#getBookDirByBookKey: 拼路径，
/// bookKey 来自 getBookKey: → getBookKeyByBookName:author:（格式 bookName_author），
/// 与 dicBook.bookKey（Legado URL 键）无关。seed 必须落到同一目录，否则
/// stringWithContentsOfFile 得 nil → callBackResponse 空载 → 无 QF。
static id LBAppConfigShared(void) {
    Class cls = NSClassFromString(@"AppConfig");
    if (!cls) return nil;
    if ([cls respondsToSelector:@selector(sharedInstance)]) {
        return ((id (*)(id, SEL))objc_msgSend)(cls, @selector(sharedInstance));
    }
    if ([cls respondsToSelector:@selector(sharedManager)]) {
        return ((id (*)(id, SEL))objc_msgSend)(cls, @selector(sharedManager));
    }
    return nil;
}

static NSString *LBNativeBookKey(NSString *bookName, NSString *author, NSDictionary *book) {
    id cfg = LBAppConfigShared();
    if (cfg && [book isKindOfClass:[NSDictionary class]]) {
        SEL gk = NSSelectorFromString(@"getBookKey:");
        if ([cfg respondsToSelector:gk]) {
            @try {
                id k = ((id (*)(id, SEL, id))objc_msgSend)(cfg, gk, book);
                if ([k isKindOfClass:[NSString class]] && [(NSString *)k length] > 0) {
                    return (NSString *)k;
                }
            } @catch (__unused NSException *e) {}
        }
    }
    if (cfg && bookName.length > 0) {
        SEL gk2 = NSSelectorFromString(@"getBookKeyByBookName:author:");
        if ([cfg respondsToSelector:gk2]) {
            @try {
                id k = ((id (*)(id, SEL, id, id))objc_msgSend)(
                    cfg, gk2, bookName, author ?: @"");
                if ([k isKindOfClass:[NSString class]] && [(NSString *)k length] > 0) {
                    return (NSString *)k;
                }
            } @catch (__unused NSException *e) {}
        }
    }
    // 静态回退：与 getBookKeyByBookName 的 stringByAppendingFormat:@"_%@" 同形
    if (bookName.length == 0) return nil;
    NSString *bn = bookName;
    if (bn.length > 20) bn = [bn substringToIndex:20];
    NSString *au = author ?: @"";
    if (au.length > 20) au = [au substringToIndex:20];
    return [bn stringByAppendingFormat:@"_%@", au];
}

/// 反汇编 @0x100061480：AppConfig#getBookDir:(book) 优先；其次 getBookDirByBookKey:。
static NSString *LBNativeBookDirForBook(NSDictionary *book, NSString *bookKey) {
    id cfg = LBAppConfigShared();
    if (cfg && [book isKindOfClass:[NSDictionary class]]) {
        SEL gd = NSSelectorFromString(@"getBookDir:");
        if ([cfg respondsToSelector:gd]) {
            @try {
                id d = ((id (*)(id, SEL, id))objc_msgSend)(cfg, gd, book);
                if ([d isKindOfClass:[NSString class]] && [(NSString *)d length] > 0) {
                    return (NSString *)d;
                }
            } @catch (__unused NSException *e) {}
        }
    }
    if (cfg && bookKey.length > 0) {
        SEL gd2 = NSSelectorFromString(@"getBookDirByBookKey:");
        if ([cfg respondsToSelector:gd2]) {
            @try {
                id d = ((id (*)(id, SEL, id))objc_msgSend)(cfg, gd2, bookKey);
                if ([d isKindOfClass:[NSString class]] && [(NSString *)d length] > 0) {
                    return (NSString *)d;
                }
            } @catch (__unused NSException *e) {}
        }
    }
    if (bookKey.length == 0) return nil;
    return [NSHomeDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"Documents/xsfolder/book/%@", bookKey]];
}

static NSString *LBNativeBookDirForKey(NSString *bookKey) {
    return LBNativeBookDirForBook(nil, bookKey);
}

static void LBLogHypothesisZFileProbe(NSString *tag, NSDictionary *book, NSString *bookKey,
                                      NSInteger cpIndex, NSUInteger bodyLen) {
    NSString *dir = LBNativeBookDirForBook(book, bookKey);
    NSString *rel = [NSString stringWithFormat:@"%ld", (long)cpIndex];
    NSString *cpPath = dir.length ? [dir stringByAppendingPathComponent:rel] : nil;
    BOOL exists = cpPath.length > 0 &&
                  [[NSFileManager defaultManager] fileExistsAtPath:cpPath];
    unsigned long long fsz = 0;
    if (exists) {
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:cpPath
                                                                               error:NULL];
        fsz = [attrs fileSize];
    }
    // 打出 lastPathComponent，区分 getBookKey 是「名|作者」还是「名_作者」
    LBStateLog([NSString stringWithFormat:
                @"hypothesis_Z %@ bookKey=%@ dirLeaf=%@ bookDirLen=%lu cpRel=%@ "
                @"fileExists=%d fileSize=%llu bodyLen=%lu",
                tag ?: @"-",
                bookKey ?: @"-",
                dir.lastPathComponent ?: @"-",
                (unsigned long)dir.length,
                rel,
                exists ? 1 : 0,
                fsz,
                (unsigned long)bodyLen]);
}

/// confirmed 边界：dicContents / xsfolder / setCpCached（禁 UI / pageModel）
static BOOL LBSeedConfirmedCache(id reader, NSDictionary *payload, NSMutableArray *paths) {
    if (!reader || ![payload isKindOfClass:[NSDictionary class]]) return NO;
    NSString *body = LBBodyFromPayload(payload);
    if (body.length == 0) return NO;

    NSString *title = payload[@"cpTitle"] ?: payload[@"title"] ?: @"章节";
    if (![title isKindOfClass:[NSString class]] || title.length == 0) title = @"章节";
    NSInteger cpIndex = LBCpIndexFromPayload(payload, reader);

    NSDictionary *dicBook = nil;
    @try {
        id d = [reader valueForKey:@"dicBook"];
        if ([d isKindOfClass:[NSDictionary class]]) dicBook = d;
    } @catch (__unused NSException *e) {}
    NSString *legacyKey = [dicBook[@"bookKey"] isKindOfClass:[NSString class]] ? dicBook[@"bookKey"] : nil;
    NSString *bookName = nil;
    NSString *author = nil;
    if ([dicBook[@"bookName"] isKindOfClass:[NSString class]]) bookName = dicBook[@"bookName"];
    else if ([dicBook[@"name"] isKindOfClass:[NSString class]]) bookName = dicBook[@"name"];
    else if ([dicBook[@"title"] isKindOfClass:[NSString class]]) bookName = dicBook[@"title"];
    if ([dicBook[@"author"] isKindOfClass:[NSString class]]) author = dicBook[@"author"];
    if (bookName.length == 0 && [payload[@"bookName"] isKindOfClass:[NSString class]]) {
        bookName = payload[@"bookName"];
    }
    if (author.length == 0 && [payload[@"author"] isKindOfClass:[NSString class]]) {
        author = payload[@"author"];
    }
    if (bookName.length == 0) bookName = @"斗破苍穹";
    if (author.length == 0) author = @"天蚕土豆";
    NSMutableDictionary *keyBook = [NSMutableDictionary dictionary];
    if ([dicBook isKindOfClass:[NSDictionary class]]) {
        [keyBook addEntriesFromDictionary:dicBook];
    }
    keyBook[@"bookName"] = bookName;
    keyBook[@"author"] = author;
    NSString *bookKey = LBNativeBookKey(bookName, author, keyBook);
    if (bookKey.length == 0) {
        bookKey = legacyKey.length > 0 ? legacyKey : @"legado|bridge";
    }
    NSString *sourceName = [dicBook[@"sourceName"] isKindOfClass:[NSString class]] ? dicBook[@"sourceName"] : @"本地静态测试源";
    if (sourceName.length == 0) {
        sourceName = [payload[@"sourceName"] isKindOfClass:[NSString class]] ? payload[@"sourceName"] : @"本地静态测试源";
    }
    LBStateLog([NSString stringWithFormat:
                @"hypothesis_Z native_bookKeyLen=%lu legacyKeyLen=%lu nameLen=%lu authorLen=%lu",
                (unsigned long)bookKey.length,
                (unsigned long)legacyKey.length,
                (unsigned long)bookName.length,
                (unsigned long)author.length]);

    // 1) dicContents
    @try {
        NSMutableDictionary *dc = nil;
        id cur = nil;
        @try { cur = [reader valueForKey:@"dicContents"]; } @catch (__unused NSException *e) {}
        if ([cur isKindOfClass:[NSMutableDictionary class]]) {
            dc = (NSMutableDictionary *)cur;
        } else if ([cur isKindOfClass:[NSDictionary class]]) {
            dc = [NSMutableDictionary dictionaryWithDictionary:(NSDictionary *)cur];
        } else {
            dc = [NSMutableDictionary dictionary];
        }
        dc[@(cpIndex)] = body;
        dc[[@(cpIndex) stringValue]] = body;
        if (title.length > 0) dc[title] = body;
        NSString *chUrl = payload[@"chapterUrl"] ?: payload[@"cpUrl"];
        if ([chUrl isKindOfClass:[NSString class]] && chUrl.length > 0) dc[chUrl] = body;
        if ([reader respondsToSelector:@selector(setDicContents:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(reader, @selector(setDicContents:), dc);
        } else {
            @try { [reader setValue:dc forKey:@"dicContents"]; } @catch (__unused NSException *e) {}
        }
        [paths addObject:@"dicContents"];
        id container = LBFindReadPageContainerForReader(reader);
        if (container) {
            LBApplyDicContents(container, dc, paths,
                               [NSString stringWithFormat:@"dicContents@%@",
                                NSStringFromClass(object_getClass(container))]);
        }
    } @catch (__unused NSException *e) {}

    // 2) xsfolder + localSourceText（供 queryCpFileByBook 读本地缓存）
    // 假设 Z：主写 native getBookDirByBookKey 目录；legacyKey 不同则双写兜底。
    @try {
        NSMutableArray<NSString *> *dirs = [NSMutableArray array];
        NSString *nativeDir = LBNativeBookDirForBook(keyBook, bookKey);
        if (nativeDir.length > 0) [dirs addObject:nativeDir];
        if (legacyKey.length > 0 && ![legacyKey isEqualToString:bookKey]) {
            NSString *legacyDir = [NSHomeDirectory() stringByAppendingPathComponent:
                                   [NSString stringWithFormat:@"Documents/xsfolder/book/%@", legacyKey]];
            if (legacyDir.length > 0) [dirs addObject:legacyDir];
        }
        NSString *primaryDir = dirs.firstObject;
        for (NSString *bookDir in dirs) {
            [[NSFileManager defaultManager] createDirectoryAtPath:bookDir
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:NULL];
            NSString *cpPath = [bookDir stringByAppendingPathComponent:
                                [NSString stringWithFormat:@"%ld", (long)cpIndex]];
            [body writeToFile:cpPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            NSString *dirKey = [bookDir lastPathComponent] ?: bookKey;
            NSString *altPath = [bookDir stringByAppendingPathComponent:
                                 [NSString stringWithFormat:@"%@%ld", dirKey, (long)cpIndex]];
            [body writeToFile:altPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            NSDictionary *lstPlist = @{
                @"list": @[ @{
                    @"title": title,
                    @"url": [@(cpIndex) stringValue]
                } ]
            };
            [lstPlist writeToFile:[bookDir stringByAppendingPathComponent:@"localSourceText"]
                       atomically:YES];
        }
        if (primaryDir.length > 0) {
            for (id tgt in @[reader, LBFindReadPageContainerForReader(reader) ?: [NSNull null]]) {
                if (tgt == (id)[NSNull null]) continue;
                @try { [tgt setValue:primaryDir forKey:@"bookDirPath"]; } @catch (__unused NSException *e) {}
                if ([tgt respondsToSelector:NSSelectorFromString(@"setBookDirPath:")]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(
                        tgt, NSSelectorFromString(@"setBookDirPath:"), primaryDir);
                }
            }
        }
        [paths addObject:@"xsfolder"];
        [paths addObject:@"localSourceText"];
        LBLogHypothesisZFileProbe(@"seed", keyBook, bookKey, cpIndex, body.length);
        if (primaryDir.length > 0) {
            LBStateLog([NSString stringWithFormat:
                        @"hypothesis_Z write_dirs primaryLeaf=%@ nDirs=%lu",
                        primaryDir.lastPathComponent ?: @"-",
                        (unsigned long)dirs.count]);
        }
    } @catch (__unused NSException *e) {}

    // 3) BookDbManager#setCpCached
    @try {
        id mgr = nil;
        for (NSString *cn in @[@"BookDbManager", @"BookQueryManager", @"CacherManager"]) {
            Class cls = NSClassFromString(cn);
            if (!cls) continue;
            if ([cls respondsToSelector:@selector(sharedInstance)]) {
                mgr = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(sharedInstance));
            } else if ([cls respondsToSelector:@selector(sharedManager)]) {
                mgr = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(sharedManager));
            }
            if (!mgr) continue;
            SEL sel = NSSelectorFromString(@"setCpCached:cpIndex:bookKey:sourceName:");
            if (![mgr respondsToSelector:sel]) continue;
            @try {
                ((void (*)(id, SEL, id, NSInteger, id, id))objc_msgSend)(
                    mgr, sel, body, cpIndex, bookKey, sourceName);
                [paths addObject:[NSString stringWithFormat:@"setCpCached@%@", cn]];
                break;
            } @catch (__unused NSException *e1) {
                @try {
                    ((void (*)(id, SEL, id, NSInteger, id, id))objc_msgSend)(
                        mgr, sel, title, cpIndex, bookKey, sourceName);
                    [paths addObject:[NSString stringWithFormat:@"setCpCachedTitle@%@", cn]];
                    break;
                } @catch (__unused NSException *e2) {}
            }
        }
    } @catch (__unused NSException *e) {}

    return paths.count > 0;
}

static void LBRequestContent(NSString *chapterUrl, NSString *bookUrl, NSString *sourceUrl) {
    if (chapterUrl.length == 0 || bookUrl.length == 0) return;
    id core = LBLegadoCoreIfReady();
    if (![core respondsToSelector:@selector(handleContentRequestWithChapterUrl:bookUrl:sourceUrl:)]) return;
    ((void (*)(id, SEL, NSString *, NSString *, NSString *))objc_msgSend)(
        core, @selector(handleContentRequestWithChapterUrl:bookUrl:sourceUrl:),
        chapterUrl, bookUrl, sourceUrl ?: @""
    );
}

/// 假设 P：loadCurCp 静态 callee 含 curPageVC；过早 invoke 会跳过 queryCpFile
static id LBContainerCurPageVC(id container) {
    if (!container) return nil;
    @try {
        id v = [container valueForKey:@"curPageVC"];
        return v;
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static void LBEnsureContainerReaderLink(id container, id reader) {
    if (!container || !reader) return;
    @try {
        id cur = nil;
        @try { cur = [container valueForKey:@"reader"]; } @catch (__unused NSException *e) {}
        if (cur == reader) return;
        if ([container respondsToSelector:NSSelectorFromString(@"setReader:")]) {
            ((void (*)(id, SEL, id))objc_msgSend)(
                container, NSSelectorFromString(@"setReader:"), reader);
        } else {
            @try { [container setValue:reader forKey:@"reader"]; } @catch (__unused NSException *e) {}
        }
        LBStateLog([NSString stringWithFormat:@"hypothesis_P link_reader %@",
                    NSStringFromClass(object_getClass(reader))]);
    } @catch (__unused NSException *e) {}
}

static NSUInteger LBCountOrZero(id obj) {
    if ([obj isKindOfClass:[NSArray class]]) return [(NSArray *)obj count];
    if ([obj isKindOfClass:[NSDictionary class]]) return [(NSDictionary *)obj count];
    if ([obj respondsToSelector:@selector(count)]) {
        @try { return [[obj valueForKey:@"count"] unsignedIntegerValue]; } @catch (__unused NSException *e) {}
    }
    return 0;
}

static void LBSetIntegerKey(id target, NSString *key, NSInteger value) {
    if (!target || key.length == 0) return;
    NSString *setter = [NSString stringWithFormat:@"set%@%@:",
                        [[key substringToIndex:1] uppercaseString],
                        [key substringFromIndex:1]];
    SEL sel = NSSelectorFromString(setter);
    @try {
        if ([target respondsToSelector:sel]) {
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(target, sel, value);
            return;
        }
    } @catch (__unused NSException *e) {}
    // 假设 R：标量 q/Q ivar 不能 object_setIvar(NSNumber*)，按 offset 写
    NSString *ivarName = [@"_" stringByAppendingString:key];
    Class cls = object_getClass(target);
    while (cls && cls != [NSObject class]) {
        Ivar iv = class_getInstanceVariable(cls, ivarName.UTF8String);
        if (iv) {
            const char *enc = ivar_getTypeEncoding(iv);
            if (enc && (enc[0] == 'q' || enc[0] == 'Q' || enc[0] == 'i' || enc[0] == 'I'
                        || enc[0] == 'l' || enc[0] == 'L')) {
                ptrdiff_t off = ivar_getOffset(iv);
                void *base = (__bridge void *)target;
                if (enc[0] == 'q' || enc[0] == 'l') {
                    *(NSInteger *)((uint8_t *)base + off) = value;
                } else if (enc[0] == 'Q' || enc[0] == 'L') {
                    *(NSUInteger *)((uint8_t *)base + off) = (NSUInteger)value;
                } else {
                    *(int *)((uint8_t *)base + off) = (int)value;
                }
                return;
            }
        }
        cls = class_getSuperclass(cls);
    }
    @try { [target setValue:@(value) forKey:key]; } @catch (__unused NSException *e) {}
}

static NSInteger LBReadIntegerKey(id target, NSString *key, NSInteger fallback) {
    if (!target || key.length == 0) return fallback;
    @try {
        if ([target respondsToSelector:NSSelectorFromString(key)]) {
            return ((NSInteger (*)(id, SEL))objc_msgSend)(target, NSSelectorFromString(key));
        }
    } @catch (__unused NSException *e) {}
    @try {
        id v = [target valueForKey:key];
        if ([v respondsToSelector:@selector(integerValue)]) return [v integerValue];
    } @catch (__unused NSException *e) {}
    return fallback;
}

/// 假设 Q：loadCurCp callee 还含 arrCatalog/count；缺目录会跳过 query
/// 假设 R/R2：分页模式 index 在 ReadPageModel._nCpIndex（method-map confirmed）；
/// TextReadVC3/ReadPageContainer **无** _curCpIndex（gates 的 curCp@r/c=-999 是误报）。
/// ReadScrollContainer 才有 curCpIndex，滚动模式再写。
static void LBEnsureLoadCurCpPrereqs(id reader, id container, NSDictionary *payload) {
    if (!reader || ![payload isKindOfClass:[NSDictionary class]]) return;
    NSInteger cpIndex = LBCpIndexFromPayload(payload, reader);
    NSString *title = payload[@"cpTitle"] ?: payload[@"title"] ?: @"章节";
    if (![title isKindOfClass:[NSString class]] || title.length == 0) title = @"章节";
    NSString *chUrl = payload[@"chapterUrl"] ?: payload[@"cpUrl"];
    if (![chUrl isKindOfClass:[NSString class]] || chUrl.length == 0) {
        chUrl = [@(cpIndex) stringValue];
    }

    id curPage = LBContainerCurPageVC(container);
    id pageModel = nil;
    if (curPage) {
        @try { pageModel = [curPage valueForKey:@"pageModel"]; } @catch (__unused NSException *e) {}
        if (!pageModel) {
            @try { pageModel = [curPage valueForKey:@"readPageModel"]; } @catch (__unused NSException *e) {}
        }
    }

    // 分页：只写 ReadPageModel 标量
    if (pageModel) {
        LBSetIntegerKey(pageModel, @"nCpIndex", cpIndex);
        LBSetIntegerKey(pageModel, @"nPageIndex", 0);
        NSUInteger cpCount = 1;
        @try {
            id cat = [reader valueForKey:@"arrCatalog"];
            NSUInteger n = LBCountOrZero(cat);
            if (n > 0) cpCount = n;
        } @catch (__unused NSException *e) {}
        LBSetIntegerKey(pageModel, @"nCpCount", (NSInteger)cpCount);
        // 假设 V：loadCurCp @0x1000d7d8c 为 cmp pageStatus,#3；!=3 则 epilogue 早退，
        // 永不进入 queryCpFileByBook（chain-msg + 反汇编 confirmed）。R2 误 seed=0。
        LBSetIntegerKey(pageModel, @"pageStatus", 3);
        LBStateLog([NSString stringWithFormat:
                    @"hypothesis_V seed pageModel nCpIndex=%ld nCpCount=%lu pageStatus=3",
                    (long)cpIndex, (unsigned long)cpCount]);
    }
    // 滚动容器若在栈上，补 curCpIndex
    for (id tgt in @[container ?: [NSNull null], curPage ?: [NSNull null]]) {
        if (tgt == (id)[NSNull null]) continue;
        NSString *cn = NSStringFromClass(object_getClass(tgt));
        if ([cn containsString:@"Scroll"]) {
            LBSetIntegerKey(tgt, @"curCpIndex", cpIndex);
        }
    }

    id cat = nil;
    @try { cat = [reader valueForKey:@"arrCatalog"]; } @catch (__unused NSException *e) {}
    if (LBCountOrZero(cat) == 0) {
        NSDictionary *chapter = @{
            @"title": title,
            @"name": title,
            @"url": chUrl,
            @"cpUrl": chUrl,
            @"index": @(cpIndex),
            @"cpIndex": @(cpIndex),
        };
        NSArray *arr = @[chapter];
        @try {
            if ([reader respondsToSelector:NSSelectorFromString(@"setArrCatalog:")]) {
                ((void (*)(id, SEL, id))objc_msgSend)(
                    reader, NSSelectorFromString(@"setArrCatalog:"), arr);
            } else {
                [reader setValue:arr forKey:@"arrCatalog"];
            }
            LBStateLog(@"hypothesis_Q seed_arrCatalog count=1");
        } @catch (__unused NSException *e) {
            LBStateLog(@"hypothesis_Q seed_arrCatalog_failed");
        }
    }

    // 假设 W：queryCpFileByBook → queryByActionID 调 AppConfig#getBookKey:(book)。
    // book=nil 或非 Dictionary / 缺 bookName|author → @0x10006114c cbz 早退，无 QF。
    // V 真机：pre pageStatus=3 → post=1，已越过 cmp #3；ivar _dicFatBook 仍为 nil。
    @try {
        id existing = nil;
        @try { existing = [reader valueForKey:@"dicFatBook"]; } @catch (__unused NSException *e) {}
        NSMutableDictionary *fat = nil;
        if ([existing isKindOfClass:[NSMutableDictionary class]]) {
            fat = (NSMutableDictionary *)existing;
        } else if ([existing isKindOfClass:[NSDictionary class]]) {
            fat = [NSMutableDictionary dictionaryWithDictionary:(NSDictionary *)existing];
        } else {
            fat = [NSMutableDictionary dictionary];
        }
        NSDictionary *dicBook = nil;
        @try {
            id d = [reader valueForKey:@"dicBook"];
            if ([d isKindOfClass:[NSDictionary class]]) dicBook = (NSDictionary *)d;
        } @catch (__unused NSException *e) {}
        NSString *bookName = nil;
        NSString *author = nil;
        if ([dicBook[@"bookName"] isKindOfClass:[NSString class]]) bookName = dicBook[@"bookName"];
        else if ([dicBook[@"name"] isKindOfClass:[NSString class]]) bookName = dicBook[@"name"];
        else if ([dicBook[@"title"] isKindOfClass:[NSString class]]) bookName = dicBook[@"title"];
        if ([dicBook[@"author"] isKindOfClass:[NSString class]]) author = dicBook[@"author"];
        if (bookName.length == 0 && [payload[@"bookName"] isKindOfClass:[NSString class]]) {
            bookName = payload[@"bookName"];
        }
        if (author.length == 0 && [payload[@"author"] isKindOfClass:[NSString class]]) {
            author = payload[@"author"];
        }
        if (bookName.length == 0) bookName = @"斗破苍穹";
        if (author.length == 0) author = @"天蚕土豆";
        if (![fat[@"bookName"] isKindOfClass:[NSString class]] || [fat[@"bookName"] length] == 0) {
            fat[@"bookName"] = bookName;
        }
        if (![fat[@"author"] isKindOfClass:[NSString class]] || [fat[@"author"] length] == 0) {
            fat[@"author"] = author;
        }
        id bk = nil;
        @try { bk = [reader valueForKey:@"bookKey"]; } @catch (__unused NSException *e) {}
        if (![bk isKindOfClass:[NSString class]] || [(NSString *)bk length] == 0) {
            bk = dicBook[@"bookKey"];
        }
        // 假设 Z：fat.bookKey 仅作旁路；真正路径键由 getBookKey(bookName,author) 决定。
        // 仍写入 nativeKey，避免其它读 bookKey 的路径漂移。
        NSString *nativeKey = LBNativeBookKey(bookName, author, fat);
        if (nativeKey.length > 0) {
            fat[@"bookKey"] = nativeKey;
            bk = nativeKey;
        } else if ([bk isKindOfClass:[NSString class]] && [(NSString *)bk length] > 0 &&
                   !([fat[@"bookKey"] isKindOfClass:[NSString class]] &&
                     [fat[@"bookKey"] length] > 0)) {
            fat[@"bookKey"] = bk;
        }
        // 假设 X（反汇编校正）：@0x10006116c/1a8 的 chapterList|chapterContent 是
        // queryByActionID 的 actionID（queryCpFileByBook 已硬编码 @"chapterContent"），
        // 不是 fat 字典键。W 之后最先挡住的字段是 book[@"_useSName"]：
        // sourceName 实参恒 nil（@0x100060ec0），length==0 → @0x100061204 返
        // 「没有使用中的站点」。
        // 假设 Y（形态校正，非仅 keys）：138bfb5/7b52bfb 虽 sourceILKeys=1 仍无 QF。
        // 真机 useSNameLen=7 = dicBook.sourceName「本地静态测试源」；越过后
        // @0x100061500 [useSName hasPrefix:@"localSource"] 失败，落入站点注册表分支
        // 而非本地 xsfolder。LBSeedConfirmedCache 写的文件名是 localSourceText，
        // 故强制 _useSName=localSourceText，并种 _sourceIL[localSourceText]=
        // bookShelf.plist 形 {_lCTime,lastChapterTitle}。本地 chapterContent 块
        // @0x100061808 还读 queryInfo[@"url"] → 补 arrCatalog.url（cpIndex 文件名）。
        NSString *prevUse = nil;
        if ([fat[@"_useSName"] isKindOfClass:[NSString class]] &&
            [fat[@"_useSName"] length] > 0) {
            prevUse = fat[@"_useSName"];
        } else if ([dicBook[@"_useSName"] isKindOfClass:[NSString class]] &&
                   [dicBook[@"_useSName"] length] > 0) {
            prevUse = dicBook[@"_useSName"];
        } else if ([dicBook[@"sourceName"] isKindOfClass:[NSString class]] &&
                   [dicBook[@"sourceName"] length] > 0) {
            prevUse = dicBook[@"sourceName"];
        } else if ([payload[@"sourceName"] isKindOfClass:[NSString class]] &&
                   [payload[@"sourceName"] length] > 0) {
            prevUse = payload[@"sourceName"];
        }
        NSString *useSName = @"localSourceText";
        if ([prevUse hasPrefix:@"localSource"] && [prevUse length] > 0) {
            useSName = prevUse;
        }
        fat[@"_useSName"] = useSName;
        NSMutableDictionary *sourceIL = nil;
        id sil = fat[@"_sourceIL"];
        if ([sil isKindOfClass:[NSMutableDictionary class]]) {
            sourceIL = (NSMutableDictionary *)sil;
        } else if ([sil isKindOfClass:[NSDictionary class]]) {
            sourceIL = [NSMutableDictionary dictionaryWithDictionary:(NSDictionary *)sil];
        } else {
            sourceIL = [NSMutableDictionary dictionary];
        }
        // 清掉非 localSource* 键（如「本地静态测试源」），避免 keys>=1 但查错键
        if (prevUse.length > 0 && ![prevUse hasPrefix:@"localSource"] &&
            sourceIL[prevUse] != nil) {
            [sourceIL removeObjectForKey:prevUse];
        }
        if (![sourceIL[useSName] isKindOfClass:[NSDictionary class]]) {
            NSString *lastTitle = title;
            if ([dicBook[@"_sourceIL"] isKindOfClass:[NSDictionary class]]) {
                id existingEntry = dicBook[@"_sourceIL"][useSName];
                if (![existingEntry isKindOfClass:[NSDictionary class]] &&
                    prevUse.length > 0) {
                    existingEntry = dicBook[@"_sourceIL"][prevUse];
                }
                if ([existingEntry isKindOfClass:[NSDictionary class]]) {
                    id lt = existingEntry[@"lastChapterTitle"];
                    if ([lt isKindOfClass:[NSString class]] && [(NSString *)lt length] > 0) {
                        lastTitle = (NSString *)lt;
                    }
                }
            }
            // 原版 bookShelf.plist 文本源站点对象形态
            sourceIL[useSName] = @{
                @"_lCTime": @"0",
                @"lastChapterTitle": lastTitle ?: @"",
            };
        }
        fat[@"_sourceIL"] = sourceIL;
        // queryInfo=arrCatalog 项：本地 chapterContent 读 queryInfo[@"url"] 作相对路径
        id catObj = nil;
        @try { catObj = [reader valueForKey:@"arrCatalog"]; } @catch (__unused NSException *e) {}
        if ([catObj isKindOfClass:[NSArray class]]) {
            NSMutableArray *patched = [NSMutableArray arrayWithCapacity:[(NSArray *)catObj count]];
            BOOL changed = NO;
            NSInteger i = 0;
            for (id item in (NSArray *)catObj) {
                if (![item isKindOfClass:[NSDictionary class]]) {
                    if (item) [patched addObject:item];
                    i++;
                    continue;
                }
                NSMutableDictionary *m = [NSMutableDictionary dictionaryWithDictionary:(NSDictionary *)item];
                // 本地 chapterContent @0x100061808：url 作 bookDir 相对文件名。
                // Legado 章 url 常为 http(s)，必须改成 cpIndex（与 xsfolder 下 "0"/"1" 对齐）。
                id idx = m[@"cpIndex"] ?: m[@"index"] ?: @(i);
                NSString *rel = [[idx description] copy] ?: [@(i) stringValue];
                NSString *curUrl = [m[@"url"] isKindOfClass:[NSString class]] ? m[@"url"] : @"";
                BOOL httpish = [curUrl hasPrefix:@"http://"] || [curUrl hasPrefix:@"https://"] ||
                               [curUrl containsString:@"://"];
                if (curUrl.length == 0 || httpish) {
                    m[@"url"] = rel;
                    changed = YES;
                }
                if (![m[@"_useSName"] isKindOfClass:[NSString class]] ||
                    ![m[@"_useSName"] isEqualToString:useSName]) {
                    m[@"_useSName"] = useSName;
                    changed = YES;
                }
                [patched addObject:m];
                i++;
            }
            if (changed) {
                @try {
                    if ([reader respondsToSelector:NSSelectorFromString(@"setArrCatalog:")]) {
                        ((void (*)(id, SEL, id))objc_msgSend)(
                            reader, NSSelectorFromString(@"setArrCatalog:"), patched);
                    } else {
                        [reader setValue:patched forKey:@"arrCatalog"];
                    }
                } @catch (__unused NSException *e) {}
            }
        }
        if ([reader respondsToSelector:NSSelectorFromString(@"setDicFatBook:")]) {
            ((void (*)(id, SEL, id))objc_msgSend)(
                reader, NSSelectorFromString(@"setDicFatBook:"), fat);
        } else {
            [reader setValue:fat forKey:@"dicFatBook"];
        }
        LBStateLog([NSString stringWithFormat:
                    @"hypothesis_W seed dicFatBook bookNameLen=%lu authorLen=%lu bookKeyLen=%lu",
                    (unsigned long)[fat[@"bookName"] length],
                    (unsigned long)[fat[@"author"] length],
                    (unsigned long)([fat[@"bookKey"] isKindOfClass:[NSString class]]
                                    ? [fat[@"bookKey"] length] : 0)]);
        LBStateLog([NSString stringWithFormat:
                    @"hypothesis_X seed _useSNameLen=%lu",
                    (unsigned long)([fat[@"_useSName"] isKindOfClass:[NSString class]]
                                    ? [fat[@"_useSName"] length] : 0)]);
        LBStateLog([NSString stringWithFormat:
                    @"hypothesis_Y seed _sourceILKeys=%lu useSNameLen=%lu "
                    @"useSName=%@ prevUseLen=%lu localPrefix=1",
                    (unsigned long)sourceIL.count,
                    (unsigned long)[useSName length],
                    useSName,
                    (unsigned long)(prevUse.length)]);
    } @catch (__unused NSException *e) {
        LBStateLog(@"hypothesis_W seed_dicFatBook_failed");
    }
}

static void LBLogLoadCurCpGates(id reader, id container, NSString *tag) {
    NSUInteger nCat = 0, nDc = 0, nDcC = 0, nFat = 0;
    NSString *bookKey = @"-";
    NSString *bookDir = @"-";
    NSInteger curR = -999, curC = -999, nCp = -999;
    @try { nCat = LBCountOrZero([reader valueForKey:@"arrCatalog"]); } @catch (__unused NSException *e) {}
    @try { nDc = LBCountOrZero([reader valueForKey:@"dicContents"]); } @catch (__unused NSException *e) {}
    @try { nFat = LBCountOrZero([reader valueForKey:@"dicFatBook"]); } @catch (__unused NSException *e) {}
    if (container) {
        @try { nDcC = LBCountOrZero([container valueForKey:@"dicContents"]); } @catch (__unused NSException *e) {}
    }
    @try {
        id bk = [reader valueForKey:@"bookKey"];
        if (![bk isKindOfClass:[NSString class]]) {
            id db = [reader valueForKey:@"dicBook"];
            if ([db isKindOfClass:[NSDictionary class]]) bk = db[@"bookKey"];
        }
        if ([bk isKindOfClass:[NSString class]]) bookKey = bk;
    } @catch (__unused NSException *e) {}
    @try {
        id bd = [reader valueForKey:@"bookDirPath"];
        if ([bd isKindOfClass:[NSString class]]) bookDir = bd;
    } @catch (__unused NSException *e) {}
    curR = LBReadIntegerKey(reader, @"curCpIndex", -999);
    if (container) curC = LBReadIntegerKey(container, @"curCpIndex", -999);
    id curPage = LBContainerCurPageVC(container);
    id pageModel = nil;
    if (curPage) {
        @try { pageModel = [curPage valueForKey:@"pageModel"]; } @catch (__unused NSException *e) {}
    }
    if (pageModel) nCp = LBReadIntegerKey(pageModel, @"nCpIndex", -999);
    NSInteger pageStatus = -999;
    if (pageModel) pageStatus = LBReadIntegerKey(pageModel, @"pageStatus", -999);
    else if (container) pageStatus = LBReadIntegerKey(container, @"pageStatus", -999);
    NSUInteger useSNameLen = 0, sourceILKeys = 0;
    @try {
        id fat = [reader valueForKey:@"dicFatBook"];
        if ([fat isKindOfClass:[NSDictionary class]]) {
            id us = fat[@"_useSName"] ?: fat[@"sourceName"];
            if ([us isKindOfClass:[NSString class]]) useSNameLen = [(NSString *)us length];
            id sil = fat[@"_sourceIL"];
            if ([sil isKindOfClass:[NSDictionary class]]) sourceILKeys = [(NSDictionary *)sil count];
        }
    } @catch (__unused NSException *e) {}

    LBStateLog([NSString stringWithFormat:
                @"hypothesis_R2 gates(%@) arrCatalog=%lu dicContents@r=%lu dicContents@c=%lu "
                @"dicFatBook=%lu bookKeyLen=%lu bookDirLen=%lu nCp@pm=%ld pageStatus=%ld "
                @"useSNameLen=%lu sourceILKeys=%lu "
                @"(curCp@r/c N/A paged-no-ivar got %ld/%ld)",
                tag ?: @"-",
                (unsigned long)nCat, (unsigned long)nDc, (unsigned long)nDcC,
                (unsigned long)nFat,
                (unsigned long)bookKey.length, (unsigned long)bookDir.length,
                (long)nCp, (long)pageStatus,
                (unsigned long)useSNameLen, (unsigned long)sourceILKeys,
                (long)curR, (long)curC]);
}

/// 假设 T：loadViewIfNeeded 阶段会 contentReady，但此时 VC 尚未 push，过早 invoke 无窗口/无链并很快回到书架
static BOOL LBReaderIsAttachedToUI(id reader) {
    if (![reader isKindOfClass:[UIViewController class]]) return NO;
    UIViewController *vc = (UIViewController *)reader;
    @try {
        if (vc.viewIfLoaded.window != nil) return YES;
    } @catch (__unused NSException *e) {}
    @try {
        if (vc.navigationController != nil) return YES;
    } @catch (__unused NSException *e) {}
    @try {
        if (vc.parentViewController != nil) return YES;
    } @catch (__unused NSException *e) {}
    @try {
        if (vc.presentingViewController != nil) return YES;
    } @catch (__unused NSException *e) {}
    return NO;
}

static void LBInvokeOriginalLoadCurCp(id reader, BOOL forceWithoutCurPage);
static void LBScheduleInvokeWhenPageReady(id reader, NSInteger attempt);

static void LBInvokeOriginalLoadCurCp(id reader, BOOL forceWithoutCurPage) {
    if (!reader) {
        LBStateLog(@"invoke_skip reason=null_reader");
        return;
    }
    if (!sOrigLoadCurCp) {
        LBStateLog(@"invoke_skip reason=null_orig");
        return;
    }
    if (sReentryGuard) {
        LBStateLog(@"invoke_skip reason=reentry");
        return;
    }
    if (sState == LBLoadCurCpStateInvokingOriginal || sState == LBLoadCurCpStateRendered) {
        LBStateLog([NSString stringWithFormat:@"invoke_skip reason=bad_state sm=%@",
                    LBLoadCurCpBridgeStateName()]);
        return;
    }

    id container = LBRouteBResolveContainer(reader);
    if (!container) {
        LBStateLog(@"invoke_skip reason=no_container");
        return;
    }
    // 假设 R2：+load 时 ReadPageContainer 可能未链入，此处补注册 native IMP
    if (!sOrigLoadCurCp) {
        for (NSString *cn in @[@"ReadPageContainer", @"TextRPageContainer",
                               NSStringFromClass(object_getClass(container))]) {
            Class cls = NSClassFromString(cn);
            if (!cls) continue;
            Method m = class_getInstanceMethod(cls, @selector(loadCurCp));
            if (!m) continue;
            IMP imp = method_getImplementation(m);
            if (!imp) continue;
            LBLoadCurCpBridgeRegisterOrig((void (*)(id, SEL))imp);
            LBStateLog([NSString stringWithFormat:
                        @"hypothesis_R2 late_register_orig %@ imp=%p", cn, imp]);
            break;
        }
    }
    if (!sOrigLoadCurCp) {
        LBStateLog(@"invoke_skip reason=null_orig_after_late_register");
        return;
    }
    LBEnsureContainerReaderLink(container, reader);
    id curPage = LBContainerCurPageVC(container);
    BOOL attached = LBReaderIsAttachedToUI(reader);
    id pageStatus = nil;
    @try { pageStatus = [container valueForKey:@"pageStatus"]; } @catch (__unused NSException *e) {}
    NSString *containerName = NSStringFromClass(object_getClass(container));
    LBStateLog([NSString stringWithFormat:
                @"hypothesis_T pre_invoke target=%@ curPageVC=%@ attached=%d pageStatus=%@ force=%d",
                containerName,
                curPage ? NSStringFromClass(object_getClass(curPage)) : @"nil",
                attached ? 1 : 0,
                pageStatus ?: @"nil",
                forceWithoutCurPage ? 1 : 0]);
    if (!attached && !forceWithoutCurPage) {
        LBStateLog([NSString stringWithFormat:
                    @"routeB defer_invoke attached=0 container=%@",
                    containerName]);
        LBScheduleInvokeWhenPageReady(reader, 0);
        return;
    }

    if (sPendingPayload) {
        NSMutableArray *paths = [NSMutableArray array];
        LBSeedConfirmedCache(reader, sPendingPayload, paths);
        LBEnsureLoadCurCpPrereqs(reader, container, sPendingPayload);
        LBLogLoadCurCpGates(reader, container, @"pre_invoke_routeB");
    } else {
        LBLogLoadCurCpGates(reader, container, @"no_payload");
    }

    sReentryGuard = YES;
    sInvokeCount++;
    LBSetState(LBLoadCurCpStateInvokingOriginal, @"routeB_invoke_begin");
    LBABInstallProbes();
    LBAGStartBgHeartbeat();
    LBABSyncProbe([NSString stringWithFormat:@"pre_invoke_orig target=%@", containerName]);
    LBTraceLoadCurCp([NSString stringWithFormat:
                      @"sm=invokingOriginal ch=%@ target=%@ orig=%p",
                      sChapterUrl ?: @"-", containerName, sOrigLoadCurCp]);
    // AQ/AR 探针：invoke 前 pageStatus + orig IMP 类名/地址/dladdr fname/是否主二进制 + container 视图层级 attach
    {
        NSString *aqOrigCls = @"?";
        NSString *aqOrigFname = @"?";
        BOOL aqOrigMain = NO;
        Dl_info di;
        if (dladdr((void *)sOrigLoadCurCp, &di)) {
            if (di.dli_sname) {
                aqOrigCls = [NSString stringWithUTF8String:di.dli_sname];
            }
            if (di.dli_fname) {
                aqOrigFname = [NSString stringWithUTF8String:di.dli_fname].lastPathComponent ?: @"?";
                aqOrigMain = (strstr(di.dli_fname, "StandarReader") != NULL &&
                              strstr(di.dli_fname, "LegadoBridge") == NULL);
            }
        }
        for (NSString *cn in @[@"ReadPageContainer", @"TextRPageContainer", containerName]) {
            Class cls = NSClassFromString(cn);
            if (!cls) continue;
            Method m = class_getInstanceMethod(cls, @selector(loadCurCp));
            if (!m) continue;
            if (method_getImplementation(m) == (IMP)sOrigLoadCurCp) {
                aqOrigCls = [NSString stringWithFormat:@"%@/loadCurCp", cn];
                break;
            }
        }
        LBABSyncProbe([NSString stringWithFormat:
                       @"ar_orig_imp_class cls=%@ imp=%p fname=%@ mainApp=%d",
                       aqOrigCls, (void *)sOrigLoadCurCp, aqOrigFname, aqOrigMain ? 1 : 0]);
    }
    {
        NSString *aqContainerAttach = @"none";
        @try {
            if ([container isKindOfClass:[UIView class]]) {
                UIView *cv = (UIView *)container;
                if (cv.window) aqContainerAttach = @"container_window";
                else if (cv.superview) aqContainerAttach = @"container_superview";
                else aqContainerAttach = @"container_orphan";
            } else if ([container isKindOfClass:[UIViewController class]]) {
                UIViewController *cvc = (UIViewController *)container;
                if (cvc.viewIfLoaded.window) aqContainerAttach = @"container_vc_window";
                else if (cvc.parentViewController) aqContainerAttach = @"container_vc_parent";
                else if (cvc.navigationController) aqContainerAttach = @"container_vc_nav";
                else aqContainerAttach = @"container_vc_orphan";
            }
        } @catch (__unused NSException *e) {}
        LBABSyncProbe([NSString stringWithFormat:
                       @"aq_container_attach state=%@ readerAttached=%d",
                       aqContainerAttach, attached ? 1 : 0]);
    }
    {
        // AR：pageStatus 同时取 container.pageStatus 和 pageModel.pageStatus（V 假设 cmp #3 对照 pageModel）
        id pmStatusPre = nil;
        NSString *pmStatusSrc = @"none";
        @try {
            id pageModel = [container valueForKey:@"pageModel"];
            if (pageModel) {
                pmStatusPre = [pageModel valueForKey:@"pageStatus"];
                pmStatusSrc = @"pageModel.pageStatus";
            }
        } @catch (__unused NSException *e) {}
        LBABSyncProbe([NSString stringWithFormat:
                       @"ar_pageStatus_pre container=%@ val=%@ pmSrc=%@ pmVal=%@",
                       containerName, pageStatus ?: @"nil", pmStatusSrc, pmStatusPre ?: @"nil"]);
        // 6A：原版路径 container->curPageVC->pageModel->pageStatus（diff §8.3；与上方 KVC 读数对照）
        {
            id opCurPageVCPre = LBOrigPathMsgSendId(container, @"curPageVC");
            NSNumber *opStatusPre = LBOrigPathPageStatus(container);
            LBABSyncProbe([NSString stringWithFormat:
                           @"ar_origpath_pre curPageVC=%@ pageStatus=%@",
                           opCurPageVCPre ? NSStringFromClass(object_getClass(opCurPageVCPre)) : @"nil",
                           opStatusPre ?: @"nil"]);
        }
    }
    @try {
        sOrigLoadCurCp(container, @selector(loadCurCp));
        LBABSyncProbe([NSString stringWithFormat:@"invoke_orig_returned target=%@", containerName]);
        // AQ 探针：invoke 后 pageStatus + main drain 脉冲
        {
            id pageStatusPost = nil;
            @try { pageStatusPost = [container valueForKey:@"pageStatus"]; } @catch (__unused NSException *e) {}
            id pmStatusPost = nil;
            NSString *pmStatusSrc = @"none";
            @try {
                id pageModel = [container valueForKey:@"pageModel"];
                if (pageModel) {
                    pmStatusPost = [pageModel valueForKey:@"pageStatus"];
                    pmStatusSrc = @"pageModel.pageStatus";
                }
            } @catch (__unused NSException *e) {}
            LBABSyncProbe([NSString stringWithFormat:
                           @"ar_pageStatus_post container=%@ val=%@ pmSrc=%@ pmVal=%@",
                           containerName, pageStatusPost ?: @"nil", pmStatusSrc, pmStatusPost ?: @"nil"]);
            // 6A：原版路径对照（同 pre 块）
            {
                id opCurPageVCPost = LBOrigPathMsgSendId(container, @"curPageVC");
                NSNumber *opStatusPost = LBOrigPathPageStatus(container);
                LBABSyncProbe([NSString stringWithFormat:
                               @"ar_origpath_post curPageVC=%@ pageStatus=%@",
                               opCurPageVCPost ? NSStringFromClass(object_getClass(opCurPageVCPost)) : @"nil",
                               opStatusPost ?: @"nil"]);
            }
        }
        {
            static atomic_int sAQDrainSeen;
            atomic_store(&sAQDrainSeen, 0);
            dispatch_async(dispatch_get_main_queue(), ^{
                atomic_store(&sAQDrainSeen, 1);
                LBABSyncProbe(@"aq_main_drain_pulse fired=1");
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                           dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                int drained = atomic_load(&sAQDrainSeen);
                LBABSyncProbe([NSString stringWithFormat:
                               @"aq_main_drain_result drained=%d", drained]);
            });
        }
        // AI：invoke 返回后立刻采样主队列是否排空 / 主线程 PC
        LBAICaptureMainMachThread();
        LBAIStartMainBlockSampler();
        LBStateLog([NSString stringWithFormat:@"invoke_orig_OK target=%@", containerName]);
        LBTraceLoadCurCp(@"ORIG loadCurCp OK");
        LBLogLoadCurCpGates(reader, container, @"post_invoke_routeB");
        LBABSyncProbe(@"post_invoke_gates_done");
        // 假设 Z：异步 notify=callBackResponse→QF；延迟探针确认 native 目录正文在位
        if (sPendingPayload) {
            NSDictionary *payload = sPendingPayload;
            NSInteger cpIndex = LBCpIndexFromPayload(payload, reader);
            NSUInteger bodyLen = LBBodyFromPayload(payload).length;
            NSString *bookName = @"斗破苍穹";
            NSString *author = @"天蚕土豆";
            NSMutableDictionary *probeBook = [NSMutableDictionary dictionary];
            @try {
                id fat = [reader valueForKey:@"dicFatBook"];
                if ([fat isKindOfClass:[NSDictionary class]]) {
                    [probeBook addEntriesFromDictionary:(NSDictionary *)fat];
                    if ([fat[@"bookName"] isKindOfClass:[NSString class]]) bookName = fat[@"bookName"];
                    if ([fat[@"author"] isKindOfClass:[NSString class]]) author = fat[@"author"];
                }
            } @catch (__unused NSException *e) {}
            probeBook[@"bookName"] = bookName;
            probeBook[@"author"] = author;
            NSString *bk = LBNativeBookKey(bookName, author, probeBook) ?: @"";
            LBLogHypothesisZFileProbe(@"post_invoke", probeBook, bk, cpIndex, bodyLen);
            LBABSyncProbe(@"post_invoke_z_probe_done");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                LBABSyncProbe(@"async_plus0.6s_enter");
                LBLogHypothesisZFileProbe(@"async_plus0.6s", probeBook, bk, cpIndex, bodyLen);
                LBABSyncProbe(@"async_plus0.6s_done");
            });
        }
        // 假设 O：invoke_orig_OK 后禁止人工 kick；等原生 queryCpFileByBook→QF→DR→finish
        if (sPendingPayload && LBBodyFromPayload(sPendingPayload).length > 0) {
            LBTraceLoadCurCp(@"hypothesis_O kick_disabled await_native_chain");
            LBStateLog(@"hypothesis_O kick_disabled await_native_QF_DR_finish");
            LBABSyncProbe(@"await_native_chain");
        }
    } @catch (NSException *ex) {
        LBABSyncProbe([NSString stringWithFormat:@"invoke_orig_EX %@", ex.reason ?: @""]);
        LBSetState(LBLoadCurCpStateFailed, [NSString stringWithFormat:@"invoke_orig_EX %@", ex.reason ?: @""]);
        sReentryGuard = NO;
        return;
    }
    sReentryGuard = NO;
    LBABSyncProbe(@"invoke_reentry_cleared");
    if (sState == LBLoadCurCpStateInvokingOriginal) {
        LBSetState(LBLoadCurCpStateIdle, @"invoke_orig_done_pending_render");
        LBABSyncProbe(@"invoke_state_idle");
        // AK：idle 后立即采 main PC（禁 WakeUp / 禁 drain enqueue；KEEP inThread）
        LBABSyncProbe(@"ak_main_idle_seen");
        LBAKStartPostIdleMainBlockForensics();
    }
}

static void LBScheduleInvokeWhenPageReady(id reader, NSInteger attempt) {
    if (attempt >= 30) {
        LBStateLog(@"routeB wait_container_timeout");
        LBSetState(LBLoadCurCpStateFailed, @"routeB_wait_container_timeout");
        return;
    }
    __weak id weakReader = reader;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        id strong = weakReader;
        if (!strong) {
            LBStateLog(@"hypothesis_R2 defer_tick reader_gone");
            return;
        }
        LBStateLog([NSString stringWithFormat:
                    @"hypothesis_R2 defer_tick_enter attempt=%ld", (long)attempt]);
        id container = nil;
        id curPage = nil;
        BOOL attached = NO;
        @try {
            container = LBRouteBResolveContainer(strong);
            curPage = LBContainerCurPageVC(container);
            attached = LBReaderIsAttachedToUI(strong);
        } @catch (NSException *ex) {
            LBStateLog([NSString stringWithFormat:@"hypothesis_R2 defer_tick EX %@",
                        ex.reason ?: @""]);
            LBScheduleInvokeWhenPageReady(strong, attempt + 1);
            return;
        }
        LBStateLog([NSString stringWithFormat:
                    @"routeB defer_tick attempt=%ld container=%@ curPageVC=%@ attached=%d",
                    (long)attempt,
                    container ? NSStringFromClass(object_getClass(container)) : @"nil",
                    curPage ? NSStringFromClass(object_getClass(curPage)) : @"nil",
                    attached ? 1 : 0]);
        if (container && attached) {
            LBInvokeOriginalLoadCurCp(strong, NO);
        } else if (attached && attempt >= 12) {
            LBStateLog(@"routeB defer_giveup attached_no_container");
            LBSetState(LBLoadCurCpStateFailed, @"routeB_no_container");
        } else {
            LBScheduleInvokeWhenPageReady(strong, attempt + 1);
        }
    });
}

/// 在窗口/导航栈上找 TextReadVC*（不依赖 CExports）
static id LBFindTextReaderVCInHierarchy(void) {
    // AK：禁止直接碰 UIApplication.windows / keyWindow；bg 仅弱缓存
    if (![NSThread isMainThread]) {
        LBABSyncProbe(@"hypothesis_AK ak_bg_windows_api_skip caller=LBFindTextReaderVCInHierarchy");
        UIWindow *kw = LBLegadoKeyWindow();
        NSArray *windows = kw ? @[kw] : @[];
        for (UIWindow *w in windows) {
            UIViewController *root = w.rootViewController;
            if (!root) continue;
            NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
            while (stack.count > 0) {
                UIViewController *vc = stack.lastObject;
                [stack removeLastObject];
                NSString *cn = NSStringFromClass([vc class]);
                if ([cn containsString:@"TextReadVC"] || [cn containsString:@"ReadVCBase"]) {
                    return vc;
                }
                for (UIViewController *c in vc.childViewControllers) [stack addObject:c];
                if (vc.presentedViewController) [stack addObject:vc.presentedViewController];
                if ([vc isKindOfClass:[UINavigationController class]]) {
                    for (UIViewController *c in [(UINavigationController *)vc viewControllers]) {
                        [stack addObject:c];
                    }
                }
            }
        }
        return nil;
    }
    UIWindow *key = LBLegadoKeyWindow();
    NSMutableArray *windows = [NSMutableArray array];
    if (key) [windows addObject:key];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w && ![windows containsObject:w]) [windows addObject:w];
            }
        }
    }
    for (UIWindow *w in windows) {
        UIViewController *root = w.rootViewController;
        if (!root) continue;
        NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
        while (stack.count > 0) {
            UIViewController *vc = stack.lastObject;
            [stack removeLastObject];
            NSString *cn = NSStringFromClass([vc class]);
            if ([cn containsString:@"TextReadVC"] || [cn containsString:@"ReadVCBase"]) {
                return vc;
            }
            for (UIViewController *c in vc.childViewControllers) [stack addObject:c];
            if (vc.presentedViewController) [stack addObject:vc.presentedViewController];
            if ([vc isKindOfClass:[UINavigationController class]]) {
                for (UIViewController *c in [(UINavigationController *)vc viewControllers]) {
                    [stack addObject:c];
                }
            }
        }
    }
    return nil;
}

static void LBScheduleContentReadyWhenReaderReady(NSInteger attempt) {
    if (attempt >= 40) {
        LBStateLog(@"routeB wait_reader_timeout");
        return;
    }
    if (!sPendingPayload || LBBodyFromPayload(sPendingPayload).length == 0) return;
    if (sState != LBLoadCurCpStateContentReady && sState != LBLoadCurCpStateFetching) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!sPendingPayload || LBBodyFromPayload(sPendingPayload).length == 0) return;
        if (sState != LBLoadCurCpStateContentReady && sState != LBLoadCurCpStateFetching) return;
        id reader = sWeakReader ?: LBFindTextReaderVCInHierarchy();
        if (reader) {
            LBStateLog([NSString stringWithFormat:
                        @"routeB reader_ready attempt=%ld cls=%@",
                        (long)attempt, NSStringFromClass(object_getClass(reader))]);
            LBTryContentReadyAndInvoke(reader, sPendingPayload);
            return;
        }
        LBStateLog([NSString stringWithFormat:
                    @"routeB wait_reader attempt=%ld", (long)attempt]);
        LBScheduleContentReadyWhenReaderReady(attempt + 1);
    });
}

static void LBTryContentReadyAndInvoke(id reader, NSDictionary *payload) {
    if (!reader || ![payload isKindOfClass:[NSDictionary class]]) return;
    if (LBBodyFromPayload(payload).length == 0) {
        LBSetState(LBLoadCurCpStateFailed, @"contentReady_no_body");
        return;
    }
    sPendingPayload = [payload copy];
    sWeakReader = reader;
    LBSetState(LBLoadCurCpStateContentReady, @"contentReady");

    NSMutableArray *paths = [NSMutableArray array];
    LBSeedConfirmedCache(reader, payload, paths);
    LBStateLog([NSString stringWithFormat:@"routeB seed_cache paths=%@",
                [paths componentsJoinedByString:@","] ?: @"-"]);

    id container = LBRouteBResolveContainer(reader);
    if (container) {
        LBEnsureLoadCurCpPrereqs(reader, container, payload);
        LBStateLog(@"routeB_container_hit immediate");
        // 有 container 即尝试 invoke；attached=0 时由 LBInvokeOriginalLoadCurCp 内部 defer
        LBInvokeOriginalLoadCurCp(reader, YES);
        return;
    }
    LBStateLog(@"routeB schedule_wait_container");
    LBScheduleInvokeWhenPageReady(reader, 0);
}

BOOL LBLoadCurCpBridgeHandleHook(id self, SEL _cmd,
                                 BOOL isLegado,
                                 NSString *bookUrl,
                                 NSString *sourceUrl,
                                 NSString *chapterUrl) {
    if (!isLegado) return NO;

    if (self) {
        sWeakHookReceiver = self;
    }

    if (LBLoadCurCpBridgePassThroughToNative()) {
        LBStateLog(@"hook_passthrough_native");
        return NO;
    }

    sWeakReader = LBReaderVCFromContext(self) ?: self;
    if (bookUrl.length > 0) sBookUrl = [bookUrl copy];
    if (chapterUrl.length > 0) {
        sChapterUrl = [chapterUrl copy];
        sToken = [chapterUrl copy];
    }

    if (sState == LBLoadCurCpStateRendered) {
        LBStateLog(@"hook_skip_rendered");
        return YES;
    }

    if (sPendingPayload && LBBodyFromPayload(sPendingPayload).length > 0 &&
        sState != LBLoadCurCpStateFetching) {
        // 路 B：contentReady 后放行原生 loadCurCp，由原版走完 queryCpFile→division
        if (sState == LBLoadCurCpStateContentReady ||
            sState == LBLoadCurCpStateInvokingOriginal) {
            LBStateLog(@"routeB hook_passthrough_native_loadCurCp");
            return NO;
        }
        LBStateLog(@"hypothesis_T5 hook_block_early_invoke await_postCurCp");
        return YES;
    }

    if (sState == LBLoadCurCpStateFetching) {
        LBStateLog(@"hook_already_fetching");
        return YES;
    }

    if (chapterUrl.length > 0 && bookUrl.length > 0) {
        LBSetState(LBLoadCurCpStateFetching, @"hook_start_fetch");
        LBRequestContent(chapterUrl, bookUrl, sourceUrl);
        LBStateLog([NSString stringWithFormat:@"hook_fetch book=%@ ch=%@", bookUrl, chapterUrl]);
        return YES;
    }

    LBSetState(LBLoadCurCpStateFailed, @"hook_no_chapter_url");
    return YES;
}

void LBLoadCurCpBridgeOnContentPosted(NSDictionary *payload, id readerVC) {
    if (![payload isKindOfClass:[NSDictionary class]] || payload.count == 0) return;

    NSString *body = LBBodyFromPayload(payload);
    BOOL hasBody = body.length > 0;
    BOOL hasRealError = LBPayloadHasRealError(payload);

    if (!hasBody && hasRealError) {
        LBSetState(LBLoadCurCpStateFailed,
                   [NSString stringWithFormat:@"content_err %@", payload[@"error"]]);
        return;
    }
    if (!hasBody && !hasRealError && payload[@"error"]) {
        LBStateLog(@"content_err_empty_ignored");
        return;
    }
    if (!hasBody) {
        LBStateLog(@"content_post_no_body");
        return;
    }

    sPendingPayload = [payload copy];
    NSString *ch = payload[@"chapterUrl"] ?: payload[@"cpUrl"];
    if ([ch isKindOfClass:[NSString class]] && ch.length > 0) {
        sChapterUrl = ch;
        sToken = ch;
    }
    id bookUrl = payload[@"bookUrl"];
    if ([bookUrl isKindOfClass:[NSString class]]) sBookUrl = bookUrl;

    id reader = readerVC ?: sWeakReader ?: LBFindTextReaderVCInHierarchy();
    if (!reader) {
        LBSetState(LBLoadCurCpStateContentReady, @"contentReady_no_reader_yet");
        LBStateLog(@"routeB schedule_wait_reader");
        LBScheduleContentReadyWhenReaderReady(0);
        return;
    }
    LBTryContentReadyAndInvoke(reader, payload);
}
