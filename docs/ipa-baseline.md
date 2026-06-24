# 香色闺阁 2.56.1 IPA 基线分析

> 分析对象：`ipa/香色闺阁2.56.1_未加密.ipa`（砸壳未加密版）

## 基本信息

| 字段 | 值 |
|------|-----|
| Bundle ID | `com.appbox.StandarReader` |
| 版本 | `2.56.1` |
| 可执行文件 | `StandarReader` |
| 最低系统 | iOS 13.0 |
| 二进制大小 | 3,270,496 字节 |
| URL Scheme | `com.appbox.StandarReader` |

## 包结构

- **无** `Frameworks/` 目录 — 注入只需处理主二进制，无插件重签链
- **无** `PlugIns/` 目录
- 含 `_CodeSignature/`、`embedded.mobileprovision`、`SC_Info/`
- 资源目录：`dir_res/`（配置 plist、示例书源、导入模板）
- 内置 JS：`SearchWebView.js`（阅读器内搜索高亮）

## 书源相关资源

| 路径 | 说明 |
|------|------|
| `xsBookSource.xbs` | 默认书源包名（字符串） |
| `sourceModelList.xbs` | 站点列表包名 |
| `mulShare.xbs` | 分享书源包名 |
| `dir_res/dir_import/` | 本地导入模板 |
| `findXbsLink` / `queryXbsFile` | XBS 解密/查询入口（二进制符号） |

## 关键 ObjC 类（字符串提取）

| 类名 | 推测职责 |
|------|----------|
| `BookSourceManager` / `BookSourceModelManager` | 书源 CRUD |
| `BookSourceManagerBase` | 书源管理基类 |
| `SearchBookSource` | 搜索书源聚合 |
| `BookSearchVCBase2` | 搜索界面 |
| `ConfigSourceModelListCon` | 站点列表配置 |
| `LPNetWork2` / `LPNetWorkParser` | 网络请求与规则解析 |
| `XPathParserWithSource:` | XPath 规则执行 |
| `DomModelParser` | DOM 模型解析 |
| `LocalTextImportVC` | 本地文本导入 |

## 通知名（Hook 锚点）

| 通知 | 用途 |
|------|------|
| `dNotifyName_SearchBookSourceResponse` | 搜索结果回调 |
| `dNotifyName_UpdateBookSourceModelList` | 书源列表更新 |
| `dNotifyName_QueryCatalogResponse` | 目录查询响应 |
| `dNotifyName_ReadView_ResetContent` | 正文渲染 |
| `dNotifyName_ReadView_FilterContent` | 正文过滤 |

## 规则引擎特征

- 支持 `@js:` 前缀（与 Legado 类似但语法子集不同）
- 使用 `WKWebView` / `LPWebView` 做 WebView 嗅探
- JSON 路径：`SMJJSONPath`（Jayway JSONPath）
- XPath：`xmlXPath*` / `XPathParserWithSource:`

## 安装方式（本方案）

- **TrollStore** 永久安装修改后 IPA
- 无需有效开发者签名
- 通过 `insert_dylib` 注入 `LegadoBridge.framework`

## 原始数据

- `analysis/baseline.json` — Info.plist 摘要
- `analysis/deep-strings.json` — 关键字字符串命中
- `analysis/objc-classes.txt` — ObjC 类名候选
- `analysis/unpacked/` — 解压后 Payload
