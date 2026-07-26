# 阶段七 U0：原生功能兼容回归（2026-07-26）

计划：`.cursor/plans/香色Legado书源原生呈现总计划_20260726.plan.md` §12.2 U0。  
终局：XBS + Legado JSON **双源并存**，一律香色原生 UI；硬规则 12；**U0 全 PASS 前禁止 U1**。

## 终局口径（2026-07-27 对齐）

- 香色原生 XBS 功能不被 Hook 破坏
- Legado JSON 书源及书源相关功能可用
- 呈现层全是香色原生 UI（非桥接页终态）
- 两套源同时正常、互不吞数据

## 对照基线

| 包 | 用途 |
|---|---|
| 未注入基线 / `StandarReader0` | 「坏没坏」对照 |
| 当前注入包 `e685ff5` legado-debug（run `30210873340`） | U0 推进中 |

## F / R / P 缺陷板

| ID | 项 | 状态 | 证据 |
|---|---|---|---|
| R | 斗破目录点章 | **PASS** | `verify_u0_r_doupo/`，`1340b3c` |
| F1 | 书架列表模式空 | **PASS** | `verify_u0_f1_list/`，`773ee29` |
| F2 | open_once 残留 | **PASS** | `analysis/reader-forensics/u0-f2-strict-SUMMARY.json`，`e685ff5`：阅读/回书架后文件均不存在；`diskOpenOnce cleared`；`bodyLen=764` |
| F3 | 站点数据策略 | **策略闭合** | 日常站点(3)；全量 aside；禁 replace 保留 |
| F4 | 换源选择器 | **PASS** | `verify_u0_f4/` |
| F5 | 检测站点入口 | **PASS_ENTRY** | `verify_u0_cont/f5_04_check.png` |
| F6 | 发现页 | 壳 OK；内容空归书源 | 不记 Hook FAIL |
| F7 | 品牌/调试泄漏 | debug **PASS_NO_LEAK**；**release 待验** | N 冒烟设置页 |
| P | 搜索 trace | **PASS** | `legado_search_last` enter/ok |

## 普查清单 N

| ID | 项 | 状态 | 证据 |
|---|---|---|---|
| N01 | 书源导入（Legado JSON 深链） | **PASS** | `u0-n-smoke-SUMMARY.json` / REPROBE |
| N02 | 搜索 | **PASS** | 深链 + search_last |
| N03 | 检测站点 | **PASS_ENTRY** | 本夜复核 + f5 图 |
| N04 | 目录 | **PASS** | mock 链 trace |
| N05 | 正文阅读 | **PASS** | mock 斗破 / F2 bodyLen |
| N06 | 本地 TXT | **PENDING** | 需本地文件夹具 |
| N07 | 书架增删与进度 | 列表 **PASS**（F1）；增删 **PENDING** | |
| N08 | 阅读设置 | **PASS** | 无品牌泄漏 |
| N09 | 分享导出 | **PENDING** | |
| N10 | AudioRead | **PENDING** | 总计划例外不开发 TTS |
| N11 | 云同步 | **PENDING** | |

## 门禁

- **禁止 U1**：U0 未全 PASS（F7 release 待验；N06/N09/N10/N11、N07 增删 PENDING）。规则：`.cursor/rules/u0-gate-before-u1.mdc`。
- 日常只用站点(3)/mock；禁止当测试面恢复全量 900 站。
- 真机收工：全部任务完成后 `press_power`；执行中不批量删文件。

## 本夜进展（2026-07-27）

1. 总计划第一节补强「双源并存」。
2. F2 修复并严验 **PASS**（`e685ff5` / `30210873340`）。
3. N 冒烟+复核：可测项有证据；PENDING 已登记。
4. **U0 尚未全 PASS → 不得开工 U1**。
5. 本回合可做项完成 → 熄屏。
