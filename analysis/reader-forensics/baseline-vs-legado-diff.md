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
