# 延后总验收备忘（2026-07-25）

用户决定：**现在不验全能书源 / 不全功能验收；先记下来，等功能做完再验。**

## 选源（源仓库 https://www.yckceo.com/yuedu/shuyuan/index.html）

没有单源覆盖全部能力。届时建议：

| 角色 | 书源 | 用来验什么 |
|---|---|---|
| 主 | 领域书库（lysxh.com） | Cookie、发现、搜索、详情、目录、正文、下一页、Cloudflare 网页等待 |
| 对照 | 笔趣读（详情 id/5811） | 登录表单、Cookie、图形验证码、搜索需登录；需真实账号，勿瞎填 |

## 总验收前必须先做完的开发项（未做完不要开总验）

- 起点书单解析 → **条数 + bookUrl + 目录 chapters=1681 + 第一章正文上屏已 PASS**（包 `efac2d4`，见 `real-source-e2e.md`）
- 网页等待 `startBrowserAwait` 真机走到并可完成人机
  - **2026-07-25（`efac2d4`）**：未触发；根因 `java` 全局不可见。
  - **2026-07-25（`51a63b7` / run `30154271872`）**：触发已 PASS；等待页可见 / 点完成 / Cookie 回灌仍 FAIL（原生挂钮杀进程）。
  - **2026-07-25（`6f25ffd` / run `30162463665`）**：开页存活 PASS；点「完成验证」后 Cookie/`await_search` 通，但点后 ≤1s 杀进程 → `process_survived` FAIL（EvalJS 轮询竞态）。
  - **2026-07-25（`5c758fe` / run `30162921072`）**：停 EvalJS + CookieStore 完成探测后，**冷启动** `browserAwait` ≤0.5s 杀进程 FAIL（Present 前碰 `WKHTTPCookieStore`）。
  - **2026-07-25（`51d5ed8` / run `30163275599`）**：Present 前不碰 CookieStore；冷启动 `browserAwait` 最小门禁 **PASS**（`process_survived` + user done/harvest + `/await_search` Cookie `AWAIT_TOKEN=ok`）。证据见 `phase88-browser-await-progress.md` 与 `fixtures/_devkit/browser_await/browser_await_accept_20260725T151942Z.json`。总验（领域/笔趣读）仍延后。
- 登录：香色原版网页/表单，而不是系统 Alert 冒充
  - **2026-07-25（`51d5ed8`）**：打开正确登录页 **PASS**（受控源 `loginUrl` → `mock_login.html`，`XiangseOpenWebView hit`，UI 可见表单；非 Alert）。完整账号登录 **PARTIAL**。
  - **2026-07-25（`ea8f85e` / run `30163674589` Debug）**：同上门禁 **PASS**，且 `login_ui_probe_present=true`（`path=XiangseWebLogin`，`loginUiLen=73`）。
  - **2026-07-25（`7cf8ccc` / run `30164112714`）**：mock 提交→成功页→jar 含 `LB_LOGIN` **PASS**（`mock_submit=PASS`）。证据：`phase88-login-progress.md`、`fixtures/_devkit/login_ui/login_accept_20260725T154429Z.json`。真实站账号仍 **PARTIAL**（勿瞎填；总验笔趣读时再做）。
- Cookie 带到搜索/后续请求（已有进展，总验时再回归）
- 至少 1 条真实源：搜索 → 详情 → **有章节的目录** → 香色正文（起点已满足；总验仍要覆盖领域/笔趣读）

## 已有、可留作回归对照（总验时复核，现在不专门开验）

- 本地 mock：香色阅读页翻页/切章/离线/进度
- 香色原版开网页（LCStandarConfig → WebViewController_WK）
- Cookie 回灌探针

## 执行约定

- 开发任务继续做；**总验收只开一次**，在上表开发项闭环后。
- 不要两个代理同时抢真机做验收。
- 不要改计划文件里的 completed 充数。
