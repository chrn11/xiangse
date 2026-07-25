# 真实书源端到端（2026-07-25 复跑 005c154）

**verdict**：FAIL（起点 Cookie 已带到搜索请求，搜索 HTML 非空且含 `res-book-item`，但书单解析仍 0 条；得奇/大熊猫未本轮复跑）  
**装包 HEAD**：`005c154`（完整 `005c1542d3fbc47ed0cbdc24a8cfacfd6b71cd4b`）  
**CI**：run `30150059083` 成功；artifact `LegadoBridge-IPA-Debug`  
**variant**：`legado-debug`（`reader-build-manifest.json`）  
**相关提交（已在 main，已与 origin/main 同步）**：

| commit | 内容 |
|---|---|
| `70a997e` | CookieJar 注入到搜索请求；探针挪到空 body 之前；search_last 追加写 |
| `b9b84a3` | `@js` 失败时从 `baseUrl+"/path"` 字面量恢复 URL |
| `2ca53a9` | evalJS 去掉 IIFE（曾导致丢 baseUrl） |
| `005c154` | evalJS 字面量注入 baseUrl；勿把 `@js:` 原文当 url 初值 |

**MCP**：`http://192.168.1.18:8090`  
**包名**：`com.appbox.StandarReader`  
**本轮报告**：

- `fixtures/_devkit/phase88_visible_webview/qidian_cookie_search_20260725T075344Z.json`（`005c154`）
- 同内容：`qidian_cookie_search_latest.json` / `qidian_cookie_search_005c154.json`（若脚本已写）
- 过程证据：`qidian_cookie_search_20260725T073402Z.json`（`70a997e`，localhost）、`…T074249Z.json`（`b9b84a3`）、`…T074813Z.json`（`2ca53a9`）

## 源名单与结果

| # | 书源 | bookSourceUrl | 关键字 | 搜索 marker | 结论 | 失败点 |
|---|---|---|---|---|---|---|
| 1 | 得奇小说网 | `https://www.deqixs.com` | 斗破苍穹 | （本轮未复跑） | **FAIL**（旧） | 设备侧同源搜索 **HTTP 403** |
| 2 | 大熊猫文学网 | `https://www.dxmwx.org` | 斗破苍穹 | （本轮未复跑） | **FAIL**（旧） | 设备侧下载超时；引擎 0 条 |
| 3 | 起点中文 | `https://www.qidian.com` | 斗破苍穹 | `ok total=0 sources=1` | **FAIL** | HTML 已下到；`bookList` 解析 0 条 |

## 起点本轮（2026-07-25，包 `005c154` Debug）

| 项 | 结果 |
|---|---|
| 装包 | PASS：CI Debug IPA；manifest `git_commit=005c154…` / `github_run_id=30150059083` / `variant=legado-debug` |
| Cookie 回灌 | PASS：开 `/all/` + WKCookieStore harvest；jar/store 有 qidian |
| Cookie 带到搜索请求 | **PASS**：`legado_request_cookie_probe.txt`：`cookieAttached=true`，`headerCookieLen=599`，`domain=www.qidian.com`，`url=https://www.qidian.com/so/…` |
| 搜索 URL | **PASS**：`https://www.qidian.com/so/%E6%96%97%E7%A0%B4%E8%8B%8D%E7%A9%B9.html`；无 `/undefined`；无 `localhost` |
| `@js` / analyzeJs | **本轮搜索未再写 `legado_analyze_js_probe.txt`（该文件仅 recovered/failed 时写）**，且 body 探针时间晚于旧 recovered 戳，说明 URL 已由正常解析得到，不再依赖字面量恢复 |
| 搜索体 | **非空**：`len=52297`，`has_buid=false`，`has_res_book_item=true` |
| `startBrowserAwait` | **未进入**（合理：无 `var buid`） |
| 书单 | **FAIL**：`ok total=0`，`books_found=0` |
| 正文 | 未尝试（无搜索结果） |
| 探针前置 | PASS：空 body 也会写 analyzed/body 探针；`search_last` 追加写，可见完整 enter→ok |

对照（PC 同 Cookie 请求 `/so/`，上一轮）：

- HTTP 200，≈65KB，`res-book-item=true`，`var buid=false`
- App 本轮已能拿到同类非空 HTML（≈52KB）并带上 Cookie

## 含义（相对旧文档的修正）

1. **Cookie 可用且已注入 App 搜索 `URLSession` 请求**（根因曾是 `getResponseBody` 重建 `AnalyzeUrl` 时 `domain` 用空 `url`）。
2. **空 body 不再盖掉探针**；`ok total=0` 不再单独抹掉中间标记。
3. **`/undefined` / `localhost` 本轮均未再现**。
4. **`startBrowserAwait` 未走到是预期**：响应无 `var buid`。
5. **剩余失败点**：`ruleSearch.bookList` 的 `<js>…java.getElement('class.res-book-item')…`（或后续 name/bookUrl 规则）在已有书单项 HTML 上仍产出 0 条。

## 诚实边界

- **未**把真实源标 PASS。
- **未**把 `legado-feature-parity` 标 completed。
- **未**打开正文。
- 可见 WebView + Cookie 回灌 PASS **不等于**起点搜索书单 PASS。
