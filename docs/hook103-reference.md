# hook103 参考清单（仅逆向参考，禁止构建依赖）

> 样本：`ipa/香色闺阁Plus_2.56.1_hook103.ipa`  
> 指纹见 [`analysis/baseline-hashes.json`](../analysis/baseline-hashes.json)  
> **硬性策略：禁止把 hook103 内任何第三方 dylib 作为注入/链接/运行时依赖。**

## 禁止依赖的二进制

| 组件 | 角色 | 处置 |
|------|------|------|
| `MikeCrack.dylib` | Logos/Substrate 功能 tweak（书源/UI/JS/解压等） | **禁止**注入与链接；仅作 selector 线索 |
| `libsubstrate.dylib` | Cydia Substrate 运行时 | **禁止** |
| `SideloadMikepass1/2.dylib` | 侧载/订阅绕过 | **禁止**；与书源无关 |
| `Tg@TrollstoreKios.dylib` / `Tg@TrollstoreMios.dylib` | 去广告/TrollStore 辅助 | **禁止** |
| `UnrarKit.framework` | RAR 解压（hook103 附带） | 首版不引入；若日后需要须独立开源实现 + 单独验收 |

注入基线永远是 `ipa/香色闺阁2.56.1_未加密.ipa`，不得改用 hook103 IPA。

## MikeCrack 能力 — 类 — selector — 验证状态

验证状态约定：

- `字符串已确认`：在 `MikeCrack.dylib` 字符串/Logos 符号中可见
- `基线主程序存在`：同名类/selector 字符串出现在原版 `StandarReader` 2.56.1 可执行文件中（见 `baseline-hashes.json`）
- `类型编码待真机`：须在未修改 2.56.1 诊断构建上复核 type encoding / 参数后再作为生产 Hook
- `产品未采用`：本仓库不复制该能力的无源码实现

| 能力分类 | 类 | selector | MikeCrack | 基线主程序 | 产品处置 |
|----------|----|----------|-----------|------------|----------|
| UI 关于页 | `AboutController` | `viewDidLoad` | 字符串已确认 | 待专项核对 | 产品未采用 |
| 书单列表 | `BookListCon` | `viewDidLoad` | 字符串已确认 | 待专项核对 | 产品未采用 |
| 书单 Cell | `BookListCellBase` | `initWithStyle:reuseIdentifier:` | 字符串已确认 | 待专项核对 | 产品未采用 |
| 书籍详情绑定 | `BookDetailController` | `setDicBook:` | 字符串已确认 | 基线主程序存在 | **候选探针**；runtime-hooks 阶段真机复核后可作详情锚点 |
| 详情滚动复位 | `BookDetailScrollView` | `initWithFrame:` / `resetPosition` | 字符串已确认 | `resetPosition` 基线存在 | **候选探针** |
| 书架 Cell 刷新 | `BookShelfListCell` | `reset:updating:lastTimeStamp:` | 字符串已确认 | 基线主程序存在 | **候选探针**（进度/封面刷新） |
| 书源落盘 | `BookSourceModelManager` | `save` | 字符串已确认 | 基线主程序存在（类名+`save`） | **候选探针**；与本仓库列表 Hook（`dicModelList` 等）并列，不替代 |
| JS AES | `LCJSTool` | `dataByAesDecryptWithBase64String:withKey:withIv:` | 字符串已确认 | 待专项核对 | 产品未采用二进制；语义可在 RuleCore 用自研夹具重写 |
| 设备指纹模板 | `LCJSTool` | `deviceIdWithTemplate:withSeparator:` | 字符串已确认 | 待专项核对 | 产品未采用 |
| 解压 | `LCJSTool` | `unzipFile:` / `unzipFile:withPassword:` | 字符串已确认 | 待专项核对 | 产品未采用；依赖 UnrarKit 时另立项 |
| 图片缓存策略 | `SDWebImageDownloaderOperation` | `URLSession:dataTask:willCacheResponse:completionHandler:` | 字符串已确认 | 待专项核对 | 产品未采用；脚本化图片解密另做夹具 |
| 视频播放 | `VideoReadPlayerCon` | `playUrl:cpIndex:httpHeaders:` | 字符串已确认 | 待专项核对 | 产品未采用（post-core） |
| 视频长按 | `VideoReadPlayerCon` | `handleLongPress:` | 字符串已确认 | 待专项核对 | 产品未采用 |
| HTML 解析 | `TFHpple` | `initWithHTMLData:` / `initWithData:encoding:isXML:` | 字符串已确认 | 待专项核对 | 产品未采用二进制；编码修复语义可自研 |

## 与本仓库已落地 Hook 的关系

本仓库生产路径见 [`docs/hook-map.md`](hook-map.md)，**不依赖** MikeCrack：

| 本仓库能力 | 类 / 符号 | 状态 |
|------------|-----------|------|
| JSON 导入（备用） | `NSJSONSerialization` `JSONObjectWithData:options:error:` | 已实现（IMP 替换 + 重入保护） |
| 文件打开导入 | `AppDelegate` `application:openURL:options:` | 已实现 |
| 搜索转发 | `startSearch:prioritySourceType:fromShuping:quick:` | 已实现 |
| 书源列表合并 | `BookSourceModelManager` `dicModelList` / `getSortedSourceNames*` 等 | 已实现 |
| 目录/正文 | 通知 `dNotifyName_QueryCatalogResponse` / `ResetContent` + 引擎 API；生产窄锚点 `setDicBook:` / `loadCatalog:ignoringCache:` / `loadCurCp` / `addBook:groupKey:tempBook:`（`LBReadingHooks`） | 请求侧已接通；`BookBindingStore` 持久映射防串源 |

## BookBindingStore（native-flow）

| 项 | 说明 |
|----|------|
| 落盘 | `Documents/legado_bridge_books.json` |
| 键 | `bookUrl` → `sourceUrl` + `legadoBridgeToken` |
| 搜索 | 结果字典带 `legadoBridge` / `legadoBridgeToken` / `canAddBookShelf`，进原生详情 |
| 书架 | Hook `BookShelfManager addBook:groupKey:tempBook:` 再次落盘；**进度/章节缓存不 Hook，走香色原生** |
| 删源 | 默认 `keepBooksMarkUnavailable`；可切 `clearBridgeBindings`；原版语义待 iOS MCP 复核 |

## 分类说明（避免误吸收）

1. **可复用线索**：详情/书架/书源保存相关 selector（上表标「候选探针」）。
2. **语义可重写、二进制不可用**：`LCJSTool` AES/解压、`TFHpple` HTML 修复、图片回调 — 只允许在独立 RuleCore 夹具中按社区源需求重写。
3. **明确排除**：Sideload 订阅绕过、去广告 Substrate 链、TrollStore 辅助 dylib、无源码 MikeCrack 本体。

## 再生与证据

```powershell
python .test_tools\gen_baseline_hashes.py
# 字符串摘录目录（本地临时，勿提交依赖）：analysis/_hook103_tmp/strings/
```
