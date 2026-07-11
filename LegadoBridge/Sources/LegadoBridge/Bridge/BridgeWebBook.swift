import Foundation
import LegadoRuleCore

/// 网络书籍操作 — 薄封装 LegadoRuleCore.RuleWebBook，保持既有调用方兼容
enum BridgeWebBook {

    static func searchBook(
        source: MemoryBridgeBookSource,
        key: String,
        page: Int = 1
    ) async throws -> [SearchBookResult] {
        try await RuleWebBook.searchBook(source: source, key: key, page: page)
    }

    static func exploreBook(
        source: MemoryBridgeBookSource,
        url: String? = nil,
        page: Int = 1
    ) async throws -> [SearchBookResult] {
        try await RuleWebBook.exploreBook(source: source, url: url, page: page)
    }

    static func getBookInfo(
        source: MemoryBridgeBookSource,
        book: inout BridgeBook
    ) async throws -> BridgeBook {
        try await RuleWebBook.getBookInfo(source: source, book: &book)
    }

    static func getChapterList(
        source: MemoryBridgeBookSource,
        book: BridgeBook
    ) async throws -> [BridgeChapter] {
        try await RuleWebBook.getChapterList(source: source, book: book)
    }

    static func getContent(
        source: MemoryBridgeBookSource,
        book: BridgeBook,
        chapter: BridgeChapter
    ) async throws -> String {
        try await RuleWebBook.getContent(source: source, book: book, chapter: chapter)
    }
}
