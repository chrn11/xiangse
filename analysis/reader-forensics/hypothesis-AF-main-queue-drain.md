# 假设 AF：invoke 后主队列不排空 / +1～2s 进程重建

**基线**：`main`=`2659e88`（AE）；KEEP V+W+X+Y+Z；禁 bounce / dontFormat；AA 保持 revert  
**日期**：2026-07-18  
**真机 IPA**：`96f29b7` / `5f6c09d`（CI `29643306279` / `29643497898`）  
**证据**：`fixtures/_accept_af_probe.json`、`fixtures/_accept_af_probe_sync.json`  
**承接**：AE 注入 `callback_inThread` 通 QF，但萧炎否（前台曾在短信）

---

## 1. 本刀动作

1. **撤** `callback_inThread` 注入，保持 original `path=async_main`。  
2. **探针**：`af_main_hb` / `appState` / `af_main_drain_*` / `pid=`。  
3. **修尝试**：invoke 后立刻让出主队列，Z 探针延后；验收强制 `get_frontmost_app==StandarReader`。  
4. **禁**：bounce / dontFormat / 手工 alloc container / Bridge 外调 pageContainer getter / setPageModel。

---

## 2. 真机裁定（`5f6c09d`）

| 项 | 结果 |
|---|---|
| `app=` | **active(0)**（非 background） |
| 前台 bundle | **com.appbox.StandarReader**（非短信） |
| UI | **书架空列表**（非阅读页正文） |
| `path` | **async_main**；`af_no_inThread_inject`；无 `inject_inThread` |
| `format_exit` / `cb` | format 通；**无 `cb_exit`**（死在 `af_after_cb` 之后） |
| `qf_enter` / pulse / hb / drain_slot / drain_ok | **全 0** |
| `af_main_drain_TIMEOUT` | **未落到盘**（进程在 1.2s 等待内被杀） |
| pid | invoke=`60763` → 下一秒 `install_done pid=60808` |
| 今日 StandarReader `.ips` | **无**（与 AB 一致，偏 SIGKILL/看门狗静默杀） |
| 萧炎 / FIRST-CHAPTER | **否** |

`96f29b7` 同构：`path=async_main`、无 QF/pulse、`app=active`、前台 StandarReader，但 UI 已回书架；`nativeRead` 前后 pid `60677→60745`。

---

## 3. 重建根因（本刀结论）

**不是**「验收抢焦点 / 前台挂起导致主队列不排空」。

1. AE 即使 `inThread` 通 QF，`main_pulse` 仍为 0 → 主队列本就不排空。  
2. AF 在 `app=active` + StandarReader 前台下复现：**async_main 入队后主队列任何后续块（hb/pulse/drain/QF）均不执行**，约 +1s `install_*` 且 pid 变。  
3. 无新 `.ips` / 无 `fatal_signal` → 与 AB 相同，偏 **SIGKILL / scene-update 类静默终止**，不是已证实的 EXC_BAD_ACCESS。  
4. AE 的 `inThread` 只是在进程被杀前于 **后台线程同步跑完 QF**；不能上屏，也不能恢复主队列。

**仍卡在**：`format`/`after_cb` 之后 → **主线程未跑到 `qf_enter`**（进程先灭）。下一刀应查 **谁在 invoke/CB 窗口 SIGKILL**（Jetsam / scene-update / 原生 abort 无报告），而不是再叠 inThread。

---

## 4. inThread 可否撤

| 问 | 答 |
|---|---|
| 撤掉后 async_main→QF？ | **否**（本刀未通） |
| inThread 是否可作长期方案？ | **否**（QF 在 bg，UI/萧炎不通；pulse 仍 0） |
| 本刀代码 | **已 revert**（失败按约定回退） |

---

## 5. 验收脚本侧 KEEP

`fixtures/_accept_af_probe.py` 的前台硬断言（`get_frontmost_app` + 禁止在短信 UI 上 dismiss）仍有价值，避免 AE 伪阴性；随 revert 一并回退时可由下一刀按需拣回。
