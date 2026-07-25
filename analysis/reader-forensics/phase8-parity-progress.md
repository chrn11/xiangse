# 阶段一书源功能收口证据（2026-07-25 更新）

SHA：`0045524`（8.5/8.6）；**8.7 PASS**（`10d89e3` 真导航；旧 `1ec40dd` about:blank 作废）；parity **整体未 completed**

## 矩阵

| # | 功能 | 证据 | 结论 |
|---|---|---|---|
| 8.1–8.4 | 搜索/详情/目录/正文 | 既有 BC17 / scroll S5（**仅 mock**） | ✅ mock；❌ 真实源未通（见下） |
| 8.5 | 缓存与进度 | `7c82687`/`0045524`；`phase85_cache_accept` PASS。见 `phase85-cache-progress.md` | ✅ PASS |
| 8.6 | 替换净化 | `0045524`；`phase86_purify_accept` PASS。见 `phase86-purify-progress.md` | ✅ PASS |
| 8.7 | 后台 WebView 抓正文 | `10d89e3`；`load(URLRequest)` 真导航。见 `phase87-webview-progress.md` | ✅ PASS（**仅 Backstage**） |
| 8.8 | 登录 | 深链曾 Alert PASS；**可见网页登录/Cookie 全链未 PASS** | ⚠️ 深链 Alert 不作产品门禁；可见 WV 见 `phase88-visible-webview-progress.md` |
| 8.8b | 可见 WebView 过盾/登录 | `82df124`；真机 `XiangseOpenWebView hit class=LCStandarConfig` + WKCookieStore 回灌 jar；起点页可开，过人机+搜索未复跑 | ⚠️ 原生开页+Cookie 回灌已通；真实源搜索仍 FAIL；parity 勿 completed |
| 8.9 | 发现 | `legado://explore` 深链 marker PASS；`mock_explore.html` | ✅ 深链；UI 列表待加强 |
| 8.10 | 变量/并发 | 引擎已有；源夹具含 `variable`/`concurrentRate` | ⚠️ 引擎级，夹具已挂 |
| 8.11 | 例外 | `legado-feature-exceptions.md` | ✅ |
| **真实源 E2E** | 得奇 / 大熊猫 / 起点 | `real-source-e2e.md`；3/3 搜索 `total=0`；得奇设备 HTTP 403；起点需 Cookie 浏览器 | ❌ FAIL |

真机报告：`fixtures/_devkit/phase8_parity/report.json`（login/explore 深链）；8.5–8.7 见各 `phase8*_*/report.json`；真实源：`fixtures/_devkit/real_source_e2e/report.json`。

## 明确未完成（对照「能用」）

1. 真实书源搜索→正文至少 1 源 PASS  
2. 可见 WebView 真机网页截图 + Cookie 回灌后请求带 Cookie  
3. 与 Legado 原版结构化对拍装置  
4. Release 全量矩阵（当前多项仍 Debug IPA）
