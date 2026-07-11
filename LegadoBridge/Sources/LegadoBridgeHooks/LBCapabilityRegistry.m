#import "LBCapabilityRegistry.h"
#include <string.h>
#include <stdlib.h>

static NSString *LBStatusNames[] = {
    @"pending", @"enabled", @"skipped", @"failed"
};

static LBHookGroupStatus gStatus[LBHookGroupCount];
static NSString *gDetail[LBHookGroupCount];
static dispatch_queue_t LBCapQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.xiangse.legado.capability", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

NSString *LBHookGroupName(LBHookGroup group) {
    switch (group) {
        case LBHookGroupRuntimeValidate: return @"runtime-validate";
        case LBHookGroupImport: return @"import";
        case LBHookGroupSearch: return @"search";
        case LBHookGroupSourceList: return @"source-list";
        case LBHookGroupReading: return @"reading";
        default: return @"unknown";
    }
}

void LBCapabilityResetAll(void) {
    dispatch_sync(LBCapQueue(), ^{
        for (NSInteger i = 0; i < LBHookGroupCount; i++) {
            gStatus[i] = LBHookGroupStatusPending;
            gDetail[i] = nil;
        }
    });
}

static void LBCapabilitySet(LBHookGroup group, LBHookGroupStatus status, NSString *detail) {
    if (group < 0 || group >= LBHookGroupCount) return;
    dispatch_sync(LBCapQueue(), ^{
        gStatus[group] = status;
        gDetail[group] = [detail copy];
    });
}

void LBCapabilityMarkEnabled(LBHookGroup group, NSString *detail) {
    LBCapabilitySet(group, LBHookGroupStatusEnabled, detail ?: @"ok");
}

void LBCapabilityMarkSkipped(LBHookGroup group, NSString *reason) {
    LBCapabilitySet(group, LBHookGroupStatusSkipped, reason ?: @"skipped");
}

void LBCapabilityMarkFailed(LBHookGroup group, NSString *reason) {
    LBCapabilitySet(group, LBHookGroupStatusFailed, reason ?: @"failed");
}

LBHookGroupStatus LBCapabilityStatus(LBHookGroup group) {
    __block LBHookGroupStatus s = LBHookGroupStatusPending;
    if (group < 0 || group >= LBHookGroupCount) return s;
    dispatch_sync(LBCapQueue(), ^{ s = gStatus[group]; });
    return s;
}

BOOL LBCapabilityIsEnabled(LBHookGroup group) {
    return LBCapabilityStatus(group) == LBHookGroupStatusEnabled;
}

NSArray<NSDictionary *> *LBHookCapabilityStatuses(void) {
    __block NSMutableArray *arr = [NSMutableArray array];
    dispatch_sync(LBCapQueue(), ^{
        for (NSInteger i = 0; i < LBHookGroupCount; i++) {
            LBHookGroupStatus st = gStatus[i];
            NSString *statusName = (st >= 0 && st <= LBHookGroupStatusFailed)
                ? LBStatusNames[st] : @"pending";
            [arr addObject:@{
                @"name": LBHookGroupName((LBHookGroup)i),
                @"status": statusName,
                @"detail": gDetail[i] ?: @""
            }];
        }
    });
    return arr;
}

BOOL LBDiagProbesEnabled(void) {
    static dispatch_once_t once;
    static BOOL enabled;
    dispatch_once(&once, ^{
        if ([[NSUserDefaults standardUserDefaults] boolForKey:@"LegadoBridgeDiagProbes"]) {
            enabled = YES;
            return;
        }
        const char *env = getenv("LEGADO_DIAG_PROBES");
        enabled = (env && env[0] != '\0' && strcmp(env, "0") != 0);
    });
    return enabled;
}

void LBCapabilityPersistMarker(void) {
    NSArray *statuses = LBHookCapabilityStatuses();
    NSMutableArray *lines = [NSMutableArray array];
    for (NSDictionary *d in statuses) {
        [lines addObject:[NSString stringWithFormat:@"%@=%@ (%@)",
                          d[@"name"], d[@"status"], d[@"detail"]]];
    }
    NSString *body = [lines componentsJoinedByString:@"\n"];
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_hook_capabilities.txt"];
    [body writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}
