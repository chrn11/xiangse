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
/// B6：打开净化规则管理页（列表/启停/导入/分组）
void LBPresentLegadoReplaceRulesManager(void);
/// U2：仅推编辑页到当前导航栈（返回落回原版站点列表）；不经过书源管理列表页
void LBLegadoPresentSourceEditor(NSString * _Nullable sourceUrl);
/// U3：优先推原版 ConfigSourceModelSyncCon；失败返回 NO（调用方再回退 UIAlert）
BOOL LBLegadoPresentNativeImport(void);
/// 从指定 VC 的 navigationController push 导入页（避免全局可见 nav 指错栈）
BOOL LBLegadoPresentNativeImportFrom(UIViewController * _Nullable fromVC);
/// E-02/E-03：用户倒序/过滤后同步 pending，避免 UI 仍画引擎原始顺序
void LBSyncPendingCatalogChapters(NSArray * _Nullable chapters);
/// 当前 pending 目录快照（可能为空）；供倒序/过滤与 cell 同源读取
NSArray * _Nullable LBCopyPendingCatalogChapters(void);
void LBSetCatalogUserOrderLocked(BOOL locked);
BOOL LBCatalogUserOrderLocked(void);
void LBLegadoShowImportAlert(void);
void LBLegadoImportData(NSData *data);
void LBLegadoFetchAndImport(NSURL *url);

/// 导入/启停后：清 dicModelList 合并缓存，并刷新可见的站点/书源列表 UI
void LBInvalidateSourceListMergeCache(void);
void LBRefreshVisibleSourceListUIs(void);
void LBPostSourceListRefresh(void);

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
void LBInstallDiscoverTabHooks(void);
void LBInstallRuntimeValidateHooks(void);
/// 顶栏「发现」是否处于激活（setSquare / segment）
BOOL LBIsDiscoverTabActive(void);
void LBSetDiscoverTabActive(BOOL active);
/// 用户从书架/顶栏主动打开搜索（C-01：避免发现 sticky 抢路由）
void LBSetBookSearchUserIntent(BOOL active);
BOOL LBIsBookSearchUserIntent(void);
NSArray *LBFindDiscoverHostVCs(void);
/// 推出/复用原生广场壳（BookWorld/Store）；禁止 push BookSearch 冒充发现
BOOL LBEnsureNativeDiscoverHostPresented(void);
/// 清除发现页 Bridge overlay 子视图（tag LBKB/LBPV）
void LBRemoveDiscoverOverlays(UIViewController *host);
/// 按当前发现宿主源名判断是否应走纯原生发现（找不到 Legado explore 名 → YES）
BOOL LBDiscoverShouldUseNativeXBS(void);
/// 进入发现 Tab / 刷新前同步 XBS↔Legado；返回 YES 表示当前为纯原生发现（最小干预）
BOOL LBDiscoverSyncModeForCurrentSource(void);
/// 当前选中的 BookListCon 子页
UIViewController * _Nullable LBActiveDiscoverListVC(UIViewController *host);
/// 书列表灌入后刷新原生子页
void LBReloadDiscoverNativeList(UIViewController *host);
/// 发现列表 VC 无表时：在子页内建 LBLT（非全屏 LBDT 脏表），并挂安全 DS hooks
UITableView * _Nullable LBEnsureDiscoverListSurface(UIViewController *host);
/// 分类条透明 hit 置顶（叠表 bringToFront 后必须再调）
void LBBringDiscoverKindHitFront(UIViewController * _Nullable host);
/// 给 BookListCon / 列表 VC 挂 numberOfRows / cellForRow 兜底
void LBEnsurePlazaListTableHooks(Class cls);
void LBPinDiscoverContentToFirstPage(UIViewController *host);
void LBInstallDiscoverNativeUIHooks(void);
/// T4：按源名切换发现页当前源（Legado explore / 原生 XBS），并尽量落到发现宿主
void LBSwitchDiscoverToSourceName(NSString * _Nullable sourceName);
/// Legado 阅读护栏：消毒 dicBook/站点后走原生 openReader；点章失败再 Bridge
void LBInstallLegadoReaderKillSwitch(void);

/// 可见 WebView：优先 LCStandarConfig openWebViewWithUrlStr:（内部 show WebViewController_WK），否则 WK 回退
void LBPresentVisibleWebView(NSString *urlStr, NSString * _Nullable sourceUrl, NSString * _Nullable modeTag);
void LBPresentLoginWebViewForSource(NSString * _Nullable sourceUrl);
/// 真 loginUi 原生表单（字段 + 按钮执行 loginUrl JS）
void LBPresentLoginUiFormForSource(NSString * _Nullable sourceUrl);
/// 打开可见网页并阻塞等待用户点「完成验证」；返回页面 HTML（可空）。timeoutSec<=0 默认 180。
NSString * _Nullable LBStartBrowserAwait(NSString *urlStr,
                                         NSString * _Nullable sourceUrl,
                                         NSString * _Nullable title,
                                         NSTimeInterval timeoutSec);
/// 页内深链 / 外部完成信号：解除当前 startBrowserAwait 等待。
void LBBrowserAwaitSignalUserDone(NSString * _Nullable reason);

/// 阅读会话内存映射 + BookBindingStore 持久化（经 Core.rememberBookBinding）
void LBReadingRememberBook(NSDictionary * _Nullable dicBook);
NSString * _Nullable LBReadingSourceUrlForBookUrl(NSString * _Nullable bookUrl);
BOOL LBReadingDicLooksLegado(NSDictionary * _Nullable dic);
NSString * _Nullable LBReadingBookUrlFromDic(NSDictionary * _Nullable dic);
NSString * _Nullable LBReadingSourceUrlFromDic(NSDictionary * _Nullable dic);
NSDictionary * _Nullable LBReadingDicFromObject(id _Nullable object);

/// Wave0：书评列表 / 封面解密 C 桥
void LBPresentBookReviewsJSON(NSString *bookUrl, NSString *json);
NSString * _Nullable LBDecodeCoverURL(NSString *url, NSString * _Nullable sourceUrl);
void LBPresentAudioPlayer(NSString *bookUrl, NSString *chapterUrl, NSString * _Nullable chapterTitle);

NS_ASSUME_NONNULL_END

#endif /* LBInternal_h */
