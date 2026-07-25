# 香色原生样式还原（xiangse-ui-restore）进度

日期：2026-07-25  
设备包：`7cf8ccc` / run `30164112714` / variant `legado-release`  
工作区 HEAD：`f475a4b`（含本轮未发包改动）  
真机证据目录：`fixtures/_devkit/ui_restore/`（gitignore，不入库）  
对照矩阵旧稿：`xiangse-ui-restore-matrix.md`（2026-07-23，当时把「周边自建」标成阶段二完成；本阶段目标更严：用户可见面尽量不像「外挂 Legado」）

## 1. 本阶段「样式还原」指什么

计划最终目的句：点章后看到的是**香色原版阅读 UI**（分页/滚动/字体/排版/缓存/进度），协议只做书源后端。

可拆成五块：

| 块 | 原版承载体 | Bridge 现状 | 还原目标 |
|---|---|---|---|
| A. 阅读页工具栏/触区 | `TextReadVC3` + `ToolBarCreator` + `dir_res/dir_readview/*` | `legado://nativeRead` 进原版 VC | 点章后工具栏/触区与本地书一致 |
| B. 字体/主题/排版 | `TextReadSettingVC` + `dir_font` + theme_* 资源 | 原版设置页，未自建 | 原版面板可用，不另造 |
| C. 目录 | 原版 `BookDetail*` / Catalog 链 | `LBLegadoCatalogListVC` 自建列表（避开 BookDetail 杀进程） | 视觉接近宿主；功能可点章 |
| D. 搜索/发现列表 | 宿主搜索通知 / `LBApplySearchResultsToUI` | 结果注入宿主搜索 UI | 列表像香色搜索，不像外挂页 |
| E. 书源管理/导入 | 原版站点管理 + Bridge 入口 | `LBLegadoSourceManagerVC` + `UIAlert` 导入；站点栏「Legado」按钮 | 文案/入口不像外挂；管理页可读 |

登录 WebView / browserAwait 已在延后总验备忘里 PASS，**不纳入本阶段主缺口**（Alert 残留见例外清单）。

## 2. 真机对照结论（包 `7cf8ccc`）

### 2.1 已像香色（阅读内核侧）

- `legado://nativeRead` 后前台仍为 `com.appbox.StandarReader`，UI 含「返回 / 菜单 / 上一页 / 下一页 / 侧滑返回书架」——原版触区模型，不是 Bridge overlay。
- 误入触区「修改功能」弹窗（`reader_toolbar.jpg`）也是香色原版能力，说明阅读壳是宿主。
- **干净阅读页**（`reader_clean.jpg`）：黑顶栏「返回」+ 章题、纸质纹理底、正文缩进/行距——典型香色原版排版，非 Bridge 自绘页。
- 静态资源：`dir_res/dir_readview/`（mulu/zihao/theme_*/baitian/yejian…）仍在 App 包内，由原版工具栏消费。

**结论**：A/B 在「走 nativeFull」时**视觉与功能已由原版承载**；本阶段不是重画工具栏/字体主题，而是保证进阅读后不偏到自建页，并修周边串味与串书。

**同时**：`reader_clean` 章题仍是「上架感言」，而本次 `bookUrl` 是 mock `doupo.html` → **G2 串书在真机复现**，阅读壳对、章节数据错。

### 2.2 明确缺口（未 PASS）

| ID | 缺口 | 证据 | 优先级 |
|---|---|---|---|
| G1 | 自建目录页视觉简陋（系统 `UITableView` + 默认 cell） | 代码 `LBLegadoCatalogListVC`；矩阵已标 ⚠️ | P1 |
| G2 | 目录 pending **串书**：`doupo` 开章标题变成「上架感言」 | `legado_catalog_select.txt`：`book=.../doupo.html ... title=上架感言`；mock TOC 实际是「第一章 陨落的天才」 | P0 |
| G3 | 书源管理/导入/站点栏文案带「Legado」 | `LBLegadoSourceManagerVC` title；导入 Alert；`LBSourceListHooks` 栏按钮 `Legado`；足迹可见「Legado」 | P1 |
| G4 | 书源管理页暴露 Hook 能力区（开发感） | section0「Hook 能力…」 | P2 |
| G5 | 导入仍是系统 `UIAlertController`，非香色原生表单页 | `LBShowLegadoImportAlert` | P2 |
| G6 | 本轮未能稳定截到「底栏图标工具栏 + 正文 OCR」干净对照 | `reader0`/`reader_toolbar` 偏触区编辑态；搜索深链未把结果页推到前台（书架仍空） | P1 取证 |
| G7 | `8765` 当前是 browserAwait mock，正文 mock 需另起端口 | 本轮用 `192.168.1.4:8766` 起 `serve_local_mock.py` | 环境 |

### 2.3 截图/元数据索引

| 文件 | 含义 |
|---|---|
| `shelf0.jpg` | 空书架 |
| `after_import.jpg` | 导入 1 个书源 Alert |
| `reader0.jpg` / `reader_toolbar.jpg` | 原版触区/修改功能 |
| `*_meta.json` | OCR + UI 文案 |

## 3. 本轮已改代码（未发包，真机尚未验证新包）

不需例外批准：

1. **G2 串书**：`LBEnsurePendingCatalogForBook` / `lb_reloadFromPending` / push 目录 改为 **bookUrl 严格匹配**，不匹配则清空 pending。  
   文件：`LegadoBridgeCExports.m`
2. **G1 目录样式**：自动行高、分隔 inset、系统字号、disclosure、章数 header。  
   文件：`LegadoBridgeCExports.m`
3. **G3 文案去外挂感**：  
   - 管理页 title →「书源管理」  
   - 导入 Alert/成功/格式错误文案去掉「Legado」前缀  
   - 站点管理栏按钮「Legado」→「书源」  
   文件：`LBLegadoSourceManagerVC.m`、`LBImportHooks.m`、`LBSourceListHooks.m`

**未改计划文件 status。未 commit。**

## 4. 须大脑批准（例外 / 高风险）

| 项 | 原因 |
|---|---|
| 用原版 `BookDetailController` / Catalog 链替换 `LBLegadoCatalogListVC` | 历史：push/setDicBook 无 ips 回桌面；属新私有生命周期，硬规则 2 |
| 调用/改写 `ToolBarCreator` / `TextReadSettingVC` 私有 API | method-map 无 confirmed 门禁条目 |
| 用原版 `BookSourceManager*` 替换 `LBLegadoSourceManagerVC` | 原生站点模型与协议源并存，易污染宿主源列表 |
| 导入改成完整香色原生表单页（非 Alert） | 需宿主 VC/私有入口或大改 UI，超出文案级还原 |
| Release 隐藏 Hook 能力区 | 影响排障；是否出货可见需产品拍板 |
| 搜索 `typeTitle` 从 `@"Legado"` 再改语义 | `LBSourceListHooks` 注释写明与 `BookSearchController` 行为相关，乱改可能丢结果 |
| 删 `legado://login?mode=alert` | 调试旁路；默认已是 WebView，删除需确认无回归依赖 |

## 5. 完成定义（建议，未宣称 PASS）

1. mock 书：搜索 → 自建目录（章名正确、无串书）→ 点章 → 原版阅读；中点「菜单」出现原版底栏（目录/字号/主题等），截图 OCR 命中正文夹具字。  
2. 用户可见入口不再出现「Legado」品牌字（内部类名/日志可保留）。  
3. 不恢复 BookDetail 杀进程路径；若要换原版目录，须大脑批准 + 差分门禁。  
4. 本阶段 **不** 开全能书源总验收。

## 6. 下一步可执行

1. CI 打含本轮改动的 IPA → 装真机。  
2. 固定 mock 端口策略：`8765` browserAwait 与正文 mock 并存或文档约定双端口。  
3. 验收脚本：`nativeRead` → 断言章名 ≠ 串书；目录 header「共 N 章」；导入/管理文案无「Legado」。  
4. 补 G6：干净正文截图 + 底栏工具栏截图（对照本地 TXT 书）。  
5. 例外项保持清单，不擅自做。

修订：2026-07-25
