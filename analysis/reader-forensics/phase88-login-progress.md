# 登录页（香色 WebView / loginUi）进度

**日期**：2026-07-25  
**MCP**：`http://192.168.1.18:8090`  
**mock**：`http://192.168.1.4:8765`（`.test_tools/serve_browser_await_mock.py`，已加 `/mock_login.html` + `/mock_login_ok.html` Set-Cookie）  
**本轮不做**：全能书源 / 领域 / 笔趣读总验收；未改计划 status；不填真实账号。

## 结论

| 项 | 结果 |
|---|---|
| 触发路径是否 UIAlert 冒充 | **否（默认）**。`legado://login` 默认 `mode=webview` → 香色 `WebViewController_WK`。仅 `mode=alert` 对照。 |
| 打开正确登录页（受控 mock 表单） | **PASS**（装包 `ea8f85e` / run `30163674589` Debug） |
| mock 填表提交 → 成功页 | **PASS**（`ea8f85e`）：`username=mock_user` → `/mock_login_ok.html`，UI `LOGIN_OK` |
| mock 提交后 Cookie 回灌 jar（`LB_LOGIN`） | **FAIL（现包）** → **已改待 commit** |
| 完整真实站账号登录 | **PARTIAL**（勿瞎填） |
| `legado_login_ui_probe.txt` | **PASS**：`path=XiangseWebLogin`，`loginUiLen=73` |

## 根因（Cookie 缺口）

香色原生路径开页后只在 Present 后固定延迟 harvest（旧逻辑 2.5s/5s）。表单 GET 提交导航到 `mock_login_ok` 后：

- WebView `document.cookie` 已有 `LB_LOGIN=ok; LB_USER=mock_user`（UI 可见）
- mock 请求日志有 `/mock_login_ok.html?username=mock_user`
- 但 **无再次 harvest**，`legado_cookie_dump.txt` / jar 仍是开页时旧 Cookie（含 `AWAIT_*`，无 `LB_LOGIN`）

## 代码改动（已改待 commit）

文件：`LegadoBridge/Sources/LegadoBridgeHooks/LBVisibleWebView.m`

- `LBScheduleXiangseCookieWatch`：开页后约 90s 内按 2s 轮询原生 WK URL；**导航变化立刻 harvest**，并刷新 `legado_visible_webview_open.txt`
- `LBWriteLoginCookieProbeIfNeeded`：jar 字符串含 `LB_LOGIN` 时落盘 `legado_login_cookie.txt`

脚本：`fixtures/_accept_login_ui.py` 增加门禁 B（填表→成功页→轮询 jar 含 `LB_LOGIN`）  
夹具：`fixtures/mock_login_ok.html` 写 `document.cookie` + 展示 `user=` / `cookie=`

**需新 IPA 复验** mock_submit 全绿；未 commit/push（按用户要求）。

## 真机证据（本轮 mock 提交，现包）

- JSON：`fixtures/_devkit/login_ui/login_accept_20260725T153638Z.json`
- 截图：`fixtures/_devkit/login_ui/login_form_20260725T153638Z.png`、`login_ok_20260725T153638Z.png`
- 关键事实：
  - `verdict=PASS`（开表单）
  - `mock_submit=FAIL`（`cookie_lb_login_in_jar=false`；其余 submitted / landed / mock_login_ok_request / alive 均为 true）
  - UI 成功页：`LOGIN_OK | user=mock_user | cookie=LB_LOGIN=ok; LB_USER=mock_user; ...`
  - `full_login=PARTIAL`

## 复验（新 IPA 装上后）

```text
python fixtures/_accept_login_ui.py
```

期望：`verdict=PASS` 且 `mock_submit=PASS`（`cookie_lb_login_in_jar=true`）；`full_login` 仍为 PARTIAL。
