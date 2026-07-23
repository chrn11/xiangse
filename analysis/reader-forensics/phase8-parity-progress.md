# 阶段一书源功能收口证据（2026-07-23）

SHA：`7c82687`（CI `30003630299` Debug）；阶段一/二文档仍见既有提交；**8.5 真机 PASS，可进 8.6；parity 整体未 completed**

## 矩阵

| # | 功能 | 证据 | 结论 |
|---|---|---|---|
| 8.1–8.4 | 搜索/详情/目录/正文 | 既有 BC17 / scroll S5 | ✅ |
| 8.5 | 缓存与进度 | `7c82687` 页位落盘+`setContentOffset` 恢复；`phase85_cache_accept` verdict=PASS（含 `restore_has_yaolao`）。见 `phase85-cache-progress.md` | ✅ PASS：可进 8.6 |
| 8.6 | 替换净化 | `RuleFixtureTests.testApplyReplaceRegexStripsAdBlock`；`legado-purify-mock.json` | ✅ 单测 + 夹具；真机 dump 针可开 |
| 8.7 | WebView | `legado-webview-mock.json` + `webview_challenge.html` | ⚠️ 夹具就绪，真机轮待补 |
| 8.8 | 登录 | `legado://login` → UIAlert「书源登录」真机 PASS | ✅ |
| 8.9 | 发现 | `legado://explore` 深链 marker PASS；`mock_explore.html` | ✅ 深链；UI 列表依赖搜索通知 |
| 8.10 | 变量/并发 | 引擎已有；源夹具含 `variable`/`concurrentRate` | ⚠️ 引擎级，夹具已挂 |
| 8.11 | 例外 | `legado-feature-exceptions.md` | ✅ |

真机报告：`fixtures/_devkit/phase8_parity/report.json`（login/explore 深链 PASS）；8.5 报告：`fixtures/_devkit/phase85_cache/report.json`。
