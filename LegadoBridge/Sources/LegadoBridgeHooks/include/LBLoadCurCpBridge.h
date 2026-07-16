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

/// 注册原版 loadCurCp IMP（由 LBReadingHooks 安装时调用）
void LBLoadCurCpBridgeRegisterOrig(void (*orig)(id, SEL));

/// Legado loadCurCp hook 入口；返回 YES 表示已处理（勿再调原版）
BOOL LBLoadCurCpBridgeHandleHook(id self, SEL _cmd,
                                 BOOL isLegado,
                                 NSString * _Nullable bookUrl,
                                 NSString * _Nullable sourceUrl,
                                 NSString * _Nullable chapterUrl);

/// 正文载荷到达（LBNoteResetContentPosted 接线）
void LBLoadCurCpBridgeOnContentPosted(NSDictionary *payload, id _Nullable readerVC);

/// 阅读页激活（setDicBook 后）：若有 pending 正文则 contentReady→invoke，否则启动 fetch
void LBLoadCurCpBridgeReaderActivated(id reader);

/// 原生绘制证据置位（forensics / 验收探针）
void LBLoadCurCpBridgeMarkRendered(void);

/// 重置状态机（换章 / 失败 fail-open）
void LBLoadCurCpBridgeReset(NSString * _Nullable reason);

/// 诊断：当前状态名
NSString *LBLoadCurCpBridgeStateName(void);

NS_ASSUME_NONNULL_END

#endif /* LBLoadCurCpBridge_h */
