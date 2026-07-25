# 真实书源端到端（2026-07-25 起点 bookUrl + 详情）

**本轮范围**：起点搜索不破条数，且至少 1 条可用 `bookUrl`，能点进详情（有目录线索即可）。全能书源总验收见 `deferred-full-verify.md`，本轮不做。

**书单条数**：PASS（`ok total=10`，`books_found=10`，`parsed_count=10`）  
**bookUrl**：PASS（parse 探针均为 `https://m.qidian.com/book/<bid>/`）  
**详情/目录线索**：PASS（`legado_catalog_last.txt`：`toc=…/catalog/`，`chapters=0` 仅为章列表解析未出数，不挡本轮）  
**装包 HEAD**：`eb8cf90`（完整 `eb8cf904300f2a4db732c60eee580e295577697f`）  
**CI**：run `30152582640` 成功；artifact `LegadoBridge-IPA-Debug`  
**IPA SHA256**：`40f232fc1d21178223f260c2a80a5867366d78632a332fe19aa4fa5ab3d89bff`  
**variant**：`legado-debug`（`reader-build-manifest.json`）  
**MCP**：`http://192.168.1.18:8090`  
**包名**：`com.appbox.StandarReader`

**相关提交（已在 main）**：

| commit | 内容 |
|---|---|
| `b1e63fd` | `data-*` 属性回落；空 bookUrl 按书名去重（书单条数 10） |
| `543465a` | `@` 链改 `RuleSplitter.splitTopLevel`（去掉「列表全文」误切） |
| `eb8cf90` | `@js` 链：`'prefix'+result+'suffix'` 走 Swift 拼接；其余 JSON 注入 `result`（修空 bookUrl；本轮装包） |

**本轮报告**：

- 搜索：`fixtures/_devkit/phase88_visible_webview/qidian_cookie_search_20260725T092311Z.json`
- 同内容：`qidian_cookie_search_latest.json` / `qidian_cookie_search_eb8cf90.json`
- 详情：`fixtures/_devkit/phase88_visible_webview/qidian_detail_20260725T092625Z.json`（`qidian_detail_latest.json`）

## 起点本轮（包 `eb8cf90` Debug）

| 项 | 结果 |
|---|---|
| 装包 | PASS：manifest `git_commit=eb8cf90…` / `github_run_id=30152582640` / `variant=legado-debug` |
| Cookie 带到搜索 | PASS：`cookieAttached=true` |
| 搜索 URL | PASS：无 `/undefined` |
| 书单条数 | **PASS**：`ok total=10`；`books_found=10`；`parsed_count=10` |
| bookUrl | **PASS**：样例 `https://m.qidian.com/book/1209977/` 等；非列表全文、非空 |
| 点进详情 | **PASS**：`openURL nativeRead book=https://m.qidian.com/book/1209977/`；catalog marker `ok … toc=https://m.qidian.com/book/1209977/catalog/ chapters=0` |
| 章节列表数 / 正文 | `chapters=0`；正文未作为本轮门禁（见延后总验） |

## 根因链

1. `b1e63fd` 前：书单条数不稳 / 去重成 1。
2. `543465a`：`@` 链切不开 → bookUrl 变成列表项全文；切开后 bookUrl 又变空。
3. `eb8cf90`：`@js` 段依赖裸 `JSContext.setValue(result)`，全局 `result` 未生效；对起点规则 `'https://m.qidian.com/book/'+result+'/'` 改为 Swift 拼接，其余用 JSON 字面量注入。

## 诚实边界

- 起点：**搜索条数 + 可用 bookUrl + 详情请求（含 toc 线索）已 PASS**。
- **未**开全能书源 / 领域书库 / 笔趣读总验收。
- **未**把计划里的 feature parity 标 completed。
- 章列表解析出 0、正文可读：仍记在 `deferred-full-verify.md`。
