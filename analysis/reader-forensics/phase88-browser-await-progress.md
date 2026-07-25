# 网页等待 startBrowserAwait（phase88 续）

**日期**：2026-07-25  
**MCP**：`http://192.168.1.18:8090`  
**mock**：`http://192.168.1.4:8765`（`.test_tools/serve_browser_await_mock.py`）  
**本轮不做**：全能书源 / 领域 / 笔趣读总验收；未改计划 status。

## 结论（诚实）

| 阶段 | 包 | 结果 |
|---|---|---|
| 触发 `startBrowserAwait` + `handler=true` + `XiangseOpenWebView` + mock `await_gate.html` | `51a63b7` / `f142774` | **PASS** |
| 等待页前台可见 + 点「完成验证」+ `/await_search` Cookie | `51a63b7` / `f142774` | **FAIL**（挂原生钮杀进程） |
| 去原生钮、页内注入；进程开页存活 | `6f25ffd`（CI `30162463665`） | **开页存活 PASS** |
| 点「完成验证」→ harvest → `await_search` 带 `AWAIT_TOKEN=ok` | `6f25ffd` | **链路通，但点后杀进程 → process_survived FAIL** |
| 停 EvalJS 轮询 / CookieStore 完成探测 / 串行化 await | **已改待 commit** | **未出 IPA，未真机复验** |

### `6f25ffd` 真机事实（本轮）

- manifest：`git_commit=6f25ffd7d1…` / `github_run_id=30162463665` / `variant=legado-debug`
- IPA：`dist/ci-artifact-30162463665-debug/dist/StandarReader-legado-bridge-debug.ipa`
- IPA SHA256：`c38d3636d2f59ae53661cb03c6746f79346c0327b139d150449d5819578bb0ab`
- 开页：`host=WKInject`；进程存活；页可见
- 验收脚本曾点到说明文案里的「完成验证」而非按钮 → 已改为精确匹配 `text == "完成验证"`
- 精确点击后：`user done` + `harvest done` + mock `/await_search.html?q=等待` Cookie 含 `AWAIT_TOKEN=ok`（`x_cookie_jar=1`）
- 唯一剩余门禁失败：`process_survived=false`（点后 ≤1s 落到 SpringBoard）
- 单深链 `legado://browserAwait` 精确点击同样 ≤1s 杀进程（与搜索路径无关）
- 对照：未点击前可长时间存活；杀进程与「等待环每 0.4s `evaluateJavaScript`」和点击竞态强相关

验收 JSON：

- FAIL（假 tap）：`fixtures/_devkit/browser_await/browser_await_accept_20260725T145608Z.json`
- FAIL（精确 tap，功能通、进程死）：`fixtures/_devkit/browser_await/browser_await_accept_20260725T150233Z.json`

## 代码修复（已改待 commit）

文件：

1. `LegadoBridge/Sources/LegadoBridgeHooks/LBVisibleWebView.m`
   - 查找 WK：优先已上屏 / top VC，避免打到残留 WebView
   - 注入按钮改视口底部（原 top-right 被导航栏挡住）
   - **注入成功后停止 EvalJS 轮询**；完成信号改读 `WKHTTPCookieStore` 的 `LB_AWAIT_DONE`
   - `LBStartBrowserAwait` 加 gate 串行化（禁止双开页双 Finish）
   - Finish 不再 `outerHTML` EvalJS；提供 `LBBrowserAwaitSignalUserDone`
2. `LegadoBridge/Sources/LegadoBridgeHooks/LBImportHooks.m`
   - 深链 `legado://browserAwaitDone` → `LBBrowserAwaitSignalUserDone`
3. `LegadoBridge/Sources/LegadoBridgeHooks/include/LBInternal.h`
   - 声明 `LBBrowserAwaitSignalUserDone`
4. `fixtures/await_gate.html`
   - 页内可见「完成验证」按钮；点击写 `LB_AWAIT_DONE=1`（加载时清残留）
5. `fixtures/_accept_browser_await.py`
   - 精确点击 `text == "完成验证"`；`harvest_done` 只认 `startBrowserAwait harvest done`
   - 点后等待加长到 8s

**状态**：**已改待 commit**（本代理不 commit/push）；待父代理提交 → CI Debug IPA → 真机复验 `process_survived`。

## 复验步骤（新 IPA 到手后）

1. 确认 mock：`http://192.168.1.4:8765/health`
2. 装 CI Debug IPA（`xiangse_devkit.py --mcp http://192.168.1.18:8090 install … --expected-sha <新commit>`）
3. `python fixtures/_accept_browser_await.py`
4. 断言：`process_survived` + `user done`/`harvest done` + `/await_search` Cookie `AWAIT_TOKEN=ok`

## 装包与证据

### FAIL 基线 `51a63b7` / `f142774`

见上文历史；根因曾为原生挂钮杀进程。

### `6f25ffd`（本轮）

- CI run `30162463665` success
- Debug artifact：`LegadoBridge-IPA-Debug`
- 开页存活已证实；点完成验证后杀进程；Cookie 回灌与 `await_search` 在杀进程前已成功

## 受控源 / 验收脚本

| 路径 | 用途 |
|---|---|
| `fixtures/await_gate.html` | 写 `AWAIT_TOKEN=ok` + 页内「完成验证」 |
| `fixtures/legado-browser-await-mock.json` | 受控源模板 |
| `.test_tools/serve_browser_await_mock.py` | 记 Cookie 的 mock |
| `fixtures/_accept_browser_await.py` | 真机验收（已收紧 + 精确点击） |

## 下一步

1. 父代理 commit/push 本改动 → 等 CI Debug IPA。
2. 真机跑 `_accept_browser_await.py`，确认 `process_survived`。
3. 仍不做全能书源总验收。
