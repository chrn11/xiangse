#ifndef LBInternal_h
#define LBInternal_h

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdatomic.h>
#import "LBCapabilityRegistry.h"

NS_ASSUME_NONNULL_BEGIN

/// Core.shared 安全取用（防 dispatch_once 重入）
id _Nullable LBLegadoCoreIfReady(void);

NSArray *LBLegadoGetSourceNames(void);
BOOL LBLegadoIsSourceName(NSString * _Nullable name);
NSDictionary * _Nullable LBLegadoNativeModel(NSString *name);
NSArray *LBMergeLegadoNames(NSArray * _Nullable orig);

UIWindow * _Nullable LBLegadoKeyWindow(void);
void LBLegadoShowResult(NSString *msg);
void LBLegadoPresentManagerVC(NSString * _Nullable focusSourceUrl);
void LBLegadoShowImportAlert(void);
void LBLegadoImportData(NSData *data);
void LBLegadoFetchAndImport(NSURL *url);

/// 向上查找真正实现该实例方法的类
Class _Nullable LBClassOwningInstanceMethod(Class _Nullable cls, SEL sel);

/// 类型编码校验：expectedHint 非空时要求 actual 包含该子串；失败写 reason，返回 NO（调用方应 fail-open 跳过）
BOOL LBValidateInstanceMethod(Class _Nullable cls,
                              SEL sel,
                              const char * _Nullable expectedHint,
                              NSString * _Nullable * _Nullable outActualEnc,
                              NSString * _Nullable * _Nullable outReason);

BOOL LBValidateClassMethod(Class _Nullable cls,
                           SEL sel,
                           const char * _Nullable expectedHint,
                           NSString * _Nullable * _Nullable outActualEnc,
                           NSString * _Nullable * _Nullable outReason);

/// 安装 IMP：先校验，失败则跳过且不抛
BOOL LBInstallInstanceHook(Class _Nullable cls,
                           SEL sel,
                           const char * _Nullable expectedHint,
                           IMP newIMP,
                           IMP _Nullable * _Nullable outOrigIMP,
                           NSString *hookLabel);

void LBInstallImportHooks(void);
void LBInstallOpenURLHook(void);
void LBInstallSearchHooks(void);
void LBInstallSourceListHooks(void);
void LBInstallReadingHooks(void);
void LBInstallRuntimeValidateHooks(void);
/// Legado 阅读护栏：消毒 dicBook/站点后走原生 openReader；点章失败再 Bridge
void LBInstallLegadoReaderKillSwitch(void);

/// 阅读会话内存映射 + BookBindingStore 持久化（经 Core.rememberBookBinding）
void LBReadingRememberBook(NSDictionary * _Nullable dicBook);
NSString * _Nullable LBReadingSourceUrlForBookUrl(NSString * _Nullable bookUrl);
BOOL LBReadingDicLooksLegado(NSDictionary * _Nullable dic);
NSString * _Nullable LBReadingBookUrlFromDic(NSDictionary * _Nullable dic);
NSString * _Nullable LBReadingSourceUrlFromDic(NSDictionary * _Nullable dic);
NSDictionary * _Nullable LBReadingDicFromObject(id _Nullable object);

NS_ASSUME_NONNULL_END

#endif /* LBInternal_h */
