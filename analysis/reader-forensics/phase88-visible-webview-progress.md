# 可见 WebView（香色规格）进度

**日期**：2026-07-25  
**目标**：`LCStandarConfig -openWebViewWithUrlStr:` → `LCControllerManager show:WebViewController_WK` → 人过盾/登录 → Cookie → CookieJar → 回原流程。  
**禁止**：把 `BackstageWebView` 当本项完成；禁止 Alert 当产品门禁；禁止控桌面浏览器；**禁止 FallbackWKWebView 单独当香色规格 PASS**。

## Mach-O 差分结论（本轮）

| 项 | 证据 |
|---|---|
| `openWebViewWithUrlStr:` 实现类 | **`LCStandarConfig`**（实例方法，`v24@0:8@16`，imp `0x10002d090`） |
| 非实现位置 | AppDelegate / VC 树 / `WebViewController_WK` **均无**该选择子（故上轮 miss） |
| 体内转发 | `[LCControllerManager sharedInstance] show:@"WebViewController_WK" params:@{@"url": url} parent:nil showType:0` |
| `WebViewController_WK` | 继承 `WebViewController_Base`（含 `loadUrl:` / `setUrl:` / `myWebView` WK） |
| `loginWebView` | **`ReadVCBase1` ivar**（类型 `WebViewController_WK`），另有 `openLoginUrl`；不是全局开页入口 |

解析命令：`tools/reader-forensics/parse_objc_method_map.py` + `__objc_classlist` 全量扫选择子。

## 实现（本轮修复）

| 项 | 说明 |
|---|---|
| `LBVisibleWebView.m` | **主路径** `[[LCStandarConfig alloc] init] openWebViewWithUrlStr:]`；日志 `path=XiangseOpenWebView hit class=…`；次路径 VC 扫描；再备份 `LCControllerManager show:`；最后才 Fallback WK |
| `legado://webview?url=` | 验收深链 |
| `legado://login` | 默认可见网页 |
| 验收门禁 | `_accept_phase88_visible_webview.py` **要求** `XiangseOpenWebView hit` + `class=`；Fallback-only = FAIL |

## 状态

- 上轮：`9b45997` / `5488a15` 真机可见页 PASS，但 **`path=FallbackWKWebView` + miss**（未达香色规格）
- 本轮：差分锁定 `LCStandarConfig`；代码已改；待 CI Debug IPA + 真机验收
- **parity 勿 completed**；真实源搜索仍见 `real-source-e2e.md`
