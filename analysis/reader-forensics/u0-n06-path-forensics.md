# U0-N06 本地 TXT 导入路径取证

**日期**：2026-07-27  
**结论状态**：**BLOCKED**（**不宣称 PASS**）  
**正文针**：未命中「角色甲」/「本地TXT」

---

## 1. 分流逻辑（代码）

文件：`LegadoBridge/Sources/LegadoBridgeHooks/LBImportHooks.m`

`AppDelegate application:openURL:options:` Hook：

1. 调试落盘 `Documents/legado_openurl_hit.txt` = URL 原文  
2. `legado://` / `yuedu://` → Bridge 深链（导入/搜索/nativeRead 等），`return YES`  
3. **`file://`**：读文件 bytes → `probeLegadoJSONData:`  
   - **是 Legado JSON** → `importLegadoJSONData:`，写 `legado_islegado_result.txt=YES`，**短路原生**，`return YES`  
   - **不是 Legado JSON**（含 TXT）→ **调用原 IMP**，走香色原生 xbs/txt 分流  
4. 文档与注释：系统「打开方式」会把文件拷到 `Documents/Inbox/<file>` 再进此入口（见 `docs/hook-map.md`）

因此：**只要系统真正把 TXT 以 document-open 投进 `openURL`，Hook 会放行原生**，不会当书源 JSON 吃掉。

---

## 2. 文档 / App 自述路径

| 来源 | 内容 |
|------|------|
| `docs/hook-map.md` | `open_file_with_app` 应复制到 Inbox 并经 `application:openURL:options:` 投递 |
| `docs/ios-mcp-acceptance.md` | 导入可用 `open_file_with_app`（主要针对 JSON 书源） |
| App 侧栏「添加」文案（真机截图） | **通过微信/浏览器等 App 导入 txt**：点 TXT →「用其他应用打开」→「香色闺阁」 |
| `Info.plist` `CFBundleDocumentTypes` | 含 **`public.text`**（与 xbs 等同声明），理论支持 TXT |

官方人工路径 = iOS Share / Open In → Inbox → 原生 openURL。  
**不是** App 内文件选择器；侧栏只写第三方 App「用其他应用打开」。

---

## 3. 真机自动化尝试（MCP `http://192.168.1.18:8090`）

夹具：`fixtures/u0_local_smoke.txt`（含「角色甲」「本地TXT」）

| 步骤 | 结果 |
|------|------|
| `wake_and_home` + `upload_file` | OK |
| `open_file_with_app(txt → StandarReader)` | **返回成功**；Inbox 出现 `*-u0_local_smoke.txt` |
| 读 `Documents/legado_openurl_hit.txt` | **文件不存在** → **未进入** AppDelegate openURL Hook |
| 书架 UI | 仍只有示例书，**无**本地冒烟书 |
| OCR/AX | **无**「角色甲」/「本地TXT」 |
| `open_url(file:///.../Inbox/u0_local_smoke.txt)` | ios-mcp 弹「**不支持的 URL** / 尚未载入此 URL」遮罩（可关） |
| 冷启动后再 `open_file_with_app` | 同上：Inbox 有文件，**无** openURL 标记，无正文 |
| 点导航「添加」/侧栏 | 见官方微信导入文案（`u0-n06-import-menu.png`） |
| 会话后段 | 设备 **锁屏要密码**，`wake_and_home` 无法解锁，后续 UI/`uiopen` 停在锁屏 |

---

## 4. 结论

### 可自动化路径

**当前：无完整可自动化 E2E 路径**（拷贝 Inbox ≠ 完成导入）。

已打通的半截：

1. `upload_file` / `write_file` → `Documents/Inbox/*.txt`（**可靠**）  
2. 缺：**真正触发** `application:openURL:options:`（或等价 Scene document open）  
3. 缺：阅读页 OCR 命中「角色甲」/「本地TXT」

理论闭环（代码+声明支持，**未在本回合跑通**）：

```text
Share/Open In「香色闺阁」
  → Documents/Inbox/<name>.txt
  → AppDelegate openURL
  → Hook 判定非 Legado JSON
  → 原 IMP 原生 TXT
  → 书架/阅读 → 正文针
```

`open_file_with_app` **只完成拷贝**，**不完成投递**（与 `docs/hook-map.md` 描述不一致）。  
`MCP open_url(file://)` **不可用**（ios-mcp「不支持的 URL」）。

### BLOCKED 根因

1. **主因**：ios-mcp `open_file_with_app` 未触发 App 的 document-open / `openURL`（无 `legado_openurl_hit.txt`）。  
2. **次因**：`open_url(file://)` 被 MCP 拒绝，且曾留下遮罩干扰取证。  
3. **会话末**：设备锁屏需密码，自动化无法继续点「添加」或试 `uiopen`。  
4. **验收**：从未出现正文针 → **禁止标 N06 PASS**。

### 下一步人工步骤

1. 解锁真机（密码/Face ID）。  
2. 将 `fixtures/u0_local_smoke.txt` 发到手机（隔空投送/微信/Files）。  
3. 按 App 侧栏：**用其他应用打开 → 香色闺阁**。  
4. 书架出现书后打开阅读，确认正文含 **「角色甲」** 或 **「本地TXT」**。  
5. 若人工 Open In **成功**：向 ios-mcp 排查 `open_file_with_app` 是否缺少 `LSOpenURL` / Inbox 投递；修好后脚本可自动化为：`upload → open_file_with_app（修复后）→ OCR 针`。  
6. 若人工 Open In **也失败**：再查原生 Inbox 消费 / Scene `openURLContexts`（当前 Hook 只挂 AppDelegate）。

---

## 5. 证据路径

| 文件 | 说明 |
|------|------|
| `analysis/reader-forensics/u0-n06-path-forensics.md` | 本报告 |
| `analysis/reader-forensics/u0-n06-clean-open-SUMMARY.json` | 清遮罩后 open_file；Inbox 拷贝、无 openURL hit；plist `public.text` |
| `analysis/reader-forensics/u0-n06-clean-shelf.png` | 干净书架 |
| `analysis/reader-forensics/u0-n06-clean-after-open.png` | open_file 后仍示例书 |
| `analysis/reader-forensics/u0-n06-import-menu.png` | 侧栏官方 TXT 导入说明 |
| `analysis/reader-forensics/u0-n06-path-probe-SUMMARY.json` | 首轮 Inbox/open_url 探测 |
| `analysis/reader-forensics/u0-n06-after-open-20260727_005641.png` | 首轮后仍在 mock 斗破章 |
| `analysis/reader-forensics/u0-n06-after-fileurl-20260727_005641.png` | file:// → 不支持的 URL |
| `analysis/reader-forensics/u0-n06-cold-open-SUMMARY.json` | 冷启动 open_file |
| `analysis/reader-forensics/u0-n06-inbox-direct-SUMMARY.json` | Inbox 内文件再 open |
| `analysis/reader-forensics/u0-n06-unlock-add-SUMMARY.json` | 锁屏阻断 |
| `analysis/reader-forensics/u0-n06-SUMMARY.json` | 更早 PENDING（仅推 Documents） |
| `.test_tools/u0_n06_*.py` | 本回合探测脚本 |

---

## 6. N06 判定

| 项 | 状态 |
|----|------|
| N06 PASS | **否** |
| 可自动化全路径 | **否（BLOCKED）** |
| 建议进度板 | 保持 **PENDING/BLOCKED**：根因 = MCP document-open 投递缺失；人工 Open In 验证后可改写 |
