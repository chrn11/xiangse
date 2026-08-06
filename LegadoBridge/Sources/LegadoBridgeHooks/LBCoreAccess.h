#ifndef LBCoreAccess_h
#define LBCoreAccess_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Core 轻量探测 / 阅读会话映射（token + pair）。实现见 LBCoreAccess.m。

id _Nullable LBLegadoCoreIfReady(void);

/// 阅读会话：记住 Legado 书（要求 dic 含 pair；优先 token）。
void LBReadingRememberBook(NSDictionary * _Nullable dicBook);

/// 显式 pair + token 写入进程内阅读映射。
void LBReadingRememberPair(NSString *sourceUrl, NSString *bookUrl, NSString * _Nullable token);

/// token 精确反查 sourceUrl。
NSString * _Nullable LBReadingSourceUrlForToken(NSString *token);

/// bookUrl-only：仅唯一 legacy 命中时返回；歧义返回 nil。
NSString * _Nullable LBReadingSourceUrlForBookUrl(NSString * _Nullable bookUrl);

/// token → @{ @"sourceUrl", @"bookUrl", @"token" }
NSDictionary * _Nullable LBReadingPairForToken(NSString *token);

BOOL LBReadingDicLooksLegado(NSDictionary * _Nullable dic);
BOOL LBReadingDicLooksExplicitNativeXBS(NSDictionary * _Nullable dic);
NSString * _Nullable LBReadingBookUrlFromDic(NSDictionary * _Nullable dic);
NSString * _Nullable LBReadingSourceUrlFromDic(NSDictionary * _Nullable dic);
NSString * _Nullable LBReadingTokenFromDic(NSDictionary * _Nullable dic);
NSDictionary * _Nullable LBReadingDicFromObject(id _Nullable object);

NS_ASSUME_NONNULL_END

#endif /* LBCoreAccess_h */
