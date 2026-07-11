# post-core：换源 / 发现分组 / 替换净化

> 日期：2026-07-11  
> 范围：核心闭环之后的三项扩展；**不依赖** hook103 无源码 dylib。  
> 协议锁：legado-E **3.26.030717**

## 1. 书籍换源与章节匹配

| 组件 | 路径 | 说明 |
|------|------|------|
| `ChapterMatcher` | `LegadoBridge/Sources/LegadoRuleCore/ChapterMatcher.swift` | 标题精确 → 归一化 → 包含 → 相似度 → 索引兜底 |
| Core API | `LegadoBridgeCore.matchChapterWithTitle:index:chapterTitles:chapterUrls:` | 同步匹配，返回 index/title/url/score/strategy |
| 换源入口 | `LegadoBridgeCore.switchBookSourceWithOldBookUrl:newBookUrl:newSourceUrl:chapterTitle:chapterIndex:` | 拉详情+目录、匹配章节、重绑定；通知 `LegadoBridgeSourceSwitched` |
| 夹具 | `CompatibilityFixtures.matchChapter` | 无网络能力夹具 |

旧 `bookUrl` 与新不同时：旧绑定标记 `sourceAvailable=false`，新绑定写入 `legado_bridge_books.json`。

## 2. 发现页 / 书源分组

| 组件 | 说明 |
|------|------|
| `RuleWebBook.exploreBook` | 使用 `exploreUrl` + `ruleExplore`（无则回退 search 列表规则） |
| `SourceRegistry.allGroups` / `allSourcesInfoDicts(groupFilter:)` / `exploreCapableSources` | 分组筛选与发现能力标记 |
| 管理页 | `LBLegadoSourceManagerVC` 右上角「分组」「发现」；列表展示 `· 发现` |
| Hook/API | `handleExploreRequestWithSourceUrl:exploreUrl:page:`；结果走搜索通知并带 `fromExplore=true` |

筛选约定：`__all__` 全部；`__ungrouped__` 无分组；其它等于 `bookSourceGroup`。

## 3. 替换净化

| 组件 | 说明 |
|------|------|
| `ReplaceRuleItem` / `ReplaceEngine` / `ReplaceAnalyzer` | `LegadoRuleCore` 无 CoreData 实现 |
| `ReplaceRuleStore` | 持久化 `Documents/legado_bridge_replace_rules.json`；启动装载预设 |
| 正文路径 | `handleContentRequest` 在引擎正文后调用 `purify`（书源内 `replaceRegex` 仍由 RuleWebBook 处理） |
| Package | Vendor 下旧 CoreData 版 `ReplaceEngine*` **继续 exclude**；勿与 RuleCore 版混淆 |

导入：`importReplaceRulesJSON:error:`；单测净化：`purifyContent:bookUrl:chapterUrl:`。

## 4. 测试与门禁

```
# Windows / 本地结构门禁
python .test_tools/validate_baseline_and_tests.py

# macOS / CI
swift test --package-path LegadoBridge
```

- `PostCoreFixtureTests`：章节匹配 + ReplaceEngine
- `PostCoreBridgeTests`：分组/发现标记、Core 匹配、ReplaceRuleStore、换源重绑定语义

## 5. 手工 / 真机测

1. 导入带 `bookSourceGroup` 与 `exploreUrl` 的源 → 管理页见分组与「· 发现」
2. 点「分组」筛选 → 列表变化
3. 点「发现」→ 控制台/`legado_search_last.txt` 见 `explore ok`；搜索通知带 `fromExplore`
4. 两源搜同书 → 调 `switchBookSource...`（或 Frida/ObjC）→ 收 `LegadoBridgeSourceSwitched`，章节 index 合理
5. 导入替换 JSON → 读正文广告壳被去掉

## 6. CI 就绪度

代码与门禁脚本已具备**推送编译意义**（Swift 源、Hooks、测试、Package exclude 说明齐全）。  
仍须主会话决定：git commit / push 后由 `bridge-ci` 产出含 insert_dylib 的 IPA；真机验收未完成前属「可编译可测，未闭环验收」。
