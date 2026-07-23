# 阶段一书源功能收口证据（2026-07-23）

SHA：`0045524`（8.5/8.6）；**8.7 旧 PASS `1ec40dd` 作废**（about:blank）；真导航重验中；parity 整体未 completed

## 矩阵

| # | 功能 | 证据 | 结论 |
|---|---|---|---|
| 8.1–8.4 | 搜索/详情/目录/正文 | 既有 BC17 / scroll S5 | ✅ |
| 8.5 | 缓存与进度 | `7c82687`/`0045524`；`phase85_cache_accept` PASS。见 `phase85-cache-progress.md` | ✅ PASS |
| 8.6 | 替换净化 | `0045524`；`phase86_purify_accept` PASS。见 `phase86-purify-progress.md` | ✅ PASS |
| 8.7 | WebView | 旧 `1ec40dd` about:blank **作废**；须 WK `load(URLRequest)` 章节 http(s) + dump 针。见 `phase87-webview-progress.md` | ⏳ 真导航重验 |
| 8.8 | 登录 | `legado://login` → UIAlert「书源登录」真机 PASS | ✅ 深链；全链 Cookie 待加强（**勿开深化直至 8.7 真导航 PASS**） |
| 8.9 | 发现 | `legado://explore` 深链 marker PASS；`mock_explore.html` | ✅ 深链；UI 列表待加强 |
| 8.10 | 变量/并发 | 引擎已有；源夹具含 `variable`/`concurrentRate` | ⚠️ 引擎级，夹具已挂 |
| 8.11 | 例外 | `legado-feature-exceptions.md` | ✅ |

真机报告：`fixtures/_devkit/phase8_parity/report.json`（login/explore 深链）；8.5：`fixtures/_devkit/phase85_cache/report.json`；8.6：`fixtures/_devkit/phase86_purify/report.json`；8.7：`fixtures/_devkit/phase87_webview/report.json`（待真导航 PASS）。
