#ifndef LBDebugPanel_h
#define LBDebugPanel_h

#import <Foundation/Foundation.h>

/// 真机调试面板（三指单击 / 单指三击 / legado://debugPanel）；+load 自动安装，不依赖 LegadoBridgeHooks。
@interface LBDebugPanel : NSObject
+ (void)lb_debugDumpAction;
@end

#endif /* LBDebugPanel_h */
