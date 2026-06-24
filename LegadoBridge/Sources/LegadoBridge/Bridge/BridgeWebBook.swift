import Foundation
import SwiftSoup

/// 网络书籍操作 — 从 legado-ios WebBook 适配，使用 MemoryBridgeBookSource
enum BridgeWebBook {
    private static let ruleEngine = RuleEngine()
    private static let tocParser = TocParser(ruleEngine: ruleEngine)

    static func searchBook(
        source: MemoryBridgeBookSource,
        key: String,
        page: Int = 1
    ) async throws -> [SearchBookResult] {
        guard let searchUrl = source.searchUrl, !searchUrl.isEmpty else {
            throw WebBookError.noSearchUrl
        }

        let analyzedUrl = AnalyzeUrl.analyze(
            ruleUrl: searchUrl,
            key: key,
            page: page,
            baseUrl: source.bookSourceUrl,
            source: source
        )

        var (body, redirectUrl) = try await AnalyzeUrl.getResponseBody(analyzedUrl: analyzedUrl)
        (body, redirectUrl) = applyLoginCheckIfNeeded(source: source, body: body, url: redirectUrl)
        guard !body.isEmpty else { throw WebBookError.emptyResponse }

        guard let searchRule = source.getSearchRule() else {
            throw WebBookError.noRule("搜索规则")
        }

        return try parseBookList(
            source: source,
            body: body,
            baseUrl: redirectUrl,
            bookListRule: searchRule.bookList,
            nameRule: searchRule.name,
            authorRule: searchRule.author,
            kindRule: searchRule.kind,
            bookUrlRule: searchRule.bookUrl,
            coverUrlRule: searchRule.coverUrl,
            introRule: searchRule.intro,
            lastChapterRule: searchRule.lastChapter,
            wordCountRule: searchRule.wordCount
        )
    }

    static func getChapterList(
        source: MemoryBridgeBookSource,
        book: BridgeBook
    ) async throws -> [BridgeChapter] {
        guard let tocRule = source.getTocRule() else {
            throw WebBookError.noRule("目录规则")
        }

        let tocUrl = book.tocUrl.isEmpty ? book.bookUrl : book.tocUrl
        let body: String
        let redirectUrl: String

        if tocUrl == book.bookUrl, let cached = book.tocHtml, !cached.isEmpty {
            body = cached
            redirectUrl = book.bookUrl
        } else {
            let analyzedUrl = AnalyzeUrl.analyze(
                ruleUrl: tocUrl,
                baseUrl: source.bookSourceUrl,
                source: source
            )
            var (fetchedBody, fetchedUrl) = try await AnalyzeUrl.getResponseBody(analyzedUrl: analyzedUrl)
            (fetchedBody, fetchedUrl) = applyLoginCheckIfNeeded(source: source, body: fetchedBody, url: fetchedUrl)
            body = fetchedBody
            redirectUrl = fetchedUrl
        }

        guard !body.isEmpty else { throw WebBookError.emptyResponse }

        let webChapters = try tocParser.parseChapters(
            body: body,
            baseUrl: redirectUrl,
            rule: tocRule,
            startIndex: 0
        )

        return webChapters.enumerated().map { idx, ch in
            BridgeChapter(title: ch.title, url: ch.url, index: idx)
        }
    }

    static func getContent(
        source: MemoryBridgeBookSource,
        book: BridgeBook,
        chapter: BridgeChapter
    ) async throws -> String {
        guard let contentRule = source.getContentRule() else {
            throw WebBookError.noRule("正文规则")
        }
        guard let ruleStr = contentRule.content, !ruleStr.isEmpty else {
            return chapter.url
        }

        let analyzedUrl = AnalyzeUrl.analyze(
            ruleUrl: chapter.url,
            baseUrl: source.bookSourceUrl,
            source: source
        )
        var (body, redirectUrl) = try await AnalyzeUrl.getResponseBody(
            analyzedUrl: analyzedUrl,
            javaScript: contentRule.webJs,
            sourceRegex: contentRule.sourceRegex,
            forceWebView: !(contentRule.webJs?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        )
        (body, redirectUrl) = applyLoginCheckIfNeeded(source: source, body: body, url: redirectUrl)
        guard !body.isEmpty else { throw WebBookError.emptyResponse }

        let elementCtx = try makeElementContext(body: body, baseUrl: redirectUrl)
        return ruleEngine.getString(ruleStr: ruleStr, elementContext: elementCtx, baseUrl: redirectUrl)
    }

    // MARK: - 私有辅助

    private static func applyLoginCheckIfNeeded(
        source: MemoryBridgeBookSource,
        body: String,
        url: String
    ) -> (body: String, url: String) {
        guard let js = source.loginCheckJs?.trimmingCharacters(in: .whitespacesAndNewlines),
              !js.isEmpty else { return (body, url) }
        return (body, url)
    }

    private static func makeElementContext(body: String, baseUrl: String) throws -> ElementContext {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let isJson = trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
        let element: Any
        if isJson, let data = body.data(using: .utf8) {
            element = try JSONSerialization.jsonObject(with: data)
        } else {
            element = try SwiftSoup.parse(body)
        }
        return ElementContext(element: element, baseUrl: baseUrl)
    }

    private static func parseBookList(
        source: MemoryBridgeBookSource,
        body: String,
        baseUrl: String,
        bookListRule: String?,
        nameRule: String?,
        authorRule: String?,
        kindRule: String?,
        bookUrlRule: String?,
        coverUrlRule: String?,
        introRule: String?,
        lastChapterRule: String?,
        wordCountRule: String?
    ) throws -> [SearchBookResult] {
        guard let bookListRule, !bookListRule.isEmpty else { return [] }

        let elements = try ruleEngine.getElements(ruleStr: bookListRule, body: body, baseUrl: baseUrl)
        var results: [SearchBookResult] = []

        for el in elements {
            var item = SearchBookResult()
            item.sourceUrl = source.bookSourceUrl
            item.sourceName = source.bookSourceName
            if let nameRule { item.name = ruleEngine.getString(ruleStr: nameRule, elementContext: el, baseUrl: baseUrl) }
            if let authorRule { item.author = ruleEngine.getString(ruleStr: authorRule, elementContext: el, baseUrl: baseUrl) }
            if let kindRule { item.kind = ruleEngine.getString(ruleStr: kindRule, elementContext: el, baseUrl: baseUrl) }
            if let bookUrlRule {
                item.bookUrl = ruleEngine.getString(ruleStr: bookUrlRule, elementContext: el, baseUrl: baseUrl)
            }
            if let coverUrlRule {
                item.coverUrl = ruleEngine.getString(ruleStr: coverUrlRule, elementContext: el, baseUrl: baseUrl)
            }
            if let introRule { item.intro = ruleEngine.getString(ruleStr: introRule, elementContext: el, baseUrl: baseUrl) }
            if let lastChapterRule {
                item.lastChapter = ruleEngine.getString(ruleStr: lastChapterRule, elementContext: el, baseUrl: baseUrl)
            }
            if let wordCountRule {
                item.wordCount = ruleEngine.getString(ruleStr: wordCountRule, elementContext: el, baseUrl: baseUrl)
            }
            if !item.name.isEmpty || !item.bookUrl.isEmpty {
                results.append(item)
            }
        }
        return results
    }
}

/// 与 legado-ios WebBook 兼容的搜索结果
public struct SearchBookResult {
    var name: String = ""
    var author: String = ""
    var kind: String?
    var bookUrl: String = ""
    var coverUrl: String?
    var intro: String?
    var lastChapter: String?
    var wordCount: String?
    var sourceUrl: String = ""
    var sourceName: String = ""
}

enum WebBookError: Error, LocalizedError {
    case noSearchUrl
    case noRule(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .noSearchUrl: return "书源未配置 searchUrl"
        case .noRule(let n): return "缺少\(n)"
        case .emptyResponse: return "网络响应为空"
        }
    }
}
