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
/// 把目录章节灌入可见 CatalogCon/详情/阅读页的 arrCatalog 并 reload
FOUNDATION_EXPORT void LBApplyCatalogToUI(NSArray *chapters, NSString * _Nullable bookUrl);
/// 安装搜索页 viewDidAppear 冲刷 pending（LBInstallSearchHooks 内也会调用）
FOUNDATION_EXPORT void LBInstallSearchUIAppearFlush(void);
/// 安装目录页 viewDidAppear 冲刷 pending（详情时引擎先返回，CatalogCon 后出现）
FOUNDATION_EXPORT void LBInstallCatalogUIAppearFlush(void);
FOUNDATION_EXPORT void LBHandleCatalogRequest(NSString *bookUrl, NSString *sourceUrl);
FOUNDATION_EXPORT void LBHandleContentRequest(NSString *chapterUrl, NSString *bookUrl, NSString *sourceUrl);
/// 正文通知已发出：缓存载荷，阅读页 viewDidAppear 时再投一次（避免 ReadVC 尚未监听）
FOUNDATION_EXPORT void LBNoteResetContentPosted(NSDictionary * _Nullable userInfo);
/// 安装 TextRead/ReadVC appear 冲刷 pending 正文
FOUNDATION_EXPORT void LBInstallReaderContentAppearFlush(void);
/// 点章兜底：present Bridge UITextView 阅读页（绕过 TextReadVC3 SIGABRT）；后续可再接原生阅读器
FOUNDATION_EXPORT BOOL LBPresentBridgeReader(NSString * _Nullable title,
                                             NSString *chapterUrl,
                                             NSString *bookUrl,
                                             NSString * _Nullable * _Nullable outMsg);
/// 把 ResetContent 载荷灌入可见的 Bridge 阅读页
FOUNDATION_EXPORT void LBBridgeReaderApplyContent(NSDictionary * _Nullable userInfo);

FOUNDATION_EXPORT NSString *LBBridgeVersion(void);

/// 弹出 Legado 书源导入 alert（URL / 粘贴 JSON）；仅用户主动触发，不再启动强弹
FOUNDATION_EXPORT void LBShowLegadoImportAlert(void);

/// 打开 Legado 书源管理页；sourceUrl 非空时自动进入该源编辑器
FOUNDATION_EXPORT void LBPresentLegadoSourceManager(NSString * _Nullable sourceUrl);

#endif /* LegadoBridge_h */
