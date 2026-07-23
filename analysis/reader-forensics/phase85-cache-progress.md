# 8.5 缓存与页位 — 真机进度

**日期**：2026-07-23  
**verdict**：PASS  
**commit**：`7c82687`（全量 `7c8268743a942656d13edd3293e15a262bd35b6b`）  
**CI**：https://github.com/chrn11/xiangse/actions/runs/30003630299 （success；含 Debug IPA）  
**真机包**：`D:\soft\xiangse\dist-ci\phase8\dist\StandarReader-legado-bridge-debug.ipa`  
**旁路**：`StandarReader-legado-bridge-debug-7c82687.ipa`  
**manifest.git_commit**：`7c8268743a942656d13edd3293e15a262bd35b6b`

页位门禁此前在 `edf303c` 仍 FAIL；经 `32d3e36`→`7c82687` 系列修复后真机全量 PASS。

## 本轮已完成

| 项 | 结果 |
|---|---|
| 开读 online 萧炎/药老 | ✅ |
| xsfolder 缓存 | ✅（含斗破） |
| 停 mock 离线正文 | ✅ |
| 杀进程后页位（药老） | ✅ `restore_has_yaolao=true`，prekill/restore pageIdx=2 |
| SHA 门禁 | ✅ `7c82687` |
| `phase85_cache_accept.py` | ✅ verdict=PASS |

未改计划文件。parity 整体未标 completed（仅 8.5 过门，可进 8.6）。

## 真机 checks（`fixtures/_devkit/phase85_cache/report.json`，`7c82687`）

| check | 结果 |
|---|---|
| sha | true |
| online_xiaoyan / online_title / online_yaolao | true |
| xsfolder_has_cache | true |
| mock_down / offline_body / offline_no_error | true |
| offline_bookshelf_tap | false（非阻塞；正文已过） |
| prekill_yaolao | true（pageIdx=2） |
| restore_has_yaolao | **true**（pageIdx=2，preview 含药老） |
| restore_not_only_ch1_open | true |
| bookshelf_tap | false（书架点书未命中；nativeRead + 盘上页位恢复仍 PASS） |

## 根因与修复摘要

### A. `6afce46` online 挂死（`edf303c` 已修）

`LBCatalogCacheSafeKey` in-place 替换非 alnum 为 `_` 死循环 → 主线程卡死。改为逐字符重建。

### B. 杀进程后页位丢失（`32d3e36`…`7c82687`）

1. `goRecordAfterLoadCp` 在滚动容器上，冷开未注入页码；Bridge 强制滚动翻页。
2. 书架点书常失败，fallback `nativeRead idx=0` 会回到章首。
3. 修复：dump/resign 将可见 `cell.pageModel.nPageIndex` 落盘 `Documents/legado_page_progress.json`；同书已有 `page>0` 时拒绝被 `page=0` 覆盖；冷开写 `goRecordAfterLoadCp`，并用 `scrollToRow` + `setContentOffset` + 延长重试 / MarkRendered 后再补页，使 offset 真正稳住。

## 产物

- `fixtures/_devkit/phase85_cache/report.json`（verdict=PASS）
- dumps / 截图：同目录 `dump_*` / `*.png`

## 是否可进 8.6

**是** — `phase85_cache_accept` 全量 PASS（含 `restore_has_yaolao`）。书架 tap 仍 false，属体验缺口，不挡 8.5 门禁。

## Bridge / 脚本

- Bridge：`LBLoadCurCpBridge.m` / `LBDebugPanel.m`（页位落盘 + 恢复滚动）等，合入 `7c82687`。
- 验收脚本：本地 `.test_tools/phase85_cache_accept.py`（gitignore）；仅修语法/`#` 注释，未放宽断言。
