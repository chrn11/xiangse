# 可见 WebView（香色规格）进度

**日期**：2026-07-25  
**目标**：`LCStandarConfig -openWebViewWithUrlStr:` → `LCControllerManager show:WebViewController_WK` → 人过盾/登录 → Cookie → CookieJar → 回原流程。  
**禁止**：把 `BackstageWebView` 当本项完成；禁止 Alert 当产品门禁；禁止控桌面浏览器；**禁止 FallbackWKWebView 单独当香色规格 PASS**。

## Mach-O 差分结论

| 项 | 证据 |
|---|---|
| `openWebViewWithUrlStr:` 实现类 | **`LCStandarConfig`**（实例方法，`v24@0:8@16`，imp `0x10002d090`） |
| 非实现位置 | AppDelegate / VC 树 / `WebViewController_WK` **均无**该选择子（故上轮 miss） |
| 体内转发 | `[LCControllerManager sharedInstance] show:@"WebViewController_WK" params:@{@"url": url} parent:nil showType:0` |
| `WebViewController_WK` | 继承 `WebViewController_Base`（`myWebView` / `loadUrl:` / `setUrl:`） |
| `loginWebView` | **`ReadVCBase1` ivar**（类型 `WebViewController_WK`），另有 `openLoginUrl`；不是全局开页入口 |

## 实现

| 项 | 说明 |
|---|---|
| `LBVisibleWebView.m` | 主路径 `[[LCStandarConfig alloc] init] openWebViewWithUrlStr:]`；日志 `path=XiangseOpenWebView hit class=…`；原生后从 `myWebView` WKCookieStore 回灌；Fallback 仅退路 |
| 验收门禁 | `_accept_phase88_visible_webview.py` **要求** `XiangseOpenWebView hit` + `class=` |

## 真机验收（`0267e5e` / CI `30139764504`）

- 脚本：`fixtures/_accept_phase88_visible_webview.py` → **PASS**
- 日志：`path=XiangseOpenWebView hit class=LCStandarConfig`
- UI：香色原生栏 `返回 | 刷新`（非 Fallback「完成/回灌Cookie」）
- 截图：`fixtures/_devkit/phase88_visible_webview/visible_wv_20260725T022027Z.png`
- `legado://login` → 起点：`hit class=LCStandarConfig url=https://www.qidian.com/all/`；截图 `qidian_login_native.png`（分类页 + App 引导弹层，**未**完成人机过盾后搜索复跑）
- Cookie：原生路径曾仅 NSHTTPCookieStorage 空抽；已补 WKCookieStore 回灌（待下一 IPA 复验 jar）
- **parity 勿 completed**；真实源搜索仍见 `real-source-e2e.md`（3/3 FAIL 未改）
