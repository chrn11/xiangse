# 阶段七 U0：原生功能兼容回归（2026-07-26）

计划：`.cursor/plans/香色Legado书源原生呈现总计划_20260726.plan.md` §12.2 U0。  
终局：XBS + Legado JSON **双源并存**，一律香色原生 UI；硬规则 12；**U0 全 PASS 前禁止 U1**。

## 状态（勿误读）

**U0 未关闭终局。** 板子上多项已过，N06 仍 BLOCKED；终局（U1–U3 / 双源终验）未达成。禁止称「全部完成」。  
计划里几条文档/严验 todo 做完 ≠ 终局交付完成。

## 终局口径

- 香色原生 XBS 功能不被 Hook 破坏
- Legado JSON 书源及书源相关功能可用
- 呈现层全是香色原生 UI（非桥接页终态）
- 两套源同时正常、互不吞数据

## 对照基线

| 包 | 用途 |
|---|---|
| 未注入基线 / `StandarReader0` | 「坏没坏」对照 |
| `e685ff5` legado-debug / release（run `30210873340`） | 当前推进包 |

## F / R / P

| ID | 状态 | 证据 |
|---|---|---|
| R | **PASS** | `verify_u0_r_doupo/` |
| F1 | **PASS** | `verify_u0_f1_list/`，`773ee29` |
| F2 | **PASS** | `u0-f2-strict-SUMMARY.json`，`e685ff5` |
| F3 | **待 D 阶段** | 双源共存未实测；当前日常仍站点(3)；全量 aside 待 D2 恢复后验收。D4 未过不得开 U1 |
| F4 | **PASS** | `verify_u0_f4/` |
| F5 | **PASS_ENTRY** | `f5_04_check.png`；早间 `u0-desc-nav-SUMMARY.json` 复证检测站点 |
| F6 | 壳 OK；内容空归书源 | 不记 Hook FAIL |
| F7 | debug **PASS_NO_LEAK**；release **PASS_NO_LEAK**（OCR 弱，无拉丁泄漏词） | `u0-f7-release-SUMMARY.json` |
| P | **PASS** | search_last |

## 普查清单 N

| ID | 状态 | 证据 / 缺口 |
|---|---|---|
| N01 | **PASS** | JSON 深链 import |
| N02 | **PASS** | 深链搜索 |
| N03 | **PASS_ENTRY** | 检测站点入口；早间复证 `检测站点(3)`+开始 |
| N04 | **PASS** | mock 目录链 |
| N05 | **PASS** | mock 正文 |
| N06 | **BLOCKED→修中** | MCP `open_file_with_app` 只拷 Inbox；`uiopen`/`file://`/`objc_invoke`(无 dumpagent) 均不投递。**自动化解法**：Bridge 已加 `legado://nativeOpenFile?path=`（`LBImportHooks.m`），装新包后用 MCP `open_url` 自测（`.test_tools/verify_u0_n06_deeplink.py`）。**不再甩人工 Open In** |
| N07 | **PASS**（可销毁书增删，UI 元素判定） | `u0-n07-crud-SUMMARY.json` |
| N08 | **PASS** | 阅读设置 |
| N09 | **PASS** | 站点管理→更多→导出站点 → 系统分享板（`sourceModelList` 12KB，隔空投送/拷贝）。`u0-n09-SUMMARY.json`、`u0-n09f-after-export.png`。旧「微信」PASS 作废（导入说明假阳性） |
| N10 | **PENDING** | 总计划例外（不开发 TTS） |
| N11 | **PASS_ENTRY** | 整理→云备份入口可达；无账号夹具不做完整同步。`u0-n11-SUMMARY.json` |

## 双源 UI（U0 旁证，非 U1）

| 项 | 状态 | 证据 |
|---|---|---|
| 原生站点页 | **PASS** | `站点(3)` + 本地静态测试源/笔趣读/领域书库；`u0-dual-source-ui-SUMMARY.json`、`u0-dual-site-mgr.png` |
| Legado 搜索 | **PASS** | search_last 仍通 |

导航必须以 `describe_screen.rect` / `tap_screen` 点「整理」；`tap_element` 常假成功。

## 门禁

- **U0 门禁**：以本板 F/R/P/N 表为准；N06 仍 BLOCKED（有根因）；N09 PASS；N10 PENDING；N11 PASS_ENTRY。未显式批准前禁止 U1。
- **D4 前置**：双源共存验收（计划 `双源共存到终局` D4）未过，不得开 U1。
- **仍禁止宣称终局完成**；U1 启动须另开任务并显式确认。
- 日常站点(3)/mock；禁止当测试面恢复 900 站。**双源终验期间显式破例**恢复全量，验完可切回三源测试面。

## 本晨结论（2026-07-27）

已推进：N09 真分享板 PASS；双源站点页 PASS；N11 云备份入口 PASS_ENTRY。  
**N06**：不甩人工 Open In。MCP 已证实 `open_file_with_app`/uiopen/objc 均缺投递；Bridge 已实现 `legado://nativeOpenFile?path=`（待 commit→CI→装包→`verify_u0_n06_deeplink.py`）。  
**未完成**：终局 U1–U3；N06 新包装机验收；N10 TTS 例外。
