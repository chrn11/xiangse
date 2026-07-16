#ifndef LBDebugPanel_h
#define LBDebugPanel_h

#import <Foundation/Foundation.h>

/// 真机调试面板（三指单击 / 单指三击 / legado://debugPanel）；+load 自动安装，不依赖 LegadoBridgeHooks。
@interface LBDebugPanel : NSObject
+ (void)lb_debugDumpAction;
/// 同步 dump，返回 Documents 内 JSON 绝对路径（供 MCP objc_invoke）
+ (NSString *)lb_debugDumpSyncWithPhase:(NSString *)phase;
@end

/// C 入口：同步 dump，phase 可为 NULL；返回 json 路径（调用方勿 free，线程内静态缓冲仅调试用）
FOUNDATION_EXPORT const char *LBDebugForceDump(const char *phase);

#endif /* LBDebugPanel_h */
