# 8.6 替换净化 — 真机进度

**日期**：2026-07-23  
**verdict**：PASS  
**commit**：`0045524`（全量 `0045524…`）  
**CI**：https://github.com/chrn11/xiangse/actions/runs/30007609961（success；含 Debug IPA）  
**真机包**：`D:\soft\xiangse\dist-ci\phase86\StandarReader-legado-bridge-debug-0045524.ipa`  
**manifest.git_commit**：以 `0045524` 为前缀

## 验收定义（计划 8.6）

源内 `ruleContent.replaceRegex` 在香色正文链路实际生效：广告/乱码被净；含净化规则源的**净化前后对照**（原文有广告针，dump/UI 无广告且正文针在）。禁假通过（空阅读器「无广告」不算）。

## 本轮结论

| 项 | 结果 |
|---|---|
| 单测 `testApplyReplaceRegexStripsAdBlock` | ✅（既有） |
| 夹具 `legado-purify-mock.json` / `legado-purify-min.json` | ✅ |
| 真机：原文含 `【广告】`/`XYZ999`，dump 无广告 | ✅ |
| 真机：dump 含萧炎/纳兰嫣然 + 阅读器非空 | ✅ |
| `legado_purify_debug.txt` 含 replaceRegex 且 afterHasAd=false | ✅ |
| `phase86_purify_accept` verdict | ✅ PASS |

## 根因与修复

1. **`pattern##` 空替换**：`RuleSplitter.splitTopLevel` 丢掉空段返回 nil，整串（含 `##`）被当地正则 → 永不匹配。修复：`applyReplaceRegex` 对空 replacement 单独切开。
2. **二次落盘**：`handleContentRequest` 在 `getContent` 后再应用一次 `replaceRegex`，并写 `Documents/legado_purify_debug.txt`。
3. **完整净化源含 login 字段**会导致「章节加载中」挂死；验收改用最小源 `legado-purify-min.json`（仅 content+replaceRegex）。
4. 独立 `doupo_purify` 书在换书/`keepTextRead` 下易灌错书；本轮门禁用已验证斗破章临时插广告针（脚本跑完恢复 `doupo_1.html`）。

## 产物

- `fixtures/_devkit/phase86_purify/report.json`（verdict=PASS）
- `dump_purify.txt` / `purify.png` / `chapter_before.html` / `purify_debug.txt`
- 验收脚本：`.test_tools/phase86_purify_accept.py`（gitignore）

## Bridge / SHA

- 未改计划文件。parity 整体未标 completed。
- 相关提交：`485ae77` → `06625ad` → `52da8f4` → **`0045524`**（本轮验收 SHA）。

## 是否可进 8.7

**是**（8.6 真机 PASS）。8.7 WebView 夹具已在，真机轮待开。
