# MVP 验收报告 — 香色闺阁 Legado 注入

> 日期：2026-07-11（文档校正）  
> 版本：LegadoBridge 1.0.0-mvp  
> 目标 IPA：香色闺阁 2.56.1（`com.appbox.StandarReader`）  
> 协议锁：legado-E **3.26.030717**  
> 基线哈希：[`docs/baseline-hashes.md`](baseline-hashes.md) / [`analysis/baseline-hashes.json`](../analysis/baseline-hashes.json)

## 验收范围

| 步骤 | 状态 | 说明 |
|------|------|------|
| IPA 解压与基线分析 | 通过 | `analysis/baseline.json` + `analysis/baseline-hashes.json`，无 Frameworks |
| Hook 映射文档 | 通过 | `docs/hook-map.md` 四条链路 |
| hook103 参考清单 | 通过（文档） | `docs/hook103-reference.md`；**禁止**依赖其第三方 dylib |
| LegadoBridge 工程 | 通过 | SPM + ObjC Hook + 引擎 vendor + `LegadoBridgeTests` |
| 导入 Hook | 通过（代码） | `openURL` 主入口 + `NSJSONSerialization` 备用 + `SourceRegistry` 持久化 |
| 搜索 Hook | 通过（代码） | `BookSourceManager startSearch` + 通知注入 |
| 目录 / 正文 | 通过（代码） | `LBReadingHooks` + `BookBindingStore`：`setDicBook:` / `loadCatalog:` / `loadCurCp` / `addBook:`；持久映射 `legado_bridge_books.json` |
| Hook 拆分 / 能力表 | 通过 | `LBSwizzle` 拆为五组 + `LBCapabilityRegistry` fail-open；管理页展示状态 |
| 书源持久化 | 通过（代码） | `Documents/legado_bridge_sources.json`，支持启停与重启恢复 |
| 书籍绑定 / 原生书架 | 通过（代码） | `BookBindingStore`：bookUrl/sourceUrl/bridgeToken；删源默认保留书籍并标记不可用（待真机复核） |
| post-core 换源/发现/净化 | 通过（代码） | 见 [`post-core.md`](post-core.md)：`ChapterMatcher`、分组筛选、`ReplaceEngine`/`ReplaceRuleStore` |
| 重打包流水线 | 通过（脚本） | `tools/repack/repack.sh` / `.ps1` |
| 真机 TrollStore | 待用户 | 需 macOS CI 产出含 insert_dylib 的 IPA |

## 测试书源

### 1. 简单源 — `fixtures/legado-simple.json`

- 类型：静态 CSS/XPath 规则
- 用途：验证导入识别 + 搜索规则解析
- Legado 识别：`bookSourceUrl` + `ruleSearch` ✓

### 2. JS 重度源 — `fixtures/legado-js-heavy.json`

- 类型：`@js:` searchUrl、bookList、content、webJs
- 用途：验证 JavaScriptCore + `java.*` 桥接路径
- 依赖：legado-ios `JSBridge.swift`（已 vendor）

## 本地自动化验证

```
python .test_tools/gen_baseline_hashes.py
python .test_tools/validate_baseline_and_tests.py
→ 校验 IPA 哈希、关键 selector、文档、Package 测试 target、Registry 语义镜像

# macOS / CI（iOS SDK）：
swift test --package-path LegadoBridge
→ SourceRegistry：单源/数组导入、重复源、禁用、持久化恢复
→ BookBindingStore：绑定/落盘/删源策略/不串源；Adapter token 字段
→ post-core：章节匹配、分组/发现标记、ReplaceRuleStore 净化
```

> **Windows 说明**：本机无 iOS SDK 时无法执行 `swift test`；以 `.test_tools/validate_baseline_and_tests.py` 作结构与语义镜像门禁，完整 Swift 测试留给 macOS CI。

## 真机验收清单（用户执行）

- [ ] TrollStore 安装 `dist/StandarReader-legado-bridge.ipa`
- [ ] 导入 `fixtures/legado-simple.json`（文件分享 → 香色闺阁）
- [ ] 站点管理中出现 Legado 源（或控制台见 `[LegadoBridge] Legado JSON imported`）
- [ ] 杀进程重启后 Legado 源仍在（读 `legado_bridge_sources.json`）
- [ ] 搜索关键词，结果列表有数据
- [ ] 点开书籍，目录加载
- [ ] 第一章正文显示
- [ ] 用 `legado-js-heavy.json` 重复（允许部分失败，记录 `java.*` 缺口）
- [ ] post-core：分组筛选 / 发现按钮 / 换源通知 / 替换净化（见 [`post-core.md`](post-core.md)）

## 已知限制（MVP）

1. **目录/正文方法级 Hook**：通知与引擎路径已通，详情绑定等锚点仍须在 2.56.1 诊断构建复核（参见 hook103 候选探针，不依赖其 dylib）
2. **insert_dylib**：Windows 本地 repack 不写入主二进制加载命令，需 macOS CI 最终产物
3. **符号剥离**：若 `BookSourceManager` 类名变更，搜索 Hook 降级为仅 JSON 导入路径
4. **引擎完整度**：继承 legado-ios 约 20% 整体完成度；复杂书源失败需回流修 JSBridge
5. **删源语义**：默认「保留书籍 + 标记书源不可用」（`SourceDeletePolicy.keepBooksMarkUnavailable`）；原版是否连带删书尚无真机取证，见 [`ios-mcp-acceptance.md`](ios-mcp-acceptance.md)

## 产物

| 文件 | 路径 |
|------|------|
| 原始 IPA | `ipa/香色闺阁2.56.1_未加密.ipa` |
| 预打包 IPA | `dist/StandarReader-legado-bridge.ipa`（Windows 生成） |
| CI IPA | GitHub Actions artifact `StandarReader-legado-bridge` |
| 注入库 | `LegadoBridge` dynamic product |

## 下一步

- 真机（iOS MCP）复核删源原版语义，必要时切换 `SourceDeletePolicy`
- 真机诊断包复核 `setDicBook:` / `loadCatalog:` / `loadCurCp` / `addBook:` 类型编码
- post-core 真机验收（换源通知、发现列表、净化效果）— 代码见 [`post-core.md`](post-core.md)
- 与 legado-E / legado-ios 引擎同步 CI
