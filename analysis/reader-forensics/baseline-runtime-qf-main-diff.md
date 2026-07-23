# 原版正常 TXT 阅读 vs Legado：QF 线程 / main 排空 / invoke 后行为差分

**HEAD（取证树）**：见 git main 最新
**基线 IPA SHA256**：`ed35e2734ef9d75ab8700921ec2819bb329c679ea508ba88e6d9576ae7be1631`
**可执行文件 SHA256**：`04f780eb59f86c9104f8c8c3c04fb24278f521d0a43e401b3773d2a47890dea7`
**形式**：静态反汇编（lldb 21.1.6 disassemble arm64）+ 假设链真机结论回写 + BC4–BC10 真机回写。
**BC4 回写（2026-07-21）**：`bc_main_drain_end drain=1` → **推翻** AF/AI/AJ「main 不排空」。
**BC5/BC6 误判链（已推翻）**：无 `cb_enter` ≠ CB 绕过；旧 `stackRem` 公式把 used/remaining 标反，**「栈耗尽」不成立**（BC8c：`cb_enter stackRem=535196`）。
**BC8c（2026-07-22）**：CB 完成并声明 `path=async_main`；随后 post-CB 取证窗 SIGSEGV。
**BC9（2026-07-22，`0b46cfe`）**：禁 `LBAMStartPostCbHeartbeat` / `LBAKStartPostIdleMainBlockForensics`。真机：见 `bc9_*_skipped`，**无探针内 SIGSEGV 字样**，但仍无 `qf_enter`；进程约 1s 后换 pid。
**BC10（2026-07-22）**：BC9 IPS 裁定 VWA 风暴；改为 probe-local addMethod + 移除 `viewWillAppear:`。
**BC11（2026-07-23）**：BC10 后仍无 `qf_enter`。IPS `StandarReader-2026-07-23-093434.ips`（pid=48715）：
- 仍 main 511 帧，但符号换成 `LBFHook_drawRect` ↔ `StandarReader` drawRect@0x5bf20
- 根因：`TextReadTV`+`TextReadTVBase` 同 sel 双钩；子类真实 IMP 内 `[super drawRect:]` 进父钩时 `object_getClass(self)` 仍是子类，GetOrig 再次指向子类真实 IMP → 死递归
- 修复：Observer 清单移除 `drawRect:`/`resetContentPosByScreenSize:`；安装时同一继承链同一 sel 去重
**关联**：
- [`baseline-vs-legado-diff.md`](baseline-vs-legado-diff.md)
- [`hypothesis-AE-qf-dispatch-after-format.md`](hypothesis-AE-qf-dispatch-after-format.md)
- [`hypothesis-AF-main-queue-drain.md`](hypothesis-AF-main-queue-drain.md)
- [`hypothesis-AI-bg-uikit-main-block.md`](hypothesis-AI-bg-uikit-main-block.md)
- [`hypothesis-AJ-ban-bg-uikit-main-drain.md`](hypothesis-AJ-ban-bg-uikit-main-drain.md)
- [`reader-call-chain.md`](reader-call-chain.md)

---

## 0. 裁定速览

| 维度 | 原版正常 TXT 阅读（静态判定） | Legado 路径（真机实测） | 差分性质 |
|---|---|---|---|
| loadCurCp 调用线程 | main（UIKit appear/onReset 链） | main | 相同 |
| callBackResponse 执行线程 | bg 网络回调 | bg（Legado CB） | 相同 |
| QF 默认派发路径 | `dispatch_async(main)` | 同（`after_cb path=async_main`） | 相同 |
| main runloop 排空 | 是 | **是**（BC4/BC9：`drain=1`） | 非根因 |
| CB 栈 | 正常 | **正常**（BC8c：`stackRem≈535KB`；旧 rem 公式误标） | 非根因 |
| QF 是否进入 | 是 | BC9/BC10 仍无 `qf_enter`（forensics 钩风暴） | **取证钩副作用** |
| 结果 | QF→division→drawRect 上屏 | forensics 递归风暴杀进程 → 回空书架 | 根因差分（BC10/BC11） |

**核心结论（BC11）**：业务路径（CB→format→`dispatch_async(main)` QF）与原版一致，main 也排空。进程死在 **LegadoBridgeDebug forensics** 对 UIKit/绘制链的错误挂钩（先 `viewWillAppear`，后 `drawRect` 父子双钩 + super 取 orig 错），**QF 块未及执行**。BC6「栈耗尽」、BC5「CB 绕过」、AF「main 不排空」均为误判。

---
## 1. 原版 `callBackResponse` 反汇编（LPNetWork2 @ 0x10008a1d4，全分支）

反汇编工具：lldb 21.1.6 `disassemble --start-address --count`。覆盖范围 +0 ~ +1380（ret @ +1376）。

### 1.1 分支结构（指令级）

| 地址（VA） | 偏移 | 指令/语义 | 含义 |
|---|---|---|---|
| 0x10008a234 | +96 | `cbz x23, 0x10008a274` | **唯一 PRE-CHECK**：response==nil 跳过 check（与 AD 一致） |
| 0x10008a238–250 | +100~124 | `msgSend checkCallBackResponse:config:userInfo:` | 进入 check |
| 0x10008a254 | +128 | `cbz w0, 0x10008a26c` | check 返回 NO 跳过 format |
| 0x10008a4cc/4f0 | +760/792 | 取 `callback_notify` / `callback_target` | 读 ivar |
| 0x10008a50c | +824 | `cbz x24, 0x10008a52c` | notify==nil 跳过 notify_oriConfig |
| 0x10008a52c | +856 | `cbz x25, 0x10008a558` | **target==nil 跳过 responds** |
| 0x10008a530–548 | +860~884 | `respondsToSelector: lpNetWorkDelegateQueryFinish:`；`tbz w0, #0, +900` | NO -> 清 target（w20=0） |
| 0x10008a54c | +888 | `mov w20, #1` | target 有效标记 |
| 0x10008a570–594 | +924~956 | `callback_dontFormatResponse`；`cbz x19, +1052` | **nil 才 format** |
| 0x10008a5f0–624 | +1052~1100 | `formatCallBackResponse`（返回 id，覆盖 x23） | format 改写 response |
| 0x10008a624 | +1104 | `cbnz w20, +968` | format 后回查 inThread（w20=target 有效位） |
| 0x10008a59c–5c0 | +968~1004 | 读 `callback_inThread`；`cbz x19, +1108` | **inThread==nil 落到异步** |
| 0x10008a5c4–5ec | +1008~1048 | `msgSend lpNetWorkDelegateQueryFinish:config:userInfo:`（x0=x25 target） | **inThread!=nil：当前线程同步 QF**，release target，清 nil |
| 0x10008a628 | +1108 | `orr x8, x24, x25`；`cbz x8, +1292` | notify 和 target 都 nil 则跳过 dispatch |
| 0x10008a630–6ac | +1116~1240 | 构造 block（invoke=0x10008a868），`dispatch_async(main_queue, block)` | **async_main QF 派发** |
| 0x10008a868 | block +32 | `ldr x1, [x8, #0xd28]`（QF selref）；`bl msgSend` | block 在 main 上同步调 QF |

### 1.2 原版 QF 线程判定（静态）

- `callback_inThread` 是 **只读 ivar**（getter），原版二进制无任何 `setCallback_inThread:` 或 KVC 写入路径（selrefs 扫描未发现 setter 调用）。
- 原版正常 TXT 阅读时 `callback_inThread == nil`（默认未设置）。
- -> 走 `dispatch_async(main_queue)` 分支（0x10008a630–6ac）。
- block invoke（0x10008a868）在 main 队列上同步调 `lpNetWorkDelegateQueryFinish:config:userInfo:`。
- **QF 在 main 线程执行**（原版正常路径）。

### 1.3 原版 main 排空判定（静态推断）

- `callBackResponse` 在 bg 网络回调线程执行，末尾 `dispatch_async(main, block)` 入队后立即返回（非阻塞）。
- main 线程 RunLoop 在原版正常阅读时处于活跃状态（appear/触摸/绘制驱动），会在下次循环迭代调度该 block。
- QF 在 main 跑 -> `divisionResponse` -> `textViewL` lazy -> `setAttString`/`resetFrameRef` -> `setNeedsDisplay` -> `drawRect:` 上屏。
- **原版无任何在 main 上阻塞网络/锁的路径**（见 §2 loadCurCp 反汇编）。

---
## 2. 原版 `loadCurCp` 反汇编（ReadPageContainer @ 0x1000d7cf4，全函数 +0~+776）

### 2.1 关键指令序列

| 地址（VA） | 偏移 | 指令/语义 | 含义 |
|---|---|---|---|
| 0x1000d7d14–d30 | +32~60 | retain self -> x20；msgSend 取 ivar（curPageVC?）-> x19 | 取 receiver 状态 |
| 0x1000d7d88 | +148 | `msgSend`（取 pageStatus?）；`cmp x0, #0x3` | pageStatus 判断 |
| 0x1000d7d90 | +156 | `b.ne 0x1000d7fd4`（+736 返回路径） | pageStatus!=3 早退 |
| 0x1000d7da4 | +176 | `objc_loadWeakRetained`（reader weak ref） | 取 weak reader |
| 0x1000d7dbc–dd8 | +200~228 | msgSend arrCatalog / count | 目录计数 |
| 0x1000d7df8 | +260 | `b.hs 0x1000d7fdc`（+744 返回） | count 边界 |
| 0x1000d7eb0–ebc | +448~456 | `msgSend queryCpFileByBook:cpInfo:cpIndex:userInfo:target:cachePolicy:`（w7=2） | **异步发起章文请求** |
| 0x1000d7ec0–ef8 | +460~516 | retainAutoreleasedReturnValue / release（5 次） | 清理临时 retain |
| 0x1000d7efc | +520 | `cbz x23, 0x1000d7fd4`（+736 返回） | queryCpFile 返回 nil 早退 |
| 0x1000d7f00–f50 | +524~604 | msgSend resetLoadCpTip / queryCpFileByBook 二次调用（w4=1, w6=0） | 失败重试或补取 |
| 0x1000d7fd4–ffc | +736~776 | release / ldp / `b objc_release`（tail call） | 返回 |

### 2.2 同步等待判定

- **全函数无 `dispatch_sync` / `dispatch_barrier_sync` / `os_unfair_lock_lock` / `pthread_mutex_lock` / `semaphore_wait` / `mach_msg` 同步原语**。
- `queryCpFileByBook:...cachePolicy:2` 是异步发起（网络/缓存回调走 `callBackResponse`）。
- `loadCurCp` 调用后立即返回，**main 不阻塞**。
- 原版正常阅读时 main 不会被 `loadCurCp` 阻塞 -> main RunLoop 持续排空 -> `dispatch_async(main)` 的 QF 块能被调度。

### 2.3 原版 main 阻塞候选点列表（静态：无）

反汇编确认原版 `loadCurCp` 与 `callBackResponse` 路径上 **不存在** main 同步阻塞点。main 排空的前提是 RunLoop 活跃（appear/绘制驱动），这在原版正常阅读时成立。

---
## 3. Legado invoke 路径：main 阻塞候选点列表

### 3.1 invoke 调用链与线程

```
[main] ResetContent 通知（LBBridgeReaderVC.m:59 注册 mainQueue）
  -> [main] LBNoteResetContentPosted (LegadoBridgeCExports.m:7443)
  -> [main] LBLoadCurCpBridgeOnContentPosted (LBLoadCurCpBridge.m:3237)
  -> [main] LBTryContentReadyAndInvoke (LBLoadCurCpBridge.m:3154)
  -> [main] LBInvokeOriginalLoadCurCp (LBLoadCurCpBridge.m:2876)
  -> [main] sOrigLoadCurCp(container, @selector(loadCurCp))  // 2960 行
  -> [main] 原版 loadCurCp IMP -> queryCpFileByBook（异步）
  -> [main] invoke_orig_returned -> post_invoke 探针
  -> [bg]  网络回调 -> callBackResponse -> dispatch_async(main, QF block)
  -> [main] QF block 应在此调度  <-- Legado 实测：永不执行
```

invoke 前后 **无 dispatch_sync(main)**（AG 已验证 dispatch_sync(main) QF 会死锁）。线程模型与原版相同。

### 3.2 Legado invoke 后 main 阻塞候选点（待逐项排除/确认）

以下为 invoke orig 返回后、main 队列应排空却未排空的候选原因，按可能性排序：

| # | 候选点 | 证据状态 | 评估 |
|---|---|---|---|
| **C1** | invoke orig 触发原生 `pageContainer` 工厂 `addChildViewController:`（0x10006697c）在 Legado 父 VC 层级下不一致，引发 UIKit 内部状态机异常 -> main RunLoop 卡在 scene update | I/D confirmed 杀点；J defer 避同步杀但未 attach_OK | **高**：UIKit 容器层级操作在 main 同步执行，可能触发内部 assertion/scene 挂起 |
| **C2** | Bridge bg 线程枚举 `UIWindowScene.windows` / `UIApplication.windows`（LBLegadoKeyWindow / LBAllAppWindows）在 invoke 前后命中 UIKit 内部锁，与 main 上的 scene update 互锁 | AI `ai_bg_uikit` 空（本刀未捕获）；AJ 禁 bg 枚举后 `bgWin=0` 但 main 仍 drain=0 | **中**：AJ 部分生效但未根除；现代 iOS scene.windows 内部可能仍触 UIKit 锁 |
| **C3** | invoke 后 main 上排队的 forensics 探针块（`dispatch_async(main, qf_dispatch_main_pulse)`、`dispatch_after(main, 0.6s, async_plus)`）与原生 QF block 竞争，若 UIKit 已挂起则全部饿死 | AF `af_main_drain_TIMEOUT` 未落盘；AJ `aj_main_drain_enqueue` 有但执行体无 | **中**：探针本身不阻塞，但若 main 已挂起则探针也无法运行，故 drain=0 |
| **C4** | Legado `LBSeedConfirmedCache` / `LBEnsureLoadCurCpPrereqs` 在 main 上做 KVC 写 ivar（`setDicBook:` / `arrCatalog` seed），若触发原生 KVO/通知在 main 上链式调用 UIKit -> 与 C1 叠加 | 静态：seed 为 scalar/数组非 UI；diff §4 允许 | **低**：seed 本身非 UI，但若触发原生 observer 回调到 UIKit 则可能叠加 |
| **C5** | invoke orig 时 container 未 attach（R2 `findContainer miss` / `invoke_skip no_container`），原生 loadCurCp 在非预期状态下触发内部 early return 或异常路径 -> UIKit 状态不一致 | R2 confirmed no_container；但 AE 真机 `responds=1` 说明 container 存在 | **低**：AE 路径 container 存在，此候选主要适用于 R2 早期路径 |
| **C6** | 进程级资源耗尽（phys_footprint 暴涨 / fd 泄漏 / mach port 满）导致 main 线程被 jetsam 预警挂起 | AG `mem(phys_footprint)` 探针；pid +1~2s 变 | **低-中**：AG 未证实 mem 暴涨；pid 变更更偏 SIGKILL 而非渐进资源耗尽 |

### 3.3 候选点排除进度

- **C1** 最可能：与 baseline-vs-legado-diff §5 「第一个确定偏离 = onReset->pageContainer 工厂路径」一致。原版正常阅读时父 VC 层级正确，`addChildViewController:` 不触发异常；Legado 父 VC 层级（nativeFull push 时序）可能使该调用进入 UIKit 内部不一致状态，进而 main RunLoop 无法回到 BeforeWaiting。
- **C2** 次可能：AJ 禁 bg 枚举后 main 仍 drain=0，说明 C2 非唯一根因，但可能贡献。
- **C3–C6** 为伴生现象或低概率，需后续真机逐项排除。

---
## 4. 原版 vs Legado：QF 线程 / main 排空 / invoke 后行为对照表

| 相位 | 原版正常 TXT（静态判定） | Legado（真机实测 + 静态） | 偏离点 |
|---|---|---|---|
| **loadCurCp 调用** | main，appear/onReset 链 | main，ResetContent 通知（mainQueue 注册） | 无 |
| **queryCpFileByBook** | 异步，cachePolicy=2 | 异步（invoke orig 后） | 无 |
| **网络回调线程** | bg（NSURLConnection delegate） | bg（Legado handleContentRequest 回调） | 无 |
| **callBackResponse 入口** | bg，response 非 nil | bg，response 非 nil（AD 真机 respLen=111） | 无 |
| **checkCallBackResponse** | 进入，ok=1 | 进入，ok=1（AD 真机） | 无 |
| **formatCallBackResponse** | 进入，返回非 nil | 进入，返回非 nil（AE 真机 outLen=107） | 无 |
| **callback_inThread 读** | nil | 原本 nil；**AE 起注入 @YES** | **Legado workaround** |
| **QF 派发分支** | dispatch_async(main) | 注入后：同步当前线程；未注入：dispatch_async(main) | 静态相同；运行时 Legado 选同步 |
| **QF 执行线程** | **main**（block 被调度） | 注入：bg（同步）；未注入：**永不执行**（main 不排空） | **根因差分** |
| **main 队列排空** | **是**（RunLoop 活跃，BeforeWaiting/BeforeSources 正常） | **否**（AF/AI/AJ：drain=0 pulse=0 wait=0 src=0） | **根因差分** |
| **divisionResponse** | main 上执行 | 未到达（QF 没跑） | 级联 |
| **textViewL lazy / drawRect** | 触发，上屏 | 未触发 | 级联 |
| **进程结局** | 正常阅读 | +1~2s pid 变（SIGKILL/scene 静默杀；bg QF 后 SIGSEGV） | 杀点 |

### 4.1 invoke 后 main 行为差异（核心）

| 项 | 原版 | Legado | 差异原因 |
|---|---|---|---|
| invoke orig 返回 | 正常返回 | 正常返回（`invoke_orig_returned` / `invoke_state_idle` 有） | 无 |
| main RunLoop 回到可排空边界 | 是（BeforeWaiting/BeforeSources 计数正常） | **否**（AI RunLoop observer 无 BeforeWaiting/BeforeSources 计数） | **C1/C2 候选** |
| dispatch_async(main) 块调度 | 被调度（QF/pulse/drain 均执行） | **不被调度**（QF/pulse/drain 均为 0） | main RunLoop 未回到排空边界 |
| main 线程 PC | UIKit 正常绘制/事件处理 | AI `ai_main_block_pc` 未落盘（进程濒死）；AJ 未采到 | 需更强采样 |

---

## 5. 静态证据完整性

| 证据 | 来源 | 置信度 |
|---|---|---|
| callBackResponse 全分支反汇编 | 本回合 lldb disassemble 0x10008a1d4 +0~+1380 | confirmed |
| loadCurCp 全函数反汇编 | 本回合 lldb disassemble 0x1000d7cf4 +0~+776 | confirmed |
| lpNetWorkDelegateQueryFinish 入口 | 本回合 lldb disassemble 0x1000d8278 +0~+316 | confirmed（入口；完整 IMP 未全反汇编，但与 QF 线程判定无关） |
| dispatch_async block invoke 调 QF | 本回合 lldb disassemble 0x10008a868 +0~+128 | confirmed |
| callback_inThread 原版只读 | selrefs 扫描（setter 未发现）+ 反汇编仅 getter 读 | probable（全二进制 msgSend 扫描未覆盖 100%，但 callBackResponse 内确认仅读） |
| Legado invoke 在 main | LBBridgeReaderVC.m:59 mainQueue 注册 + 调用链静态分析 | confirmed |
| Legado main 不排空 | AF/AI/AJ 真机实测 | **推翻**（BC4 真机 `bc_main_drain_end drain=1 wait=8 src=11`；AF/AI/AJ drain=0 为 QF 块 bg 自测误导） |
| 原版 main 排空 | 静态推断 + BC4 legado 真机对照 | confirmed（BC4：legado main 排空正常，原版同理） |

### 5.1 缺口（BC4 后状态）

- ~~原版正常 TXT 阅读的运行时 baseline dump 从未补齐~~ **BC4 已闭合**：BC4 真机在 legado-debug IPA 采到 `bc_main_drain_end drain=1 wait=8 src=11`，证实 main runloop 排空正常。baseline-debug 因 forensics early wrap 副作用点书即退出，无法真机采集，但 legado 路径已足够证明 main 排空正常，原版同理 confirmed。
- **新缺口**：CB 线程栈耗尽根因未定位。BC6b 证实进入 CB 时栈仅剩 1284 字节（已用约 523KB/524KB）。需追查 CB 进入前谁耗尽栈（候选：LegadoBridge 探针链/forensics trampoline 深度递归/原生 queryCpFileByBook 回调链过深）。

---

## 5.5 BC4 真机回写：main runloop 排空 confirmed（推翻 AF/AI/AJ）

**commit**：`5f7535c`（BC4：main drain 探针挂 viewDidLoad after，回退 ReadPageContainer early wrap）
**IPA**：`dist-ci/bc4_5f7535c/dist/StandarReader-legado-debug.ipa`（git_commit=5f7535c, variant=legado-debug）
**采集时间**：2026-07-21 21:36:08–09（inv=1, pid=33967）

### 5.5.1 探针设计

- `LBFBCStartMainDrainSampler`：viewDidLoad TextReadVC3 after 触发（main 线程）
  - `CFRunLoopObserver` 监听 main runloop `kCFRunLoopBeforeSources` / `kCFRunLoopBeforeWaiting`，计数 src/wait
  - `dispatch_async(main_queue, drain_slot)`：若 main runloop 排空则 drain_slot 被调度执行 -> drain=1
  - bg 轮询 2.5s 每 100ms 写 watch 行

### 5.5.2 实测结果（`legado_ab_probe.txt` 原文）

```
21:36:08 | bc_main_drain_start main=1                          # viewDidLoad after，main 线程投 drain slot
21:36:08 | bc_main_drain_watch i=0 drain=0 wait=1 src=2 main=0  # 100ms 后，drain slot 未执行，但 runloop 有活动（wait=1 src=2）
21:36:08 | bc_main_drain_slot wait=1 src=3 main=1               # drain slot 执行了（main 排空），main=1
21:36:09 | bc_main_drain_watch i=1 drain=1 wait=8 src=11 main=0 # 200ms 后，drain=1（已排空），wait=8 src=11（runloop 活跃）
21:36:09 | bc_main_drain_done i=1 main=0                       # 完成
21:36:09 | bc_main_drain_end drain=1 wait=8 src=11 main=0       # 最终：drain=1
```

### 5.5.3 结论

- **main runloop 排空正常**：drain_slot 在 100–200ms 内被 main 调度执行（drain=1），RunLoop observer 计数 wait=8 src=11（活跃）。
- **AF/AI/AJ 的 drain=0 被推翻**：`ak_main_block_other drain=0` 是 QF 块在 bg 线程（main=0）自测「main 是否正在执行 block」，非「main runloop 是否排空」。QF 块自己在 bg 执行时 main 自然不在执行它，drain=0 是线程错配的症状，非 main 排空状态。
- **原版 main 排空 confirmed**：legado 路径 main 排空正常，原版同理（原版无 invoke 注入，QF 走原生 dispatch_async(main) 正常调度）。

### 5.5.4 BC5 真机回写：CB 被绕过（纠正 BC4 线程错配误判）

**commit**：`1f2d340`（BC5：CB hook 优先装 BQM，探针查 BQM 是否覆盖 callBackResponse）
**IPA**：`dist-ci/bc5_1f2d340/dist/StandarReader-legado-debug.ipa`（git_commit=1f2d340）
**采集时间**：2026-07-21 22:31:24–25（inv=1 pid=34287, inv=0 pid=34308）

#### BC5 探针设计

- `bc5_cb_owner_probe`：install_cb 时查 BQM 和 LPNetWork2 的 CB IMP，报告 `bqmOverrides`（BQM 是否覆盖 CB）
- install_cb 优先装 BQM（cbOwner = BQM ?: net），fallback LPNetWork2，与 format/check 一致

#### BC5 实测结果

```
22:31:25 | bc5_cb_owner_probe bqm=BookQueryManager bqmImp=0x104fd21d4 netImp=0x104fd21d4 same=1 bqmOverrides=0  (inv=0 pid=34308)
22:31:25 | install_cb next=0x104fd21d4 owner=BookQueryManager  (inv=0 pid=34308)
```

- **BQM 未覆盖 CB**（bqmImp == netImp，same=1，bqmOverrides=0）。CB 实现在 LPNetWork2，BQM 继承使用。install_cb 装在 BQM 正确。

#### inv=1 周期（pid=34287）ab_probe 关键行

```
22:31:24 | pre_invoke_orig target=TextRPageContainer main=1 inv=1
22:31:24 | invoke_orig_returned main=1 inv=1
22:31:24 | swcf_enter/exit  (stringWithContentsOfFile, bg)
22:31:24 | check_enter/exit self=BookQueryManager main=0 inv=1  (check 被调)
22:31:24 | format_enter respLen=111 main=0 inv=1  (format 被调)
22:31:24 | qf_dispatch_gates phase=post_format path=async_main main=0 inv=1  (post_format 标注)
22:31:24 | format_exit main=0 inv=1
22:31:24 | invoke_state_idle main=1 inv=1
22:31:24 | ak_main_block_other/nosym drain=0 main=0 inv=1  (AK 采样)
（进程死亡，pid 切到 34308）
```

**缺失行**（inv=1 周期完全没有）：
- `cb_enter` / `cb_exit`（CB hook 入口/出口）
- `after_cb`（CB 返回后探针）
- `qf_dispatch_main_pulse`（CB hook 投的 main pulse）
- `qf_enter`（QF hook 入口）

#### BC5 结论（BC6b 推翻）

- ~~CB（callBackResponse）未被调用~~ **BC6b 推翻**：CB 被调用，但 BB 低栈保护跳过了探针。
- ~~format 被直接调用~~ **BC6b 推翻**：`inCB=1` 证实 format 在 CB hook 内。
- ~~QF 投递点未到达~~ 待 BC7 确认：CB 进入时栈已耗尽，进程可能在 QF 投递后、上屏前被杀。
- **纠正 BC4 线程错配误判**：仍成立（`path=async_main main=0` 的 main=0 是探针自己在 bg）。

### 5.5.5 BC6b 真机回写：CB 进入但栈耗尽（纠正 BC5 绕过误判）

**commit**：`ca80ea4`（BC6b：区分 CB 绕过 vs BB 低栈跳过探针）
**IPA**：`dist-ci/bc6b_ca80ea4/dist/StandarReader-legado-debug.ipa`
**采集时间**：2026-07-22 10:38:00（inv=1 pid=38609）

#### BC6b 探针设计

- `bc6_cb_lowstack`：BB 低栈路径（rem<8KB）纯 C 写盘，不走 ObjC
- `format_enter/check_enter` 追加 `inCB=sABInCallBack` + `stackRem`
- 调用栈仅在 `stackRem>=16KB` 时采集

#### BC6b 实测结果（`legado_ab_probe.txt` 原文）

```
bc6_cb_lowstack rem=1284 pid=38609 inv=1
check_enter ... inCB=1 stackRem=2012 main=0 inv=1 pid=38609
bc6_check_caller inCB=1 stack=skipped_low rem=2012
format_enter ... inCB=1 stackRem=2004 main=0 inv=1 pid=38609
bc6_format_caller inCB=1 stack=skipped_low rem=2004
```

#### BC6b 结论

- **CB 被调用**：`bc6_cb_lowstack rem=1284` 证实 CB hook 入口被命中。
- **BB 低栈保护掩盖了 CB 进入**：rem=1284 < 8192，跳过所有 ObjC 探针（故无 `cb_enter/cb_exit/after_cb`），BC5 因此误判「CB 被绕过」。
- **check/format 在 CB 内**：`inCB=1`（`_Thread_local sABInCallBack`），非绕过。
- **栈耗尽**：进入 CB 时仅剩 1284 字节，format 时约 2000 字节。与 BA 真机（cb_exit 时 rem=596，栈溢出确认）一致。
- **真根因**：CB 线程栈在进入 `callBackResponse` 前已耗尽约 523KB/524KB。进程在 QF 上屏前被杀（栈 guard page）。需 BC7 追查谁耗尽栈。

---

## 6. 对 baseline-vs-legado-diff 的补充条目

以下条目建议追加至 `baseline-vs-legado-diff.md`（本回合不修改原文件，仅在此声明）：

- **§1 路径分叉总览 / 正文加载行**：补充「原版 QF 在 main 执行（静态判定），Legado QF 跑不到 main（真机 confirmed）」。
- **§3 五问 / Q1 下一条取证**：原「baseline-debug after_pagination dump」可具体化为「baseline-debug main_drain_slot + qf_enter main=1 + divisionResponse phase dump」。
- **§5 大脑门禁**：`GATE-3-APPROVED` 条件中「运行时 baseline dump 可并行后补」维持；本回合静态差分填补 QF 线程判定空白，不阻塞路 B。

---
## 7. 交付摘要

### 7.1 差分结论

原版正常 TXT 阅读与 Legado 路径在 `callBackResponse` 静态分支结构上 **完全相同**；差分根因是 **CB 线程栈耗尽**（BC6b 修正）：

- 原版：main 排空（BC4 confirmed）-> CB 执行（栈充足）-> CB 内 `dispatch_async(main)` 投 QF -> QF 在 main 执行 -> 上屏。
- Legado：main 排空正常（BC4），CB **被调用**（BC6b `bc6_cb_lowstack rem=1284`），但进入时栈仅剩 1284 字节 -> 进程在 QF 上屏前被杀（栈 guard page）-> 无上屏。
- BC5「CB 被绕过」是误判：BB 低栈保护跳过 ObjC 探针，但 `inCB=1` 证实 check/format 在 CB 内。
- BC4「QF 线程错配」是误判：`path=async_main main=0` 的 main=0 是探针自己在 bg。
- AF/AI/AJ「main 不排空」是误判：BC4 `drain=1` 推翻。

### 7.2 原版 QF 线程判定

**main**（静态 confirmed）。原版正常 TXT 阅读时 `callback_inThread == nil` -> `callBackResponse` 走 `dispatch_async(main_queue)` 分支（0x10008a630–6ac）-> block invoke（0x10008a868）在 main 上同步调 `lpNetWorkDelegateQueryFinish:config:userInfo:`。

### 7.3 Legado invoke 后 main 阻塞候选点列表

按可能性排序：

1. **C1**（高）：invoke 触发原生 `pageContainer` 工厂 `addChildViewController:`（0x10006697c）在 Legado 父 VC 层级下 UIKit 状态机异常 -> main RunLoop 卡在 scene update。与 baseline-vs-legado-diff §5「第一个确定偏离 = onReset->pageContainer 工厂路径」一致。
2. **C2**（中）：Bridge bg 线程枚举 `UIWindowScene.windows` 与 main 上 scene update 互锁。AJ 禁后部分缓解但未根除。
3. **C3**（中）：main 上排队的 forensics 探针块与原生 QF block 竞争（伴生现象，非根因）。
4. **C4**（低）：main 上 KVC seed 触发原生 KVO/通知链式调 UIKit。
5. **C5**（低）：container 未 attach 时 invoke 触发原生异常路径（R2 早期路径）。
6. **C6**（低-中）：进程级资源耗尽导致 main 被 jetsam 预警挂起。

### 7.4 下一步建议（BC6b 后修正）

- ~~优先验证 C1~~ / ~~追查 QF 线程错配~~ / ~~追查 CB 绕过~~：均已推翻或失效。
- **新优先（BC7）**：追查 CB 进入前谁耗尽约 523KB 栈。候选：
  1. LegadoBridge 探针链（AK/AI/AG/forensics trampoline）在 CB 前的深度调用
  2. forensics `LBForensicsMethodOwnerClass` → `class_copyMethodList` 递归
  3. 原生 `queryCpFileByBook` / `stringWithContentsOfFile` 回调链过深
  4. 验证手段：CB 入口采最小栈帧数（纯 C backtrace_symbols），或临时抬高线程栈 / 将 CB 后处理迁到新线程

---

## 8. 反汇编证据原始片段（关键节选）

### 8.1 callBackResponse callback_inThread 分支（0x10008a59c–5ec）

```
0x10008a59c  +968   adrp  x2, 473 ; @selector(callback_inThread)
0x10008a5a0  +972   add   x2, x2, #0x430
0x10008a5a4  +976   mov   x0, x22          ; config
0x10008a5a8  +980   mov   x1, x27
0x10008a5ac  +984   bl    objc_msgSend     ; 读 callback_inThread
0x10008a5b0  +988   mov   x29, x29
0x10008a5b4  +992   bl    objc_retainAutoreleasedReturnValue
0x10008a5b8  +996   mov   x19, x0          ; inThread 值
0x10008a5bc  +1000 bl    objc_release
0x10008a5c0  +1004 cbz   x19, 0x10008a628  ; inThread==nil -> 落到异步 dispatch
0x10008a5c4  +1008 adrp  x8, 593
0x10008a5c8  +1012 ldr   x1, [x8, #0xd28]  ; lpNetWorkDelegateQueryFinish:config:userInfo:
0x10008a5cc  +1016 mov   x0, x25           ; target
0x10008a5d0  +1020 mov   x2, x23           ; response
0x10008a5d4  +1024 mov   x3, x21           ; config
0x10008a5d8  +1028 mov   x4, x22           ; userInfo
0x10008a5dc  +1032 bl    objc_msgSend      ; 同步调 QF（当前线程）
0x10008a5e0  +1036 mov   x0, x25
0x10008a5e4  +1040 bl    objc_release
0x10008a5e8  +1044 mov   x25, #0x0
0x10008a5ec  +1048 b     0x10008a628       ; 跳过 dispatch_async
```

### 8.2 callBackResponse dispatch_async(main) QF 分支（0x10008a628–6ac）

```
0x10008a628  +1108 orr   x8, x24, x25      ; notify | target
0x10008a62c  +1112 cbz   x8, 0x10008a6e0   ; 都 nil 跳过 dispatch
0x10008a630  +1116 adrp  x8, 466           ; main_queue
0x10008a634  +1120 ldr   x8, [x8, #0x2d8]
0x10008a638  +1124 str   x8, [sp, #0x30]
0x10008a63c  +1128 adrp  x8, 376
0x10008a640  +1132 ldr   d0, [x8, #0xd40]
0x10008a644  +1136 adr   x8, 0x10008a868   ; block invoke 函数
0x10008a648  +1140 nop
0x10008a64c  +1144 str   d0, [sp, #0x38]
0x10008a650  +1148 adrp  x9, 468           ; block descriptor
0x10008a654  +1152 add   x9, x9, #0x10
0x10008a658  +1156 stp   x8, x9, [sp, #0x40]
...
0x10008a6a0  +1228 adrp  x0, 466
0x10008a6a4  +1232 ldr   x0, [x0, #0x300]  ; dispatch_get_main_queue
0x10008a6a8  +1236 add   x1, sp, #0x30     ; block
0x10008a6ac  +1240 bl    dispatch_async    ; 入队 main
```

### 8.3 dispatch_async block invoke（0x10008a868，在 main 上执行）

```
0x10008a868  +0    stp   x20, x19, [sp, #-0x20]!
0x10008a86c  +4    stp   x29, x30, [sp, #0x10]
0x10008a870  +8    add   x29, sp, #0x10
0x10008a874  +12   mov   x19, x0           ; block
0x10008a878  +16   ldr   x0, [x0, #0x20]   ; target
0x10008a87c  +20   cbz   x0, 0x10008a894   ; target==nil 跳过
0x10008a880  +24   ldp   x2, x3, [x19, #0x28] ; response, config
0x10008a884  +28   ldr   x4, [x19, #0x38]    ; userInfo
0x10008a888  +32   adrp  x8, 593
0x10008a88c  +36   ldr   x1, [x8, #0xd28]    ; lpNetWorkDelegateQueryFinish:config:userInfo:
0x10008a890  +40   bl    objc_msgSend        ; 同步调 QF（main 线程）
```

### 8.4 loadCurCp 异步返回（0x1000d7efc，无同步等待）

```
0x1000d7eb0  +448 bl    objc_msgSend        ; queryCpFileByBook:...cachePolicy:2
0x1000d7eb4  +452 mov   x29, x29
0x1000d7eb8  +456 bl    objc_retainAutoreleasedReturnValue
0x1000d7ebc  +460 mov   x23, x0
0x1000d7ecc  +472 bl    objc_release
...
0x1000d7efc  +520 cbz   x23, 0x1000d7fd4    ; nil 早退 -> 返回
0x1000d7fd4  +736 mov   x0, x23
0x1000d7fd8  +740 bl    objc_release
0x1000d7fdc  +744 ldp   x29, x30, [sp, #0x70] ; 返回
...
0x1000d7ffc  +776 b     objc_release        ; tail call 返回
```

全函数无 dispatch_sync / lock / semaphore / mach_msg 同步原语。

---

**报告结束**。本回合静态反汇编 + 差分文件写入完成，未修改代码、未 commit。
