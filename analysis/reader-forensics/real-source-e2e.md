# 真实书源端到端（2026-07-25）

**verdict**：FAIL（3/3 搜索空结果）  
**HEAD（可见 WebView 合入）**：`9b45997`  
**真实源跑机基线**：`196622b`（合入前旧包）  
**MCP**：`http://192.168.1.18:8090`  
**报告**：`fixtures/_devkit/real_source_e2e/report.json`（gitignore）  
**脚本**：`fixtures/_accept_real_source_e2e.py`（同逻辑副本亦在 `.test_tools/`）  
**选源来源**：公开订阅 [XIU2/Yuedu `shuyuan`](https://cdn.jsdelivr.net/gh/XIU2/Yuedu@master/shuyuan)（无密钥）

## 源名单与结果

| # | 书源 | bookSourceUrl | 关键字 | 搜索 marker | 结论 | 失败点 |
|---|---|---|---|---|---|---|
| 1 | 得奇小说网 | `https://www.deqixs.com` | 斗破苍穹 | `ok total=0 sources=1` | **FAIL** | 设备侧 `download_url` 同源搜索页 **HTTP 403**（站点挡爬/盾） |
| 2 | 大熊猫文学网 | `https://www.dxmwx.org` | 斗破苍穹 | `ok total=0 sources=1` | **FAIL** | 设备侧 `download_url` **超时**；引擎 0 条 |
| 3 | 起点中文 | `https://www.qidian.com` | 斗破苍穹 | `ok total=0 sources=1` | **FAIL** | 书源注释明确要求**内置浏览器过 Cookie 验证**；`ruleSearch` 含 `java.startBrowserAwait`；无可见 WebView 时预期失败 |

附：酷我根路径设备下载 `http_status=200` 但 `bytes=0`（无可用正文探测）。

截图：`fixtures/_devkit/real_source_e2e/{deqi,dxmwx,qidian}_search_*.png`（搜索空列表 UI）。

## 含义

- 引擎「能搜」在 mock 上成立；**真实源首次真机跑通未达成**。
- 起点是**可见 WebView / CookieJar** 的直接需求源，不是规则写错 alone。
- 得奇 403 说明部分站在 App HTTP 客户端路径即被挡，需 WebView 过盾后再回灌 Cookie。

## 诚实边界

- 本轮**未**把真实源标 PASS。
- **未**把 `legado-feature-parity` 标 completed。
- 8.7 `BackstageWebView` 真导航 PASS **不等于**可见过盾/登录完成。

## 夹具（本地）

- `fixtures/_devkit/real_source_e2e/deqi.json` / `dxmwx.json` / `qidian.json` / `kuwo.json` / `ttkan.json`
- `picked.json`、`report.json`、搜索截图、可选 `probe_*.html`
