#ifndef LBHookSiteRegistry_h
#define LBHookSiteRegistry_h

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

/// setDicBook: object-setter typed IMP（合同 ABI fixture：v24@0:8@16）。
typedef void (*LBSetDicBookIMP)(id, SEL, id);

/// 公共体：Legado enrichment / native·XBS 透传后恰好调用 captured previous 一次。
typedef void (*LBSetDicBookInvokeFn)(id self, SEL sel, id _Nullable book, LBSetDicBookIMP _Nullable previous);

/// 生产公共体（定义于 LBReadingHooks.m）。
FOUNDATION_EXPORT void LBSetDicBook_Invoke(id self, SEL sel, id _Nullable book, LBSetDicBookIMP _Nullable previous);

typedef NS_ENUM(NSInteger, LBHookInstallResult) {
    LBHookInstallResultInstalled = 0,
    LBHookInstallResultAlreadyInstalled = 1,
    LBHookInstallResultSkippedABI = 2,
    LBHookInstallResultFailClosed = 3,
    LBHookInstallResultNoMethod = 4,
    LBHookInstallResultNotDeclaringOwner = 5,
};

typedef NS_ENUM(NSInteger, LBHookSiteInstallState) {
    LBHookSiteInstallStateNone = 0,
    LBHookSiteInstallStateInstalled = 1,
    LBHookSiteInstallStateSkipped = 2,
    LBHookSiteInstallStateFailClosed = 3,
};

/// 合同证实的 object setter ABI（fixture；生产仍须 runtime 校验）。
FOUNDATION_EXPORT NSString * const LBSetDicBookExpectedEncodingABI;

/// 类是否在本类 method list 中声明该实例方法（不含继承）。
FOUNDATION_EXPORT BOOL LBClassDeclaresInstanceMethod(Class _Nullable cls, SEL sel);

/// 安装 per-owner setDicBook: site。key=(declaringOwner, @selector(setDicBook:))。
FOUNDATION_EXPORT LBHookInstallResult LBHookSiteRegistryInstallSetDicBook(
    Class declaringOwner,
    NSString *expectedEncoding,
    LBSetDicBookInvokeFn invokeFn,
    NSString * _Nullable * _Nullable outSanitizedReason
);

/// 对候选类名列表安装：仅声明 owner；幂等。
FOUNDATION_EXPORT NSUInteger LBHookSiteRegistryInstallSetDicBookCandidates(
    NSArray<NSString *> *candidateClassNames,
    NSString *expectedEncoding,
    LBSetDicBookInvokeFn invokeFn,
    NSMutableArray<NSString *> * _Nullable installedLabels
);

FOUNDATION_EXPORT NSUInteger LBHookSiteRegistryInstalledCount(void);
FOUNDATION_EXPORT IMP _Nullable LBHookSiteRegistryPreviousIMP(Class owner, SEL sel);
FOUNDATION_EXPORT IMP _Nullable LBHookSiteRegistryReplacementIMP(Class owner, SEL sel);
FOUNDATION_EXPORT LBHookSiteInstallState LBHookSiteRegistryState(Class owner, SEL sel);
FOUNDATION_EXPORT NSInteger LBHookSiteRegistryMaxDepthSeen(Class owner, SEL sel);
FOUNDATION_EXPORT NSInteger LBHookSiteRegistryFatalReentryCount(Class owner, SEL sel);
FOUNDATION_EXPORT BOOL LBHookSiteRegistryIsKnownReplacement(IMP imp);

/// 测试复位（仅测例；生产勿调用）。
FOUNDATION_EXPORT void LBHookSiteRegistryResetForTests(void);

NS_ASSUME_NONNULL_END

#endif /* LBHookSiteRegistry_h */
