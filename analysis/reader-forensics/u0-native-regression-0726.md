# U0 原生功能兼容回归 — 首轮实测（2026-07-26）

> 触发：用户报告「检测站点」等原生功能注入后不能用，并要求实测验证「总验收全部通过」的说法。
> 通道：ios-mcp `192.168.1.18:8090`（文档默认 `.6` 实测不可达）。设备红线遵守：未装包、未碰 StandarReader0、未重启 SpringBoard。
> 被测包：manifest 实测 `git_commit=2c1cf80` / `run=30194525472` / **variant=legado-release** / 构建 2026-07-26T08:24Z。
> 证据：`fixtures/_devkit/verify_0726/`（截图 + a–k 分步报告；gitignore）。验证脚本：`.test_tools/verify_0726_*.py`。

## 一、实测为真的（PASS）

| 项 | 证据 |
|---|---|
| 包身份与文档声称一致 | `a_env_report.json` manifest 字段全吻合 |
| Legado 源注册且持久化 | `legado_bridge_sources.json` 3 源（本地静态测试源/笔趣读/领域书库） |
| 书籍绑定在 | `legado_bridge_books.json` 含「斗破之魂风」（领域书库）等 |
| 书源管理页可开、G3 品牌字不回归 | `k01_source_mgr.png`：title「书源管理」，无 Legado 字样 |
| HOOK 安装全成功 | 管理页能力行：`ok=11 miss=0`，五组全 enabled |
| 全程无崩溃 | pid 36936 自 launch 起未变；无 SIGABRT |

## 二、实测为假的（FAIL ——「全部通过」不成立）

| # | 问题 | 证据 | 初步定性 |
|---|---|---|---|
| F1 | **书架空**：books.json 有 Legado 绑定书，书架 UI 却「空列表」 | `b01_shelf.png` | Legado 书未进原生书架，或加书架链路在 release 失效；phase85 曾记「书架 tap=false 不挡门禁」 |
| F2 | **open_once 残留**：`legado_native_open_once.txt`（mock 斗破）存于 Documents+Caches | `b_explore_report.json` read 结果 | 违反 acceptance contract「open_once 最终不存在」；上次会话未正常清理 |
| F3 | **原生 XBS 站点被掏空**：站点管理页仅 `站点(3)` Legado 源；SR0 对照为 `站点(960)` | `forensics_sr0_sites/INJ_site_mgr.json` vs `SR0_site_mgr.json` | **已坐实数据面**：原生站点未进注入包列表；嫌疑 `BookSourceModelManager`/`getGroupData` 合并替换 |
| F4 | **切换站点选择器无响应**：单击/长按站点行均无反应（不选中、无菜单） | `j_checksite_report.json` | 换源选择器路径仍待测；与「站点管理」页不同 |
| F5 | ~~「检测站点」入口不可达~~ → **入口仍在** | `u0-sr0-site-forensics.md`：两边均为 整理→站点管理→更多→检测站点 | **旧结论作废**；用户在换源/Bridge 页找不到≠入口被删。宿主类 `ConfigSourceModelListCon.onSourceCheckEvent` |
| F6 | **发现页/广场全空白** | `b02_discover.png`、`h01_square.png` | 无 XBS 站点的连带结果，或独立缺陷 |
| F7 | **HOOK 能力调试面板在 legado-release 用户可见** | `k01_source_mgr.png` | 属「须批准」清单项（Release 隐藏 Hook 能力区）未决事项；当前暴露内部状态 |

## 三、嫌疑链（待 U0 对照取证，先取证后定罪）

1. `source-list` Hook → 原生站点列表 tap 被拦 → F4/F5（最重大嫌疑）
2. `search` Hook 组（`canSearch`/`sortedByPriNativeOnly`/`startSearch`/`suppressNoSiteAlert`）→ 检测站点若走搜索测速路径 → F5
3. `BookSourceModelManager` Hook → 原生默认站点加载 → F3
4. 书架注入（addBook/BookDbManager）→ F1

## 四（续）、恢复后实测增量（2026-07-26 18:00–19:0x，m–u 步）

**结论修正**：中途失效列表比首轮更多，需按「MCP 直发可开 vs UI 路径失效」分层理解。

| # | 项 | 实测结果 | 判定 |
|---|---|---|---|
| M | 「整理」/站点管理原生入口 | 「整理」打开的是文件夹侧滑视图（图标），无站点管理/设置入口；native 站点管理入口未找到 | 入口未定位（非必然失效，需原生对照确认是否存在） |
| N | 运行时取证「检测站点」 | `find_class_for_selector onSourceCheckEvent` 提示需 TrollFools 注入 mcp-dumpagent.dylib；class_dump 输出噪声大不可用 | 该路径当前取证手段不足，暂搁置 |
| O | Legado 搜索（UI 路径） | 书架搜索图标 → 输入「斗破」回车 → 出 mock 4 本结果（斗破苍穹/净化验收专书/WebView验收专书/凡人修仙传） | **PASS** |
| P | 搜索 trace + 点书 | `legado_search_last.txt` 仍停在 08:34 起点搜索（**UI 搜索不写该 trace，trace 不完全**）；首次点书行无反应 | trace 缺陷待记；点击疑似时机问题 |
| Q | 深链+点书行 | `legado://search` scheme 不存在（Invalid URL）；但再次 UI 点书行 **成功**进入目录页「斗破苍穹 共2章」 | 目录可达 **PASS** |
| R | 目录点章 | 首轮：点「第一章 陨落的天才」无反应。**1340b3c 斗破复验 PASS**：`verify_u0_r_doupo/03_after_tap.png` 正文含萧炎；select=`…/book/doupo.html` | **PASS（斗破，1340b3c）** |
| S | nativeRead（错误参数） | `url=` 参数 → Alert「nativeRead 缺少 bookUrl」 | 参数名应为 bookUrl |
| T | nativeRead（正确参数） | **正文完整上屏**（第一章全文，原生排版）；中点唤出完整底栏：上一章/下一章/目录/缓存/设置/换源（G6 真机复现 PASS）；open_once 仍残留 | **PASS**（MCP 直发路径） |
| U | 阅读页「换源」 | 「换源」→「选择站点」页（localSourceText），点行 → 目录页（斗破苍穹，到底部/已全部加载完毕） | **PASS**（换源功能可用） |
| U2 | 发现页 | 无任何可读元素，整页空白（截图确认） | **FAIL 维持 F6** |
| 设备 | 已购 App | `com.appbox.StandarReader0`（已购）与注入包并存 | 后续可做原生对照（未操作，守红线） |

**失效分层结论**：
- **MCP 直发可开**：nativeRead→正文 PASS、G6 底栏 PASS、换源 PASS、搜索→目录 PASS
- **UI 路径失效**：目录点章不进正文（R，硬失效）；书架绑定书不显示（F1）；原生站点为 0（F3）；「检测站点」入口不可达（F4/F5）
- **待原生对照才能定罪**：「整理」/站点管理原生入口是否存在、选择站点页对 Legado 假条目失效是否 Hook 所致

**U0 完成定义更新**：需补「目录点章失效（R）」与「搜索 trace 不写（P）」两项缺陷的根因定位；F1–F7 + R/P 共 9 项全部修复且复测 PASS 方可进 U1。

- 「整理」菜单与原生站点管理页（ConfigSourceModelListCon）入口探测
- 「检测站点」实际触发（需先有原生 XBS 站点；可经 dir_res 示例 xbs 导入构造对照）
- Legado 搜索→目录→正文回归（需 PC 起 `fixtures/serve_local_mock.py`，书源指向 192.168.1.4:8766）
- 起点正文 PASS 复核、forensics_dump 在 release 是否仍新增

## 五、结论

- 「总验收全部通过」在**当时 Legado 链路**上可信度较高（包身份/源/绑定/HOOK 全对得上）；但 **F1–F7 证明「全部通过」不覆盖原生兼容与会话清理**，U0 必要性实证成立。
- 用户所报「书源检测不能用」**实测成立**（F3/F4/F5 三重表现）；根因待 U0 按嫌疑链对照取证。
