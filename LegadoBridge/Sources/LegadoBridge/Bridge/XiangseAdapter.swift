import Foundation
import LegadoRuleCore

/// 将 Legado 引擎结果转为香色闺阁可消费的 NSDictionary / 通知 userInfo
enum XiangseAdapter {
    static let notifySearchResponse = "dNotifyName_SearchBookSourceResponse"
    static let notifyCatalogResponse = "dNotifyName_QueryCatalogResponse"
    static let notifyResetContent = "dNotifyName_ReadView_ResetContent"
    static let notifyUpdateSourceList = "dNotifyName_UpdateBookSourceModelList"
    static let legadoMarkerKey = "legadoBridge"
    static let legadoMarkerValue = "1"
    /// 持久绑定令牌，写入搜索/详情字典，供 BookBindingStore 反查
    static let bridgeTokenKey = "legadoBridgeToken"
    /// 书源可用性（删源后保留书籍时为 0）
    static let sourceAvailableKey = "legadoSourceAvailable"

    /// 批量结果载荷（调试/兼容）。原生 `onSearchBookSourceResponse:` 实际消费的是
    /// **单本** `queryBook`（见 `searchResultNotifyPayload`）；批量场景请逐条 post。
    static func searchResultsPayload(
        results: [SearchBookResult],
        keyword: String,
        sourceUrl: String,
        bindings: [String: BookBinding] = [:]
    ) -> [String: Any] {
        let books = results.map { r -> [String: Any] in
            searchBookDict(r, binding: bindings[r.bookUrl])
        }
        let sourceName = results.first?.sourceName
            ?? bindings.values.first?.sourceName
            ?? ""
        var payload: [String: Any] = [
            "keyword": keyword,
            "sourceUrl": sourceUrl,
            "sourceName": sourceName,
            "querySourceName": sourceName,
            "queryingSourceNameList": sourceName.isEmpty ? [] : [sourceName],
            legadoMarkerKey: legadoMarkerValue,
            "arrSearchBook": books,
            "arrSearchItems": books,
            "fromLegadoBridge": true
        ]
        // 原生监听侧期望 searchBook/queryBook 为字典；数组会 unrecognized selector / 闪退
        // 多本时仍只放首本字典（批量列表走 arrSearchBook），禁止把 [dict] 塞进 searchBook
        if let first = books.first {
            payload["queryBook"] = first
            payload["tempBook"] = first
            payload["searchBook"] = first
        }
        return payload
    }

    /// 单本增量通知载荷：对齐香色 `dNotifyName_SearchBookSourceResponse` 键
    ///（二进制邻接串：`queryBook` / `querySourceName` / `queryingSourceNameList` / `tempBook`）。
    static func searchResultNotifyPayload(
        book: [String: Any],
        keyword: String,
        sourceUrl: String,
        sourceName: String
    ) -> [String: Any] {
        let name = sourceName.isEmpty
            ? ((book["sourceName"] as? String) ?? (book["bookSourceName"] as? String) ?? "")
            : sourceName
        return [
            "keyword": keyword,
            "sourceUrl": sourceUrl,
            "sourceName": name,
            "querySourceName": name,
            "queryingSourceNameList": name.isEmpty ? [] : [name],
            "queryBook": book,
            "tempBook": book,
            // 兼容旧键：必须是字典，不能是数组
            "searchBook": book,
            "arrSearchBook": [book],
            "arrSearchItems": [book],
            legadoMarkerKey: legadoMarkerValue,
            "fromLegadoBridge": true
        ]
    }

    static func catalogPayload(
        chapters: [BridgeChapter],
        bookUrl: String,
        binding: BookBinding? = nil,
        bookDetail: [String: Any]? = nil
    ) -> [String: Any] {
        let list = chapters.map { chapterDict($0) }
        // 原生 onCatalogQueryFinishNotify / CatalogCon 读 chapterList，属性为 arrCatalog
        var payload: [String: Any] = [
            "bookUrl": bookUrl,
            legadoMarkerKey: legadoMarkerValue,
            "chapterList": list,
            "arrCatalog": list,
            "arrChapter": list,
            "fromLegadoBridge": true
        ]
        if let last = chapters.last?.title, !last.isEmpty {
            payload["lastChapterTitle"] = last
        }
        if let binding {
            payload["sourceUrl"] = binding.sourceUrl
            payload["sourceName"] = binding.sourceName
            payload["querySourceName"] = binding.sourceName
            payload["queryingSourceNameList"] = binding.sourceName.isEmpty ? [] : [binding.sourceName]
            payload[bridgeTokenKey] = binding.bridgeToken
            payload[sourceAvailableKey] = binding.sourceAvailable ? "1" : "0"
            let detail = bookDetail ?? detailDict(from: binding)
            payload["bookDetail"] = detail
            payload["tempBook"] = detail
            payload["dicBook"] = detail
        } else if let bookDetail {
            payload["bookDetail"] = bookDetail
            payload["tempBook"] = bookDetail
            payload["dicBook"] = bookDetail
        }
        return payload
    }

    static func contentPayload(
        content: String,
        chapterUrl: String,
        binding: BookBinding? = nil
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "chapterUrl": chapterUrl,
            legadoMarkerKey: legadoMarkerValue,
            "chapterContent": content,
            "content": content,
            "fromLegadoBridge": true
        ]
        if let binding {
            payload["bookUrl"] = binding.bookUrl
            payload["sourceUrl"] = binding.sourceUrl
            payload[bridgeTokenKey] = binding.bridgeToken
        }
        return payload
    }

    static func sourceListPayload(sources: [MemoryBridgeBookSource]) -> [String: Any] {
        let items = sources.map { sourceDict($0) }
        return [
            legadoMarkerKey: legadoMarkerValue,
            "bookSourceModels": items,
            "fromLegadoBridge": true
        ]
    }

    /// 搜索条目 → 香色原生详情/书架可消费字典（含 bridge token；进度/缓存仍由原生持有）
    static func searchBookDict(_ r: SearchBookResult, binding: BookBinding? = nil) -> [String: Any] {
        let token = binding?.bridgeToken
            ?? BookBindingStore.makeToken(bookUrl: r.bookUrl, sourceUrl: r.sourceUrl)
        var d: [String: Any] = [
            "name": r.name,
            "bookName": r.name,
            "author": r.author,
            "bookUrl": r.bookUrl,
            "url": r.bookUrl,
            "sourceUrl": r.sourceUrl,
            "sourceName": r.sourceName,
            "bookSourceName": r.sourceName,
            // 原生搜索页 filterSourceType 默认 text；填 DOM 会被筛成空列表
            "sourceType": "text",
            legadoMarkerKey: legadoMarkerValue,
            bridgeTokenKey: token,
            sourceAvailableKey: (binding?.sourceAvailable ?? true) ? "1" : "0",
            // 允许原生详情页走「加书架」；章节预加载/离线缓存/进度不由 Bridge 接管
            "canAddBookShelf": true,
            "fromLegadoBridge": true
        ]
        if let cover = r.coverUrl { d["coverUrl"] = cover }
        if let intro = r.intro { d["intro"] = intro }
        if let kind = r.kind {
            d["kind"] = kind
            d["type"] = kind
        }
        if let last = r.lastChapter { d["lastChapterTitle"] = last }
        if let wc = r.wordCount { d["wordCount"] = wc }
        return d
    }

    /// 从持久绑定还原详情字典（重启后点书架/历史进入详情）
    static func detailDict(from binding: BookBinding) -> [String: Any] {
        [
            "name": binding.name,
            "bookName": binding.name,
            "author": binding.author,
            "bookUrl": binding.bookUrl,
            "url": binding.bookUrl,
            "coverUrl": binding.coverUrl,
            "sourceUrl": binding.sourceUrl,
            "sourceName": binding.sourceName,
            "bookSourceName": binding.sourceName,
            "sourceType": "text",
            legadoMarkerKey: legadoMarkerValue,
            bridgeTokenKey: binding.bridgeToken,
            sourceAvailableKey: binding.sourceAvailable ? "1" : "0",
            "canAddBookShelf": true,
            "fromLegadoBridge": true
        ]
    }

    static func chapterDict(_ c: BridgeChapter) -> [String: Any] {
        [
            "title": c.title,
            "name": c.title,
            "chapterName": c.title,
            "url": c.url,
            "chapterUrl": c.url,
            "index": c.index,
            "chapterIndex": c.index
        ]
    }

    static func sourceDict(_ s: MemoryBridgeBookSource) -> [String: Any] {
        [
            "bookSourceUrl": s.bookSourceUrl,
            "bookSourceName": s.bookSourceName,
            "sourceUrl": s.bookSourceUrl,
            "sourceName": s.bookSourceName,
            "enable": "1",
            "enabled": true,
            legadoMarkerKey: legadoMarkerValue
        ]
    }
}
