import Foundation
import JavaScriptCore
import SwiftSoup

/// 规则引擎对外书籍操作入口 — 承接搜索/详情/目录/正文（含分页）
public enum RuleWebBook {

    private static let ruleEngine = RuleEngine()
    private static let tocParser = TocParser(ruleEngine: ruleEngine)

    // MARK: - 搜索

    public static func searchBook(
        source: any BridgeSourceProtocol,
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

        if let bookUrlPattern = source.bookUrlPattern,
           let regex = try? NSRegularExpression(pattern: bookUrlPattern) {
            let range = NSRange(redirectUrl.startIndex..., in: redirectUrl)
            if regex.firstMatch(in: redirectUrl, range: range) != nil,
               let direct = try parseDetailPageAsSearchResult(
                    source: source, body: body, requestURL: analyzedUrl.url, redirectURL: redirectUrl
               ) {
                return [direct]
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
           let direct = try parseDetailPageAsSearchResult(
                source: source, body: body, requestURL: analyzedUrl.url, redirectURL: redirectUrl
           ) {
            return [direct]
        }

        return dedupeSearchResults(results)
    }

    // MARK: - 发现

    /// 发现页列表；`url` 为空时使用源的 `exploreUrl`
    public static func exploreBook(
        source: any BridgeSourceProtocol,
        url: String? = nil,
        page: Int = 1
    ) async throws -> [SearchBookResult] {
        let exploreTarget = (url?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? source.exploreUrl
        guard let exploreTarget, !exploreTarget.isEmpty else {
            throw WebBookError.noRule("发现 URL（exploreUrl）")
        }

        let analyzedUrl = AnalyzeUrl.analyze(
            ruleUrl: exploreTarget,
            page: page,
            baseUrl: source.bookSourceUrl,
            source: source
        )
        var (body, redirectUrl) = try await AnalyzeUrl.getResponseBody(analyzedUrl: analyzedUrl)
        (body, redirectUrl) = applyLoginCheckIfNeeded(source: source, body: body, url: redirectUrl)
        guard !body.isEmpty else { throw WebBookError.emptyResponse }

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
           let direct = try parseDetailPageAsSearchResult(
                source: source, body: body, requestURL: analyzedUrl.url, redirectURL: redirectUrl
           ) {
            return [direct]
        }
        return dedupeSearchResults(results)
    }

    // MARK: - 详情

    @discardableResult
    public static func getBookInfo(
        source: any BridgeSourceProtocol,
        book: inout BridgeBook
    ) async throws -> BridgeBook {
        guard let infoRule = source.getBookInfoRule() else {
            throw WebBookError.noRule("书籍信息规则")
        }

        let analyzedUrl = AnalyzeUrl.analyze(
            ruleUrl: book.bookUrl,
            baseUrl: source.bookSourceUrl,
            source: source
        )
        var (body, redirectUrl) = try await AnalyzeUrl.getResponseBody(analyzedUrl: analyzedUrl)
        (body, redirectUrl) = applyLoginCheckIfNeeded(source: source, body: body, url: redirectUrl)
        guard !body.isEmpty else { throw WebBookError.emptyResponse }

        var elementCtx = try makeElementContext(body: body, baseUrl: redirectUrl)

        if let initRule = infoRule.initRule?.trimmingCharacters(in: .whitespacesAndNewlines),
           !initRule.isEmpty,
           let initialized = try ruleEngine.getElements(ruleStr: initRule, body: body, baseUrl: redirectUrl).first {
            elementCtx = initialized
        }

        let canRename = !(infoRule.canReName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

        if let name = infoRule.name {
            let parsed = normalizeBookName(ruleEngine.getString(ruleStr: name, elementContext: elementCtx, baseUrl: redirectUrl))
            if !parsed.isEmpty, (canRename || book.name.isEmpty) { book.name = parsed }
        }
        if let author = infoRule.author {
            let parsed = normalizeBookAuthor(ruleEngine.getString(ruleStr: author, elementContext: elementCtx, baseUrl: redirectUrl))
            if !parsed.isEmpty, (canRename || book.author.isEmpty) { book.author = parsed }
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
        if book.tocUrl.isEmpty { book.tocUrl = book.bookUrl }
        if book.tocUrl == book.bookUrl { book.tocHtml = body }
        if let lastChapter = infoRule.lastChapter {
            let parsed = ruleEngine.getString(ruleStr: lastChapter, elementContext: elementCtx, baseUrl: redirectUrl)
            if !parsed.isEmpty { book.latestChapterTitle = parsed }
        }
        if let wordCount = infoRule.wordCount {
            let parsed = ruleEngine.getString(ruleStr: wordCount, elementContext: elementCtx, baseUrl: redirectUrl)
            if !parsed.isEmpty { book.wordCount = formatWordCount(parsed) }
        }

        book.sourceUrl = source.bookSourceUrl
        book.sourceName = source.bookSourceName
        return book
    }

    // MARK: - 目录（含 nextTocUrl 分页）

    public static func getChapterList(
        source: any BridgeSourceProtocol,
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
            var (nextBody, nextRedirectUrl) = try await AnalyzeUrl.getResponseBody(analyzedUrl: nextAnalyzedUrl)
            (nextBody, nextRedirectUrl) = applyLoginCheckIfNeeded(source: source, body: nextBody, url: nextRedirectUrl)
            guard !nextBody.isEmpty else { continue }
            visitedUrls.insert(nextRedirectUrl)

            let preparedNext = applyPreUpdateJS(tocRule.preUpdateJs, body: nextBody, baseUrl: nextRedirectUrl)
            let nextChapters = try tocParser.parseChapters(
                body: preparedNext,
                baseUrl: nextRedirectUrl,
                rule: tocRule,
                startIndex: chapters.count
            )
            chapters.append(contentsOf: nextChapters)

            for discovered in tocParser.parseNextPageUrls(body: preparedNext, baseUrl: nextRedirectUrl, rule: tocRule)
            where !visitedUrls.contains(discovered) {
                pendingPageUrls.append(discovered)
            }

            if visitedUrls.count >= 100 || chapters.count > 10_000 { break }
        }

        return chapters.enumerated().map { idx, ch in
            BridgeChapter(title: ch.title, url: ch.url, index: idx)
        }
    }

    // MARK: - 正文（含 nextContentUrl 分页 + 内联图片）

    public static func getContent(
        source: any BridgeSourceProtocol,
        book: BridgeBook,
        chapter: BridgeChapter
    ) async throws -> String {
        guard let contentRule = source.getContentRule() else {
            throw WebBookError.noRule("正文规则")
        }
        guard let ruleStr = contentRule.content, !ruleStr.isEmpty else {
            return chapter.url
        }

        let body: String
        let redirectUrl: String

        if chapter.url == book.bookUrl, let cached = book.tocHtml, !cached.isEmpty {
            body = cached
            redirectUrl = book.bookUrl
        } else {
            let analyzedUrl = AnalyzeUrl.analyze(
                ruleUrl: chapter.url,
                baseUrl: source.bookSourceUrl,
                source: source
            )
            var (fetched, url) = try await AnalyzeUrl.getResponseBody(
                analyzedUrl: analyzedUrl,
                javaScript: contentRule.webJs,
                sourceRegex: contentRule.sourceRegex,
                forceWebView: !(contentRule.webJs?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                    || !(contentRule.sourceRegex?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            )
            (fetched, url) = applyLoginCheckIfNeeded(source: source, body: fetched, url: url)
            body = fetched
            redirectUrl = url
        }

        guard !body.isEmpty else { throw WebBookError.emptyResponse }

        let elementCtx = try makeElementContext(body: body, baseUrl: redirectUrl)
        var content = ruleEngine.getString(ruleStr: ruleStr, elementContext: elementCtx, baseUrl: redirectUrl)

        if let nextContentUrlRule = contentRule.nextContentUrl, !nextContentUrlRule.isEmpty {
            var visitedUrls: Set<String> = [redirectUrl]
            var pendingPages = extractNextContentUrls(rule: nextContentUrlRule, body: body, baseUrl: redirectUrl)

            while !pendingPages.isEmpty && visitedUrls.count < 50 {
                let nextUrl = pendingPages.removeFirst()
                guard !nextUrl.isEmpty, !visitedUrls.contains(nextUrl) else { continue }

                let nextAnalyzedUrl = AnalyzeUrl.analyze(
                    ruleUrl: nextUrl,
                    baseUrl: source.bookSourceUrl,
                    source: source
                )
                var (nextBody, nextRedirectUrl) = try await AnalyzeUrl.getResponseBody(
                    analyzedUrl: nextAnalyzedUrl,
                    javaScript: contentRule.webJs,
                    sourceRegex: contentRule.sourceRegex,
                    forceWebView: !(contentRule.webJs?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                        || !(contentRule.sourceRegex?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                )
                (nextBody, nextRedirectUrl) = applyLoginCheckIfNeeded(source: source, body: nextBody, url: nextRedirectUrl)
                guard !nextBody.isEmpty, !visitedUrls.contains(nextRedirectUrl) else { continue }
                visitedUrls.insert(nextUrl)
                visitedUrls.insert(nextRedirectUrl)

                let nextCtx = try makeElementContext(body: nextBody, baseUrl: nextRedirectUrl)
                let nextContent = ruleEngine.getString(ruleStr: ruleStr, elementContext: nextCtx, baseUrl: nextRedirectUrl)
                if !nextContent.isEmpty { content += "\n" + nextContent }

                for page in extractNextContentUrls(rule: nextContentUrlRule, body: nextBody, baseUrl: nextRedirectUrl)
                where !visitedUrls.contains(page) {
                    pendingPages.append(page)
                }
            }
        }

        if let replaceRegex = contentRule.replaceRegex, !replaceRegex.isEmpty {
            content = applyReplaceRegex(content, regex: replaceRegex)
        }

        content = HTMLToTextConverter.formatKeepImg(html: content, baseURL: URL(string: redirectUrl))
        return content
    }

    // MARK: - 本地规则解析（夹具 / 无网络）

    /// 对给定 body 执行规则，返回字符串结果（供确定性夹具）
    public static func evaluateString(
        rule: String,
        body: String,
        baseUrl: String = "https://fixture.local/",
        variables: [String: String] = [:]
    ) throws -> String {
        let ctx = try makeElementContext(body: body, baseUrl: baseUrl)
        if variables.isEmpty {
            return RuleEngine().getString(ruleStr: rule, elementContext: ctx, baseUrl: baseUrl)
        }
        // 有预置变量时走完整 ExecutionContext，供 @js / @get 夹具
        let engine = RuleEngine()
        let exec = ExecutionContext()
        exec.variables = variables
        exec.baseURL = URL(string: baseUrl)
        exec.document = ctx.element
        if let json = ctx.element as? [String: Any] {
            exec.jsonDict = json
            exec.jsonValue = json
        } else if let arr = ctx.element as? [Any] {
            exec.jsonValue = arr
        }
        let result = try engine.executeSingle(rule: rule, context: exec)
        switch result {
        case .string(let value): return value
        case .list(let values): return values.joined(separator: "\n")
        case .none: return ""
        }
    }

    public static func evaluateElementCount(
        rule: String,
        body: String,
        baseUrl: String = "https://fixture.local/"
    ) throws -> Int {
        try RuleEngine().getElements(ruleStr: rule, body: body, baseUrl: baseUrl).count
    }

    public static func evaluateStringList(
        rule: String,
        body: String,
        baseUrl: String = "https://fixture.local/",
        isUrl: Bool = false
    ) throws -> [String] {
        try RuleEngine().getStringList(ruleStr: rule, body: body, baseUrl: baseUrl, isUrl: isUrl)
    }

    /// 声明不支持能力并抛出可分类错误
    public static func rejectUnsupported(_ error: RuleCapabilityError) throws -> Never {
        throw WebBookError.unsupported(error)
    }

    // MARK: - 私有辅助

    private static func applyLoginCheckIfNeeded(
        source: any BridgeSourceProtocol,
        body: String,
        url: String
    ) -> (body: String, url: String) {
        guard let js = source.loginCheckJs?.trimmingCharacters(in: .whitespacesAndNewlines),
              !js.isEmpty else { return (body, url) }

        let executionContext = ExecutionContext()
        executionContext.source = source
        executionContext.baseURL = URL(string: url)
        executionContext.variables["body"] = body
        executionContext.variables["url"] = url

        let jsContext = executionContext.jsContext
        jsContext.setValue(["body": body, "url": url], forKey: "result")
        jsContext.setValue(body, forKey: "body")
        jsContext.setValue(url, forKey: "url")

        guard let value = jsContext.evaluateScript(js) else { return (body, url) }
        if let dict = value.toDictionary() as? [String: Any] {
            return (
                body: (dict["body"] as? String) ?? body,
                url: (dict["url"] as? String) ?? url
            )
        }
        if let string = value.toString(), !string.isEmpty, string != "undefined", string != "null" {
            if let data = string.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return (
                    body: (dict["body"] as? String) ?? body,
                    url: (dict["url"] as? String) ?? url
                )
            }
            return (body: string, url: url)
        }
        return (body, url)
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

    private static func parseBookList(
        source: any BridgeSourceProtocol,
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
            item.name = normalizeBookName(ruleEngine.getString(ruleStr: nameRule, elementContext: el, baseUrl: baseUrl))
            item.author = normalizeBookAuthor(ruleEngine.getString(ruleStr: authorRule, elementContext: el, baseUrl: baseUrl))
            let kindValue = ruleEngine.getString(ruleStr: kindRule, elementContext: el, baseUrl: baseUrl)
            if !kindValue.isEmpty {
                item.kind = kindValue
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: ",")
            }
            let parsedBookUrl = ruleEngine.getString(ruleStr: bookUrlRule, elementContext: el, baseUrl: baseUrl)
            item.bookUrl = parsedBookUrl.isEmpty ? baseUrl : parsedBookUrl
            let parsedCover = ruleEngine.getString(ruleStr: coverUrlRule, elementContext: el, baseUrl: baseUrl)
            if !parsedCover.isEmpty {
                item.coverUrl = URL(string: parsedCover, relativeTo: URL(string: baseUrl))?.absoluteURL.absoluteString ?? parsedCover
            }
            let parsedIntro = ruleEngine.getString(ruleStr: introRule, elementContext: el, baseUrl: baseUrl)
            item.intro = parsedIntro.isEmpty ? nil : normalizeIntro(parsedIntro)
            let last = ruleEngine.getString(ruleStr: lastChapterRule, elementContext: el, baseUrl: baseUrl)
            item.lastChapter = last.isEmpty ? nil : last
            let wc = ruleEngine.getString(ruleStr: wordCountRule, elementContext: el, baseUrl: baseUrl)
            item.wordCount = wc.isEmpty ? nil : formatWordCount(wc)

            if !item.name.isEmpty || !item.bookUrl.isEmpty {
                results.append(item)
            }
        }
        return results
    }

    private static func parseDetailPageAsSearchResult(
        source: any BridgeSourceProtocol,
        body: String,
        requestURL: String,
        redirectURL: String
    ) throws -> SearchBookResult? {
        guard let infoRule = source.getBookInfoRule() else { return nil }
        var elementCtx = try makeElementContext(body: body, baseUrl: redirectURL)
        if let initRule = infoRule.initRule?.trimmingCharacters(in: .whitespacesAndNewlines),
           !initRule.isEmpty,
           let initialized = try ruleEngine.getElements(ruleStr: initRule, body: body, baseUrl: redirectURL).first {
            elementCtx = initialized
        }

        var result = SearchBookResult()
        result.sourceUrl = source.bookSourceUrl
        result.sourceName = source.bookSourceName
        result.name = normalizeBookName(ruleEngine.getString(ruleStr: infoRule.name, elementContext: elementCtx, baseUrl: redirectURL))
        result.author = normalizeBookAuthor(ruleEngine.getString(ruleStr: infoRule.author, elementContext: elementCtx, baseUrl: redirectURL))
        result.bookUrl = redirectURL.isEmpty ? requestURL : redirectURL
        return result.name.isEmpty ? nil : result
    }

    private static func dedupeSearchResults(_ input: [SearchBookResult]) -> [SearchBookResult] {
        var seen: Set<String> = []
        var output: [SearchBookResult] = []
        for item in input {
            let key = "\(item.sourceUrl)|\(item.bookUrl)"
            if seen.insert(key).inserted { output.append(item) }
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
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func formatWordCount(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let words = Int(trimmed), words > 0 else { return trimmed }
        if words >= 10_000 {
            let formatted = (Double(words) / 10_000.0 * 10).rounded() / 10
            let text = formatted.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(formatted))
                : String(format: "%.1f", formatted)
            return "\(text)万字"
        }
        return "\(words)字"
    }

    /// 供测试与调试：源级 replaceRegex（`pattern##replacement`）
    public static func applyReplaceRegex(_ content: String, regex: String) -> String {
        let parts = RuleSplitter.splitTopLevel(regex, token: "##") ?? [regex]
        let pattern: String
        let replacement: String
        let firstOnly: Bool
        if parts.count >= 2 {
            pattern = parts[0]
            replacement = parts[1]
            firstOnly = parts.count > 2
        } else {
            pattern = regex
            replacement = ""
            firstOnly = false
        }
        // 兼容书源里常用的 [\s\S]：部分 ICU 下字符类异常时改为 . + DOTALL
        let patternsToTry = [pattern, pattern.replacingOccurrences(of: "[\\s\\S]", with: ".")]
        var reg: NSRegularExpression?
        for p in patternsToTry {
            if let compiled = try? NSRegularExpression(
                pattern: p,
                options: [.dotMatchesLineSeparators]
            ) {
                reg = compiled
                break
            }
        }
        guard let reg else {
            return firstOnly ? replacement : content.replacingOccurrences(of: pattern, with: replacement)
        }
        let range = NSRange(content.startIndex..., in: content)
        if firstOnly {
            guard let match = reg.firstMatch(in: content, range: range),
                  let matchRange = Range(match.range, in: content) else { return content }
            let replaced = reg.stringByReplacingMatches(
                in: String(content[matchRange]),
                range: NSRange(location: 0, length: (content[matchRange] as NSString).length),
                withTemplate: replacement
            )
            return content.replacingCharacters(in: matchRange, with: replaced)
        }
        return reg.stringByReplacingMatches(in: content, range: range, withTemplate: replacement)
    }
}

/// 与 legado-ios WebBook / Bridge 兼容的搜索结果
public struct SearchBookResult {
    public var name: String = ""
    public var author: String = ""
    public var kind: String?
    public var bookUrl: String = ""
    public var coverUrl: String?
    public var intro: String?
    public var lastChapter: String?
    public var wordCount: String?
    public var sourceUrl: String = ""
    public var sourceName: String = ""

    public init() {}
}
