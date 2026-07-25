# 可见 WebView（香色规格）进度

**日期**：2026-07-25  
**目标**：`WebViewController_WK` / `openWebViewWithUrlStr:` 打开网页 → 人过盾/登录 → Cookie → CookieJar → 回原流程。  
**禁止**：把 `BackstageWebView` 当本项完成；禁止 Alert 当产品门禁；禁止控桌面浏览器。

## 实现（本轮合入）

| 项 | 说明 |
|---|---|
| `LBVisibleWebView.m` | 优先遍历 VC/`AppDelegate` 调 `openWebViewWithUrlStr:`；尝试 `WebViewController_WK`；否则全屏 WKWebView 回退 |
| `legado://webview?url=` | 验收深链 |
| `legado://login` | **默认**走可见网页（`loginUrl` 或书源根站）；`mode=alert` 保留旧 UIAlert |
| `LegadoBridgeCore.saveCookieJarForUrl:cookieString:` | WK Cookie / 快照 → 内存 CookieJar + `legado_cookie_jar.txt` |
| 标记 | `legado_visible_webview_open.txt` / `legado_visible_webview.txt` |

## 验收

- 脚本：`fixtures/_accept_phase88_visible_webview.py`
- 产物：`fixtures/_devkit/phase88_visible_webview/`（gitignore）
- 门禁：打开标记 + `path=XiangseOpenWebView|FallbackWKWebView` + 截图为网页（非 Alert）+ 不得用 Backstage 证据冒充

## 状态

- 代码已合入；**真机截图须在含本改动的 IPA 安装后**再跑脚本。
- 合入前设备仍为旧包：login 仍可能是 Alert。
