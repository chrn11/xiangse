# IPA / 可执行文件 / 关键 selector 基线哈希

> 机器可读完整清单：[`analysis/baseline-hashes.json`](../analysis/baseline-hashes.json)  
> 再生：`python .test_tools/gen_baseline_hashes.py`

## 协议与注入锁定

| 项 | 值 |
|----|-----|
| 注入基线 IPA | `ipa/香色闺阁2.56.1_未加密.ipa` |
| Bundle ID | `com.appbox.StandarReader` |
| 版本 | `2.56.1` |
| 可执行文件 | `StandarReader`（thin **arm64**） |
| Legado 协议锁 | **legado-E 3.26.030717** |
| hook103 | 仅参考样本，**禁止**依赖其第三方 dylib |

## 基线哈希（原版 2.56.1）

| 对象 | SHA-256 |
|------|---------|
| IPA | `ed35e2734ef9d75ab8700921ec2819bb329c679ea508ba88e6d9576ae7be1631` |
| Info.plist | `920fa5bcedeabb271ad3c0604e1888eb508df98753aca3485b58adc205a517ce` |
| StandarReader 可执行文件 | `04f780eb59f86c9104f8c8c3c04fb24278f521d0a43e401b3773d2a47890dea7` |

- 可执行文件大小：3,270,496 字节  
- 架构：thin arm64（`MH_MAGIC_64` / `0xfeedfacf`）  
- `Frameworks/`：**无**（注入只需处理主二进制）

## 关键 ObjC selector 存在性（主程序字符串）

下列符号均在基线可执行文件中命中（`key_selector_present` 全为 true）：

- 导入：`application:openURL:options:`、`JSONObjectWithData:options:error:`
- 搜索：`startSearch:prioritySourceType:fromShuping:quick:`
- 书源管理：`BookSourceModelManager`、`dicModelList`、`getSortedSourceNames`、`getSortedSourceNamesByPriority`、`sourceTypeBySourceName:`、`sourceTypeTitleBySourceName:`
- 通知：`dNotifyName_SearchBookSourceResponse`、`dNotifyName_QueryCatalogResponse`、`dNotifyName_ReadView_ResetContent`、`dNotifyName_UpdateBookSourceModelList`
- hook103 候选探针对照：`setDicBook:`、`resetPosition`、`reset:updating:lastTimeStamp:`、`save`

## hook103 样本指纹（非注入基线）

| 对象 | SHA-256 |
|------|---------|
| hook103 IPA | `4876f4cece4164deb1a81b4cebb9d9b8469f44e938d87ead2a1827254d437b0a` |
| MikeCrack.dylib | `634b746a2149318bed3b2f90af315bd5f4b0415959dba18cd977391913714e1b` |

能力—类—selector 对照见 [`docs/hook103-reference.md`](hook103-reference.md)。

## 确定性测试门禁

| 入口 | 说明 |
|------|------|
| `LegadoBridge/Tests/LegadoBridgeTests` | 单源/数组导入、重复源覆盖、禁用、持久化恢复 |
| macOS/CI | `swift test --package-path LegadoBridge` |
| Windows | 无 iOS SDK 时跑 `python .test_tools/validate_baseline_and_tests.py` 校验哈希与测试 target 结构 |
