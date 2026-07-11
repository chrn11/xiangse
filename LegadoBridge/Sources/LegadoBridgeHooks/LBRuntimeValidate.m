#import "LBInternal.h"
#import "LegadoBridge.h"
#include <string.h>

/// 运行时校验 + hook103 候选探针（仅诊断开关开启时安装行为探针；生产默认只校验并落盘编码）

typedef struct {
    const char *className;
    const char *selectorName;
    const char *expectedHint; // 子串；NULL=只要求存在
    BOOL isClassMethod;
    BOOL productAdopted; // 生产是否采用（否=仅诊断）
} LBProbeSpec;

static const LBProbeSpec kLBProbes[] = {
    { "BookDetailController", "setDicBook:", "@16", NO, YES },
    { "BookDetailScrollView", "resetPosition", "v16", NO, NO },
    { "BookDetailScrollView", "initWithFrame:", NULL, NO, NO },
    { "BookShelfListCell", "reset:updating:lastTimeStamp:", NULL, NO, NO },
    { "BookSourceModelManager", "save", NULL, NO, NO },
    { "LCJSTool", "dataByAesDecryptWithBase64String:withKey:withIv:", NULL, NO, NO },
    { "LCJSTool", "deviceIdWithTemplate:withSeparator:", NULL, NO, NO },
    { "LCJSTool", "unzipFile:", NULL, NO, NO },
    { "TFHpple", "initWithHTMLData:", NULL, NO, NO },
    { "TFHpple", "initWithData:encoding:isXML:", NULL, NO, NO },
    { "SDWebImageDownloaderOperation", "URLSession:dataTask:willCacheResponse:completionHandler:", NULL, NO, NO },
};

static void LBDiagAppend(NSString *line) {
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_probe_validate.txt"];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    NSString *full = [line stringByAppendingString:@"\n"];
    if (!fh) {
        [full writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return;
    }
    [fh seekToEndOfFile];
    [fh writeData:[full dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

/// 诊断探针：只记录脱敏调用信息，不改业务语义（调用原 IMP）
static void LBInstallDiagPassthrough(Class cls, SEL sel, NSString *label) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    IMP orig = method_getImplementation(m);
    const char *types = method_getTypeEncoding(m) ?: "v@:";
    // 统一用 objc_msgSend 风格：包装一层日志再调原 IMP（仅支持常见 void 返回）
    IMP hook = imp_implementationWithBlock(^void(id self, ...) {
        LBDiagAppend([NSString stringWithFormat:@"HIT %@ cls=%@ thread=%@",
                      label,
                      NSStringFromClass([self class]),
                      NSThread.isMainThread ? @"main" : @"bg"]);
        // 无法安全转发可变参数；改为直接调 orig 仅当无额外参数时正确。
        // 对多参数方法改用 method_invoke 不安全，故仅对无额外参数方法安装 block 包装。
        ((void (*)(id, SEL))orig)(self, sel);
    });
    // 仅当类型编码显示无额外参数（典型 v16@0:8）时替换
    if (types[0] == 'v' && strstr(types, "@16") == NULL) {
        method_setImplementation(m, hook);
        LBDiagAppend([NSString stringWithFormat:@"diag-hooked %@", label]);
    } else {
        LBDiagAppend([NSString stringWithFormat:@"diag-skip-wrap %@ enc=%s (多参仅记录存在性)", label, types]);
        (void)orig;
    }
}

void LBInstallRuntimeValidateHooks(void) {
    @try {
        NSMutableArray *ok = [NSMutableArray array];
        NSMutableArray *miss = [NSMutableArray array];
        BOOL diag = LBDiagProbesEnabled();
        LBDiagAppend([NSString stringWithFormat:@"=== validate diag=%d ===", (int)diag]);

        size_t n = sizeof(kLBProbes) / sizeof(kLBProbes[0]);
        for (size_t i = 0; i < n; i++) {
            LBProbeSpec spec = kLBProbes[i];
            Class cls = NSClassFromString(@(spec.className));
            SEL sel = sel_registerName(spec.selectorName);
            NSString *enc = nil;
            NSString *reason = nil;
            BOOL valid = NO;
            if (spec.isClassMethod) {
                valid = LBValidateClassMethod(cls, sel, spec.expectedHint, &enc, &reason);
            } else {
                valid = LBValidateInstanceMethod(cls, sel, spec.expectedHint, &enc, &reason);
            }
            NSString *line = [NSString stringWithFormat:@"%@ %@ => %@ enc=%@ %@",
                              @(spec.className),
                              @(spec.selectorName),
                              valid ? @"OK" : @"FAIL",
                              enc ?: @"-",
                              reason ?: @""];
            LBDiagAppend(line);
            if (valid) {
                [ok addObject:[NSString stringWithFormat:@"%@.%@", @(spec.className), @(spec.selectorName)]];
                if (diag && !spec.productAdopted && !spec.isClassMethod) {
                    LBInstallDiagPassthrough(cls, sel,
                        [NSString stringWithFormat:@"%@.%@", @(spec.className), @(spec.selectorName)]);
                }
            } else {
                [miss addObject:[NSString stringWithFormat:@"%@.%@", @(spec.className), @(spec.selectorName)]];
            }
        }

        // 运行时校验组：只要核心生产锚点 setDicBook 或至少一个候选存在即 enabled；否则 skipped（fail-open）
        BOOL hasSetDic = NO;
        for (NSString *s in ok) {
            if ([s containsString:@"setDicBook:"]) { hasSetDic = YES; break; }
        }
        if (ok.count == 0) {
            LBCapabilityMarkSkipped(LBHookGroupRuntimeValidate, @"no probe targets on baseline");
        } else {
            LBCapabilityMarkEnabled(
                LBHookGroupRuntimeValidate,
                [NSString stringWithFormat:@"ok=%lu miss=%lu setDicBook=%d diag=%d",
                 (unsigned long)ok.count, (unsigned long)miss.count, (int)hasSetDic, (int)diag]
            );
        }
    } @catch (NSException *e) {
        LBCapabilityMarkFailed(LBHookGroupRuntimeValidate, e.reason ?: @"exception");
        NSLog(@"[LegadoBridge] runtime validate exception: %@", e);
    }
}
