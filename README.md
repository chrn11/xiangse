# 香色闺阁 2.56.1 + Legado 书源注入

在保留香色闺阁 UI 的前提下，通过 dylib 注入复用 [legado-ios](D:\soft\legado-ios) 的 RuleEngine，实现 Legado JSON 书源解析。

## 目录

| 路径 | 说明 |
|------|------|
| `ipa/` | 原始 IPA |
| `analysis/` | 解压与分析产物 |
| `LegadoBridge/` | 注入用动态库（Swift + ObjC Hook） |
| `tools/repack/` | 重打包脚本 |
| `tools/sync_legado_vendor.ps1` | 从 legado-ios 同步引擎源码 |
| `docs/` | 基线、Hook 映射、MVP 报告 |
| `fixtures/` | 测试用书源 |

## 快速开始

### 1. 同步引擎

```powershell
powershell -File tools\sync_legado_vendor.ps1
```

### 2. 本地逻辑验证（Windows）

```powershell
python .test_tools\validate_bridge_logic.py
```

### 3. 编译 LegadoBridge（需 macOS / GitHub Actions）

```bash
cd LegadoBridge
swift package resolve
# 在 macOS 上:
xcodebuild -scheme LegadoBridge -destination 'generic/platform=iOS' -configuration Release
```

或推送后由 `.github/workflows/bridge-ci.yml` 自动构建。

### 4. 重打包 IPA

**macOS（含 insert_dylib）：**

```bash
bash tools/repack/repack.sh
```

**Windows（预打包，insert_dylib 在 CI 完成）：**

```powershell
powershell -File tools\repack\repack.ps1
```

### 5. TrollStore 安装

将 `dist/StandarReader-legado-bridge.ipa` 安装到设备。

## MVP 流程

1. 用「用其他 App 打开」导入 `fixtures/legado-simple.json`
2. Hook 识别 Legado 格式并注册到 `SourceRegistry`
3. 在香色闺阁搜索界面搜索 → `BookSourceManager startSearch` 被 Hook → Legado 引擎执行
4. 结果通过 `dNotifyName_SearchBookSourceResponse` 注入 UI
5. 打开书籍 → 目录/正文同理

## 并行线

- **legado-ios**：完整 App 移植（继续独立推进）
- **本仓库**：仅书源桥接；引擎修复在 legado-ios 完成后运行 `sync_legado_vendor.ps1` 同步

## 文档

- [ipa-baseline.md](docs/ipa-baseline.md)
- [hook-map.md](docs/hook-map.md)
- [mvp-report.md](docs/mvp-report.md)
