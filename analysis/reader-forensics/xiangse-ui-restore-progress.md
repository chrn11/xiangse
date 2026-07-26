# 香色原生样式还原（xiangse-ui-restore）进度

日期：2026-07-26  
设备包：`1fd3c15` / run `30165507011` / variant `legado-debug`（已装真机，manifest 一致）  
工作区：与发包提交一致（`a@text` 修复已进包）  
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

## 2. 真机验收（包 `1fd3c15` / run `30165507011`）

### 2.0 装包身份

- IPA：`.test_tools/ci-ipa-30165507011/dist/StandarReader-legado-bridge-debug.ipa`
- SHA256：`1de140ba52575bc72ef1affbedb866d8e6f4e68d6c2731aae97045b54b37f8f7`
- artifact：`LegadoBridge-IPA-Debug`
- `reader-build-manifest.json`：`git_commit=1fd3c154f968b0…`，`github_run_id=30165507011`，`variant=legado-debug` → **PASS**

### 2.1 验收表（诚实）

| ID | 项 | 结果 | 证据 |
|---|---|---|---|
| G2 | 冷开无错误目录缓存：不得「上架感言」，期望「第一章 陨落的天才」，`chapters>0` | **PASS** | 清 doupo 缓存后 `NO_DOUPO_CACHE`；`catalog_last`=`chapters=2 first=第一章 陨落的天才`；UI=`返回`+`第一章 陨落的天才`；无「上架感言」。`v_1fd_doupo_cold*` |
| G3 | 用户可见无「Legado」品牌字 | **PASS** | 导入 Alert=`导入 1 个书源`；站点栏=`书源`；管理页 title=`书源管理`（`v_1fd_after_import*` / `v_1fd_sites*` / `v_1fd_source_manager*`） |
| G6 | 底栏图标工具栏干净截图 | **FAIL（根因已定位，代码已改待新包）** | `1fd3c15` 中点仍只有顶栏「返回」+章题。静态对照：`ReadVCBase2.viewDidAppear` = super → `createToolbar` → `hideToolBar`；`ToolBarCreator.createBottom:` 含 mulu/zihao 等。nativeFull 的 `viewDidAppear` 旁路未调 ORIG → `createToolbar` 从未执行。已在 `LegadoBridgeCExports.m` 补一次 `createToolbar`+`hideToolBar`。**需新 IPA 真机复验**。旧证：`v_1fd_g6_toolbar_*` |
| A | 阅读壳仍为宿主 | 保持 | 冷开章题「返回」+「第一章 陨落的天才」 |

对照上一包 `e51cab5`：G2 冷开 `chapters=0` FAIL；本包 `a@text` 修复后冷开网络 TOC 解析成功，无需种缓存。

### 2.2 G2 探针（本轮）

`Documents/legado_catalog_body_probe.txt`：

- `toc=http://192.168.1.4:8766/book/doupo_toc.html`
- `bodyLen=270` / `ddApprox=2` / `hasListId=true`
- `chapterListRule=#list dd`
- `chapterCount=2`
- `first=第一章 陨落的天才`

`legado_catalog_last.txt`：`ok … chapters=2 first=第一章 陨落的天才`  
`legado_catalog_select.txt`：`title=第一章 陨落的天才`

### 2.3 截图/元数据索引（本轮）

| 文件 | 含义 |
|---|---|
| `v_1fd_shelf0*` | 冷启书架 |
| `v_1fd_after_import*` | 导入 Alert（无 Legado） |
| `v_1fd_sites*` / `v_1fd_source_manager*` | 站点栏「书源」+「书源管理」 |
| `v_1fd_doupo_cold*` | G2 PASS：无缓存冷开章题陨落的天才 |
| `v_1fd_g6_reader*` / `v_1fd_g6_toolbar_*` | G6 重试仍未出底栏图标 |
| `.test_tools/mcp-evidence/accept_ui_restore_1fd3c15.json` | 验收汇总 |
| `.test_tools/mcp-evidence/ipa_upload_1fd3c15.json` / `ipa_install_1fd3c15.json` | 装包 |
| `.test_tools/mcp-evidence/g6_retry_1fd3c15.json` | G6 单独重试 |

## 3. 本轮代码状态

`1fd3c15` 已包含并真机验证：

1. **`RuleEngine.swift`（CSSParser.executeAtChain）**  
   非末段仅把「像属性」的名字当属性；不再把标签名 `a`/`div`/`li` 当属性 → mock TOC `a@text` 章题可解析。
2. **`RuleWebBook.swift`**  
   `legado_catalog_body_probe.txt`（bodyLen / ddApprox / chapterCount）已在真机写出且 `chapterCount=2`。

更早已进包、仍有效：

- http(s) 禁止 xsfolder 填 pending 目录  
- `LBGuessBookKeyForUrl` 未知 URL 不再默认斗破 key  
- http(s) 禁止 `LBReadXsfolderChapterBody`

### 已改待 commit（G6 底栏）

**文件**：`LegadoBridge/Sources/LegadoBridgeHooks/LegadoBridgeCExports.m`

**根因（只对 `com.appbox.StandarReader` 静态对照 + 现包行为，未用 Reader0）**：

1. 原版 `ReadVCBase2.viewDidAppear:`：`super` → `createToolbar` → `hideToolBar`
2. `createToolbar` 经 `ToolBarCreator` 调 `createHeader:` / `createBottom:`（底栏图 mulu/zihao/…）
3. 中点手势 `TextReadVC2.onTapGestureEvent:` 区域类型 1 → `changeToolBar`
4. Bridge nativeFull 的 `LBTextRead_viewDidAppear_Safe` 为避崩只走 UIKit super，**从不执行**上述 `createToolbar` → 底栏视图不存在；中点只能看到导航顶栏

**改动**：nativeFull `viewDidAppear` 在 UIKitSuper 之后，对当前阅读页实例补一次 `createToolbar` + `hideToolBar`（不恢复完整 ORIG appear；`LBPushTextReaderNativeFull` 入口清零实例标记）。

**真机复验**：需父代理 commit → CI 出 Debug IPA → 只装 `com.appbox.StandarReader` → nativeRead 中点截「目录/字号/主题」；并回归 G2/G3。

未改计划文件 status。未 commit。未 push。未再 launch `com.appbox.StandarReader0`。

## 4. 须大脑批准（例外 / 高风险）— 只列不擅自做

| 项 | 原因 |
|---|---|
| 用原版 `BookDetailController` / Catalog 链替换 `LBLegadoCatalogListVC` | 历史：push/setDicBook 无 ips 回桌面；属新私有生命周期，硬规则 2 |
| 调用/改写 `ToolBarCreator` / `TextReadSettingVC` 私有 API | **G6 底栏：大脑已批**仅限 nativeRead 阅读页唤出底栏；本轮只补 `createToolbar`/`hideToolBar`，不扩 BookDetail/书源管理 |
| 用原版 `BookSourceManager*` 替换 `LBLegadoSourceManagerVC` | 原生站点模型与协议源并存，易污染宿主源列表 |
| 导入改成完整香色原生表单页（非 Alert） | 需宿主 VC/私有入口或大改 UI，超出文案级还原 |
| Release 隐藏 Hook 能力区 | 影响排障；是否出货可见需产品拍板 |
| 搜索 `typeTitle` 从 `@"Legado"` 再改语义 | 与 `BookSearchController` 行为相关，乱改可能丢结果 |
| 删 `legado://login?mode=alert` | 调试旁路；默认已是 WebView |
| 清空/重写用户机上 `xsfolder/斗破苍穹_天蚕土豆` 污染数据 | 属设备数据手术，非桥逻辑；是否做需另批 |

## 5. 完成定义（仍未宣称总 PASS）

1. mock 书：搜索 → 目录（章名正确、无串书）→ 点章 → 原版阅读；中点「菜单」出现原版底栏，截图命中正文夹具字 — **冷开点章/章名 `1fd3c15` PASS；底栏 G6 仍 FAIL，待新包复验**。
2. 用户可见入口不再出现「Legado」品牌字（内部类名/日志可保留）— **G3 PASS**。
3. 不恢复 BookDetail 杀进程路径。
4. 本阶段 **不** 开全能书源总验收。

## 6. 下一步可执行

1. **父代理 commit G6 补丁 → CI Debug IPA → 只装 StandarReader → 复验 G6 + G2/G3**。
2. 可选：干净正文夹具字 OCR 断言（完成定义第 1 条后半）。
3. 例外项：BookDetail / 书源管理整页等仍勿擅自做。

修订：2026-07-26（G6 根因：nativeFull 跳过 `createToolbar`；已改待 commit；禁碰 StandarReader0）
