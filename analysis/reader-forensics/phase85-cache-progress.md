# 8.5 缓存与页位 — 真机进度

**日期**：2026-07-23  
**verdict**：FAIL / **BLOCKED（待含补丁的新 Debug IPA）**  
**当前真机包**：`dist-ci/phase8/dist/StandarReader-legado-bridge-debug.ipa` → manifest `git_commit=f6904f25c9ba…`（run `29994659934`），**不含**本轮离线补丁  
**工作区**：Bridge 离线回退已改源码且未 commit（用户未授权 commit）

## 本轮核对（源码）

| 文件 | 状态 | 要点 |
|---|---|---|
| `LegadoBridge/.../LegadoBridgeCExports.m` | 工作区已改 (+257) | 目录盘缓存、`Library/appdata/xsfolder` 预注、错误通知不冲缓存、`notOnStack` 冷开清 openOnce |
| `LegadoBridge/.../LegadoBridgeCore.swift` | 工作区已改 | 目录网络失败读 `Documents/legado_catalog_cache` |
| `.test_tools/phase85_cache_accept.py` | 就绪（`.gitignore`） | dump/xsfolder/上滑/离线路径 |

未改计划文件 `.cursor/plans/原生阅读闭环重建_b9167d21.plan.md`。

## 出包阻塞

- Windows 本地无 Xcode/`insert_dylib` 全链路；Debug IPA 须走 `LegadoBridge CI` → job `build-bridge-debug`。
- CI `actions/checkout` 只含已推送 commit；**未 commit 则产物仍为 f6904f2，无法验证补丁**。
- 本轮遵守「不要 git commit」，故 **未推送、未触发新 CI、未重装、未重跑真机门禁**（禁假通过）。

## 已确认（同包 f6904f2，上一轮）

| 项 | 结果 |
|---|---|
| SHA | ✅ `f6904f25c9ba…` |
| 联网正文 萧炎 | ✅ |
| 上滑到当前页 药老 | ✅ |
| xsfolder 章缓存 | ✅ `Library/appdata/xsfolder/book/斗破苍穹_天蚕土豆/` |
| 停 mock | ✅ |
| 离线开已缓存章 | ❌ `awaitingCatalog` / 书架「空列表」 |
| 杀进程恢复药老页 | ❌ preview 回章首 |

## 产物（旧）

- `fixtures/_devkit/phase85_cache/report.json`（verdict=FAIL）
- IPA：`dist-ci/phase8/dist/StandarReader-legado-bridge-debug.ipa`

## 解阻后最小命令（需用户授权 commit 后）

```powershell
cd D:\soft\xiangse
git add LegadoBridge/Sources/LegadoBridgeHooks/LegadoBridgeCExports.m `
  LegadoBridge/Sources/LegadoBridge/Bridge/LegadoBridgeCore.swift
git commit -m "fix(legado)：8.5 离线目录盘缓存与 xsfolder 正文回退"
git push
gh run watch
$run = (gh run list --workflow bridge-ci.yml -L 1 --json databaseId -q ".[0].databaseId")
Remove-Item -Recurse -Force dist-ci\phase8 -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path dist-ci\phase8 | Out-Null
gh run download $run -n LegadoBridge-IPA-Debug -D dist-ci\phase8
$env:XIANGSE_MCP = "http://192.168.1.18:8090"
$env:XIANGSE_MOCK = "http://192.168.1.4:8765"
$env:XIANGSE_IPA = "D:\soft\xiangse\dist-ci\phase8\dist\StandarReader-legado-bridge-debug.ipa"
# XIANGSE_EXPECT_SHA 设为新 commit 前缀
python .test_tools/phase85_cache_accept.py
```

## 是否可进 8.6

**否** — 8.5 真机未 PASS（仍缺含补丁 IPA 的验收）。
