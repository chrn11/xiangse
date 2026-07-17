# pageContainer 原生创建链（假设 A 静态取证）

**基线**：StandarReader 2.56.1，`executable_sha256=04f780eb59f86c9104f8c8c3c04fb24278f521d0a43e401b3773d2a47890dea7`  
**工具**：`tools/reader-forensics/build_chain_msgs.py` + ObjC `__objc_classlist` 解析  
**日期**：2026-07-17

---

## 结论（置信度）

| 项 | 结论 | 置信度 |
|---|---|---|
| **谁创建 TextRPageContainer** | `TextReadVC1#pageContainer` getter（IMP `0x10006684c`）懒创建 | **confirmed** |
| **持有 ivar** | `TextReadVC1.pageContainerA` → `@"TextRPageContainer"` | **confirmed** |
| **viewWillAppear 是否创建 container** | `ReadVCBase2#viewWillAppear`（`0x1000e568c`）仅 `super` + idle timer，**无** pageContainer | **confirmed** |
| **viewDidLoad 是否创建 container** | `TextReadVC3#viewDidLoad` / `ReadVCBase2#viewDidLoad` 均**无** pageContainer 调用 | **confirmed** |
| **appear noop 挡住哪一步** | 挡住 willAppear/didAppear 全量 ORIG（防 0.35s 回书架），**不是** container alloc 的唯一入口 | **probable** |
| **另一入口** | `TextReadVC3#onResetContentNotify`（`0x10000b578`）两次 msgSend `pageContainer`；Bridge 在 mode=1 **旁路** no-arg ORIG | **confirmed** |

---

## TextReadVC1#pageContainer getter（创建链）

IMP `0x10006684c`，静态 msgSend 窗口：

```
arrCatalog → count
standardUserDefaults → integerForKey:   // 阅读模式（分页/滚动）
init → setReader: → addChildViewController:
create:options: → insertSubview:atIndex:
（滚动模式分支会 removeFromParent/removeFromSuperview 后切换）
```

**判定**：container 由 reader 已有 **property getter** 创建，非 Bridge 手工 alloc。

---

## 生命周期扫描（谁调用 pageContainer）

| 方法 | 类 | IMP | 调 pageContainer |
|---|---|---|:---:|
| pageContainer | TextReadVC1 | 0x10006684c | （自身工厂） |
| pageContainer | ReadVCBase2 | 0x1000e7c34 | ✓（转发到子类 getter） |
| onResetContentNotify | TextReadVC3 | 0x10000b578 | ✓ |
| onReloadContentEvent | TextReadVC3 | 0x10000aa4c | ✓ |
| viewWillTransitionToSize:… | TextReadVC1 | 0x100066b98 | ✓ |
| resetToolBarValues | ReadVCBase2 | 0x1000e6bb0 | ✓ |
| **viewWillAppear:** | ReadVCBase2 | 0x1000e568c | **✗** |
| **viewDidLoad** | TextReadVC3 / ReadVCBase2 | — | **✗** |

---

## 与 Legado 路径矛盾的对齐

1. **真机**：`viewDidLoad ORIG_OK` 后 `pageContainerA=nil`（ivar dump），`invoke_skip reason=no_container`。
2. **根因**：从未触发 `pageContainer` getter；appear noop **不是**直接原因（willAppear 本就不建 container）。
3. **历史成功 trace**（`fixtures/_parent_verify/trace_c0b8399.txt`）：`willAppear ORIG_OK` + `onReset noArg ORIG_OK` 后出现 `foundTV=TextReadTV`；当前 Bridge 旁路 no-arg onReset，getter 未被调用。
4. **本回合假设 A**：在 `invoke` 前 **一次** `objc_msgSend(reader, @selector(pageContainer))`，打日志证明 `TextRPageContainer` 由原生 getter 创建。

---

## 禁止项核对

- ✗ 手工 `[TextRPageContainer alloc]`
- ✗ `object_setIvar` 写 pageContainerA
- ✗ `setPageModel` / 拼 PVC / idlePageVC
- ✓ 仅调用 confirmed selector `pageContainer`

---

## 下一刀输入（若假设 A 失败）

- 若 getter EX / 回 SpringBoard：检查 `arrCatalog.count` 与 `nativeFull prep cat=2` 是否在 getter 前就绪。
- 若 container 有但 `invoke=false`（无 curPageVC/attached）：再评估 **软种 pageStatus / dicContents**（须在原生 container 存在之后）。
