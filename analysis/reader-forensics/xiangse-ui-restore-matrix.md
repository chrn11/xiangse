# 阶段二：香色原生界面还原清单

> **2026-07-25**：下一阶段 `xiangse-ui-restore` 以更严标准推进，详见 [`xiangse-ui-restore-progress.md`](xiangse-ui-restore-progress.md)。下文为 2026-07-23 快照，**不代表本阶段已 PASS**。

## 原则

阅读正文已由香色原版内核承载（`TextReadVC3` / `TextRPageContainer` / `TextRScrollContainer`）。书源周边界面尽量对齐香色 Tab/列表视觉；无法映射者列入例外。

## 还原矩阵状态（2026-07-23）

| 功能 | 承载体 | 状态 | 说明 |
|---|---|---|---|
| 阅读分页/滚动 | 原版阅读内核 | ✅ 已还原 | 6A/6B + scroll S5 |
| 搜索结果 | 香色搜索通知/`LBApplySearchResultsToUI` | ✅ 走宿主搜索 UI | 非 Legado 独立阅读器 |
| 目录 | `LBLegadoCatalogListVC` → 点章进原版阅读 | ⚠️ 目录列表为 Bridge 自建 | 点章后阅读页为原版；2026-07-25 发现 pending 串书 |
| 书源管理 | `LBLegadoSourceManagerVC` | ⚠️ Bridge 自建 | 提供导入/发现入口；文案去「Legado」进行中 |
| 发现 explore | 复用搜索结果通知 | ✅ 深链 `legado://explore` | 列表走搜索 UI |
| 登录 | 可见 WebView（非 Alert） | ✅ 默认网页登录 | Alert 仅 `mode=alert` 旁路；见 phase88-login |
| 设置（净化/并发） | 书源 JSON 字段 | ✅ 源级配置 | 无独立设置页 |

## 例外（经 8.11 + 本阶段）

见 `legado-feature-exceptions.md`：评论、听书 TTS、封面解密、`bookVariable`。

## 阶段二完成定义（2026-07-23 口径；已被 progress 文档收紧）

1. 主阅读路径 100% 原版内核（已满足）。
2. 搜索/发现结果落入宿主搜索 UI（已满足）。
3. 自建目录/书源管理保留为书源协议入口，**不冒充原版阅读 UI**；登记为「周边入口自建、阅读内核原版」。
4. ~~登录用系统 Alert 作为过渡呈现~~ → 已改为香色 WebView（2026-07-25）。

修订：2026-07-25（仅交叉链接与状态注记；不改计划文件 status）
