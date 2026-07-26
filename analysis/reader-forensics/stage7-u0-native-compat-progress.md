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

- **U0-R（最高优先级）**：目录点章断链 — 代码已改 `LegadoBridgeCExports.m`（openOnce+chapterDone 无阅读展示时 reclaim；栈下 TextRead 时 pop 回；cellTap 探针）。**待 CI 装包复验**。
- F3/F4/F5：StandarReader0 对照取证或 TrollFools dumpagent（根因未定罪）
- 复现 N03 + 对照基线；写回归探针脚本
