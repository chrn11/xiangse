# 假设 AL：AK syslog 归零后剩余 SIGSEGV/pid 重建杀因取证

**基线 tip（会话起）**：`f381d71`（AK docs）  
**功能 KEEP**：`fe1c9eb`（禁任何 bg windows API）  
**本刀 forensics commit**：`ff4f5ea`（致命栈/QF UIKit/ICU/多线程 PC；**非**行为修复）  
**日期**：2026-07-19  
**真机 IPA**：`ff4f5ea`（CI `29669310648`）  
**证据**：`fixtures/_accept_al_probe_sync.json`、`fixtures/_accept_al_kill_syslog.json`、`fixtures/_accept_al_probe.json`  
**承接**：AK 证 scene syslog=0、main 忙 ICU、仍 pid 变；禁叠 WakeUp；KEEP inThread

---

## 1. 本刀动作

1. `sigaction(SA_SIGINFO|SA_ONSTACK)`：`al_fatal_signal` 写 PC/LR/FP/tid/inQF/postQF（Documents + `/tmp`）。  
2. QF 窗钩 `UIView` `setNeedsLayout` / `layoutIfNeeded` / `setNeedsDisplay` → `al_qf_uikit_*`（仅打点）。  
3. 主线程 PC 分类增加 `al_icu_busy` / `al_icu_trigger`。  
4. `cb_exit` 后全线程 PC 采样 `al_thr_pc`（禁 WakeUp / 禁撤 inThread / 禁 `dispatch_sync(main)`）。  
5. 验收：清 openOnce；禁 mid-chain `launch_app`；前台硬断言 StandarReader + 萧炎。

---

## 2. 真机裁定（`ff4f5ea`）

| 项 | 结果 |
|---|---|
| AK windows 禁 | **KEEP**：`ak_bg_windows_api_skip`；`scene_syslog_n=0`；`ai_bg_uikit` 空 |
| QF | `qf_enter`→`ag_post_qf`→`qf_exit`→`cb_exit`（**bg**，`main=0`，`path=sync_inThread`） |
| `al_qf_uikit sel=` | **0**（`al_qf_uikit_summary hit=0`）；QF 未走所钩 UIView 布局 API |
| `al_icu_*` | **有**（r=1..4）：`ures_getLocaleByType` / `DecimalFormatSymbols` / `DateFormatSymbols` / `CharString::append` |
| `al_thr_pc` | round0：main=`icu::StringPiece`←`ures_getByKeyWithFallback`；其余线程 `nanosleep`/`mach_msg` |
| `al_post_cb_sample_end` | **无**（死在 round0 与 +40ms 之间） |
| `al_fatal_signal` / `/tmp` | **无** |
| `.ips` / `new_crash_count` | **0** |
| 本刀 capture SIGSEGV/Corpse | **未命中**（与 AK 先验不同；见下） |
| pid | **69405→69463**（`t≈2.3s` 已变；`mid_chain_launch_app=false`） |
| 前台 | StandarReader；UI **空列表** |
| 萧炎 / FIRST-CHAPTER | **否** |

**裁定**：无**可证最小修**；只交取证。AK KEEP；inThread KEEP；勿叠 WakeUp。

---

## 3. 新杀因窗（相对 AK）

### 3.1 时间线（pid=69405）

1. `inject_inThread` → bg `qf_enter`…`qf_exit`…`cb_exit`（链路完整）。  
2. 立刻 `al_post_cb_sample_start`；main PC 落在 **ICU 资源/日期货币符号表**。  
3. **未见** `al_post_cb_sample_end` → 进程在 **cb 后 &lt;40ms** 灭。  
4. 新 pid=69463 装钩（`al_keep_inThread=1`，mem≈6）。

### 3.2 排除 / 澄清

| 候选 | 本刀证据 |
|---|---|
| bg `UIWindowScene.windows` | **否**（syslog=0；`ai_bg_uikit` 空） |
| QF 内 `setNeedsLayout` 等 | **否**（hit=0） |
| Bridge `dispatch_sync(main)` | **否**（无 `ak_main_block_dispatch_sync`） |
| 验收 `launch_app` 伪杀 | **否** |
| 主线程 ICU 忙等 | **是（伴生）**：drain/pulse 仍 0；标签 `al_icu_busy` |
| 致命栈 PC/LR | **未拿到**（handler 未落盘；无 .ips） |

### 3.3 与 AK SIGSEGV 先验

AK（`fe1c9eb`）同构链路有明确 `domain:signal(2) code:SIGSEGV(11)` + Corpse。  
本刀 `stop_capture` 4395 行中过滤未命中 SIGSEGV/Corpse，但 **pid 仍变** 且死窗与 AK 同构（QF/CB 完成后、main ICU 忙）。  
**不**据此改判「非 SIGSEGV」；标为 **capture 漏采或日志形态漂移**，下一刀需扩 syslog 关键字 / 缩短采样副作用后再证。

---

## 4. 是否最小修？

| 候选 | 裁定 |
|---|---|
| 禁 bg windows（AK） | **KEEP** |
| 按 `al_qf_uikit` 拦 UIKit | **不做**（hit=0） |
| 修 ICU/本地化 | **不做**（系统库；无 Bridge 可控根因栈） |
| 撤 inThread | **不做**（未证 drain） |
| WakeUp / `dispatch_sync(main)` | **禁** |

---

## 5. 下一刀建议

1. 在 **不** `thread_suspend` 全线程（防取证副作用）前提下，用更轻的 post-cb 心跳 + 扩 syslog（runningboardd/SpringBoard exit reason）再钉 SIGSEGV。  
2. 查 **谁在 invoke/QF 窗触发 main 上 DateFormat/Currency ICU 初始化**（系统？原生分页？），仍勿 WakeUp。  
3. 长期仍需 **主线程 QF**；KEEP V+W+X+Y+Z / BQM check/format id / AK skip。
