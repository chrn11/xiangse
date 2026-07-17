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

## 假设 A 真机结果（9d4161d，已 revert）

- `defer_tick_enter attempt=0` 后 ivar_dump 显示 `pageContainerA=nil`
- **未出现** `hypothesis_A pageContainer_lazy` 日志
- 前台回 **SpringBoard**（`has_invoke=false`）
- **判定**：`objc_msgSend(reader, @selector(pageContainer))` 在 Legado 路径上**杀进程**（与历史 `valueForKey:@"container"` 禁令一致量级）

---

## TextReadVC1#pageContainer getter（创建链）

IMP `0x10006684c`，静态 msgSend 窗口：

```
arrCatalog → count
standardUserDefaults → integerForKey:
init → setReader: → addChildViewController:
create:options: → insertSubview:atIndex:
```

---

## 生命周期扫描（谁调用 pageContainer）

| 方法 | 类 | IMP | 调 pageContainer |
|---|---|---|:---:|
| pageContainer | TextReadVC1 | 0x10006684c | （自身工厂） |
| onResetContentNotify | TextReadVC3 | 0x10000b578 | ✓ |
| viewWillAppear: | ReadVCBase2 | 0x1000e568c | **✗** |
| viewDidLoad | TextReadVC3 | 0x100009488 | **✗** |

---

## 给下一刀的唯一输入

1. **禁止**在 arrCatalog/视图未就绪时裸调 `pageContainer` getter（9d4161d 已证实杀进程）。
2. 基线创建链依赖 `arrCatalog.count` + `init`；Legado `nativeFull prep cat=2` 后仍需确认 getter 前置是否满足。
3. 可评估：`onResetContentNotify` **分段**恢复（仅到 pageContainer 调用前）或等 attached+arrCatalog 就绪后再调 getter——**不得**叠 soft pageStatus/dicContents 为本回合第一刀。
