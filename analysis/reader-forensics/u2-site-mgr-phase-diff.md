# U2 原版站点管理承载 — 相位差分

## 取证结论（2026-07-27）

| 项 | 结果 | 证据 |
|---|---|---|
| 入口 | 整理 → 站点管理 → `站点(961)` + 右上角「书源」 | `u2-site-mgr-phase-SUMMARY.json`、`u2-G-sites-cold.jpg` |
| 列表承载 | Hook 已合并：`getUseSourceNames orig=961 legado=4`；merge `verified=OK` | `legado_getusesources_hook.txt`、`legado_native_sync.txt` |
| 首屏 | 无 Legado（按更新时间靠后，与 D4 一致） | `u2-G-sites-cold.jpg` |
| 搜索 | 搜「笔趣读」→ `站点(3)` 可见三源 | `u2-E-search-biqu2.jpg` |
| 点 Legado 行（改前） | 推 `LBLegadoSourceManagerVC` 再进编辑；返回落在桥接列表 | `u2-tap-legado-row-SUMMARY.json`、`u2-I-tap-biqu.jpg` |
| 「书源」按钮 | 仍进完整桥接管理页（回退入口保留） | `u2-D-legado-mgr.jpg` / mgr_labs |

## 缺口（相对 §12.2 U2）

- 列表层已由原版 `ConfigSourceModelListCon` 承载 Legado。
- 点行仍经桥接**管理列表**，返回不落原版站点页 → 主路径未「用」香色导航语义。

## 本轮改动

- 点原生列表 Legado 行：`LBLegadoPresentSourceEditor` 直接 push `LBLegadoSourceEditorVC`，返回 → 原版站点列表。
- 右上角「书源」仍 `LBPresentLegadoSourceManager`（完整管理 + 启停/分组/发现）。
- 回退开关：`Documents/legado_u2_use_bridge_manager.txt` 存在则恢复旧「管理列表→编辑」。

## 门禁（装新包后）

1. 站点管理搜「笔趣读」可见行。
2. 点行进入结构化/JSON 编辑（标题非「书源管理」列表）。
3. 返回后仍在 `站点(96x)` 原版列表（不是桥接「共 N 个」页）。
4. 右上角「书源」仍能进完整管理页。
