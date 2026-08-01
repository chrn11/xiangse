#ifndef LegadoBridge_h
#define LegadoBridge_h

#import <Foundation/Foundation.h>
#import "LBCapabilityRegistry.h"

FOUNDATION_EXPORT void LBInstallHooks(void);

FOUNDATION_EXPORT BOOL LBIsLegadoJSONData(NSData *data);
FOUNDATION_EXPORT NSInteger LBImportLegadoJSONData(NSData *data, NSError **error);
FOUNDATION_EXPORT void LBHandleSearchRequest(NSString *keyword, NSString *sourceUrl);
/// 验收/深链入口：优先 startSearch（建立原生搜索会话），失败再直调引擎
FOUNDATION_EXPORT void LBTriggerMixedSearch(NSString *keyword, NSString *sourceUrl);
/// 把引擎搜索结果灌入 BookSearchController.arrBaseData 并 reload（通知 alone 不会填列表）
FOUNDATION_EXPORT void LBApplySearchResultsToUI(NSArray *books, NSString * _Nullable keyword);
/// 发现页换分类/换源前清空已灌书单（避免旧结果残留）
FOUNDATION_EXPORT void LBClearDiscoverExploreBooks(void);
/// 只清 Legado explore 的 pending/lastApplied，不动发现宿主原生列表（切 XBS 时用）
FOUNDATION_EXPORT void LBClearDiscoverExplorePendingOnly(void);
/// 发现页当前是否处于「用户切到纯 XBS」态（此时禁止再灌 Legado explore）
FOUNDATION_EXPORT BOOL LBIsDiscoverNativeXBSMode(void);
FOUNDATION_EXPORT void LBSetDiscoverNativeXBSMode(BOOL on);
/// 按当前发现宿主源名判断是否应走纯原生发现（找不到 Legado explore 名 → YES）
FOUNDATION_EXPORT BOOL LBDiscoverShouldUseNativeXBS(void);
/// 进入发现 Tab / 刷新前同步 XBS↔Legado；返回 YES 表示当前为纯原生发现（最小干预）
FOUNDATION_EXPORT BOOL LBDiscoverSyncModeForCurrentSource(void);
/// 在原生发现壳上刷新 SGPageTitleView 分类（禁止 Bridge overlay 标签栏）
FOUNDATION_EXPORT void LBRefreshDiscoverKindBar(void);
/// 书源管理「发现」：真正切到指定源的发现态（禁止 Alert 冒充）
FOUNDATION_EXPORT void LBSwitchDiscoverToSourceName(NSString * _Nullable sourceName);
/// 把目录章节灌入可见 CatalogCon/详情/阅读页的 arrCatalog 并 reload
FOUNDATION_EXPORT void LBApplyCatalogToUI(NSArray *chapters, NSString * _Nullable bookUrl);
/// 安装搜索页 viewDidAppear 冲刷 pending（LBInstallSearchHooks 内也会调用）
FOUNDATION_EXPORT void LBInstallSearchUIAppearFlush(void);
/// 安装目录页 viewDidAppear 冲刷 pending（详情时引擎先返回，CatalogCon 后出现）
FOUNDATION_EXPORT void LBInstallCatalogUIAppearFlush(void);
FOUNDATION_EXPORT void LBHandleCatalogRequest(NSString *bookUrl, NSString *sourceUrl);
FOUNDATION_EXPORT void LBHandleContentRequest(NSString *chapterUrl, NSString *bookUrl, NSString *sourceUrl);
/// 验收深链：拉目录后按 idx 走原生 openReader（失败再 Bridge）
FOUNDATION_EXPORT void LBOpenNativeChapterAtIndex(NSString *bookUrl, NSString * _Nullable sourceUrl, NSInteger idx);
/// 正文通知已发出：缓存载荷，阅读页 viewDidAppear 时再投一次（避免 ReadVC 尚未监听）
FOUNDATION_EXPORT void LBNoteResetContentPosted(NSDictionary * _Nullable userInfo);
/// 安装 TextRead/ReadVC appear 冲刷 pending 正文
FOUNDATION_EXPORT void LBInstallReaderContentAppearFlush(void);
/// 点章兜底：present Bridge UITextView（仅原生 TextReadVC 未出现时）
FOUNDATION_EXPORT BOOL LBPresentBridgeReader(NSString * _Nullable title,
                                             NSString *chapterUrl,
                                             NSString *bookUrl,
                                             NSString * _Nullable * _Nullable outMsg);
/// 把 ResetContent 载荷灌入可见的 Bridge 阅读页
FOUNDATION_EXPORT void LBBridgeReaderApplyContent(NSDictionary * _Nullable userInfo);
/// Bridge 阅读页 appear 时重灌 pending 正文（正文常早于 VC 可见）
FOUNDATION_EXPORT void LBBridgeReaderApplyPendingOnAppear(void);

FOUNDATION_EXPORT NSString *LBBridgeVersion(void);

/// 弹出 Legado 书源导入 alert（URL / 粘贴 JSON）；仅用户主动触发，不再启动强弹
FOUNDATION_EXPORT void LBShowLegadoImportAlert(void);

/// 打开 Legado 书源管理页；sourceUrl 非空时自动进入该源编辑器
FOUNDATION_EXPORT void LBPresentLegadoSourceManager(NSString * _Nullable sourceUrl);
/// B6：打开净化规则管理页
FOUNDATION_EXPORT void LBPresentLegadoReplaceRulesManager(void);

/// 书源 JS：java.startBrowserAwait — 可见网页等待（香色 WebView）
FOUNDATION_EXPORT NSString * _Nullable LBStartBrowserAwait(NSString *urlStr,
                                                           NSString * _Nullable sourceUrl,
                                                           NSString * _Nullable title,
                                                           NSTimeInterval timeoutSec);

/// 封面 URL 解密（coverDecodeJs）
FOUNDATION_EXPORT NSString * _Nullable LBDecodeCoverURL(NSString *url, NSString * _Nullable sourceUrl);
/// 展示书评列表（JSON 数组字符串）
FOUNDATION_EXPORT void LBPresentBookReviewsJSON(NSString *bookUrl, NSString *json);
/// 打开听书播控（直链章节 URL）
FOUNDATION_EXPORT void LBOpenTTS(NSString *bookUrl, NSString *chapterUrl, NSString * _Nullable chapterTitle);

#endif /* LegadoBridge_h */
