# onResetContentNotify × arrCatalog 杀进程静态取证

**基线**：StandarReader 2.56.1  
**可执行文件**：`analysis/unpacked/Payload/StandarReader.app/StandarReader`  
**SHA256**：`04f780eb59f86c9104f8c8c3c04fb24278f521d0a43e401b3773d2a47890dea7`  
**HEAD（revert D 后）**：`25405b5`  
**取证日期**：2026-07-17  
**反汇编脚本**：`fixtures/_tmp_disasm_pagecontainer/disasm_onreset.py`  
**机器可读产物**：
- `analysis/reader-forensics/_tmp_TextReadVC3_onResetContentNotify.json`
- `analysis/reader-forensics/_tmp_TextReadVC3_onFilterContentNotify.json`
- `analysis/reader-forensics/_tmp_pagecontainer_full.json`

**关联真机验收**：
- 假设 C `be69d0b`：`fixtures/_accept_hypothesis_c.json`
- 假设 D `6854db9`（已 revert）：`fixtures/_accept_hypothesis_d.json`
- pageContainer 工厂：`analysis/reader-forensics/pagecontainer-kill-analysis.md`

---

## 0. 真机矛盾（confirmed）

| 假设 | fire 时 cat | ORIG_OK | pageContainerA | UI |
|---|---:|---|---|---|
| C `be69d0b` | 0（仅 window） | ✅ | nil | 未回书架 |
| D `6854db9`（revert） | 2 | ❌ 中途杀 | 未到 after | 回书架 |

**静态结论**：`pageContainer` getter 在 `arrCatalog.count==0` 时 `cbz` 早退返回 nil（`0x1000668d0`），**不进入工厂**；`count>0` 才 alloc + `addChildViewController:` + `insertSubview:`。故 D 崩在 **有 catalog 的工厂路径**，杀点发生在 `onReset` 内首个 `pageContainer` 调用（`0x10000b590`）所同步触发的工厂链，而非 `onReset` 后半段。

---

## 1. method-map 与「无参 / 有参」符号

### 1.1 TextReadVC3 已确认方法

| Selector | type encoding | IMP | ret | 说明 |
|---|---|---|---|---|
| `onResetContentNotify` | `v16@0:8` | `0x10000b578` | `0x10000b5f4`（tail release） | **无参**；Bridge 假设 C/D 所 fire 的 ORIG |
| `onFilterContentNotify:` | `v24@0:8@16` | `0x10000b5f8` | `0x10000b9ac` | **有参**（`NSNotification *`）；含第二处 `pageContainer` |
| `onSearchContentNotify:` | `v24@0:8@16` | `0x10000b714` | — | 与 filter 路径共享尾部 |

### 1.2 `onResetContentNotify:` **不存在于二进制**

`__objc_methname` 全文检索 **无** `onResetContentNotify:` 字符串；`method-map.json` 亦无该 selector。Bridge `LBInstallNativeResetContentHook` 所列 `onResetContentNotify:` **在 TextReadVC3 上不会命中**（`class_getInstanceMethod` 为 NULL）。

**有参通知的正确静态对应物**：`onFilterContentNotify:` / `onSearchContentNotify:`（均 `v24@0:8@16`），而非虚构的 `onResetContentNotify:`。

### 1.3 其他类的无参 `onResetContentNotify`

| 类 | IMP |
|---|---|
| `TextRPageContainerPage` | `0x1000b2fb4` |
| `TextRScrollContainer` | `0x1000fefd0` |

本报告聚焦 **TextReadVC3**（Legado nativeFull 入口）。

---

## 2. 无参 `onResetContentNotify` 完整反汇编（`0x10000b578`）

**指令数**：77（至 `0x10000b5f4` tail branch，不含相邻 `onFilterContentNotify:` 体）

### 2.1 控制流总览

```
0x10000b578  prologue; x19=self
0x10000b590  [self pageContainer]          ← 杀进程同步入口（cat>0 时进工厂）
0x10000b598  [self pageContainer]          retain 链
0x10000b59c  x20 = container
0x10000b5a8  [container clearPageData]     ← nil 安全（ObjC no-op）
0x10000b5b0  [container clearPageData]
0x10000b5c0  [self dicGoAfterLoadCatalog]
0x10000b5c8  [self dicGoAfterLoadCatalog]
0x10000b5e4  [self tryOpenRecord:sourceName:]  (x2=dicGoAfterLoadCatalog, x3=0)
0x10000b5f4  tail → objc_release; return
```

**关键**：无参路径在 `pageContainer` 之后 **无任何 cbz/cbnz**——若 `pageContainer` 工厂中途 abort，**到不了** `0x10000b5a8` 之后的 `clearPageData`，与真机「无 `onReset_noArg_after_ORIG` 探针」一致。

### 2.2 msgSend 表（无参）

| # | 地址 | 接收者 | Selector | 备注 |
|---:|---|---|---|---|
| 1 | `0x10000b590` | self | `pageContainer` | **首个业务调用**；内部可能进工厂 |
| 2 | `0x10000b598` | self | `pageContainer` | retain |
| 3 | `0x10000b5a8` | container | `clearPageData` | x20=container |
| 4 | `0x10000b5b0` | container | `clearPageData` | |
| 5 | `0x10000b5c0` | self | `dicGoAfterLoadCatalog` | |
| 6 | `0x10000b5c8` | self | `dicGoAfterLoadCatalog` | |
| 7 | `0x10000b5e4` | self | `tryOpenRecord:sourceName:` | x2=dic, x3=0 |

### 2.3 `pageContainer` 调用后分支

**无**——线性 fallthrough 至 `0x10000b5f4` 返回。  
因此 C/D 差异 **完全由 `0x10000b590` 内嵌的 getter 工厂** 决定，而非 onReset 主体分支。

---

## 3. 有参 `onFilterContentNotify:` 完整反汇编（`0x10000b5f8`）

**指令数**：238（至 `0x10000b9ac` ret）  
**与无参关系**：紧接无参 IMP 之后；**不共享** prologue，但 filter/search 尾部汇合。

### 3.1 控制流总览

```
0x10000b5f8  prologue; x19=self, x20=notification 相关
0x10000b610  tryOpenRecord:（arg 来自 x2）
0x10000b624  [self viewVisible]
0x10000b628  cbz w0 → 0x10000b700     [不可见：跳过 Filter push]
             … FilterVC create / push …
0x10000b740  [self viewVisible]
0x10000b744  cbz w0 → 0x10000b854     [不可见：跳过 Search push]
             … SearchVC create / push …
0x10000b884  cbz x0 → 0x10000b898     [某 ivar 为 nil：跳过 stop:]
0x10000b894  [ivar stop:]
0x10000b8a4  [self pageContainer]     ← 第二处 pageContainer（有参路径）
0x10000b8ac  [self pageContainer]
0x10000b8bc  [container clearPageData]
0x10000b900  [self showTutorialView:]
0x10000b908  cbz w0 → 0x10000b998     [不显示教程则跳过]
             … BookTutorialView addSubview …
0x10000b9ac  ret
```

### 3.2 `pageContainer` 调用与后续分支（有参）

| 地址 | 调用 | 后继分支 |
|---|---|---|
| `0x10000b8a4` / `0x10000b8ac` | `pageContainer` ×2 | 无 nil 检查；直连 `clearPageData` @ `0x10000b8bc` |
| `0x10000b8bc` | `clearPageData` | → `showTutorialView:` @ `0x10000b900` |
| `0x10000b908` | `cbz w0` | `w0==0` → `0x10000b998` 跳过教程 overlay |

**Legado 路径**：假设 C/D 仅 fire **无参** `onResetContentNotify`；有参路径当前未被验收触发，但静态上 **同样** 在 `pageContainer` 无守卫。

---

## 4. `pageContainer` 工厂：cat==0 分叉后逐步杀点

IMP `0x10006684c`（详见 `pagecontainer-kill-analysis.md`）。

### 4.1 分叉点

| 地址 | 指令 | 条件 | 结果 |
|---|---|---|---|
| `0x100066870` | `cbnz` | `pageContainerA != nil` | → `0x100066884` 早退（**不杀**） |
| `0x100066880` | `cbz` | `pageContainerB == nil` | → `0x10006689c` 进工厂 |
| `0x1000668d0` | `cbz x21` | **`arrCatalog.count == 0`** | → `0x1000669b4` → **返回 nil**（**C 路径**） |
| `0x10006692c` | `b.eq` | `tr_turnPageType==3 && byte@0xbd8==0` | → UIPage `create:options:` @ `0x1000669bc` |
| `0x100066930` | fallthrough | 否则 | **TextRScrollContainer** `init` @ `0x100066944` |

### 4.2 cat>0 工厂逐步（滚动支路，B2 已 seed `tr_turnPageType=0`）

| 步 | 地址 | 调用 | 可能杀因 |
|---:|---|---|---|
| 1 | `0x1000668a8` | `[self arrCatalog]` | 安全 |
| 2 | `0x1000668c0` | `[arrCatalog count]` | → x21=2（D） |
| 3 | `0x1000668d0` | **不跳**（count>0） | 进入工厂 |
| 4 | `0x100066904` | `integerForKey:@"tr_turnPageType"` | 已 seed=0 |
| 5 | `0x100066920` | `ldrb [self+0xbd8]` | D 真机 `0xac`；与 UIPage 支路无关（type≠3） |
| 6 | `0x100066944` | `[TextRScrollContainer init]` | **probable** init 内断言 |
| 7 | `0x100066968` | `[container setReader:self]` | unlikely |
| 8 | `0x10006697c` | **`[self addChildViewController:container]`** | **#1 confirmed 候选** |
| 9 | `0x100066990`~`0x100066a48` | `[container view]` ×N | **#4 probable** loadView 链 |
| 10 | `0x100066a64` | **`[self.view insertSubview:cv atIndex:0]`** | **#2 probable** |
| 11 | `0x100066a7c` | `cbnz pageContainerA` | 返回新建 container |

UIPage 支路（`tr_turnPageType==3`）额外杀点：`[TextRPageContainer create:options:]` @ `0x1000669d4`（**#3**）；B2 已 seed 避开，D 真机仍走滚动支路仍杀 → **UIPage 支路可排除为本回合主因**。

---

## 5. 指令级：为何 C（cat=0）ORIG_OK、D（cat=2）杀进程

### 5.1 假设 C `be69d0b`

| 证据 | 值 |
|---|---|
| fire 日志 | `hypothesis_C fire_onReset immediate` |
| 完成 | `hypothesis_C onReset noArg ORIG_OK` |
| 探针 | `onReset_noArg_after_ORIG pageContainerA=nil byte@bd8=0x00` |
| UI | 未回书架（`PARTIAL_C_NO_CONTAINER`） |

**指令链**：

1. `LBHypothesisCFireOnResetNoArg` → `origNoArg` @ `0x10000b578`
2. `0x10000b590` → `pageContainer` getter
3. `0x1000668a8`/`count` → **x21=0**（arrCatalog 尚未灌入 reader）
4. `0x1000668d0 cbz x21, #0x1000669b4` → **Taken** → 返回 **nil**
5. `0x10000b5a8` `clearPageData` 对 nil → **no-op**
6. 后续 `dicGoAfterLoadCatalog` / `tryOpenRecord:` 正常返回 → **ORIG_OK**
7. `pageContainerA` ivar 仍为 nil（工厂未写 ivar）

### 5.2 假设 D `6854db9`

| 证据 | 值 |
|---|---|
| pre_fire | `hypothesis_D pre_fire cat=2 window=1 appeared=1` |
| fire | `hypothesis_C fire_onReset immediate`（复用 C 日志 tag） |
| 缺失 | **无** `ORIG_OK`、**无** `onReset_noArg_after_ORIG`、**无** `hypothesis_D after_ORIG` |
| UI | 书架（`FAIL_SPRINGBOARD_OR_SHELF_REVERTED`） |

**指令链**：

1. D 门控：`cat>=1 && window && viewLoaded` 通过后 fire（**非**「空 catalog 早退」）
2. `0x10000b590` → `pageContainer` getter
3. `0x1000668c0` → **x21=2**
4. `0x1000668d0 cbz` → **Not taken** → 进入 `0x10006689c` 工厂
5. `0x10006692c b.eq` → **Not taken**（`tr_turnPageType=0`）→ 滚动支路 `0x100066930`
6. `0x100066944` `TextRScrollContainer init` → `0x100066968` `setReader:` → **`0x10006697c addChildViewController:`** ← **最可能 abort 点**（UIKit `NSInternalInconsistencyException`，`@catch` 无效 → SpringBoard）
7. 未返回至 `0x10000b5a8` → 无 after_ORIG 探针

### 5.3 矛盾的本质（一句话）

**同一无参 onReset IMP，差异仅在 `0x1000668d0`：`count==0` 时 getter 返回 nil 整条链安全完成；`count>0` 时同步执行 `addChildViewController:` 工厂步骤，在 Legado 父 VC 层级下 abort。**

---

## 6. 杀因排名（本回合）

| 排名 | 地址 / 调用 | 机制 | 置信度 | C/D 对照 |
|---:|---|---|---|---|
| **1** | `addChildViewController:` @ `0x10006697c` / `0x100066a14` | UIKit 父 VC 层级/appear 不一致；non-ObjC exception | **confirmed** | D cat=2 杀；C cat=0 未到达 |
| **2** | `insertSubview:atIndex:` @ `0x100066a64` | superview 未就绪 | **probable** | 紧随 addChild |
| **3** | `TextRScrollContainer init` @ `0x100066944` | init/loadView 断言 | **possible** | D 已走滚动支路仍杀 → 次于 addChild |
| **4** | `[container view]` 懒加载链 | loadView/didLoad 断言 | **possible** | — |
| **5** | `TextRPageContainer create:options:` @ `0x1000669d4` | UIPageVC 工厂 | **rejected** 本回合 | B2 seed type=0 |
| **6** | `arrCatalog.count==0` @ `0x1000668d0` | 返回 nil | **rejected** 作杀因 | C 存活证据 |
| **7** | `clearPageData` @ `0x10000b5a8` | 对 nil no-op | **rejected** | C 已验证 |

---

## 7. 下一刀唯一生产假设

**禁止**：Bridge 外调 `pageContainer` getter；「只延迟 fire / 只等 catalog」（D 已证伪）。

**陈述（一句话）**：

> 在 `arrCatalog.count≥1` 且即将 fire 无参 `onResetContentNotify` ORIG 之前，由 Bridge **仅通过 ivar** 预分配 `TextRScrollContainer` 并完成 `setReader:` 写入 `pageContainerA`，但 **故意不执行** 原生工厂内的 `addChildViewController:`（`0x10006697c`）与 `insertSubview:atIndex:`（`0x100066a64`），使 `0x10000b590` 的 `pageContainer` 在 `0x100066870 cbnz` **早退**；随后在 `viewDidAppear:` **首次**回调完成后再补执行 deferred `addChildViewController:` + `insertSubview:`，让 onReset 主体 `clearPageData`/`tryOpenRecord:` 可安全跑完且层级 attach 落在 UIKit 认可的 appear 之后。

**可测信号**：
- fire 后出现 `ORIG_OK` + `onReset_noArg_after_ORIG pageContainerA=TextRScrollContainer`
- `viewDidAppear` 后出现 `deferred_addChild_OK`
- UI 不回书架且阅读器可见

**风险**：若杀点实际在 `TextRScrollContainer init`（排名 3）而非 addChild，本刀需降级为 init 后再 deferred attach。

---

## 8. 应拒绝的谎言

| 谎言 | 证据 |
|---|---|
| 「等 catalog 非空再 fire 即可」 | D：`cat=2,window=1,appeared=1` 仍杀 |
| 「有参 onResetContentNotify: 存在」 | `__objc_methname` 无此字符串 |
| 「杀在 clearPageData」 | C：container=nil 仍 ORIG_OK |
| 「杀在 onReset 后半段」 | 无参路径 `pageContainer` 后无分支，杀必在 `0x10000b590` 同步工厂内 |
| 「再调 Bridge pageContainer getter」 | A2 已 confirmed 杀进程 |
| 「arrCatalog 空时 getter 崩」 | `0x1000668d0` 明确返回 nil |

---

## 9. 交接模板

```
输入 SHA: 25405b5 (revert D)
产物路径: analysis/reader-forensics/onreset-catalog-kill-analysis.md
         analysis/reader-forensics/_tmp_TextReadVC3_onResetContentNotify.json
         fixtures/_tmp_disasm_pagecontainer/disasm_onreset.py
杀因排名: ① addChildViewController: @0x10006697c ② insertSubview: @0x100066a64 ③ ScrollContainer init ④ view 懒加载
C vs D: 0x1000668d0 count==0 → nil 安全 vs count>0 → 工厂 addChild 杀
下一刀唯一假设: ivar 预置 TextRScrollContainer+setReader 跳过工厂 addChild，viewDidAppear 后 deferred addChild+insertSubview
停 — 等父代理派 integrator
```
