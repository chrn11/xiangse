# 登录页（香色 WebView / loginUi）进度

**日期**：2026-07-25  
**MCP**：`http://192.168.1.18:8090`  
**mock**：`http://192.168.1.4:8765`（`.test_tools/serve_browser_await_mock.py`，已加 `/mock_login.html` + login 源）  
**本轮不做**：全能书源 / 领域 / 笔趣读总验收；未改计划 status；不填真实账号。

## 结论

| 项 | 结果 |
|---|---|
| 触发路径是否 UIAlert 冒充 | **否（默认）**。`legado://login` 默认 `mode=webview` → `LBPresentLoginWebViewForSource` / `LBPresentVisibleWebView` → `LCStandarConfig openWebViewWithUrlStr:` → `WebViewController_WK`。仅 `mode=alert` 才出系统 Alert（对照用，非产品路径）。 |
| 打开正确登录页（受控 mock 表单） | **PASS**（装包 `ea8f85e` / run `30163674589` Debug） |
| 完整填账号登录 | **PARTIAL**（勿瞎填真实账号；mock 表单可点，未做产品级账号登录） |
| `legado_login_ui_probe.txt`（loginUi 探针） | **PASS**：`login_ui_probe_present=true`，`path=XiangseWebLogin`，`loginUiLen=73` |

## 路径摸底

| 入口 | 行为 |
|---|---|
| `legado://login?sourceUrl=` | 解析书源 `loginUrl` → 香色可见 WebView |
| `legado://login?...&url=` | 直接打开给定 URL（仍走香色 WebView） |
| `legado://login?mode=alert` | 旧 UIAlert 用户名/密码（保留对照，禁止当产品门禁） |
| 书源字段 `loginUi` | 模型已有；探针落盘 `legado_login_ui_probe.txt`（`path=XiangseWebLogin`）；无 `loginUrl` 时用 loginUi 生成 data: HTML 表单仍走 WebView |

## 真机验收（打开正确登录页 + 探针）

- 包：`ea8f85e`（CI run `30163674589`，`LegadoBridge-IPA-Debug`；manifest `git_commit=ea8f85ee92ac776335e38195335fc392aec1ad3c`）
- 脚本：`fixtures/_accept_login_ui.py`
- 步骤：导入 `legado-login-ui-mock.runtime.json` → `legado://login?sourceUrl=.../login-ui-source`（无 url 覆盖）
- 证据：
  - JSON：`fixtures/_devkit/login_ui/login_accept_20260725T153241Z.json`（亦写 `report.json`）
  - 截图：`fixtures/_devkit/login_ui/login_form_20260725T153241Z.png`
- 关键事实：
  - `open visibleWV url=.../mock_login.html`
  - `path=XiangseOpenWebView hit class=LCStandarConfig`
  - `legado_login_ui_probe.txt`：`login present ... loginUiLen=73 path=XiangseWebLogin`
  - UI：`书源登录表单 | 用户名 | username | 密码 | password | 登录`
  - `not_alert_only=true`；`login_ui_probe_present=true`；Alert 对照 `mode=alert` 可单独触发
  - `verdict=PASS`；`full_login=PARTIAL`

## 前序对照

- `51d5ed8`：打开正确登录页已 PASS；当时包无 loginUi 探针文件。
- `ea8f85e`：同上门禁 + 探针增强复验 PASS。

## 复验

```text
python fixtures/_accept_login_ui.py
```

mock health：`http://192.168.1.4:8765/health`；登录页：`/mock_login.html`；源：`/legado-login-ui-mock.runtime.json`。
