# U0 取证：StandarReader0 对照「站点管理 / 检测站点」（2026-07-26）

包：`1340b3c` / run `30204398092` legado-debug vs 已购 `com.appbox.StandarReader0`。  
证据目录：`fixtures/_devkit/forensics_sr0_sites/`（gitignore）。

## 入口（两边都有）

| 步骤 | SR0 | 注入包 |
|---|---|---|
| 整理侧栏 | 有「站点管理」 | 有「站点管理」 |
| 站点管理页 | `站点(960)` + 大量原生 XBS | `站点(3)` 仅 Legado 三源 |
| 更多菜单 | 含「检测站点」 | 含「检测站点」 |

路径：**书架 → 整理 → 站点管理 → 更多 → 检测站点**。

此前「入口没了」不成立：入口在原生整理侧栏，不在换源选择器 / Bridge「书源管理」页。用户在错误界面找，才会判 F5。

## 宿主类

`find_class_for_selector(onSourceCheckEvent)` → **`ConfigSourceModelListCon`**（instance）。  
与 `LBSourceListHooks` 已 hook 的类名一致。dumpagent 在 SR0 上 stale（未注 mcp-dumpagent），但不妨碍 UI 对照定罪。

## 缺陷重定性

| ID | 旧说法 | 取证后 |
|---|---|---|
| F5 | 检测站点入口不可达 | **入口存在**；须走 整理→站点管理→更多。体验问题改为「文档/导航误导」或「更多菜单难发现」，不是 Hook 删入口 |
| F3 | 原生站点 0 | **坐实**：注入包站点管理只剩 3 个 Legado 源；SR0 约 960。根因指向站点列表数据被替换/过滤（`BookSourceModelManager` / `getGroupData` 嫌疑），非入口消失 |
| F4 | 站点行点不动 | 仍待在「站点管理」列表上对原生行 / Legado 行分别测 tap/长按编辑；换源选择器上的失效是另一条路径 |

## U0-R（目录点章）复验摘要

装 `1340b3c` Debug 后：UI 点章写 `legado_catalog_cell_tap.txt` + `legado_catalog_select.txt`，trace 有 `openOnce commit` / `preferNativeFull` / `pushNativeFull settle vis=1`。  
点章→进阅读页链路已通；部分书正文「章节加载中」属内容拉取/书目点错行，与 openOnce 吞点不同。
