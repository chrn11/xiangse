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

/// 重置状态机（换章 / 失败 fail-open）
void LBLoadCurCpBridgeReset(NSString * _Nullable reason);

/// 诊断：当前状态名
NSString *LBLoadCurCpBridgeStateName(void);

/// 假设 F：invoke_orig_OK 后同步补 division 链（禁 dispatch_after）
void LBLoadCurCpBridgeKickDivisionChain(id _Nullable readerVC,
                                        id _Nullable container,
                                        NSDictionary * _Nullable payload);

NS_ASSUME_NONNULL_END

#endif /* LBLoadCurCpBridge_h */
