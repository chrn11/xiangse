# 假设 AD：callBackResponse 在 check 之前的早退门禁

**基线**：`main`=`8e271af`（含 Reapply AC）；KEEP V+W+X+Y+Z；禁 bounce / dontFormat；AA 保持 revert  
**日期**：2026-07-18  
**真机 IPA**：`ccf9c5f`（CI `29642390919`）；证据 `fixtures/_accept_ad_probe_sync.json`  
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

### 覆盖关系（AC 漏钩根因）

| 类 | `callBackResponse` | `checkCallBackResponse` | `formatCallBackResponse` |
|---|---|---|---|
| `LPNetWork2` | `0x10008a1d4`（实现） | `0x10008a1c8`（仅 `response!=nil`） | `0x10008a8ec` |
| `BookQueryManager` : `LPNetWork2` | 继承 | **`0x10005e784` 覆盖**（章文校验） | **`0x10005f66c` 覆盖** |

AC 把 check/format 钩在 `LPNetWork2` → runtime `self=BookQueryManager` 走覆盖 IMP → **永远无 `check_enter`**，被误读成「check 前早退」。

---

## 2. 本刀（禁 bounce / dontFormat）

- 探针：`cb_precheck_gate_resp` / `cb_precheck_gate_check_seen` / `cb_precheck_gate_skip_check`
- **最小修**：`install_check` / `install_format` 改挂 `BookQueryManager`
- KEEP：once / peel / forensics 禁抢回 / swcf

---

## 3. 真机裁定（ccf9c5f）

```
cb_enter … self=BookQueryManager respLen=111
cb_precheck_gate_resp nil=0 len=111 self=BookQueryManager
check_enter … self=BookQueryManager qsrc=localSourceText respCls=__NSCFString
check_exit ok=1
format_enter → format_exit
cb_precheck_gate_check_seen
cb_exit
```

| 项 | 结果 |
|---|---|
| PRE-CHECK `resp_nil` | **未命中**（nil=0） |
| `check_enter` / `ok=1` | **有** |
| `format_enter` / `format_exit` | **有** |
| QF | **否**（qf_n=0） |
| 萧炎 / FIRST-CHAPTER | **否**（停在书架空列表） |

**裁定**：AC「check 前早退」不成立；唯一 PRE-CHECK 是 `response==nil`，本路径未触发。  
漏标因钩错类；改钩 BQM 后已通到 format。卡点下移到 **format 后 QF 派发**。

---

## 4. 下一刀（AE）

查 `formatCallBackResponse` 之后 → `callback_target` / `lpNetWorkDelegateQueryFinish` 派发（仍禁 bounce/dontFormat）。
