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

/// 安装只读 lifecycle observer（+load 调用一次）
FOUNDATION_EXPORT void LBForensicsInstallObservers(void);

/// 设置远程 dump phase（legado://debugDump?phase=）
FOUNDATION_EXPORT void LBForensicsSetPendingDumpPhase(NSString *phase);

/// 取 pending phase 并清空
FOUNDATION_EXPORT NSString *LBForensicsConsumePendingDumpPhase(void);

#endif /* LBForensics_h */
