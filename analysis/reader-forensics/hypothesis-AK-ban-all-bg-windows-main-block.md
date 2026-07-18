# 假设 AK：禁任何 bg windows API + idle 后 main 阻塞点取证

**基线**：`main` tip=`9a2d389`（AJ docs；功能态=`945ce64` revert AJ）  
**日期**：2026-07-18  
**功能 commit**：`fe1c9eb`（**KEEP**：syslog 归零已证实；未叠 WakeUp）  
**真机 IPA**：`fe1c9eb`（CI `29645681995`）  
**证据**：`fixtures/_accept_ak_probe_sync.json`、`fixtures/_accept_ak_kill_syslog.json`、`fixtures/_accept_ak_probe.json`  
**承接**：AJ 证 skip scene 后 legacy `keyWindow`/`UIApplication.windows` 仍疑触 scene；drain WakeUp 无效

---

## 1. 本刀动作

1. Bridge 非主线程路径：**禁止任何** windows API（`UIWindowScene.windows` / `connectedScenes` / `UIApplication.windows` / `keyWindow`）；仅回主线程弱缓存或 nil；标签 `ak_bg_windows_api_skip caller=...`。  
2. 覆盖：`LBLegadoKeyWindow`、`LBAllAppWindows`、`LBFindTextReaderVCInHierarchy`、`LBBridgeReaderHost`、`LBReloadLegadoCatalogListIfVisible`、ShowResult/ImportAlert/PresentManager、forensics/Debug 取窗。  
3. `invoke_state_idle` 后：密集 mach PC 采样（`ak_main_block_*` / `ak_main_idle_*`）；**禁** WakeUp / drain enqueue。  
4. **KEEP** `inject_inThread`（未证 drain 前不撤）。

---

## 2. 真机裁定（`fe1c9eb`，禁 mid-chain launch）

| 项 | 结果 |
|---|---|
| bg windows API 禁 | **生效**：`ak_bg_windows_api_skip`（KeyWindow / AllAppWindows / FindTextReader）；`ai_bg_uikit` **空**；watch `bgWin=0` |
| scene syslog | **归零**（`scene_syslog_n=0`；AJ 为 ×3） |
| `ak_main_block_*` | **有** r=0..4；分类均为 `ak_main_block_other`（见下） |
| `ai_main_drain_slot` / main_pulse | **无**；watch `drain=0 wait=0 src=0` |
| inThread / path | **KEEP**；`sync_inThread`；`qf_enter main=0` |
| QF | `qf_enter`→`ag_post_qf`→`qf_exit`→`cb_exit`（仍 **bg**） |
| pid | **62219→62309** |
| SIGSEGV | **有**（×3；`domain:signal(2) code:SIGSEGV(11)`） |
| 前台 | StandarReader；UI **书架空列表** |
| 萧炎 / FIRST-CHAPTER | **否** |

**裁定**：windows API 禁 **KEEP**（syslog 归零）；main 饿死 **仅取证**（无 Bridge 同步可修点）；总体 FIRST-CHAPTER **未达成**；**不**叠 WakeUp；**不**撤 inThread。

---

## 3. 取证解读

### 3.1 windows API 清零（AJ 残留已消）

- AJ 回落 legacy `keyWindow`/`UIApplication.windows` 时 syslog 仍 ×3；AK 彻底禁后 **syslog=0** 且钩 `ai_bg_uikit` 空、`bgWin=0`。  
- 证实：现代 iOS 上 bg 触任何 windows API 均可间接触发 scene 枚举警告；弱缓存足够避免该路径。

### 3.2 main「饿死」根因（PC 分类）

idle 后同窗采样（`wait=0 src=0 drain=0`）：

| r | PC 符号（摘要） | 分类 |
|---|---|---|
| 0 | `objc_autorelease` / redacted | `ak_main_block_other` |
| 1 | redacted | `ak_main_block_other` |
| 2 | `_platform_strcmp` ← `res_getTableItemByKey` | `ak_main_block_other`（ICU） |
| 3 | `icu::DecimalFormatSymbols::setPatternForCurrencySpacing` | `ak_main_block_other`（ICU） |
| 4 | `icu::ResourceArray::getValue` | `ak_main_block_other`（ICU） |

**结论标签**：`ak_main_busy_icu_not_sync_wait`

- **不是** Bridge `dispatch_sync(main)` 互锁（无 `ak_main_block_dispatch_sync`）。  
- **不是** RunLoop 空闲等待（无 `ak_main_block_runloop_wait`；observer wait/src 恒 0）。  
- 主线程在 QF/崩溃窗内 **忙于 ICU 资源表**（本地化/格式），故主队列 drain 槽永不执行；与 AJ「WakeUp 无效」一致——唤醒无法打断同步忙计算。  
- **无**可落地的 Bridge 最小修（勿对 ICU 叠 WakeUp）。

### 3.3 杀因

仍为 **bg QF（KEEP inThread）→ SIGSEGV**；禁 windows API **消除 syslog**，**未**消除 Corpse/SIGSEGV，也未带来主线程 QF。

---

## 4. 是否最小修？

| 候选 | 裁定 |
|---|---|
| 禁任何 bg windows API | **KEEP**（syslog/bgWin 归零） |
| idle WakeUp / drain enqueue | **不做**（AJ 已证伪） |
| 按 PC 修 ICU/本地化 | **不做**（非 Bridge 可控根因） |
| 撤 inThread | **本刀不做**（无 main drain/pulse） |

---

## 5. 下一刀建议

1. 主线程饿死：主因是 **busy ICU** 而非 sync 等待；下一刀应查 **谁在 invoke/QF 窗触发 ICU**（系统本地化？原生分页？）或改派发策略，勿再 WakeUp。  
2. 杀因仍绑 bg QF：未证 drain 前勿撤 inThread；长期上屏仍需主线程 QF。  
3. 保留 `ak_bg_windows_api_skip` + AI 钩/PC 采样；KEEP V+W+X+Y+Z / BQM check/format id。
