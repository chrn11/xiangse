# Release 回归 PASS（含滚动切章）

- SHA：`b82d71f`
- CI：`29986640816`
- IPA：`dist-ci/scroll_ch2_release/dist/StandarReader-legado-bridge.ipa`
- variant：`legado-release`，`legado_debug_sha256=null`，Frameworks 仅 `LegadoBridge`

## 真机 checks

| 项 | 结果 |
|---|---|
| IPA/设备无 LegadoBridgeDebug | PASS |
| 无 overlay92011 | PASS |
| scroll seed + invoke_loadCp OK | PASS |
| UI 第一章标题 | PASS |
| UI 第二章「斗气大陆」 | PASS |
| 无「请求错误」 | PASS |
| 回第一章 | PASS |

报告：`fixtures/_devkit/scroll_release/report.json`
