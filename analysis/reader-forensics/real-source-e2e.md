# 真实书源端到端（2026-07-25 起点目录 chapters>0）

**本轮范围**：起点详情后目录 `chapters>0`；尽量第一章正文上屏。搜索条数与 bookUrl 不回归。全能书源总验收见 `deferred-full-verify.md`，本轮不做。

**书单条数**：PASS（`ok total=10`，`books_found=10`，`parsed_count=10`）  
**bookUrl**：PASS（样例 `https://m.qidian.com/book/1209977/`）  
**目录章数**：PASS（`legado_catalog_last.txt`：`toc=…/catalog/ chapters=1681 first=上架感言`）  
**正文上屏**：PARTIAL（已进香色阅读页 `readerVis=1`，`contentReady`，UI 见章名「上架感言」；正文区仍偏空/下拉刷新，首章为 VIP 向感言，未作为本轮硬门禁）  
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

- 搜索+目录：`fixtures/_devkit/phase88_visible_webview/qidian_toc_20260725T094807Z.json`
- 同内容：`qidian_toc_latest.json` / `qidian_toc_efac2d4.json`
- 上一轮详情（chapters=0）：`qidian_detail_20260725T092625Z.json`（`eb8cf90`）

## 起点本轮（包 `efac2d4` Debug）

| 项 | 结果 |
|---|---|
| 装包 | PASS：manifest `git_commit=efac2d4…` / `github_run_id=30153293936` / `variant=legado-debug` |
| Cookie 带到搜索 | PASS：`need_cookie=false`（jar 仍在） |
| 书单条数 | **PASS**：`ok total=10`；`books_found=10`；`parsed_count=10` |
| bookUrl | **PASS**：`https://m.qidian.com/book/1209977/` 等 |
| 点进详情 / 目录 | **PASS**：`chapters=1681 first=上架感言`；`catalogCache save n=1681` |
| 阅读页 | PARTIAL：`nativeOpen … readerVis=1`；`contentReady`；UI「上架感言」；正文非空未稳 |

## 根因链

1. `eb8cf90` 前：搜索 bookUrl 空 / 列表全文。
2. `eb8cf90`：详情 toc 线索已通，但 `chapters=0`。
3. **`getElements` 不识别 AllInOne（`:` 前缀正则）**，起点 `chapterList` 被当 CSS → 0 章。
4. `d555b40`：补 AllInOne + `$N` 取值后，真机千章每章跑 `@js` 新建 JSContext → 挂死、无 `legado_catalog_last.txt`。
5. `efac2d4`：起点 chapterUrl / VIP `result.replace` 走 Swift → `chapters=1681`。

## 诚实边界

- 起点：**搜索条数 + bookUrl + 目录章数>0 已 PASS**。
- 正文可读：阅读页已开、状态 `contentReady`，但首章正文上屏未稳定确认。
- **未**开全能书源 / 领域书库 / 笔趣读总验收。
- **未**改计划文件 status。
