# 假设 AG：invoke/CB 窗口静默杀进程取证（KEEP inThread）

**基线**：`main`=`7ef39bd`（AE 功能 + AF revert）→ 取证 tip=`f7b54eb`；marshal 两刀已 revert（`598ce49`）  
**日期**：2026-07-18  
**真机 IPA**：`f7b54eb`（CI `29643902644`）  
**证据**：`fixtures/_accept_ag_probe_sync.json`、`fixtures/_accept_ag_kill_syslog.json`  
**承接**：AF 撤 inThread 后 async_main 全不跑且 +1s pid 变；本刀 KEEP `inject_inThread`

---

## 1. 本刀动作

1. **KEEP** `callback_inThread` 注入（禁再撤）。  
2. **探针**：`pid` / `up` / `mem(phys_footprint)` / `ag_bg_hb` / `ag_atexit` / `ag_post_qf`（POSIX fsync）。  
3. **验收**：nativeRead 链路内 **禁止 `launch_app`**（排除 AF 伪杀）；`start_capture` 收 syslog。  
4. **修尝试（已失败并 revert）**：QF 钩 `dispatch_sync(main)` → 死锁；`dispatch_async(main)` → 同 AF 主队列不跑 QF。

---

## 2. 真机裁定（`f7b54eb`，禁 mid-chain launch）

| 项 | 结果 |
|---|---|
| `inject_inThread` / `path` | **KEEP**；`sync_inThread` |
| QF | **`qf_enter`→`ag_post_qf`→`qf_exit`→`cb_exit`**（bg，`main=0`） |
| QF 耗时 | ~171ms（`up` 509→680） |
| `ag_bg_hb` | i=0/i=1 有；**无 i=2 / 无 done**（进程中途灭） |
| `ag_atexit` / `fatal_signal` | **无**（handler 未落盘） |
| pid | **61304→61385**（链路内变；`mid_chain_launch_app=false`） |
| mem | 链中仅 **40–43MB**（非本进程 Jetsam 高压） |
| 今日 StandarReader `.ips` | **无**；`new_crash_count=0` |
| 前台 | StandarReader；UI **书架空列表** |
| 萧炎 / FIRST-CHAPTER | **否** |
| `main_pulse` / `async_plus` | **否**（死后未排空） |

---

## 3. 杀因结论（syslog + SpringBoard，confirmed）

**不是** Jetsam / scene-update 509 / 验收 `launch_app` 伪杀 / 自愿 `exit`。

1. QF 前：`Unsupported enumeration of UIWindowScene windows on non-main thread.`（×3）  
2. 内核：`StandarReader[61304] Corpse allowed`；`ReportCrash Parsing corpse`  
3. SpringBoard / runningboardd：  
   `domain:signal(2) code:SIGSEGV(11)` / `launchd (2, 11, 11)`  

**根因**：`inject_inThread` 使 original 在 **后台线程同步调 QF** → QF→division/UIKit 碰 `UIWindowScene` → **SIGSEGV(11)**；无稳定 `.ips`（corpse 未进 CrashReporter 列表），故先前误判为「静默 SIGKILL」。

| 误判 | 澄清 |
|---|---|
| AF「SIGKILL/看门狗」 | 本刀在 KEEP inThread 下证实为 **SIGSEGV**；AF 无 QF 时的死法可能另因，但「无 .ips≠非崩溃」 |
| AF +1s pid 变=验收 relaunch | AG 禁 mid-chain `launch_app` 后仍 pid 变 |
| 主队列饿死是根因 | bg 心跳停跳=**进程已死**；主队列不排空是伴生 |

---

## 4. 修尝试与 revert

| 刀 | 现象 | 裁定 |
|---|---|---|
| `dispatch_sync(main)` QF | 仅 `ag_qf_marshal_to_main`，无 `qf_enter` | **死锁**（CB 等 main，main 未跑块） |
| `dispatch_async(main)` QF | `cb_exit` 有，无 `qf_enter`/`pulse`，pid 仍变 | **同 AF**：主队列在死后不跑 QF |
| 代码 | **已 revert** marshal；**保留** pid/mem/bg 探针与禁 launch 验收 |

---

## 5. inThread KEEP

| 问 | 答 |
|---|---|
| 可否撤 inThread？ | **本刀不撤**（约定）；撤后回到 AF async_main 饿死窗口 |
| inThread 能否上屏？ | **不能直接上屏**：bg QF 会 SIGSEGV；async marshal 又跑不到 main |
| 下一刀方向 | 在 KEEP inThread 入口的前提下，找 **不死锁且能让 main 执行 UIKit QF** 的调度（或恢复主队列存活后再走 async_main） |

---

## 6. 下一刀建议

1. 查 **为何 invoke 返回后主队列不处理 async 块**（AF/AG-async 同构），在进程存活前提下让 QF 上主线程。  
2. 或：CB 返回后用 **非 sync** 机制唤醒 main（勿再 `dispatch_sync`）。  
3. 禁 bounce/dontFormat/pageContainer getter/setPageModel；KEEP V+W+X+Y+Z。
