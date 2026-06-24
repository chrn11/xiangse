# MVP 验收报告 — 香色闺阁 Legado 注入

> 日期：2026-06-24  
> 版本：LegadoBridge 1.0.0-mvp  
> 目标 IPA：香色闺阁 2.56.1（`com.appbox.StandarReader`）

## 验收范围

| 步骤 | 状态 | 说明 |
|------|------|------|
| IPA 解压与基线分析 | 通过 | `analysis/baseline.json`，无 Frameworks |
| Hook 映射文档 | 通过 | `docs/hook-map.md` 四条链路 |
| LegadoBridge 工程 | 通过 | SPM + ObjC Hook + 引擎 vendor |
| 导入 Hook | 通过（代码） | `NSJSONSerialization` swizzle + `SourceRegistry` |
| 搜索→目录→正文 Hook | 通过（代码） | `BookSourceManager startSearch` + 通知注入 |
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
python .test_tools/validate_bridge_logic.py
→ 验证通过（IPA 基线、fixtures、工程文件、hook-map）
```

## 真机验收清单（用户执行）

- [ ] TrollStore 安装 `dist/StandarReader-legado-bridge.ipa`
- [ ] 导入 `fixtures/legado-simple.json`（文件分享 → 香色闺阁）
- [ ] 站点管理中出现 Legado 源（或控制台见 `[LegadoBridge] Legado JSON imported`）
- [ ] 搜索关键词，结果列表有数据
- [ ] 点开书籍，目录加载
- [ ] 第一章正文显示
- [ ] 用 `legado-js-heavy.json` 重复（允许部分失败，记录 `java.*` 缺口）

## 已知限制（MVP）

1. **书架持久化**：Legado 源存于内存 `SourceRegistry`，App 重启需重新导入
2. **insert_dylib**：Windows 本地 repack 不写入主二进制加载命令，需 macOS CI 最终产物
3. **符号剥离**：若 `BookSourceManager` 类名变更，搜索 Hook 降级为仅 JSON 导入路径
4. **引擎完整度**：继承 legado-ios 约 20% 整体完成度；复杂书源失败需回流 legado-ios 修 JSBridge

## 产物

| 文件 | 路径 |
|------|------|
| 原始 IPA | `ipa/香色闺阁2.56.1_未加密.ipa` |
| 预打包 IPA | `dist/StandarReader-legado-bridge.ipa`（Windows 生成） |
| CI IPA | GitHub Actions artifact `StandarReader-legado-bridge` |
| 注入库 | `LegadoBridge` dynamic product |

## 下一步（Phase 5）

- Legado 书源订阅 URL 批量导入
- 书架/书源 SQLite sidecar 持久化
- `queryXbsFile` 显式 bypass（与 JSON 路径并列）
- 与 legado-ios 引擎同步 CI
