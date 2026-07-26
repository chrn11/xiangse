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
| F3 | 原生站点 0 | **坐实**：注入包 `sourceModelList.xbs`≈12KB / `getUseSourceNames orig=3`；SR0≈22MB / 站点(960)。**根因修正**：MCP `stat` 注入包沙盒目录创建时间 = `Jul 25 15:05:48`（7/25 首次装注入包，沙盒新建；7/26 覆盖装保留旧沙盒）；拷回前 `.xbs.bak_u0f3`=12,124B，按 SR0 比例（22MB/960≈23KB/源）连 1 个原生站点都装不下，`strings` grep 常见源名 0 匹配——**注入包沙盒从未导入过 SR0 的 960 站点**，`.xbs` 一直只有 3 个 Legado 源。`NativeSourceInjector.invokeAddModels` 的 `replace=true` 是**替罪羊**（没东西可截断），此前"整表替换致原生站点归零"的根因是**误诊**。真正的 F3 修复 = 把 SR0 的 `.xbs` 拷进注入包（已做，现 22MB）。`aae202d` 的 `replace=false` + `if replace { continue }` 改动**虽基于误诊，但属正确的防御性改动**（`replace=true` 本身是危险设计，未来若导入 960 站点会截断），**保留不回滚**。`aae202d` 的 commit message 把 replace 当真凶是误诊表述，但代码改动方向正确 |
| F4 | 站点行点不动 | 仍待在「站点管理」列表上对原生行 / Legado 行分别测 tap/长按编辑；换源选择器上的失效是另一条路径 |

## U0-R（目录点章）复验摘要

**状态：PASS（2026-07-26 22:29 斗破苍穹真机，包 `1340b3c` legado-debug）**。

证据目录：`fixtures/_devkit/verify_u0_r_doupo/`（gitignore）。

| 步骤 | 结果 |
|---|---|
| 搜索→点「斗破苍穹」（排除 WebView/净化） | 目录「共 2 章 / 第一章 陨落的天才」`02_catalog.png` |
| 点「第一章 陨落的天才」 | `cellTap` + `didSelect … book=…/book/doupo.html … doupo_1.html` |
| 是否进阅读页 | **是**：`03_after_tap.png` 正文含「萧炎」与本地 mock 验收段；trace `openOnce commit` → `preferNativeFull` → `pushNativeFull visible` → `settle vis=1` |
| 排除项 | 非 openOnce 吞点；非书目点错行；非内容拉取失败 |

说明：无障碍树/`assert_text_present(萧炎)` 当时未暴露正文，脚本曾误标 `FAIL_STILL_ON_CATALOG`；以截图+OCR 为准纠正为 PASS（见 `SUMMARY.json`）。
