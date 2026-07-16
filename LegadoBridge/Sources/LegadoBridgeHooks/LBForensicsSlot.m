#import <objc/runtime.h>

/// 由 LegadoBridgeDebug 在 +load/constructor 赋值；生产 Bridge 经此槽读取真原版 IMP
IMP (*LBForensicsResolveOrigIMPPtr)(Class, SEL) = NULL;
