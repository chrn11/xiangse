# U1 原版 TXT 目录链同相位差分（2026-07-27）

包：`c9b9ae1` / CI `30240818802` · 真机全量双源面（22659944）

## 同相位操作

书架 → 打开「文本|小说示例」→ 中点唤出底栏 → 点「目录」

## 证据

| 相位 | 截图 | UI 锚点 |
|---|---|---|
| B 阅读 | `u1-phase-B-reader.jpg` | 「使用示例」「1/5」 |
| C 底栏 | `u1-phase-C-toolbar.jpg` | 上一章/下一章/目录/缓存/设置/换源 |
| D 目录 | `u1-phase-D-catalog.jpg` | **返回 / 目录|书签 / 到底部 / 搜索 /「1. 使用示例」** |

汇总：`u1-catalog-phase-diff-SUMMARY.json`

## 类归属（硬规则 2：同相位 + 仓库元数据，非字符串瞎猜）

| 结论 | 依据 |
|---|---|
| 本地书目录页是 **原版 Catalog 链**（非 `LBLegadoCatalogListVC`） | D 相位 UI：分段「目录\|书签」、右上「到底部」、搜索栏、编号章名——与自建目录页（纯 UITableView +「共 N 章」）形态不同 |
| `CatalogCon` 存在于 Reader 模块 | `open/.../Headers/Reader.h`、`objc-classes.txt` |
| `BookDetailController` / `BookDetailVCBase` / `BookDetailPannel` | `Headers/Other.h`；`BookDetailPannel` 有 `_catalogView` 属性（selectors 元数据） |
| `setArrCatalog:` / `loadCatalog:ignoringCache:` / `setDicBook:` | `objc-selectors.txt`；生产已 Hook：`CatalogCon#setArrCatalog:`、`LBApplyCatalogToUI` appear 冲刷 |
| **禁止**把 `BookDetailController` 推进导航栈 | 代码注释与历史真机：push + `setDicBook` → 无 ips 回 SpringBoard；隐藏实例仅可作写回 |

## U1 安全路径（confirmed 后才动生产）

1. **目标**：搜索点 Legado 书不再 push `LBLegadoCatalogListVC`，改为进入与本地书同构的原版目录 UI（`CatalogCon` / 阅读页内目录链）。
2. **手段**：复用已有 `sPendingCatalogChapters` + `CatalogCon viewDidAppear` 冲刷 + `setArrCatalog:` 守卫；桥接页保留为回退（§12.3-1/3）。
3. **禁区**：不要 `nav push BookDetailController` 作为主路径。
4. **门禁**：Legado 书目录截图须与本地书 `u1-phase-D-catalog.jpg` 同构（目录|书签/到底部/搜索）；点章进正文；杀进程则立即回退桥接页。

## 状态

取证相位 **PASS** → 进入 U1 开发（CatalogCon 承载，BookDetail 不上栈）。
