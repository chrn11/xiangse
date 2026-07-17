# 路 B：`loadCurCp` 数据接入缝设计

**HEAD**：`57d80b8`  
**前提**：假设 J 证伪「onReset 工厂 + defer flush」；路 A（继续 K/L/M 修 flush）禁止。  
**目标**：恢复原版 `loadCurCp` 生命周期，**只替换正文数据/缓存边界**；container/TV/pageModel 由原版创建。

---

## 1. 可行性结论

| 判定 | **有条件可行（probable → 待真机验证）** |
|---|---|

**理由（支持）**：

1. **静态**：`ReadPageContainer#loadCurCp` callee 含 `queryCpFileByBook`、`arrCatalog`、`curPageVC`，**不含** `TextReadVC3#pageContainer` getter（`chain-msg-hits.json`）。
2. **静态**：正文链 `loadCurCp` → `lpNetWorkDelegateQueryFinish` → `divisionResponse` → `textViewL` lazy（`reader-call-chain.md`）。
3. **真机 R2**：阅读页标题已显示（`第一章 陨落的天才`），说明 **openReader / VC 链可到达**；卡点为 **container nil** 而非数据层。
4. **真机 J**：`pageContainerA=TextRPageContainer` 证明工厂 **可分配** 容器对象；失败在 **attach**，不是数据 seam。

**理由（风险）**：

1. **container 实例**在基线中由 `onReset` → `pageContainer` getter 创建；路 B **不得** Bridge-fire onReset。
2. 须依赖 **原版 appear / 通知链** 在 `arrCatalog` 已 seed 时自然创建 container，或 container 已存在后再 invoke。
3. `loadCurCp` IMP owner 为 `ReadPageContainer`；invoke 前必须有 receiver（`invoke_skip no_container` 为当前硬阻塞）。

---

## 2. 状态机（已有 + 路 B 收紧）

```
idle → fetching → contentReady → invokingOriginal → rendered/failed
```

| 状态 | 路 B 行为 |
|---|---|
| **idle** | 原生 `loadCurCp` 首次进入 hook：识别 Legado → `fetching`，发 `handleContentRequest` |
| **fetching** | 忽略重入 |
| **contentReady** | 正文回调：`LBSeedConfirmedCache` + `LBEnsureLoadCurCpPrereqs`；**等待 container**；不 fire onReset |
| **invokingOriginal** | 主线程 **一次** `sOrigLoadCurCp(container, loadCurCp)` |
| **rendered** | 原生 dump/OCR 证据置位 |
| **failed** | fail-open，不 overlay |

---

## 3. 最小改动点（优先 `LBLoadCurCpBridge.m`）

| # | 改动 | 目的 |
|---|---|---|
| 1 | 记录 hook `self` 为 `sWeakHookReceiver` | 原生若已对 container 调 `loadCurCp`，保留 receiver |
| 2 | `contentReady` 时 **完整** `LBSeedConfirmedCache`（非仅 xsfolder） | 满足 `queryCpFile` 读缓存 |
| 3 | `LBRouteBResolveContainer`：ivar `_pageContainerA` + hook receiver + 原 find | 对齐 J 证据 `TextRPageContainer` |
| 4 | **轮询等待** container（attached UI 后，≤30 tick）再 invoke | 修复 R2 `no_container` |
| 5 | `contentReady` 后 **passthrough** 后续原生 `loadCurCp`（撤 T5 硬挡） | 让原版二次调用参与 |
| 6 | **不新增** CExports `LBHypothesis*` | 遵守膨胀禁令 |

**后续（非本回合）**：

- CExports：停 Bridge 主动 `LBHypothesisEFireOnResetNoArg`（`nativeFull` 下改由通知链自然触发）。
- J swizzle：第一章门禁通过后拆除 `addChild`/`insertSubview` defer。

---

## 4. 与 J 证据对照

| J 观测 | 路 B 用法 |
|---|---|
| `pageContainerA=TextRPageContainer` | 作为 **invoke target 解析** 的确认类名，不依赖 flush |
| `children=0` | 说明仅 ivar 有对象不够；路 B 仍须 attach 或原生链补齐 |
| `deferred_attach_OK` 空 | 证明路 A 不可继续；路 B 不依赖 deferred flush |

---

## 5. 验收信号（第一章最小验证）

1. `legado_loadcurcp_state.txt` 出现 `routeB_invoke` + `invoke_orig_OK`。
2. 无 `invoke_skip reason=no_container`（或仅出现在首次 tick）。
3. 阅读页前台；OCR 正文区「萧炎」（后续门禁）。
4. dump：`pageContainerA` 非 nil；`nativePaged=1`（后续门禁）。

---

## 6. 下一步唯一动作

**同 SHA Debug IPA 真机一轮**：MCP `nativeRead` → 检查 `legado_loadcurcp_state.txt` 是否出现 `routeB_container_hit` / `invoke_orig_OK`；若仍 `no_container`，补 **runtime dump** 记录自然 onReset 是否触发及 `pageContainerA` 写入时刻（不回到路 A）。
