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

/// 假设 AC/AD/AE/AF：CB 透传链上 check/format/QF 派发取证（禁 bounce / 禁 dontFormat）
/// AB 真机：cb_enter×N 无 check/format/cb_exit；6b5ef8e 未清 openOnce 假阳性已 revert 回 swcf
/// AD：original CB 在 check 前仅 response==nil 门禁；runtime check/format 在 BookQueryManager 覆盖实现
/// AE：format 编码为返回 id（@40@0:8@16@24@32）；void 钩会丢掉返回值并破坏 format 后 QF 派发
/// AF：撤 callback_inThread；查主队列不排空（前台挂起 / 心跳）并让 async_main→QF 自然落地
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
static NSString *LBAFAppStateTag(void);
static void LBAFStartMainHeartbeat(void);
static IMP LBACPeelObserverNext(Class cls, SEL sel, IMP cur);
static void LBAB_CallBackResponse(id self, SEL _cmd, id response, id config, id userInfo);
static id LBAB_FormatCallBack(id self, SEL _cmd, id response, id config, id userInfo);
static BOOL LBAB_CheckCallBack(id self, SEL _cmd, id response, id config, id userInfo);
static void LBAE_QueryFinish(id self, SEL _cmd, id response, id config, id userInfo);
static void LBAEProbeDispatchGates(id response, id config, id userInfo, NSString *phase);

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

/// POSIX append+fsync：SIGKILL 前尽量保住最后一条存活点
static NSString *LBAFAppStateTag(void) {
    // 0=active 1=inactive 2=background；非主线程读 UIApplication 仅作取证
    NSInteger st = -1;
    @try {
        st = (NSInteger)[UIApplication sharedApplication].applicationState;
    } @catch (__unused NSException *e) {
        st = -1;
    }
    const char *name = "unknown";
    if (st == UIApplicationStateActive) name = "active";
    else if (st == UIApplicationStateInactive) name = "inactive";
    else if (st == UIApplicationStateBackground) name = "background";
    return [NSString stringWithFormat:@"app=%s(%ld)", name, (long)st];
}

static void LBAFStartMainHeartbeat(void) {
    // AF：invoke 前后主队列心跳；若 hb 停而进程仍在 → 主线程堵死；若 hb 与进程同灭 → 重建/挂起
    for (NSInteger i = 0; i < 12; i++) {
        int64_t ns = (int64_t)((0.25 + 0.25 * i) * NSEC_PER_SEC);
        NSInteger tick = i;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, ns), dispatch_get_main_queue(), ^{
            LBABSyncProbe([NSString stringWithFormat:@"af_main_hb tick=%ld %@",
                           (long)tick, LBAFAppStateTag()]);
        });
    }
}

static void LBABSyncProbe(NSString *tag) {
    if (tag.length == 0) return;
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_ab_probe.txt"];
    const char *cpath = path.fileSystemRepresentation;
    if (!cpath) return;

    char buf[640];
    time_t now = time(NULL);
    struct tm tm;
    localtime_r(&now, &tm);
    int n = snprintf(buf, sizeof(buf),
                     "%04d-%02d-%02d %02d:%02d:%02d | hypothesis_AC %s main=%d inv=%lu pid=%d\n",
                     tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
                     tm.tm_hour, tm.tm_min, tm.tm_sec,
                     tag.UTF8String ?: "?",
                     [NSThread isMainThread] ? 1 : 0,
                     (unsigned long)sInvokeCount,
                     (int)getpid());
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

static void LBABOnFatalSignal(int sig) {
    char mark[80];
    int n = snprintf(mark, sizeof(mark), "hypothesis_AC fatal_signal SIG=%d\n", sig);
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
    signal(sig, SIG_DFL);
    raise(sig);
}

static void LBABInstallSignalProbes(void) {
    if (sABSignalInstalled) return;
    sABSignalInstalled = YES;
    signal(SIGSEGV, LBABOnFatalSignal);
    signal(SIGBUS, LBABOnFatalSignal);
    signal(SIGABRT, LBABOnFatalSignal);
    signal(SIGTRAP, LBABOnFatalSignal);
    signal(SIGILL, LBABOnFatalSignal);
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
    LBABSyncProbe([NSString stringWithFormat:
                   @"qf_enter self=%@ respLen=%lu action=%@ respCls=%@ %@",
                   self ? NSStringFromClass(object_getClass(self)) : @"nil",
                   (unsigned long)respLen,
                   [action isKindOfClass:[NSString class]] ? action : @"-",
                   response ? NSStringFromClass(object_getClass(response)) : @"nil",
                   LBAFAppStateTag()]);
    @try {
        if (sAENextQueryFinish) {
            sAENextQueryFinish(self, _cmd, response, config, userInfo);
        } else {
            LBABSyncProbe(@"qf_early_return reason=null_next");
        }
    } @catch (NSException *ex) {
        LBABSyncProbe([NSString stringWithFormat:@"qf_EX %@", ex.reason ?: @""]);
    }
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
    LBABSyncProbe([NSString stringWithFormat:
                   @"cb_enter respLen=%lu action=%@ target=%@ dontFormat=%d self=%@",
                   (unsigned long)respLen,
                   [action isKindOfClass:[NSString class]] ? action : @"-",
                   target ? NSStringFromClass(object_getClass(target)) : @"nil",
                   dont ? 1 : 0,
                   selfCls]);
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
    // AF：不再注入 callback_inThread；保持 original async_main 派 QF（禁 bounce/dontFormat）。
    // AE 的 inThread 能进 QF 但不能上屏，且主队列 pulse 仍为 0——疑前台挂起导致主队列不排空。
    LBABSyncProbe([NSString stringWithFormat:
                   @"af_no_inThread_inject action=%@ %@",
                   [action isKindOfClass:[NSString class]] ? action : @"-",
                   LBAFAppStateTag()]);
    sADCheckEntered = 0;
    sABInCallBack = 1;
    @try {
        sABNextCallBackResponse(self, _cmd, response, config, userInfo);
    } @finally {
        sABInCallBack = 0;
    }
    // AE/AF：original 在 format 后可能 dispatch_async(main) 派 QF；CB 返回后主队列脉冲确认可排空
    LBAEProbeDispatchGates(response, config, userInfo, @"after_cb");
    LBABSyncProbe([NSString stringWithFormat:@"af_after_cb %@", LBAFAppStateTag()]);
    dispatch_async(dispatch_get_main_queue(), ^{
        LBABSyncProbe([NSString stringWithFormat:@"qf_dispatch_main_pulse %@", LBAFAppStateTag()]);
    });
    // AF：bg 侧 1.2s 内等主队列回执；TIMEOUT=主线程堵死/未跑 runloop；ok=主队列可排空
    {
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_main_queue(), ^{
            LBABSyncProbe([NSString stringWithFormat:@"af_main_drain_ok %@", LBAFAppStateTag()]);
            dispatch_semaphore_signal(sem);
        });
        long waitRc = dispatch_semaphore_wait(
            sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)));
        if (waitRc == 0) {
            LBABSyncProbe(@"af_main_drain_wait_ok");
        } else {
            LBABSyncProbe(@"af_main_drain_TIMEOUT");
        }
    }
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
    // 只装一次：invoke 前反复 setImplementation 会把 next 指到 forensics 桩并成环
    if (sABHooksInstalled) return;

    Class net = NSClassFromString(@"LPNetWork2");
    if (net) {
        SEL cbSel = NSSelectorFromString(@"callBackResponse:config:userInfo:");
        Method cbm = class_getInstanceMethod(net, cbSel);
        if (cbm) {
            IMP cur = method_getImplementation(cbm);
            if (cur == (IMP)LBAB_CallBackResponse) {
                LBABSyncProbe(@"install_cb_skip already_self");
            } else if (!sABNextCallBackResponse) {
                IMP next = LBACPeelObserverNext(net, cbSel, cur);
                if (!next) {
                    LBABSyncProbe([NSString stringWithFormat:
                                   @"install_cb_pollute_blocked cur=%p", cur]);
                } else {
                    if (next != cur) {
                        LBABSyncProbe([NSString stringWithFormat:
                                       @"install_cb_peeled cur=%p next=%p", cur, next]);
                    }
                    sABNextCallBackResponse = (void (*)(id, SEL, id, id, id))next;
                    method_setImplementation(cbm, (IMP)LBAB_CallBackResponse);
                    LBABSyncProbe([NSString stringWithFormat:
                                   @"install_cb next=%p", sABNextCallBackResponse]);
                }
            } else {
                LBABSyncProbe([NSString stringWithFormat:
                               @"install_cb_skip next_frozen cur=%p", cur]);
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
    LBABSyncProbe([NSString stringWithFormat:@"pre_invoke_orig target=%@ %@",
                   containerName, LBAFAppStateTag()]);
    LBAFStartMainHeartbeat();
    LBTraceLoadCurCp([NSString stringWithFormat:
                      @"sm=invokingOriginal ch=%@ target=%@ orig=%p",
                      sChapterUrl ?: @"-", containerName, sOrigLoadCurCp]);
    @try {
        sOrigLoadCurCp(container, @selector(loadCurCp));
        LBABSyncProbe([NSString stringWithFormat:@"invoke_orig_returned target=%@ %@",
                       containerName, LBAFAppStateTag()]);
        LBStateLog([NSString stringWithFormat:@"invoke_orig_OK target=%@", containerName]);
        LBTraceLoadCurCp(@"ORIG loadCurCp OK");
        // AF：立即结束 invoke 临界区并让出主队列，使已入队的 async_main QF 优先于 Z 探针重活
        sReentryGuard = NO;
        if (sState == LBLoadCurCpStateInvokingOriginal) {
            LBSetState(LBLoadCurCpStateIdle, @"invoke_orig_done_pending_render");
            LBABSyncProbe([NSString stringWithFormat:@"invoke_state_idle %@", LBAFAppStateTag()]);
        }
        LBABSyncProbe(@"invoke_reentry_cleared");
        LBABSyncProbe(@"await_native_chain");
        __weak id weakReader = reader;
        __weak id weakContainer = container;
        NSDictionary *payload = sPendingPayload;
        dispatch_async(dispatch_get_main_queue(), ^{
            LBABSyncProbe([NSString stringWithFormat:@"af_main_drain_slot %@", LBAFAppStateTag()]);
            id strongReader = weakReader;
            id strongContainer = weakContainer;
            if (strongReader) {
                LBLogLoadCurCpGates(strongReader, strongContainer, @"post_invoke_routeB");
            }
            LBABSyncProbe(@"post_invoke_gates_done");
            if (payload) {
                NSInteger cpIndex = LBCpIndexFromPayload(payload, strongReader);
                NSUInteger bodyLen = LBBodyFromPayload(payload).length;
                NSString *bookName = @"斗破苍穹";
                NSString *author = @"天蚕土豆";
                NSMutableDictionary *probeBook = [NSMutableDictionary dictionary];
                @try {
                    id fat = [strongReader valueForKey:@"dicFatBook"];
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
                    LBABSyncProbe([NSString stringWithFormat:@"async_plus0.6s_enter %@",
                                   LBAFAppStateTag()]);
                    LBLogHypothesisZFileProbe(@"async_plus0.6s", probeBook, bk, cpIndex, bodyLen);
                    LBABSyncProbe(@"async_plus0.6s_done");
                });
            }
            if (payload && LBBodyFromPayload(payload).length > 0) {
                LBTraceLoadCurCp(@"hypothesis_O kick_disabled await_native_chain");
                LBStateLog(@"hypothesis_O kick_disabled await_native_QF_DR_finish");
            }
        });
        return;
    } @catch (NSException *ex) {
        LBABSyncProbe([NSString stringWithFormat:@"invoke_orig_EX %@", ex.reason ?: @""]);
        LBSetState(LBLoadCurCpStateFailed, [NSString stringWithFormat:@"invoke_orig_EX %@", ex.reason ?: @""]);
        sReentryGuard = NO;
        return;
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
    NSArray *windows = [UIApplication sharedApplication].windows;
    if (windows.count == 0) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        UIWindow *kw = [UIApplication sharedApplication].keyWindow;
#pragma clang diagnostic pop
        if (kw) windows = @[kw];
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
