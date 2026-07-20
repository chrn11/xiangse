# Container Attach 与 invoke orig 后 main 阻塞静态分析

**日期**：2026-07-20
**分析者**：Grok 4.5（静态分析，无真机/无 CI）
**对象**：`analysis/xiangse_2.56.1_open/Payload/StandarReader.app/StandarReader`（arm64 Mach-O，未加密）
**Bridge 源**：`LegadoBridge/Sources/LegadoBridgeHooks/LBLoadCurCpBridge.m`、`LBForensicsObserver.m`

---

## 0. 结论速览

| 问题 | 结论 |
|---|---|
| 原版 `loadCurCp` 是否同步阻塞 main | **否**。`pageStatus != 3` 时直接 release 返回（空操作）；`pageStatus == 3` 时同步调 `queryCpFileByBook`，但后者内部用 `dispatch_async(global_queue, ...)` 异步派发网络请求，不阻塞 main。 |
| invoke orig 后 main 阻塞候选点 | 见 §2，按可能性排序：① forensics early-wrap 50ms 递归重试（main）；② `LBFScheduleAutoDumpPhase` `PerformDump`（main，含对象图遍历）；③ `LBABInstallProbes` method swizzle（main，首次）；④ `LBAKStartPostIdleMainBlockForensics` bg `thread_suspend(main)` 取证；⑤ `LBSeedConfirmedCache` 文件 IO（main）。 |
| container attach 状态 | **不确定（倾向未 attach）**。`sWeakHookReceiver` 是 hook 捕获的 `loadCurCp` receiver（即 `ReadPageContainer` 实例），但原版 `pageContainer` getter 只懒创建并 `setReader:`，**不调 addSubview/addChild**。`LBReaderIsAttachedToUI` 检查的是 **reader VC** 的 `viewIfLoaded.window`，**不检查 container 是否在视图层级**。因此即便 reader VC 已 attach，container 可能仍是裸对象。 |
| 原版 `loadCurCp` 的真正 receiver | **仅 `ReadPageContainer`** 有 `loadCurCp` IMP（0x1000d7cf4）。`TextRPageContainer` / `TextRScrollContainer` 都**没有** `loadCurCp`。若 Bridge 路由到 `TextRPageContainer`，invoke 会落到 NSObject 抛异常或 no-op。 |

**新增盲点**：原版 `loadCurCp` 在 `pageStatus != 3` 时是**空操作**。若 Bridge invoke orig 时 `pageModel.pageStatus != 3`（forensics gate 历史日志常见 `pageStatus=-999`），**invoke 等于没执行**，`invoke_orig_OK` 后自然无萧炎。这是 AH/AI 之外未验证的第三种可能。

---

## 1. 原版 `loadCurCp` 反汇编结论

### 1.1 方法定位（通过 `__objc_classlist` + method list 解析）

| 方法 | 类 | IMP VA |
|---|---|---|
| `loadCurCp` | `ReadPageContainer` | `0x1000d7cf4` |
| `pageContainer` | `TextReadVC1` | `0x10006684c` |
| `pageContainer` | `ReadVCBase2` | `0x1000e7c34`（`mov x0,#0; ret` -- 抽象方法返回 nil） |
| `pageContainer` | `ComicReadVC` | `0x1000432a0` |
| `onResetContentNotify:` | `TextReadVC3` | `0x10000b578` |
| `queryCpFileByBook:cpInfo:cpIndex:userInfo:target:cachePolicy:` | `BookQueryManager` | `0x100060dc4` |
| `queryByActionID:book:queryInfo:sourceName:userInfo:target:notify:cachePolicy:` | `BookQueryManager` | `0x10006106c` |
| `callBackResponse:config:userInfo:` | `LPNetWork2` | `0x10008a1d4` |
| `checkCallBackResponse:config:userInfo:` | `BookQueryManager` / `LPNetWork2` | `0x10005e784` / `0x10008a1c8` |
| `formatCallBackResponse:config:userInfo:` | `BookQueryManager` / `LPNetWork2` | `0x10005f66c` / `0x10008a8ec` |

**关键**：`TextRPageContainer`、`TextRScrollContainer`、`TextRPageContainerPage` **都没有** `loadCurCp`。若 Bridge `LBRouteBResolveContainer` 命中这些类，`sOrigLoadCurCp` 指向的 IMP 实际属于 `ReadPageContainer`（通过 `LBLoadCurCpBridgeRegisterOrig` 注册时拿到的 IMP），调用时 receiver 是 `TextRPageContainer` 实例 -- 这会触发 `doesNotRecognizeSelector` 或在 ivar 读取时拿到错误偏移。

### 1.2 `ReadPageContainer loadCurCp` 控制流（0x1000d7cf4 → 0x1000d7ffc）

```
[self curPageVC]                          ; 0x1000d7d18  selref 0x1002ddc68
[curPageVC pageModel]                     ; 0x1000d7d30  selref 0x1002dd020
[pageModel nCpIndex]                      ; 0x1000d7d50  selref 0x1002da7a8  -> x25
[pageModel pageStatus]                    ; 0x1000d7d84  selref 0x1002da7f0
cmp x0, #0x3; b.ne 0x1000d7fd4            ; ★ pageStatus != 3 -> 直接 release 返回（空操作）
; ---- 仅 pageStatus == 3 才执行 ----
读 ivar (0x1002e5ae0 偏移表)              ; 可能是 arrCatalog 引用
[arrCatalog count]                        ; 0x1000d7dbc  selref 0x1002da4a0
[arrCatalog objectAtIndexedSubscript:]    ; 0x1000d7e88  selref 0x1002da368
[BookQueryManager sharedInstance]         ; 0x1000d7e20  classref 0x1002e3630
[dicFatBook ...]                          ; 0x1000d7e4c  selref 0x1002da410
[BookQueryManager queryCpFileByBook:cpInfo:cpIndex:userInfo:target:cachePolicy:]
                                         ; 0x1000d7ebc  selref 0x1002da7c0
                                         ; 参数: x0=BookQueryManager, x2=cpInfo, x3=cpIndex, x4=book, x5=0, x6=self(reader), x7=2
cbz x23, 0x1000d7fd4                      ; ★ queryCpFileByBook 返回 nil -> 跳结尾
; ---- 返回非 nil 才显示 ----
[self resetLoadCpTip:]                    ; 0x1000d7f00  selref 0x1002de2a8
[LCCommonTool showHudText:detail:view:]   ; 0x1000d7fac  classref 0x1002e35c8
```

### 1.3 `queryCpFileByBook` 不阻塞 main（0x100060dc4 → 0x100060f18）

内部组装 `queryInfo` 字典（`dictionary` + `numberWithInteger:` + `setObject:forKeyedSubscript:`），最后 tail-call：

```
[BookQueryManager queryByActionID:book:queryInfo:sourceName:userInfo:target:notify:cachePolicy:]
                                         ; 0x100060ecc  selref 0x1002dca50
b 0x100201318 (objc_autoreleaseReturnValue)
```

### 1.4 `queryByActionID` 异步派发（0x10006106c → 0x100061718）

```
0x100061524: mov x0, #0; mov x1, #0
0x10006152c: bl 0x10020103c             ; _dispatch_get_global_queue(0, 0) -> x21
0x1000615b0: bl 0x100201018             ; _dispatch_async(x21, block)
```

block 字面量在 `0x10006171c`，descriptor 在 `0x10025d000+0xb90`。block 内部（0x10006171c 起）调用 `[LPNetWork2 ...]` 触发实际网络请求，结果通过 `callBackResponse:config:userInfo:` 回调（`LPNetWork2` IMP `0x10008a1d4`）。

**stub 映射证据**（`llvm-objdump --macho --lazy-bind` + stub 解析）：
- `0x100201018 = _dispatch_async`
- `0x10020103c = _dispatch_get_global_queue`
- `0x100201318 = _objc_autoreleaseReturnValue`
- `0x10020139c = _objc_msgSend`
- `0x1002013b4 = _objc_release`
- `0x1002013c0 = _objc_retain`
- `0x1002013e4 = _objc_retainAutoreleasedReturnValue`
- `0x100201474 = _objc_unsafeClaimAutoreleasedReturnValue`

**`queryByActionID` 全程未出现**：`mach_msg`、`kevent`、`semaphore_wait`、`dispatch_sync`、`dispatch_barrier_sync`、`OSSpinLockLock`、`os_unfair_lock_lock`、`objc_sync_enter`。仅用 `dispatch_async` 派发到全局并发队列。

### 1.5 `loadCurCp` 阻塞 main 结论

| 场景 | 是否阻塞 main |
|---|---|
| `pageModel.pageStatus != 3` | **不阻塞**（空操作，直接 ret） |
| `pageStatus == 3` 且 `queryCpFileByBook` 返回 nil | **不阻塞**（组装字典 + 一次 msgSend，微秒级） |
| `pageStatus == 3` 且 `queryCpFileByBook` 返回非 nil | **不阻塞**（额外 `resetLoadCpTip:` + `showHudText:`，UI 操作但非阻塞） |

**原版 `loadCurCp` 本身不是 main 阻塞源**。AI 假设文档（`hypothesis-AI-bg-uikit-main-block.md`）中 `ai_main_drain_slot` 未排空的原因**不在原版 `loadCurCp` 内部**，而在 Bridge 包裹层（见 §2）。

---

## 2. invoke orig 后 main 阻塞候选点（按可能性排序）

### 2.1 候选 ① forensics early-wrap 50ms 递归重试（main，最高可能）

**代码位置**：`LBForensicsObserver.m` `LBFScheduleEarlyWrapRetry` (L472-479)

```c
static void LBFScheduleEarlyWrapRetry(void) {
    LBFEarlyWrapDiscoverAndInstall();   // 含 objc_getClassList 全表扫描
    LBForensicsInstallObservers();       // 非主线程会 dispatch_sync(main)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        LBFScheduleEarlyWrapRetry();     // 递归，永不停止
    });
}
```

**问题**：
1. **无限递归**：`+load` 时启动，永不停止。每 50ms 在 main queue 排一个 block。
2. **`LBFEarlyWrapDiscoverAndInstall` 开销**：`LBFInitEarlyWrapGlobals` + 遍历命名类 + **`objc_getClassList(NULL,0)` 全表扫描**（L405-419），438 个类逐个 `LBFEnsureEarlyWrap`。
3. **`LBForensicsInstallObservers` 隐患**：非主线程调用时 `dispatch_sync(main, ...)`（L944-950）--若 main 正在等该线程，**死锁**。
4. **与 invoke 后时段重叠**：`invoke_orig_returned` 后 main 需要排空 `ai_main_drain_slot`（`dispatch_async(main)`），但每 50ms 被这个递归 block 抢占。AI 假设 `ai_main_watch i=0..3 drain=0 wait=0 src=0` 与此一致--main 在跑 forensics 重试，不进 RunLoop waiting/sources 边界。

**AH 假设已尝试修复**（`hypothesis-AH-main-thread-qf.md` §1.3：early-wrap 装成功后停止 50ms 重试），但真机裁定 `drain/pulse/QF 仍全 0`--说明仅停重试不足以让 main 排空，但重试本身确实是 main 的常驻负载。

### 2.2 候选 ② `LBFScheduleAutoDumpPhase` + `PerformDump`（main，高可能）

**代码位置**：`LBForensicsObserver.m` `LBFMaybeScheduleAutoDump` (L215-261)

```c
g_autoDumpQueue = dispatch_queue_create("com.legado.forensics.autodump", DISPATCH_QUEUE_SERIAL);
NSDictionary *uiHints = LBFGatherAutoDumpUIHints(triggerVC);  // main 才碰 windows
NSDictionary *dump = LBForensicsPerformDump(phase);            // 对象图遍历
```

`LBFGatherAutoDumpUIHints` 在非主线程直接返回空 hints（L167-172），但 `PerformDump` 本身（`LBForensicsBuildObjectGraph` + `LBForensicsBuildMethodOwners`）开销大。`LBFMaybeScheduleAutoDump` 由 `LBFEarlyWrap_loadCurCp` / `LBFEarlyWrap_viewDidLoad` 触发（L447-470），即 **invoke orig 前后都会触发**。

**注意**：`LBFEarlyWrap_loadCurCp` 在 main 同步执行（因为是 method swizzle IMP），它调用 `LBFMaybeScheduleBeforeDump` + `LBFMaybeScheduleAutoDump`，这两个虽派发到 serial queue，但 forensics 早期版本曾有同步路径。AH 假设 §1.3 提到 "auto-dump 延后 1.5s"，但 tip 是否已落地未确认。

### 2.3 候选 ③ `LBABInstallProbes` method swizzle（main，首次，中可能）

**代码位置**：`LBLoadCurCpBridge.m` `LBABInstallProbes` (L1746-1810)

```c
static void LBABInstallProbes(void) {
    LBABInstallSignalProbes();
    LBAGInstallAtExit();
    LBAIInstallWindowSceneHook();   // UIWindowScene.windows swizzle
    LBALInstallQFUIKitHooks();      // QF UIKit 钩
    LBAMInstallICUCallerHooks();    // ICU caller 钩
    if (sABHooksInstalled) return;
    // 钩 LPNetWork2 callBackResponse / formatCallBack / checkCallBack
    // 钩 BookQueryManager formatCallBack / checkCallBack
}
```

`LBABInstallProbes` 在 `LBInvokeOriginalLoadCurCp` pre_invoke（L2953）和 `LBLoadCurCpBridgeRegisterOrig`（L1890）都调用。首次执行时多个 `class_getInstanceMethod` + `method_setImplementation` + `LBACPeelObserverNext`（遍历类链解包 observer 短桩）--这是 main 同步操作。

**但**：`sABHooksInstalled` 守卫保证只装一次，后续 invoke 不会重复。首次开销在 `register_orig` 时（+load 阶段），不在 invoke orig 后。**因此 invoke orig 后此路径不是阻塞源**，除非 `LBACPeelObserverNext` 每次都跑（看代码 `sABNextCallBackResponse` 冻结后跳过）。

### 2.4 候选 ④ `LBAKStartPostIdleMainBlockForensics` bg `thread_suspend(main)`（中可能）

**代码位置**：`LBLoadCurCpBridge.m` `LBAKStartPostIdleMainBlockForensics` (L554-590+)

```c
dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    const useconds_t delays[] = {0, 30000, 80000, 150000, 300000, 500000};
    // 每个延迟后 LBAKSampleMainThreadPC(round)
    // LBAKSampleMainThreadPC 内部: thread_suspend(mainTh) -> thread_get_state -> thread_resume
});
```

`thread_suspend(main)` 会**挂起 main 线程**读取 PC/LR。虽然 `thread_resume` 立即恢复，但挂起瞬间 main 无法处理任何消息。若 bg 线程在 `delays[]` 的 0/30/80/150/300/500ms 节点采样，**每个节点都短暂挂起 main**。

**与 AI 假设的关系**：AI 假设 `ai_main_block_pc 未落盘`（进程濒死未写出）。AK 假设在 idle 后立即密集采 PC，`LBAKSampleMainThreadPC` 的 `thread_suspend` 可能与 main 的 RunLoop 推进竞争。但这是 invoke orig **之后** idle 阶段的取证开销，不是 invoke 函数体内部的阻塞。

### 2.5 候选 ⑤ `LBSeedConfirmedCache` 文件 IO（main，低可能）

**代码位置**：`LBLoadCurCpBridge.m` `LBSeedConfirmedCache` (L2259-2422)

pre_invoke 时调用（L2943）。内部：
- `writeToFile:atomically:encoding:` 写 cp 文件（L2360）
- `writeToFile:atomically:` 写 localSourceText plist（L2371）
- `createDirectoryAtPath:withIntermediateDirectories:`（L2357）
- 双写目录（nativeDir + legacyDir）

这些是 main 线程同步文件 IO。单次开销通常 <10ms，但若磁盘繁忙（设备老化/容器化）可能达 50-100ms。**不是 main 阻塞主因**，但会延迟 invoke orig 的实际执行点。

### 2.6 候选 ⑥ `LBLogLoadCurCpGates` KVC 链（main，低可能）

**代码位置**：`LBLoadCurCpBridge.m` `LBLogLoadCurCpGates` (L2795-2852)

pre_invoke 和 post_invoke 各调用一次（L2945, L2967）。内部 8+ 次 `valueForKey:`（KVC），每次可能触发 ivar getter 或甚至自定义 getter。`container valueForKey:@"dicContents"` / `curPageVC valueForKey:@"pageModel"` 等可能触发懒创建（见 §3.2）。开销通常 <5ms，但若触发 `pageContainer` getter 懒创建链，可能放大。

### 2.7 候选排序汇总

| 排序 | 候选 | 可能性 | 证据 |
|---|---|---|---|
| ① | forensics early-wrap 50ms 递归 | 最高 | 无限递归 + 全表扫描 + `dispatch_sync(main)` 隐患；AI `drain=0 wait=0 src=0` 与此一致 |
| ② | `PerformDump` auto-dump | 高 | 对象图遍历开销；invoke 前后都触发 |
| ③ | `LBABInstallProbes` swizzle | 中 | 首次 main 同步，但有 `sABHooksInstalled` 守卫 |
| ④ | `LBAKStartPostIdleMainBlockForensics` `thread_suspend` | 中 | 挂起 main 读 PC，但仅 idle 后取证 |
| ⑤ | `LBSeedConfirmedCache` 文件 IO | 低 | main 同步 IO，通常 <10ms |
| ⑥ | `LBLogLoadCurCpGates` KVC | 低 | KVC 链，可能触发懒创建 |

**真正阻塞 main 的最可能源**：候选 ① + ②（forensics 自身常驻负载）。原版 `loadCurCp` 不阻塞（§1.5）。

---

## 3. Container Attach 状态判定

### 3.1 `sWeakHookReceiver` 的来源与性质

**赋值点**：`LBLoadCurCpBridge.m` `LBLoadCurCpBridgeHandleHook` (L3189)

```c
BOOL LBLoadCurCpBridgeHandleHook(id self, SEL _cmd, BOOL isLegado, ...) {
    if (!isLegado) return NO;
    if (self) {
        sWeakHookReceiver = self;   // ★ hook 入口的 self = loadCurCp 的 receiver
    }
    ...
}
```

`LBLoadCurCpBridgeHandleHook` 是 loadCurCp 的 hook 入口（被 swizzle 替换后的 IMP）。`self` 是原生 loadCurCp 的 receiver，即 **`ReadPageContainer` 实例**（或其子类，若 swizzle 装在子类上）。

**性质**：`sWeakHookReceiver` 是 hook 捕获瞬间的 container 对象，**__weak 弱引用**。它**不代表**该 container 已 attach 到 UI。

### 3.2 原版 `pageContainer` getter 的懒创建（不 attach）

**反汇编**（`TextReadVC1 pageContainer` 0x10006684c）：

```
ldr x22, [x8, #0x520]   ; ivar 偏移 _pageContainerA
ldr x0, [x0, x22]       ; 读 _pageContainerA
cbnz x0, 0x100066884    ; 非 nil -> retain 返回（缓存命中）
ldr x23, [x8, #0x524]   ; ivar 偏移 _pageContainerB（备用）
ldr x0, [x19, x23]
cbz x0, 0x10006689c     ; nil -> 创建分支
; 缓存命中路径：retain + autoreleaseReturnValue 返回

; 创建分支 0x10006689c:
[arrCatalog count]                       ; 0x1002da4a0
cbz count, 0x1000669b4                   ; count==0 -> 返回 nil
[NSUserDefaults objectForKey:@"tr_turnPageType"]  ; 0x1002da6b0
ccmp byte@0xbd8, #0x0
b.eq 0x1000669bc                         ; turnPageType==3 && byte@bd8==0 -> UIPageVC 分支
; 否则滚动分支
[ReadScrollContainer alloc]              ; 0x1002e3bc0 classref
[obj setReader:self]                     ; 0x1002da490
[reader setPageContainer:obj]            ; 0x1002da498  ★ 写回 ivar
[obj setPageModel:...]                   ; 0x1002da308
retain + autoreleaseReturnValue 返回
```

**关键**：`pageContainer` getter 只做 **`alloc` + `setReader:` + `setPageModel:` + 写回 ivar**。**不调** `addSubview:` / `addChildViewController:` / `didMoveToParentViewController:`。container 创建后是**裸对象**，未链入视图层级。

### 3.3 Container 何时 attach 到 UI？

原版 `pageContainer` getter 不 attach。attach 发生在其它路径（推测）：
- `onResetContentNotify:` / `onResetContent:` 收到章节内容后，`addSubview:` container 到 reader.view
- `viewDidLoad` / `loadView` 中布局 container

但 **Bridge 的 `LBReaderIsAttachedToUI` 检查的是 reader VC**：

```c
static BOOL LBReaderIsAttachedToUI(id reader) {
    if (![reader isKindOfClass:[UIViewController class]]) return NO;
    UIViewController *vc = (UIViewController *)reader;
    @try { if (vc.viewIfLoaded.window != nil) return YES; } @catch (...) {}
    @try { if (vc.navigationController != nil) return YES; } @catch (...) {}
    @try { if (vc.parentViewController != nil) return YES; } @catch (...) {}
    @try { if (vc.presentingViewController != nil) return YES; } @catch (...) {}
    return NO;
}
```

**盲点**：`LBReaderIsAttachedToUI` 检查 reader VC 是否在导航栈/窗口，**但不检查 container 是否在 reader.view 的子视图树**。因此：
- reader VC 已 push（`navigationController != nil`）-> `attached = YES`
- 但 container 可能仍是 `_pageContainerA` ivar 持有的裸对象，未 `addSubview:`

### 3.4 Legado 路径 invoke orig 时 container 是否已 attach？

**判定：不确定，倾向未 attach**。

理由：
1. Bridge `LBTryContentReadyAndInvoke` -> `LBInvokeOriginalLoadCurCp` 在 `contentReady` 时触发，此时 reader VC 可能刚 `loadViewIfNeeded` 但未 `viewWillAppear`（假设 T：`LBReaderIsAttachedToUI` 注释明确提到 "loadViewIfNeeded 阶段会 contentReady，但此时 VC 尚未 push"）。
2. 即便 reader VC 已 push（attached=YES），container 的 attach 取决于 `onResetContentNotify` 是否已执行。Bridge 的 R2/R3 路径在 `contentReady` 后立即 invoke orig，**早于** `onResetContentNotify`。
3. `sWeakHookReceiver` 是 hook 捕获的 container，但 hook 入口就是 loadCurCp 被调用时--而 loadCurCp 在原版流程里是 `onResetContentNotify` **之后**才调（pageStatus==3 表示已 reset 完成）。Bridge 提前 invoke orig，`pageStatus` 可能仍是初始值（-999 或 0），导致 §1.2 的 `b.ne 0x1000d7fd4` 空返回。

### 3.5 `sWeakHookReceiver` 是已 attach 的 container 还是裸对象？

**判定：裸对象（高置信度）**。

理由：
1. `sWeakHookReceiver` 在 `LBLoadCurCpBridgeHandleHook` 赋值，此时 hook 入口被触发--可能是 Bridge 自身派发的 `loadCurCp`（用于捕获 receiver），**不是**原生 UI 流程触发。
2. 即便是原生流程触发，`pageContainer` getter 返回的 container 在创建后未 attach（§3.2）。
3. `LBRouteBResolveContainer` 优先用 `sWeakHookReceiver`（L2091-2095），若它非 nil 就直接用，**不验证**它是否在视图层级。

### 3.6 R2 真机 `findContainer miss` / `invoke_skip no_container` 的解释

R2 真机历史：`findContainer miss` / `invoke_skip no_container`。这与 §3.2 一致：`pageContainer` getter 在 `arrCatalog.count == 0` 时返回 nil（L `cbz count, 0x1000669b4`）。若 Legado 路径在 arrCatalog 未填充时调 getter，得到 nil container。

AE 之后真机：container 命中 `TextRPageContainer`（非 `ReadPageContainer`）。但 §1.1 反汇编显示 **`TextRPageContainer` 没有 `loadCurCp` IMP**。这意味着：
- 要么 `sOrigLoadCurCp` 注册的是 `ReadPageContainer` 的 IMP，但 receiver 是 `TextRPageContainer`--调用时 ivar 偏移错位，可能崩溃或空操作
- 要么 Bridge 的 `LBObjectIsHypothesisFContainerLike` 把 `TextRPageContainer` 误判为 container，但实际 loadCurCp 应该在 `ReadPageContainer` 上

**建议**：`LBRouteBResolveContainer` 应增加类名白名单（`ReadPageContainer` / `ReadScrollContainer`），拒绝 `TextRPageContainer`（它是 page 容器，不是 chapter 容器）。

---

## 4. 综合结论与下一刀建议

### 4.1 三个盲点的回答

1. **container attach 状态从未确认**：确认。`LBReaderIsAttachedToUI` 只查 reader VC，不查 container 视图层级。`sWeakHookReceiver` 是裸对象（§3.5）。**Bridge 应增加 `container.view.superview != nil` 或 `container.reader.view != nil` 的 attach 校验**。

2. **invoke 返回后 main 队列不排空的真根因**：最可能是 forensics early-wrap 50ms 递归（§2.1）+ auto-dump（§2.2）占用 main，**不是**原版 `loadCurCp` 阻塞（§1.5）。AI 假设的 `drain=0 wait=0 src=0` 与 forensics 常驻负载一致。

3. **原版 `loadCurCp` 是否同步阻塞 main**：**否**（§1.5）。但新增盲点：`pageStatus != 3` 时 `loadCurCp` 是**空操作**，Bridge 提前 invoke orig 可能命中此分支。

### 4.2 下一刀建议

1. **验证 pageStatus**：在 `LBLogLoadCurCpGates` 的 `pre_invoke_routeB` 日志中确认 `pageStatus` 值。若恒为 -999 或非 3，则 invoke orig 是空操作，需推迟到 `pageStatus == 3` 后再 invoke。

2. **container attach 校验**：`LBRouteBResolveContainer` 增加容器类白名单（`ReadPageContainer` / `ReadScrollContainer`），并校验 `container.view.superview != nil` 或等价的 attach 信号。

3. **停 forensics early-wrap 递归**：`LBFScheduleEarlyWrapRetry` 装成功后应**停止递归**（AH 假设已尝试但未落地）。同时 `LBFEarlyWrapDiscoverAndInstall` 的 `objc_getClassList` 全表扫描应改为只在命名类未命中时才扫。

4. **auto-dump 延后**：`LBFMaybeScheduleAutoDump` 的 `PerformDump` 应延后到 invoke orig 完成 1.5s 后，且非 main 线程执行（serial queue）。

5. **盲点验证**：在 invoke orig 前后采 `container.view.window` / `container.view.superview`，确认 container attach 状态，而非仅查 reader VC。

### 4.3 限制

- 静态分析，无真机验证。
- `TextRPageContainer` / `TextRScrollContainer` 的 `onResetContentNotify:` IMP 未反汇编（0x1000b2fb4 / 0x1000fefd0），无法确认 attach 发生在哪个方法。
- `ReadPageContainer loadCurCp` 的 ivar 偏移（0x1002e5ae0）未解析具体 ivar 名（需解析 `__objc_ivar`）。
- forensics early-wrap 递归在 tip 是否已停（AH 假设说已 revert）未确认--需对照当前 Bridge 源确认 `LBFScheduleEarlyWrapRetry` 是否仍有递归（本分析基于当前源 L472-479，**仍有递归**）。

---

## 附录 A. 反汇编工具链

- `lief 0.17.6`：解析 Mach-O section / classlist / method list / selref
- `llvm-objdump --macho --lazy-bind`：解析 `__la_symbol_ptr` -> import 符号
- `llvm-objdump -d --start-address --stop-address`：反汇编指定范围
- 辅助脚本：`.test_tools/disasm_loadcurcp.py`、`.test_tools/resolve_selrefs.py`、`.test_tools/map_stubs2.py`、`.test_tools/querycpfile_disasm.txt`、`.test_tools/querybyaction_disasm.txt`、`.test_tools/pagecontainer_vc1.txt`

## 附录 B. 关键 IMP 地址速查

| 方法 | 类 | IMP | 说明 |
|---|---|---|---|
| `loadCurCp` | `ReadPageContainer` | `0x1000d7cf4` | pageStatus!=3 空返回；==3 调 queryCpFileByBook |
| `queryCpFileByBook:...` | `BookQueryManager` | `0x100060dc4` | 组装 queryInfo，tail-call queryByActionID |
| `queryByActionID:...` | `BookQueryManager` | `0x10006106c` | `dispatch_async(global_queue, block)` 异步 |
| `pageContainer` | `TextReadVC1` | `0x10006684c` | 懒创建 + setReader + setPageModel，不 attach |
| `pageContainer` | `ReadVCBase2` | `0x1000e7c34` | `mov x0,#0; ret` 抽象方法 |
| `onResetContentNotify:` | `TextReadVC3` | `0x10000b578` | 未反汇编（待续） |
| `callBackResponse:...` | `LPNetWork2` | `0x10008a1d4` | 网络回调入口 |

## 附录 C. stub VA -> import 映射（关键）

| stub VA | import |
|---|---|
| `0x10020100c` | `_dispatch_after` |
| `0x100201018` | `_dispatch_async` |
| `0x100201024` | `_dispatch_barrier_async` |
| `0x100201030` | `_dispatch_barrier_sync` |
| `0x10020103c` | `_dispatch_get_global_queue` |
| `0x1002010e4` | `_dispatch_sync` |
| `0x1002010cc` | `_dispatch_semaphore_wait` |
| `0x10020139c` | `_objc_msgSend` |
| `0x1002013b4` | `_objc_release` |
| `0x1002013c0` | `_objc_retain` |
| `0x100201318` | `_objc_autoreleaseReturnValue` |
| `0x1002013e4` | `_objc_retainAutoreleasedReturnValue` |
| `0x100201450` | `_objc_sync_enter` |
| `0x10020148c` | `_os_unfair_lock_unlock` |

`queryByActionID` 反汇编中仅出现 `0x10020103c`（get_global_queue）和 `0x100201018`（dispatch_async），**无任何同步原语**。



