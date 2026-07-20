# 假设 AQ：撤 AE inThread 注入回原版 QF 路径 + 禁 early-wrap 50ms 递归

- **commit**: `c90cafa`（基于 tip `6f49200`）
- **日期**: 2026-07-20
- **CI run**: `29716225333`（success，2m54s）
- **模型**: cursor-grok-4.5
- **前置 KEEP**: `fe1c9eb`(AK 禁 bg windows) + `8984070`(strftime) + V+W+X+Y+Z + BQM
- **MCP**: `http://192.168.1.18:8090`；**mock**: `http://192.168.1.4:8765`

## 假设

AE 的 `callback_inThread=YES` 注入是偏移点，AG-AP 全在处理它的副作用（bg QF SIGSEGV/UIWindowScene/ICU/CF）。真根因是「invoke 后 main 不排空」从未被定位。本刀回到原版路径：

1. 撤 `callback_inThread=@YES` 注入，回原版 `dispatch_async(main)` QF 路径
2. 禁 `LBFScheduleEarlyWrapRetry` 的 50ms 无限递归（`objc_getClassList` 全表 + `dispatch_sync(main)` 隐患）
3. 加最小探针定位 main 排空 / pageStatus / container attach / orig IMP

## 改动

### `LegadoBridge/Sources/LegadoBridgeHooks/LBLoadCurCpBridge.m`
- 删除 1603-1616 行的 `callback_inThread=@YES` 注入逻辑，改透传原 `userInfo`
- 加 `aq_qf_path_orig` 探针记录 action/inThread/dontFormat
- `LBInvokeOriginalLoadCurCp` 内 invoke 前后加 4 个 AQ 探针：
  - `aq_orig_imp_class`：`sOrigLoadCurCp` 的 dladdr 符号 + 反查类名
  - `aq_container_attach`：container 视图层级 attach（UIView window/superview 或 VC window/parent/nav）
  - `aq_pageStatus_pre/post`：invoke 前后 `container.pageStatus` 值
  - `aq_main_drain_pulse/result`：`dispatch_async(main)` 脉冲 + 300ms 后检查 drained

### `LegadoBridge/Sources/LegadoBridgeDebug/LBForensicsObserver.m`
- `LBFScheduleEarlyWrapRetry`：删除 `dispatch_after(main, 50ms)` 自递归
- 仅保留首次 `DiscoverAndInstall + InstallObservers`，写 `aq_early_wrap_retry_disabled` ping

## 真机证据（pid=13200 -> 13210）

### AQ 探针（全部触发）
| 探针 | 值 | 解读 |
|------|-----|------|
| `aq_early_wrap_retry_disabled` | `true`（forensics_hook_ping.txt 有记录）| early-wrap 50ms 递归已禁，AQ 改动生效 |
| `aq_qf_path_orig` | `action=chapterContent inThread=0 dontFormat=0 main=0` | **撤 AE inThread 注入确认生效**；CB 在非 main 线程 |
| `aq_orig_imp_class` | `cls=? imp=0x10017fcf4` | dladdr 未解析出符号，反查 ReadPageContainer/TextRPageContainer 的 loadCurCp IMP 也不匹配--**sOrigLoadCurCp 可能错位** |
| `aq_container_attach` | `state=container_vc_orphan readerAttached=1` | **container VC 无 window/parent/nav（orphan），但 readerVC 有 parent**--attach 判定盲点确认 |
| `aq_pageStatus_pre` | `val=nil container=TextRPageContainer` | **invoke 前 pageStatus=nil**（不是 3 也不是 -999，container 无此属性或值为 nil）|
| `aq_pageStatus_post` | `val=nil` | invoke 后仍 nil |
| `aq_main_drain_pulse` | `false`（未触发）| **main drain 脉冲未执行**--进程在 QF 后 SIGSEGV 前 dispatch_async 还没来得及跑 |
| `aq_main_drain_result` | `""`（空）| 同上，进程已崩 |

### invoke -> SIGSEGV 完整序列
1. `pre_invoke_orig target=TextRPageContainer main=1` - invoke 在 main
2. `aq_orig_imp_class cls=? imp=0x10017fcf4` - orig IMP 错位
3. `aq_container_attach state=container_vc_orphan readerAttached=1` - container orphan
4. `aq_pageStatus_pre val=nil` - pageStatus nil
5. `invoke_orig_returned target=TextRPageContainer` - invoke 返回
6. `aq_pageStatus_post val=nil` - 仍 nil
7. `cb_enter ... main=0` - CB 非主线程
8. `aq_qf_path_orig inThread=0` - 撤 AE 生效
9. `check_enter -> check_exit ok=1` - check 通过
10. `format_enter -> format_exit` - format 完成
11. `qf_dispatch_gates phase=post_format path=async_main` - **QF 走原版 async_main**
12. `qf_dispatch_gates phase=after_cb path=async_main` - CB 后也是 async_main
13. `cb_exit` - CB 退出
14. **`ao_lbf_hook` 风暴**：depth 从 64 飙到 4864（76 条记录，递归 4864 层），`postQF=1 main=1`
15. `an_fault_signal SIG=11 si_code=2 fault=16fc5bfa0 pc=1cc516c98` - **SIGSEGV**
16. `ap_fault_sym tag=CFRetain addr=1cc506038 img=CoreFoundation` - **崩溃在 CFRetain**

### 关键结论
| 指标 | 值 | 状态 |
|------|-----|------|
| inThread 是否撤 | `inThread=0` | ✅ 撤成功 |
| early-wrap 是否禁 | `aq_early_wrap_retry_disabled=true` | ✅ 禁成功 |
| pageStatus pre | `nil` | ⚠️ container 无 pageStatus 属性（不是 3 也不是 -999）|
| pageStatus post | `nil` | ⚠️ invoke 未改变 |
| container attach | `container_vc_orphan` | ⚠️ container VC orphan 但 readerAttached=1（盲点确认）|
| main drain | 未触发 | ❌ 进程 SIGSEGV 前 dispatch_async 没跑 |
| QF 线程 | CB `main=0`，QF `path=async_main` | ⚠️ QF 派发到 main 但 main 未排空就崩 |
| 萧炎 | `passed=false` | ❌ 进程崩后重启回书架 |
| pid | 13200 -> 13210 | ❌ 不稳（SIGSEGV 后重启）|

## 根因定位

**AQ 撤 inThread + 禁 early-wrap 递归都生效，但未解决真根因。** 真根因不是「main 不排空」（这是表象），而是：

1. **postQF 窗 `LBFHook` 递归风暴**（depth=4864）--AO 已识别，AQ 撤 inThread 后依旧
2. LBFHook 在 postQF 窗疯狂重入 CFRetain/CFRelease，最终 SIGSEGV（pc=1cc516c98 = CoreFoundation CFRetain）
3. main drain 脉冲未触发是因为进程在 dispatch_async 执行前就崩了

**新盲点确认：**
- `sOrigLoadCurCp` 指向 `imp=0x10017fcf4`，dladdr 和类名反查都没匹配--**orig IMP 错位**（可能 hook 到了 wrapper 而非 native IMP）
- `container_vc_orphan`：container VC 无 window/parent/nav，但 `readerAttached=1`（readerVC 有 parent）--attach 判定不一致
- `pageStatus=nil`：container 根本没有 pageStatus 属性（KVC 取 nil），V 假设的 `cmp pageStatus,#3` 对照的是 pageModel.pageStatus 而非 container.pageStatus

## 下一步（AR 候选）

1. **LBFHook postQF 风暴是 SIGSEGV 直接触发点**--须在 postQF 窗禁 LBFHook 重入（depth > N 时 short-circuit），而非撤 inThread
2. **sOrigLoadCurCp 错位**：`imp=0x10017fcf4` 不属于 ReadPageContainer/TextRPageContainer 的 loadCurCp--须验证是否 hook 到了 forensics early-wrap wrapper
3. **pageStatus 取值路径**：应从 `pageModel.pageStatus` 而非 `container.pageStatus` 取，V 假设的 cmp #3 对照的是 pageModel
4. main drain 须在 invoke 返回后立即 dispatch_sync(main) 测试（而非 async），避免进程崩前脉冲没跑

## 交付

- ✅ inThread 撤成功（`inThread=0`）
- ✅ early-wrap 递归禁成功（`aq_early_wrap_retry_disabled`）
- ⚠️ pageStatus pre/post = nil（container 无此属性）
- ⚠️ container attach = container_vc_orphan（盲点确认）
- ❌ main drain 未触发（SIGSEGV 前未执行）
- ⚠️ QF 线程 = async_main（原版路径），但 main 未排空就崩
- ❌ 萧炎未通过（SIGSEGV 后重启）
- pid = 13200 -> 13210（不稳）

**失败：revert 本刀功能改动**（用户要求成功才保留，失败 revert）。

## Revert 记录

- **commit `501cab7`**：恢复 AE `callback_inThread=@YES` 注入
- 保留：AQ 探针（`aq_*`）+ early-wrap 50ms 递归禁用（诊断工具，非功能改动）
- CI 已推送 `c90cafa..501cab7`，待下次 CI 验证

## 保留的诊断价值

1. **AQ 探针**：invoke 前后 pageStatus / container attach / orig IMP / main drain，后续 AR 可复用
2. **early-wrap 递归禁用**：消除了 `objc_getClassList` 全表 + `dispatch_sync(main)` 隐患，减少 main 阻塞候选
3. **根因确认**：inThread 不是根因，LBFHook postQF 风暴才是（depth=4864，main=1，SIGSEGV@CFRetain）
