//
//  AnalyzeUrl.swift
//  Legado-iOS
//
//  URL 解析与构建器 - 参考原版 AnalyzeUrl.kt（978行）
//  1:1 移植 Android io.legado.app.model.analyzeRule.AnalyzeUrl
//  支持 {{key}}、{{page}} 变量替换、<page,list> 模式、POST/body/headers/charset 解析
//  支持 @js: URL前缀、retry、bodyJs、dnsIp、type(binary)、webView、webJs
//  支持 HEAD 方法、Cookie 管理、StrResponse 对象、encoded form/query params
//  支持 serverID、proxy、ConcurrentRateLimiter
//

import Foundation
import JavaScriptCore
import CommonCrypto

// MARK: - 请求方法枚举

/// HTTP 请求方法 - 对应 Android RequestMethod.kt
enum RequestMethod: String {
    case GET
    case POST
    case HEAD
}

// MARK: - URL 解析结果（兼容旧接口）

/// URL 解析结果 — 对应 Android AnalyzeUrl 暴露的属性集合
struct AnalyzedUrl {
    var url: String
    var method: RequestMethod = .GET
    var body: String?
    var headers: [String: String] = [:]
    var charset: String?
    var webView: Bool = false
    var webJs: String?
    var sourceRegex: String?
}

// MARK: - AnalyzeUrl 主类

/// URL 构建器 - 将书源中的规则 URL 解析为实际可用的请求
/// 对应 Android AnalyzeUrl（978行）完整移植
class AnalyzeUrl {

    // MARK: - 公开属性

    /// 原始规则 URL（经 JS 处理后）
    private(set) var ruleUrl: String = ""
    /// 最终 URL
    private(set) var url: String = ""
    /// 类型（如 "image/jpeg"），用于二进制响应
    private(set) var type: String?
    /// 请求头（internal 以便兼容层访问）
    var headerMap: [String: String] = [:]
    /// 去掉 query 的 URL
    private(set) var urlNoQuery: String = ""

    // MARK: - 私有属性

    private(set) var body: String?
    private(set) var encodedForm: String?
    private(set) var encodedQuery: String?
    private(set) var charset: String?
    private(set) var method: RequestMethod = .GET
    private var proxy: String?
    private var retry: Int = 0
    private(set) var useWebView: Bool = false
    private(set) var webJs: String?
    private var bodyJs: String?
    private var dnsIp: String?
    private let enabledCookieJar: Bool
    private let domain: String
    private var webViewDelayTime: Int64 = 0
    private let concurrentRateLimiter: ConcurrentRateLimiter
    /// 服务器 ID（对应 Android serverID）
    private(set) var serverID: Int64?

    // MARK: - 初始化参数

    private let mUrl: String
    private let key: String?
    private let page: Int?
    private let speakText: String?
    private let speakSpeed: Int?
    private var baseUrl: String
    private let source: (any BridgeSourceProtocol)?
    private let ruleData: AnyObject? // Book 或 BookChapter
    private let readTimeout: Int64?
    private let callTimeout: Int64?
    private let infoMap: [String: String]?

    // MARK: - 正则

    /// 分离 URL 和配置 JSON 的正则：匹配 ,{ 之前的逗号
    private static let paramPattern = try! NSRegularExpression(pattern: #"\s*,\s*(?=\{)"#)
    /// <page,list> 页码模式
    private static let pagePattern = try! NSRegularExpression(pattern: "<(.*?)>")
    /// @js: URL 前缀
    private static let jsPrefixPattern = try! NSRegularExpression(pattern: #"(?i)^@js:"#, options: [])
    /// <js>...</js> 包裹
    private static let jsBlockPattern = try! NSRegularExpression(
        pattern: #"(?:(<js>)([\s\S]*?)(<\/js>))|(?:(@js:)([\s\S]*))"#, options: []
    )

    // MARK: - 初始化

    init(
        mUrl: String,
        key: String? = nil,
        page: Int? = nil,
        speakText: String? = nil,
        speakSpeed: Int? = nil,
        baseUrl: String = "",
        source: (any BridgeSourceProtocol)? = nil,
        ruleData: AnyObject? = nil,
        readTimeout: Int64? = nil,
        callTimeout: Int64? = nil,
        headerMapF: [String: String]? = nil,
        hasLoginHeader: Bool = true,
        infoMap: [String: String]? = nil
    ) {
        self.mUrl = mUrl
        self.key = key
        self.page = page
        self.speakText = speakText
        self.speakSpeed = speakSpeed
        self.baseUrl = baseUrl
        self.source = source
        self.ruleData = ruleData
        self.readTimeout = readTimeout
        self.callTimeout = callTimeout
        self.infoMap = infoMap
        self.enabledCookieJar = source?.enabledCookieJar == true

        // 从 baseUrl 去掉变量占位符
        if let match = Self.paramPattern.firstMatch(
            in: self.baseUrl, range: NSRange(self.baseUrl.startIndex..., in: self.baseUrl)
        ), let range = Range(match.range, in: self.baseUrl) {
            self.baseUrl = String(self.baseUrl[self.baseUrl.startIndex..<range.lowerBound])
        }

        // 初始化 headerMap
        if let headerMapF = headerMapF {
            self.headerMap = headerMapF
            if let proxy = headerMapF["proxy"] {
                self.proxy = proxy
                self.headerMap.removeValue(forKey: "proxy")
            }
        } else if let source = source, let header = source.header {
            // 尝试解码书源 header
            if let data = header.data(using: .utf8),
               let headers = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                self.headerMap = headers
                if let proxy = headers["proxy"] {
                    self.proxy = proxy
                    self.headerMap.removeValue(forKey: "proxy")
                }
            }
        }

        self.concurrentRateLimiter = ConcurrentRateLimiter(source: source)

        // 解析 URL（domain 先初始化，initUrl 才能安全使用 self）
        self.domain = Self.getSubDomain(from: source?.bookSourceUrl ?? url)
        initUrl()
    }

    /// 便捷初始化
    convenience init(_ mUrl: String) {
        self.init(mUrl: mUrl, key: nil)
    }

    // MARK: - URL 解析主流程

    /// 处理 URL（对应 Android initUrl）
    private func initUrl() {
        ruleUrl = mUrl
        // 1. 执行 @js: 和 <js></js>
        analyzeJs()
        // 2. 替换关键字、页数、JS
        replaceKeyPageJs()
        // 3. 解析 URL
        analyzeUrl()
    }

    // MARK: - 执行 JS

    /// 执行 @js: 和 <js></js>（对应 Android analyzeJs）
    private func analyzeJs() {
        var start = 0
        var result = ruleUrl
        let fullRange = NSRange(ruleUrl.startIndex..., in: ruleUrl)

        // 匹配 <js>...</js> 和 @js: 模式
        let jsPattern = try! NSRegularExpression(
            pattern: #"(?:<js>([\s\S]*?)<\/js>)|(?:@js:([\s\S]*))"#, options: []
        )
        let matches = jsPattern.matches(in: ruleUrl, range: fullRange)

        for match in matches {
            if match.range.location > start {
                let prefixRange = NSRange(location: start, length: match.range.location - start)
                if let prefix = Range(prefixRange, in: ruleUrl) {
                    let trimmed = ruleUrl[prefix].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        result = trimmed.replacingOccurrences(of: "@result", with: result)
                    }
                }
            }

            let jsCode: String
            if let group1Range = Range(match.range(at: 1), in: ruleUrl), match.range(at: 1).location != NSNotFound {
                jsCode = String(ruleUrl[group1Range])
            } else if let group2Range = Range(match.range(at: 2), in: ruleUrl), match.range(at: 2).location != NSNotFound {
                jsCode = String(ruleUrl[group2Range])
            } else {
                continue
            }

            let evalResult = evalJS(jsCode, result: result)
            result = String(describing: evalResult ?? result)
            start = match.range.location + match.range.length
        }

        if ruleUrl.count > start {
            let suffixIndex = ruleUrl.index(ruleUrl.startIndex, offsetBy: start)
            let suffix = String(ruleUrl[suffixIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !suffix.isEmpty {
                result = suffix.replacingOccurrences(of: "@result", with: result)
            }
        }

        ruleUrl = result
    }

    // MARK: - 替换变量

    /// 替换关键字、页数、JS（对应 Android replaceKeyPageJs）
    private func replaceKeyPageJs() {
        // 1. 替换 {{js}} 内嵌规则
        if ruleUrl.contains("{{") && ruleUrl.contains("}}") {
            let analyzer = RuleAnalyzer(data: ruleUrl)
            let url = analyzer.innerRule(startStr: "{{", endStr: "}}") { [weak self] jsCode in
                guard let self = self else { return "" }
                let jsEval = self.evalJS(jsCode) ?? ""
                if let doubleVal = jsEval as? Double, doubleVal == floor(doubleVal) {
                    return String(format: "%.0f", doubleVal)
                }
                return String(describing: jsEval)
            }
            if !url.isEmpty { ruleUrl = url }
        }

        // 2. 替换 <page,list> 模式
        if let page = page {
            let fullRange = NSRange(ruleUrl.startIndex..., in: ruleUrl)
            let pageMatches = Self.pagePattern.matches(in: ruleUrl, range: fullRange)

            // 从后往前替换，避免偏移
            for match in pageMatches.reversed() {
                guard let fullRange = Range(match.range, in: ruleUrl),
                      let groupRange = Range(match.range(at: 1), in: ruleUrl) else { continue }

                let pages = String(ruleUrl[groupRange]).split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                let replacement: String
                if page <= pages.count {
                    replacement = pages[page - 1]
                } else {
                    replacement = pages.last ?? ""
                }
                ruleUrl.replaceSubrange(fullRange, with: replacement)
            }
        }
    }

    // MARK: - 解析 URL

    /// 解析 URL 参数（对应 Android analyzeUrl）
    private func analyzeUrl() {
        let fullRange = NSRange(ruleUrl.startIndex..., in: ruleUrl)
        let urlMatcher = Self.paramPattern.firstMatch(in: ruleUrl, range: fullRange)

        let urlNoOption: String
        if let match = urlMatcher, let range = Range(match.range, in: ruleUrl) {
            urlNoOption = String(ruleUrl[ruleUrl.startIndex..<range.lowerBound])
        } else {
            urlNoOption = ruleUrl
        }

        // 解析绝对 URL
        url = Self.getAbsoluteURL(baseUrl: baseUrl, urlNoOption)

        // 更新 baseUrl
        if let newBase = Self.getBaseUrl(from: url) {
            baseUrl = newBase
        }

        // 解析 URL Option JSON
        if urlNoOption.count != ruleUrl.count,
           let match = urlMatcher,
           let range = Range(match.range, in: ruleUrl) {
            let optionStartIndex = ruleUrl.index(after: range.upperBound)
            let urlOptionStr = String(ruleUrl[optionStartIndex...])

            // 尝试严格解析，再尝试宽松解析
            var urlOption: UrlOption?
            if let data = urlOptionStr.data(using: .utf8) {
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                urlOption = try? decoder.decode(UrlOption.self, from: data)
                if urlOption == nil {
                    // 宽松解析
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        urlOption = UrlOption.fromDict(json)
                    }
                }
            }

            if let option = urlOption {
                // 方法
                if let methodStr = option.method {
                    switch methodStr.uppercased() {
                    case "POST": method = .POST
                    case "HEAD": method = .HEAD
                    default: method = .GET
                    }
                }

                // 请求头
                if let headers = option.getHeaderMap() {
                    for (k, v) in headers {
                        headerMap[k] = String(describing: v)
                    }
                }

                // Body
                if let bodyStr = option.getBody() {
                    self.body = bodyStr
                }

                type = option.type
                charset = option.charset
                retry = option.retry ?? 0
                useWebView = option.useWebView()
                webJs = option.webJs
                bodyJs = option.bodyJs
                dnsIp = option.dnsIp

                // 执行 option.js 并将结果赋值给 url
                if let jsStr = option.js, !jsStr.isEmpty {
                    if let evalResult = evalJS(jsStr, result: url) {
                        let str = String(describing: evalResult)
                        if !str.isEmpty { url = str }
                    }
                }

                serverID = option.serverID
                webViewDelayTime = max(0, option.webViewDelayTime ?? 0)
            }
        }

        urlNoQuery = url

        // 处理编码后的参数
        switch method {
        case .POST:
            if let body = body {
                let isJson = body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
                let isXml = body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<")
                if !isJson && !isXml && headerMap["Content-Type"] == nil {
                    encodedForm = encodeParams(body, charset: charset, isQuery: false)
                }
            }
        case .GET, .HEAD:
            if let qIndex = url.firstIndex(of: "?") {
                let query = String(url[url.index(after: qIndex)...])
                encodedQuery = encodeParams(query, charset: charset, isQuery: true)
                urlNoQuery = String(url[url.startIndex..<qIndex])
            }
        }
    }

    // MARK: - 参数编码

    /// 编码 form/query 参数（对应 Android encodeParams）
    private func encodeParams(_ params: String, charset: String?, isQuery: Bool) -> String {
        let checkEncoded = (charset == nil || charset!.isEmpty)
        let resolvedCharset: String.Encoding?
        if let cs = charset, !cs.isEmpty {
            if cs.lowercased() == "escape" {
                resolvedCharset = nil // escape 模式
            } else {
                resolvedCharset = Self.charsetNameToEncoding(cs)
            }
        } else {
            resolvedCharset = .utf8
        }

        if isQuery && resolvedCharset != nil {
            if Self.isEncodedQuery(params) {
                return params
            }
            return Self.queryEncode(params, charset: resolvedCharset!)
        }

        var sb = ""
        var pos = 0
        let len = params.count
        let chars = Array(params)

        while pos <= len {
            if !sb.isEmpty { sb += "&" }
            var ampOffset = -1
            for i in pos..<len {
                if chars[i] == "&" || Character(String(chars[i])) == "&" {
                    ampOffset = i
                    break
                }
            }
            if ampOffset == -1 { ampOffset = len }

            var eqOffset = -1
            for i in pos..<ampOffset {
                if chars[i] == "=" || Character(String(chars[i])) == "=" {
                    eqOffset = i
                    break
                }
            }

            let key: String
            let value: String?
            let charsStr = String(chars)

            if eqOffset == -1 || eqOffset > ampOffset {
                let keyStart = charsStr.index(charsStr.startIndex, offsetBy: pos)
                let keyEnd = charsStr.index(charsStr.startIndex, offsetBy: ampOffset)
                key = String(charsStr[keyStart..<keyEnd])
                value = nil
            } else {
                let keyStart = charsStr.index(charsStr.startIndex, offsetBy: pos)
                let keyEnd = charsStr.index(charsStr.startIndex, offsetBy: eqOffset)
                let valStart = charsStr.index(charsStr.startIndex, offsetBy: eqOffset + 1)
                let valEnd = charsStr.index(charsStr.startIndex, offsetBy: ampOffset)
                key = String(charsStr[keyStart..<keyEnd])
                value = String(charsStr[valStart..<valEnd])
            }

            sb += appendEncoded(key, checkEncoded: checkEncoded, charset: resolvedCharset)
            if let value = value {
                sb += "="
                sb += appendEncoded(value, checkEncoded: checkEncoded, charset: resolvedCharset)
            }
            pos = ampOffset + 1
        }
        return sb
    }

    /// 追加编码值（对应 Android appendEncoded）
    private func appendEncoded(_ value: String, checkEncoded: Bool, charset: String.Encoding?) -> String {
        if checkEncoded && Self.isEncodedForm(value) {
            return value
        } else if charset == nil {
            // escape 模式
            return Self.escape(value)
        } else {
            return value.addingPercentEncoding(withAllowedCharacters: Self.urlQueryAllowedSet) ?? value
        }
    }

    // MARK: - JS 执行

    /// 执行 JS（对应 Android evalJS）
    func evalJS(_ jsStr: String, result: Any? = nil) -> Any? {
        let trimmed = jsStr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return result }

        let jsContext = JSContext()!

        // 注入绑定
        let bridge = JSBridge()
        let execContext = ExecutionContext()
        execContext.source = source
        execContext.baseURL = URL(string: baseUrl)
        execContext.variables = buildVariableMap()
        bridge.context = execContext
        bridge.inject(into: jsContext)

        // 设置特定变量
        jsContext.setValue(baseUrl, forKey: "baseUrl")
        jsContext.setValue(result, forKey: "result")
        jsContext.setValue(result, forKey: "url")
        if let page = page { jsContext.setValue(page, forKey: "page") }
        if let key = key { jsContext.setValue(key, forKey: "key") }
        if let speakText = speakText { jsContext.setValue(speakText, forKey: "speakText") }
        if let speakSpeed = speakSpeed { jsContext.setValue(speakSpeed, forKey: "speakSpeed") }

        // 执行
        let evalResult = jsContext.evaluateScript(trimmed)
        if let value = evalResult {
            let str = value.toString() ?? ""
            if !str.isEmpty && str != "undefined" && str != "null" {
                return str
            }
            if value.isNumber {
                return value.toNumber()?.stringValue ?? str
            }
            return str
        }
        return result
    }

    // MARK: - getStrResponse（对应 Android getStrResponseAwait）

    /// 访问网站返回 StrResponse（对应 Android getStrResponseAwait）
    func getStrResponseAwait(
        jsStr: String? = nil,
        sourceRegex: String? = nil,
        useWebView: Bool = true,
        isTest: Bool = false,
        skipRateLimit: Bool = false
    ) async throws -> StrResponse {
        if type != nil {
            // 二进制响应，返回 hex 编码
            let bytes = try await getByteArrayAwait()
            return StrResponse(url: url, body: bytes.map { String(format: "%02x", $0) }.joined())
        }

        if skipRateLimit {
            return try await executeStrRequest(jsStr: jsStr, sourceRegex: sourceRegex, useWebView: useWebView, isTest: isTest)
        }

        return try await concurrentRateLimiter.withLimit {
            try await self.executeStrRequest(jsStr: jsStr, sourceRegex: sourceRegex, useWebView: useWebView, isTest: isTest)
        }
    }

    /// 执行请求（对应 Android executeStrRequest）
    private func executeStrRequest(
        jsStr: String? = nil,
        sourceRegex: String? = nil,
        useWebView: Bool = true,
        isTest: Bool = false
    ) async throws -> StrResponse {
        setCookie()
        let startTime = Date().timeIntervalSince1970 * 1000

        do {
            let strResponse: StrResponse

            if self.useWebView && useWebView {
                // WebView 模式
                switch method {
                case .POST:
                    // POST: 先发 HTTP 请求获取响应，再通过 WebView 加载
                    let res = try await httpClientNewCallStrResponse { builder in
                        builder.addHeaders(headerMap)
                        builder.url = self.urlNoQuery
                        if let form = self.encodedForm, !form.isEmpty {
                            builder.body = form
                            builder.contentType = "application/x-www-form-urlencoded"
                        } else if let body = self.body, !body.isEmpty {
                            builder.body = body
                            builder.contentType = headerMap["Content-Type"] ?? "application/json"
                        }
                        builder.method = .POST
                    }
                    let bwv = BackstageWebView(
                        url: res.url,
                        html: res.body,
                        tag: source?.bookSourceUrl,
                        headerMap: headerMap,
                        sourceRegex: sourceRegex,
                        javaScript: webJs ?? jsStr,
                        delayTime: webViewDelayTime
                    )
                    strResponse = try await bwv.getStrResponse()

                case .GET, .HEAD:
                    let effectiveSourceRegex = webJs != nil ? nil : sourceRegex
                    let bwv = BackstageWebView(
                        url: url,
                        tag: source?.bookSourceUrl,
                        headerMap: headerMap,
                        sourceRegex: effectiveSourceRegex,
                        javaScript: webJs ?? jsStr,
                        delayTime: webViewDelayTime
                    )
                    strResponse = try await bwv.getStrResponse()
                }
            } else {
                // 普通 HTTP 请求
                strResponse = try await httpClientNewCallStrResponse { builder in
                    builder.addHeaders(headerMap)
                    switch self.method {
                    case .POST:
                        builder.url = self.urlNoQuery
                        if let form = self.encodedForm, !form.isEmpty {
                            builder.body = form
                            builder.contentType = "application/x-www-form-urlencoded"
                        } else if let body = self.body, !body.isEmpty {
                            if let ct = headerMap["Content-Type"] {
                                builder.body = body
                                builder.contentType = ct
                            } else {
                                builder.body = body
                                builder.contentType = "application/json"
                            }
                        }
                        builder.method = .POST

                    case .HEAD:
                        builder.url = self.urlNoQuery
                        if let query = self.encodedQuery {
                            builder.query = query
                        }
                        builder.method = .HEAD

                    case .GET:
                        builder.url = self.urlNoQuery
                        if let query = self.encodedQuery {
                            builder.query = query
                        }
                        builder.method = .GET
                    }
                }

                // bodyJs 后处理
                if let bodyJs = bodyJs, !bodyJs.isEmpty {
                    let bodyEvalResult = evalJS(bodyJs, result: strResponse.body) ?? ""
                    return StrResponse(url: strResponse.url, body: String(describing: bodyEvalResult))
                }
            }

            let connectionTime = Int64(Date().timeIntervalSince1970 * 1000 - startTime)
            strResponse.putCallTime(Int(connectionTime))
            return strResponse

        } catch {
            if !isTest { throw error }

            // 测试模式错误码
            let errorCode: Int
            if let urlError = error as? URLError {
                switch urlError.code {
                case .timedOut: errorCode = -1
                case .cannotFindHost: errorCode = -3
                case .cannotConnectToHost: errorCode = -4
                case .networkConnectionLost: errorCode = -5
                case .secureConnectionFailed: errorCode = -6
                case .internationalRoamingOff: errorCode = -7
                default: errorCode = -7
                }
            } else {
                errorCode = -7
            }
            return StrResponse(url: url, errorMessage: error.localizedDescription, errorCode: errorCode)
        }
    }

    /// 同步版本（对应 Android getStrResponse）
    func getStrResponse(
        jsStr: String? = nil,
        sourceRegex: String? = nil,
        useWebView: Bool = true
    ) -> StrResponse {
        return waitForAsync {
            try await self.getStrResponseAwait(jsStr: jsStr, sourceRegex: sourceRegex, useWebView: useWebView)
        }
    }

    // MARK: - getResponse（对应 Android getResponseAwait）

    /// 获取原始响应（对应 Android getResponseAwait）
    func getResponseAwait() async throws -> (data: Data, response: HTTPURLResponse) {
        try await concurrentRateLimiter.withLimit {
            self.setCookie()
            return try await self.httpClientNewCall { builder in
                builder.addHeaders(self.headerMap)
                switch self.method {
                case .POST:
                    builder.url = self.urlNoQuery
                    builder.method = .POST
                    if let form = self.encodedForm, !form.isEmpty {
                        builder.body = form
                        builder.contentType = "application/x-www-form-urlencoded"
                    } else if let body = self.body, !body.isEmpty {
                        builder.body = body
                        builder.contentType = headerMap["Content-Type"] ?? "application/json"
                    }
                case .GET, .HEAD:
                    builder.url = self.urlNoQuery
                    if let query = self.encodedQuery { builder.query = query }
                    builder.method = self.method
                }
            }
        }
    }

    // MARK: - 二进制响应

    /// 获取字节数组（对应 Android getByteArrayAwait）
    func getByteArrayAwait() async throws -> Data {
        // 检查 data: URI
        if urlNoQuery.hasPrefix("data:") {
            if let base64Data = Self.extractDataUri(urlNoQuery) {
                return base64Data
            }
        }
        let (data, _) = try await getResponseAwait()
        return data
    }

    func getByteArray() -> Data {
        return waitForAsync { try await self.getByteArrayAwait() }
    }

    // MARK: - Cookie 管理

    /// 设置 Cookie（对应 Android setCookie）
    private func setCookie() {
        let cookie = CookieManager.shared.getCookie(for: domain) ?? ""
        if !cookie.isEmpty {
            let existingCookie = headerMap["Cookie"] ?? ""
            let merged = Self.mergeCookies(cookie, existing: existingCookie)
            headerMap["Cookie"] = merged
        }
        if enabledCookieJar {
            headerMap["X-Cookie-Jar"] = "1"
        } else {
            headerMap.removeValue(forKey: "X-Cookie-Jar")
        }
    }

    // MARK: - 工具方法

    var isPost: Bool { method == .POST }

    func getUserAgent() -> String {
        return headerMap["User-Agent"] ?? Self.defaultUA
    }

    // MARK: - HTTP 客户端封装

    /// HTTP 请求构建器
    private struct RequestBuilder {
        var url: String = ""
        var method: RequestMethod = .GET
        var body: String?
        var contentType: String?
        var query: String?
        var headers: [String: String] = [:]

        mutating func addHeaders(_ headers: [String: String]) {
            for (k, v) in headers { self.headers[k] = v }
        }
    }

    /// 使用构建器发起 HTTP 请求，返回 StrResponse（对应 Android newCallStrResponse）
    private func httpClientNewCallStrResponse(
        retry: Int = 0,
        configure: (inout RequestBuilder) -> Void
    ) async throws -> StrResponse {
        var builder = RequestBuilder()
        configure(&builder)

        let finalURL: String
        if let query = builder.query, !query.isEmpty {
            finalURL = builder.url + "?" + query
        } else {
            finalURL = builder.url
        }

        guard let url = URL(string: finalURL) else {
            return StrResponse(url: finalURL, body: "")
        }

        var request = URLRequest(url: url)
        request.httpMethod = builder.method.rawValue
        if let timeout = callTimeout {
            request.timeoutInterval = Double(timeout) / 1000.0
        } else {
            request.timeoutInterval = 30
        }

        for (k, v) in builder.headers {
            request.setValue(v, forHTTPHeaderField: k)
        }

        if let body = builder.body {
            request.httpBody = body.data(using: .utf8)
            if let ct = builder.contentType {
                request.setValue(ct, forHTTPHeaderField: "Content-Type")
            }
        }

        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(Self.defaultUA, forHTTPHeaderField: "User-Agent")
        }

        // 重试逻辑
        var lastError: Error?
        for attempt in 0...max(0, retry) {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let encoding = Self.detectEncoding(data: data, response: response, charset: self.charset)
                let bodyStr = String(data: data, encoding: encoding)
                    ?? String(data: data, encoding: .utf8)
                    ?? ""

                let httpResponse = response as? HTTPURLResponse
                return StrResponse(response: httpResponse, body: bodyStr)
            } catch {
                lastError = error
                if attempt < retry {
                    try? await Task.sleep(nanoseconds: 500_000_000) // 500ms 重试间隔
                }
            }
        }
        throw lastError ?? URLError(.unknown)
    }

    /// 使用构建器发起 HTTP 请求，返回原始 Data + HTTPURLResponse
    private func httpClientNewCall(
        configure: (inout RequestBuilder) -> Void
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        var builder = RequestBuilder()
        configure(&builder)

        let finalURL: String
        if let query = builder.query, !query.isEmpty {
            finalURL = builder.url + "?" + query
        } else {
            finalURL = builder.url
        }

        guard let url = URL(string: finalURL) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = builder.method.rawValue
        request.timeoutInterval = callTimeout.map { Double($0) / 1000.0 } ?? 30

        for (k, v) in builder.headers {
            request.setValue(v, forHTTPHeaderField: k)
        }

        if let body = builder.body {
            request.httpBody = body.data(using: .utf8)
            if let ct = builder.contentType {
                request.setValue(ct, forHTTPHeaderField: "Content-Type")
            }
        }

        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(Self.defaultUA, forHTTPHeaderField: "User-Agent")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, httpResponse)
    }

    // MARK: - 旧接口兼容

    /// 解析搜索/发现 URL（旧接口兼容）
    static func analyze(
        ruleUrl: String,
        key: String? = nil,
        page: Int = 1,
        baseUrl: String? = nil,
        source: (any BridgeSourceProtocol)? = nil
    ) -> AnalyzedUrl {
        let analyzer = AnalyzeUrl(
            mUrl: ruleUrl,
            key: key,
            page: page,
            baseUrl: baseUrl ?? "",
            source: source
        )
        return AnalyzedUrl(
            url: analyzer.url,
            method: analyzer.method,
            body: analyzer.body,
            headers: analyzer.headerMap,
            charset: analyzer.charset,
            webView: analyzer.useWebView,
            webJs: analyzer.webJs,
            sourceRegex: nil
        )
    }

    /// 使用解析后的 URL 发起网络请求并返回响应内容（旧接口兼容）
    static func getResponseBody(
        analyzedUrl: AnalyzedUrl,
        charset: String.Encoding = .utf8,
        javaScript: String? = nil,
        sourceRegex: String? = nil,
        forceWebView: Bool = false
    ) async throws -> (body: String, url: String) {
        let analyzer = AnalyzeUrl(mUrl: analyzedUrl.url, source: nil)
        analyzer.headerMap = analyzedUrl.headers
        analyzer.method = analyzedUrl.method
        analyzer.body = analyzedUrl.body
        analyzer.charset = analyzedUrl.charset
        // forceWebView（ruleContent.webJs / sourceRegex）必须落到 self.useWebView，
        // 否则 executeStrRequest 的 `self.useWebView && useWebView` 永远进不了 BackstageWebView。
        let needWebView = forceWebView || analyzedUrl.webView
        analyzer.useWebView = needWebView
        analyzer.webJs = javaScript ?? analyzedUrl.webJs
        let hasWebJs = !(analyzer.webJs?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if needWebView {
            // 进入前先打点：若仍无完成标记，可区分「未进分支」与「WebView 卡住」
            writeWebViewDebugMarker(
                url: analyzedUrl.url,
                body: "",
                force: forceWebView,
                analyzedFlag: analyzedUrl.webView,
                hasWebJs: hasWebJs,
                phase: "enter"
            )
        }

        let response = try await analyzer.getStrResponseAwait(
            jsStr: javaScript,
            sourceRegex: sourceRegex,
            useWebView: needWebView
        )
        if needWebView {
            writeWebViewDebugMarker(
                url: response.url,
                body: response.body ?? "",
                force: forceWebView,
                analyzedFlag: analyzedUrl.webView,
                hasWebJs: hasWebJs,
                phase: "done"
            )
        }
        return (body: response.body ?? "", url: response.url)
    }

    /// 8.7 真机门禁：证明本轮走了 BackstageWebView，且渲染后正文含针时可对照
    private static func writeWebViewDebugMarker(
        url: String,
        body: String,
        force: Bool,
        analyzedFlag: Bool,
        hasWebJs: Bool,
        phase: String
    ) {
        let marker = [
            "ts=\(ISO8601DateFormatter().string(from: Date()))",
            "phase=\(phase)",
            "path=BackstageWebView",
            "forceWebView=\(force)",
            "analyzedWebView=\(analyzedFlag)",
            "hasWebJs=\(hasWebJs)",
            "url=\(url)",
            "bodyLen=\(body.count)",
            "hasMarker=\(body.contains("WEBVIEW_OK_MARKER"))",
            "hasXiaoyan=\(body.contains("萧炎"))",
        ].joined(separator: "\n")
        let path = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Documents/legado_webview_debug.txt")
        try? marker.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - 静态工具方法

    private static let defaultUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.5 Mobile/15E148 Safari/604.1"

    /// URL 编码允许字符集（对应 Android RFC3986 UNRESERVED + 特殊字符）
    private static let urlQueryAllowedSet: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.insert(charactersIn: "!$%&'()*+,/:;=?@[]^`{|}~")
        return set
    }()

    /// 获取绝对 URL（对应 Android NetworkUtils.getAbsoluteURL）
    private static func getAbsoluteURL(baseUrl: String, _ url: String) -> String {
        if url.hasPrefix("http") { return url }
        guard !baseUrl.isEmpty, let base = URL(string: baseUrl) else { return url }
        return URL(string: url, relativeTo: base)?.absoluteString ?? url
    }

    /// 获取 URL 的 baseUrl 部分
    private static func getBaseUrl(from urlStr: String) -> String? {
        guard let url = URL(string: urlStr) else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        return components?.url?.absoluteString
    }

    /// 获取子域名（对应 Android NetworkUtils.getSubDomain）
    private static func getSubDomain(from urlStr: String) -> String {
        guard let url = URL(string: urlStr), let host = url.host else { return urlStr }
        return host
    }

    /// 合并 Cookie（对应 Android CookieManager.mergeCookies）
    private static func mergeCookies(_ newCookie: String, existing: String?) -> String {
        guard let existing = existing, !existing.isEmpty else { return newCookie }
        var cookieMap: [String: String] = [:]
        for pair in existing.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { cookieMap[parts[0]] = parts[1] }
        }
        for pair in newCookie.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { cookieMap[parts[0]] = parts[1] }
        }
        return cookieMap.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    /// 检测编码
    private static func detectEncoding(data: Data, response: URLResponse?, charset: String?) -> String.Encoding {
        if let charset = charset {
            return charsetNameToEncoding(charset) ?? .utf8
        }
        if let httpResponse = response as? HTTPURLResponse,
           let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased() {
            if contentType.contains("gbk") || contentType.contains("gb2312") {
                return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
            }
        }
        if data.count > 0 {
            let prefix = String(data: data.prefix(1024), encoding: .ascii) ?? ""
            if prefix.lowercased().contains("charset=gbk") || prefix.lowercased().contains("charset=gb2312") {
                return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
            }
        }
        return .utf8
    }

    /// 字符集名称转编码
    private static func charsetNameToEncoding(_ name: String) -> String.Encoding? {
        switch name.lowercased() {
        case "utf-8", "utf8": return .utf8
        case "gbk", "gb2312", "gb18030":
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        case "big5":
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue)))
        case "iso-8859-1", "latin1": return .isoLatin1
        case "ascii": return .ascii
        case "unicode": return .unicode
        default: return nil
        }
    }

    /// 检查 query 是否已经编码
    private static func isEncodedQuery(_ query: String) -> Bool {
        return query.contains("%") && query.range(of: #"%[0-9A-Fa-f]{2}"#, options: .regularExpression) != nil
    }

    /// 检查 form 是否已经编码
    private static func isEncodedForm(_ value: String) -> Bool {
        return value.contains("%") && value.range(of: #"%[0-9A-Fa-f]{2}"#, options: .regularExpression) != nil
    }

    /// URL query 编码（对应 Android queryEncoder.encode）
    private static func queryEncode(_ params: String, charset: String.Encoding) -> String {
        return params.addingPercentEncoding(withAllowedCharacters: urlQueryAllowedSet) ?? params
    }

    /// JavaScript escape 等价（对应 Android EncoderUtils.escape）
    private static func escape(_ string: String) -> String {
        var result = ""
        for char in string.unicodeScalars {
            if char.isASCII && (Character(char).isLetter || Character(char).isNumber || "_*+-./@".contains(Character(char))) {
                result.append(Character(char))
            } else {
                let value = char.value
                if value < 256 {
                    result += String(format: "%%%02X", value)
                } else {
                    result += String(format: "%%u%04X", value)
                }
            }
        }
        return result
    }

    /// 从 data: URI 提取 Base64 数据
    private static func extractDataUri(_ url: String) -> Data? {
        guard url.hasPrefix("data:") else { return nil }
        let pattern = try? NSRegularExpression(pattern: #"data:[^;]*;base64,(.*)"#)
        let range = NSRange(url.startIndex..., in: url)
        guard let match = pattern?.firstMatch(in: url, range: range),
              let dataRange = Range(match.range(at: 1), in: url) else { return nil }
        return Data(base64Encoded: String(url[dataRange]))
    }

    /// 构建变量 Map
    private func buildVariableMap() -> [String: String] {
        var vars: [String: String] = [:]
        if let key = key {
            let encoded = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
            vars["key"] = encoded
            vars["searchKey"] = encoded
        }
        if let page = page {
            vars["page"] = "\(page)"
            vars["page-1"] = "\(page - 1)"
        }
        if let variable = source?.variable,
           let data = variable.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (name, value) in json {
                if let str = value as? String { vars[name] = str }
                else if let bool = value as? Bool { vars[name] = bool ? "true" : "false" }
                else { vars[name] = String(describing: value) }
            }
        }
        return vars
    }

    /// 同步等待异步结果
    private func waitForAsync<T>(_ block: @escaping () async throws -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        // 使用 UnsafeMutablePointer 实现线程安全的值传递
        let resultPointer = UnsafeMutablePointer<T?>.allocate(capacity: 1)
        resultPointer.initialize(to: nil)
        let errorPointer = UnsafeMutablePointer<Error?>.allocate(capacity: 1)
        errorPointer.initialize(to: nil)

        Task {
            do {
                resultPointer.pointee = try await block()
            } catch let e {
                errorPointer.pointee = e
            }
            semaphore.signal()
        }

        semaphore.wait()
        if let error = errorPointer.pointee {
            resultPointer.deallocate()
            errorPointer.deallocate()
            fatalError("同步等待失败: \(error)")
        }
        guard let value = resultPointer.pointee else {
            resultPointer.deallocate()
            errorPointer.deallocate()
            fatalError("同步等待结果为空")
        }
        resultPointer.deallocate()
        errorPointer.deallocate()
        return value
    }
}

// MARK: - UrlOption 结构体

/// URL 配置选项 - 对应 Android AnalyzeUrl.UrlOption
struct UrlOption: Codable {
    var method: String?
    var charset: String?
    var headers: AnyCodable?
    var body: AnyCodable?
    var origin: String?
    var retry: Int?
    var type: String?
    var webView: AnyCodable?
    var webJs: String?
    var dnsIp: String?
    var js: String?
    var bodyJs: String?
    var serverID: Int64?
    var webViewDelayTime: Int64?

    enum CodingKeys: String, CodingKey {
        case method, charset, headers, body, origin, retry, type
        case webView, webJs, dnsIp, js, bodyJs, serverID, webViewDelayTime
    }

    /// 从字典构造
    static func fromDict(_ dict: [String: Any]) -> UrlOption? {
        var option = UrlOption()
        option.method = dict["method"] as? String
        option.charset = dict["charset"] as? String
        if let h = dict["headers"] { option.headers = AnyCodable(h) }
        if let b = dict["body"] { option.body = AnyCodable(b) }
        option.origin = dict["origin"] as? String
        option.retry = dict["retry"] as? Int
        option.type = dict["type"] as? String
        if let wv = dict["webView"] { option.webView = AnyCodable(wv) }
        option.webJs = dict["webJs"] as? String
        option.dnsIp = dict["dnsIp"] as? String
        option.js = dict["js"] as? String
        option.bodyJs = dict["bodyJs"] as? String
        option.serverID = dict["serverID"] as? Int64
        option.webViewDelayTime = dict["webViewDelayTime"] as? Int64
        return option
    }

    func getHeaderMap() -> [String: Any]? {
        guard let headers = headers else { return nil }
        if let dict = headers.value as? [String: Any] { return dict }
        if let str = headers.value as? String,
           let data = str.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }
        return nil
    }

    func getBody() -> String? {
        guard let body = body else { return nil }
        if let str = body.value as? String { return str }
        if let dict = body.value as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: dict),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return String(describing: body.value)
    }

    func useWebView() -> Bool {
        guard let webView = webView else { return false }
        if let boolVal = webView.value as? Bool { return boolVal }
        if let strVal = webView.value as? String { return !strVal.isEmpty && strVal.lowercased() != "false" }
        if let intVal = webView.value as? Int { return intVal != 0 }
        return false
    }
}

// MARK: - AnyCodable 辅助类型

/// 用于处理 JSON 中 Any 类型的编解码
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) { value = str }
        else if let int = try? container.decode(Int.self) { value = int }
        else if let double = try? container.decode(Double.self) { value = double }
        else if let bool = try? container.decode(Bool.self) { value = bool }
        else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        }
        else if let arr = try? container.decode([AnyCodable].self) {
            value = arr.map { $0.value }
        }
        else { value = NSNull() }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let str as String: try container.encode(str)
        case let int as Int: try container.encode(int)
        case let double as Double: try container.encode(double)
        case let bool as Bool: try container.encode(bool)
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        case let arr as [Any]:
            try container.encode(arr.map { AnyCodable($0) })
        default: try container.encodeNil()
        }
    }
}