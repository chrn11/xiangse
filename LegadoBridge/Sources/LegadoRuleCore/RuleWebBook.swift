import Foundation
import JavaScriptCore
import SwiftSoup
import LegadoObjCSupport

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

        // 探针必须在空 body 早退之前：否则 ok total=0 前看不到 URL/Cookie/长度
        Self.writeSearchAnalyzedProbe(analyzedUrl: analyzedUrl, source: source, key: key)

        var (body, redirectUrl) = try await AnalyzeUrl.getResponseBody(
            analyzedUrl: analyzedUrl,
            source: source
        )
        (body, redirectUrl) = applyLoginCheckIfNeeded(source: source, body: body, url: redirectUrl)

        Self.writeSearchBodyProbe(
            sourceUrl: source.bookSourceUrl,
            key: key,
            requestUrl: analyzedUrl.url,
            redirectUrl: redirectUrl,
            body: body,
            headers: analyzedUrl.headers
        )

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
        Self.writeSearchParseProbe(
            sourceUrl: source.bookSourceUrl,
            key: key,
            elementHint: (try? ruleEngine.getElements(
                ruleStr: "class.res-book-item", body: body, baseUrl: redirectUrl, source: source
            ).count) ?? -1,
            results: results
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

    /// 发现分类项：标签名 + 请求 URL（对齐香色/Legado explore 分类标签）
    public struct ExploreKind: Equatable {
        public let title: String
        public let url: String
        public init(title: String, url: String) {
            self.title = title
            self.url = url
        }
    }

    /// exploreUrl 是否以顶层 `@js:` / `<js>` 脚本开头（须求值后再解析分类）。
    public static func isTopLevelExploreJS(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()
        return lower.hasPrefix("@js:") || lower.hasPrefix("<js>")
    }

    /// 解析 exploreUrl 为全部分类（名::url 多行 / && 分隔 / JSON kinds / 单 URL）。
    /// - Note: 无 `source` 时不执行顶层 JS，仅做结构解析（并跳过 `//` 注释行）。
    public static func parseExploreKinds(_ raw: String) -> [ExploreKind] {
        parseExploreKinds(raw, source: nil, evaluateJS: false)
    }

    /// 解析 exploreUrl；`evaluateJS == true` 且为顶层 JS 时，用绑定了 source 的 JSContext 求值后再结构解析。
    /// JS 失败 / 超时 → 返回空数组（不崩、不产出 `//` 垃圾标题或整段脚本当 URL）。
    public static func parseExploreKinds(
        _ raw: String,
        source: (any BridgeSourceProtocol)?,
        evaluateJS: Bool = true,
        jsTimeoutSeconds: TimeInterval = 8
    ) -> [ExploreKind] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var text = trimmed
        if evaluateJS, isTopLevelExploreJS(text) {
            guard let evaluated = evaluateExploreUrlJS(
                text,
                source: source,
                timeoutSeconds: jsTimeoutSeconds
            ) else {
                return []
            }
            text = evaluated.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !isTopLevelExploreJS(text) else { return [] }
        }

        return parseExploreKindsStructural(text)
    }

    /// 结构解析（JSON / 多行名::url / 单 URL）；跳过 `//`、`°`、`☆` 行。
    public static func parseExploreKindsStructural(_ raw: String) -> [ExploreKind] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // JSON kinds：[{ "title":"…", "url":"/path/{{page}}.html", "style":{…} }, …]
        // style 仅影响阅读 App 布局，这里只取 title/url（换源分类仍完整）
        if trimmed.hasPrefix("[") {
            var out: [ExploreKind] = []
            if let data = trimmed.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for item in arr {
                    let u = ((item["url"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !u.isEmpty else { continue }
                    let tRaw = (item["title"] as? String)
                        ?? (item["name"] as? String)
                        ?? ""
                    let t = tRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                    out.append(ExploreKind(title: t.isEmpty ? "分类\(out.count + 1)" : t, url: u))
                }
            }
            return out
        }

        // 阅读官方格式一：可用换行或 && 分隔多条「名称::url」
        let normalized = trimmed
            .replacingOccurrences(of: "&&", with: "\n")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        if normalized.contains("::") && (normalized.contains("\n") || normalized != trimmed || trimmed.contains("&&")) {
            var out: [ExploreKind] = []
            for line in normalized.components(separatedBy: "\n") {
                let l = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !l.isEmpty else { continue }
                guard !l.hasPrefix("°"), !l.hasPrefix("☆"), !l.hasPrefix("//") else { continue }
                guard let range = l.range(of: "::") else { continue }
                let title = String(l[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let u = String(l[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !u.isEmpty else { continue }
                out.append(ExploreKind(title: title.isEmpty ? "分类\(out.count + 1)" : title, url: u))
            }
            if !out.isEmpty { return out }
        }

        // 单行 名::url
        if trimmed.contains("::"), !trimmed.lowercased().hasPrefix("http"), !trimmed.hasPrefix("/") {
            if let range = trimmed.range(of: "::") {
                let title = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let u = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !u.isEmpty, !title.hasPrefix("//") {
                    return [ExploreKind(title: title.isEmpty ? "发现" : title, url: u)]
                }
            }
        }

        // 顶层 JS 原文不得塌缩成「发现」伪分类
        if isTopLevelExploreJS(trimmed) {
            return []
        }

        return [ExploreKind(title: "发现", url: trimmed)]
    }

    /// 把 exploreUrl 收成可请求的单条地址（取 parseExploreKinds 第一项）。
    public static func resolveExploreFetchURL(_ raw: String) -> String? {
        parseExploreKinds(raw).first?.url
    }

    /// 相对路径按 bookSourceUrl 拼绝对地址（泛化原 lysxh 硬编码）。
    public static func absoluteExploreURL(baseUrl: String, path: String) -> String {
        AnalyzeUrl.absoluteURL(baseUrl: baseUrl, path)
    }

    // MARK: - exploreUrl 顶层 JS

    private static func extractExploreJSCode(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("@js:") {
            return String(trimmed.dropFirst(4))
        }
        if trimmed.lowercased().hasPrefix("<js>") {
            var code = String(trimmed.dropFirst(4))
            if code.lowercased().hasSuffix("</js>") {
                code = String(code.dropLast(5))
            }
            return code
        }
        return trimmed
    }

    /// 求值 exploreUrl 顶层 JS；超时或失败返回 nil。
    private static func evaluateExploreUrlJS(
        _ raw: String,
        source: (any BridgeSourceProtocol)?,
        timeoutSeconds: TimeInterval
    ) -> String? {
        let code = extractExploreJSCode(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return nil }

        // 用 eval 取脚本完成值（对齐 AnalyzeUrl.analyzeJs）；数组/对象再 JSON.stringify。
        var jsonErr: NSString?
        guard let codeJSON = ObjCExceptionCatch.jsonStringLiteral(code, error: &jsonErr) as String? else {
            return nil
        }
        let wrapped = """
        (function(){
          var __exploreOut = eval(\(codeJSON));
          if (__exploreOut === undefined || __exploreOut === null) return '';
          if (typeof __exploreOut === 'string') return __exploreOut;
          try { return JSON.stringify(__exploreOut); } catch (e) { return String(__exploreOut); }
        })()
        """

        let baseUrl = source?.bookSourceUrl ?? ""
        let seedUrl = baseUrl.isEmpty ? "https://localhost/" : baseUrl
        let timeout = max(0.5, timeoutSeconds)

        final class Box: @unchecked Sendable {
            var value: String?
            let lock = NSLock()
        }
        let box = Box()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            let analyzer = AnalyzeUrl(
                mUrl: seedUrl,
                key: nil,
                page: 1,
                baseUrl: baseUrl,
                source: source
            )
            var err: String?
            guard let out = analyzer.evalJS(wrapped, result: nil, errorOut: &err, lite: false) else {
                return
            }
            let text: String
            if let s = out as? String {
                text = s
            } else {
                text = String(describing: out)
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  trimmed != "null",
                  trimmed != "undefined",
                  !trimmed.hasPrefix("@js:"),
                  !trimmed.hasPrefix("<js>") else {
                return
            }
            box.lock.lock()
            box.value = trimmed
            box.lock.unlock()
        }
        let waited = group.wait(timeout: .now() + timeout)
        if waited == .timedOut {
            return nil
        }
        box.lock.lock()
        defer { box.lock.unlock() }
        return box.value
    }

    /// 发现页列表；`url` 为空时使用源的 `exploreUrl`（自动展开分类表）
    public static func exploreBook(
        source: any BridgeSourceProtocol,
        url: String? = nil,
        page: Int = 1
    ) async throws -> [SearchBookResult] {
        let rawTarget = (url?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? source.exploreUrl
        guard let rawTarget, !rawTarget.isEmpty else {
            throw WebBookError.noRule("发现 URL（exploreUrl）")
        }
        guard let exploreTarget = resolveExploreFetchURL(rawTarget), !exploreTarget.isEmpty else {
            throw WebBookError.noRule("发现 URL（exploreUrl 分类表无可用地址）")
        }

        let analyzedUrl = AnalyzeUrl.analyze(
            ruleUrl: exploreTarget,
            page: page,
            baseUrl: source.bookSourceUrl,
            source: source
        )
        var (body, redirectUrl) = try await AnalyzeUrl.getResponseBody(
            analyzedUrl: analyzedUrl,
            source: source
        )
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
        ruleEngine.bindBook(bookUrl: book.bookUrl, bookName: book.name, source: source)
        defer { ruleEngine.clearBoundBook() }
        guard let infoRule = source.getBookInfoRule() else {
            throw WebBookError.noRule("书籍信息规则")
        }

        let analyzedUrl = AnalyzeUrl.analyze(
            ruleUrl: book.bookUrl,
            baseUrl: source.bookSourceUrl,
            source: source
        )
        var (body, redirectUrl) = try await AnalyzeUrl.getResponseBody(
            analyzedUrl: analyzedUrl,
            source: source
        )
        (body, redirectUrl) = applyLoginCheckIfNeeded(source: source, body: body, url: redirectUrl)
        // 真机：Documents/legado_bookinfo_body_probe.txt —— 区分 CF/空体/解析崩
        Self.writeBookInfoBodyProbe(bookUrl: book.bookUrl, redirectUrl: redirectUrl, body: body)
        guard !body.isEmpty else { throw WebBookError.emptyResponse }

        var elementCtx: ElementContext
        do {
            elementCtx = try makeElementContext(body: body, baseUrl: redirectUrl)
        } catch {
            throw WebBookError.parseFailed(
                "详情 HTML 解析失败: \(error.localizedDescription) bodyLen=\(body.count) head=\(String(body.prefix(120)).replacingOccurrences(of: "\n", with: " "))"
            )
        }

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
                let absolute = URL(string: parsed, relativeTo: URL(string: redirectUrl))?.absoluteURL.absoluteString ?? parsed
                book.coverUrl = CoverDecodeHelper.decodeCoverURL(
                    absolute,
                    decodeJs: source.coverDecodeJs,
                    baseUrl: redirectUrl,
                    source: source
                )
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
        book.variable = BookVariableStore.jsonString(for: book.bookUrl)
        return book
    }

    // MARK: - 目录（含 nextTocUrl 分页）

    public static func getChapterList(
        source: any BridgeSourceProtocol,
        book: BridgeBook
    ) async throws -> [BridgeChapter] {
        ruleEngine.bindBook(bookUrl: book.bookUrl, bookName: book.name, source: source)
        defer { ruleEngine.clearBoundBook() }
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
            var (fetchedBody, fetchedUrl) = try await AnalyzeUrl.getResponseBody(
                analyzedUrl: analyzedUrl,
                source: source
            )
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
        // 真机：Documents/legado_catalog_body_probe.txt —— 区分「未拉到 TOC」与「拉到但解析 0 章」
        Self.writeCatalogBodyProbe(
            bookUrl: book.bookUrl,
            tocUrl: tocUrl,
            redirectUrl: redirectUrl,
            body: preparedBody,
            chapterListRule: tocRule.bookList ?? tocRule.chapterList,
            chapterCount: chapters.count,
            firstTitle: chapters.first?.title
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
            var (nextBody, nextRedirectUrl) = try await AnalyzeUrl.getResponseBody(
                analyzedUrl: nextAnalyzedUrl,
                source: source
            )
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
        ruleEngine.bindBook(bookUrl: book.bookUrl, bookName: book.name, source: source)
        defer { ruleEngine.clearBoundBook() }
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
                    || !(contentRule.sourceRegex?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
                source: source
            )
            (fetched, url) = applyLoginCheckIfNeeded(source: source, body: fetched, url: url)
            body = fetched
            redirectUrl = url
        }

        Self.writeContentBodyProbe(
            chapterUrl: chapter.url,
            redirectUrl: redirectUrl,
            body: body,
            contentRule: ruleStr
        )
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
                        || !(contentRule.sourceRegex?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
                    source: source
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

    // MARK: - 书评

    /// 拉取书评列表（最小实现：reviewUrl + 列表规则解析）
    public static func fetchReviews(
        source: any BridgeSourceProtocol,
        bookUrl: String
    ) async throws -> [BookReview] {
        guard let reviewRule = source.getReviewRule(),
              let reviewUrlRule = reviewRule.reviewUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reviewUrlRule.isEmpty else {
            throw WebBookError.noRule("书评规则")
        }

        ruleEngine.bindBook(bookUrl: bookUrl, source: source)
        defer { ruleEngine.clearBoundBook() }

        let analyzedUrl = AnalyzeUrl.analyze(
            ruleUrl: reviewUrlRule,
            key: bookUrl,
            baseUrl: bookUrl.isEmpty ? source.bookSourceUrl : bookUrl,
            source: source
        )
        var (body, redirectUrl) = try await AnalyzeUrl.getResponseBody(
            analyzedUrl: analyzedUrl,
            source: source
        )
        (body, redirectUrl) = applyLoginCheckIfNeeded(source: source, body: body, url: redirectUrl)
        guard !body.isEmpty else { throw WebBookError.emptyResponse }
        return try parseReviews(body: body, baseUrl: redirectUrl, reviewRule: reviewRule, source: source)
    }

    /// 本地夹具：无网络解析书评
    public static func parseReviews(
        body: String,
        baseUrl: String,
        reviewRule: BridgeReviewRule,
        source: (any BridgeSourceProtocol)? = nil
    ) throws -> [BookReview] {
        let listRule = "class.review-item"
        let elements = try ruleEngine.getElements(ruleStr: listRule, body: body, baseUrl: baseUrl, source: source)
        var reviews: [BookReview] = []
        let avatarRule = reviewRule.avatarRule ?? "class.avatar@src"
        let textRule = reviewRule.contentRule ?? "class.content@text"
        for el in elements {
            let avatarRaw = ruleEngine.getString(ruleStr: avatarRule, elementContext: el, baseUrl: baseUrl)
            let content = ruleEngine.getString(ruleStr: textRule, elementContext: el, baseUrl: baseUrl)
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let avatar: String
            if avatarRaw.isEmpty {
                avatar = ""
            } else {
                avatar = URL(string: avatarRaw, relativeTo: URL(string: baseUrl))?.absoluteURL.absoluteString ?? avatarRaw
            }
            let raw: String
            if let soup = el.element as? Element {
                raw = (try? soup.outerHtml()) ?? trimmed
            } else {
                raw = trimmed
            }
            reviews.append(BookReview(avatar: avatar, content: trimmed, raw: raw))
        }
        return reviews
    }

    // MARK: - 本地规则解析（夹具 / 无网络）

    /// 对给定 body 执行规则，返回字符串结果（供确定性夹具）
    public static func evaluateString(
        rule: String,
        body: String,
        baseUrl: String = "https://fixture.local/",
        variables: [String: String] = [:],
        bookUrl: String? = nil,
        source: (any BridgeSourceProtocol)? = nil
    ) throws -> String {
        let ctx = try makeElementContext(body: body, baseUrl: baseUrl)
        if variables.isEmpty && (bookUrl == nil || bookUrl?.isEmpty == true) && source == nil {
            return RuleEngine().getString(ruleStr: rule, elementContext: ctx, baseUrl: baseUrl)
        }
        // 有预置变量 / 书本上下文时走完整 ExecutionContext，供 @js / @get / bookVariable 夹具
        let engine = RuleEngine()
        if let bookUrl, !bookUrl.isEmpty {
            engine.bindBook(bookUrl: bookUrl, source: source)
        }
        defer { engine.clearBoundBook() }
        let exec = ExecutionContext()
        exec.variables = variables
        exec.baseURL = URL(string: baseUrl)
        exec.document = ctx.element
        exec.bookUrl = bookUrl
        exec.source = source
        if let bookUrl, !bookUrl.isEmpty {
            for (k, v) in BookVariableStore.variables(for: bookUrl) {
                if exec.variables[k] == nil { exec.variables[k] = v }
            }
        }
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
        // Legado 仓源写 result.body()/result.url()；用 block 闭包，避免全局变量被 JSC/禁令清掉
        let bodyCopy = body
        let urlCopy = url
        let resultObj = JSValue(newObjectIn: jsContext)!
        let bodyBlock: @convention(block) () -> String = { bodyCopy }
        let urlBlock: @convention(block) () -> String = { urlCopy }
        let headerBlock: @convention(block) () -> String = { "" }
        resultObj.setObject(bodyBlock, forKeyedSubscript: "body" as NSString)
        resultObj.setObject(urlBlock, forKeyedSubscript: "url" as NSString)
        resultObj.setObject(headerBlock, forKeyedSubscript: "header" as NSString)
        jsContext.setObject(resultObj, forKeyedSubscript: "result" as NSString)
        jsContext.setValue(body, forKey: "body")
        jsContext.setValue(url, forKey: "url")

        var jsError: String?
        jsContext.exceptionHandler = { _, ex in jsError = ex?.toString() }
        guard let value = jsContext.evaluateScript(js) else {
            Self.writeLoginCheckProbe(url: url, jsError: jsError ?? "nil_return", bodyLen: body.count)
            return (body, url)
        }
        if let jsError, !jsError.isEmpty {
            Self.writeLoginCheckProbe(url: url, jsError: jsError, bodyLen: body.count)
        }

        if let parsed = parseLoginCheckJSValue(value, fallbackBody: body, fallbackUrl: url) {
            return parsed
        }
        return (body, url)
    }

    /// 解析 loginCheckJs 返回值：字符串正文 / {body,url} 字典 / 带 body() 的对象
    private static func parseLoginCheckJSValue(
        _ value: JSValue,
        fallbackBody: String,
        fallbackUrl: String
    ) -> (body: String, url: String)? {
        if value.isString, let string = value.toString(), !string.isEmpty,
           string != "undefined", string != "null" {
            if let data = string.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return (
                    body: (dict["body"] as? String) ?? fallbackBody,
                    url: (dict["url"] as? String) ?? fallbackUrl
                )
            }
            return (body: string, url: fallbackUrl)
        }
        if let dict = value.toDictionary() as? [String: Any] {
            let b = (dict["body"] as? String) ?? fallbackBody
            let u = (dict["url"] as? String) ?? fallbackUrl
            if b != fallbackBody || u != fallbackUrl || dict["body"] is String {
                return (body: b, url: u)
            }
        }
        if value.isObject {
            if let bodyVal = value.invokeMethod("body", withArguments: []),
               let s = bodyVal.toString(), !s.isEmpty, s != "undefined", s != "null" {
                let u = value.invokeMethod("url", withArguments: [])?.toString()
                let urlOut = (u?.isEmpty == false && u != "undefined" && u != "null") ? u! : fallbackUrl
                return (body: s, url: urlOut)
            }
        }
        return nil
    }

    private static func writeLoginCheckProbe(url: String, jsError: String, bodyLen: Int) {
        let path = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Documents/legado_login_check_probe.txt")
        let line = "ts=\(Date()) url=\(url) bodyLen=\(bodyLen) jsError=\(jsError)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: path),
               let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? line.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }

    private static func writeBookInfoBodyProbe(bookUrl: String, redirectUrl: String, body: String) {
        let path = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Documents/legado_bookinfo_body_probe.txt")
        let head = String(body.prefix(900))
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let lower = body.lowercased()
        let flags = [
            "cf=\(lower.contains("just a moment") || lower.contains("cloudflare") || lower.contains("cf-browser"))",
            "hasTop=\(body.contains("class=\"top\"") || body.contains("class='top'"))",
            "hasSection=\(body.contains("section-box"))",
            "hasContent=\(body.contains("id=\"content\"") || body.contains("id='content'"))",
        ].joined(separator: " ")
        let line = """
        ts=\(Date())
        book=\(bookUrl)
        redirect=\(redirectUrl)
        bodyLen=\(body.count)
        \(flags)
        head=\(head)

        """
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private static func writeContentBodyProbe(
        chapterUrl: String,
        redirectUrl: String,
        body: String,
        contentRule: String
    ) {
        let path = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Documents/legado_content_body_probe.txt")
        let head = String(body.prefix(900))
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let lower = body.lowercased()
        let cf = lower.contains("just a moment") || lower.contains("cloudflare") || lower.contains("cf-browser")
        let hasContentId = body.contains("id=\"content\"") || body.contains("id='content'")
        let ruleHead = String(contentRule.prefix(120))
        let line = """
        ts=\(Date())
        chapter=\(chapterUrl)
        redirect=\(redirectUrl)
        bodyLen=\(body.count)
        rule=\(ruleHead)
        cf=\(cf) hasContentId=\(hasContentId)
        head=\(head)

        """
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// 搜索请求对照探针（空 body 前就会写）：Documents/legado_search_analyzed_url.txt
    private static func writeSearchAnalyzedProbe(
        analyzedUrl: AnalyzedUrl,
        source: any BridgeSourceProtocol,
        key: String
    ) {
        let jarHost = URL(string: source.bookSourceUrl)?.host ?? source.bookSourceUrl
        let jarCookie = CookieManager.shared.getCookie(for: jarHost)
            ?? CookieManager.shared.getCookie(for: source.bookSourceUrl)
            ?? ""
        let headerCookie = analyzedUrl.headers["Cookie"] ?? ""
        let path = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Documents/legado_search_analyzed_url.txt")
        let line = """
        ts=\(Date())
        url=\(analyzedUrl.url)
        key=\(key)
        src=\(source.bookSourceUrl)
        method=\(analyzedUrl.method.rawValue)
        jarHost=\(jarHost)
        jarCookieLen=\(jarCookie.count)
        headerCookieLen=\(headerCookie.count)
        cookieLikelyAttached=\(!jarCookie.isEmpty || !headerCookie.isEmpty)
        hasUndefined=\(analyzedUrl.url.contains("undefined"))

        """
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// 目录 TOC 对照探针：Documents/legado_catalog_body_probe.txt
    private static func writeCatalogBodyProbe(
        bookUrl: String,
        tocUrl: String,
        redirectUrl: String,
        body: String,
        chapterListRule: String?,
        chapterCount: Int,
        firstTitle: String?
    ) {
        let path = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Documents/legado_catalog_body_probe.txt")
        let head = body.count > 800 ? String(body.prefix(800)) : body
        let compactHead = head
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let ddCount = body.components(separatedBy: "<dd").count - 1
        let listId = body.contains("id=\"list\"") || body.contains("id='list'")
        let line = """
        ts=\(Date())
        book=\(bookUrl)
        toc=\(tocUrl)
        redirect=\(redirectUrl)
        bodyLen=\(body.count)
        hasListId=\(listId)
        ddApprox=\(ddCount)
        chapterListRule=\(chapterListRule ?? "")
        chapterCount=\(chapterCount)
        first=\(firstTitle ?? "")
        head=\(compactHead)

        """
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// 搜索响应对照探针：Documents/legado_search_body_probe.txt（空 body 也会写）
    private static func writeSearchBodyProbe(
        sourceUrl: String,
        key: String,
        requestUrl: String,
        redirectUrl: String,
        body: String,
        headers: [String: String]
    ) {
        let path = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Documents/legado_search_body_probe.txt")
        let hasBuid = body.contains("var buid")
        let hasList = body.contains("res-book-item")
        let jarHost = URL(string: sourceUrl)?.host ?? sourceUrl
        let jarCookie = CookieManager.shared.getCookie(for: jarHost)
            ?? CookieManager.shared.getCookie(for: sourceUrl)
            ?? ""
        let headerCookie = headers["Cookie"] ?? ""
        let head = body.count > 1200 ? String(body.prefix(1200)) : body
        let compactHead = head
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        // 解析探针：直接 class.res-book-item 与 JS bookList 路径各计一次
        let directCount = (try? RuleEngine().getElements(
            ruleStr: "class.res-book-item", body: body, baseUrl: sourceUrl
        ).count) ?? -1
        let line = """
        ts=\(Date())
        src=\(sourceUrl)
        key=\(key)
        request=\(requestUrl)
        redirect=\(redirectUrl)
        len=\(body.count)
        jarCookieLen=\(jarCookie.count)
        headerCookieLen=\(headerCookie.count)
        cookieAttached=\(!jarCookie.isEmpty || !headerCookie.isEmpty)
        has_buid=\(hasBuid)
        has_res_book_item=\(hasList)
        hasUndefined=\(requestUrl.contains("undefined") || redirectUrl.contains("undefined"))
        direct_class_count=\(directCount)
        head=\(compactHead)

        """
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// 搜索解析探针：Documents/legado_search_parse_probe.txt
    private static func writeSearchParseProbe(
        sourceUrl: String,
        key: String,
        elementHint: Int,
        results: [SearchBookResult]
    ) {
        let path = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Documents/legado_search_parse_probe.txt")
        let samples = results.prefix(5).enumerated().map { idx, r in
            "[\(idx)] name=\(r.name) url=\(r.bookUrl)"
        }.joined(separator: "\n")
        let line = """
        ts=\(Date())
        src=\(sourceUrl)
        key=\(key)
        direct_class_count=\(elementHint)
        parsed_count=\(results.count)
        samples:
        \(samples.isEmpty ? "(none)" : samples)

        """
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
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

        let elements = try ruleEngine.getElements(
            ruleStr: bookListRule,
            body: body,
            baseUrl: baseUrl,
            source: source
        )
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
            // 勿用列表页 baseUrl 填空 bookUrl：否则 10 条会去重成 1 条
            item.bookUrl = parsedBookUrl
            let parsedCover = ruleEngine.getString(ruleStr: coverUrlRule, elementContext: el, baseUrl: baseUrl)
            if !parsedCover.isEmpty {
                let absolute = URL(string: parsedCover, relativeTo: URL(string: baseUrl))?.absoluteURL.absoluteString ?? parsedCover
                item.coverUrl = CoverDecodeHelper.decodeCoverURL(
                    absolute,
                    decodeJs: source.coverDecodeJs,
                    baseUrl: baseUrl,
                    source: source
                )
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
        // 字段级对照：elements 数 vs 入选数（写在 parse 探针前由调用方汇总）
        if results.count <= 1, elements.count > 1 {
            let path = (NSHomeDirectory() as NSString)
                .appendingPathComponent("Documents/legado_search_field_probe.txt")
            var lines: [String] = [
                "ts=\(Date())",
                "elements=\(elements.count)",
                "kept=\(results.count)",
                "nameRule=\(nameRule ?? "")",
                "bookUrlRule=\(bookUrlRule ?? "")"
            ]
            for (idx, el) in elements.prefix(5).enumerated() {
                let n = ruleEngine.getString(ruleStr: nameRule, elementContext: el, baseUrl: baseUrl)
                let u = ruleEngine.getString(ruleStr: bookUrlRule, elementContext: el, baseUrl: baseUrl)
                let kind: String
                if el.element is Element { kind = "Element" }
                else if el.element is String { kind = "String" }
                else { kind = String(describing: type(of: el.element)) }
                lines.append("[\(idx)] type=\(kind) name=\(n) url=\(u)")
            }
            try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
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
            // bookUrl 为空时用 name 区分，避免 10 本空 url 去重成 1
            let key: String
            if item.bookUrl.isEmpty {
                key = "\(item.sourceUrl)|name:\(item.name)|author:\(item.author)"
            } else {
                key = "\(item.sourceUrl)|\(item.bookUrl)"
            }
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

    /// 供测试与调试：源级 replaceRegex。
    /// 支持 `pattern##replacement`、`pattern##`（替换为空）、`##pattern##` / `##pattern##replacement`（Legado 仓源常见前缀）。
    public static func applyReplaceRegex(_ content: String, regex: String) -> String {
        var raw = regex.trimmingCharacters(in: .whitespacesAndNewlines)
        // 前导 `##`：整段是替换规则，不是「空 pattern」
        if raw.hasPrefix("##") {
            raw = String(raw.dropFirst(2))
        }
        let pattern: String
        let replacement: String
        let firstOnly: Bool
        if raw.contains("##") {
            // 保留空 replacement（`pattern##` / `pattern##` 尾）
            let segs = splitReplaceRegexKeepEmpty(raw)
            pattern = segs.pattern
            replacement = segs.replacement
            firstOnly = segs.firstOnly
        } else {
            pattern = raw
            replacement = ""
            firstOnly = false
        }
        // 空 pattern 时 `replacingOccurrences(of:"")` 会把 replacement 写进正文（领域源 bodyLen=16 即此）
        guard !pattern.isEmpty else { return content }
        let patternsToTry = [pattern, pattern.replacingOccurrences(of: "[\\s\\S]", with: ".")]
        var reg: NSRegularExpression?
        for p in patternsToTry where !p.isEmpty {
            if let compiled = try? NSRegularExpression(
                pattern: p,
                options: [.dotMatchesLineSeparators]
            ) {
                reg = compiled
                break
            }
        }
        guard let reg else {
            return content.replacingOccurrences(of: pattern, with: replacement)
        }
        let range = NSRange(content.startIndex..., in: content)
        if firstOnly {
            guard let match = reg.firstMatch(in: content, range: range),
                  let matchRange = Range(match.range, in: content) else { return content }
            let replaced = reg.stringByReplacingMatches(
                in: String(content[matchRange]),
                range: NSRange(location: 0, length: (content[matchRange] as NSString).length),
                withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
            )
            return content.replacingCharacters(in: matchRange, with: replaced)
        }
        return reg.stringByReplacingMatches(
            in: content,
            range: range,
            withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
        )
    }

    /// 按首个顶层 `##` 切开，保留空 replacement（`pattern##`）。
    private static func splitReplaceRegexKeepEmpty(_ regex: String) -> (pattern: String, replacement: String, firstOnly: Bool) {
        guard let hashRange = regex.range(of: "##") else {
            return (regex, "", false)
        }
        let pattern = String(regex[..<hashRange.lowerBound])
        let rest = String(regex[hashRange.upperBound...])
        if let second = rest.range(of: "##") {
            return (pattern, String(rest[..<second.lowerBound]), true)
        }
        return (pattern, rest, false)
    }

    /// 封面 URL 解密（coverDecodeJs）
    private static func decodeCoverURL(
        _ url: String,
        source: any BridgeSourceProtocol,
        baseUrl: String
    ) -> String {
        CoverDecodeHelper.decodeCoverURL(
            url,
            decodeJs: source.coverDecodeJs,
            baseUrl: baseUrl,
            source: source
        )
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

/// 书评条目
public struct BookReview: Equatable {
    public var avatar: String
    public var content: String
    public var raw: String

    public init(avatar: String = "", content: String = "", raw: String = "") {
        self.avatar = avatar
        self.content = content
        self.raw = raw
    }
}
