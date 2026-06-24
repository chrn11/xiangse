import Foundation

/// 将 Legado 引擎结果转为香色闺阁可消费的 NSDictionary / 通知 userInfo
enum XiangseAdapter {
    static let notifySearchResponse = "dNotifyName_SearchBookSourceResponse"
    static let notifyCatalogResponse = "dNotifyName_QueryCatalogResponse"
    static let notifyResetContent = "dNotifyName_ReadView_ResetContent"
    static let notifyUpdateSourceList = "dNotifyName_UpdateBookSourceModelList"
    static let legadoMarkerKey = "legadoBridge"
    static let legadoMarkerValue = "1"

    static func searchResultsPayload(
        results: [SearchBookResult],
        keyword: String,
        sourceUrl: String
    ) -> [String: Any] {
        let books = results.map { searchBookDict($0) }
        return [
            "keyword": keyword,
            "sourceUrl": sourceUrl,
            legadoMarkerKey: legadoMarkerValue,
            "searchBook": books,
            "arrSearchBook": books,
            "fromLegadoBridge": true
        ]
    }

    static func catalogPayload(chapters: [BridgeChapter], bookUrl: String) -> [String: Any] {
        let list = chapters.map { chapterDict($0) }
        return [
            "bookUrl": bookUrl,
            legadoMarkerKey: legadoMarkerValue,
            "chapterList": list,
            "arrChapter": list,
            "fromLegadoBridge": true
        ]
    }

    static func contentPayload(content: String, chapterUrl: String) -> [String: Any] {
        [
            "chapterUrl": chapterUrl,
            legadoMarkerKey: legadoMarkerValue,
            "chapterContent": content,
            "content": content,
            "fromLegadoBridge": true
        ]
    }

    static func sourceListPayload(sources: [MemoryBridgeBookSource]) -> [String: Any] {
        let items = sources.map { sourceDict($0) }
        return [
            legadoMarkerKey: legadoMarkerValue,
            "bookSourceModels": items,
            "fromLegadoBridge": true
        ]
    }

    static func searchBookDict(_ r: SearchBookResult) -> [String: Any] {
        var d: [String: Any] = [
            "name": r.name,
            "bookName": r.name,
            "author": r.author,
            "bookUrl": r.bookUrl,
            "url": r.bookUrl,
            "sourceUrl": r.sourceUrl,
            legadoMarkerKey: legadoMarkerValue
        ]
        if let cover = r.coverUrl { d["coverUrl"] = cover }
        if let intro = r.intro { d["intro"] = intro }
        if let kind = r.kind { d["kind"] = kind }
        if let last = r.lastChapter { d["lastChapterTitle"] = last }
        if let wc = r.wordCount { d["wordCount"] = wc }
        return d
    }

    static func chapterDict(_ c: BridgeChapter) -> [String: Any] {
        [
            "title": c.title,
            "chapterName": c.title,
            "url": c.url,
            "chapterUrl": c.url,
            "index": c.index
        ]
    }

    static func sourceDict(_ s: MemoryBridgeBookSource) -> [String: Any] {
        [
            "bookSourceUrl": s.bookSourceUrl,
            "bookSourceName": s.bookSourceName,
            "sourceUrl": s.bookSourceUrl,
            "sourceName": s.bookSourceName,
            "enabled": true,
            legadoMarkerKey: legadoMarkerValue
        ]
    }
}
