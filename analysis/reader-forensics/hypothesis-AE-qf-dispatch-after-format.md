# 假设 AE：format 之后未派发到 QF

**基线**：`main`=`0856315`（AD）；KEEP V+W+X+Y+Z；禁 bounce / dontFormat；AA 保持 revert  
**日期**：2026-07-18  
**真机 IPA**：`08530a1`（CI `29643000346`）；证据 `fixtures/_accept_ae_probe_sync.json`  
**承接**：AD 通 check/format，`qf_n=0`

---

## 1. 静态（`LPNetWork2#callBackResponse` @ `0x10008a1d4`，成功汇合 `0x10008a448`）

| 地址 | 含义 |
|---|---|
| `0x10008a4cc` / `0x10008a4f0` | 取 `callback_notify` / `callback_target` |
| `0x10008a52c` | **target==nil → 清 target，可能整段跳过 QF** |
| `0x10008a530`–`548` | `respondsToSelector: lpNetWorkDelegateQueryFinish:`；**NO → 清 target（w20=0）** |
| `0x10008a570`–`594` | `callback_dontFormatResponse`；nil 才 `formatCallBackResponse`（编码 `@40@0:8@16@24@32` **返回 id**） |
| `0x10008a5f0`–`624` | format；之后 `cbnz w20` |
| `0x10008a59c`–`5c0` | **`callback_inThread` 非 nil → 当前线程同步 QF**；nil → 落到异步 |
| `0x10008a628`–`6ac` | `notify\|target` 非空 → **`dispatch_async(main)`** 块内调 QF（`0x10008a868`） |

`TextRPageContainer` 自身无 QF IMP，父类 `ReadPageContainer` @ `0x1000d8278` 有实现 → `responds` 应为 YES。

---

## 2. 本刀（禁 bounce / dontFormat）

1. **修**：`LBAB_FormatCallBack` 由 `void` 改为返回 `id`（AD 钩签名错误会丢掉 format 返回值）。  
2. **探针**：`qf_dispatch_gates` / `qf_enter`（挂 `ReadPageContainer`）/ `qf_dispatch_main_pulse`。  
3. **修**：`chapterContent` 写入 `callback_inThread=YES`，走 original 同步 QF（因主队列不排空）。

---

## 3. 真机裁定

### 3.1 仅修 format 返回值（`e521bac`）

```
qf_dispatch_gates post_format … responds=1 notify=0 inThread=0 path=async_main respLen=107
format_exit outNil=0 outLen=107
after_cb path=async_main
cb_exit
```

| 项 | 结果 |
|---|---|
| responds / path | **1 / async_main**（非 target 门禁） |
| `qf_enter` / main_pulse / async_plus0.6s | **全 0** |
| 进程 | 约 +2s 再现 `install_*`（主队列未排空即重建） |

**跳过 QF 条件（运行时）**：original 已选 `dispatch_async(main)`，但 **main 在 invoke 后不执行该块**（非 responds/notify 失败）。

### 3.2 + inThread（`08530a1`）

```
qf_dispatch_inject_inThread
… path=sync_inThread inThread=1
format_exit outNil=0 outLen=107
qf_enter self=TextRPageContainer respLen=107
qf_exit → cb_exit
```

| 项 | 结果 |
|---|---|
| QF | **是**（qf_enter/exit） |
| 萧炎 / FIRST-CHAPTER | **否**（验收时前台在「信息」短信 UI，非阅读器） |

---

## 4. 下一刀（AF）

查 **invoke 后主队列不排空 / 约 +2s 进程重建** 根因；在不依赖 inThread 时让 `async_main` QF 自然落地；并在阅读器前台复验萧炎。
