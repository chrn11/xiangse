# 假设 AI：bg UIWindowScene caller + invoke 后主线程阻塞点

**基线**：`main` tip 取证前=`98c53ed`（AH docs）  
**日期**：2026-07-18  
**真机 IPA**：`d0030bd`（CI `29645025834`）  
**证据**：`fixtures/_accept_ai_probe_sync.json`、`fixtures/_accept_ai_kill_syslog.json`、`fixtures/_accept_ai_probe_stack.txt`  
**承接**：AH 证无 inThread/无 QF 仍有 UIWindowScene syslog + SIGSEGV；本刀 KEEP `inject_inThread`，专打 caller 与 main 阻塞

---

## 1. 本刀动作

1. 钩 `-[UIWindowScene windows]`：非主线程写 `ai_bg_uikit` + `legado_ai_probe.txt` 栈摘要。  
2. `LBLegadoKeyWindow` / forensics `InstallObservers`/`GatherAutoDumpUIHints` 打 `ai_bg_tag=`。  
3. invoke 返回后：`ai_main_drain_slot` + CFRunLoop observer + `ai_main_watch` + 尝试挂起主线程采 PC。  
4. **KEEP** `inject_inThread`；禁 bounce/dontFormat/mid-chain `launch_app`/`dispatch_sync(main)` QF。

---

## 2. 真机裁定（`d0030bd`，禁 mid-chain launch）

| 项 | 结果 |
|---|---|
| `inject_inThread` / path | **KEEP**；`sync_inThread` |
| QF | `qf_enter`→`ag_post_qf`→`qf_exit`→`cb_exit`（**bg** `main=0`） |
| `ai_main_drain_slot` / `qf_dispatch_main_pulse` / `async_plus` | **全无** |
| `ai_main_watch` | i=0..3 均为 `drain=0 wait=0 src=0 bgWin=4` |
| `ai_main_block_pc` | **未落盘**（采样窗内进程已濒死/挂起未写出） |
| pid | **61859→61947**（`mid_chain_launch_app=false`） |
| 前台 | StandarReader；UI **书架空列表** |
| 萧炎 / FIRST-CHAPTER | **否** |

---

## 3. 取证 A：bg UIWindowScene caller（可归因）

**Caller**：`LBLegadoKeyWindow`（C 函数；内部枚举 `UIWindowScene.windows`）

| 证据 | 内容 |
|---|---|
| 标签 | `ai_bg_tag=LBLegadoKeyWindow main=0` ×2（与 windows hit 同期） |
| 钩子 | `ai_bg_uikit sel=windows hit=1..4` 均在 **invoke 前**（`inv=0`，state `idle`→`contentReady`） |
| 配比 | 2 次 KeyWindow × 多 scene ≈ 4 次 `windows` 命中 |
| syslog | 同秒 `Unsupported enumeration of UIWindowScene windows on non-main thread.` ×3 |
| 未命中 | `ForensicsInstallObservers_sync_main` / `LBFGatherAutoDumpUIHints` **无** |

上游可能入口（静态）：`LBLegadoShowResult` / `LBLegadoPresentManagerVC` / `LBLegadoShowImportAlert` / `LBAllAppWindows`→再调 KeyWindow（`LegadoBridgeCExports.m`）。  
压缩栈符号质量差（见 `_accept_ai_probe_stack.txt` 数字碎片），**以 `ai_bg_tag` 为准**。

**对 AH 的解释**：无 QF 仍可出现该 syslog —— **Bridge 自有 `LBLegadoKeyWindow` 在 bg 触达**，不唯一绑定 inThread QF。

---

## 4. 取证 B：main「阻塞」形态（可证伪同步饿死）

时间线（同一 pid=61859，`up` ms）：

1. `invoke_orig_returned`（main）→ 装 `ai_main_rl_observer_ok`  
2. 数 ms 内：`post_invoke_*` / `invoke_state_idle`（main）与 CB/format/QF（bg）交错  
3. `qf_enter`（bg）后 ~100ms：`ai_main_watch i=0 drain=0 wait=0 src=0`  
4. QF 约 314ms 后 `qf_exit`/`cb_exit`；watch i=3 仍 `drain=0`  
5. 随后 Corpse + `SIGSEGV(11)`；pid→61947  

**结论标签**：`ai_main_starved_after_invoke_idle`

- 不是「invoke 函数体内没返回」——已见 `invoke_state_idle`。  
- 是 **idle 之后主队列仍不跑** `ai_main_drain_slot`/`pulse`；RunLoop observer **无** `BeforeWaiting`/`BeforeSources` 计数 → 主线程在死前未回到可排空的 runloop 边界（或已处于不可恢复态）。  
- 伴生：bg QF（KEEP inThread）后 SIGSEGV；与 AG 一致。  
- PC 符号本刀未拿到；下一刀需在 QF 前加强采样或缩短 QF 窗。

---

## 5. 杀因（syslog，confirmed）

1. `UIWindowScene windows on non-main thread`（KeyWindow 窗，invoke 前已出现）  
2. `StandarReader[61859] Corpse allowed`  
3. `domain:signal(2) code:SIGSEGV(11)` / `launchd (2, 11, 11)`  

---

## 6. 是否最小修？

| 候选 | 裁定 |
|---|---|
| 仅禁 bg `LBLegadoKeyWindow` 碰 scene | 可消 invoke 前 syslog；**不能**单独证 `drain`+主线程 QF+萧炎（KEEP inThread 下 QF 仍 bg） |
| 再撤 inThread / sync marshal | AH/AG 已否；本刀不重试 |
| 本刀功能修 | **不做**（无通到 pulse/drain/主线程 QF/萧炎） |

代码保留 AI 探针；**KEEP inject_inThread**。

---

## 7. 下一刀建议

1. **归因上游**：给 `LBLegadoShowResult` / `ShowImportAlert` / `LBAllAppWindows` / `LBFindBookSearchVCs` 打调用点标签，确认 nativeRead 窗是谁在 bg 调 KeyWindow。  
2. **消 bg scene**：`LBLegadoKeyWindow` 非主线程走 legacy `keyWindow`/`windows`，禁枚举 `UIWindowScene`；`LBAllAppWindows` 同步守卫。  
3. **主线程**：在 `invoke_state_idle` 当帧用 `CFRunLoopPerformBlock`/`wakeup` 强行穿一次 drain；并在 QF **enter 前**采 main PC（勿等 200ms）。  
4. 禁：`dispatch_sync(main)` QF；未证 drain 前勿撤 inThread 上屏。  
5. 改善 `callStackSymbols` 落盘（原始前 12 行，勿过度压缩）。
