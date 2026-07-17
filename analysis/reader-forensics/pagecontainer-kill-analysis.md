# pageContainer getter 杀进程静态取证（完整反汇编）

**基线**：StandarReader 2.56.1  
**可执行文件 SHA256**：`04f780eb59f86c9104f8c8c3c04fb24278f521d0a43e401b3773d2a47890dea7`  
**输入 SHA（Bridge 树）**：`6241bc6`（A2 revert 后）  
**取证日期**：2026-07-17  
**反汇编脚本**：`fixtures/_tmp_disasm_pagecontainer/disasm_pagecontainer.py`  
**机器可读产物**：`analysis/reader-forensics/_tmp_pagecontainer_full.json`

---

## 1. 目标符号

| 项 | 值 |
|---|---|
| 类 | `TextReadVC1` |
| Selector | `pageContainer` |
| IMP | `0x10006684c` |
| 返回 | `0x100066b94`（`ret`） |
| 指令数 | 211（含 prologue/epilogue） |

**关联入口**：`TextReadVC3#onResetContentNotify` IMP `0x10000b578` → ret `0x10000b9ac`（内部 **两次** `pageContainer` @ `div0x10000b590` / `0x10000b598`，以及后半 @ `0x10000b8a4` / `0x10000b8ac`）

---

## 2. 控制流总览

```
0x10006684c  prologue; x19=self
0x10006686c  ldr pageContainerA (ivar offset 0x520)
0x100066870  cbnz → 0x100066884  [已有 A：早退返回]
0x10006687c  ldr pageContainerB (ivar offset 0x524)
0x100066880  cbz  → 0x10006689c  [B 为 nil：进入工厂]
             fallthrough → 0x100066884  [B 非 nil：早退返回]

── 工厂 0x10006689c ──
0x1000668a8  [self arrCatalog]
0x1000668c0  [arrCatalog count] → x21
0x1000668d0  cbz x21 → 0x1000669b4  [count==0：返回 nil]
0x1000668e4  [NSUserDefaults standardUserDefaults]
0x100066904  integerForKey:@"tr_turnPageType"  (CFString @ 0x100261510)
0x100066920  ldrb byte @ [self + 0xbd8]
0x100066924  cmp x20, #3
0x100066928  ccmp w8, #0, #0, ne
0x10006692c  b.eq → 0x1000669bc   [turnPageType==3 且 byte@bd8==0：翻页 UIPageVC 支路]
0x100066930  … TextRScrollContainer 支路 …
0x1000669b0  b → 0x100066a48          [滚动支路汇合]
0x1000669bc  … TextRPageContainer create:options: 支路 …
0x100066a48  … insertSubview:atIndex:0 …
0x100066a7c  cbnz pageContainerA → 0x100066884
0x100066a84  b → 0x100066884            [返回新建或已有 ivar]
0x100066a88  … 旧 container 拆除（setReader:nil / removeFromParent / removeFromSuperview）…
0x100066b10  … 另一旧 container 拆除 …
0x100066b80  epilogue; ret
```

**早退块 `0x100066884`**：`objc_retainAutoreleaseReturnValue` 形态（`bl 0x1002013c0` + `b 0x100201318`），非业务 msgSend。

---

## 3. 逐步 msgSend / 分支（工厂路径）

| # | 地址 | 接收者 | Selector | 备注 |
|---:|---|---|---|---|
| 1 | `0x1000668a8` | self | `arrCatalog` | 工厂前置 |
| 2 | `0x1000668c0` | arrCatalog | `count` | → x21 |
| — | `0x1000668d0` | **cbz** | count==0 → `0x1000669b4` 返回 **nil** | 不杀进程 |
| 3 | `0x1000668e4` | `NSUserDefaults` | `standardUserDefaults` | classref `0x1002e3670` |
| 4 | `0x100066904` | defaults | `integerForKey:` | **key=`tr_turnPageType`** |
| 5a | `0x100066944` | `TextRScrollContainer` | `init` | turnPageType≠3 或 byte@bd8≠0 |
| 5b | `0x1000669d4` | `TextRPageContainer` | `create:options:` | turnPageType==3 且 byte@bd8==0；x2=type, x3=0 |
| 6 | `0x100066968` / `0x100066a00` | 新 container | `setReader:` | x2=self |
| 7 | `0x10006697c` / `0x100066a14` | self | `addChildViewController:` | x2=container |
| 8 | `0x100066990`~`0x100066a48` | container / self | `view` | 多次 retain 链 |
| 9 | `0x100066a64` | self.view | `insertSubview:atIndex:` | x2=child.view, x3=0 |
| 10+ | `0x100066acc`~`0x100066b5c` | 旧 A/B | `setReader:` / `removeFromParentViewController` / `view` / `removeFromSuperview` | 仅当替换已有 ivar |

**分支指令（完整）**

| 地址 | 指令 | 目标 | 语义 |
|---|---|---|---|
| `0x100066870` | cbnz | `0x100066884` | pageContainerA 已存在 |
| `0x100066880` | cbz | `0x10006689c` | pageContainerB 为 nil 才创建 |
| `0x1000668d0` | cbz | `0x1000669b4` | **arrCatalog.count==0** |
| `0x10006692c` | b.eq | `0x1000669bc` | **UIPageVC 翻页支路** |
| `0x1000669b0` | b | `0x100066a48` | 滚动支路跳到 insertSubview |
| `0x1000669b8` | b | `0x100066888` | count==0 清理后返回 nil |
| `0x100066a7c` | cbnz | `0x100066884` | 创建后 A 非 nil 即返回 |
| `0x100066ac0` | cbz | `0x100066b10` | 旧 A 拆除跳过 |
| `0x100066b1c` | cbz | `0x100066b80` | 旧 B 拆除跳过 |

---

## 4. 杀进程点排名

| 排名 | 地址 / 调用 | 机制 | 置信度 | 与 A2 真机关系 |
|---:|---|---|---|---|
| **1** | `addChildViewController:` @ `0x10006697c` / `0x100066a14` | UIKit `NSInternalInconsistencyException`（子 VC 无 window、父未 appear、重复 add）— **@catch 捕不到** | **confirmed** | 与「回 SpringBoard、无日志」一致 |
| **2** | `insertSubview:atIndex:` @ `0x100066a64` | `self.view` 未就绪 / 零尺寸 / 非层级内插入 | **probable** | 紧随 `view` 链之后 |
| **3** | `[TextRPageContainer create:options:]` @ `0x1000669d4` | `UIPageViewController` 工厂 + options；Legado 缺省 `tr_turnPageType==3` 时走此支 | **probable** | 需对照 defaults |
| **4** | `view` @ `0x100066990`~`0x100066a40` | 懒加载 `loadView`/`viewDidLoad` 链上原生断言 | **probable** | cat=2 attached=1 仍可能未走完 |
| **5** | `arrCatalog.count==0` @ `0x1000668d0` | 返回 nil，**不抛异常** | **rejected** 作杀因 | 若 count=0 应非 SpringBoard |
| **6** | `setReader:` / `removeFromParent` | 仅替换路径；nil reader 通常安全 | **unlikely** | — |
| **7** | force unwrap / Swift trap | 本 IMP **无** Swift 显式 trap；全 ObjC msgSend | **rejected** | — |

**真机已证实（A2）**：Bridge 外调 `objc_msgSend(reader,@selector(pageContainer))` → SpringBoard，`@catch` 无效 → 与排名 1–4 的 **non-ObjC exception** 或 **abort** 一致，而非单纯返回 nil。

---

## 5. 与基线 TXT 路径差异（getter 内）

| 字段 | 基线原生 | getter 内证据 | Legado 缺口候选 |
|---|---|---|---|
| **arrCatalog** | 打开书后非空 NSArray | `0x1000668a8`/`count`；count==0 不创建 | **confirmed** 必须 count≥1 |
| **dicBook** | 书元数据 | **本 IMP 不读 dicBook** | 非直接杀因；经 `setReader:` 间接 |
| **readMode** | 用户翻页偏好 | **不读 ivar**；读 `NSUserDefaults integerForKey:@"tr_turnPageType"` @ `0x100066904` | **probable** Legado 未 seed 或值为 3 |
| **contentPageClass** | 滚动/分页类名 | **未出现**；硬编码 `TextRScrollContainer` vs `TextRPageContainer create:` | **confirmed** 不走 KVC contentPageClass |
| **byte@0xbd8** | 未知布尔 | `ldrb` + `ccmp` 与 type==3 联动 | **probable** 未初始化致误入 UIPage 支路 |
| **pageContainerA/B** | 懒 nil | ivar offset `0x520`/`0x524` | A2：仍为 nil 直至 getter 进入工厂 |

**支路选择逻辑（静态）**

```
if (tr_turnPageType == 3 && self.byteAt0xbd8 == 0)
    TextRPageContainer + UIPageViewController create:options:
else
    [[TextRScrollContainer alloc] init]
```

---

## 6. onResetContentNotify 与 pageContainer 关系

| 地址 | Selector | 说明 |
|---:|---|---|
| `0x10000b590` | `pageContainer` | **方法入口后首个业务调用** |
| `0x10000b598` | `pageContainer` | retain 链 |
| `0x10000b5a8` | `clearPageData` | 依赖已有 container |
| `0x10000b8a4` | `pageContainer` | 后半再次取 container |
| `0x10000b8bc` | `clearPageData` | — |

Bridge 现状（`6241bc6`）：`sLegadoReaderMode==1` 时 **旁路** no-arg `onResetContentNotify` ORIG → 原生 `pageContainer` 工厂 **不会被该通知触发**。

---

## 7. 下一刀唯一生产代码假设（非「再调 pageContainer」）

**陈述（一句话）**：在 `nativeFull` 已 attached 且 `arrCatalog.count≥1` 前提下，**恢复 `onResetContentNotify` 全量 ORIG（取消 mode=1 旁路）并仅用 ivar/`NSUserDefaults` 预置 `tr_turnPageType≠3`（强制走 `TextRScrollContainer init` 支路，地址 `0x100066930`）**，使 `pageContainer` 仅由 `onReset` 内部 `0x10000b590` 调用、而非 Bridge `defer_tick` 外调 getter。

**分段说明（若需降级）**：仅在 ORIG 恢复仍崩时，再考虑 imp 级 hook 在 `0x10000b58c` 前 return（跳过 `0x10000b590` 两次 `pageContainer`），**本刀不作为第一选择**——因 onReset 主体依赖 container 做 `clearPageData`。

**风险**：`addChildViewController:`（排名 1）仍可能在 onReset 内触发；需 forensics 日志对齐 `tr_turnPageType`、`arrCatalog.count`、`window` 与 `viewLoaded` 后再迭代。

---

## 8. 应拒绝的谎言

| 谎言 | 证据 |
|---|---|
| 「viewWillAppear / viewDidLoad 会创建 pageContainer」 | 生命周期扫描无 xref（见 `pagecontainer-lifecycle-analysis.md`） |
| 「Legado 只需 KVC `contentPageClass`」 | getter 硬编码两类，无 `contentPageClass` selref |
| 「arrCatalog 空时 getter 会崩」 | `0x1000668d0` 明确返回 nil |
| 「@catch 可兜住 pageContainer 崩溃」 | A2 真机：SpringBoard，`@catch` 无效 → UIKit/abort 级 |
| 「再调一次 pageContainer getter 即可」 | A2 已 **confirmed** 杀进程；本报告禁止 |
| 「Bridge 旁路 onReset 不影响 container」 | 旁路切断 `0x10000b590` 原生工厂入口 |
| 「readMode ivar 决定容器类型」 | 实际为 **`tr_turnPageType` defaults** |

---

## 9. 交接模板

```
输入 SHA: 6241bc6
产物路径: analysis/reader-forensics/pagecontainer-kill-analysis.md
         analysis/reader-forensics/_tmp_pagecontainer_full.json
         fixtures/_tmp_disasm_pagecontainer/disasm_pagecontainer.py
杀因排名: ① addChildViewController: ② insertSubview:atIndex: ③ UIPageVC create:options: ④ view 懒加载链
下一刀唯一假设: nativeFull 就绪后恢复 onResetContentNotify 全量 ORIG + 预置 tr_turnPageType≠3 走滚动支路，禁止 Bridge 外调 pageContainer getter
```
