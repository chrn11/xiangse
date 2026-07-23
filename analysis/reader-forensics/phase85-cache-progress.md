# 8.5 缓存与页位 — 真机进度

**日期**：2026-07-23  
**verdict**：FAIL（页位恢复未过；开读/离线正文已过）  
**commit**：`edf303c`（全量 `edf303cb94d1b58dfabfa6495fd59c08166ec2e9`）  
**CI**：https://github.com/chrn11/xiangse/actions/runs/30000222485 （success；含 `build-bridge-debug`）  
**真机包**：`D:\soft\xiangse\dist-ci\phase8\dist\StandarReader-legado-bridge-debug.ipa`  
**旁路**：`StandarReader-legado-bridge-debug-edf303c.ipa`  
**manifest.git_commit**：`edf303cb94d1b58dfabfa6495fd59c08166ec2e9`

上一坏包：`6afce46` / run `29999044970`（online 全 false，见下方根因）。

## 本轮已完成

| 项 | 结果 |
|---|---|
| 差分取证 `f6904f2...6afce46` | ✅ 单假设：`LBCatalogCacheSafeKey` 死循环 |
| 修复 commit + push | ✅ `edf303c` → `origin/main` |
| LegadoBridge CI | ✅ success `30000222485` |
| Debug IPA 下载 | ✅ 覆盖 `dist-ci/phase8/dist/` |
| SHA 门禁 | ✅ `checks.sha=true`（`edf303c`） |
| `phase85_cache_accept.py` | ❌ verdict=FAIL（仅 `restore_has_yaolao` 等页位门禁） |

未改计划文件 `.cursor/plans/原生阅读闭环重建_b9167d21.plan.md`。

## 真机 checks（`fixtures/_devkit/phase85_cache/report.json`）

| check | `6afce46` | `edf303c` |
|---|---|---|
| sha | true | true |
| online_xiaoyan | false | **true** |
| online_title | false | **true** |
| online_yaolao | false | **true** |
| xsfolder_has_cache | true（无斗破） | true（含 `斗破苍穹_天蚕土豆/0`） |
| mock_down | true | true |
| offline_body | false | **true** |
| offline_no_error | true | true |
| offline_bookshelf_tap | false | false |
| prekill_yaolao | false | **true**（pageIdx=1） |
| restore_has_yaolao | false | **false**（pageIdx=0，章首萧炎） |
| bookshelf_tap | — | false |

## 根因（证据）

### A. `6afce46` online 挂死（已修）

1. 真机最小复现：`legado_nativeread_openurl.txt` 已写，但 `legado_nativeread_request.txt` 永不出现；`legado_openreader_trace.txt` 无任何 `nativeRead*` 行；前台长期卡住后 UI 落 SpringBoard。
2. `6afce46` 在 `LBOpenNativeChapterAtIndex` 无条件调用 `LBEnsurePendingCatalogForBook` → `LBLoadCatalogCache` → `LBCatalogCacheSafeKey`。
3. 旧实现：in-place 把非 alnum 换成 `_`，而 `_` 仍非 alnum → **死循环**。任意含 `:/._` 的 bookUrl（全部 http URL）都会卡死主线程，故 `TextReadVC3 count=0`。
4. 修复：改为与 Swift 侧一致的逐字符重建（`edf303c`）。重跑后 online 萧炎/药老、停 mock 离线正文均 true。

### B. 仍 FAIL：杀进程后页位（药老）未恢复

1. prekill：`page_index=1`，preview 含「药老」。
2. kill 后书架点书失败（`bookshelf_tap=false`），fallback `nativeRead idx=0` → `page_index_restore=0`，preview 为章首「萧炎，萧家历史上…」。
3. 属 8.5「页位」子项，与 A 的目录 key 死循环无关；本轮未扩 scope 改 goRecord/nPageIndex。

## 产物

- `fixtures/_devkit/phase85_cache/report.json`
- dumps：`dump_online*.txt` / `dump_offline.txt` / `dump_restore.txt` / `dump_prekill.txt`
- 截图：`online0.png` / `offline.png` / `restore.png` / `prekill.png`
- 复现旁证：`fixtures/_devkit/phase85_repro/`

## 是否可进 8.6

**否** — `phase85_cache_accept` 仍 FAIL（`restore_has_yaolao=false`）。开读与离线正文已恢复，页位未过门禁。

## Bridge / 脚本

- Bridge：已改 `LegadoBridgeCExports.m`（`LBCatalogCacheSafeKey`）并入 `edf303c`。
- 验收脚本：本轮未改（非环境假阴；online/offline 已能判真）。
