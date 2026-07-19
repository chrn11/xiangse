# 假设 AM：cb_exit 后轻量心跳钉 exit reason + ICU caller

**基线 tip（会话起）**：`9cb0efa`（AL docs）  
**功能 KEEP**：`fe1c9eb`（禁任何 bg windows API）+ inThread  
**本刀 forensics commit**：`fda300c`（`am_post_cb_hb_*` + `am_icu_caller_*`；**非**行为修复）  
**日期**：2026-07-19  
**真机 IPA**：`fda300c`（CI `29669760941`）  
**证据**：`fixtures/_accept_am_probe_sync.json`、`fixtures/_accept_am_kill_syslog.json`、`fixtures/_accept_am_probe.json`  
**承接**：AL 证死窗伴生 ICU、无 fatal/.ips；建议轻量心跳 + 扩 syslog + 查 Date/Currency 上游

---

## 1. 本刀动作

1. `cb_exit` 后 `am_post_cb_hb_*`：POSIX write+fsync，步长 5ms，覆盖 0–200ms；**禁**全线程 `thread_suspend`（不叠 AL `al_thr_pc`）。  
2. 钩 `NSDateFormatter`（`init` / `setDateFormat:` / `stringFromDate:`）、`NSNumberFormatter`（`init` / `stringFromNumber:` / `setNumberStyle:`）、`+[NSLocale currentLocale]` → `am_icu_caller`（类+SEL+短栈；仅 inQF/postQF）。  
3. 验收扩 syslog：`termination` / `SIGSEGV` / `Jetsam` / `watchdog` / `exit reason` / `RBSProcessExitStatus` / `runningboard`。  
4. 清 openOnce；禁 mid-chain `launch_app`；前台硬断言 StandarReader + 萧炎。

---

## 2. 真机裁定（`fda300c`）

| 项 | 结果 |
|---|---|
| AK windows 禁 | **KEEP**：`ak_bg_windows_api_skip`；`scene_syslog_n=0` |
| QF | `qf_enter`→`ag_post_qf`→`qf_exit`→`cb_exit`（**bg**，`main=0`，`path=sync_inThread`） |
| `am_post_cb_hb` | **完整**：`i=0..40`，`ms_max=200`，有 `am_post_cb_hb_done` |
| 死窗修订 | **非** AL 所称 &lt;40ms：心跳跑满 200ms 后仍存活；随后 pid 变 |
| mem 斜率 | hb 窗内 `mem≈41→140`（约 +100MB/200ms） |
| **exit reason** | **钉住**：`namespace=2 code=11`（SIGNAL/SIGSEGV）；`launchd (2, 11, 11)`；`Corpse allowed`；`pid:69545 terminated` |
| `al_fatal` / `.ips` / crash_stack | **仍空**（ReportCrash 解析 corpse 但本刀未捞到可读栈） |
| **ICU caller** | **钉住**：`NSDateFormatter` `init`→`setDateFormat:`→`stringFromDate:` + `NSLocale currentLocale`；QF 内 **main+bg**；postQF **主线程**继续至 hit 上限 32；**无** `NSNumberFormatter` 命中 |
| 伴生 ICU PC | `DateFormatSymbols::assignArray` / `LocalizedNumberFormatter::getDecimalFormatSymbols`（AK idle 采样） |
| pid | **69545→69605**（`mid_chain_launch_app=false`） |
| 前台 | StandarReader；UI **书架空列表** |
| 萧炎 / FIRST-CHAPTER | **否** |

**裁定**：取证成功（exit reason + ICU caller）；**无可证最小修**；只交取证。AK/inThread KEEP；勿叠 WakeUp / `dispatch_sync(main)`。

---

## 3. 时间线（pid=69545）

1. `inject_inThread` → bg `qf_enter`…`qf_exit`…`cb_exit`。  
2. QF 内即见 `am_icu_caller`（main hit1–4；bg hit5–16，同构 init/format/string/locale）。  
3. postQF 主线程继续 hit17–32（达上限停记）。  
4. `am_post_cb_hb_start`→…→`am_post_cb_hb_done`（200ms 满窗）。  
5. 其后仍有 `ai_main_watch` / `ag_bg_hb`；mem 继续升至 ~200。  
6. runningboardd：`exit reason namespace=2 code=11`；新 pid=69605 装钩。

---

## 4. 相对 AL 的纠正

| AL 先验 | AM 证据 |
|---|---|
| 死在 cb 后 &lt;40ms（无 `al_post_cb_sample_end`） | 心跳证明 **≥200ms** 仍活；AL 全线程 suspend 采样未跑完 ≠ 进程已死 |
| capture 漏 SIGSEGV | **已钉** `namespace=2 code=11` + Corpse + ReportCrash |
| ICU 仅伴生标签 | **上游 ObjC**：`NSDateFormatter`+`NSLocale`（阅读页时间/本地化路径），非 Bridge 主动 format |

---

## 5. 是否最小修？

| 候选 | 裁定 |
|---|---|
| 禁 bg windows（AK） | **KEEP** |
| 拦/缓存 `NSDateFormatter` | **不做**（系统/原生分页侧；无可控根因栈；可能遮盖） |
| 撤 inThread | **不做**（未证 drain；QF 仍须主线程长期解） |
| WakeUp / `dispatch_sync(main)` | **禁** |

---

## 6. 下一刀建议

1. 用 ReportCrash/corpse 或更轻的 signal 落盘，拿到 **SIGSEGV 故障 PC/LR**（本刀仍空）。  
2. 符号化 `am_icu_caller` 短栈（当前为偏移数字），确认是否 `TextRPageContainer`/状态栏/电池时间视图。  
3. 查 mem +100MB/200ms 是否与 ICU 资源表/分页布局风暴同源。  
4. 长期仍需 **主线程 QF**；KEEP V+W+X+Y+Z / BQM check/format id / AK skip / inThread。
