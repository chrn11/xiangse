# 阶段一书源功能收口证据（2026-07-23）

SHA：`f6904f2`（CI `29994659934`）+ 文档 `64a4c09`

## 矩阵

| # | 功能 | 证据 | 结论 |
|---|---|---|---|
| 8.1–8.4 | 搜索/详情/目录/正文 | 既有 BC17 / scroll S5 | ✅ |
| 8.5 | 缓存与进度 | Bridge 离线补丁在工作区未进包；IPA 仍 `f6904f2`；见 `phase85-cache-progress.md` | ❌ FAIL/BLOCKED：待 commit+CI 新 Debug IPA 后重跑 `phase85_cache_accept.py` |
| 8.6 | 替换净化 | `RuleFixtureTests.testApplyReplaceRegexStripsAdBlock`；`legado-purify-mock.json` | ✅ 单测 + 夹具；真机 dump 针待稳定目录点章 |
| 8.7 | WebView | `legado-webview-mock.json` + `webview_challenge.html` | ⚠️ 夹具就绪，真机轮待补 |
| 8.8 | 登录 | `legado://login` → UIAlert「书源登录」真机 PASS | ✅ |
| 8.9 | 发现 | `legado://explore` 深链 marker PASS；`mock_explore.html` | ✅ 深链；UI 列表依赖搜索通知 |
| 8.10 | 变量/并发 | 引擎已有；源夹具含 `variable`/`concurrentRate` | ⚠️ 引擎级，夹具已挂 |
| 8.11 | 例外 | `legado-feature-exceptions.md` | ✅ |

真机报告：`fixtures/_devkit/phase8_parity/report.json`（login/explore 深链 PASS）。
