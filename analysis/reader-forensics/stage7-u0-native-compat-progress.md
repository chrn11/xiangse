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
| F2 | open_once 残留 | **PASS** | `verify_u0_f2_strict/SUMMARY.json`，`e685ff5`：阅读页与回书架后文件均不存在；trace 有 `diskOpenOnce cleared`；正文 `bodyLen=764` |
| F3 | 站点数据策略 | **策略闭合** | 日常站点(3)；全量 aside；禁 replace 保留 |
| F4 | 换源选择器 | **PASS** | `verify_u0_f4/` |
| F5 | 检测站点入口 | **PASS_ENTRY** | `verify_u0_cont/f5_04_check.png` |
| F6 | 发现页 | 壳 OK；内容空归书源 | 不记 Hook FAIL |
| F7 | 品牌/调试泄漏 | debug **PASS_NO_LEAK**；**release 待验** | 设置页冒烟 |
| P | 搜索 trace | **PASS** | `legado_search_last` enter/ok |

## 普查清单 N

| ID | 项 | 状态 | 证据 |
|---|---|---|---|
| N01 | 书源导入 | 待 N 冒烟刷新（JSON 深链） | |
| N02 | 搜索 | **PASS**（深链） | `verify_u0_cont/N02.json` |
| N03 | 检测站点 | **PASS_ENTRY**（同 F5） | |
| N04 | 目录 | 待 N 冒烟 | |
| N05 | 正文阅读 | mock 斗破链 PASS（同 R/F2） | |
| N06 | 本地 TXT | **PENDING** | 需夹具 |
| N07 | 书架增删与进度 | 列表可见 PASS；增删待测 | F1 |
| N08 | 阅读设置 | 待 N 冒烟 | |
| N09 | 分享导出 | **PENDING** | |
| N10 | AudioRead | **PENDING**（总计划例外不开发 TTS） | |
| N11 | 云同步 | **PENDING** | |

## 门禁

- **禁止 U1**：直至 F1–F7 + R/P + N 可测项全 PASS（PENDING 项须有登记理由，不得静默跳过）。
- 日常只用站点(3)/mock；禁止当测试面恢复全量 900 站。
- 真机收工：全部任务完成后 `press_power`；执行中不批量删文件。

## 本夜进展（2026-07-27）

1. 总计划第一节补强「双源并存」。
2. F2 修复：`pushSettle` / `readerLeave` / 多书架 VC `viewDidAppear` 清 open_once（`e685ff5`）。
3. F2 严验 PASS：`fixtures/_devkit/verify_u0_f2_strict/`。
4. 下一步：N 清单冒烟留证 → 更新本表 → 可做项耗尽后熄屏。
