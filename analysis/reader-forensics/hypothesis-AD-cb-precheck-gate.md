# 假设 AD：callBackResponse 在 check 之前的早退门禁

**基线**：`main`=`8e271af`（含 Reapply AC）；KEEP V+W+X+Y+Z；禁 bounce / dontFormat；AA 保持 revert  
**日期**：2026-07-18  
**承接**：AC 真机 `cb_enter→cb_exit`，`install_check` 有，**无** `check_enter`（误判为「check 前早退」）

---

## 1. 静态（StandarReader `LPNetWork2#callBackResponse` @ `0x10008a1d4`）

| 地址 | 指令 | 含义 |
|---|---|---|
| `0x10008a210`–`230` | retain response/config/userInfo → x23/x21/x22 | 无门禁 |
| **`0x10008a234`** | **`cbz x23 → 0x10008a274`** | **唯一 PRE-CHECK：`response == nil` 则跳过 check** |
| `0x10008a238`–`250` | `msgSend checkCallBackResponse:config:userInfo:` | 进入 check |
| `0x10008a254` | `cbz w0 → 0x10008a26c` | check 返回 NO（已进 check） |

**结论**：original CB **没有** config / userInfo / action / dontFormat / 主线程 的 PRE-CHECK 门禁；唯一早退是 `response==nil`。

### 覆盖关系（关键）

| 类 | `callBackResponse` | `checkCallBackResponse` | `formatCallBackResponse` |
|---|---|---|---|
| `LPNetWork2` | `0x10008a1d4`（实现） | `0x10008a1c8`（仅 `response!=nil`） | `0x10008a8ec` |
| `BookQueryManager` : `LPNetWork2` | 继承 | **`0x10005e784` 覆盖**（章文校验） | **`0x10005f66c` 覆盖** |

AC 把 check/format 钩在 `LPNetWork2` 上 → runtime `self=BookQueryManager` 时 msgSend 走覆盖 IMP → **探针永远看不到 `check_enter`**，被误读成「check 前早退」。

---

## 2. 本刀探针（禁 bounce / dontFormat）

- `cb_precheck_gate_resp`：打 nil/len/self/main/next
- `cb_precheck_gate_skip_check` / `cb_precheck_gate_check_seen`：next 返回后是否见过 check
- `install_check owner=BookQueryManager` / `install_format owner=BookQueryManager`
- `check_enter` 增补 `self` / `qsrc` / `respCls`

---

## 3. 真机裁定（待填）

| 项 | 结果 |
|---|---|
| IPA / CI | TBD |
| `cb_precheck_gate_*` | TBD |
| `check_enter` / `check_exit` | TBD |
| `format_enter` | TBD |
| QF / 萧炎 / FIRST-CHAPTER | TBD |

证据：`fixtures/_accept_ad_probe_sync.json`

---

## 4. 下一刀

若 `check_enter` + `ok=0`：拆 BQM#check 内 actionID/length/qsrc/localSource 门禁（仍禁 bounce/dontFormat）。  
若已 `format_enter` 无 QF：查 target 派发。
