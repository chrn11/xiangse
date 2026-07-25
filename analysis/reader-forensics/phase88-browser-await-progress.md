# 网页等待 startBrowserAwait（phase88 续）

**日期**：2026-07-25  
**MCP**：`http://192.168.1.18:8090`  
**mock**：`http://192.168.1.4:8765`（`.test_tools/serve_browser_await_mock.py`）  
**本轮不做**：全能书源 / 领域 / 笔趣读总验收；未改计划 status。

## 结论（诚实）

| 阶段 | 包 | 结果 |
|---|---|---|
| 触发 `startBrowserAwait` + `handler=true` + `XiangseOpenWebView` + mock `await_gate.html` | `51a63b7` / `f142774` | **PASS** |
| 等待页前台可见 + 点「完成验证」+ `/await_search` Cookie | `51a63b7` | **FAIL**（进程被杀 → SpringBoard） |
| 同门禁复验 | `f142774`（CI `30162067981`） | **FAIL**（同上；脚本曾假 PASS） |
| 去掉原生挂钮、改 WK 页内注入 | **已改待 commit** | **未出 IPA，未真机复验** |

`f142774` 真机事实：

- manifest：`git_commit=f14277429f…` / `github_run_id=30162067981` / `variant=legado-debug`
- 开页 marker：`XiangseOpenWebView hit/returned` + `overlay host=WebViewController_WK hasBtn=1` 仍写出
- 随后 ≤0.4s 进程消失，frontmost=`com.apple.springboard`；截图为主屏
- 对照：同包 `legado://webview?url=…/await_gate.html` **存活**，且 2.5s/5s harvest 正常
- mock 仅有 `/await_gate.html` 与 runtime.json 带 `AWAIT_TOKEN=ok`，**无** `/await_search*`
- `_accept_browser_await.py` 旧逻辑把 gate/runtime Cookie 当成成功 → **假 PASS**（已收紧）

根因修正方向：杀进程与「往 `WebViewController_WK` 挂 `UIBarButtonItem`/`UIButton`」强相关（webview 深链不挂钮则存活）。`f142774` 的「先开页再挂原生钮」未消除该杀进程。

## 代码修复（已改待 commit）

文件：

1. `LegadoBridge/Sources/LegadoBridgeHooks/LBVisibleWebView.m`
   - **删除**原生 `LBAttachBrowserAwaitDoneUI` / `LBBrowserAwaitTarget` 挂钮路径
   - 开页仍走 `LBPresentVisibleWebView`（与存活的 `legado://webview` 同路径）
   - 「完成验证」改为对 WK **页内 DOM 注入** button；点击写 `LB_AWAIT_DONE` / `window.__lbAwaitDone`
   - 后台线程轮询 JS；检测到 done → `user done` → `LBBrowserAwaitFinish`（harvest Cookie）
2. `fixtures/_accept_browser_await.py`
   - 增加 `process_survived` / SpringBoard 检测
   - Cookie 成功只认 mock 路径含 `await_search` 且 `AWAIT_TOKEN=ok`
   - 进程已死则不再盲点「完成验证」冒充

**状态**：**已改待 commit**（本代理不 commit/push）；待父代理提交 → CI IPA → 真机复验。

## 复验步骤（新 IPA 到手后）

1. 确认 mock：`http://192.168.1.4:8765/health`
2. 装 CI Debug IPA（`xiangse_devkit.py --mcp http://192.168.1.18:8090 install …`）
3. `python fixtures/_accept_browser_await.py`
4. 深链探针：`legado://browserAwait?url=http://192.168.1.4:8765/await_gate.html`
   - 期望：进程存活；页可见；可点页内「完成验证」
5. 断言：marker 含 `user done` 或 `harvest done`；mock `/await_search*` Cookie 含 `AWAIT_TOKEN=ok`

## 装包与证据

### FAIL 基线 `51a63b7`

- CI run `30154271872` / IPA SHA256 `32d58333…f76044`
- 汇总：`fixtures/_devkit/browser_await/browser_await_accept_20260725T141502Z_51a63b7.json`

### FAIL 复验 `f142774`（本轮）

- CI run `30162067981` / commit `f14277429f427f274a619649cc1b2b27907b67f3`
- IPA：`dist/ci-artifact-30162067981/dist/StandarReader-legado-bridge-debug.ipa`
- IPA SHA256：`8393a71b88343ea527fb8cf0d6b61937340801afe1fe7876f6cc70a777ea6c6b`
- 验收 JSON（脚本曾报 PASS，实为假阳性）：`fixtures/_devkit/browser_await/browser_await_accept_20260725T144404Z.json`
- 截图：`await_wait_20260725T144404Z.png` / `await_after_20260725T144404Z.png`（均主屏）
- 对照：`webview` 存活 vs `browserAwait` ≤0.4s 杀进程（本轮探针）

关键 marker（杀进程前）：

```text
path=XiangseOpenWebView hit class=LCStandarConfig url=…/await_gate.html
path=XiangseOpenWebView returned class=LCStandarConfig
startBrowserAwait presented url=… title=网页验证
startBrowserAwait overlay host=WebViewController_WK hasBtn=1
```

## 受控源 / 验收脚本

| 路径 | 用途 |
|---|---|
| `fixtures/await_gate.html` | 写 `AWAIT_TOKEN=ok` |
| `fixtures/legado-browser-await-mock.json` | 受控源模板 |
| `.test_tools/serve_browser_await_mock.py` | 记 Cookie 的 mock |
| `fixtures/_accept_browser_await.py` | 真机验收（已收紧） |

## 下一步

1. 父代理 commit/push 本改动 → 等 CI Debug IPA。
2. 真机跑 `_accept_browser_await.py`，更新本页结论表。
3. 仍不做全能书源总验收。
