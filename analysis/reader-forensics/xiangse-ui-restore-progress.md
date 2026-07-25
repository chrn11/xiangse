# 香色原生样式还原（xiangse-ui-restore）进度

日期：2026-07-26  
设备包：`e51cab5` / run `30165002442` / variant `legado-debug`（已装真机，manifest 一致）  
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

## 2. 真机验收（包 `e51cab5` / run `30165002442`）

### 2.0 装包身份

- IPA：`.test_tools/ci-ipa-30165002442/dist/StandarReader-legado-bridge-debug.ipa`
- SHA256：`890eba34471d6d13febdafbfc1bf14d406110ca6487e96ebbec21583b9f35ba2`
- `reader-build-manifest.json`：`git_commit=e51cab5266f188…`，`github_run_id=30165002442`，`variant=legado-debug` → **PASS**

### 2.1 验收表（诚实）

| ID | 项 | 结果 | 证据 |
|---|---|---|---|
| G2 | 冷开无错误目录缓存：不得「上架感言」，期望「第一章 陨落的天才」 | **FAIL** | `skipXsfolder` 已生效（不再走 xsfolder「上架感言」）；但 `legado_catalog_last.txt`=`chapters=0`，UI 停在空书架，无正确章题。`v_e51_doupo_cold*` |
| G2′ | 同包 + 种入正确 `legado_catalog_cache/<safeKey>.json` 后再 `nativeRead` doupo | **PASS** | `v_e51_doupo_with_cache_meta.json`：UI/select=`第一章 陨落的天才` |
| G3 | 用户可见无「Legado」品牌字 | **PASS** | 导入 Alert=`导入 1 个书源`；站点栏=`书源`；管理页 title=`书源管理`（`v_e51_after_import*` / `v_e51_sites*` / `v_e51_source_manager*`） |
| G6 | 底栏图标工具栏干净截图 | **FAIL** | 中点未出目录/字号/主题；`v_e51_reader_toolbar_*` / `v_e51_toolbar_cached*` |
| A | 阅读壳仍为宿主 | 保持 | G2′ 前台章题「返回」+「第一章 陨落的天才」 |

上一轮 `0419490`：G2 串「上架感言」；本包已堵住 xsfolder 污染路径，但冷开网络目录解析空 → 仍总 FAIL。

### 2.2 G2 本轮根因（钉死）

1. `e51cab5` 的 http(s) 禁 xsfolder pending / 禁 xsfolder 正文 → 冷开无缓存时 **不再**出现「上架感言」（对照旧包已验证）。
2. 冷开改走 `LBHandleCatalogRequest` → 拉到正确 `doupo_toc.html`（cookie probe / catalog_last toc 均对）。
3. `getChapterList` 返回 **chapters=0**：TOC HTML 含 `<dd><a>…`，规则 `chapterName=a@text`。
4. 根因在 `RuleEngine.CSSParser.executeAtChain`：非末段把标签名 `a` 误判为属性名，`a@text` 得到空标题 → TocParser 过滤掉全部章。
5. 对照：写入正确 bookUrl 目录缓存后，**同包**章题「第一章 陨落的天才」→ pending/开章链正常。

### 2.3 截图/元数据索引（本轮）

| 文件 | 含义 |
|---|---|
| `v_e51_shelf0*` | 冷启书架 |
| `v_e51_after_import*` | 导入 Alert（无 Legado） |
| `v_e51_sites*` / `v_e51_source_manager*` | 站点栏「书源」+「书源管理」 |
| `v_e51_doupo_cold*` | G2 FAIL：无缓存冷开未进阅读 / chapters=0 |
| `v_e51_doupo_with_cache*` | G2′ PASS：正确缓存后章题陨落的天才 |
| `v_e51_reader_toolbar_*` / `v_e51_toolbar_cached*` | G6 未拍到底栏图标 |
| `.test_tools/mcp-evidence/accept_ui_restore_e51cab5.json` | 验收汇总 |
| `.test_tools/mcp-evidence/ipa_upload_e51cab5.json` / `ipa_install_e51cab5.json` | 装包 |

## 3. 本轮已改代码（已改待 commit，未进 `e51cab5` 包）

1. **`RuleEngine.swift`（CSSParser.executeAtChain）**  
   非末段仅把「像属性」的名字（`href` / `data-bid` 等）当属性；**不再**把标签名 `a`/`div`/`li` 当属性。修复 `a@text` 空标题 → mock TOC `chapters=0`。
2. **`RuleWebBook.swift`**  
   增加 `Documents/legado_catalog_body_probe.txt`（bodyLen / ddApprox / chapterCount），便于区分「未拉 TOC」与「拉到但解析 0」。

上一轮已进 `e51cab5` 包、无需再改：

- http(s) 禁止 xsfolder 填 pending 目录  
- `LBGuessBookKeyForUrl` 未知 URL 不再默认斗破 key  
- http(s) 禁止 `LBReadXsfolderChapterBody`

**未改计划文件 status。未 commit。未 push。**

下一包验收要点：删 doupo 目录缓存后冷开 → select/UI 须为「第一章 陨落的天才」（或 mock 正确章题），且不得「上架感言」；探针 `legado_catalog_body_probe.txt` 应 `chapterCount>=1`。

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
2. 验收断言：无 doupo 缓存时 `nativeRead` → UI/select 含「陨落」且不含「上架感言」；`catalog_body_probe.chapterCount>=1`。
3. 补 G6：干净正文 + 底栏工具栏（对照本地 TXT）。
4. 例外项保持清单。

修订：2026-07-26（e51cab5 真机验：G3 PASS / G2 冷开 FAIL(chapters=0) / G2′ PASS / 已改待 commit：a@text 中段属性误判）
