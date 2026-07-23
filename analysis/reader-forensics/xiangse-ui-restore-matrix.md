# 阶段二：香色原生界面还原清单

## 原则

阅读正文已由香色原版内核承载（`TextReadVC3` / `TextRPageContainer` / `TextRScrollContainer`）。书源周边界面尽量对齐香色 Tab/列表视觉；无法映射者列入例外。

## 还原矩阵状态（2026-07-23）

| 功能 | 承载体 | 状态 | 说明 |
|---|---|---|---|
| 阅读分页/滚动 | 原版阅读内核 | ✅ 已还原 | 6A/6B + scroll S5 |
| 搜索结果 | 香色搜索通知/`LBApplySearchResultsToUI` | ✅ 走宿主搜索 UI | 非 Legado 独立阅读器 |
| 目录 | `LBLegadoCatalogListVC` → 点章进原版阅读 | ⚠️ 目录列表为 Bridge 自建 | 点章后阅读页为原版 |
| 书源管理 | `LBLegadoSourceManagerVC` | ⚠️ Bridge 自建 | 提供导入/发现入口 |
| 发现 explore | 复用搜索结果通知 | ✅ 深链 `legado://explore` | 列表走搜索 UI |
| 登录 | `UIAlertController` 最小表单 | ⚠️ 系统弹窗 | 非香色自定义表单；阶段一可用 |
| 设置（净化/并发） | 书源 JSON 字段 | ✅ 源级配置 | 无独立设置页 |

## 例外（经 8.11 + 本阶段）

见 `legado-feature-exceptions.md`：评论、听书 TTS、封面解密、`bookVariable`。

## 阶段二完成定义（本轮达成）

1. 主阅读路径 100% 原版内核（已满足）。
2. 搜索/发现结果落入宿主搜索 UI（已满足）。
3. 自建目录/书源管理保留为书源协议入口，**不冒充原版阅读 UI**；登记为「周边入口自建、阅读内核原版」。
4. 登录用系统 Alert 作为过渡呈现，登记例外「非香色原生表单」。

修订：2026-07-23
