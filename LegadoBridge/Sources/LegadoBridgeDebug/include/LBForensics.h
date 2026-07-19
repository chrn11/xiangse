#ifndef LBForensics_h
#define LBForensics_h

#import <Foundation/Foundation.h>

/// Forensics dump schema_version（与 reader-build-manifest 无关）
FOUNDATION_EXPORT const NSInteger LBForensicsDumpSchemaVersion;

/// 候选 reader 类名（逐类独立 dump，不假定单一 readerHost）
FOUNDATION_EXPORT NSArray<NSString *> *LBForensicsCandidateClassNames(void);

/// 执行完整 forensics dump；phase 可为 nil（默认 manual）
FOUNDATION_EXPORT NSDictionary *LBForensicsPerformDump(NSString *phase);

/// 将 dump 写入 Documents，返回 @{@"json":path, @"text":path, @"legacy":path}
FOUNDATION_EXPORT NSDictionary<NSString *, NSString *> *LBForensicsWriteDumpFiles(NSDictionary *dump);

/// 尽早安装 viewDidLoad/loadCurCp IMP 包装（+load/constructor 调用）
FOUNDATION_EXPORT void LBForensicsInstallEarlyWrap(void);

/// 返回 early-wrap 安装前捕获的真原版 IMP（供生产 shell hook 解环）
FOUNDATION_EXPORT IMP LBForensicsResolveOrigIMP(Class cls, SEL sel);

/// 返回 forensics EarlyWrap 钩子 IMP（供 Bridge 解包识别）
FOUNDATION_EXPORT IMP LBForensicsEarlyWrapIMPForSelectorName(NSString *selName);

/// 返回 observer 挂钩时保存的 orig IMP（owner 类链上 method owner）
FOUNDATION_EXPORT IMP LBForensicsResolveObserverOrigIMP(Class cls, SEL sel);

/// 返回 forensics observer 短桩 IMP（供 Bridge 解包识别）
FOUNDATION_EXPORT IMP LBForensicsHookIMPForSelectorName(NSString *selName);

/// 安装只读 lifecycle observer（+load 调用一次）
FOUNDATION_EXPORT void LBForensicsInstallObservers(void);

/// 设置远程 dump phase（legado://debugDump?phase=）
FOUNDATION_EXPORT void LBForensicsSetPendingDumpPhase(NSString *phase);

/// 取 pending phase 并清空
FOUNDATION_EXPORT NSString *LBForensicsConsumePendingDumpPhase(void);

/// AO：Hooks 经 dlsym 标记 QF/postQF 窗（供 LBFHook 命中/重入统计）
FOUNDATION_EXPORT void LBForensicsSetQFWindow(int inQF, int postQF);

/// AO：临时降噪——quiet≠0 时 LBFRecordEvent 跳过写事件（仅真机证 pid 稳后才开）
FOUNDATION_EXPORT void LBForensicsSetRecordQuiet(int quiet);

/// AO：落盘/探针输出 LBFHook 命中与重入摘要
FOUNDATION_EXPORT void LBForensicsEmitHookStats(const char *why);

#endif /* LBForensics_h */
