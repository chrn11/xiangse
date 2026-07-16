# StandarReader 2.56.1 阅读器静态调用链（reader-forensics）

## 基线身份

| 项 | 值 |
|---|---|
| base IPA SHA256 | `ed35e2734ef9d75ab8700921ec2819bb329c679ea508ba88e6d9576ae7be1631` |
| 可执行文件 SHA256 | `04f780eb59f86c9104f8c8c3c04fb24278f521d0a43e401b3773d2a47890dea7` |
| Mach-O | arm64 thin, image base `0x100000000` |
| 解析工具 | `tools/reader-forensics/parse_objc_method_map.py`, `build_chain_msgs.py` |

`open/StandarReader-2.56.1` 仅作类名/selector 索引；**类归属与 IMP 均以 `__objc_classlist` / `class_ro_t` / `method_list_t` 为准**。

---

## 一、目标类元数据摘要

| 类 | superclass | 关键 ivar / property |
|---|---|---|
| **TextReadVC3** | TextReadVC2 | `_cacherManager`, `_speaker` |
| **TextRPageContainer** | ReadPageContainer | 继承 `_dicContents`, `_reader`, `_dicPageVC` |
| **TextRPageContainerPage** | ReadPageContainerPage | `_textViewL`/`textViewL` (TextReadTV), `_textViewR`, `_widgetViewB` |
| **TextRScrollContainer** | ReadScrollContainer | `_titleLb`, `_widgetViewH`, `_widgetViewB` |
| **TextReadTV** | TextReadTVBase | 选区/手势 ivar；基类含 `frameRef` (CTFrame) |
| **ReadPageModel** | NSObject | `_pageStatus`, `_nPageCount`, `_nCpIndex`, `_nPageIndex` 等（无 CTFrame ivar） |
| **ReadPageContainer** | NSObject | `_dicContents`, `_reader`, `_dicPageVC`；**`loadCurCp` IMP owner** |
| **ReadScrollContainer** | NSObject | 17 ivar；`divisionResponse:cpTitle:cpIndex:heights:` |

完整 method/ivar/property/IMP offset 见 `method-map.json`。

---

## 二、调用链（静态 xref）

### 2.1 正文加载 → 分页入口

```
ReadPageContainer#loadCurCp          [IMP 0x1000d7cf4, offset 0xd7cf4]
  ├─ curPageVC / pageStatus / arrCatalog / count
  ├─ BookDbManager#sharedInstance → dicFatBook
  ├─ queryCpFileByBook:cpInfo:cpIndex:userInfo:target:cachePolicy:  (缓存/网络取章)
  └─ showError:cpIndex:... / resetLoadCpTip: (失败路径)

ReadPageContainer#lpNetWorkDelegateQueryFinish:config:userInfo:  [0xd8278]
  └─ divisionResponse:cpTitle:cpIndex:   (confirmed msgSend trace)
```

**`setCpCached:cpIndex:bookKey:sourceName:`** owner = **BookDbManager** [IMP `0x1000b0ca8`]，写 DB 表 `createCpCachedTableByTableName:` / `getCpCachedIdBySourceName:...`（与 `loadCurCp` 读路径配对；静态未见 `loadCurCp` 直接 bl 到 `setCpCached`）。

### 2.2 分页 / division

```
TextRScrollContainer#divisionResponse:cpTitle:cpIndex:heights:  [0xfdd04]
  ├─ divisionText:cpTitle:cpIndex:tvSize:doubleCol:backHeights:  → PaibanManager
  ├─ didPagingCompleted:
  └─ resetWidgetContent

PaibanManager#divisionText:...:paibanInfo:  [0x55bfc]
  └─ 正文清洗/排版字典/AttributedString 构建（无静态命中 onDivisionTextFinish）

TextRPageContainer#divisionResponse:cpTitle:cpIndex:  [0xabf1c]
  ├─ curPageVC
  ├─ textViewL          (lazy getter，见下)
  └─ frame

ReadPageContainer#onDivisionTextFinish:cpIndex:  [0xd8870]
  ├─ curPageVC / pageStatus / nPageIndex / fPageProgress
  └─ gotoCp:page:progress:usePageIndex:directShow:direction:animated:
```

**注**：`ReadPageContainer#divisionResponse:cpTitle:cpIndex:` method list IMP `0xd886c` 为单条 `ret` 桩；**有效实现**在子类 `TextRPageContainer` / 滚动容器覆盖，以及 **`onDivisionTextFinish`** 与其实质同体（相邻 IMP）。

**`onDivisionTextFinish:cpIndex:` 静态调用方**：全二进制 msgSend 窗口扫描 **未发现** confirmed caller → **unknown**（可能 block/performSelector/通知）。

### 2.3 textViewL 创建与展示

```
TextRPageContainerPage#textViewL  [getter IMP 0xb1924]  ← confirmed owner
  若 _textViewL == nil:
    ├─ [TextReadTV alloc]
    ├─ initWithFrame:useLongPress:
    ├─ view / addSubview:
    ├─ backgroundColor / textColor 等
    └─ str → _textViewL

TextRPageContainerPage#viewDidLoad  [0xb148c]
  ├─ [super viewDidLoad]
  ├─ resetContentPosByScreenSize:
  └─ resetWidgetPosByScreenSize:

TextRPageContainerPage#showContent:title:  [0xb2450]
  ├─ firstObject / objectAtIndexedSubscript:
  ├─ showWidget:
  └─ showContent:title:  (super ReadPageContainerPage — 仅 removeFromSuperview/setDelegate:)
```

### 2.4 pageModel / CTFrame / setPageModel

| 对象 | 证据 | 说明 |
|---|---|---|
| **ReadPageModel** | ivar 列表 | 仅页码/进度元数据，**无 CTFrame** |
| **CTFrame** | `TextReadTVBase.frameRef` (`^{__CTFrame=}`) | confirmed ivar |
| **setPageModel:** | **ReadScrollContainerCell** [0x7957c] | synthesized setter 写 `_pageModel`；**静态无 confirmed 调用方** |
| **pageModel** getter | ReadPageContainerPage / ReadScrollContainerCell | 容器页与滚动 cell 各持有 `ReadPageModel*` |

滚动展示路径：

```
ReadScrollContainerCell#showContent:  [0x7928c]
  ├─ pageModel / setPageStatus: / loadCp:
  └─ showErrorView: / reader
```

### 2.5 首次绘制

```
TextReadTVBase#setAttString:   → setNeedsDisplay  (confirmed)
TextReadTVBase#resetFrameRef  → setNeedsDisplay  (confirmed)

TextReadTV#drawRect:  [0x5bed0]
  ├─ drawRect: (super)
  ├─ bounds / setFill
  └─ CoreText 绘制在 IMP 内直接调用（非 objc_msgSend）
```

**首次 draw 触发链**：`setNeedsDisplay` ← `setAttString`/`resetFrameRef` ← **unknown** 何者在 division 完成后调用（静态未闭环到 `showContent`/`setPageModel`）。

---

## 三、五个核心问题（置信度）

| # | 问题 | 结论 | 置信度 |
|---|---|---|---|
| 1 | 谁创建/赋值 **textViewL**？ | **`TextRPageContainerPage#textViewL` getter**（IMP `0xb1924`）lazy 创建 `TextReadTV` 并写入 `_textViewL` | **confirmed** |
| 2 | 谁创建 **pageModel / CTFrame**？ | **pageModel**：`ReadPageModel` 为模型类；**CTFrame** 在 **`TextReadTVBase.frameRef`**，非 ReadPageModel | **confirmed**（归属）；创建时机 **unknown** |
| 3 | 谁调用 **setPageModel:**？ | owner = **ReadScrollContainerCell**；静态 msgSend 扫描 **无 caller** | owner **confirmed**；caller **unknown** |
| 4 | 缓存正文如何进入分页？ | **loadCurCp** → **queryCpFileByBook:...** → **lpNetWorkDelegateQueryFinish** → **divisionResponse** → **PaibanManager#divisionText**；写缓存 **BookDbManager#setCpCached**（与读路径分离） | **probable**（读链 confirmed 到 divisionText；写缓存未与 loadCurCp 直连） |
| 5 | 谁触发首次 **draw**？ | **setAttString** / **resetFrameRef** → **setNeedsDisplay** → **drawRect:** | **probable**（draw 入口 confirmed；上游谁调 setAttString **unknown**） |

---

## 四、与 b492825 实验分支注释冲突清单

| b492825 假设/注释 | 静态证据 | 判定 |
|---|---|---|
| `textViewL` 在 TextRPageContainerPage | getter IMP + `_textViewL` ivar | **一致** |
| `divisionResponse` 在 TextRScrollContainer | method list owner + IMP `0xfdd04` | **一致** |
| `showContent:title:` 在 ReadPageContainerPage 系 | TextRPageContainerPage 覆盖 IMP `0xb2450` | **一致**（具体类为子类） |
| CTFrame / 正文在 **ReadPageModel** KVC `text` | ReadPageModel **无** CTFrame；CTFrame 在 **TextReadTVBase.frameRef** | **冲突** |
| `onDivisionTextFinish` 由 division 链显式 msgSend | 全库静态 **无 caller** | **未证实**（仍可能动态） |
| `setPageModel` 可由 container textViewL/R 直接调用 | 仅 **ReadScrollContainerCell** 有 method；TextReadTV **无 setPageModel** | **部分冲突**（翻页容器 vs 滚动 cell） |
| `loadCurCp` 在 TextReadVC3 | **ReadPageContainer** method list owner | **冲突**（VC 继承容器，非 VC 自身 IMP） |

---

## 五、关键 IMP / offset 速查

| selector | owner class | imp_offset | imp_va |
|---|---|---:|---|
| loadCurCp | ReadPageContainer | 0xd7cf4 | 0x1000d7cf4 |
| onDivisionTextFinish:cpIndex: | ReadPageContainer | 0xd8870 | 0x1000d8870 |
| divisionResponse:cpTitle:cpIndex: | TextRPageContainer | 0xabf1c | 0x1000abf1c |
| divisionResponse:...:heights: | TextRScrollContainer | 0xfdd04 | 0x1000fdd04 |
| divisionText:...:paibanInfo: | PaibanManager | 0x55bfc | 0x100055bfc |
| textViewL | TextRPageContainerPage | 0xb1924 | 0x1000b1924 |
| showContent:title: | TextRPageContainerPage | 0xb2450 | 0x1000b2450 |
| setPageModel: | ReadScrollContainerCell | 0x7957c | 0x10007957c |
| drawRect: | TextReadTV | 0x5bed0 | 0x10005bed0 |
| setCpCached:... | BookDbManager | 0xb0ca8 | 0x1000b0ca8 |
| setAttString: | TextReadTVBase | 0x5b6a4 | 0x10005b6a4 |

---

## 六、停止条件检查

- base IPA hash：**一致** ✓
- method owner：**已从 method list 定位** ✓
- 需动态证据项：已标 **unknown** ✓
- **未停止**
