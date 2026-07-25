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
| `LBVisibleWebView.m` | 主路径 `[[LCStandarConfig alloc] init] openWebViewWithUrlStr:]`；日志 `path=XiangseOpenWebView hit class=…`；原生后从 `myWebView` WKCookieStore 回灌；Fallback 仅退路；本轮补 `legado_cookie_dump.txt` |
| `CookieManager`（BridgeStubs） | **本轮**：内存 + `Documents/legado_cookie_store.json` 落盘（杀进程不丢） |
| `RuleWebBook` | **本轮**：搜索写 `legado_search_body_probe.txt`（`has_buid` / `has_res_book_item`） |
| 验收门禁 | `_accept_phase88_visible_webview.py` **要求** `XiangseOpenWebView hit` + `class=` |

## 真机验收

| SHA | 结果 |
|---|---|
| `0267e5e` / CI `30139764504` | **PASS** 原生 hit；截图原生栏；起点页可开 |
| `82df124` / CI `30140323556` | **PASS** 同上 + `WKCookieStore harvest done` + jar `save key=` |
| 本轮复跑（装包仍为 `82df124`） | 开页+回灌仍 PASS；**起点搜索 FAIL**（见下） |

### 起点搜索复跑（诚实 FAIL）

- 流程：先保证书源 → 原生打开 `loginUrl=/all/` → 同进程搜索（避免 kill 丢内存 Cookie）
- 结果：`ok total=0`；CSS `bookList` 对照同样 0
- `/so/` 在原生 WebView：**长期「进行中」**，未见结果列表，也未见可点的人机控件文案
- PC 无 Cookie：`/so/` → HTTP 202 + `var buid`
- **parity 勿 completed**；真实源仍 FAIL（`real-source-e2e.md`）

证据目录：`fixtures/_devkit/phase88_visible_webview/`（`qidian_cookie_search_v2.json`、`qidian_css_control.json`、`qidian_so_wait.json`、截图）
