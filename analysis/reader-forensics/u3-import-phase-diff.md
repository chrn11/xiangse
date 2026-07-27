# U3 原版导入入口 — 相位差分

## 取证（2026-07-27）

| 项 | 结果 |
|---|---|
| 站点管理「导入」 | a11y 可见；点后界面无变化（5s 内仍 `站点(961)`） | 
| 「更多」 | 原生 sheet：新建/导出/反转/删除/重置/**检测站点** |
| UIAlert「书源导入」 | 仅桥接管理页 `+` / `LBShowLegadoImportAlert` |
| 候选宿主 | 二进制存在 `ConfigSourceModelSyncCon`；`sourceModelSyncUrl` / `configSyncUrl2.plist` |

证据：`u3-A-import-*.jpg`、`u3-B-more.jpg`、`u3-import-entry-SUMMARY.json`

## 实现（本轮）

- `LBLegadoPresentNativeImport`：push `ConfigSourceModelSyncCon`
- `LBLegadoShowImportAlert`：先原生 SyncCon，失败再 UIAlert
- 站点管理「导入」按钮改接到 `onNativeImportTapped`（同链）
- 回退：`Documents/legado_u3_force_alert.txt`

## 门禁

1. 点「导入」进入非 UIAlert 页（期望 SyncCon）
2. 返回仍在站点管理
3. `legado_u3_import.txt` 含 `OK push ConfigSourceModelSyncCon`
4. force_alert 时仍能出 UIAlert（抽验即可）
