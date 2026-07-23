# Legado 书源功能例外清单（阶段 8.11）

登记不纳入本闭环交付的功能。经计划阶段 8 矩阵约定，下列项**只登记不开发**。

| 功能 | 原因 | 替代呈现 |
|---|---|---|
| `ruleReview` 书评/评论 | 引擎仅有 schema 字段，无 `RuleWebBook` 实现 | 不提供评论入口 |
| 听书 / TTS（`HttpTTSConfig`） | 仅有异常类型桩，无播放引擎与 AVAudio 链路 | 不提供听书 |
| `coverDecodeJs` 封面解密 | 活跃 Bridge 图片路径未接入 Vendor `ImageCacheManager` 的 CoreData 解密链 | 显示未解密封面或占位图 |
| `bookVariable`（与 `variable` 区分） | 代码库零引用；仅有源级 `variable` / JS put/get | 用源 `variable` + JS 变量 |

已纳入阶段 8 打通（非例外）：搜索、详情、目录、正文、缓存进度、替换净化、WebView 源、登录态、发现 explore、变量与并发限速。

修订：2026-07-23
