# 网页等待 startBrowserAwait（phase88 续）

**日期**：2026-07-25  
**MCP**：`http://192.168.1.18:8090`  
**mock**：`http://192.168.1.4:8765`（`.test_tools/serve_browser_await_mock.py`）  
**装包**：仍为 `efac2d4`（`legado-debug` / run `30153293936`）  
**本轮不做**：全能书源 / 领域 / 笔趣读总验收；未改计划 status。

## 结论（诚实）

| 项 | 结果 |
|---|---|
| 代码路径 `startBrowserAwait` 真机被触发 | **FAIL**（现包） |
| 等待页 + 完成验证 + Cookie 回灌后续请求 | **FAIL**（现包；根因挡住触发） |
| 根因定位 | **PASS**（有可复现证据） |
| 修复代码（未装包） | 已写在工作区，**待 commit / CI / 装包后再验** |

**不要把本轮标成 BrowserAwait PASS。**

## 根因（证据链）

1. 受控源已导入：`legado_bridge_sources.json` 含 `BrowserAwait受控源`，`searchUrl` 为 `@js` + `java.startBrowserAwait(...)`。
2. 不含 `java.` 的 `@js`（只 `result=http://…/await_search.html?q=+key`）**能命中 mock**（`await_search.html` 有 StandarReader UA 请求）。
3. 一旦脚本访问 `java.startBrowserAwait`，搜索对该源报 `网络响应为空`，且 **无** `legado_visible_webview*.txt`，mock **无** `await_gate.html`。
4. 诊断源把异常塞进 query 后，mock 记到：

```text
h=EX:ReferenceError: Can't find variable: java
```

证据：`fixtures/_devkit/browser_await/request_log.jsonl`（`handlerProbe` 条目）；脚本 `.test_tools/browser_await_js_probe.py`。

5. 与 `AnalyzeUrl.evalJS` 注释一致：真机 `JSContext.setValue(_:forKey:)` 写入的全局对 `evaluateScript` **不可见**（曾修 `baseUrl` 字面量）。`java`/`cookie`/`source`/`network` 仍用 `setValue`，故 **起点 searchUrl 实际靠 `recoverUrlFromFailedAnalyzeJs` 回落**，`java.put` 在真机 AnalyzeUrl 路径上并未真正跑通。

## 已改代码（工作区，未进 efac2d4 包）

| 文件 | 改动 |
|---|---|
| `JSBridge.swift` | 桥接全局改为 `setObject:forKeyedSubscript:` + `globalObject`（`bindGlobal`） |
| `AnalyzeUrl.swift` | 注入后探测 `typeof java`；`legado_js_bridge_probe.txt` |
| `SourceSessionStore.swift` | `BrowserAwaitGate` 调用落盘 `legado_browser_await_gate.txt` |
| `LBVisibleWebView.m` | `LBBrowserAwaitFinish` **同步等待** Cookie harvest 再放行 |
| `LBImportHooks.m` | `legado://browserAwait?url=` 后台队列探针深链 |
| `LegadoBridgeCExports.m` | 指定 `sourceUrl` 时直调 `LBHandleSearchRequest`（不再被 startSearch 丢掉筛选） |

## 受控源 / 验收脚本

| 路径 | 用途 |
|---|---|
| `fixtures/await_gate.html` | 写 `AWAIT_TOKEN=ok` |
| `fixtures/legado-browser-await-mock.json` | 受控源模板 |
| `.test_tools/serve_browser_await_mock.py` | 记 Cookie 的 mock |
| `fixtures/_accept_browser_await.py` | 真机验收（现包预期 FAIL） |

## 现包失败证据 SHA256

清单：`fixtures/_devkit/browser_await/evidence_sha256.txt`

| 文件 | SHA256 |
|---|---|
| `browser_await_accept_20260725T100634Z.json` | `f07f6d1ff3a7b8d8269badc08d9dc493a38bee33f8868994e3677804ef67d57e` |
| `await_wait_20260725T100634Z.png` | `8eb7d75f4ea5971e278ca8e859707f716f7db0a483be9b9cbe0d5e951680883d` |
| `await_after_20260725T100634Z.png` | `00f07b61ec3334776190e06ffdb4f76476fa86e21ab64c0141437bf28291e1f0` |
| `request_log.jsonl` | `5b09fb77e9929118496e512ae4227f5a5b091950b4113880b684e8a7ccda3bd0` |

关键 mock 行（`handlerProbe`）：`h=EX:ReferenceError: Can't find variable: java`。

（装包后复跑通过时，在本文件追加 PASS 段与新 SHA。）

## 下一步（装新包后最小门禁）

1. CI Debug IPA → 真机安装。  
2. 起 mock → 导入受控源 → `legado://search?keyword=等待&sourceUrl=http://192.168.1.4:8765/browser-await-source`。  
3. 断言：`legado_browser_await_gate.txt` handler=true；`startBrowserAwait overlay` + `XiangseOpenWebView hit`；点「完成验证」；mock `/await_search` 的 Cookie 含 `AWAIT_TOKEN=ok`（或 `legado_request_cookie_probe` / jar）。  
4. 可选：`legado://browserAwait?url=…` 深链对照。
