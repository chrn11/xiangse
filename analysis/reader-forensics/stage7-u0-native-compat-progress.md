# 阶段七 U0：原生功能兼容回归（2026-07-26）

计划：`.cursor/plans/香色Legado书源原生呈现总计划_20260726.plan.md` §12.2 U0。  
终局：XBS + Legado JSON **双源并存**，一律香色原生 UI；硬规则 12；**U0 全 PASS 前禁止 U1**。

## 状态（勿误读）

**U0 未关闭。终局未达成。禁止称「全部完成」。**  
计划里几条文档/严验 todo 做完 ≠ U0 交付完成。下列待验/PENDING 仍在。

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
| F3 | **策略闭合** | 站点(3)；全量 aside |
| F4 | **PASS** | `verify_u0_f4/` |
| F5 | **PASS_ENTRY** | `f5_04_check.png` |
| F6 | 壳 OK；内容空归书源 | 不记 Hook FAIL |
| F7 | debug **PASS_NO_LEAK**；release **PASS_NO_LEAK**（OCR 弱，无拉丁泄漏词） | `u0-f7-release-SUMMARY.json` |
| P | **PASS** | search_last |

## 普查清单 N

| ID | 状态 | 证据 / 缺口 |
|---|---|---|
| N01 | **PASS** | JSON 深链 import |
| N02 | **PASS** | 深链搜索 |
| N03 | **PASS_ENTRY** | 检测站点入口 |
| N04 | **PASS** | mock 目录链 |
| N05 | **PASS** | mock 正文 |
| N06 | **PENDING** | TXT 已推 Documents，无稳定原生导入路径夹具（`u0-n06-SUMMARY.json`） |
| N07 | **PASS_PARTIAL** | 编辑入口+二次打开进度 OK；**未做破坏性增删**（`u0-n07-SUMMARY.json`） |
| N08 | **PASS** | 阅读设置 |
| N09 | **PENDING** | 分享面板未做完整夹具 |
| N10 | **PENDING** | 总计划例外（不开发 TTS） |
| N11 | **PENDING** | 云同步未测 |

## 门禁

- **禁止 U1**：U0 未全 PASS（N06/N09/N11、N07 完整增删、F6 内容等仍开放）。规则：`.cursor/rules/u0-gate-before-u1.mdc`。
- 日常站点(3)/mock；禁止当测试面恢复 900 站。
- 计划 todo 完成 ≠ 终局完成。

## 本夜真实结论（2026-07-27）

已推进：双源终局表述、F2 严验、F7 release 冒烟、N 可测项留证。  
**未完成**：U0 全 PASS、U1–U3、双源终局验收。下一步优先：N06 原生 TXT 导入路径取证、N07 可重建书库下的真增删、N09 分享。
