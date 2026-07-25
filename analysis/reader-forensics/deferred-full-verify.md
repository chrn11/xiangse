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
  - **2026-07-25（`51a63b7` / run `30154271872`）**：触发已 PASS（`handler=true` + overlay + `XiangseOpenWebView` + mock `await_gate.html`）；**等待页前台可见 / 点「完成验证」/ `/await_search` Cookie 回灌仍 FAIL**。根因升级：对照 `legado://webview` 存活 vs `browserAwait` **进程被杀→SpringBoard**（无新 crash report）；旧实现往 keyWindow 挂钮 + 主线程 Finish 信号量。代码已改（`LBVisibleWebView.m`：先开页、钮挂 WebView VC、Finish 转后台），**已改未提交，待 commit/CI 新 IPA 真机复验**。见 `phase88-browser-await-progress.md`；**最小门禁整体仍勿标 PASS**。
- 登录：香色原版网页/表单，而不是系统 Alert 冒充
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
