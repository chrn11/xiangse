# 登录页（香色 WebView / loginUi）进度

**日期**：2026-07-25  
**MCP**：`http://192.168.1.18:8090`  
**mock**：`http://192.168.1.4:8765`（`.test_tools/serve_browser_await_mock.py`，已加 `/mock_login.html` + `/mock_login_ok.html` Set-Cookie）  
**本轮不做**：全能书源 / 领域 / 笔趣读总验收；未改计划 status；不填真实账号。

## 结论

| 项 | 结果 |
|---|---|
| 触发路径是否 UIAlert 冒充 | **否（默认）**。`legado://login` 默认 `mode=webview` → 香色 `WebViewController_WK`。仅 `mode=alert` 对照。 |
| 打开正确登录页（受控 mock 表单） | **PASS**（装包 `7cf8ccc` / run `30164112714` Debug） |
| mock 填表提交 → 成功页 | **PASS**（`7cf8ccc`）：`username=mock_user` → `/mock_login_ok.html`，UI `LOGIN_OK` |
| mock 提交后 Cookie 回灌 jar（`LB_LOGIN`） | **PASS**（`7cf8ccc`）：导航后轮询 harvest，`cookie_lb_login_in_jar=true` |
| 完整真实站账号登录 | **PARTIAL**（勿瞎填） |
| `legado_login_ui_probe.txt` | **PASS**：`path=XiangseWebLogin`，`loginUiLen=73` |

## 修复（已合入 `7cf8ccc`）

文件：`LegadoBridge/Sources/LegadoBridgeHooks/LBVisibleWebView.m`

- `LBScheduleXiangseCookieWatch`：开页后约 90s 内按 2s 轮询原生 WK URL；**导航变化立刻 harvest**，并刷新 `legado_visible_webview_open.txt`
- `LBWriteLoginCookieProbeIfNeeded`：jar 字符串含 `LB_LOGIN` 时落盘 `legado_login_cookie.txt`

脚本：`fixtures/_accept_login_ui.py` 门禁 B（填表→成功页→轮询 jar 含 `LB_LOGIN`）  
夹具：`fixtures/mock_login_ok.html` 写 `document.cookie` + 展示 `user=` / `cookie=`

CI：run `30164112714` success；真机 manifest `git_commit=7cf8ccc…` / `github_run_id=30164112714`。

## 真机证据（`7cf8ccc` 复验 PASS）

- JSON：`fixtures/_devkit/login_ui/login_accept_20260725T154429Z.json`
- 截图：`fixtures/_devkit/login_ui/login_form_20260725T154429Z.png`、`login_ok_20260725T154429Z.png`
- 关键事实：
  - `verdict=PASS`（开表单）
  - `mock_submit=PASS`（`cookie_lb_login_in_jar=true`；submitted / landed / mock_login_ok_request / cookie_harvest_seen / alive 均为 true）
  - 导航后 marker：`xiangse path nav url=.../mock_login_ok.html?username=mock_user` → 立刻 `cookieJarSaved` / `WKCookieStore harvest done`
  - dump：`LB_LOGIN=ok; LB_USER=mock_user`
  - UI 成功页：`LOGIN_OK | user=mock_user | cookie=LB_LOGIN=ok; LB_USER=mock_user; ...`
  - `full_login=PARTIAL`

## 上一轮对照（`ea8f85e`，无 CookieWatch）

- `verdict=PASS`，填表到 `LOGIN_OK` 也 PASS
- `mock_submit=FAIL`：仅开页 harvest，jar 无 `LB_LOGIN`
- 证据：`fixtures/_devkit/login_ui/login_accept_20260725T153638Z.json`

## 复验命令

```text
python tools/xiangse_devkit.py --mcp http://192.168.1.18:8090 install --run-id 30164112714 --expected-run 30164112714 --expected-sha 7cf8ccc
python fixtures/_accept_login_ui.py
```

期望：`verdict=PASS` 且 `mock_submit=PASS`；`full_login` 仍为 PARTIAL。
