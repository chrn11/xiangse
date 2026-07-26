# 香色原生样式还原（xiangse-ui-restore）进度

日期：2026-07-26  
设备包：`2f50f81` / run `30185697330` / variant `legado-debug`（已装真机，全量 PASS）  
真机证据目录：`fixtures/_devkit/ui_restore/`（gitignore，不入库）  
对照矩阵旧稿：`xiangse-ui-restore-matrix.md`

## 1. 本阶段「样式还原」指什么

计划最终目的句：点章后看到的是**香色原版阅读 UI**（分页/滚动/字体/排版/缓存/进度），协议只做书源后端。

| 块 | 原版承载体 | Bridge 现状 | 还原目标 |
|---|---|---|---|
| A. 阅读页工具栏/触区 | `TextReadVC3` + `ToolBarCreator` | `legado://nativeRead` 进原版 VC | 点章后工具栏/触区与本地书一致 |
| B. 字体/主题/排版 | `TextReadSettingVC` | 原版设置页 | 原版面板可用 |
| C. 目录 | 原版 Catalog 链 | `LBLegadoCatalogListVC` 自建 | 可点章 |
| D. 搜索/发现 | 宿主搜索 UI | 结果注入 | 像香色搜索 |
| E. 书源管理/导入 | 站点管理 + Bridge | Alert 导入 +「书源」按钮 | 无 Legado 文案 |

登录 / browserAwait 在延后总验备忘，不纳入本阶段主缺口。

## 2. 真机验收（包 `2f50f81` / run `30185697330`）— 全量 PASS

### 2.0 装包身份

- IPA：`.test_tools/ci-ipa-30185697330/dist/StandarReader-legado-bridge-debug.ipa`
- `git_commit=2f50f81…`，`github_run_id=30185697330`，`variant=legado-debug`
- 只装 `com.appbox.StandarReader`；未碰 Reader0；未重启 SpringBoard

### 2.1 验收表

| ID | 项 | 结果 | 证据 |
|---|---|---|---|
| G2 | 冷开「第一章 陨落的天才」，`chapters=2`，无「上架感言」 | **PASS** | `v_2f50_doupo_cold*`；目录两章 |
| G3 | 用户可见无「Legado」 | **PASS** | 导入/站点/书源管理 |
| G6 | 中点「目录/缓存/设置/换源」可见可点 | **PASS** | `v_2f50_toolbar_try`；点目录/设置 |
| A | 阅读壳仍为宿主 | 保持 | — |

报告：`.test_tools/mcp-evidence/accept_ui_restore_2f50f81.json`  
脚本：`.test_tools/accept_ui_restore_2f50f81.py`

### 2.2 根因链（已闭合）

1. nativeFull 旁路 `createToolbar` → 补调  
2. `toolBarBottom` nil → ToolBarCreator 回退  
3. 中点不进 `changeToolBar` → midTap（`7805520`）  
4. 按钮已建但 `bottomWin.y=847` 屏外（屏高 844）→ reposition 上移 91pt（`2f50f81`）

## 3. 须大脑批准 — 只列不擅自做

| 项 | 原因 |
|---|---|
| 换回原版 BookDetail/Catalog 链 | 历史杀进程 |
| 大改 ToolBarCreator / TextReadSettingVC | 已批范围仅唤出底栏 |
| 换原版书源管理页 | 易污染宿主源列表 |
| Release 隐藏 Hook 区 | 需产品拍板 |

## 4. 下一刀

1. 「章节加载中」偶发卡住  
2. 收敛对比度强制（保留 reposition）  
3. 延后总验按备忘未开  

修订：2026-07-26（`2f50f81` G2/G3/G6 全量 PASS）
