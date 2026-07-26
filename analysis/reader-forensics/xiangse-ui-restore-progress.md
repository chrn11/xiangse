# 香色原生样式还原（xiangse-ui-restore）进度

日期：2026-07-26  
设备包：`b82ef6e` / run `30184275267` / variant `legado-debug`（已装真机，manifest 一致）  
工作区：含 G6 中点 → `changeToolBar` 补丁（**已改待 commit**，未进当前真机包）  
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

## 2. 真机验收（包 `b82ef6e` / run `30184275267`）

### 2.0 装包身份

- IPA：`.test_tools/ci-ipa-30184275267/dist/StandarReader-legado-bridge-debug.ipa`
- SHA256：`e39b47f9bbd1cb9bb35b4a854be73a0073f003eb50be0e7c4425042e07eae9b6`
- artifact：`LegadoBridge-IPA-Debug`
- `reader-build-manifest.json`：`git_commit=b82ef6e898bbb6a07…`，`github_run_id=30184275267`，`variant=legado-debug` → **PASS**
- 只装 `com.appbox.StandarReader`；未碰 `StandarReader0`；未重启 SpringBoard

### 2.1 验收表（诚实）

| ID | 项 | 结果 | 证据 |
|---|---|---|---|
| G2 | 冷开无错误目录缓存：不得「上架感言」，期望「第一章 陨落的天才」，`chapters>0` | **PASS** | `catalog_last`=`chapters=2 first=第一章 陨落的天才`；probe `chapterCount=2`；UI=`返回`+`第一章 陨落的天才`；无「上架感言」。`v_b82_doupo_cold*` |
| G3 | 用户可见无「Legado」品牌字 | **PASS** | 导入 Alert=`导入 1 个书源`；站点栏=`书源`；管理页 title=`书源管理`（`v_b82_after_import*` / `v_b82_sites*` / `v_b82_source_manager*`） |
| G6 | 底栏图标工具栏干净截图 | **FAIL** | `toolBarBottom` **非 nil**（`G6 afterCreate … bottom=UIView`；`g6_toolBarBottom_non_nil=PASS`），但中点后仍只有顶栏「返回」+章题，无「目录/字号/主题」。多点位/双击均无底栏。证：`v_b82_g6_toolbar_*` / `v_b82_probe_*` / `accept_ui_restore_b82ef6e.json` / `g6_trace_grep_b82ef6e.txt` |
| A | 阅读壳仍为宿主 | 保持 | 冷开章题「返回」+「第一章 陨落的天才」 |

对照上一包 `27c1ed6`：G2/G3 仍 PASS；G6 从「createToolbar 后 bottom 可能仍缺」推进到「bottom 已建成 + hide 正常」，卡点变为**中点未触发 `changeToolBar`**。

### 2.2 G2 探针（本轮）

`Documents/legado_catalog_body_probe.txt`：

- `toc=http://192.168.1.4:8766/book/doupo_toc.html`
- `bodyLen=270` / `ddApprox=2` / `hasListId=true`
- `chapterListRule=#list dd`
- `chapterCount=2`
- `first=第一章 陨落的天才`

`legado_catalog_last.txt`：`ok … chapters=2 first=第一章 陨落的天才`  
`legado_catalog_select.txt`：`title=第一章 陨落的天才`

### 2.3 G6 marker / trace（本轮）

关键行（`legado_openreader_trace.txt`）：

- `G6 createToolbar OK via=didAppear`
- `G6 afterCreate(didAppear) bottom=UIView header=UIView hidden=0 subviews=5`
- `G6 retrySkip_t0.8 bottom=UIView header=UIView hidden=1 …`（`hideToolBar` 后 `toolBarHidden=1`）
- `G6 retrySkip_t2.0 …` 同上
- **无** `changeToolBar` / midTap 相关行（中点未进原版切换）

`loadCurCp` 早于 create 的 ivar dump 仍可见 `toolBarFont/Theme/…=nil`（create 前快照，不代表 create 后仍空）。

### 2.4 截图/元数据索引（本轮 `b82ef6e`）

| 文件 | 含义 |
|---|---|
| `v_b82_shelf0*` | 冷启书架 |
| `v_b82_after_import*` | 导入 Alert（无 Legado） |
| `v_b82_sites*` / `v_b82_source_manager*` | 站点栏「书源」+「书源管理」 |
| `v_b82_doupo_cold*` | G2 PASS：冷开章题陨落的天才 |
| `v_b82_g6_toolbar_*` / `v_b82_probe_*` | G6 FAIL：中点/多点位无底栏图标 |
| `.test_tools/mcp-evidence/accept_ui_restore_b82ef6e.json` | 验收汇总 |
| `.test_tools/mcp-evidence/ipa_upload_b82ef6e.json` / `ipa_install_b82ef6e.json` / `ipa_manifest_b82ef6e.json` | 装包 |
| `.test_tools/mcp-evidence/g6_trace_grep_b82ef6e.txt` | G6 trace grep |

## 3. 本轮代码状态

`b82ef6e` 已装真机并验证：

1. `createToolbar` + ToolBarCreator 回退生效 → **`toolBarBottom` 非 nil**
2. `hideToolBar` 后 `toolBarHidden=1`
3. G2/G3 不回归（PASS）
4. G6 仍 FAIL：中点不唤出底栏（原版 `changeToolBar` / `onTapGestureEvent:` 未跑到）

### 已改待 commit（G6 中点 → changeToolBar）

**文件**：`LegadoBridge/Sources/LegadoBridgeHooks/LegadoBridgeCExports.m`

**新发现（`b82ef6e` 真机）**：

1. 底栏容器已建成，问题不在「createToolbar 未调 / bottom=nil」
2. 中点/双击/多点位 UI 不变 → 手势链未进 `changeToolBar`
3. `ReadVCBase2` 有 `-changeToolBar` / `-onTapGestureEvent:`（dump 旧稿；未 launch Reader0）

**改动（工作区，未进真机包）**：

1. Hook `ReadVCBase2.changeToolBar` 打 trace（`G6 changeToolBar enter` + after 状态，含 bottom frame/hidden/alpha/sub）
2. `LBG6InstallMidTapToggle`：中区 1/3 宽点击 → `changeToolBar`（防抖 0.2s；挂 reader.view + Scroll/Page 子视图；`simultaneous=YES`）
3. `didAppear` ensure 后安装上述手势

**真机复验**：需 commit → CI Debug IPA → 只装 `com.appbox.StandarReader` → 中点截底栏并可点一项；回归 G2/G3；看 trace 是否有 `G6 midTap -> changeToolBar` / `afterChangeToolBar`。

未改计划文件 status。未 commit。未 push。未 launch `StandarReader0`。未重启 SpringBoard。

## 4. 须大脑批准（例外 / 高风险）— 只列不擅自做

| 项 | 原因 |
|---|---|
| 用原版 `BookDetailController` / Catalog 链替换 `LBLegadoCatalogListVC` | 历史：push/setDicBook 无 ips 回桌面；属新私有生命周期，硬规则 2 |
| 调用/改写 `ToolBarCreator` / `TextReadSettingVC` / `changeToolBar` 私有 API | **G6 底栏：大脑已批**仅限 nativeRead 阅读页唤出底栏；本轮在 create/hide/ToolBarCreator 之外补中区→`changeToolBar` |
| 用原版 `BookSourceManager*` 替换 `LBLegadoSourceManagerVC` | 原生站点模型与协议源并存，易污染宿主源列表 |
| 导入改成完整香色原生表单页（非 Alert） | 需宿主 VC/私有入口或大改 UI，超出文案级还原 |
| Release 隐藏 Hook 能力区 | 影响排障；是否出货可见需产品拍板 |
| 搜索 `typeTitle` 从 `@"Legado"` 再改语义 | 与 `BookSearchController` 行为相关，乱改可能丢结果 |
| 删 `legado://login?mode=alert` | 调试旁路；默认已是 WebView |
| 清空/重写用户机上 `xsfolder/斗破苍穹_天蚕土豆` 污染数据 | 属设备数据手术，非桥逻辑；是否做需另批 |

## 5. 完成定义（仍未宣称总 PASS）

1. mock 书：搜索 → 目录（章名正确、无串书）→ 点章 → 原版阅读；中点「菜单」出现原版底栏，截图命中正文夹具字 — **冷开点章/章名 `b82ef6e` PASS；底栏 G6 仍 FAIL**。
2. 用户可见入口不再出现「Legado」品牌字（内部类名/日志可保留）— **G3 PASS**。
3. 不恢复 BookDetail 杀进程路径。
4. 本阶段 **不** 开全能书源总验收。

## 6. 下一步可执行

1. **commit G6 中点→changeToolBar 补丁 → CI Debug IPA → 只装 StandarReader → 复验 G6 + G2/G3**。
2. 若 midTap 已进 `changeToolBar` 仍无图标：查 `afterChangeToolBar` 的 bottom frame/sub，必要时再补 `arrToolBarBtn` / ToolBarCreator 子栏。
3. 可选：干净正文夹具字 OCR 断言（完成定义第 1 条后半）。
4. 例外项：BookDetail / 书源管理整页等仍勿擅自做。

修订：2026-07-26（`b82ef6e` G6：bottom 非 nil 仍 FAIL；中点未触发 changeToolBar；已补 midTap 手势待 commit；禁 Reader0 / 禁 SpringBoard 重启）
