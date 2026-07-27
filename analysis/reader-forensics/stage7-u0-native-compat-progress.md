# 阶段七 U0：原生功能兼容回归（2026-07-26）

计划：`.cursor/plans/香色Legado书源原生呈现总计划_20260726.plan.md` §12.2 U0。  
终局：XBS + Legado JSON **双源并存**，一律香色原生 UI；硬规则 12；**U0 全 PASS 前禁止 U1**。

## 状态（勿误读）

**U0 阶段 D 已收口。** 当前包 `8a41b73` / CI `30241868842`；全量双源面。  
**U1 PASS**：搜索点书 → `CatalogCon`（1914 章）→ 点「第一章 陨落的天才」进原生阅读正文。证据 `u1-catalogcon-gate-SUMMARY.json`、`u1-chapter-tap-SUMMARY.json`、`u1-after-chapter-wait.jpg`。

## 终局口径

- 香色原生 XBS 功能不被 Hook 破坏
- Legado JSON 书源及书源相关功能可用
- 呈现层全是香色原生 UI（非桥接页终态）
- 两套源同时正常、互不吞数据

## 对照基线

| 包 | 用途 |
|---|---|
| 未注入基线 / `StandarReader0` | 「坏没坏」对照 |
| `8a41b73` legado-debug（run `30241868842`） | 当前推进包（U1：搜索点书优先 CatalogCon） |

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
| 原生本地书打开 | **PASS** | `c9b9ae1` 全量 22MB 面：点「文本\|小说示例」进程存活，UI「使用示例」「1/5」。根因：Debug forensics early wrap `viewDidLoad`（死前仅 `early before viewDidLoad TextReadVC3`）。`u0-d4-openbook-after-earlywrap-off-SUMMARY.json`、`u0-d4-openbook-PASS.jpg` |
| 表文件 | **PASS** | 全程/复验 `sourceModelList.xbs`=22659944；aside 保留 |

## 测面策略

- **双源终验面（计划 D2–D4）**：全量 22MB / `站点(96x)` + 三 Legado（aside 勿删）
- **日常冒烟**（计划允许验完切回）：`.test_tools/trim_to_3sites.py` → 12KB；恢复用 `.test_tools/restore_full_xbs.py`

## 门禁

- **U0 门禁**：本地书打开已过；开 U1 前再扫一眼 D4 清单无回退。
- **仍禁止宣称整包终局完成**（U1–U3 未开）。
- 当前真机：**双源终验面**（22659944）。

## 本午结论（2026-07-27）续

U1 **PASS**：`8a41b73` 搜索点书走 CatalogCon（禁 BookDetail 上栈），灌入 1914 章后点章进原生正文。

### U2（进行中）

- **取证**：原版 `ConfigSourceModelListCon` 已能搜到三 Legado；点行旧路径进桥接管理列表。见 `u2-site-mgr-phase-diff.md`。
- **实现**：点行改 `LBLegadoPresentSourceEditor`（返回落原版列表）；「书源」按钮保留完整管理页回退。
- **门禁**：待本轮 CI 装机后按 diff 文末 4 条验收；**U2 未 PASS 前不开 U3**。
- **U0 仍未宣称整包终局**（U2/U3 未过）。
