# 假设 AN：捞 corpse/SIGSEGV 故障 PC + 符号化 ICU 栈 + mem 对照

**基线 tip（会话起）**：`d923609`（AM docs）  
**功能 KEEP**：`fe1c9eb`（AK 禁 bg windows）+ inThread + AM 探针  
**本刀 forensics**：`d308e1b`（夺回 SIGSEGV handler / `an_fault_*` / `LBANSymbolStack` / `an_mem_path`）  
**本刀最小修**：`8984070`（Debug `LBForensicsUTCNow`→`strftime`）  
**日期**：2026-07-19  
**真机 IPA**：forensics=`d308e1b`（CI `29670061930`）；fix=`8984070`（CI `29670275937`）  
**证据**：`fixtures/_accept_an_*.json`、`analysis/reader-forensics/an_fault_*.json`  
**承接**：AM 钉 exit reason=SIGSEGV + DateFormatter caller，但故障 PC 空、栈为数字偏移、mem≈41→140 未判源

---

## 1. 本刀动作

1. 根因：`LBInstallNativeOpenCrashGuards` 的 `signal(SIGSEGV)` 覆盖 AL `sigaction` → `al_fatal` 空。  
2. `post_cb_hb` 窗 `LBANClaimFaultHandlers` 夺回 `SA_SIGINFO|SA_ONSTACK`，写 `an_fault_signal`（Documents+/tmp）。  
3. `LBANSymbolStack`（ObjC `-[Class sel]` / `image!sym+off`）替换 ICU 数字栈。  
4. hb 窗每 25ms `an_mem_path`（仅挂起 main）分类 icu/page/alloc/other。  
5. 验收：卸装重装硬保证 manifest=HEAD；清 openOnce；禁 mid-chain `launch_app`；前台硬断言 StandarReader。

---

## 2. 真机裁定（forensics `d308e1b`）

| 项 | 结果 |
|---|---|
| AK / scene_syslog | **KEEP**；`scene_syslog_n=0` |
| QF | bg `sync_inThread`；`qf_main=false` |
| **故障 PC** | **钉住**：`SIG=11 si_code=2 fault=16ed83ff8 pc=192b6e084 lr≈192b6e050 fp=16ed84050`；`inQF=0 postQF=1`；pid=69754 |
| PC 归属 | `libicucore` 邻域（对照同窗 `uhash`/`UnicodeString`/`DateFormatSymbols`） |
| **ICU 上游栈** | **钉住**：`LBForensicsUTCNowString`→`LBFRecordEvent`→`LBFHook_*`→（QF 内 `LBAE_QueryFinish` / 主线程 `UIKitCore`） |
| mem | hb `46→153`（+107MB/200ms）；`path_class` **icu=12 page=0** → **与 ICU 同源，非分页** |
| 萧炎 / FIRST-CHAPTER | **否**；UI 空列表 |
| pid | **69754→69812** |

**裁定**：取证成功。可证最小修点=Debug 热路径 `NSDateFormatter`。

---

## 3. 最小修后（`8984070`）

| 项 | 结果 |
|---|---|
| `am_icu_caller` | **0**（DateFormatter 风暴消失） |
| hb mem 陡升 | **消失**（仅见 i=0 mem=44） |
| `an_fault_signal` | 本跑未落（capture 亦无 exit reason/Corpse） |
| pid | **69882→69980** 仍变 |
| 萧炎 / FIRST-CHAPTER | **否** |

**裁定**：修消除自伤 ICU/mem 陡升；**未**达 pid 稳/上屏。不 revert（证据正确且去掉已知自伤）；长期仍需主线程 QF。

---

## 4. 是否继续修？

| 候选 | 裁定 |
|---|---|
| AK / inThread | **KEEP** |
| Debug UTC→strftime | **KEEP**（`8984070`） |
| 拦系统 ICU / 猜分页 | **不做** |
| 撤 inThread / WakeUp / `dispatch_sync(main)` | **禁** |

---

## 5. 下一刀建议

1. 在 strftime KEEP 下再钉 **剩余杀因**（exit reason/corpse；本跑 capture 漏）。  
2. 评估 Debug `LBFHook_*` 在 QF 窗的重入/开销（栈见 `LBFHook`↔`UIKitCore`/`StandarReader`）。  
3. 长期：**主线程 QF**；KEEP V+W+X+Y+Z / BQM / AK / inThread。
