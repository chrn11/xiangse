# 假设 AH：不死锁前提下让 QF 跑在主线程（疏通主队列 / 撤 inThread）

**基线**：`main`=`4127f2d`（AG docs）  
**日期**：2026-07-18  
**真机 IPA**：`69d99c5`（CI `29644642978`）→ **功能已 revert**（`2af4d07`）  
**证据**：`fixtures/_accept_ah_probe_sync.json`、`fixtures/_accept_ah_kill_syslog.json`、`fixtures/_accept_ah_probe.json`  
**承接**：AG 证实 KEEP inThread 时 bg QF→`UIWindowScene`→`SIGSEGV(11)`；marshal sync 死锁 / async 同 AF

---

## 1. 本刀动作（首选）

1. **静态**：AF/AE 时间线显示 `invoke_orig` 在 main 很快返回，CB 在 bg；主队列仍不跑 `async_main` QF/pulse。  
2. **根因假设**：forensics **永久 50ms** `LBFScheduleEarlyWrapRetry` 每次全量 `objc_getClassList` + `loadCurCp` **同步** `PerformDump`（枚举 `UIWindowScene.windows`）饿死主队列。  
3. **修**：
   - early-wrap 装成功后停止 50ms 重试；命名类命中则跳过全表扫描  
   - auto-dump 延后 1.5s（禁抢回逻辑不变）  
   - **撤** `inject_inThread`，走原版 `async_main`  
   - invoke 后立刻让出临界区，Z 探针改主队列下一轮；加 `ah_main_drain_slot`  
4. **禁**：bounce / dontFormat / `dispatch_sync(main)` QF / 手工 container / Bridge 外调 pageContainer / CB 窗口 `launch_app`

---

## 2. 真机裁定（`69d99c5`，禁 mid-chain launch）

| 项 | 结果 |
|---|---|
| `path` | **async_main**；`ah_no_inThread_inject`；无 inject |
| format / cb | **通**（enter/exit） |
| `qf_enter` / pulse / `ah_main_drain_slot` / async_plus | **全 0** |
| `ag_bg_hb` | i=0/i=1 有；无 done（进程中途灭） |
| pid | **61659→61736**（链路内变；`mid_chain_launch_app=false`） |
| 前台 | StandarReader；UI **书架空列表** |
| 萧炎 / FIRST-CHAPTER | **否** |

---

## 3. 杀因（syslog）

仍见：

1. `Unsupported enumeration of UIWindowScene windows on non-main thread.`  
2. `StandarReader[61659] Corpse allowed`  
3. `domain:signal(2) code:SIGSEGV(11)` / `launchd (2, 11, 11)`  

**要点**：本刀 **无 QF、无 inThread**，仍出现 UIWindowScene 非主线程 + SIGSEGV。  
说明该 syslog **不唯一绑定**「inThread bg QF」——CB/format 窗口或其它 bg UIKit 触达亦可触发；疏通 forensics 50ms **不足以**让 main 排空 `async_main` QF。

| 误判风险 | 澄清 |
|---|---|
| 「停 50ms forensics 即可 async_main」 | **否**：drain/pulse/QF 仍全 0 |
| 「无 QF 则无 UIWindowScene」 | **否**：本刀无 qf_enter 仍有该 syslog |

---

## 4. 调度结论

| 方案 | 结果 |
|---|---|
| 首选：清 forensics 主队列占用 + 撤 inThread + async_main | **失败**（已 revert） |
| AG：`dispatch_sync(main)` QF | 死锁（已 revert） |
| AG：`dispatch_async(main)` QF（KEEP inThread） | 同 AF，main 不跑（已 revert） |
| AE：inject_inThread 同步 QF | 通 QF 但 bg→SIGSEGV |

**inThread 是否仍要**：长期上屏 **不能**依赖 inThread（bg UIKit）。但本刀证明「仅撤 inThread + 停 forensics 重试」**不能**恢复 main 排空；下一刀须在 **进程存活且 main 可证明排空** 后再派 QF，或另寻非 sync 的主线程调度（且先证 drain）。

---

## 5. 代码状态

- 功能 commit `69d99c5` **已 revert**（`2af4d07`）  
- tip 回落至 AG 取证基线行为（KEEP inThread 注入仍在 tip 的 AE 代码中）  
- 保留本文件与 `fixtures/_accept_ah_*` 证据

---

## 6. 下一刀建议

1. 在 KEEP/对照实验下定位 **谁在 bg 枚举 UIWindowScene**（非仅 QF；forensics observer / CB 内部 / 其它钩）。  
2. 找 **invoke 返回后仍占住主线程** 的真阻塞（AF 1.2s drain 窗口已证 main 不跑，非仅死后假象）。  
3. 禁再试：`dispatch_sync(main)` QF；单独 `dispatch_async(main)` 须先有 `ah_main_drain_slot`/`pulse` 证据。  
4. 禁 bounce/dontFormat/pageContainer getter/setPageModel；KEEP V+W+X+Y+Z；forensics 禁抢回。
