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
| Present 前不碰 CookieStore；仅 inject 后读完成 Cookie | `51d5ed8`（CI `30163275599`） | **冷启动 browserAwait 最小门禁 PASS** |

### `51d5ed8` 真机事实（本轮 PASS）

- manifest：`git_commit=51d5ed890a2…` / `github_run_id=30163275599` / `variant=legado-debug`
- IPA：`dist/ci-artifact-30163275599-debug/dist/StandarReader-legado-bridge-debug.ipa`
- IPA SHA256：`3876e008d62d5336955177bee28e498114987cf50889262fcafbcc8ad02c8b87`
- 验收 `fixtures/_accept_browser_await.py`：**PASS**
  - `process_survived=true`（点前/点后均存活，前台仍为 StandarReader）
  - `startBrowserAwait overlay` + `user done` + `harvest done`
  - `xiangse_native_hit`（`LCStandarConfig`）
  - `token_in_jar_or_dump` + `token_in_await_search`（本轮时间戳后 `/await_search` Cookie 含 `AWAIT_TOKEN=ok`）
- 冷启动路径：杀进程后仅经搜索触发 `legado://browserAwait`（验收脚本未先热 webview），`overlay_wait_sec=1`，未落到 SpringBoard

验收 JSON：

- PASS：`fixtures/_devkit/browser_await/browser_await_accept_20260725T151942Z.json`
- 截图：`await_wait_20260725T151942Z.png` / `await_after_20260725T151942Z.png`

### `5c758fe` 真机事实（上一轮 FAIL）

- manifest：`git_commit=5c758fe2f7…` / `github_run_id=30162921072` / `variant=legado-debug`
- 验收：**FAIL**（开页前进程已死）
- 根因：`LBStartBrowserAwait` 在 Present **之前**调用 `WKHTTPCookieStore`；冷启动无 WK 时无崩溃报告退出
- FAIL JSON：`fixtures/_devkit/browser_await/browser_await_accept_20260725T150853Z.json`

### `6f25ffd` 真机事实

- 开页存活；精确点击后 Cookie/`await_search` 通；点后 ≤1s `process_survived=false`（EvalJS 轮询竞态）

## 代码修复（已合入 `51d5ed8`）

文件：

1. `LegadoBridge/Sources/LegadoBridgeHooks/LBVisibleWebView.m`
   - **删除** Present 前的 CookieStore 清理（冷启动杀进程点）
   - CookieStore 完成探测：**仅** `sBrowserAwaitInjectLogged` 之后
   - 注入 JS 时先 `LB_AWAIT_DONE` max-age=0，避免残留误判
   - 仍保留：inject 后停 EvalJS；Finish 不取 outerHTML；gate 串行；`LBBrowserAwaitSignalUserDone`
2. `fixtures/_accept_browser_await.py`
   - `token_in_await_search` 只认本轮时间戳之后的 `/await_search`
   - `package_expected` 指向本轮修复意图

**状态**：`51d5ed8` 真机冷启动最小门禁 **PASS**。本代理不 commit/push；不做全能书源总验收。

## 复验步骤（已执行）

1. mock health：`http://192.168.1.4:8765/health` → ok
2. 装 CI Debug IPA run `30163275599`（`--expected-sha 51d5ed8 --expected-run 30163275599 --expected-variant legado-debug`）
3. `python fixtures/_accept_browser_await.py` → **PASS**
4. 断言已满足：`process_survived` + user done/harvest + `/await_search` Cookie `AWAIT_TOKEN=ok`

## 装包与证据

### `51d5ed8`（本轮 PASS）

- CI run `30163275599` success
- Debug artifact：`LegadoBridge-IPA-Debug`
- 冷启动 browserAwait 存活并完成 Cookie 回灌

### `5c758fe`（上一轮 FAIL）

- CI run `30162921072`；冷启动杀进程

### `6f25ffd`

- CI run `30162463665`；开页存活；点后杀进程

## 受控源 / 验收脚本

| 路径 | 用途 |
|---|---|
| `fixtures/await_gate.html` | 写 `AWAIT_TOKEN=ok` + 页内「完成验证」 |
| `fixtures/legado-browser-await-mock.json` | 受控源模板 |
| `.test_tools/serve_browser_await_mock.py` | 记 Cookie 的 mock |
| `fixtures/_accept_browser_await.py` | 真机验收（时间戳过滤 await_search） |

## 下一步

1. 网页等待最小门禁已 PASS；总验前仍要领域/笔趣读真实源回归（见 `deferred-full-verify.md`）。
2. 仍不做全能书源总验收。
