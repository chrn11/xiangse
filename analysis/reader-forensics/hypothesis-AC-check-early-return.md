# 假设 AC：callBackResponse 内 check 早退取证

**基线**：KEEP V+W+X+Y+Z；AA 已 revert；AB 真机末行 `cb_enter … dontFormat=0` 无 `format_enter`/`cb_exit`  
**决策**：禁 bounce、禁 dontFormat；本刀 check_* / early-return + 防 `install_cb` 污染 next  
**日期**：2026-07-18  
**真机 IPA**：`1fcaed5`（CI `29641881394`）；证据 `fixtures/_accept_ac_probe_sync.json`

---

## 1. 对 6b5ef8e：**REVERT（逻辑恢复 swcf）**

| 证据 | 结论 |
|---|---|
| `_accept_ab_6b5ef8e.json` | 仅 `install_done`，**无 invoke**，未清 openOnce 假阳性 |
| `_accept_ab_probe_sync.json`（903846e） | 有 `cb_enter … inv=1` |
| AC 真机 | `swcf_enter/exit leaf=0 len=111` + `cb_enter` |
| 故 | **不 KEEP 6b5ef8e**；AC 恢复 `install_swcf` |

---

## 2. 真机裁定（1fcaed5）

探针序列（runtime）：

```
pre_invoke_orig → invoke_orig_returned
swcf_enter leaf=0 → swcf_exit len=111
cb_enter respLen=111 action=chapterContent target=TextRPageContainer dontFormat=0
cb_exit
→ invoke_state_idle
```

| 项 | 结果 |
|---|---|
| `install_check` / `install_format` | **有**（重启后重装日志可见） |
| `check_enter` / `check_exit` / `check_early_return` | **无** |
| `format_enter` | **无** |
| `cb_exit` | **有**（风暴已消） |
| QF / 萧炎 / FIRST-CHAPTER | **否**（qf_n=0） |

**结论**：防 next 污染成立（`cb_enter→cb_exit`，无重入风暴）。  
original `callBackResponse` **在 check 之前就返回**（钩已装但未调用），不是 check 失败早退，也不是 format 内死亡。

---

## 3. 防 next 污染（已修）

1. 钩只装一次（`sABHooksInstalled`）  
2. next 冻结；若 cur 为 forensics 桩则 peel orig  
3. forensics `LBFInstallHookOnMethod` 已装 key **不再抢回**（根因：50ms retry 曾造成 forensics↔AB 环）

---

## 4. 下一刀（AD）

反汇编 / 细探针：original `LPNetWork2#callBackResponse` 在 `checkCallBackResponse` **之前**的早退条件（config/userInfo/action 门禁），使 check 被跳过且无 QF。
