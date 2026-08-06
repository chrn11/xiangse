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
    /// bindings 仅作展示 token 覆盖；搜索路径应传 ephemeral，禁止为此 upsert。
    static func searchResultsPayload(
        results: [SearchBookResult],
        keyword: String,
        sourceUrl: String,
        bindings: [String: BookBinding] = [:],
        ephemeralByBookUrl: [String: EphemeralBookDTO] = [:]
    ) -> [String: Any] {
        let books = results.map { r -> [String: Any] in
            searchBookDict(
                r,
                binding: bindings[r.bookUrl],
                ephemeral: ephemeralByBookUrl[r.bookUrl]
            )
        }
        let sourceName = results.first?.sourceName
            ?? bindings.values.first?.sourceName
            ?? ephemeralByBookUrl.values.first?.sourceName
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
        binding: BookBinding? = nil,
        cpTitle: String? = nil,
        cpIndex: Int? = nil
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "chapterUrl": chapterUrl,
            "cpUrl": chapterUrl,
            legadoMarkerKey: legadoMarkerValue,
            "chapterContent": content,
            "content": content,
            "fromLegadoBridge": true
        ]
        if let title = cpTitle, !title.isEmpty {
            payload["cpTitle"] = title
            payload["title"] = title
        }
        if let idx = cpIndex {
            payload["cpIndex"] = idx
            payload["index"] = idx
        }
        if let binding {
            payload["bookUrl"] = binding.bookUrl
            payload["sourceUrl"] = binding.sourceUrl
            payload["sourceName"] = binding.sourceName
            payload[bridgeTokenKey] = binding.bridgeToken
            // 阅读页 seed xsfolder 用 bookName_author；缺省会落到斗破假默认
            if !binding.name.isEmpty {
                payload["bookName"] = binding.name
                payload["name"] = binding.name
            }
            if !binding.author.isEmpty {
                payload["author"] = binding.author
            }
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

    /// 搜索条目 → 香色字典。优先 ephemeral DTO（不 durable）；binding 仅在已落盘后覆盖。
    static func searchBookDict(
        _ r: SearchBookResult,
        binding: BookBinding? = nil,
        ephemeral: EphemeralBookDTO? = nil,
        source: (any BridgeSourceProtocol)? = nil
    ) -> [String: Any] {
        let token: String = {
            if let binding { return binding.bridgeToken }
            if let ephemeral { return ephemeral.bridgeToken }
            if let identity = try? BookIdentity(exactSourceUrl: r.sourceUrl, exactBookUrl: r.bookUrl) {
                return identity.bridgeTokenV2
            }
            return ""
        }()
        let sourceName = binding?.sourceName.isEmpty == false
            ? binding!.sourceName
            : (ephemeral?.sourceName.isEmpty == false ? ephemeral!.sourceName : r.sourceName)
        var d: [String: Any] = [
            "name": r.name,
            "bookName": r.name,
            "author": r.author,
            "bookUrl": r.bookUrl,
            "url": r.bookUrl,
            "sourceUrl": r.sourceUrl,
            "sourceName": sourceName,
            "bookSourceName": sourceName,
            // 原生搜索页 filterSourceType 默认 text；填 DOM 会被筛成空列表
            "sourceType": "text",
            legadoMarkerKey: legadoMarkerValue,
            bridgeTokenKey: token,
            sourceAvailableKey: (binding?.sourceAvailable ?? true) ? "1" : "0",
            // 允许原生详情页走「加书架」；章节预加载/离线缓存/进度不由 Bridge 接管
            "canAddBookShelf": true,
            "fromLegadoBridge": true
        ]
        if let cover = r.coverUrl {
            let base = r.bookUrl.isEmpty ? r.sourceUrl : r.bookUrl
            let decoded = CoverDecodeHelper.decodeCoverURL(
                cover,
                decodeJs: source?.coverDecodeJs,
                baseUrl: base,
                source: source
            )
            d["coverUrl"] = decoded
        }
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

    static func detailDict(from v2: BookBindingV2) -> [String: Any] {
        detailDict(from: BookBinding(from: v2))
    }

    static func chapterDict(_ c: BridgeChapter) -> [String: Any] {
        // 香色原生目录/阅读大量读 cpTitle/cpUrl/cpIndex（非 title）
        [
            "title": c.title,
            "name": c.title,
            "chapterName": c.title,
            "cpTitle": c.title,
            "url": c.url,
            "chapterUrl": c.url,
            "cpUrl": c.url,
            "index": c.index,
            "chapterIndex": c.index,
            "cpIndex": c.index,
            legadoMarkerKey: legadoMarkerValue,
            "fromLegadoBridge": true
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

    /// 由搜索结果构造 ephemeral DTO（不写 store）。
    static func ephemeralDTO(from r: SearchBookResult) -> EphemeralBookDTO? {
        guard let identity = try? BookIdentity(exactSourceUrl: r.sourceUrl, exactBookUrl: r.bookUrl) else {
            return nil
        }
        var dto = EphemeralBookDTO(
            identity: identity,
            displayName: r.name,
            author: r.author,
            sourceName: r.sourceName
        )
        dto.coverUrl = r.coverUrl
        dto.intro = r.intro
        dto.kind = r.kind
        dto.lastChapter = r.lastChapter
        dto.wordCount = r.wordCount
        return dto
    }
}
