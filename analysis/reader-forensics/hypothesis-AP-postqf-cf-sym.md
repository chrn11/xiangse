# 假设 AP：符号化 postQF CoreFoundation 故障 PC，钉 bg QF→postQF 原生/CF 杀路径

**基线 tip（会话起）**：`27a417c`（AO docs）  
**功能 KEEP**：`fe1c9eb`（AK）+ `8984070`（strftime）+ inThread + V+W+X+Y+Z + BQM  
**本刀 forensics commit**：`6ab194a`（`ap_fault_sym` / `ap_postqf_stack` / `ap_fault_fpstack` / CF 锚点；fbase+off 对抗 `<redacted>`）  
**日期**：2026-07-20  
**MCP**：`http://192.168.1.18:8090`（原 `.6` 已漂移）  
**mock**：`http://192.168.1.4:8765`  
**设备**：iPhone14,5 / iOS 16.5 (20F66) / roothide jbroot=`A5519C452FE06486`  
**CI**：push `29710368658` 排队 25m 后取消；重派 `29710987509` fixture-gate 仍长期 queued（GitHub runner 枯竭）→ **未**装新 IPA / **未**跑 `_accept_ap_probe`  
**证据**：`analysis/reader-forensics/ap_fault_sym_device.json`、`hypothesis-AP-postqf-cf-sym.md`；`fixtures/_accept_ap_*` 待 CI  
**承接**：AO 钉 `pc=18a092c98` @ CF、`postQF=1`、LBFHook hit≈4864；静默写事件未稳 pid 已 revert；禁半截 passthrough

---

## 1. 本刀动作

1. 确认 tip=`27a417c`；弃用未接线 passthrough。  
2. 真机取 maps/DSC/Frida：MCP root 白名单极窄（仅 `id`/`killall -9 SpringBoard`）；`frida-server` pid=727 僵死占 27042，无法附着。  
3. forensics：故障 handler 写 `ap_fault_fpstack`；`an_mem_path`/`ap_fault_sym` 落 `img+fbase+off+sname`；postQF 落 `ap_postqf_stack`；install 落 CF 锚点。  
4. 对照 TextRPageContainer：`chapterContent` + `sync_inThread` + respLen≈107/111（免责声明量级）→ postQF CF SIGSEGV。  
5. 可证最小修：本刀**无**（需先拿到 CF 符号/完整 postQF 栈）；禁盲静默 LBFRecordEvent。

---

## 2. AO KEEP 杀路径（仍有效）

| 项 | 值 |
|---|---|
| 故障 | SIGSEGV(11) `si_code=2` `fault≈stack` `pc=18a092c98` `lr≈18a08a168` |
| 窗 | `inQF=0 postQF=1` tid=259 |
| 归属 | CoreFoundation（hb `an_mem_path img=CoreFoundation`；sname=`<redacted>`） |
| QF | `TextRPageContainer` / `chapterContent` / `sync_inThread` / `qf_main=false` |
| LBFHook | hit≈4864 maxDepth≈4863 reenter≈4863（写事件静默后仍杀） |
| 萧炎 / FIRST-CHAPTER | 否 |
| pid | 70016→70086 |

**杀路径（工作假说）**：bg QF（TextRPageContainer）→ postQF →（LBFHook 深重入 + 原生/CF 容器操作）→ SIGSEGV@CF；fault 邻 FP → 栈邻域/深递归嫌疑，**非** ICU。

---

## 3. 本刀真机进展

| 项 | 结果 |
|---|---|
| MCP | **改址** `.18`；health ok |
| DSC | `/private/preboot/Cryptexes/OS/.../dyld_shared_cache_arm64e*` + `.symbols` **已定位** |
| maps/vmmap | MCP 禁 `vmmap`/`cat`/`find`（root 白名单）→ **未**拿到当前 slide |
| Frida | server 僵死；`killall`/launchctl 受限 → **未**附着 |
| CF 符号名 | 待新 IPA 落 `fbase+off` 后对照 DSC `.symbols` |

---

## 4. KEEP / 不做

| 候选 | 裁定 |
|---|---|
| AK / inThread / strftime / V+W+X+Y+Z / BQM | **KEEP** |
| 盲静默 LBFRecordEvent / 半截 passthrough | **禁** |
| bounce / dontFormat / `dispatch_sync(main)` / 全线程 suspend / 空 WakeUp | **禁** |
| 手工 alloc container / Bridge 外调 pageContainer getter / setPageModel | **禁** |

---

## 5. 下一刀

1. CI 装本刀 forensics IPA → 清 openOnce → nativeRead → 收 `ap_fault_sym`/`ap_postqf_stack`/`ap_fault_fpstack`。  
2. 用 `fbase+off` + 设备 DSC `.symbols` 钉 CF 符号；对齐 TextRPageContainer 数据边界可修点。  
3. 仅当 pid 稳且上屏萧炎/FIRST-CHAPTER 才 KEEP 功能修。
