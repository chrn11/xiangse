# baseline vs Legado 差分合同（静态 + 已有真机结论）

**HEAD（取证树）**：`57d80b8`  
**基线 IPA SHA256**：`ed35e2734ef9d75ab8700921ec2819bb329c679ea508ba88e6d9576ae7be1631`  
**可执行文件 SHA256**：`04f780eb59f86c9104f8c8c3c04fb24278f521d0a43e401b3773d2a47890dea7`  
**形式**：本回合不补全量 baseline-debug dump；静态反汇编 + 假设链真机验收回写合同。  
**关联静态报告**：
- [`onreset-catalog-kill-analysis.md`](onreset-catalog-kill-analysis.md)
- [`pagecontainer-kill-analysis.md`](pagecontainer-kill-analysis.md)
- [`reader-call-chain.md`](reader-call-chain.md)
- [`method-map.json`](method-map.json)

---

## 1. 路径分叉总览

| 相位 | 原版 TXT（基线推断） | Legado 当前 | 首个确定分叉 |
|---|---|---|---|
| 开书 / 目录 | `loadCatalog` → 原生 DB/站点 | Bridge 短路 `loadCatalog`，走 `handleCatalogRequest` | **目录来源**（Legado mock vs 本地 DB） |
| 进阅读 VC | `openReader` → push `TextReadVC3` | 同（`nativeFull`） | 父 VC / appear 时序可能不同 |
| 容器创建 | `onResetContentNotify` → `pageContainer` getter → 工厂 `addChild`+`insertSubview` | Bridge 曾主动 fire onReset（C→J）；工厂在 `cat≥1` 时同步 `addChild` 易杀 | **Bridge 主动 onReset + Legado 父层级** |
| 正文加载 | `ReadPageContainer#loadCurCp` → `queryCpFileByBook` → `divisionResponse` → `textViewL` | Hook 拦截 `loadCurCp`，异步 `handleContentRequest`；invoke 常 `no_container` | **loadCurCp 被短路且 container 未就绪** |
| 上屏 | `TextRPageContainerPage#textViewL` lazy + `showContent` + `drawRect` | overlay/probe 已撤；原生 host 仍空或 detach | **container attach / division 链未走完** |

---

## 2. 假设链真机摘要（Legado-debug）

| 假设 | 关键证据 | 结论 |
|---|---|---|
| **I** `143d919` | 解包真 IMP 后进 `pageContainer` getter；`cat=2,a=nil`；无 leave；回书架 | **confirmed**：真 IMP 进工厂即 D 类杀点 |
| **C** `be69d0b` | `cat=0`；`ORIG_OK`；`pageContainerA=nil` | **confirmed**：`arrCatalog.count==0` 时 getter 早退安全 |
| **D** `6854db9`（revert） | `cat=2`；无 `ORIG_OK`；回书架 | **confirmed**：`count>0` 进工厂 → `addChild` 杀 |
| **J** `b5ba817`+`57d80b8` | `ORIG_OK`；`pageContainerA=TextRPageContainer`；`children=0`；无 `deferred_attach_OK`；回书架 | **证伪 flush 路径**：容器对象非 nil 但未 attach |
| **R2** | 阅读页标题可见；`attached=1`；`findContainer miss`；`invoke_skip no_container` | **confirmed**：无 container 时 loadCurCp 无法 invoke |

**杀点（指令级，confirmed）**：`pageContainer` 工厂内 `addChildViewController:` @ `0x10006697c`（见 onreset-catalog-kill-analysis §4–6）。

---

## 3. 五问逐项

### Q1. `textViewL` 真实 owner 与创建时刻？

| 项 | 答案 | 置信度 | 证据 |
|---|---|---|---|
| owner | **`TextRPageContainerPage#textViewL` getter**（IMP `0x1000b1924`） | confirmed | method-map + reader-call-chain §2.3 |
| 创建时刻 | 分页页 VC `viewDidLoad` 之后，**首次访问 `textViewL` getter** 时 lazy `alloc TextReadTV` | probable | 静态 xref；运行时 dump 未本回合补采 |
| Legado 偏离 | container/page 未 attach → getter 未触发 | probable | J `children=0`；R2 `curPageVC=nil` |

**下一条取证**：baseline-debug `after_pagination` dump 记录 `textViewL` 首次出现 phase（任务卡 5 运行时部分，可后补）。

---

### Q2. 原版 `loadCurCp` 必要输入？

| 字段 / 前置 | 说明 | 置信度 |
|---|---|---|
| **receiver** | `ReadPageContainer` 实例（非 `TextReadVC3` 自身 IMP） | confirmed |
| **arrCatalog** | `count≥1` 否则 `queryCpFile` 分支不进入 | confirmed（chain-msg + onreset 分叉） |
| **dicFatBook / bookKey** | `BookDbManager` 查书 | probable |
| **curPageVC** | 非 nil 时走当前页；nil 时仍可能 `queryCpFile`（静态） | probable |
| **缓存正文** | `queryCpFileByBook:...` 或 `dicContents` / xsfolder | probable |
| **不依赖** | Bridge 外调 `pageContainer` getter | confirmed（A2 杀；loadCurCp callee 表无 `pageContainer`） |

**Legado 缺口**：container 实例缺失（`pageContainerA` nil 或 detach）时 invoke 无 target（R2）。

---

### Q3. 最窄正文提供 / 缓存边界？

| 边界 | Bridge 允许 | 禁止 |
|---|---|---|
| **写入** | `dicContents`；`Documents/xsfolder/book/<bookKey>/<cpIndex>`；`BookDbManager#setCpCached:...` | `setPageModel:`；`object_setIvar` 写 `_textViewL`；手工 `alloc` container/TV |
| **调用** | 内容就绪后 **一次** 原生 `ReadPageContainer#loadCurCp` | 手工 `divisionResponse` kick（假设 O 已禁）；Bridge fire onReset（路 B 停用） |
| **通知** | 原版 `ResetContent` / appear 链自然触发 | 全局 swizzle `addChild` 长期残留（J 为临时桥，验收后拆） |

实现落点：`LBLoadCurCpBridge.m`（`LBSeedConfirmedCache` / 状态机）。

---

### Q4. `pageModel` / CTFrame 创建者？

| 对象 | 创建者 | 置信度 |
|---|---|---|
| **ReadPageModel** | 容器分页链内部分配（`onDivisionTextFinish` / `curPageVC` 路径） | probable |
| **CTFrame** | **`TextReadTVBase.frameRef`**，经 `setAttString` / `resetFrameRef` → `drawRect` | confirmed（method-map） |
| **setPageModel:** | owner = `ReadScrollContainerCell`；**无 confirmed caller** | owner confirmed；caller unknown |

**Legado 偏离**：未进入 division 链 → pageModel/CTFrame 均未创建。

---

### Q5. Legado 第一个确定偏离点？

**confirmed 偏离序列**：

1. **目录**：`loadCatalog` 被 Bridge 短路（设计如此，非杀点）。
2. **点章后**：Bridge `nativeFull` 曾 **主动 fire** `onResetContentNotify`（假设 C→J），在 `arrCatalog≥1` 时进入 `pageContainer` 工厂。
3. **杀点 /  detach**：`0x10006697c addChildViewController:` 在 Legado 父 VC 层级下不一致（I/D）；J 用 defer 避免同步杀但未 `deferred_attach_OK`。
4. **正文**：`loadCurCp` hook 拦截后 **container 仍为 nil**，`invoke_skip reason=no_container`（R2）。

**第一个确定偏离**（相对原版 TXT）：**步骤 2–3 的 onReset→pageContainer 工厂路径**（非数据层）。  
**路 B 接入缝**：跳过 Bridge 主动 onReset，改在 **缓存就绪 + 原生 container 存在** 后只 invoke `loadCurCp`（见 [`loadcurcp-data-seam.md`](loadcurcp-data-seam.md)）。

---

## 4. 允许集成 / 禁止集成

### 允许（有静态或真机证据）

- Legado 目录/正文 **数据层**（`handleCatalogRequest` / `handleContentRequest`）。
- `loadCurCp` hook：**仅**发起一次 fetch + 填 confirmed 缓存边界 + **一次**原生 `loadCurCp`。
- 假设 **I** 的 onReset IMP 解包（真 native IMP，非新假设）。
- 假设 **J** defer swizzle **临时保留**至路 B 第一章门禁通过后再拆。
- `setDicBook:` / `arrCatalog` seed（scalar/数组，非 UI）。
- Debug forensics dylib（只读 dump）。

### 禁止（硬规则 + 已证伪）

- 生产 `setPageModel:` / `object_setIvar` 写阅读私有 ivar / 手工 `alloc TextReadTV|container`。
- Bridge **外调** `[reader pageContainer]` getter（A2 confirmed 杀）。
- 继续叠 **假设 K/L/M** flush 补丁。
- overlay / probe 冒充上屏（Release）。
- 在 `LegadoBridgeCExports.m` 新增 `LBHypothesis*` 函数。
- 路 A：靠 onReset 工厂 + defer flush 修 attach（**J 已证伪**）。

---

## 5. 大脑门禁建议

| 项 | 状态 |
|---|---|
| 五问 | 均有 **confirmed/probable** 或明确下一条取证（Q1/Q4 运行时相位） |
| `GATE-3-APPROVED` | **建议有条件批准**：静态 + 假设链已闭合「偏离点」；运行时 baseline dump 可并行后补，不阻塞路 B 实现试验 |
| 路 B 实现 | 见 `loadcurcp-data-seam.md`；本回合最小 commit 在 `LBLoadCurCpBridge.m` |

---

## 6. 机器可读索引

见同目录 [`baseline-vs-legado-diff.json`](baseline-vs-legado-diff.json)。

---

## 7. 补充：原版 QF 线程 / main 排空差分（2026-07-20 静态回合）

**来源**：[`baseline-runtime-qf-main-diff.md`](baseline-runtime-qf-main-diff.md)（本回合新增，lldb 21.1.6 反汇编 + 假设链真机回写）

### 7.1 原版 QF 线程判定（静态 confirmed）

原版正常 TXT 阅读时 `callback_inThread == nil`（原版二进制不写该 ivar，`callBackResponse` 仅读）-> `LPNetWork2#callBackResponse` @ `0x10008a1d4` 走 `dispatch_async(main_queue)` 分支（`0x10008a630–6ac`）-> block invoke `0x10008a868` 在 main 上同步调 `lpNetWorkDelegateQueryFinish:config:userInfo:`。**QF 在 main 执行**。

### 7.2 Legado invoke 后 main 阻塞候选点（按可能性排序）

| # | 候选点 | 评估 |
|---|---|---|
| C1 | invoke 触发原生 `pageContainer` 工厂 `addChildViewController:`（`0x10006697c`）在 Legado 父 VC 层级下 UIKit 状态机异常 -> main RunLoop 卡 scene update | **高**（与 §5 首个偏离点一致） |
| C2 | Bridge bg 枚举 `UIWindowScene.windows` 与 main scene update 互锁 | 中（AJ 禁后部分缓解未根除） |
| C3 | main 探针块与原生 QF block 竞争（伴生） | 中 |
| C4 | main KVC seed 触发原生 KVO/通知链 | 低 |
| C5 | container 未 attach 时 invoke 触发原生异常路径 | 低（R2 早期） |
| C6 | 进程级资源耗尽 jetsam 预警 | 低-中 |

### 7.3 对 §1/§3/§5 的回写声明

- **§1 正文加载行**：补充「原版 QF 在 main 执行（静态 confirmed）；Legado QF 跑不到 main（AF/AI/AJ 真机 confirmed `drain=0`）」。
- **§3 Q1 下一条取证**：具体化为「baseline-debug `main_drain_slot` + `qf_enter main=1` + `divisionResponse` phase dump」。
- **§5 GATE-3-APPROVED**：条件维持；本回合静态差分填补 QF 线程判定空白，原版 main 排空仍为 probable（待 baseline 真机 dump），不阻塞路 B。

---

## 8. 补充：loadCurCp 前置条件与 receiver 继承澄清（2026-07-20 复核回合）

**来源**：[`container-attach-and-main-block-analysis.md`](container-attach-and-main-block-analysis.md) §1（指令级控制流）+ `method-map.json` 继承元数据 + 真机 `_diag_ipa_T5_2880c4c` / `_diag_ipa_S_cf54785` 日志交叉；Cline 静态复核，无真机/无 CI。

### 8.1 Q2 必要输入：新增两条 confirmed 前置

| 前置 | 说明 | 置信度 | 证据 |
|---|---|---|---|
| **curPageVC 非 nil** | `loadCurCp` 首指令 `[self curPageVC]`；nil 时后续 `pageModel`/`pageStatus` 全部链式归零 | confirmed（指令级） | container-attach §1.2 `0x1000d7d18` |
| **curPageVC.pageModel.pageStatus == 3** | `cmp x0,#0x3; b.ne 0x1000d7fd4`：≠3 直接 release 返回（**空操作**） | confirmed（指令级） | container-attach §1.2 `0x1000d7d84` |

**后果裁定**：Legado 场景 container 未 attach、无分页页 → `curPageVC=nil` → `pageStatus` 链式为 0 → **invoke orig 静默空操作**。这解释真机 `invoke_orig_OK target=TextRPageContainer` 后无崩溃、无 QF、无萧炎（T5/S 两轮日志一致）。`invoke_orig_OK` 只证明函数指针返回，**不证明 loadCurCp 主体执行**。

### 8.2 receiver 继承澄清（证伪 container-attach §1.1 的 doesNotRecognizeSelector 担忧）

`method-map.json`：`TextRPageContainer.superclass = ReadPageContainer`。子类实例继承 `loadCurCp` IMP，Bridge 以子类实例为 receiver 直接调函数指针**合法**，ivar 偏移前缀兼容；真机 invoke 后无崩溃佐证。container-attach §1.1「落到 doesNotRecognizeSelector」**证伪**；`LBReadPageContainerPriority` 将 `TextRPageContainer` 排在 `ReadPageContainer` 前与原版工厂产物一致（假设 J：`pageContainerA=TextRPageContainer`）。**receiver 路由不是当前杀因，当前杀因指向 §8.1 的空操作分支。**

### 8.3 探针路径偏差警告

AR 探针 `ar_pageStatus_pre/post` 取 `container.pageStatus` / `container.pageModel.pageStatus`（KVC），与原版读取路径 `curPageVC.pageModel.pageStatus` **不同**；历史 `pageStatus=-999` 类读数可能为路径误报（先例：`curCp@r/c=-999` 已证实误报，`LBLoadCurCpBridge.m:2555`）。后续相位 dump 必须按原版路径 `container→curPageVC→pageModel→pageStatus` 取值。

### 8.4 对 §3 Q2 的回写

§3 Q2 表「curPageVC 非 nil 时走当前页；nil 时仍可能 queryCpFile（静态）」**修正**：nil 时 `pageStatus` 链式为 0 ≠ 3，控制流在 `0x1000d7fd4` 直接返回，**不会**走到 `queryCpFileByBook`。置信度 probable → confirmed（指令级控制流唯一分支）。

### 8.5 6A 单轮真机结果（2026-07-20，sha 47887ff）

**报告**：`fixtures/_accept_6a_origpath.json`（单轮，ios-mcp 1.2.2 @192.168.1.18，pid 19704→19708 崩溃重启）

1. **空操作假说证伪（§8.1 修正）**：`ar_origpath_pre curPageVC=TextRPageContainerPage pageStatus=3`（post 同）——invoke 时 §8.1 两条前置均满足，loadCurCp 主体**已执行**（过 `cmp #3` 分支，进入 queryCpFileByBook 路径）。
2. **KVC 路径误报实证（§8.3 兑现）**：同帧 KVC 读数 `container=TextRPageContainer val=nil` vs 原版路径 `pageStatus=3`——历史 `pageStatus=-999/nil` 判读全部作废。
3. **唯一杀点收敛**：invoke 完成（invoke_orig_OK / done_pending_render / state=idle）后，postQF 窗 tid=259 SIGSEGV：`fault=0x16f867ff8 = fp-0x178`（栈 guard page 写穿=栈溢出）；与 7/19 崩溃完全同构（`pc-lr=0x7a80` 恒定 = 同一函数体内递归）；`ao_lbf_hook depth=2495` 持续线性增长 = **Debug Observer tramp 与 Bridge LBAB/LBAE 钩在 CB→QF 链互套**。RecordQuiet（AU）只静默日志、不断调用链，无效。

**修复方向（假设 AV，单假设）**：`LBForensicsObserver.m LBFObserverSelectors()` 移除 `callBackResponse:config:userInfo:` 与 `lpNetWorkDelegateQueryFinish:config:userInfo:` 两行，拆掉 Observer tramp 这一环（EarlyWrap 只管 viewDidLoad/loadCurCp，不涉及 CB/QF，已核）。拆后 CB/QF 链剩 Bridge 单层钩 = Z/AA 时期形态（无栈溢出史，hypothesis-AB §1）。代价：Debug 暂失 qf_enter 记录；6B 前由 Bridge 侧记录或原生绘制信号补。


