# 真实书源端到端（2026-07-25 复跑 c5c07cc）

**verdict**：FAIL（起点搜索仍 `ok total=0 sources=1`；得奇/大熊猫未本轮复跑）  
**装包 HEAD**：`c5c07cc`（完整 `c5c07cc2d7e232d915d3c21fa6de211702426a21`）  
**CI**：run `30145347037` 成功；artifact `LegadoBridge-IPA-Debug`  
**variant**：`legado-debug`（`reader-build-manifest.json`）  
**相关提交（已在 main，已与 origin/main 同步）**：

| commit | 内容 |
|---|---|
| `bd9fd07` | 搜索 URL 防 `/undefined`；接 `startBrowserAwait`；搜索体探针 |
| `9eabd67` | WebBook 列表解析不传 CoreData BookSource |
| `d9cb236` | JSBridge 编译错误 |
| `c5c07cc` | 公开 `BrowserAwaitGate` 供 Core 注入 |

**MCP**：`http://192.168.1.18:8090`  
**包名**：`com.appbox.StandarReader`  
**本轮报告**：

- `fixtures/_devkit/phase88_visible_webview/qidian_cookie_search_20260725T071113Z.json`（同内容 `qidian_cookie_search_latest.json` / `qidian_cookie_search_c5c07cc.json`）
- 复搜轮询：`fixtures/_devkit/phase88_visible_webview/qidian_research_20260725T071616Z.json`
- 高频采样：`fixtures/_devkit/phase88_visible_webview/qidian_search_poll_log.txt`

## 源名单与结果

| # | 书源 | bookSourceUrl | 关键字 | 搜索 marker | 结论 | 失败点 |
|---|---|---|---|---|---|---|
| 1 | 得奇小说网 | `https://www.deqixs.com` | 斗破苍穹 | （本轮未复跑） | **FAIL**（旧） | 设备侧同源搜索 **HTTP 403** |
| 2 | 大熊猫文学网 | `https://www.dxmwx.org` | 斗破苍穹 | （本轮未复跑） | **FAIL**（旧） | 设备侧下载超时；引擎 0 条 |
| 3 | 起点中文 | `https://www.qidian.com` | 斗破苍穹 | `ok total=0 sources=1` | **FAIL** | 见下「起点本轮」 |

## 起点本轮（2026-07-25 15:05–15:22，包 `c5c07cc` Debug）

| 项 | 结果 |
|---|---|
| 装包 | PASS：卸载后装 CI Debug IPA；manifest `git_commit=c5c07cc2…` / `github_run_id=30145347037` / `variant=legado-debug` |
| 原生开页 `/all/` | PASS：`path=XiangseOpenWebView hit class=LCStandarConfig`；分类页可见 |
| 「在此处浏览」弹层 | PASS：可点掉（`browse_gone`） |
| 人机验证 | **未见可点控件**（UI/OCR 无稳定「人机/滑动/验证」）；`captcha_seen` 多为 false |
| Cookie 回灌 | PASS：`WKCookieStore harvest done`；`legado_cookie_store.json` / jar 有 `www.qidian.com` / `m.qidian.com`（含 `_csrfToken`、`w_tsfp`） |
| 原生开页 `/so/` | 仍常白屏「进行中」；截图见 `qidian_so_wait_*_20260725T071113Z.png` |
| `/undefined` | **本轮设备侧无 `legado_search_body_probe.txt`，无法用 redirect 行直接证伪/证实**。二进制含 `legado_search_analyzed_url` / 防 undefined 逻辑（`bd9fd07`）。上一轮 `a2516f0` 探针曾明确 `redirect=…/undefined`。 |
| `startBrowserAwait` | **代码已实现并打进包**（`LegadoBridge` 二进制含 `startBrowserAwait` / `BrowserAwaitGate` / `wireBrowserAwait`；`LBStartBrowserAwait` +「完成验证」浮层）。**本轮真机未走到**：`legado_visible_webview.txt` 无 `startBrowserAwait overlay/timeout/user done`。 |
| 搜索 | **FAIL** `ok total=0 sources=1`；书源已启用且 `sources=1`；**无** `legado_search_body_probe.txt` / `legado_search_analyzed_url.txt`（空 body 会在探针写入前 `throw emptyResponse`，随后 `partial err` 又被最终 `ok total=0` 覆盖） |
| 正文 | 未尝试（无搜索结果） |

对照（PC 用设备回灌 Cookie 请求同一 `/so/`）：

- HTTP 200，body ≈ 65KB，`res-book-item=true`，`var buid=false`
- 说明：**回灌 Cookie 本身可拿到书单 HTML**；问题在 App 内搜索请求/解析路径（本轮表现为探针前空响应），不是「Cookie 文件一定无效」。

## 含义（相对旧文档的修正）

1. **`java.startBrowserAwait` 已实现**（`bd9fd07` + `c5c07cc`），旧文档「Bridge 仍未实现」作废。本轮没走到，是因为搜索未进入带 `var buid` 的 `bookList` JS（甚至未写出搜索体探针）。
2. **`/undefined` 修复已进包**；本轮因无探针，不能声称设备侧已观察到「redirect 不再含 undefined」。上一轮失败证据仍是 `a2516f0` 的 `/undefined` + `has_buid=true`。
3. 原生开页 + Cookie 回灌仍 PASS；**起点 App 内搜索仍 FAIL**。
4. 同进程 Cookie 在 PC 侧可搜到书单 → 下一步应查 App `URLSession` 是否带上 Cookie、以及 `AnalyzeUrl` 实际请求 URL（建议把 `legado_search_analyzed_url.txt` 挪到空 body 判断之前，并保留 `partial err` 不被最终 `ok` 覆盖）。

## 诚实边界

- **未**把真实源标 PASS。
- **未**把 `legado-feature-parity` 标 completed。
- **未**在本轮真机上观察到 `startBrowserAwait` 浮层或超时标记。
- **未**用本轮探针证明 `/undefined` 已消失（无探针文件）。
- 可见 WebView 原生 hit + Cookie 回灌 PASS **不等于**起点 App 内搜索 PASS。
