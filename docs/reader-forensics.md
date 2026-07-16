# Reader Forensics 双包身份

手动 workflow `reader-forensics.yml`（仅 `workflow_dispatch`）从同一基线 IPA 产出两个可验证身份的 debug IPA：

| 产物 | variant | 注入 |
| --- | --- | --- |
| `StandarReader-baseline-debug.ipa` | `baseline-debug` | 仅 `LegadoBridgeDebug` |
| `StandarReader-legado-debug.ipa` | `legado-debug` | `LegadoBridge` + `LegadoBridgeDebug` |

## 身份 manifest

两包均在 App Bundle 内嵌 `reader-build-manifest.json`，字段：

- `schema_version`
- `variant`
- `git_commit`
- `github_run_id`
- `base_ipa_sha256`
- `app_binary_sha256`
- `legado_bridge_sha256`（baseline 为 `null`）
- `legado_debug_sha256`
- `built_at_utc`

## 触发 CI

```bash
gh workflow run reader-forensics.yml
gh run watch
gh run download -n Reader-Forensics-IPAs -D dist/forensics
```

## devkit 校验

```powershell
python tools/xiangse_devkit.py install --forensics --run-id <ID> --expected-variant baseline-debug
python tools/xiangse_devkit.py status --expected-run <ID> --expected-variant baseline-debug
python tools/xiangse_devkit.py debug-dump --expected-variant baseline-debug --save
```

任一 `--expected-sha` / `--expected-run` / `--expected-variant` 与已安装 App 内 manifest 不符时，命令立即以非 0 退出，不继续真机操作。

## 本地测试

```bash
python -m unittest tools.ci.test_reader_manifest -v
```
