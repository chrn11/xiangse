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

## 4. 根因（真机 fsync 裁定）

**`cb_enter`（bg、`respLen=111`、`target=TextRPageContainer`、`dontFormat=0`）风暴式重入，无 `cb_exit` / 无 `format_enter` / 无 `fatal_signal` / 无新 `.ips`；约 +12s `register_orig inv=0`。**  
不是目录问题（`fileExists=1`）；不是已证实的 EXC_BAD_ACCESS；更像 **AB↔forensics 钩互套重入 + 后台 CB 未跳过 format**。历史 ips 多为 scene-update watchdog（bug_type 509）。

证据：`fixtures/_diag_ab_force_nativeread.json`（清 openOnce + 点掉「导入书源」后复现）。

---

## 5. 最小修复（禁 bounce）

1. **钩只装一次**（禁 invoke 前反复 `method_setImplementation`）  
2. **重入深度护栏**（防 AB↔forensics 死循环）  
3. **章文注入 `callback_dontFormatResponse=YES`**（同线程放行，禁 bounce）

---

## 6. 验收注意

- 须点掉 Alert「导入 1 个书源」→「好」  
- 须清 `legado_catalog_openreader.txt` / 杀进程，否则 `nativeRead skip openOnce sameBook`  
- 成功：`inject_dontFormat` + `cb_exit` + QF；失败只 revert AB
