# scroll-S3：attach 先于 loadCp

## 现象（S2 IPA `2b1aad6`）

- `scroll_S2 invoke_loadCp` + `invoke_orig_OK` 出现
- `hypothesis_J defer_addChild` / `defer_insertSubview` 出现
- **无** `deferred_attach_OK`
- dump 时 `TextRScrollContainer count=0`；截图回空书架
- 无 `divisionResponse` / QF finish

## 根因（confirmed）

`LBHypothesisEFireOnResetNoArg` 旧序：

1. `onReset` ORIG（J defer：只入队 addChild，不真正挂载）
2. `LBHypothesisFProbeAfterOrig` → `LBLoadCurCpBridgeCacheContainer` → **同步** `loadCp:`（容器仍 orphan）
3. `@finally` 才 `LBHypothesisJFlushDeferred`

滚动链比分页更依赖 VC/view 已挂树；orphan 上 `loadCp:` 后阅读页被清掉。

## 修复

1. `@finally` 先 `FlushDeferred`，再 `FProbe`（从而 loadCp 在 attach 之后）
2. Flush 静默丢 pending 改为 retain + `flush_add_drop` / `flush_ins_drop` 日志；OK 日志带 `pageContainerB` / `children`
3. 滚动 invoke 前若仍 orphan → `scroll_S3 defer_invoke` + `LBScheduleInvokeWhenPageReady`（含 `childViewControllers` 含 container）
4. 滚动路径跳过 `curPageVC` 探针
5. **S3b**：`LBEnsureLoadCurCpPrereqs` 对滚动容器补 `dicContents` + 空 `dicHeight`（`divisionResponse:heights:` 依赖；避免只写 reader / FindReadPage 漏 `pageContainerB`）

与 [分析 loadCp 后空书架](481584bc-6424-4fcb-9d38-16f541cb0dad) 结论一致：orphan 上 loadCp 为 silent no-op，无 QF→divisionResponse。
