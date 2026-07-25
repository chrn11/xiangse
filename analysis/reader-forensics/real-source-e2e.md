# 真实书源端到端（2026-07-25）

**verdict**：FAIL（起点搜索仍 `ok total=0`；得奇/大熊猫未本轮复跑）  
**HEAD（可见 WebView + Cookie 回灌）**：`82df124` / 文档 `8315088`  
**本轮代码（待 CI 装包）**：CookieManager 落盘 + 搜索 body 探针 + Cookie dump  
**MCP**：`http://192.168.1.18:8090`  
**报告**：`fixtures/_devkit/real_source_e2e/`；起点复跑见 `fixtures/_devkit/phase88_visible_webview/qidian_cookie_search_v2.json`

## 源名单与结果

| # | 书源 | bookSourceUrl | 关键字 | 搜索 marker | 结论 | 失败点 |
|---|---|---|---|---|---|---|
| 1 | 得奇小说网 | `https://www.deqixs.com` | 斗破苍穹 | （本轮未复跑） | **FAIL**（旧） | 设备侧同源搜索 **HTTP 403** |
| 2 | 大熊猫文学网 | `https://www.dxmwx.org` | 斗破苍穹 | （本轮未复跑） | **FAIL**（旧） | 设备侧下载超时；引擎 0 条 |
| 3 | 起点中文 | `https://www.qidian.com` | 斗破苍穹 | `ok total=0 sources=1` | **FAIL** | 见下「起点本轮」 |

## 起点本轮（2026-07-25 可见 WebView 后复跑）

| 项 | 结果 |
|---|---|
| 原生开页 | PASS：`path=XiangseOpenWebView hit class=LCStandarConfig`，`/all/` 分类页可见 |
| 人机弹层 | `/all/` **未见**人机文案；有「打开 App」底栏，非阻断 |
| Cookie 回灌 | PASS（同进程）：`WKCookieStore harvest done`；jar 有 `www.qidian.com` / `m.qidian.com` |
| 搜索复跑 | **FAIL** `ok total=0`（同进程、先回灌再搜） |
| CSS 对照 | `bookList=class.res-book-item` 仍 `total=0` → 不只是 `<js>` 规则问题 |
| `/so/` 页 | 原生 WebView 打开搜索 URL 后 UI 长期「进行中」；OCR 近空白；harvest key 仍偏分类页 |
| 无 Cookie 对照（PC） | `https://www.qidian.com/so/斗破苍穹.html` → **HTTP 202**，body 含 `var buid`（Cookie 验证页） |
| 正文 | 未尝试（无搜索结果） |

证据：

- `fixtures/_devkit/phase88_visible_webview/qidian_cookie_search_v2.json`
- `fixtures/_devkit/phase88_visible_webview/qidian_css_control.json`
- `fixtures/_devkit/phase88_visible_webview/qidian_so_wait.json`
- `fixtures/_devkit/phase88_visible_webview/qidian_so_pc_nocookie.html`

## 含义

- 引擎 mock 搜索仍成立；**真实起点搜索未通**。
- `/all/` 能开且能回灌 Cookie，**不等于** `/so/` Cookie 验证已过。
- 书源 `ruleSearch.bookList` 依赖 `java.startBrowserAwait`；Bridge **尚未实现**该 API；即便改成纯 CSS 列表，当前回灌 Cookie 下仍空结果。

## 诚实边界

- **未**把真实源标 PASS。
- **未**把 `legado-feature-parity` 标 completed。
- 可见 WebView 原生 hit + Cookie 回灌路径 PASS **不等于**起点过盾搜索 PASS。
