# 假设 AJ：禁 bg 枚举 UIWindowScene.windows + idle 当帧唤醒 main drain

**基线**：`main` tip=`13b240c`（AI 取证）  
**日期**：2026-07-18  
**功能 commit**：`0a5a08a`（已 **revert** → `945ce64`）  
**真机 IPA**：`0a5a08a`（CI `29645307271`）  
**证据**：`fixtures/_accept_aj_probe_sync.json`、`fixtures/_accept_aj_kill_syslog.json`、`fixtures/_accept_aj_probe.json`  
**承接**：AI 证 caller=`LBLegadoKeyWindow`；invoke 后 `ai_main_watch drain=0`；KEEP inThread

---

## 1. 本刀动作

1. `LBLegadoKeyWindow` / `LBAllAppWindows`：非主线程 **禁止** 枚举 `UIWindowScene.windows`；回缓存 / legacy `keyWindow`+`UIApplication.windows`；标签 `aj_bg_keywindow_skip` / `aj_bg_allwindows_skip`。  
2. `ShowResult` / `ShowImportAlert` / `PresentManagerVC`：bg 跳过并 `dispatch_async(main)`。  
3. `invoke_state_idle` 当帧：`dispatch_async(main)` + `CFRunLoopPerformBlock`/`WakeUp`，标签 `aj_main_drain` / `aj_main_pulse` / `aj_main_drain_rl`。  
4. **KEEP** `inject_inThread`（未证 drain 前不撤）。

---

## 2. 真机裁定（`0a5a08a`，禁 mid-chain launch）

| 项 | 结果 |
|---|---|
| bg 枚举禁 | **部分生效**：`aj_bg_keywindow_skip`×2 + `aj_bg_allwindows_skip`×2；`ai_bg_uikit` **空**；`ai_main_watch bgWin=0`（AI 为 4） |
| scene syslog | **仍 ×3**（`13:01:58`，invoke 前，与 skip 同秒） |
| `aj_main_drain` / `pulse` / `rl` | **仅** `aj_main_drain_enqueue`；**无** drain/pulse/rl 执行体 |
| `ai_main_drain_slot` / `qf_dispatch_main_pulse` | **全无**；watch `drain=0 wait=0 src=0` |
| inThread / path | **KEEP**；`sync_inThread`；`qf_enter main=0` |
| QF | `qf_enter`→`ag_post_qf`→`qf_exit`→`cb_exit`（仍 **bg**） |
| pid | **61973→62062** |
| SIGSEGV | **有**（Corpse + `domain:signal(2) code:SIGSEGV(11)`） |
| 前台 | StandarReader；UI **书架空列表** |
| 萧炎 / FIRST-CHAPTER | **否** |

**裁定**：功能目标未达成 → **revert** `0a5a08a`。

---

## 3. 取证解读

### 3.1 bg scene 禁的效果与残留

- Bridge KeyWindow 不再经我们的 `ai_bg_uikit` 钩打到 `-[UIWindowScene windows]`（`bgWin=0`）。  
- 但 syslog 仍有 3 条「Unsupported enumeration of UIWindowScene windows on non-main thread」——与 skip **同秒、invoke 前**。  
- 疑点：bg 回落路径仍调用 `UIApplication.windows` / `keyWindow`，现代 iOS 可能 **内部仍触 scene.windows**；或存在 **钩安装前** 的其它 caller（本刀 `ai_bg_uikit` 空，无法再归因到 KeyWindow 钩后路径）。

### 3.2 main drain 仍饿死

- idle 当帧只见 `aj_main_drain_enqueue`（主线程写日志），随后同窗 bg QF 跑完；主队列 **从未** 执行 `aj_main_drain`/`pulse`/`ai_main_drain_slot`。  
- 与 AI「`invoke_state_idle` 后主队列不排空」一致；`CFRunLoopWakeUp` **不足以** 让主线程回到可排空边界。  
- 采到 `ai_main_block_pc r=2`（符号质量仍差）。

### 3.3 杀因

仍为 **bg QF（KEEP inThread）→ SIGSEGV**；禁 KeyWindow scene 枚举 **未消除** Corpse/SIGSEGV，也未带来主线程 QF。

### 3.4 对照策略（撤 inThread）

**未执行**：成功条件要求先见 `main_pulse/drain`；本刀 drain 执行体为 0，按约定 KEEP inThread。

---

## 4. 是否最小修？

| 候选 | 裁定 |
|---|---|
| 仅禁 KeyWindow/AllAppWindows 碰 scene | 消 `ai_bg_uikit`；**不能**消 syslog×3 / SIGSEGV / 通 drain |
| idle 当帧 async+WakeUp | **失败**（仅 enqueue） |
| 撤 inThread | **本刀不做**（无 drain） |
| 功能修保留 | **否** → revert |

---

## 5. 下一刀建议

1. bg 取 window：**彻底勿碰** 任何 windows API（含 `UIApplication.windows`/`keyWindow`），仅回弱缓存或 nil，并在钩安装前打 caller 标签。  
2. 主线程饿死：在 QF **enter 前** 强化 PC/栈；查 invoke 返回后主线程卡在何处（勿再叠无证据的 WakeUp）。  
3. 未证 drain 前 **勿** 撤 inThread 上屏；长期上屏仍需主线程 QF。  
4. 保留 AI 探针；文档层 KEEP V+W+X+Y+Z / BQM check/format id。
