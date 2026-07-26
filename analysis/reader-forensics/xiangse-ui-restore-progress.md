# 香色原生样式还原（xiangse-ui-restore）进度

日期：2026-07-26  
设备包：`27c1ed6` / run `30183832647` / variant `legado-debug`（已装真机，manifest 一致）  
工作区：含 G6 加强补丁（**已改待 commit**，未进当前真机包）  
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

## 2. 真机验收（包 `27c1ed6` / run `30183832647`）

### 2.0 装包身份

- IPA：`.test_tools/ci-ipa-30183832647/dist/StandarReader-legado-bridge-debug.ipa`
- SHA256：`62ddf6ce94970ca778bc8067f306d3c270d429955b5dcfe0475ba6bca2323dd7`
- artifact：`LegadoBridge-IPA-Debug`
- `reader-build-manifest.json`：`git_commit=27c1ed6a7e5ceed0…`，`github_run_id=30183832647`，`variant=legado-debug` → **PASS**
- 只装 `com.appbox.StandarReader`；未碰 `StandarReader0`；未重启 SpringBoard

### 2.1 验收表（诚实）

| ID | 项 | 结果 | 证据 |
|---|---|---|---|
| G2 | 冷开无错误目录缓存：不得「上架感言」，期望「第一章 陨落的天才」，`chapters>0` | **PASS** | `catalog_last`=`chapters=2 first=第一章 陨落的天才`；probe `chapterCount=2`；UI=`返回`+`第一章 陨落的天才`；无「上架感言」。`v_27c_doupo_cold*` |
| G3 | 用户可见无「Legado」品牌字 | **PASS** | 导入 Alert=`导入 1 个书源`；站点栏=`书源`；管理页 title=`书源管理`（`v_27c_after_import*` / `v_27c_sites*` / `v_27c_source_manager*`） |
| G6 | 底栏图标工具栏干净截图 | **FAIL** | `27c1ed6` trace 已有 `G6 createToolbar OK`，中点截图仍只有顶栏「返回」+章题，无「目录/字号/主题」。dump：`ToolBarCreator.createBottom:` / `createHeader:sourceType:` 为**实例方法**，另有 `+sharedInstance`。证：`v_27c_g6_toolbar_*` / `v_27c_midtap_after.jpg` / `accept_ui_restore_27c1ed6.json` |
| A | 阅读壳仍为宿主 | 保持 | 冷开章题「返回」+「第一章 陨落的天才」 |

对照上一包 `1fd3c15`：G2/G3 仍 PASS；G6 在「已调 createToolbar」后仍 FAIL（不只是「从未调用」）。

### 2.2 G2 探针（本轮）

`Documents/legado_catalog_body_probe.txt`：

- `toc=http://192.168.1.4:8766/book/doupo_toc.html`
- `bodyLen=270` / `ddApprox=2` / `hasListId=true`
- `chapterListRule=#list dd`
- `chapterCount=2`
- `first=第一章 陨落的天才`

`legado_catalog_last.txt`：`ok … chapters=2 first=第一章 陨落的天才`  
`legado_catalog_select.txt`：`title=第一章 陨落的天才`

### 2.3 截图/元数据索引（本轮 `27c1ed6`）

| 文件 | 含义 |
|---|---|
| `v_27c_shelf0*` | 冷启书架 |
| `v_27c_after_import*` | 导入 Alert（无 Legado） |
| `v_27c_sites*` / `v_27c_source_manager*` | 站点栏「书源」+「书源管理」 |
| `v_27c_doupo_cold*` | G2 PASS：冷开章题陨落的天才 |
| `v_27c_g6_toolbar_*` / `v_27c_midtap_after.jpg` | G6 FAIL：中点无底栏图标 |
| `.test_tools/mcp-evidence/accept_ui_restore_27c1ed6.json` | 验收汇总 |
| `.test_tools/mcp-evidence/ipa_upload_27c1ed6.json` / `ipa_install_27c1ed6.json` | 装包 |
| `.test_tools/mcp-evidence/class_ToolBarCreator.json` | dump 只读（未 launch Reader0） |

## 3. 本轮代码状态

`27c1ed6` 已装真机并验证：

1. nativeFull `viewDidAppear` 补 `createToolbar`+`hideToolBar` → trace **`G6 createToolbar OK`**
2. G2/G3 不回归（PASS）
3. G6 仍 FAIL：中点无底栏

### 已改待 commit（G6 底栏加强）

**文件**：`LegadoBridge/Sources/LegadoBridgeHooks/LegadoBridgeCExports.m`

**新发现（`27c1ed6` 真机 + Plus dump 只读，未 launch Reader0）**：

1. `createToolbar` **已执行**（不再是「从未调用」），但中点仍无底栏
2. `ToolBarCreator`：`+sharedInstance`；`-createBottom:` / `-createHeader:sourceType:` 为实例方法（返回 `UIView`）
3. `ReadVCBase2` ivar：`toolBarBottom` / `toolBarHeader` / `toolBarHidden`

**改动（工作区，未进真机包）**：`LBG6EnsureReaderToolbar`

1. 调 `createToolbar` 后 KVC 探测 `toolBarBottom`/`toolBarHeader`
2. 若 nil：`ToolBarCreator.sharedInstance` → `createBottom:` / `createHeader:sourceType:`，写入 ivar 并 `addSubview`
3. 再 `hideToolBar`；`toolBarBottom` 仍 nil 则 0.8s / 2.0s 主线程重试

**真机复验**：需 commit → CI Debug IPA → 只装 `com.appbox.StandarReader` → 中点截底栏并可点一项；回归 G2/G3。

未改计划文件 status。未 commit。未 push。未 launch `StandarReader0`。未重启 SpringBoard。

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

1. mock 书：搜索 → 目录（章名正确、无串书）→ 点章 → 原版阅读；中点「菜单」出现原版底栏，截图命中正文夹具字 — **冷开点章/章名 `27c1ed6` PASS；底栏 G6 仍 FAIL**。
2. 用户可见入口不再出现「Legado」品牌字（内部类名/日志可保留）— **G3 PASS**。
3. 不恢复 BookDetail 杀进程路径。
4. 本阶段 **不** 开全能书源总验收。

## 6. 下一步可执行

1. **commit G6 加强补丁（ToolBarCreator 回退）→ CI Debug IPA → 只装 StandarReader → 复验 G6 + G2/G3**。
2. 可选：干净正文夹具字 OCR 断言（完成定义第 1 条后半）。
3. 例外项：BookDetail / 书源管理整页等仍勿擅自做。

修订：2026-07-26（`27c1ed6` G6 FAIL：createToolbar OK 仍无底栏；已加强 ToolBarCreator 回退待 commit；禁 Reader0 / 禁 SpringBoard 重启）
