# 香色原生样式还原（xiangse-ui-restore）进度

日期：2026-07-26  
设备包：`0419490` / run `30164640485` / variant `legado-debug`（已装真机，manifest 一致）  
工作区：含本轮**未发包**改动（见 §3）  
真机证据目录：`fixtures/_devkit/ui_restore/`（gitignore，不入库）  
对照矩阵旧稿：`xiangse-ui-restore-matrix.md`

## 1. 本阶段「样式还原」指什么

计划最终目的句：点章后看到的是**香色原版阅读 UI**（分页/滚动/字体/排版/缓存/进度），协议只做书源后端。

可拆成五块：

| 块 | 原版承载体 | Bridge 现状 | 还原目标 |
|---|---|---|---|
| A. 阅读页工具栏/触区 | `TextReadVC3` + `ToolBarCreator` + `dir_res/dir_readview/*` | `legado://nativeRead` 进原版 VC | 点章后工具栏/触区与本地书一致 |
| B. 字体/主题/排版 | `TextReadSettingVC` + `dir_font` + theme_* 资源 | 原版设置页，未自建 | 原版面板可用，不另造 |
| C. 目录 | 原版 `BookDetail*` / Catalog 链 | `LBLegadoCatalogListVC` 自建列表（避开 BookDetail 杀进程） | 视觉接近宿主；功能可点章 |
| D. 搜索/发现列表 | 宿主搜索通知 / `LBApplySearchResultsToUI` | 结果注入宿主搜索 UI | 列表像香色搜索，不像外挂页 |
| E. 书源管理/导入 | 原版站点管理 + Bridge 入口 | `LBLegadoSourceManagerVC` + `UIAlert` 导入；站点栏「书源」按钮 | 文案/入口不像外挂；管理页可读 |

登录 WebView / browserAwait 已在延后总验备忘里 PASS，**不纳入本阶段主缺口**。

## 2. 真机验收（包 `0419490` / run `30164640485`）

### 2.0 装包身份

- IPA：`.test_tools/ci-ipa-30164640485/dist/StandarReader-legado-bridge-debug.ipa`
- `reader-build-manifest.json`：`git_commit=04194901d3387c…`，`github_run_id=30164640485`，`variant=legado-debug` → **PASS**

### 2.1 验收表（诚实）

| ID | 项 | 结果 | 证据 |
|---|---|---|---|
| G2 | 目录/开章不串「上架感言」 | **FAIL**（冷开无该书目录缓存） | `legado_catalog_select.txt`：`book=.../doupo.html … title=上架感言`；UI 正文为起点感言 |
| G2′ | 同包 + 种入正确 `legado_catalog_cache/<safeKey>.json` 后再 `nativeRead` doupo | **PASS（对照）** | `v041_doupo_with_cache_meta.json`：UI/select=`第一章 陨落的天才` |
| G3 | 用户可见无「Legado」品牌字 | **PASS** | 导入 Alert=`导入 1 个书源`；站点栏按钮=`书源`；管理页 title=`书源管理`（`v041_after_import_meta.json` / `v041_source_manager_meta.json`） |
| G6 | 底栏图标工具栏干净截图 | **FAIL** | 中点后未见目录/字号/主题等；`v041_reader_toolbar*` / `v041_toolbar_after_cache*` |
| A | 阅读壳仍为宿主 | 保持 | 前台 `com.appbox.StandarReader`；章题栏「返回」模型未变 |

### 2.2 G2 根因（本轮钉死）

1. `0419490` 已做 pending **bookUrl 严格匹配**，但缓存未命中时 `LBEnsurePendingCatalogForBook` 仍回退 `LBCatalogFromXsfolderBookKey(LBGuessBookKeyForUrl)`。
2. `doupo`（及任意未知 URL 旧默认）落到本地 key `斗破苍穹_天蚕土豆`。
3. 真机该 xsfolder 章 0 / `localSourceText` **已被起点「上架感言」正文污染**（`Library/appdata/xsfolder/book/斗破苍穹_天蚕土豆/0` 开头即「又一次上架了」）。
4. 因此 `nativeRead` doupo 在**无正确 bookUrl 目录缓存**时直接 `pendingNow` 开章 → select 记 `title=上架感言`。
5. 对照：写入正确 `{bookUrl,chapters}` 缓存后，**同包**章题变为「第一章 陨落的天才」→ pending 匹配本身可用；缺口在 **http 书误用 xsfolder 目录/正文**。

### 2.3 截图/元数据索引（本轮）

| 文件 | 含义 |
|---|---|
| `v041_shelf0*` | 冷启书架 |
| `v041_after_import*` | 导入 Alert（无 Legado） |
| `v041_sites2*` / `v041_source_manager*` | 站点栏「书源」+「书源管理」 |
| `v041_doupo_reader*` | G2 FAIL：doupo 仍上架感言 |
| `v041_doupo_with_cache*` | G2′ PASS：正确缓存后章题陨落的天才 |
| `v041_reader_toolbar*` | G6 未拍到底栏图标 |
| `.test_tools/mcp-evidence/accept_ui_restore_0419490.json` | 验收汇总 |

## 3. 本轮已改代码（已改待 commit，未进 `0419490` 包）

文件：`LegadoBridge/Sources/LegadoBridgeHooks/LegadoBridgeCExports.m`

1. **http(s) 书禁止用 xsfolder 填 pending 目录**（缓存未命中则返回 NO，走 `LBHandleCatalogRequest`）。
2. **`LBGuessBookKeyForUrl`**：未知 URL 不再默认 `斗破苍穹_天蚕土豆`，改返回 `nil`。
3. **http(s) 书禁止 `LBReadXsfolderChapterBody`**，避免污染正文抢先上屏。

**未改计划文件 status。未 commit。未 push。**

下一包验收要点：删/忽略错误缓存后冷开 `doupo` → select/UI 不得出现「上架感言」；应变为 mock 章名或等网络目录返回后再开章。

## 4. 须大脑批准（例外 / 高风险）— 只列不擅自做

| 项 | 原因 |
|---|---|
| 用原版 `BookDetailController` / Catalog 链替换 `LBLegadoCatalogListVC` | 历史：push/setDicBook 无 ips 回桌面；属新私有生命周期，硬规则 2 |
| 调用/改写 `ToolBarCreator` / `TextReadSettingVC` 私有 API | method-map 无 confirmed 门禁条目 |
| 用原版 `BookSourceManager*` 替换 `LBLegadoSourceManagerVC` | 原生站点模型与协议源并存，易污染宿主源列表 |
| 导入改成完整香色原生表单页（非 Alert） | 需宿主 VC/私有入口或大改 UI，超出文案级还原 |
| Release 隐藏 Hook 能力区 | 影响排障；是否出货可见需产品拍板 |
| 搜索 `typeTitle` 从 `@"Legado"` 再改语义 | 与 `BookSearchController` 行为相关，乱改可能丢结果 |
| 删 `legado://login?mode=alert` | 调试旁路；默认已是 WebView |
| 清空/重写用户机上 `xsfolder/斗破苍穹_天蚕土豆` 污染数据 | 属设备数据手术，非桥逻辑；是否做需另批 |

## 5. 完成定义（仍未宣称总 PASS）

1. mock 书：搜索 → 目录（章名正确、无串书）→ 点章 → 原版阅读；中点「菜单」出现原版底栏，截图命中正文夹具字。
2. 用户可见入口不再出现「Legado」品牌字（内部类名/日志可保留）— **G3 本包已 PASS**。
3. 不恢复 BookDetail 杀进程路径。
4. 本阶段 **不** 开全能书源总验收。

## 6. 下一步可执行

1. **commit + 推 CI** 打含 §3 的 Debug IPA → 再装真机验 G2 冷开（勿依赖手工种缓存）。
2. 验收脚本固定：无 doupo 缓存时 `nativeRead` → 断言 select/UI ≠「上架感言」；有缓存时章题含「陨落」。
3. 补 G6：干净正文 + 底栏工具栏（对照本地 TXT）。
4. 例外项保持清单。

修订：2026-07-26（0419490 真机验：G3 PASS / G2 FAIL / 已改待 commit）
