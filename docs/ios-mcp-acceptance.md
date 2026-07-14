# iOS MCP 真机验收指南（xiangse）

面向 `com.appbox.StandarReader`（香色 / StandarReader）注入后 IPA 的真机验收。通道为局域网 **ios-mcp**，不依赖 hook103 等第三方 dylib。

## 通道信息

| 项 | 值 |
| --- | --- |
| MCP 端点 | `http://192.168.1.6:8090/mcp` |
| 健康检查 | `http://192.168.1.6:8090/health` |
| 目标 Bundle ID | `com.appbox.StandarReader` |

健康检查示例（超时宜短）：

```bash
curl.exe --connect-timeout 3 --max-time 5 http://192.168.1.6:8090/health
```

期望返回含 `"status":"ok"`、`"server":"ios-mcp"`。

## 局域网 mock 书源（搜索→目录→正文）

在与真机同网段的 PC 上起静态 HTTP，书源 `searchUrl` 指向该地址，用于证明 Bridge 能吃到真实 HTML。

```powershell
# 仓库根目录；默认探测 192.168.1.6 出站网卡 IP，监听 0.0.0.0:8765
python fixtures/serve_local_mock.py
# 或：python .test_tools/serve_local_mock.py --host 192.168.1.4 --port 8765
```

启动后会写出 `fixtures/legado-local-mock.runtime.json`（`__LAN_HOST__` 已替换）。提供页面：

| 路径 | 用途 |
| --- | --- |
| `/mock_search.html` | 搜索结果（斗破苍穹 / 凡人修仙传） |
| `/book/doupo.html`、`/book/doupo_toc.html` | 详情 / 目录 |
| `/chapter/doupo_1.html` | 正文（含「萧炎」「本地 mock」等可识别文字） |

导入：`open_file_with_app` 推送 runtime JSON，或 `legado://import/bookSource?src=http://<PC_IP>:8765/legado-local-mock.runtime.json`。搜索：`legado://search?keyword=斗破` 或 UI 回车。

## 操作约定（必读）

1. **锁屏**：先 `wake_and_home`，再用 `screenshot` / `get_ui_elements` / `get_frontmost_app` 确认已到桌面或解锁界面；勿把单次 `press_home` 当成已进主屏。
2. **点击**：优先 `tap_element`（按文案/无障碍标识），坐标点击仅作兜底。
3. **输入**：先 `input_text`；失败或超时立即改 `type_text`，不要重复 `input_text`。
4. **截图**：`screenshot` 返回 MCP image content，取 `content[0].data`（base64）与 `mimeType`。
5. **安装**：本机 IPA 先 `POST /upload_file`（头 `X-Filename`），再把返回的设备路径交给 `install_app`；支持未签名 / fakesign IPA（TrollStore / 注入包场景）。

## 安装注入 IPA（TrollStore / 无签名）

1. 确认 `/health` 可达，必要时 `get_device_info` 确认越狱/安装环境。
2. 上传 IPA：

```bash
curl.exe -H "X-Filename: StandarReader.ipa" --data-binary @StandarReader.ipa http://192.168.1.6:8090/upload_file
```

3. 用返回路径调用 MCP `install_app`。
4. `list_apps` / `get_app_info` 确认 `com.appbox.StandarReader` 已安装。
5. `launch_app` 启动；`assert_app_launched` 或 `get_frontmost_app` 核对前台包名。

**明确不做**：不依赖 hook103、不依赖额外第三方注入 dylib 作为验收前置；验收对象即为「已注入/可运行」的 IPA 本体行为。

## 功能验收清单

按顺序执行；每步失败用 `screenshot` + `ocr_screen` / `get_ui_elements` + 必要时 `get_syslog` 留证。

### A. 启动与书架

- [ ] 启动后进入书架/主界面，无崩溃闪退
- [ ] 可见导入、搜索、目录相关入口（文案以实际 UI 为准）

### B. 导入

- [ ] 走导入流程（本机文件 / 打开方式等，可用 `open_file_with_app` 或 App 内导入）
- [ ] 导入后书架出现对应书目
- [ ] 沙盒侧可用 `get_app_info` 取 data container，再 `list_dir` / `read_file` 抽查（只读核对，勿写破坏性数据）

### C. 搜索

- [ ] 进入搜索，输入关键词（`input_text` → 失败则 `type_text`）
- [ ] 结果列表与关键词相关；空结果有明确提示而非崩溃

### D. 目录

- [ ] 打开某书目录/章节列表
- [ ] 可点选章节并跳转；返回目录状态正常

### E. 正文阅读

- [ ] 正文可翻页/滚动，字体或主题切换（若有）不崩
- [ ] 断网/锁屏唤醒后可恢复阅读进度（`wake_and_home` 后重新 `launch_app` 验证）
- [ ] 进度与章节缓存由香色原生持有（Bridge 不另建缓存文件）；`legado_bridge_books.json` 仅存绑定

### F. 删源语义待复核（iOS MCP · 阻断真机验收项）

> 静态证据无法确认原版「删站点是否连带删书架书籍」。当前产品默认：
> `SourceDeletePolicy.keepBooksMarkUnavailable`（保留书籍与进度，标记书源不可用）。
> 可用 `LegadoBridgeCore.sourceDeletePolicyRaw = 1` 切换为清除桥接层绑定。

在**未修改**的 2.56.1 基线 IPA 上取证后，再决定是否改默认策略：

- [ ] 基线：加入一本原生 XBS 书 → 删除对应站点 → 观察书架书是否仍在、进度是否保留
- [ ] 注入包：Legado 搜索加书架 → 删该 Legado 源 → 书仍在且 `sourceAvailable=0`；重新导入同源后可再打开目录
- [ ] 若基线行为是「连带删书」，将默认策略改为 `clearBridgeBindings` 并补自动化回归

### G. 收尾

- [ ] `report_test_result`（若流程需要）记录通过/失败
- [ ] 失败项附截图 data、前台 Bundle ID、关键 syslog 片段

## 常用 MCP 工具速查

| 用途 | 工具 |
| --- | --- |
| 设备概况 | `get_device_info` |
| 唤醒解锁 | `wake_and_home` |
| 装包 | `upload_file`（HTTP）+ `install_app` |
| 启停 | `launch_app` / `kill_app` |
| 触控 | `tap_element` / `swipe_screen` |
| 识屏 | `get_ui_elements` / `ocr_screen` / `screenshot` |
| 沙盒 | `get_app_info` / `list_dir` / `read_file` |
| 日志 | `get_syslog` / `tail_app_log` |
| URL Scheme | `open_url` |

## 与 hook103 的关系

仓库内可有 hook103 参考文档，但 **本验收通道不以 hook103 第三方 dylib 为依赖**。真机结论以 ios-mcp 上安装并运行的目标 IPA（`com.appbox.StandarReader`）行为为准。

## devkit 快速用法（Windows CLI）

主入口：`tools/xiangse_devkit.py`（`.test_tools/` 已被 gitignore，勿放可提交脚本）。报告与截图默认写入 `fixtures/_devkit/`（已 ignore）。

环境变量（可选）：

| 变量 | 默认 |
| --- | --- |
| `XIANGSE_MCP` | `http://192.168.1.6:8090` |
| `XIANGSE_MOCK` | `http://192.168.1.4:8765` |
| `XIANGSE_BUNDLE` | `com.appbox.StandarReader` |

PowerShell 示例（用 `;` 串联，勿用 `&&`）：

```powershell
# 健康与沙盒路径
python tools/xiangse_devkit.py status

# 清 openOnce + trace/marker（可选 --backup）
python tools/xiangse_devkit.py reset

# 拉 trace 关键词
python tools/xiangse_devkit.py trace --json

# 深链 nativeRead（需 mock 已起：python fixtures/serve_local_mock.py）
python tools/xiangse_devkit.py read

# 装 CI 最新成功 artifact 或本地 IPA
python tools/xiangse_devkit.py install --ipa dist\StandarReader-legado-bridge.ipa
python tools/xiangse_devkit.py install

# 崩溃摘要 + marker SIGNAL
python tools/xiangse_devkit.py crash

# 一键验收：reset → mock 检查 → nativeRead → 萧炎 assert → 阅读页门禁 → JSON
python tools/xiangse_devkit.py accept
python tools/xiangse_devkit.py accept --install
```

`accept` 报告字段（节选）：`prefer_count`、`xiaoyan_passed`、`reader_ui_ok`（排除仍停在空书架）、`still_in_app`、`signals`、`trace_tail`、`report_path`。套件**不修复** Bridge 正文上屏；`SIGNAL sig=6`、空书架等会如实写入报告供后续排查。

共用 MCP 客户端：`tools/ios_mcp_client.py`（`fixtures/_accept_strict_render.py` 等脚本可 `from tools.ios_mcp_client import McpClient`）。
