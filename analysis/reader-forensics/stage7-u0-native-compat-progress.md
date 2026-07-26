# 阶段七 U0：原生功能兼容回归（2026-07-26）

计划：`.cursor/plans/香色Legado书源原生呈现总计划_20260726.plan.md` §12.2 U0。  
硬规则 12：Hook 不得破坏香色原生 XBS / 本地书等；清单全 PASS 前 U1 不得开工。

## 已确认症状

- 注入后原生「检测站点」不可用（`onSourceCheckEvent` → `ConfigSourceCheckVC`）
- 用户：其他功能可能也有问题，须全面普查，不许只修一点收工

## 对照基线

| 包 | 用途 |
|---|---|
| 未注入基线 IPA（同 2.56.1） | 「坏没坏」对照 |
| 当前注入包 `2c1cf80` Debug/Release | 缺陷复现 |

## 普查清单

| ID | 项 | 状态 | 证据 |
|---|---|---|---|
| N01 | XBS 书源导入 | 待测 | |
| N02 | XBS 搜索 | 待测 | |
| N03 | **检测站点** | **FAIL（用户报告）** | 待复现+根因 |
| N04 | XBS 目录 | 待测 | |
| N05 | XBS 正文阅读 | 待测 | |
| N06 | 本地 TXT 导入与阅读 | 待测 | |
| N07 | 书架增删与进度 | 待测 | |
| N08 | 阅读设置（字体/主题/翻页） | 待测 | |
| N09 | 分享导出 | 待测 | |
| N10 | AudioRead 听书 | 待测 | |
| N11 | 云同步（若有） | 待测 | |

## 可疑 Hook（先取证后定罪）

1. `LBSearchHooks` — `BookSourceManager`
2. `LBSourceListHooks` — `BookSourceModelManager` / 站点栏
3. `LBImportHooks` — `NSJSONSerialization`
4. `LegadoBridgeCExports.m` / `LBLoadCurCpBridge.m`

## 进行中

- **U0-R**：`1340b3c` 已推/已装。**状态：FAIL（首轮实测，目标书「斗破苍穹」）**——`u0-native-regression-0726.md` 第 49 行 R 行：点「第一章 陨落的天才」无反应，停留目录页。改了 `LegadoBridgeCExports.m`（reclaim + popToViewController + cell tap trace）后装 1340b3c Debug，会话记录称"链路代码路径通"（`cellTap`+`openOnce commit`+`preferNativeFull`+`pushNativeFull settle vis=1`），但**斗破上点章是否实际进阅读页——本地无落盘证据**（此前引用的 `report_r_final.json` / `report_r_pass.json` 经检索不存在，系误引）。须在斗破上真机重做验证并落盘。
- **F5**：对照 SR0 后作废「入口没了」——路径为 整理→站点管理→更多→检测站点（注入包同样有）。见 `u0-sr0-site-forensics.md`。
- **F3**：**根因修正**——`addModels replace=true` 是**替罪羊**（误诊）。MCP `stat` 注入包沙盒目录创建时间 = `Jul 25 15:05:48`（7/25 首次装注入包，沙盒新建；7/26 覆盖装保留旧沙盒）；拷回前 `.xbs.bak_u0f3`=12,124B，按 SR0 比例（22MB/960≈23KB/源）连 1 个原生站点都装不下，`strings` grep 常见源名 0 匹配——**注入包沙盒从未导入过 SR0 的 960 站点**，`.xbs` 一直只有 3 个 Legado 源。真正的 F3 修复 = 从 SR0 拷 `.xbs` 进注入包（已做，现 22MB，显示 站点(963)）。`aae202d` 的 `replace=false` + `if replace { continue }` 改动**虽基于误诊，但属正确的防御性改动**（`replace=true` 本身是危险设计，未来若导入 960 站点会截断），**保留不回滚**。
- F4：换源选择器行交互仍待测；F6 发现页随站点恢复后复测。
