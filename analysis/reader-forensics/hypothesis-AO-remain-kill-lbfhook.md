# 假设 AO：strftime KEEP 下剩余杀因 + LBFHook QF 窗评估

**基线 tip（会话起）**：`ce0e34b`（AN docs）  
**功能 KEEP**：`fe1c9eb`（AK）+ `8984070`（strftime）+ inThread  
**本刀 forensics**：`8ec9f1a`（`ao_fault_*` / handler 探针 / LBFHook 命中重入 / 晚杀窗）  
**降噪试刀**：`b6218c4`（QF/postQF 静默 `LBFRecordEvent`）→ **revert `3aee765`**（pid 仍变）  
**日期**：2026-07-19  
**真机 IPA**：forensics=`8ec9f1a`（CI `29670574318`）；quiet=`b6218c4`（CI `29670692844`）  
**证据**：`fixtures/_accept_ao_*`、`fixtures/_accept_ao_*_forensics_8ec9f1a.json`、`fixtures/_accept_ao_*_quiet_b6218c4.json`、`analysis/reader-forensics/ao_fault_summary.json`  
**承接**：AN 消 ICU/mem 自伤后 pid 仍变；capture 曾漏 SIGSEGV

---

## 1. 本刀动作

1. 强化故障捕获：`ao_fault_signal`→Documents+/tmp；QF 入口/ hb 每 50ms / 晚杀窗 2s 探针 handler（`ao_fault_handler ours=`）；handler 被盖立刻夺回。  
2. LBFHook 评估：QF→postQF 计 `ao_lbf_hook` hit/depth/reenter；`ao_lbf_stats` 摘要。  
3. 试降噪：窗内 `LBForensicsSetRecordQuiet` 跳过写事件（仍计 hit）；**仅 pid 稳才 KEEP**。  
4. 验收：卸装重装；清 openOnce；禁 mid-chain `launch_app`；前台 StandarReader。

---

## 2. 真机裁定（forensics `8ec9f1a`）

| 项 | 结果 |
|---|---|
| AK / scene_syslog | **KEEP**；`scene_syslog_n=0`；handler `ours=1` 全程，stolen=0 |
| QF | bg `sync_inThread`；`qf_main=false` |
| **故障 PC** | **钉住**：`SIG=11 si_code=2 fault=16ce6bfa0 pc=18a092c98 lr≈18a08a168`；`inQF=0 postQF=1`；pid=70016 |
| PC 归属 | **CoreFoundation** 邻域（非 ICU；对照 hb `class=other` / CF） |
| **exit reason** | **钉住**：`domain:signal(2) code:SIGSEGV(11)`；Corpse；`pid:70016 terminated`；`launchd (0,0,11)` |
| `am_icu_caller` | **0**（strftime KEEP） |
| hb mem | `43→45`（+2MB；ICU 陡升已消） |
| **LBFHook** | postQF 窗 `hit=4864 maxDepth=4863 reenter=4863`（写事件风暴；QF 栈见双层 `LBFHook_v_at_id_id_id`↔CB） |
| 萧炎 / FIRST-CHAPTER | **否**（免责声明挡板） |
| pid | **70016→70086** |

**裁定**：剩余杀因=**postQF SIGSEGV@CoreFoundation**（非 ICU）；取证自伤嫌疑指向 Debug `LBFRecordEvent` 风暴，但须降噪对照。

---

## 3. 降噪试刀（`b6218c4` → revert）

| 项 | 结果 |
|---|---|
| quiet | `quiet=1`；写事件跳过 |
| LBFHook hit | **仍≈4864**（trampoline 仍进；仅少写事件） |
| 故障 PC | 仍落：`pc=18a089fdc`（CF 邻域）；`postQF=1` |
| pid | **70149→70236 仍变** |
| 萧炎 / FIRST-CHAPTER | **否** |

**裁定**：**未**证降噪稳 pid → **revert** `b6218c4`（`3aee765`）。保留 forensics `8ec9f1a`。

---

## 4. KEEP / 不做

| 候选 | 裁定 |
|---|---|
| AK / inThread / strftime | **KEEP** |
| `ao_fault_*` / LBFHook 统计 | **KEEP**（取证） |
| QF 窗静默 LBFRecordEvent | **revert**（pid 不稳） |
| 撤 inThread / WakeUp / `dispatch_sync(main)` | **禁** |

---

## 5. 下一刀建议

1. 剩余杀因已非 ICU：盯 **bg QF→postQF 原生/CF 路径**（fault 栈址 `16ce…` 像栈邻域）。  
2. LBFHook：命中高但静默写事件不够；若再动 Debug，须证明 **卸 observer/early-wrap** 后 pid 稳，禁止盲静默。  
3. 长期：**主线程 QF**；KEEP V+W+X+Y+Z / BQM / AK / inThread / strftime。
