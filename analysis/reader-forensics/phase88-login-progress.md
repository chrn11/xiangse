# 登录页（香色 WebView / loginUi）进度

**日期**：2026-07-25  
**MCP**：`http://192.168.1.18:8090`  
**mock**：`http://192.168.1.4:8765`（`.test_tools/serve_browser_await_mock.py`，已加 `/mock_login.html` + login 源）  
**本轮不做**：全能书源 / 领域 / 笔趣读总验收；未改计划 status；不填真实账号。

## 结论

| 项 | 结果 |
|---|---|
| 触发路径是否 UIAlert 冒充 | **否（默认）**。`legado://login` 默认 `mode=webview` → `LBPresentLoginWebViewForSource` / `LBPresentVisibleWebView` → `LCStandarConfig openWebViewWithUrlStr:` → `WebViewController_WK`。仅 `mode=alert` 才出系统 Alert（对照用，非产品路径）。 |
| 打开正确登录页（受控 mock 表单） | **PASS**（当前装包 `51d5ed8`） |
| 完整填账号登录 | **PARTIAL**（勿瞎填真实账号；mock 表单可点，未做产品级账号登录） |
| `legado_login_ui_probe.txt`（loginUi 探针） | 当前包无；**已改待 commit**（见下） |

## 路径摸底

| 入口 | 行为 |
|---|---|
| `legado://login?sourceUrl=` | 解析书源 `loginUrl` → 香色可见 WebView |
| `legado://login?...&url=` | 直接打开给定 URL（仍走香色 WebView） |
| `legado://login?mode=alert` | 旧 UIAlert 用户名/密码（保留对照，禁止当产品门禁） |
| 书源字段 `loginUi` | 模型已有；旧包未写探针。本轮代码：落盘 `legado_login_ui_probe.txt`；无 `loginUrl` 时用 loginUi 生成 data: HTML 表单仍走 WebView |

## 真机验收（打开正确登录页）

- 包：`51d5ed8`（与 browserAwait 冷启动 PASS 同包）
- 脚本：`fixtures/_accept_login_ui.py`
- 步骤：导入 `legado-login-ui-mock.runtime.json` → `legado://login?sourceUrl=.../login-ui-source`（无 url 覆盖）
- 证据：
  - JSON：`fixtures/_devkit/login_ui/login_accept_20260725T152608Z.json`（亦写 `report.json`）
  - 截图：`fixtures/_devkit/login_ui/login_form_20260725T152608Z.png`
  - 基线：`fixtures/_devkit/login_ui/baseline.json`
- 关键事实：
  - `open visibleWV url=.../mock_login.html ... mode=书源登录/验证`
  - `path=XiangseOpenWebView hit class=LCStandarConfig`
  - UI：`书源登录表单 | 用户名 | username | 密码 | password | 登录`
  - `not_alert_only=true`；Alert 对照 `mode=alert` 可单独触发

## 已改待 commit（探针增强，需新 IPA 才验）

1. `BridgeSourceProtocol` / `MemoryBridgeBookSource`：暴露 `loginUi`
2. `LegadoBridgeCore.loginUiForSourceUrl:`
3. `LBPresentLoginWebViewForSource`：写 `legado_login_ui_probe.txt`（`path=XiangseWebLogin`）；无 loginUrl 时 data: HTML 回退
4. mock：`mock_login.html` / `legado-login-ui-mock.json`；`serve_browser_await_mock.py` 增加登录路由
5. 验收：`fixtures/_accept_login_ui.py`

装新包后复跑 `_accept_login_ui.py`，期望 `login_ui_probe_present=true`。

## 复验

```text
python fixtures/_accept_login_ui.py
```

mock health：`http://192.168.1.4:8765/health`；登录页：`/mock_login.html`；源：`/legado-login-ui-mock.runtime.json`。
