//
//  WebBook.swift
//  Legado-iOS
//
//  网络书籍操作核心模块 - 参考原版 WebBook.kt
//  提供搜索、获取书籍信息、获取目录、获取正文的完整链路
//

import Foundation
import CoreData
import JavaScriptCore
import SwiftSoup

/// 搜索结果
struct SearchBookResult {
    var name: String = ""
    var author: String = ""
    var kind: String?
    var bookUrl: String = ""
    var coverUrl: String?
    var intro: String?
    var lastChapter: String?
    var wordCount: String?
    var sourceUrl: String = ""       // 来源书源 URL
    var sourceName: String = ""      // 来源书源名称
}

/// 章节信息（用于远程获取）
struct WebChapter {
    var title: String = ""
    var url: String = ""
    var index: Int = 0
    var isVolume: Bool = false
    var isVip: Bool = false
    var isPay: Bool = false
    var updateTime: Int64?
}

/// WebBook 核心操作类
class WebBook {
    
    private static let ruleEngine = RuleEngine()
    private static let tocParser = TocParser(ruleEngine: ruleEngine)
    
    // MARK: - 搜索
    
    /// 在指定书源中搜索书籍
    static func searchBook(
        source: BookSource,
        key: String,
        page: Int = 1
    ) async throws -> [SearchBookResult] {
        guard let searchUrl = source.searchUrl, !searchUrl.isEmpty else {
            throw WebBookError.noSearchUrl
        }
        
        // 1. 构建搜索 URL
        let analyzedUrl = AnalyzeUrl.analyze(
            ruleUrl: searchUrl,
            key: key,
            page: page,
            baseUrl: source.bookSourceUrl,
            source: source
        )
        
        // 2. 发起请求
        var response = try await AnalyzeUrl.getResponseBody(analyzedUrl: analyzedUrl)
        response = applyLoginCheckIfNeeded(source: source, response: response)
        let body = response.body
        let redirectUrl = response.url
        
        guard !body.isEmpty else {
            throw WebBookError.emptyResponse
        }
        
        // 3. 解析搜索结果
        guard let searchRule = source.getSearchRule() else {
            throw WebBookError.noRule("搜索规则")
        }

        if let bookUrlPattern = source.bookUrlPattern,
           let regex = try? NSRegularExpression(pattern: bookUrlPattern) {
            let range = NSRange(redirectUrl.startIndex..., in: redirectUrl)
            if regex.firstMatch(in: redirectUrl, range: range) != nil,
               let directResult = try parseDetailPageAsSearchResult(
                    source: source,
                    body: body,
                    requestURL: analyzedUrl.url,
                    redirectURL: redirectUrl
               ) {
                return [directResult]
            }
        }
        
        let results = try parseBookList(
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

        if results.isEmpty, (source.bookUrlPattern?.isEmpty ?? true),
           let directResult = try parseDetailPageAsSearchResult(
                source: source,
                body: body,
                requestURL: analyzedUrl.url,
                redirectURL: redirectUrl
           ) {
            return [directResult]
        }

        return dedupeSearchResults(results)
    }

    static func exploreBook(
        source: BookSource,
        url: String,
        page: Int = 1
    ) async throws -> [SearchBookResult] {
        let analyzedUrl = AnalyzeUrl.analyze(
            ruleUrl: url,
            page: page,
            baseUrl: source.bookSourceUrl,
            source: source
        )

        var response = try await AnalyzeUrl.getResponseBody(analyzedUrl: analyzedUrl)
        response = applyLoginCheckIfNeeded(source: source, response: response)
        let body = response.body
        let redirectUrl = response.url

        guard !body.isEmpty else {
            throw WebBookError.emptyResponse
        }

        let exploreRule = source.getExploreRule()
        let hasExploreList = !(exploreRule?.exploreList?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

        let results = try parseBookList(
            source: source,
            body: body,
            baseUrl: redirectUrl,
            bookListRule: hasExploreList ? exploreRule?.exploreList : source.getSearchRule()?.bookList,
            nameRule: hasExploreList ? exploreRule?.name : source.getSearchRule()?.name,
            authorRule: hasExploreList ? exploreRule?.author : source.getSearchRule()?.author,
            kindRule: hasExploreList ? exploreRule?.kind : source.getSearchRule()?.kind,
            bookUrlRule: hasExploreList ? exploreRule?.bookUrl : source.getSearchRule()?.bookUrl,
            coverUrlRule: hasExploreList ? exploreRule?.coverUrl : source.getSearchRule()?.coverUrl,
            introRule: hasExploreList ? exploreRule?.intro : source.getSearchRule()?.intro,
            lastChapterRule: hasExploreList ? exploreRule?.lastChapter : source.getSearchRule()?.lastChapter,
            wordCountRule: hasExploreList ? exploreRule?.wordCount : source.getSearchRule()?.wordCount
        )

        if results.isEmpty, (source.bookUrlPattern?.isEmpty ?? true),
           let directResult = try parseDetailPageAsSearchResult(
                source: source,
                body: body,
                requestURL: analyzedUrl.url,
                redirectURL: redirectUrl
           ) {
            return [directResult]
        }

        return dedupeSearchResults(results)
    }
    
    // MARK: - 获取书籍详情
    
    /// 获取书籍详细信息
    static func getBookInfo(
        source: BookSource,
        book: Book
    ) async throws {
        guard let infoRule = source.getBookInfoRule() else {
            throw WebBookError.noRule("书籍信息规则")
        }
        
        // 1. 请求详情页
        let analyzedUrl = AnalyzeUrl.analyze(
            ruleUrl: book.bookUrl,
            baseUrl: source.bookSourceUrl,
            source: source
        )
        var response = try await AnalyzeUrl.getResponseBody(analyzedUrl: analyzedUrl)
        response = applyLoginCheckIfNeeded(source: source, response: response)
        let body = response.body
        let redirectUrl = response.url
        
        guard !body.isEmpty else {
            throw WebBookError.emptyResponse
        }
        
        // 2. 解析书籍信息
        let isJson = body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") ||
                     body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[")
        
        let context = ExecutionContext()
        if isJson {
            context.jsonString = body
        } else {
            context.document = try SwiftSoup.parse(body)
        }
        context.baseURL = URL(string: redirectUrl)
        
        var elementCtx = ElementContext(
            element: isJson ? (try JSONSerialization.jsonObject(with: body.data(using: .utf8)!) as Any) :
                     (try SwiftSoup.parse(body) as Any),
            baseUrl: redirectUrl
        )

        if let initRule = infoRule.initRule?.trimmingCharacters(in: .whitespacesAndNewlines),
           !initRule.isEmpty,
           let initializedContext = try ruleEngine.getElements(ruleStr: initRule, body: body, baseUrl: redirectUrl).first {
            elementCtx = initializedContext
        }

        let canRename = !(infoRule.canReName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        
        // 3. 填充书籍信息
        if let name = infoRule.name {
            let parsed = ruleEngine.getString(ruleStr: name, elementContext: elementCtx, baseUrl: redirectUrl)
            let normalized = normalizeBookName(parsed)
            if !normalized.isEmpty, (canRename || book.name.isEmpty) { book.name = normalized }
        }
        if let author = infoRule.author {
            let parsed = ruleEngine.getString(ruleStr: author, elementContext: elementCtx, baseUrl: redirectUrl)
            let normalized = normalizeBookAuthor(parsed)
            if !normalized.isEmpty, (canRename || book.author.isEmpty) { book.author = normalized }
        }
        if let kind = infoRule.kind {
            let parsed = ruleEngine.getString(ruleStr: kind, elementContext: elementCtx, baseUrl: redirectUrl)
            if !parsed.isEmpty {
                book.kind = parsed
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: ",")
            }
        }
        if let intro = infoRule.intro {
            let parsed = ruleEngine.getString(ruleStr: intro, elementContext: elementCtx, baseUrl: redirectUrl)
            if !parsed.isEmpty { book.intro = normalizeIntro(parsed) }
        }
        if let coverUrl = infoRule.coverUrl {
            let parsed = ruleEngine.getString(ruleStr: coverUrl, elementContext: elementCtx, baseUrl: redirectUrl)
            if !parsed.isEmpty {
                book.coverUrl = URL(string: parsed, relativeTo: URL(string: redirectUrl))?.absoluteURL.absoluteString ?? parsed
            }
        }
        if let tocUrl = infoRule.tocUrl {
            let parsed = ruleEngine.getString(ruleStr: tocUrl, elementContext: elementCtx, baseUrl: redirectUrl)
            if !parsed.isEmpty {
                book.tocUrl = URL(string: parsed, relativeTo: URL(string: redirectUrl))?.absoluteURL.absoluteString ?? parsed
            }
        }
        if book.tocUrl.isEmpty {
            book.tocUrl = book.bookUrl
        }
        if book.tocUrl == book.bookUrl {
            book.tocHtml = body
        }
        if let lastChapter = infoRule.lastChapter {
            let parsed = ruleEngine.getString(ruleStr: lastChapter, elementContext: elementCtx, baseUrl: redirectUrl)
            if !parsed.isEmpty { book.latestChapterTitle = parsed }
        }
        if let wordCount = infoRule.wordCount {
            let parsed = ruleEngine.getString(ruleStr: wordCount, elementContext: elementCtx, baseUrl: redirectUrl)
            if !parsed.isEmpty { book.wordCount = formatWordCount(parsed) }
        }
        if let downloadUrlsRule = infoRule.downloadUrls,
           let parsed = try? ruleEngine.getStringList(ruleStr: downloadUrlsRule, body: body, baseUrl: redirectUrl, isUrl: true),
           !parsed.isEmpty {
            book.downloadUrls = parsed.joined(separator: "\n")
        }
    }
    
    // MARK: - 获取目录
    
    /// 获取书籍章节目录
    static func getChapterList(
        source: BookSource,
        book: Book
    ) async throws -> [WebChapter] {
        guard let tocRule = source.getTocRule() else {
            throw WebBookError.noRule("目录规则")
        }
        
        let tocUrl = book.tocUrl.isEmpty ? book.bookUrl : book.tocUrl

        let body: String
        let redirectUrl: String

        if tocUrl == book.bookUrl,
           let cachedTocHtml = book.tocHtml,
           !cachedTocHtml.isEmpty {
            body = cachedTocHtml
            redirectUrl = book.bookUrl
        } else {
            // 1. 请求目录页
            let analyzedUrl = AnalyzeUrl.analyze(
                ruleUrl: tocUrl,
                baseUrl: source.bookSourceUrl,
                source: source
            )
            var response = try await AnalyzeUrl.getResponseBody(analyzedUrl: analyzedUrl)
            response = applyLoginCheckIfNeeded(source: source, response: response)
            body = response.body
            redirectUrl = response.url
        }
        
        guard !body.isEmpty else {
            throw WebBookError.emptyResponse
        }

        let preparedBody = applyPreUpdateJS(tocRule.preUpdateJs, body: body, baseUrl: redirectUrl)

        var chapters = try tocParser.parseChapters(
            body: preparedBody,
            baseUrl: redirectUrl,
            rule: tocRule,
            startIndex: 0
        )

        var pendingPageUrls = tocParser.parseNextPageUrls(body: preparedBody, baseUrl: redirectUrl, rule: tocRule)
        var visitedUrls: Set<String> = [redirectUrl]

        while !pendingPageUrls.isEmpty {
            let nextUrl = pendingPageUrls.removeFirst()
            guard !nextUrl.isEmpty, !visitedUrls.contains(nextUrl) else { continue }

            visitedUrls.insert(nextUrl)
            let nextAnalyzedUrl = AnalyzeUrl.analyze(
                ruleUrl: nextUrl,
                baseUrl: source.bookSourceUrl,
                source: source
            )
            var nextResponse = try await AnalyzeUrl.getResponseBody(analyzedUrl: nextAnalyzedUrl)
            nextResponse = applyLoginCheckIfNeeded(source: source, response: nextResponse)
            let nextBody = nextResponse.body
            let nextRedirectUrl = nextResponse.url
            guard !nextBody.isEmpty else { continue }

            visitedUrls.insert(nextRedirectUrl)
            let preparedNextBody = applyPreUpdateJS(tocRule.preUpdateJs, body: nextBody, baseUrl: nextRedirectUrl)
            let nextChapters = try tocParser.parseChapters(
                body: preparedNextBody,
                baseUrl: nextRedirectUrl,
                rule: tocRule,
                startIndex: chapters.count
            )
            chapters.append(contentsOf: nextChapters)

            let discoveredUrls = tocParser.parseNextPageUrls(body: preparedNextBody, baseUrl: nextRedirectUrl, rule: tocRule)
            for discoveredUrl in discoveredUrls where !visitedUrls.contains(discoveredUrl) {
                pendingPageUrls.append(discoveredUrl)
            }

            if visitedUrls.count >= 100 || chapters.count > 10000 {
                break
            }
        }

        return chapters
    }
    
    // MARK: - 获取正文
    
    /// 获取章节正文内容
    static func getContent(
        source: BookSource,
        book: Book,
        chapter: BookChapter
    ) async throws -> String {
        guard let contentRule = source.getContentRule() else {
            throw WebBookError.noRule("正文规则")
        }
        
        guard let ruleStr = contentRule.content, !ruleStr.isEmpty else {
            // 如果没有正文规则，直接返回章节 URL（可能就是内容本身）
            return chapter.chapterUrl
        }

        let body: String
        let redirectUrl: String

        if chapter.chapterUrl == book.bookUrl,
           let cachedTocHtml = book.tocHtml,
           !cachedTocHtml.isEmpty {
            body = cachedTocHtml
            redirectUrl = book.bookUrl
        } else {
            // 1. 请求正文页
            let analyzedUrl = AnalyzeUrl.analyze(
                ruleUrl: chapter.chapterUrl,
                baseUrl: source.bookSourceUrl,
                source: source
            )
            var response = try await AnalyzeUrl.getResponseBody(
                analyzedUrl: analyzedUrl,
                javaScript: contentRule.webJs,
                sourceRegex: contentRule.sourceRegex,
                forceWebView: !(contentRule.webJs?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ||
                    !(contentRule.sourceRegex?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            )
            response = applyLoginCheckIfNeeded(source: source, response: response)
            body = response.body
            redirectUrl = response.url
        }

        guard !body.isEmpty else {
            throw WebBookError.emptyResponse
        }
        
        // 2. 解析正文
        let context = ExecutionContext()
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let isJson = trimmedBody.hasPrefix("{") || trimmedBody.hasPrefix("[")
        
        if isJson {
            context.jsonString = body
        } else {
            context.document = try SwiftSoup.parse(body)
        }
        context.baseURL = URL(string: redirectUrl)
        
        let elementCtx = try makeElementContext(body: body, baseUrl: redirectUrl)
        
        var content = ruleEngine.getString(ruleStr: ruleStr, elementContext: elementCtx, baseUrl: redirectUrl)

        // 3. 处理正文分页（nextContentUrl）
        if let nextContentUrlRule = contentRule.nextContentUrl, !nextContentUrlRule.isEmpty {
            var visitedUrls: Set<String> = [redirectUrl]
            var pendingPages = extractNextContentUrls(
                rule: nextContentUrlRule,
                body: body,
                baseUrl: redirectUrl
            )

            while !pendingPages.isEmpty && visitedUrls.count < 50 {
                let nextUrl = pendingPages.removeFirst()
                guard !nextUrl.isEmpty, !visitedUrls.contains(nextUrl) else { continue }

                let nextAnalyzedUrl = AnalyzeUrl.analyze(
                    ruleUrl: nextUrl,
                    baseUrl: source.bookSourceUrl,
                    source: source
                )
                let result = try await AnalyzeUrl.getResponseBody(
                    analyzedUrl: nextAnalyzedUrl,
                    javaScript: contentRule.webJs,
                    sourceRegex: contentRule.sourceRegex,
                    forceWebView: !(contentRule.webJs?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ||
                        !(contentRule.sourceRegex?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                )
                let checkedResult = applyLoginCheckIfNeeded(source: source, response: result)
                let nextBody = checkedResult.body
                let nextRedirectUrl = checkedResult.url

                guard !nextBody.isEmpty, !visitedUrls.contains(nextRedirectUrl) else { continue }
                visitedUrls.insert(nextUrl)
                visitedUrls.insert(nextRedirectUrl)

                let nextElementCtxInner = try makeElementContext(body: nextBody, baseUrl: nextRedirectUrl)
                let nextContent = ruleEngine.getString(ruleStr: ruleStr, elementContext: nextElementCtxInner, baseUrl: nextRedirectUrl)

                if !nextContent.isEmpty {
                    content += "\n" + nextContent
                }

                let morePages = extractNextContentUrls(
                    rule: nextContentUrlRule,
                    body: nextBody,
                    baseUrl: nextRedirectUrl
                )
                for page in morePages where !visitedUrls.contains(page) {
                    pendingPages.append(page)
                }
            }
        }
        
// 4. 应用替换规则（净化）
        if let replaceRegex = contentRule.replaceRegex, !replaceRegex.isEmpty {
            content = applyReplaceRegex(content, regex: replaceRegex)
        }
        
        // 5. 保留图片标签（对齐 Android HtmlFormatter.formatKeepImg）
        let baseURL = URL(string: redirectUrl)
        content = HTMLToTextConverter.formatKeepImg(html: content, baseURL: baseURL)
        
        return content
    }

    private static func makeElementContext(body: String, baseUrl: String) throws -> ElementContext {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            let json = try JSONSerialization.jsonObject(with: body.data(using: .utf8) ?? Data())
            return ElementContext(element: json, baseUrl: baseUrl)
        }
        return ElementContext(element: try SwiftSoup.parse(body), baseUrl: baseUrl)
    }

    private static func extractNextContentUrls(rule: String, body: String, baseUrl: String) -> [String] {
        do {
            return try ruleEngine.getStringList(ruleStr: rule, body: body, baseUrl: baseUrl, isUrl: true)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0 != baseUrl }
        } catch {
            return []
        }
    }

    private static func applyLoginCheckIfNeeded(
        source: BookSource,
        response: (body: String, url: String)
    ) -> (body: String, url: String) {
        guard let checkJs = source.loginCheckJs?.trimmingCharacters(in: .whitespacesAndNewlines),
              !checkJs.isEmpty else {
            return response
        }

        let executionContext = ExecutionContext()
        executionContext.source = source
        executionContext.baseURL = URL(string: response.url)
        executionContext.variables["body"] = response.body
        executionContext.variables["url"] = response.url

        let jsContext = executionContext.jsContext
        jsContext.setValue(["body": response.body, "url": response.url], forKey: "result")
        jsContext.setValue(response.body, forKey: "body")
        jsContext.setValue(response.url, forKey: "url")

        guard let value = jsContext.evaluateScript(checkJs) else {
            return response
        }

        if let updated = parseLoginCheckResult(value, fallback: response) {
            return updated
        }

        return response
    }

    private static func parseLoginCheckResult(
        _ value: JSValue,
        fallback: (body: String, url: String)
    ) -> (body: String, url: String)? {
        if let dict = value.toDictionary() as? [String: Any] {
            let body = (dict["body"] as? String) ?? fallback.body
            let url = (dict["url"] as? String) ?? fallback.url
            return (body: body, url: url)
        }

        if let string = value.toString(), !string.isEmpty, string != "undefined", string != "null" {
            if let data = string.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let body = (dict["body"] as? String) ?? fallback.body
                let url = (dict["url"] as? String) ?? fallback.url
                return (body: body, url: url)
            }
            return (body: string, url: fallback.url)
        }

        return nil
    }

    private static func applyPreUpdateJS(_ js: String?, body: String, baseUrl: String) -> String {
        guard let js = js?.trimmingCharacters(in: .whitespacesAndNewlines), !js.isEmpty else {
            return body
        }

        let context = JSContext()
        context?.setValue(body, forKey: "body")
        context?.setValue(baseUrl, forKey: "baseUrl")
        if let result = context?.evaluateScript(js)?.toString(), !result.isEmpty {
            return result
        }
        return body
    }
    
    // MARK: - 解析书籍列表
    
    /// 从 HTML/JSON 中解析书籍列表（搜索结果/发现列表通用）
    private static func parseBookList(
        source: BookSource,
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
        let elements = try ruleEngine.getElements(
            ruleStr: bookListRule,
            body: body,
            baseUrl: baseUrl
        )
        
        var books: [SearchBookResult] = []
        
        for elementCtx in elements {
            var book = SearchBookResult()
            book.sourceUrl = source.bookSourceUrl
            book.sourceName = source.bookSourceName
            
            book.name = normalizeBookName(ruleEngine.getString(ruleStr: nameRule, elementContext: elementCtx, baseUrl: baseUrl))
            book.author = normalizeBookAuthor(ruleEngine.getString(ruleStr: authorRule, elementContext: elementCtx, baseUrl: baseUrl))
            let kindValue = ruleEngine.getString(ruleStr: kindRule, elementContext: elementCtx, baseUrl: baseUrl)
            if !kindValue.isEmpty {
                book.kind = kindValue
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: ",")
            }

            let parsedBookUrl = ruleEngine.getString(ruleStr: bookUrlRule, elementContext: elementCtx, baseUrl: baseUrl)
            book.bookUrl = parsedBookUrl.isEmpty ? baseUrl : parsedBookUrl

            let parsedCoverURL = ruleEngine.getString(ruleStr: coverUrlRule, elementContext: elementCtx, baseUrl: baseUrl)
            if !parsedCoverURL.isEmpty {
                book.coverUrl = URL(string: parsedCoverURL, relativeTo: URL(string: baseUrl))?.absoluteURL.absoluteString ?? parsedCoverURL
            }
            let parsedIntro = ruleEngine.getString(ruleStr: introRule, elementContext: elementCtx, baseUrl: baseUrl)
            book.intro = parsedIntro.isEmpty ? nil : normalizeIntro(parsedIntro)
            book.lastChapter = ruleEngine.getString(ruleStr: lastChapterRule, elementContext: elementCtx, baseUrl: baseUrl)
            let parsedWordCount = ruleEngine.getString(ruleStr: wordCountRule, elementContext: elementCtx, baseUrl: baseUrl)
            book.wordCount = parsedWordCount.isEmpty ? nil : formatWordCount(parsedWordCount)
            
            // 过滤无效结果
            if !book.name.isEmpty && !book.bookUrl.isEmpty {
                books.append(book)
            }
        }
        
        return books
    }

    private static func parseDetailPageAsSearchResult(
        source: BookSource,
        body: String,
        requestURL: String,
        redirectURL: String
    ) throws -> SearchBookResult? {
        guard let infoRule = source.getBookInfoRule() else { return nil }

        let isJson = body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") ||
            body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[")

        var elementCtx = ElementContext(
            element: isJson ? (try JSONSerialization.jsonObject(with: body.data(using: .utf8)!) as Any) :
                (try SwiftSoup.parse(body) as Any),
            baseUrl: redirectURL
        )

        if let initRule = infoRule.initRule?.trimmingCharacters(in: .whitespacesAndNewlines),
           !initRule.isEmpty,
           let initializedContext = try ruleEngine.getElements(ruleStr: initRule, body: body, baseUrl: redirectURL).first {
            elementCtx = initializedContext
        }

        var result = SearchBookResult()
        result.sourceUrl = source.bookSourceUrl
        result.sourceName = source.bookSourceName

        result.name = normalizeBookName(ruleEngine.getString(ruleStr: infoRule.name, elementContext: elementCtx, baseUrl: redirectURL))
        result.author = normalizeBookAuthor(ruleEngine.getString(ruleStr: infoRule.author, elementContext: elementCtx, baseUrl: redirectURL))
        let kindValue = ruleEngine.getString(ruleStr: infoRule.kind, elementContext: elementCtx, baseUrl: redirectURL)
        if !kindValue.isEmpty {
            result.kind = kindValue
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: ",")
        }
        result.lastChapter = ruleEngine.getString(ruleStr: infoRule.lastChapter, elementContext: elementCtx, baseUrl: redirectURL)
        let parsedWordCount = ruleEngine.getString(ruleStr: infoRule.wordCount, elementContext: elementCtx, baseUrl: redirectURL)
        result.wordCount = parsedWordCount.isEmpty ? nil : formatWordCount(parsedWordCount)
        let parsedIntro = ruleEngine.getString(ruleStr: infoRule.intro, elementContext: elementCtx, baseUrl: redirectURL)
        result.intro = parsedIntro.isEmpty ? nil : normalizeIntro(parsedIntro)

        let parsedCoverURL = ruleEngine.getString(ruleStr: infoRule.coverUrl, elementContext: elementCtx, baseUrl: redirectURL)
        if !parsedCoverURL.isEmpty {
            result.coverUrl = URL(string: parsedCoverURL, relativeTo: URL(string: redirectURL))?.absoluteURL.absoluteString ?? parsedCoverURL
        }

        result.bookUrl = redirectURL.isEmpty ? requestURL : redirectURL

        return result.name.isEmpty ? nil : result
    }

    private static func dedupeSearchResults(_ input: [SearchBookResult]) -> [SearchBookResult] {
        var seen: Set<String> = []
        var output: [SearchBookResult] = []

        for item in input {
            let key = "\(item.sourceUrl)|\(item.bookUrl)"
            if seen.insert(key).inserted {
                output.append(item)
            }
        }

        return output
    }

    private static func normalizeBookName(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeBookAuthor(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"^\s*作者\s*[:：\s]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeIntro(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if trimmed.contains("<") && trimmed.contains(">"),
           let document = try? SwiftSoup.parse(trimmed) {
            return (try? document.text())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? trimmed
        }

        return trimmed
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&ensp;", with: " ")
            .replacingOccurrences(of: "&emsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func formatWordCount(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let words = Int(trimmed), words > 0 else {
            return trimmed
        }

        if words >= 10_000 {
            let formatted = (Double(words) / 10_000.0 * 10).rounded() / 10
            let text = formatted.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(formatted))
                : String(format: "%.1f", formatted)
            return "\(text)万字"
        }

        return "\(words)字"
    }
    // MARK: - 替换正则
    
    private static func applyReplaceRegex(_ content: String, regex: String) -> String {
        let parts = RuleSplitter.splitTopLevel(regex, token: "##") ?? [regex]

        guard parts.count >= 2 else {
            if let reg = try? NSRegularExpression(pattern: regex) {
                let range = NSRange(content.startIndex..., in: content)
                return reg.stringByReplacingMatches(in: content, range: range, withTemplate: "")
            }
            return content.replacingOccurrences(of: regex, with: "")
        }

        let pattern = parts[0]
        let replacement = parts.count > 1 ? parts[1] : ""
        let firstOnly = parts.count > 2

        guard let reg = try? NSRegularExpression(pattern: pattern) else {
            return firstOnly ? replacement : content.replacingOccurrences(of: pattern, with: replacement)
        }

        let range = NSRange(content.startIndex..., in: content)
        if firstOnly {
            guard let match = reg.firstMatch(in: content, range: range),
                  let matchRange = Range(match.range, in: content) else {
                return ""
            }
            let firstMatch = String(content[matchRange])
            let firstRange = NSRange(firstMatch.startIndex..., in: firstMatch)
            return reg.stringByReplacingMatches(in: firstMatch, range: firstRange, withTemplate: replacement)
        }

        return reg.stringByReplacingMatches(in: content, range: range, withTemplate: replacement)
    }
}

// MARK: - 错误类型
enum WebBookError: LocalizedError {
    case noSearchUrl
    case noRule(String)
    case emptyResponse
    case parseFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .noSearchUrl: return "书源未配置搜索 URL"
        case .noRule(let name): return "书源未配置\(name)"
        case .emptyResponse: return "服务器响应为空"
        case .parseFailed(let msg): return "解析失败：\(msg)"
        }
    }
}
