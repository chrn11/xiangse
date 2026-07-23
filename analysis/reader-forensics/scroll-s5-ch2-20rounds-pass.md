# scroll-S5 真机 PASS（切章真通过 + 20 轮）

- SHA：`b82d71f`（Debug IPA，CI `29986640816`）
- 时间：2026-07-23T09:02Z
- 报告：`fixtures/_devkit/scroll_s5/report.json`

## 门禁结果

| 项 | 结果 |
|---|---|
| 第一章 dump「萧炎」+ TextRScrollContainer | PASS |
| 竖滑 preview 变化 / 药老 | PASS |
| 切章 idx=1 标题「斗气大陆」 | PASS |
| 正文 preview「纳兰嫣然」或「斗气大陆」 | PASS |
| UI 无「请求错误」 | PASS |
| 非仅第一章残留 | PASS |
| 回 idx=0 | PASS |
| kill→launch→nativeRead **20/20** | PASS |

## 相对假通过的修正

- 生产：`LBSwitchNativeChapterInPlace`（同书换 idx，不二次 push）
- 门禁：正文 preview 必含第二章针；UI 禁「请求错误」；禁把错误页标题当 PASS
