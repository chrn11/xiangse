# 真实书源端到端（2026-07-25）

**verdict**：FAIL（起点搜索仍 `ok total=0` / `has_buid=true`；得奇/大熊猫未本轮复跑）  
**装包 HEAD**：`a2516f0`（CI run `30141217889`，variant `legado-release`）  
**可见 WebView / Cookie 回灌代码**：`82df124` / `a2516f0`  
**MCP**：`http://192.168.1.18:8090`  
**包名**：`com.appbox.StandarReader`  
**本轮报告**：`fixtures/_devkit/phase88_visible_webview/qidian_cookie_search_20260725T043806Z.json`（同内容 `qidian_cookie_search_latest.json`）

## 源名单与结果

| # | 书源 | bookSourceUrl | 关键字 | 搜索 marker | 结论 | 失败点 |
|---|---|---|---|---|---|---|
| 1 | 得奇小说网 | `https://www.deqixs.com` | 斗破苍穹 | （本轮未复跑） | **FAIL**（旧） | 设备侧同源搜索 **HTTP 403** |
| 2 | 大熊猫文学网 | `https://www.dxmwx.org` | 斗破苍穹 | （本轮未复跑） | **FAIL**（旧） | 设备侧下载超时；引擎 0 条 |
| 3 | 起点中文 | `https://www.qidian.com` | 斗破苍穹 | `ok total=0 sources=1` | **FAIL** | 见下「起点本轮」 |

## 起点本轮（2026-07-25 12:38–12:41 复跑）

| 项 | 结果 |
|---|---|
| 原生开页 `/all/` | PASS：`path=XiangseOpenWebView hit class=LCStandarConfig`；分类页可见（玄幻/奇幻等标签） |
| 「在此处浏览」弹层 | PASS：点掉后 `browse_gone` |
| 人机验证 | **未见可点控件**（UI/OCR 无「人机/滑动/验证」文案）；自动点按与滑块尝试均未命中；`captcha_seen=false` |
| Cookie 回灌 | PASS（同进程）：`WKCookieStore harvest done`；jar/store 有 `www.qidian.com` / `m.qidian.com`（含 `_csrfToken`、`w_tsfp`） |
| 原生开页 `/so/` | 长期白屏「进行中」；OCR 几乎只有状态栏 |
| 搜索复跑 | **FAIL** `ok total=0`；探针 `has_buid=true`、`has_res_book_item=false`；`redirect=https://www.qidian.com/undefined` |
| 正文 | 未尝试（无搜索结果） |

证据：

- 报告：`fixtures/_devkit/phase88_visible_webview/qidian_cookie_search_20260725T043806Z.json`
- `/all/` 截图：`fixtures/_devkit/phase88_visible_webview/qidian_all_20260725T043915Z.png`
- `/so/` 等待截图：`fixtures/_devkit/phase88_visible_webview/qidian_so_wait_0_20260725T043955Z.png` 等
- 搜索后截图：`fixtures/_devkit/real_source_e2e/qidian_search_20260725T044107Z.png`（仍卡在原生网页「进行中」）

探针原文摘要：

```
redirect=https://www.qidian.com/undefined
len=209
has_buid=true
has_res_book_item=false
head=... var buid = "fffffffffffffffffff" ... /C2WF946J0/probe.js ...
```

## 含义

- 原生开页 + Cookie 回灌仍通；**起点搜索仍不通**。
- `/all/` 拿到的 Cookie **过不了** `/so/` 的 Cookie 验证：搜索响应仍是 `var buid` 挑战页，不是书单 HTML。
- `/so/` 在 App 原生网页里长时间白屏转圈，**看不到**可点的人机界面，自动化无法在网页内完成验证。
- 书源 `ruleSearch.bookList` 在 `var buid` 时会调 `java.startBrowserAwait`；Bridge **仍未实现**该 API。
- `redirect=.../undefined` 也值得单独查（搜索 URL 组装/跳转可能另有问题），但当前主因仍是 `has_buid=true`。

## 诚实边界

- **未**把真实源标 PASS。
- **未**把 `legado-feature-parity` 标 completed。
- 可见 WebView 原生 hit + Cookie 回灌 PASS **不等于**起点搜索 PASS。
