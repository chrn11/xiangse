# 香色闺阁 2.56.1 + Legado 书源注入

保留香色闺阁 UI，通过 dylib 注入复用 [legado-ios](https://github.com/chrn11/legado-ios) 的 RuleEngine，解析 Legado JSON 书源。

## 仓库内容

| 路径 | 说明 |
|------|------|
| `LegadoBridge/` | 注入用动态库（Swift 引擎桥 + ObjC Hook） |
| `tools/ci/` | CI 门禁与合同单测 |
| `tools/repack/` | IPA 重打包 / 校验脚本 |
| `tools/sync_legado_vendor.ps1` / `.sh` | 从 legado-ios 同步引擎源码 |
| `fixtures/` | CI 与本地 mock 用的固定书源 / HTML |
| `ipa/` | CI 重打包用的基线 IPA |
| `.github/workflows/` | 自动编译与出包 |

本机取证、进度板、Agent 辅助脚本等不入库（见 `.gitignore`）。

## 快速开始

### 1. 同步引擎（可选）

本地已有 `LegadoBridge/Sources/LegadoBridge/Vendor` 时可跳过。

```powershell
powershell -File tools\sync_legado_vendor.ps1
```

```bash
bash tools/sync_legado_vendor.sh
```

### 2. 本地门禁（Windows 可跑）

```powershell
python tools/ci/validate_fixtures.py
python tools/ci/validate_hooks_gate.py
python -m unittest discover -s tools/ci -p "test_*.py"
```

macOS 另跑：`swift test --package-path LegadoBridge`

### 3. 编译 LegadoBridge（需 macOS / GitHub Actions）

```bash
cd LegadoBridge
swift package resolve
xcodebuild -scheme LegadoBridge -destination 'generic/platform=iOS' -configuration Release
```

或推送后由 `.github/workflows/bridge-ci.yml` 自动构建并上传 IPA artifact。

### 4. 重打包 IPA

**macOS（含 insert_dylib）：**

```bash
bash tools/repack/repack.sh \
  "ipa/香色闺阁2.56.1_未加密.ipa" \
  "<LegadoBridge dylib 路径>" \
  "dist/StandarReader-legado-bridge.ipa"
```

**Windows：** 预打包逻辑见 `tools/repack/repack.ps1`；完整注入出包以 CI 为准。

### 5. 安装

将 CI artifact 或本地 `dist/StandarReader-legado-bridge.ipa` 用 TrollStore 装到设备。

## 最小验证流程

1. 导入 `fixtures/legado-simple.json`（或局域网 mock：`python fixtures/serve_local_mock.py`）
2. Hook 识别 Legado 格式并注册到 `SourceRegistry`
3. 香色搜索 → `BookSourceManager startSearch` 被 Hook → Legado 引擎执行
4. 结果注入原生搜索 UI；打开书籍后目录 / 正文走同一桥接链

## 并行线

- **legado-ios**：完整 App / 引擎修复（独立仓库）
- **本仓库**：香色宿主上的书源桥接；引擎更新后运行 `sync_legado_vendor` 同步 Vendor
