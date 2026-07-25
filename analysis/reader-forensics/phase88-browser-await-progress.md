# 网页等待 startBrowserAwait（phase88 续）

**日期**：2026-07-25  
**MCP**：`http://192.168.1.18:8090`  
**mock**：`http://192.168.1.4:8765`（`.test_tools/serve_browser_await_mock.py`）  
**本轮不做**：全能书源 / 领域 / 笔趣读总验收；未改计划 status。

## 结论（诚实）

| 阶段 | 包 | 结果 |
|---|---|---|
| 触发 `startBrowserAwait` + `handler=true` + `XiangseOpenWebView` + mock `await_gate.html` | `51a63b7` | **PASS** |
| 等待页前台可见 + 点「完成验证」+ `/await_search` Cookie | `51a63b7` | **FAIL**（进程被杀 → SpringBoard） |
| 修开页杀进程后的最小门禁 | **待 commit/CI 新 IPA** | **未在真机复验**（本机无 iOS 编链） |

`java` 全局不可见已在 `51a63b7` 修好。当前阻塞是：`LBStartBrowserAwait` 开可见 WebView 后 **StandarReader 进程退出**（`list_running_apps` 无进程，`new_crash_count=0`，ReportCrash↔cr4shedd 被 sandbox deny），frontmost 落到 SpringBoard。

对照实验（同包 `51a63b7`）：

| 深链 | frontmost | 进程 |
|---|---|---|
| `legado://webview?url=…/await_gate.html` | 仍为 StandarReader，页可见 | 存活 |
| `legado://browserAwait?url=…` | ≤1s 变 SpringBoard | **消失** |

两者都走 `LCStandarConfig openWebViewWithUrlStr:`。差异在 await：主线程块里 **先往 keyWindow 挂「完成验证」再（嵌套 async）show**，且 `LBBrowserAwaitFinish` 曾在主线程 `semaphore_wait`（点完成会死锁）。

## 代码修复（已改未提交）

文件：`LegadoBridge/Sources/LegadoBridgeHooks/LBVisibleWebView.m`

1. **先开页、后挂钮**：`LBPresentVisibleWebView` 主线程同步开页；「完成验证」挂到 `WebViewController_WK` 的 `navigationItem` + **该 VC 的 view**，禁止挂 `keyWindow`。  
2. **Finish 禁止主线程阻塞**：`onDone` / `LBBrowserAwaitFinish` 转到后台队列再 `evaluateJavaScript` + cookie harvest 的 semaphore。  
3. 开页 `@try/@catch` + `path=XiangseOpenWebView returned` marker，便于区分死在 IMP 内还是之后。

**状态**：已改未 commit；**待父代理 commit/push → CI 出 IPA → 真机装包复验**。

## 复验步骤（新 IPA 到手后）

1. 确认 mock：`http://192.168.1.4:8765/health`  
2. 装 CI `legado-debug` IPA（`xiangse_devkit.py install`）  
3. `python fixtures/_accept_browser_await.py`  
4. 深链探针（可选）：`legado://browserAwait?url=http://192.168.1.4:8765/await_gate.html`  
   - 期望：`get_frontmost_app` 仍为 `com.appbox.StandarReader`；UI 可见等待页；可点「完成验证」  
5. 断言：marker 含 `user done` 或 `harvest done`；mock `/await_search` Cookie 含 `AWAIT_TOKEN=ok`（勿用 runtime.json 上的 Cookie 冒充）

## 装包与证据（FAIL 基线，包 `51a63b7`）

- CI run `30154271872` / commit `51a63b70…` / IPA SHA256 `32d58333…f76044`  
- 汇总：`fixtures/_devkit/browser_await/browser_await_accept_20260725T141502Z_51a63b7.json`  
- 杀进程 syslog 摘要：`fixtures/_devkit/browser_await/browser_await_kill_filtered.json`  
- 清单：`fixtures/_devkit/browser_await/evidence_sha256.txt`

关键 marker（杀进程前仍写出）：

```text
startBrowserAwait overlay url=… title=网页验证
path=XiangseOpenWebView hit class=LCStandarConfig url=…
```

截图 `await_wait_*` / `await_after_*` 均为主屏。

## 受控源 / 验收脚本

| 路径 | 用途 |
|---|---|
| `fixtures/await_gate.html` | 写 `AWAIT_TOKEN=ok` |
| `fixtures/legado-browser-await-mock.json` | 受控源模板 |
| `.test_tools/serve_browser_await_mock.py` | 记 Cookie 的 mock |
| `fixtures/_accept_browser_await.py` | 真机验收 |

## 下一步

1. 父代理 commit/push 本改动 → 等 CI IPA。  
2. 真机跑 `_accept_browser_await.py`，更新本页结论表。  
3. 仍不做全能书源总验收。
