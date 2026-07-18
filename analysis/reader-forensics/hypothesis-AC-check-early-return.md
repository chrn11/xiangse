# 假设 AC：callBackResponse 内 check 早退取证

**基线**：KEEP V+W+X+Y+Z；AA 已 revert；AB 真机末行 `cb_enter … dontFormat=0` 无 `format_enter`/`cb_exit`  
**决策**：禁 bounce、禁 dontFormat；本刀只打 check_* / early-return + 防 `install_cb` 污染 next  
**日期**：2026-07-18

---

## 1. 对 6b5ef8e 的裁定：**REVERT（逻辑恢复 swcf）**

| 证据 | 结论 |
|---|---|
| `_accept_ab_6b5ef8e.json` | 仅 `install_done`，**无 invoke**，未清 openOnce 假阳性 |
| `_accept_ab_probe_sync.json`（903846e IPA） | 有 `cb_enter … inv=1`，证明 swcf 并非「无 invoke」根因 |
| 故 | **不 KEEP 6b5ef8e**；AC 恢复 `install_swcf` |

---

## 2. 探针（`Documents/legado_ab_probe.txt`，POSIX write+fsync）

| 标签 | 含义 |
|---|---|
| `check_enter …` | 进入 `checkCallBackResponse`（format 前） |
| `check_exit ok=0/1` | check 返回 |
| `check_early_return reason=…` | `null_next` / `check_failed` |
| `format_enter` / `format_exit` | 若 check 通过后进入 format |
| `cb_enter` / `cb_exit` / `cb_early_return` | 透传链外层（**不** inject dontFormat） |
| `install_cb_peeled` / `install_cb_pollute_blocked` / `install_skip already` | next 防污染 |
| `swcf_*` | 恢复的文件读存活点 |

---

## 3. 防 next 污染（成立 → 已修）

1. **钩只装一次**（`sABHooksInstalled`）；invoke 再调只打 `install_skip already`
2. **next 冻结**：`sABNext*` 只写一次
3. **剥 forensics**：若 cur 是 observer 桩，`LBForensicsResolveObserverOrigIMP` 取真正 orig
4. **forensics 不再抢回**：`LBFInstallHookOnMethod` 已安装 key 时不再 `method_setImplementation`

---

## 4. 真机裁定分支

- `check_early_return reason=check_failed` → 下一 commit 修数据/config 使 check 通过  
- `check_exit ok=1` + `format_enter` 无 `format_exit` → 下一刀打 format 内（本回合只交探针）  
- 仅 `cb_enter` 仍无 `check_enter` → 仍卡在 next 链（看 `install_cb_peeled` / `cb_reentry_depth_abort`）
