#import "LBHookSiteRegistry.h"
#import <objc/message.h>
#import <pthread.h>
#import <dlfcn.h>
#import <string.h>

NSString * const LBSetDicBookExpectedEncodingABI = @"v24@0:8@16";

@interface LBHookSiteEntry : NSObject
@property (nonatomic, assign) Class owner;
@property (nonatomic, assign) SEL selector;
@property (nonatomic, copy) NSString *ownerName;
@property (nonatomic, copy) NSString *typeEncoding;
@property (nonatomic, assign) IMP previousIMP;
@property (nonatomic, assign) IMP replacementIMP;
@property (nonatomic, assign) LBHookSiteInstallState installState;
@property (nonatomic, strong, nullable) id replacementBlockLifetime; // 进程生命周期持有，不 imp_removeBlock
@property (nonatomic, assign) NSInteger maxDepthSeen;
@property (nonatomic, assign) NSInteger fatalReentryCount;
@end

@implementation LBHookSiteEntry
@end

static NSMutableDictionary<NSString *, LBHookSiteEntry *> *LBHookSiteMap(void) {
    static NSMutableDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ map = [NSMutableDictionary dictionary]; });
    return map;
}

static NSString *LBHookSiteKey(Class owner, SEL sel) {
    if (!owner || !sel) return @"";
    return [NSString stringWithFormat:@"%p|%@", (void *)owner, NSStringFromSelector(sel)];
}

static pthread_key_t LBHookTLSKey;
static dispatch_once_t LBHookTLSOnce;

static void LBHookTLSInit(void) {
    dispatch_once(&LBHookTLSOnce, ^{
        pthread_key_create(&LBHookTLSKey, NULL);
    });
}

static NSMutableDictionary<NSString *, NSNumber *> *LBHookTLSDepthMap(void) {
    LBHookTLSInit();
    NSMutableDictionary *map = (__bridge NSMutableDictionary *)pthread_getspecific(LBHookTLSKey);
    if (!map) {
        map = [NSMutableDictionary dictionary];
        pthread_setspecific(LBHookTLSKey, (__bridge_retained void *)map);
    }
    return map;
}

static BOOL LBHookSiteEnter(LBHookSiteEntry *entry) {
    if (!entry) return NO;
    NSString *key = LBHookSiteKey(entry.owner, entry.selector);
    NSMutableDictionary *depths = LBHookTLSDepthMap();
    NSInteger depth = [depths[key] integerValue] + 1;
    depths[key] = @(depth);
    if (depth > entry.maxDepthSeen) entry.maxDepthSeen = depth;
    if (depth > 1) {
        entry.fatalReentryCount += 1;
        NSString *marker = [NSString stringWithFormat:
                            @"LBHookSiteFatalReentry owner=%@ sel=%@ depth=%ld",
                            entry.ownerName ?: @"?",
                            NSStringFromSelector(entry.selector) ?: @"?",
                            (long)depth];
        NSLog(@"[LegadoBridge] %@", marker);
        NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_hook_reentry_fatal.txt"];
        [marker writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        depths[key] = @(depth - 1);
        if ([depths[key] integerValue] <= 0) [depths removeObjectForKey:key];
        return NO;
    }
    return YES;
}

static void LBHookSiteLeave(LBHookSiteEntry *entry) {
    if (!entry) return;
    NSString *key = LBHookSiteKey(entry.owner, entry.selector);
    NSMutableDictionary *depths = LBHookTLSDepthMap();
    NSInteger depth = [depths[key] integerValue] - 1;
    if (depth <= 0) {
        [depths removeObjectForKey:key];
    } else {
        depths[key] = @(depth);
    }
}

BOOL LBClassDeclaresInstanceMethod(Class cls, SEL sel) {
    if (!cls || !sel) return NO;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL found = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) {
            found = YES;
            break;
        }
    }
    if (methods) free(methods);
    return found;
}

static BOOL LBIMPLooksLikeBlockStub(IMP imp) {
    if (!imp) return NO;
    Dl_info info;
    memset(&info, 0, sizeof(info));
    if (!dladdr((void *)imp, &info)) {
        // 无法解析的 IMP：按不可安全串联处理
        return YES;
    }
    // 无名符号常见于 imp_implementationWithBlock trampoline（不可安全串联）
    if (!info.dli_sname || info.dli_sname[0] == '\0') {
        return YES;
    }
    if (strstr(info.dli_sname, "block_invoke") != NULL) return YES;
    if (strstr(info.dli_sname, "_block_invoke") != NULL) return YES;
    // imp_implementationWithBlock 常落在 libclosure
    if (info.dli_fname && strstr(info.dli_fname, "libclosure") != NULL) {
        return YES;
    }
    return NO;
}

BOOL LBHookSiteRegistryIsKnownReplacement(IMP imp) {
    if (!imp) return NO;
    @synchronized (LBHookSiteMap()) {
        for (LBHookSiteEntry *e in LBHookSiteMap().allValues) {
            if (e.replacementIMP == imp) return YES;
        }
    }
    return NO;
}

static BOOL LBHookSiteFailClosedForCurrent(IMP current, NSString **outReason) {
    if (LBHookSiteRegistryIsKnownReplacement(current)) {
        if (outReason) *outReason = @"current_is_bridge_replacement";
        return YES;
    }
    // 未知第三方 block 链：无法安全串联 → fail-closed
    if (LBIMPLooksLikeBlockStub(current)) {
        if (outReason) *outReason = @"unknown_third_party_block_chain";
        return YES;
    }
    return NO;
}

LBHookInstallResult LBHookSiteRegistryInstallSetDicBook(
    Class declaringOwner,
    NSString *expectedEncoding,
    LBSetDicBookInvokeFn invokeFn,
    NSString **outSanitizedReason
) {
    if (outSanitizedReason) *outSanitizedReason = nil;
    if (!declaringOwner || !invokeFn) {
        if (outSanitizedReason) *outSanitizedReason = @"nil_owner_or_invoke";
        return LBHookInstallResultFailClosed;
    }
    SEL sel = @selector(setDicBook:);
    if (!LBClassDeclaresInstanceMethod(declaringOwner, sel)) {
        if (outSanitizedReason) *outSanitizedReason = @"not_declaring_owner";
        return LBHookInstallResultNotDeclaringOwner;
    }
    Method m = class_getInstanceMethod(declaringOwner, sel);
    if (!m) {
        if (outSanitizedReason) *outSanitizedReason = @"no_method";
        return LBHookInstallResultNoMethod;
    }
    const char *encC = method_getTypeEncoding(m) ?: "";
    NSString *enc = @(encC);
    NSString *expect = expectedEncoding.length > 0 ? expectedEncoding : LBSetDicBookExpectedEncodingABI;
    if (![enc isEqualToString:expect]) {
        if (outSanitizedReason) {
            *outSanitizedReason = [NSString stringWithFormat:@"abi_mismatch enc_len=%lu", (unsigned long)enc.length];
        }
        @synchronized (LBHookSiteMap()) {
            NSString *key = LBHookSiteKey(declaringOwner, sel);
            LBHookSiteEntry *skip = LBHookSiteMap()[key];
            if (!skip) {
                skip = [LBHookSiteEntry new];
                skip.owner = declaringOwner;
                skip.selector = sel;
                skip.ownerName = NSStringFromClass(declaringOwner) ?: @"?";
                skip.typeEncoding = enc;
                LBHookSiteMap()[key] = skip;
            }
            skip.installState = LBHookSiteInstallStateSkipped;
        }
        return LBHookInstallResultSkippedABI;
    }

    IMP current = method_getImplementation(m);
    NSString *key = LBHookSiteKey(declaringOwner, sel);

    @synchronized (LBHookSiteMap()) {
        LBHookSiteEntry *existing = LBHookSiteMap()[key];
        if (existing && existing.installState == LBHookSiteInstallStateInstalled &&
            existing.replacementIMP && current == existing.replacementIMP) {
            return LBHookInstallResultAlreadyInstalled;
        }
        if (existing && existing.installState == LBHookSiteInstallStateInstalled &&
            existing.replacementIMP && current != existing.replacementIMP) {
            // 链被外部改写且无法安全重装
            if (outSanitizedReason) *outSanitizedReason = @"installed_but_current_diverged";
            return LBHookInstallResultFailClosed;
        }
    }

    NSString *fcReason = nil;
    if (LBHookSiteFailClosedForCurrent(current, &fcReason)) {
        if (outSanitizedReason) *outSanitizedReason = fcReason;
        @synchronized (LBHookSiteMap()) {
            LBHookSiteEntry *fc = LBHookSiteMap()[key] ?: [LBHookSiteEntry new];
            fc.owner = declaringOwner;
            fc.selector = sel;
            fc.ownerName = NSStringFromClass(declaringOwner) ?: @"?";
            fc.typeEncoding = enc;
            fc.installState = LBHookSiteInstallStateFailClosed;
            LBHookSiteMap()[key] = fc;
        }
        return LBHookInstallResultFailClosed;
    }

    // 捕获权威 previous：安装前 current；method_setImplementation 返回值须一致
    __block LBSetDicBookIMP capturedPrevious = (LBSetDicBookIMP)current;
    LBHookSiteEntry *entry = [LBHookSiteEntry new];
    entry.owner = declaringOwner;
    entry.selector = sel;
    entry.ownerName = NSStringFromClass(declaringOwner) ?: @"?";
    entry.typeEncoding = enc;
    entry.previousIMP = current;

    id block = ^void(id selfObj, id book) {
        if (!LBHookSiteEnter(entry)) {
            // 同 site re-entry：fatal marker 已记，直接停止，不再调 previous
            return;
        }
        @try {
            invokeFn(selfObj, sel, book, capturedPrevious);
        } @finally {
            LBHookSiteLeave(entry);
        }
    };
    // 进程生命周期持有 block
    entry.replacementBlockLifetime = [block copy];
    IMP replacement = imp_implementationWithBlock(entry.replacementBlockLifetime);
    entry.replacementIMP = replacement;

    IMP returnedPrev = method_setImplementation(m, replacement);
    if (returnedPrev != current) {
        // 断言失败：恢复并 fail-closed
        method_setImplementation(m, returnedPrev);
        // 不 imp_removeBlock（生命周期策略）；标记失败
        entry.installState = LBHookSiteInstallStateFailClosed;
        entry.replacementIMP = NULL;
        @synchronized (LBHookSiteMap()) {
            LBHookSiteMap()[key] = entry;
        }
        if (outSanitizedReason) *outSanitizedReason = @"setImplementation_prev_mismatch";
        return LBHookInstallResultFailClosed;
    }

    entry.installState = LBHookSiteInstallStateInstalled;
    @synchronized (LBHookSiteMap()) {
        LBHookSiteMap()[key] = entry;
    }
    return LBHookInstallResultInstalled;
}

NSUInteger LBHookSiteRegistryInstallSetDicBookCandidates(
    NSArray<NSString *> *candidateClassNames,
    NSString *expectedEncoding,
    LBSetDicBookInvokeFn invokeFn,
    NSMutableArray<NSString *> *installedLabels
) {
    NSUInteger installed = 0;
    NSMutableSet<NSString *> *seenOwners = [NSMutableSet set];
    for (NSString *cn in candidateClassNames) {
        Class cls = NSClassFromString(cn);
        if (!cls) continue;
        // 只 Hook 真正声明的 owner；继承不重复算
        if (!LBClassDeclaresInstanceMethod(cls, @selector(setDicBook:))) {
            continue;
        }
        NSString *ownerKey = [NSString stringWithFormat:@"%p", (void *)cls];
        if ([seenOwners containsObject:ownerKey]) continue;
        [seenOwners addObject:ownerKey];

        NSString *reason = nil;
        LBHookInstallResult r = LBHookSiteRegistryInstallSetDicBook(
            cls, expectedEncoding, invokeFn, &reason
        );
        NSString *label = [NSString stringWithFormat:@"setDicBook@%@ result=%ld %@",
                           NSStringFromClass(cls), (long)r, reason ?: @""];
        if (installedLabels) [installedLabels addObject:label];
        if (r == LBHookInstallResultInstalled || r == LBHookInstallResultAlreadyInstalled) {
            installed += 1;
        }
    }
    return installed;
}

NSUInteger LBHookSiteRegistryInstalledCount(void) {
    NSUInteger n = 0;
    @synchronized (LBHookSiteMap()) {
        for (LBHookSiteEntry *e in LBHookSiteMap().allValues) {
            if (e.installState == LBHookSiteInstallStateInstalled) n++;
        }
    }
    return n;
}

IMP LBHookSiteRegistryPreviousIMP(Class owner, SEL sel) {
    @synchronized (LBHookSiteMap()) {
        return LBHookSiteMap()[LBHookSiteKey(owner, sel)].previousIMP;
    }
}

IMP LBHookSiteRegistryReplacementIMP(Class owner, SEL sel) {
    @synchronized (LBHookSiteMap()) {
        return LBHookSiteMap()[LBHookSiteKey(owner, sel)].replacementIMP;
    }
}

LBHookSiteInstallState LBHookSiteRegistryState(Class owner, SEL sel) {
    @synchronized (LBHookSiteMap()) {
        LBHookSiteEntry *e = LBHookSiteMap()[LBHookSiteKey(owner, sel)];
        return e ? e.installState : LBHookSiteInstallStateNone;
    }
}

NSInteger LBHookSiteRegistryMaxDepthSeen(Class owner, SEL sel) {
    @synchronized (LBHookSiteMap()) {
        return LBHookSiteMap()[LBHookSiteKey(owner, sel)].maxDepthSeen;
    }
}

NSInteger LBHookSiteRegistryFatalReentryCount(Class owner, SEL sel) {
    @synchronized (LBHookSiteMap()) {
        return LBHookSiteMap()[LBHookSiteKey(owner, sel)].fatalReentryCount;
    }
}

void LBHookSiteRegistryResetForTests(void) {
    @synchronized (LBHookSiteMap()) {
        // 测试复位：不卸载生产 IMP（测例应使用 fixture 类）；仅清 registry 元数据
        [LBHookSiteMap() removeAllObjects];
    }
}
