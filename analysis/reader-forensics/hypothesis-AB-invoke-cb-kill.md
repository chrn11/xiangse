# 假设 AB：invoke 返回后、CB→QF 前杀进程取证

**基线**：功能 Z=`8fe2661`/`39e5496`；AA 两刀均已 revert（`0fa15cd` / `5966fcc`）  
**日期**：2026-07-18  
**探针文件**：`Documents/legado_ab_probe.txt`（POSIX `write`+`fsync`）+ `legado_loadcurcp_state.txt`（`synchronizeFile`）

---

## 1. CrashReporter 取证（MCP `get_crash_logs`）

| 项 | 结果 |
|---|---|
| 今日（7/18）StandarReader `.ips` | **无** |
| 最近 StandarReader | `StandarReader-2026-07-16-114653.ips` 等（均为 7/16） |
| 旧报告类型 | `bug_type=509`（stackshot） |
| 旧 termination | **scene-update watchdog**：Foreground 耗尽 10s wall-clock |
| Jetsam 目录（run_command） | shell 沙箱看不到 CrashReporter 路径；以 MCP `get_crash_logs` 为准 |
| syslog | MCP `get_syslog` 本轮超时 |

**推论**：Z/AA 真机「约 +1s `register_orig inv=0`」**未留下新的 EXC_BAD_ACCESS `.ips`**。  
更像 **SIGKILL / 看门狗类强制终止 / 无报告退出**，不能先假定堆损坏；AA bounce 失败也不能反证为「主线程 UIKit 必崩」。

证据落盘：

- `analysis/reader-forensics/hypothesis-AB-crash-pull.json`
- `analysis/reader-forensics/hypothesis-AB-old-crash-head.txt`

---

## 2. 静态窗口（本地块 `@0x10006171c`）

```
dispatch_async(global) →
  getBookDirByBookKey →
  stringWithContentsOfFile:encoding:error: →
  dictionaryWithObjects: @{ actionID } →
  [BookQueryManager callBackResponse:config:userInfo:]
```

`LPNetWork2#callBackResponse` 内：`check` →（可跳过）`formatCallBackResponse` → `callback_target` 派 `lpNetWorkDelegateQueryFinish`。

---

## 3. AB 探针点（只读，禁 bounce / 禁改 userInfo）

| 标签 | 位置 |
|---|---|
| `pre_invoke_orig` | `sOrigLoadCurCp` 前 |
| `invoke_orig_returned` | invoke 返回后立刻 |
| `post_invoke_*` / `await_native_chain` | Z 探针与 O 等待 |
| `swcf_*` | **已撤**：全局钩 `stringWithContentsOfFile` 会打断 import/书源读取（903846e 真机无 invoke） |
| `cb_enter` / `cb_exit` | `callBackResponse` 前后（透传 next，不 inject） |
| `check_*` / `format_*` | 若 selector 存在 |
| `fatal_signal SIG=n` | SIGSEGV/BUS/ABRT/TRAP/ILL |
| `async_plus0.6s_*` | 主队列 0.6s 延迟探针 |

---

## 4. 根因（取证阶段一句话）

**今日杀点无新 `.ips`；历史同类进程死亡为 scene-update watchdog（bug_type 509），不是已证实的 EXC_BAD_ACCESS。**  
精确最后存活指令以真机 `legado_ab_probe.txt` 最后一行裁定（见验收脚本）。

---

## 5. 下一刀（勿瞎叠 AA bounce）

1. 装 AB IPA → nativeRead → 读 `legado_ab_probe.txt` 最后一条。  
2. 若停在 `swcf_exit` 前 → 异步块未跑完 / 读文件前崩。  
3. 若 `swcf_exit` 有、`cb_enter` 无 → notify 前崩（config/userInfo 组装）。  
4. 若 `cb_enter` 有、`format_enter` 有、无 `format_exit` → **后台 format 崩** → 可试「仅 inject dontFormat、禁 bounce」（与 AA2 `32211af` 同思路但须带 fsync 证据）。  
5. 若 `cb_exit` 有、无 QF → target/主队列派发问题（另刀，禁 bounce 互套）。  
6. 若出现 `fatal_signal` → 按 SIG 对照；若始终无 signal/ips 且 +1s 重启 → 优先查 watchdog/Jetsam，而非再包主线程 bounce。
