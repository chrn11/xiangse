# 阶段七 U0：原生功能兼容回归（2026-07-26）

计划：`.cursor/plans/香色Legado书源原生呈现总计划_20260726.plan.md` §12.2 U0。  
终局：XBS + Legado JSON **双源并存**，一律香色原生 UI；硬规则 12；**U0 全 PASS 前禁止 U1**。

## 状态（勿误读）

**U0 仍未全 PASS。** D0–D3 与 N06 已过；D4 **PARTIAL**（表级双源 + Legado 链 + 检测抽样过；原生本地示例书打开会杀进程）。禁止称「全部完成」、禁止开 U1。

## 终局口径

- 香色原生 XBS 功能不被 Hook 破坏
- Legado JSON 书源及书源相关功能可用
- 呈现层全是香色原生 UI（非桥接页终态）
- 两套源同时正常、互不吞数据

## 对照基线

| 包 | 用途 |
|---|---|
| 未注入基线 / `StandarReader0` | 「坏没坏」对照 |
| `4c80bb8` legado-debug（run `30237844324`） | 当前推进包（D0 守卫 + nativeOpenFile） |

## F / R / P

| ID | 状态 | 证据 |
|---|---|---|
| R | **PASS** | `verify_u0_r_doupo/` |
| F1 | **PASS** | `verify_u0_f1_list/`，`773ee29` |
| F2 | **PASS** | `u0-f2-strict-SUMMARY.json`，`e685ff5` |
| F3 | **PASS（表级）** | D2/D3：五次冷启均 22659944；`站点(961)`+搜索可见三 Legado。`u0-d3-coldstart-SUMMARY.json`、`u0-d4-sites-SUMMARY.json` |
| F4 | **PASS** | `verify_u0_f4/` |
| F5 | **PASS_ENTRY→本轮升** | 检测站点入口 `检测站点(961)`+开始，抽样至 `10/961` 后停。`u0-d4-full-SUMMARY.json` |
| F6 | 壳 OK；内容空归书源 | 不记 Hook FAIL |
| F7 | debug **PASS_NO_LEAK**；release **PASS_NO_LEAK** | `u0-f7-release-SUMMARY.json` |
| P | **PASS** | search_last 今日复证 `ok total=50 sources=4` |

## 普查清单 N

| ID | 状态 | 证据 / 缺口 |
|---|---|---|
| N01 | **PASS** | JSON 深链 import |
| N02 | **PASS** | 深链搜索 |
| N03 | **PASS** | 本轮 `检测站点(961)`+开始抽样 `10/961` |
| N04 | **PASS** | mock 目录链 |
| N05 | **PASS** | mock 正文 |
| N06 | **PASS** | `legado://nativeOpenFile`→原生导入；书架有 `n06_deeplink_…, 新•第1章`。`u0-n06-deeplink-SUMMARY.json` |
| N07 | **PASS** | `u0-n07-crud-SUMMARY.json` |
| N08 | **PASS** | 阅读设置 |
| N09 | **PASS** | 站点导出分享板 |
| N10 | **PENDING** | 总计划例外（不开发 TTS） |
| N11 | **PASS_ENTRY** | 云备份入口 |

## 双源 / D4

| 项 | 状态 | 证据 |
|---|---|---|
| 原生站点页 | **PASS** | `站点(961)`；搜索可见三 Legado |
| 混合搜索 | **PASS** | `ok total=50 sources=4`；books 含「领域书库」等。`u0-d4-full-SUMMARY.json` |
| Legado 四步 | **PASS_ENTRY** | nativeRead 命中；目录 UI 有「第一章/第二章」；正文曾「章节加载中」（mock 8765 设备侧间歇断连）。`u0-d4-legado-*.png` |
| 检测站点抽样 | **PASS** | `10/961` 进行中可停。`u0-d4-check-*.png` |
| 原生本地书打开 | **FAIL（修中）** | A/B：961/三源均杀 → 非 jetsam。根因嫌疑：`LBLoadCurCpBridgeRegisterOrig` 启动即装 `LBABInstallProbes`（全局 `stringWithContentsOfFile` 等）+ Debug early wrap `loadCurCp`。已改：探针仅 Legado 命中再装；去掉 forensics early wrap loadCurCp。待新包复验。 |
| 表文件 | **PASS（终验）** | 终验面 aside `22659944`；日常测面 `12124`（三源） |

## 测面策略（性能）

- **日常开发/冒烟**：三源 `sourceModelList.xbs`≈12KB（`.test_tools/trim_to_3sites.py`）；水位 `hwm=11`
- **D4 终验 / 吞表验收**：再从 `sourceModelList.xbs.full_22m_aside` 恢复全量（`.test_tools/restore_full_xbs.py`）
- aside **勿删**（22659944）

## 门禁

- **U0 门禁**：D4 未全 PASS（原生本地书打开 FAIL）→ **禁止 U1**。
- **仍禁止宣称终局完成**。
- 当前真机：**日常三源测面**（非 961）；终验再恢复 aside。

## 本午结论（2026-07-27）

`4c80bb8` / CI `30237844324` 已装机。D0–D3、N06、混合搜索、检测抽样过。  
**阻塞**：打开「文本|小说示例」杀进程 → 已改 RegisterOrig / forensics，待 CI 新包装机复验。
