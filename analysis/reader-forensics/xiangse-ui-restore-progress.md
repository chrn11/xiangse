# 香色原生样式还原（xiangse-ui-restore）进度

日期：2026-07-26  
设备包：`7805520` / run `30184559239` / variant `legado-debug`（已装真机，manifest 一致）  
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

## 2. 真机验收（包 `7805520` / run `30184559239`）

### 2.0 装包身份

- IPA：`.test_tools/ci-ipa-30184559239/dist/StandarReader-legado-bridge-debug.ipa`
- SHA256：`E5B1171F22A11256F170F052269D8ECDAFD5BE8C750E3317D7DC923BE2688C65`
- artifact：`LegadoBridge-IPA-Debug`
- `reader-build-manifest.json`：`git_commit=78055207da9e…`，`github_run_id=30184559239`，`variant=legado-debug` → **PASS**
- 只装 `com.appbox.StandarReader`；未碰 `StandarReader0`；未重启 SpringBoard
- 子代理 [装 7805520 验 G6 唤出](2b1376b1-0877-4904-9db7-3dffc85c1e6b) 因额度失败；父代理接手装包+验收

### 2.1 验收表（诚实）

| ID | 项 | 结果 | 证据 |
|---|---|---|---|
| G2 | 冷开无错误目录缓存：不得「上架感言」，期望「第一章 陨落的天才」，`chapters>0` | **PASS** | `catalog_last`=`chapters=2 first=第一章 陨落的天才`；probe `chapterCount=2`；UI=`返回`+`第一章 陨落的天才`。`v_780_doupo_cold*` |
| G3 | 用户可见无「Legado」品牌字 | **PASS** | 导入 Alert=`导入 1 个书源`；站点栏=`书源`；管理页 title=`书源管理` |
| G6 | 底栏图标工具栏干净截图 | **PARTIAL / 仍 FAIL** | 见下节 |
| A | 阅读壳仍为宿主 | 保持 | 冷开章题「返回」+「第一章 陨落的天才」 |

### 2.2 G6 分项（相对 `b82ef6e`）

| 分项 | 结果 | 证据 |
|---|---|---|
| midTap → `changeToolBar` | **PASS** | trace：`G6 midTap -> changeToolBar` / `G6 changeToolBar enter` / `G6 afterChangeToolBar` |
| `toolBarBottom` 非 nil + 显隐 | **PASS** | 显示时 `frame={{0,756},{390,88}} hidden=0 sub=6`；隐藏时 `y=844` + `toolBarHidden=1` |
| 底栏可见章导航 | **PASS** | 截图 `v_780_g6_*`：`上一章` / 滑块 / `下一章`；顶栏听书/书签/更多 |
| 目录/字号/主题图标行 | **FAIL** | 截图无 mulu/zihao 图标行；AX 无「目录/字号/主题」文案（原版本就是图标无障碍名，资源 `mulu@2x`/`zihao@2x` **在包内存在**） |
| 可点一项开面板 | **FAIL（按原门禁）** | 顶栏「更多」可开菜单（书籍详情/站点登录/翻页区域…）；底栏坐标扫未出字号/主题面板。验收脚本关键字仍判 FAIL |

对照 `b82ef6e`：卡点从「中点未进 changeToolBar」推进到「中点已通、章导航底栏已显，缺 mulu/zihao 图标行 / `arrToolBarBtn` 内容待钉」。

### 2.3 G6 marker / trace（本轮）

- `G6 createToolbar OK via=didAppear`
- `G6 afterCreate(didAppear) bottom=UIView … sub=6`
- `G6 midTap gesture installed hosts=1|2`
- `G6 midTap -> changeToolBar x=… y=…`
- `G6 changeToolBar enter` + `afterChangeToolBar … hidden=0|1`
- 资源：设备包 `dir_res/dir_readview/mulu@2x.png` / `zihao@2x.png` / `fanye@2x.png` 均在

### 2.4 证据路径

| 路径 | 说明 |
|---|---|
| `fixtures/_devkit/ui_restore/v_780_*` | 截图/meta |
| `.test_tools/mcp-evidence/g6_trace_grep_7805520.txt` | G6 trace |
| `.test_tools/mcp-evidence/g6_icon_scan_7805520.json` | 底栏坐标扫描 |
| `.test_tools/accept_ui_restore_7805520.py` | 验收脚本（关键字仍偏「目录/字号/主题」文案） |

## 3. 根因链（更新）

1. nativeFull 旁路 `createToolbar` → 已补（更早包）
2. `toolBarBottom` nil → ToolBarCreator 回退（`b82ef6e`）
3. 中点不进 `changeToolBar` → midTap 手势（`7805520`）**已 PASS**
4. **当前**：底栏只有章导航（上一章/滑块/下一章），缺 `mulu`/`zihao` 等图标按钮行；二进制有 `arrToolBarBtn` / `showToolBarFont` / `showToolBarTheme` / `onToolBarEvent:`；下一步 dump bottom 子视图 + `arrToolBarBtn` 再决定是否补建

## 4. `5caf570` dump 结论（已装 run `30185070965`）

- `bottomSubs`：**已有** `UIButton title=目录/缓存/设置/换源`（含 img 45×45），不是缺建
- `arrBtn=0`（ivar 空，按钮直接挂在 `toolBarBottom`）
- `toolBarPageSlider` 独立一层（上一章/滑块/下一章）
- 截图/AX/`tap_element` 仍看不到「目录」：`get_element_at_point(49,800)` 命中全屏 `AXElement`（加载层/正文层盖住底栏）
- 下一步：显示态 `bringSubviewToFront` 工具栏各层

## 5. 已改待进下一包

**文件**：`LegadoBridge/Sources/LegadoBridgeHooks/LegadoBridgeCExports.m`

- `LBG6LogToolbarState` 增强（已进 `5caf570`）
- **新增** `LBG6BringToolbarToFront`：`changeToolBar` 显示后把 header/pageSlider/bottom/left/right 提到最前（已批唤出底栏范围内）

未改计划文件 status。未 launch `StandarReader0`。未重启 SpringBoard。

## 6. 须大脑批准（例外 / 高风险）— 只列不擅自做

| 项 | 原因 |
|---|---|
| 用原版 `BookDetailController` / Catalog 链替换 `LBLegadoCatalogListVC` | 历史：push/setDicBook 无 ips 回桌面 |
| 调用/改写 `ToolBarCreator` / `TextReadSettingVC` / `changeToolBar` 私有 API | **G6 底栏：大脑已批**唤出底栏；`bringToFront` 属同范围 |
| 用原版 `BookSourceManager*` 替换 `LBLegadoSourceManagerVC` | 易污染宿主源列表 |
| Release 隐藏 Hook 能力区 | 需产品拍板 |

## 7. 下一刀

1. **对比度**：`74ff1fe` bringToFront 已跑（`bringToolbarFront n=5`），但底栏图标区像素仍近纯黑 `(22,22,22)`，章导航 `(55,55,55)` 可见 → 判深色图/字画在深色底；补 `LBG6ForceToolbarButtonContrast` + `resetToolBarBtnStatus`
2. 验收关键字改为「目录/缓存/设置/换源」
3. 顺手查「章节加载中」卡住（mock 200，可能时序）

修订：2026-07-26（`74ff1fe` bringToFront 无效于可见性；对比度修复待进包）
