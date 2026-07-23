#ifndef LBLoadCurCpBridge_h
#define LBLoadCurCpBridge_h

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

/// loadCurCp 生命周期状态机（Legado 窄路径）
typedef NS_ENUM(NSInteger, LBLoadCurCpState) {
    LBLoadCurCpStateIdle = 0,
    LBLoadCurCpStateFetching,
    LBLoadCurCpStateContentReady,
    LBLoadCurCpStateInvokingOriginal,
    LBLoadCurCpStateRendered,
    LBLoadCurCpStateFailed,
};

/// 注册原版 loadCurCp IMP（由 LBReadingHooks 安装时调用；unwrap 后的真 native）
void LBLoadCurCpBridgeRegisterOrig(void (*orig)(id, SEL));

/// 注册原版 ReadScrollContainer#loadCp:（滚动模式 invoke 用）
void LBLoadCurCpBridgeRegisterLoadCpOrig(id (*orig)(id, SEL, long long));

/// Hook 内是否应直通已保存的真 native（invoke 重入 / EarlyWrap 链）
BOOL LBLoadCurCpBridgePassThroughToNative(void);

/// Legado loadCurCp hook 入口；返回 YES 表示已处理（勿再调原版）
BOOL LBLoadCurCpBridgeHandleHook(id self, SEL _cmd,
                                 BOOL isLegado,
                                 NSString * _Nullable bookUrl,
                                 NSString * _Nullable sourceUrl,
                                 NSString * _Nullable chapterUrl);

/// 正文载荷到达（LBNoteResetContentPosted 接线）
void LBLoadCurCpBridgeOnContentPosted(NSDictionary *payload, id _Nullable readerVC);

/// 原生绘制证据置位（forensics / 验收探针）
void LBLoadCurCpBridgeMarkRendered(void);

/// 8.5：从当前阅读页快照 nCpIndex/nPageIndex 落盘（杀进程前由 dump/resign 调用）
void LBLoadCurCpBridgePersistPageProgress(void);

/// 重置状态机（换章 / 失败 fail-open）
void LBLoadCurCpBridgeReset(NSString * _Nullable reason);

/// 诊断：当前状态名
NSString *LBLoadCurCpBridgeStateName(void);

/// invoke_orig_OK 同栈同步补 division 链（divisionText → divisionResponse → onDivisionTextFinish）
void LBLoadCurCpBridgeKickDivisionSync(id container, id readerVC, NSDictionary *payload);

/// 假设 F：缓存已发现的原生 container（禁 getter/alloc；供 FindContainer / schedule invoke）
void LBLoadCurCpBridgeCacheContainer(id readerVC, id container);

NS_ASSUME_NONNULL_END

#endif /* LBLoadCurCpBridge_h */
