#ifndef LegadoBridge_h
#define LegadoBridge_h

#import <Foundation/Foundation.h>

FOUNDATION_EXPORT void LBInstallHooks(void);

FOUNDATION_EXPORT BOOL LBIsLegadoJSONData(NSData *data);
FOUNDATION_EXPORT NSInteger LBImportLegadoJSONData(NSData *data, NSError **error);
FOUNDATION_EXPORT void LBHandleSearchRequest(NSString *keyword, NSString *sourceUrl);
FOUNDATION_EXPORT void LBHandleCatalogRequest(NSString *bookUrl, NSString *sourceUrl);
FOUNDATION_EXPORT void LBHandleContentRequest(NSString *chapterUrl, NSString *bookUrl, NSString *sourceUrl);

FOUNDATION_EXPORT NSString *LBBridgeVersion(void);

/// 弹出 Legado 书源导入 alert（URL / 粘贴 JSON）
FOUNDATION_EXPORT void LBShowLegadoImportAlert(void);

#endif /* LegadoBridge_h */
