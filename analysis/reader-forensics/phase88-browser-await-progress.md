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
| 停 EvalJS 轮询 / CookieStore 完成探测 / 串行化 await | `5c758fe`（CI `30162921072`） | **冷启动 browserAwait ≤0.5s 杀进程 FAIL** |
| 去掉 Present 前 CookieStore；仅 inject 后读 CookieStore | **已改待 commit** | **未出 IPA，未真机复验** |

### `5c758fe` 真机事实（本轮）

- manifest：`git_commit=5c758fe2f7…` / `github_run_id=30162921072` / `variant=legado-debug`
- IPA：`dist/ci-artifact-30162921072-debug/dist/StandarReader-legado-bridge-debug.ipa`
- IPA SHA256：`c2a117ce45594a7b2bc4e26f6495878ab0b1544b3831ffea22b37823fcce665b`
- 验收 `fixtures/_accept_browser_await.py`：**FAIL**（开页前进程已死，无 overlay / user done / harvest）
- 对照：
  - `legado://webview` 开同页：**存活**
  - 先 webview 再 `legado://browserAwait`（WK 已热、Cookie 已清）：**可存活并 inj=injected**
  - 冷启动仅 `legado://browserAwait`：**≤0.5s → SpringBoard**；`openurl` 已写，`presented` 未写
- 根因：`LBStartBrowserAwait` 在 Present **之前**调用 `WKWebsiteDataStore.defaultDataStore.httpCookieStore getAllCookies/deleteCookie`；冷启动无 WK 时该调用会无崩溃报告退出。次因：未 inject 前读 CookieStore 会把残留 `LB_AWAIT_DONE` 误判为完成。

验收 JSON：

- FAIL（`5c758fe` 冷启动杀进程）：`fixtures/_devkit/browser_await/browser_await_accept_20260725T150853Z.json`

### `6f25ffd` 真机事实（上一轮）

- 开页存活；精确点击后 Cookie/`await_search` 通；点后 ≤1s `process_survived=false`（EvalJS 轮询竞态）

## 代码修复（已改待 commit）

文件：

1. `LegadoBridge/Sources/LegadoBridgeHooks/LBVisibleWebView.m`
   - **删除** Present 前的 CookieStore 清理（冷启动杀进程点）
   - CookieStore 完成探测：**仅** `sBrowserAwaitInjectLogged` 之后
   - 注入 JS 时先 `LB_AWAIT_DONE` max-age=0，避免残留误判
   - 仍保留：inject 后停 EvalJS；Finish 不取 outerHTML；gate 串行；`LBBrowserAwaitSignalUserDone`
2. `fixtures/_accept_browser_await.py`
   - `token_in_await_search` 只认本轮时间戳之后的 `/await_search`（禁止历史日志 / runtime.json 冒充）
   - `package_expected` 更新为 `5c758fe + post-FAIL …`

**状态**：**已改待 commit**（本代理不 commit/push）；待父代理提交 → CI Debug IPA → 真机复验冷启动 `process_survived` + Cookie。

## 复验步骤（新 IPA 到手后）

1. 确认 mock：`http://192.168.1.4:8765/health`
2. 装 CI Debug IPA（`xiangse_devkit.py --mcp http://192.168.1.18:8090 install --ipa … --expected-sha <新commit> --expected-run <id> --expected-variant legado-debug`）
3. `python fixtures/_accept_browser_await.py`
4. 断言：`process_survived` + `user done`/`harvest done` + `/await_search` Cookie `AWAIT_TOKEN=ok`
5. 额外对照：冷启动 `legado://browserAwait` 须存活（不再 ≤0.5s 死）

## 装包与证据

### `5c758fe`（本轮 FAIL）

- CI run `30162921072` success
- Debug artifact：`LegadoBridge-IPA-Debug`
- 冷启动 browserAwait 杀进程；webview 对照存活

### `6f25ffd`（上一轮）

- CI run `30162463665` success；开页存活；点后杀进程

## 受控源 / 验收脚本

| 路径 | 用途 |
|---|---|
| `fixtures/await_gate.html` | 写 `AWAIT_TOKEN=ok` + 页内「完成验证」 |
| `fixtures/legado-browser-await-mock.json` | 受控源模板 |
| `.test_tools/serve_browser_await_mock.py` | 记 Cookie 的 mock |
| `fixtures/_accept_browser_await.py` | 真机验收（时间戳过滤 await_search） |

## 下一步

1. 父代理 commit/push 本改动 → 等 CI Debug IPA。
2. 真机跑 `_accept_browser_await.py`，确认冷启动 `process_survived`。
3. 仍不做全能书源总验收。
