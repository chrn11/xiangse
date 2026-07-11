#ifndef LBCapabilityRegistry_h
#define LBCapabilityRegistry_h

#import <Foundation/Foundation.h>

/// Hook 能力分组（与 LBInstall* 一一对应）
typedef NS_ENUM(NSInteger, LBHookGroup) {
    LBHookGroupRuntimeValidate = 0,
    LBHookGroupImport,
    LBHookGroupSearch,
    LBHookGroupSourceList,
    LBHookGroupReading,
    LBHookGroupCount
};

typedef NS_ENUM(NSInteger, LBHookGroupStatus) {
    LBHookGroupStatusPending = 0,
    LBHookGroupStatusEnabled,
    LBHookGroupStatusSkipped, // 类/方法缺失或类型编码不匹配 → 降级跳过
    LBHookGroupStatusFailed   // 安装期异常 → 降级，禁止拖垮进程
};

FOUNDATION_EXPORT NSString *LBHookGroupName(LBHookGroup group);

FOUNDATION_EXPORT void LBCapabilityResetAll(void);
FOUNDATION_EXPORT void LBCapabilityMarkEnabled(LBHookGroup group, NSString * _Nullable detail);
FOUNDATION_EXPORT void LBCapabilityMarkSkipped(LBHookGroup group, NSString * _Nullable reason);
FOUNDATION_EXPORT void LBCapabilityMarkFailed(LBHookGroup group, NSString * _Nullable reason);

FOUNDATION_EXPORT LBHookGroupStatus LBCapabilityStatus(LBHookGroup group);
FOUNDATION_EXPORT BOOL LBCapabilityIsEnabled(LBHookGroup group);

/// 管理页展示用：@[@{@"name", @"status", @"detail"}]
FOUNDATION_EXPORT NSArray<NSDictionary *> *LBHookCapabilityStatuses(void);

/// 诊断探针开关：NSUserDefaults `LegadoBridgeDiagProbes` 或环境变量 LEGADO_DIAG_PROBES
FOUNDATION_EXPORT BOOL LBDiagProbesEnabled(void);

/// 将能力状态写入 Documents，便于真机取证
FOUNDATION_EXPORT void LBCapabilityPersistMarker(void);

#endif /* LBCapabilityRegistry_h */
