# 8.7 WebView / BackstageWebView — 进度

**日期**：2026-07-23  
**verdict**：PASS（真导航）  
**SHA**：`10d89e3`（CI `30017896665`）  
**报告**：`fixtures/_devkit/phase87_webview/report.json`

## 验收定义（计划 8.7 + 硬性真导航）

JS 重渲染源正文可抓取；门禁 = **BackstageWebView 轮证据**。禁假通过。

对照硬条件（均已满足）：
1. 裸 HTTP 源码**无**连续 `WEBVIEW_OK_MARKER`，且无静态 `#chaptercontent`
2. WebView/`webJs` 后阅读器 dump **有** `WEBVIEW_OK_MARKER` + `萧炎`
3. `Documents/legado_webview_debug.txt`：`path=BackstageWebView`、`phase=done`、`hasMarker=true`
4. **真导航**：debug / didFinish 的 `url` 为章节 http(s)（含 `webview_challenge`），**非** `about:blank`
5. `legado_webview_load.txt`：`loadMode=urlRequest`；hop `htmlLen=0`

## 作废记录

| SHA | 路径 | 结论 |
|---|---|---|
| `1ec40dd` | URLSession 预取 HTML → `loadHTMLString(..., about:blank)` → webJs；didFinish `url=about:blank` | **作废** |

## 根因与修复链

1. **`forceWebView` 未写入 `analyzer.useWebView`** → 永不进 BWV（`a2674bd`）
2. **主线程 Task 继承 MainActor** 与 WK 回调互锁（`5096a56` / `1ec40dd` detached）
3. **错误捷径**（`ca3a2e9`/`1ec40dd`）：先 HTTP 再 `loadHTMLString(about:blank)` — 已否决
4. **通过路径**（`10d89e3`）：GET → `BackstageWebView` **`webView.load(URLRequest)`**；detached + main.async；POST 仍可带 html，但 base 用真实 URL、禁止强行 about:blank

## 真机证据摘要（`10d89e3`）

- `legado_webview_load.txt`：`loadMode=urlRequest url=http://192.168.1.4:8765/chapter/webview_challenge.html`
- `legado_webview_hop.txt`：`hop=detached_async`，`htmlLen=0`
- `legado_webview_didfinish.txt`：`didFinish url=http://192.168.1.4:8765/chapter/webview_challenge.html`
- `legado_webview_debug.txt`：`phase=done`，`url=http://192.168.1.4:8765/chapter/webview_challenge.html`，`hasMarker=true`，`hasXiaoyan=true`，`bodyLen=644`
- UI：非空阅读器标题「第一章 WebView 验收」

## 夹具

- `fixtures/chapter/webview_challenge.html`（针拆段拼接）
- `fixtures/book/doupo_webview.html` + `doupo_webview_toc.html`
- `fixtures/legado-webview-min.json`
- 脚本：`.test_tools/phase87_webview_accept.py`（强制非 about:blank + urlRequest）

## 产物

- `fixtures/_devkit/phase87_webview/report.json`（verdict=PASS）
- `dump_webview.txt` / `webview.png` / `webview_debug.txt` / `webview_didfinish.txt` / `webview_load.txt` / `chapter_raw.html`
