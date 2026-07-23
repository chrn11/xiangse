# 8.7 WebView / BackstageWebView — 进度

**日期**：2026-07-23  
**verdict**：进行中（待 CI Debug + 真机）  
**目标 SHA**：本轮 Bridge 修复提交后由 CI 产出  

## 验收定义（计划 8.7）

JS 重渲染源正文可抓取；门禁 = **BackstageWebView 轮证据**。禁假通过。

对照硬条件：
1. 裸 HTTP 源码**无**连续 `WEBVIEW_OK_MARKER`，且无静态 `#chaptercontent`
2. WebView/`webJs` 后阅读器 dump **有** `WEBVIEW_OK_MARKER` + `萧炎`
3. `Documents/legado_webview_debug.txt` 含 `path=BackstageWebView` 且 `hasMarker=true`

## Bridge 修复

`AnalyzeUrl.getResponseBody`：原先只把 `forceWebView` 传给 `getStrResponseAwait(useWebView:)`，但 `executeStrRequest` 判定是 `self.useWebView && useWebView`，而 `self.useWebView` 仍取自 URL 选项（默认 false）→ **永远不进 BackstageWebView**。  
修复：`analyzer.useWebView = forceWebView || analyzedUrl.webView`，并写 `legado_webview_debug.txt`。

## 夹具

- `fixtures/chapter/webview_challenge.html`（针拆段拼接）
- `fixtures/book/doupo_webview.html` + `doupo_webview_toc.html`
- `fixtures/legado-webview-min.json` / `legado-webview-mock.json`
- 搜索页增加「WebView 验收专书」
- 脚本：`.test_tools/phase87_webview_accept.py`（gitignore）

## 产物（真机后补）

- `fixtures/_devkit/phase87_webview/report.json`
- `dump_webview.txt` / `webview.png` / `webview_debug.txt` / `chapter_raw.html`
