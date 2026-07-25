# 真实书源端到端（2026-07-25 起点正文上屏 PASS）

**本轮范围**：起点第一章正文真正上屏（非仅 `contentReady`）；目录 `chapters>0`、搜索条数不回归。全能书源总验收见 `deferred-full-verify.md`，本轮不做。

**书单条数**：PASS（`ok total=10`，`books_found=10`，`parsed_count=10`）  
**bookUrl**：PASS（样例 `https://m.qidian.com/book/1209977/`）  
**目录章数**：PASS（`catalogCache` / 既有 marker：`chapters=1681 first=上架感言`）  
**正文上屏**：PASS（种文件 `bodyLen=543` 含「又一次上架/土豆/月票」；阅读页截图可见完整「上架感言」正文；`contentReady` + `readerVis=1`）  
**装包 HEAD**：`efac2d4`（完整 `efac2d450ab5d60c07979abbf66d43c9ace2d55e`）  
**CI**：run `30153293936` 成功；artifact `LegadoBridge-IPA-Debug`  
**IPA SHA256**：`361b5083867321f726e677788b3e9084ee07a5c6350b70d7f02cd13b900290f7`（`StandarReader-legado-bridge-debug.ipa`）  
**dylib**：manifest `legado_bridge_sha256=70505d6ae43f2a320157a119103aa03a6cd743c01230119258d7799d3aa0b894`  
**包路径**：`fixtures/_devkit/ci-artifact-efac2d4/dist/StandarReader-legado-bridge-debug.ipa`  
**variant**：`legado-debug`（`reader-build-manifest.json`）  
**MCP**：`http://192.168.1.18:8090`  
**包名**：`com.appbox.StandarReader`

**相关提交（已在 main）**：

| commit | 内容 |
|---|---|
| `b1e63fd` | `data-*` 属性回落；空 bookUrl 按书名去重（书单条数 10） |
| `543465a` | `@` 链改 `RuleSplitter.splitTopLevel`（去掉「列表全文」误切） |
| `eb8cf90` | `@js` 链：`'prefix'+result+'suffix'` 走 Swift 拼接；其余 JSON 注入 `result`（修空 bookUrl） |
| `d555b40` | 目录 AllInOne：`:` 正则 → 捕获组上下文；`$N` / `$N@js` / `$N##` |
| `efac2d4` | 章 URL / `result.replace` 链 Swift 快路径（避免千章每章 JSContext 挂死；本轮装包） |

**本轮报告**：

- 正文验收：`fixtures/_devkit/phase88_visible_webview/qidian_content_accept_20260725T095838Z.json`
- 同内容：`qidian_content_accept_latest.json` / `qidian_content_efac2d4.json`
- 正文截图：`qidian_content_accept_20260725T095838Z.png`（另：`qidian_toc_content_20260725T094807Z.png` 已可见正文）
- 种文件探针：`qidian_seeded_content_probe.json`（`斗破苍穹_天蚕土豆/0`，543 字）
- 目录缓存：`device_catalog_cache_full.json`（`chapters=1681`）
- 搜索+目录（前序）：`qidian_toc_20260725T094807Z.json`

## 起点本轮（包 `efac2d4` Debug）

| 项 | 结果 |
|---|---|
| 装包 | PASS：manifest `git_commit=efac2d4…` / `github_run_id=30153293936` / `variant=legado-debug` |
| Cookie 带到搜索 | PASS：`need_cookie=false`（jar 仍在） |
| 书单条数 | **PASS**：`ok total=10`；`books_found=10`；`parsed_count=10` |
| bookUrl | **PASS**：`https://m.qidian.com/book/1209977/` 等 |
| 点进详情 / 目录 | **PASS**：`chapters=1681 first=上架感言`；缓存 `864340` 字节 |
| 阅读页正文 | **PASS**：`getContent`→seed `bodyLen=543`；截图可见「又一次上架了…土豆…」 |

## 根因链

1. `eb8cf90` 前：搜索 bookUrl 空 / 列表全文。
2. `eb8cf90`：详情 toc 线索已通，但 `chapters=0`。
3. **`getElements` 不识别 AllInOne（`:` 前缀正则）**，起点 `chapterList` 被当 CSS → 0 章。
4. `d555b40`：补 AllInOne + `$N` 取值后，真机千章每章跑 `@js` 新建 JSContext → 挂死、无 `legado_catalog_last.txt`。
5. `efac2d4`：起点 chapterUrl / VIP `result.replace` 走 Swift → `chapters=1681`，正文链路可走通。
6. **正文误判**：AX `get_ui_elements` 对 `TextReadTV` 自定义绘制常只返回「返回 | 章名 | 下拉可以刷新」，**不能**当作正文为空；OCR 对本页 CJK 也弱。可靠针：`xsfolder` 种文件 + 截图（本轮已取）。

## 诚实边界

- 起点：**搜索条数 + bookUrl + 目录章数>0 + 第一章正文上屏 已 PASS**（包 `efac2d4`，无需新装包）。
- 首章「上架感言」URL 在 vipreader 域，但页面仍返回可读感言正文（非空墙）；未改规则。
- 目录缓存里 `isVip` 常为 `null`（映射未写入 cache），不影响本轮正文。
- **未**开全能书源 / 领域书库 / 笔趣读总验收。
- **未**改计划文件 status。
- **未**为本轮改 Bridge 代码（证据显示 `efac2d4` 已上屏）。
