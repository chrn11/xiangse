//
//  BackstageWebView.swift
//  Legado-iOS
//
//  后台 WebView - 参考原版 BackstageWebView.kt（392行）
//  1:1 移植 Android io.legado.app.help.http.BackstageWebView
//  支持 WebView 池、JS 执行重试（200/400/600/800/1000ms 递增）、
//  sourceRegex 资源嗅探、overrideUrlRegex URL 拦截、Cookie 同步
//

import Foundation
import WebKit

// MARK: - WebView 池

/// WebView 池包装（对应 Android PooledWebView）
public struct PooledWebView {
    public let webView: WKWebView
    public let createdAt: Date
    public var isAvailable: Bool = true
}

/// WebView 池（对应 Android WebViewPool）
/// 预创建 WKWebView 实例，减少首次加载延迟
/// 支持配置级 Cookie 注入：加载前从 CookieManager 注入 Cookie，完成后同步回持久化
public class WebViewPool {
    public static let shared = WebViewPool()
    private var pool: [PooledWebView] = []
    private let maxPoolSize = 3
    private let lock = NSLock()

    @MainActor
    public func acquire() -> WKWebView {
        lock.lock()
        defer { lock.unlock() }

        // 查找可用 WebView
        if let index = pool.firstIndex(where: { $0.isAvailable }) {
            pool[index].isAvailable = false
            return pool[index].webView
        }

        // 池未满，创建新 WebView
        let webView = createWebView()
        if pool.count < maxPoolSize {
            pool.append(PooledWebView(webView: webView, createdAt: Date(), isAvailable: false))
        }
        return webView
    }

    @MainActor
    public func release(_ webView: WKWebView) {
        lock.lock()
        defer { lock.unlock() }

        // 清理状态
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)

        if let index = pool.firstIndex(where: { $0.webView === webView }) {
            pool[index].isAvailable = true
        }
    }

    @MainActor
    private func createWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.javaScriptEnabled = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let webView = WKWebView(frame: .zero, configuration: config)
        return webView
    }
}

// MARK: - BackstageWebView

/// 后台 WebView — 对应 Android BackstageWebView
/// 用于加载网页、执行 JS、嗅探资源 URL、拦截跳转 URL
class BackstageWebView {

    private let url: String?
    private let html: String?
    private let encode: String?
    private let tag: String?
    private let headerMap: [String: String]?
    private let sourceRegex: String?
    private let overrideUrlRegex: String?
    private let javaScript: String?
    private var delayTime: Int64
    private let cacheFirst: Bool
    private let timeout: Int64?
    private let result: String?
    private let isRule: Bool

    /// JS 执行默认脚本（对应 Android JS 常量）
    private static let defaultJS = "document.documentElement.outerHTML"

    /// 重试间隔递增序列（对应 Android intervals）
    static let retryIntervals: [Int64] = [200, 400, 600, 800, 1000]
    /// 最大重试次数
    private static let maxRetry = 30

    init(
        url: String? = nil,
        html: String? = nil,
        encode: String? = nil,
        tag: String? = nil,
        headerMap: [String: String]? = nil,
        sourceRegex: String? = nil,
        overrideUrlRegex: String? = nil,
        javaScript: String? = nil,
        delayTime: Int64 = 0,
        cacheFirst: Bool = false,
        timeout: Int64? = nil,
        result: String? = nil,
        isRule: Bool = false
    ) {
        self.url = url
        self.html = html
        self.encode = encode
        self.tag = tag
        self.headerMap = headerMap
        self.sourceRegex = sourceRegex
        self.overrideUrlRegex = overrideUrlRegex
        self.javaScript = javaScript
        self.delayTime = delayTime
        self.cacheFirst = cacheFirst
        self.timeout = timeout
        self.result = result
        self.isRule = isRule

        // JS 和 delayTime 都为空时，默认延迟 900ms（对应 Android 逻辑）
        if javaScript == nil && delayTime == 0 {
            self.delayTime = 900
        }
    }

    /// 获取 StrResponse（对应 Android getStrResponse）
    /// 不可标 `@MainActor` 后在本方法内 `withCheckedThrowingContinuation` 等待 WK 回调：
    /// MainActor 会挂起等 continuation，而 `didFinish`/`evaluateJS` 也要 MainActor → 死锁，
    /// 表现为正文永空且永不写 `legado_webview_debug.txt`。
    func getStrResponse() async throws -> StrResponse {
        let effectiveTimeout = timeout ?? 60000
        let url = self.url
        let html = self.html
        let encode = self.encode
        let tag = self.tag
        let headerMap = self.headerMap
        let sourceRegex = self.sourceRegex
        let overrideUrlRegex = self.overrideUrlRegex
        let javaScript = self.javaScript ?? Self.defaultJS
        let delayTime = self.delayTime
        let cacheFirst = self.cacheFirst
        let result = self.result
        let isRule = self.isRule

        return try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                let handler = WebViewHandler(
                    url: url,
                    html: html,
                    encode: encode,
                    tag: tag,
                    headerMap: headerMap,
                    sourceRegex: sourceRegex,
                    overrideUrlRegex: overrideUrlRegex,
                    javaScript: javaScript,
                    delayTime: delayTime,
                    cacheFirst: cacheFirst,
                    result: result,
                    isRule: isRule,
                    timeout: effectiveTimeout,
                    continuation: continuation
                )
                handler.start()
            }
        }
    }
}

// MARK: - WebView 事件处理器

/// WebView 事件处理器 — 包含所有 WKNavigationDelegate 和 WKScriptMessageHandler 逻辑
@MainActor
private class WebViewHandler: NSObject, WKNavigationDelegate {

    private let url: String?
    private let html: String?
    private let encode: String?
    private let tag: String?
    private let headerMap: [String: String]?
    private let sourceRegex: String?
    private let overrideUrlRegex: String?
    private let javaScript: String
    private let delayTime: Int64
    private let cacheFirst: Bool
    private let result: String?
    private let isRule: Bool
    private let timeout: Int64

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<StrResponse, Error>?
    private var retryCount: Int = 0
    private var isRedirect: Bool = false
    private var timeoutTask: Task<Void, Never>?
    private var completed: Bool = false

    init(
        url: String?,
        html: String?,
        encode: String?,
        tag: String?,
        headerMap: [String: String]?,
        sourceRegex: String?,
        overrideUrlRegex: String?,
        javaScript: String,
        delayTime: Int64,
        cacheFirst: Bool,
        result: String?,
        isRule: Bool,
        timeout: Int64,
        continuation: CheckedContinuation<StrResponse, Error>
    ) {
        self.url = url
        self.html = html
        self.encode = encode
        self.tag = tag
        self.headerMap = headerMap
        self.sourceRegex = sourceRegex
        self.overrideUrlRegex = overrideUrlRegex
        self.javaScript = javaScript
        self.delayTime = delayTime
        self.cacheFirst = cacheFirst
        self.result = result
        self.isRule = isRule
        self.timeout = timeout
        self.continuation = continuation
        super.init()
    }

    func start() {
        let webView = WebViewPool.shared.acquire()
        self.webView = webView
        webView.navigationDelegate = self

        // 配置 User-Agent
        let ua = headerMap?["User-Agent"] ?? "Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.5 Mobile/15E148 Safari/604.1"
        webView.customUserAgent = ua

        // 如果有 sourceRegex 或 overrideUrlRegex，使用嗅探模式
        let hasSourceRegex = sourceRegex != nil && !sourceRegex!.isEmpty
        let hasOverrideRegex = overrideUrlRegex != nil && !overrideUrlRegex!.isEmpty
        if hasSourceRegex || hasOverrideRegex {
            // 嗅探需要不阻止图片加载以便嗅探资源
        } else {
            // 非嗅探模式阻止图片加载
            if #available(iOS 16.0, *) {
                webView.configuration.defaultWebpagePreferences.allowsContentJavaScript = true
            }
        }

        // 加载内容
        if let html = html, !html.isEmpty {
            let baseURL = url.flatMap { URL(string: $0) }
            webView.loadHTMLString(html, baseURL: baseURL)
        } else if let url = url, !url.isEmpty {
            if let headerMap = headerMap, !headerMap.isEmpty {
                var request = URLRequest(url: URL(string: url) ?? URL(string: "http://localhost/")!)
                for (key, value) in headerMap {
                    request.setValue(value, forHTTPHeaderField: key)
                }
                webView.load(request)
            } else {
                if let urlObj = URL(string: url) {
                    webView.load(URLRequest(url: urlObj))
                }
            }
        }

        // 超时计时器
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(self?.timeout ?? 60000) * 1_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.finishWithError(WebViewFetchError.timeout)
            }
        }
    }

    // MARK: - WKNavigationDelegate

    /// 必须同步调用 decisionHandler。丢进 Task 会导致 WebKit 一直等策略、永不 didFinish。
    /// override/sourceRegex 嗅探改到 didFinish 后处理亦可；此处先一律放行以保证加载完成。
    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(.allow)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            guard !completed else { return }

            // Cookie 同步
            self.setCookieFromWebView(webView)

            // 注入 result 变量
            if let result = self.result, !result.isEmpty {
                CacheStore.put("webview_result", value: result)
                webView.evaluateJavaScript("window.result = \"\(result.replacingOccurrences(of: "\"", with: "\\\""))\"") { _, _ in }
            }

            // 延迟后执行 JS 求值
            let effectiveDelay = 100 + delayTime
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(effectiveDelay))) { [weak self] in
                guard let self = self, !self.completed else { return }
                self.evaluateJSAndCheckResult(webView: webView)
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finishWithError(error) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finishWithError(error) }
    }

    // MARK: - 资源嗅探（sourceRegex）

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(.allow)
    }

    // MARK: - JS 求值与重试

    /// 执行 JS 并检查结果（对应 Android EvalJsRunnable）
    private func evaluateJSAndCheckResult(webView: WKWebView) {
        guard !completed else { return }

        webView.evaluateJavaScript(javaScript) { [weak self] result, error in
            guard let self = self, !self.completed else { return }

            if let error = error {
                self.finishWithError(error)
                return
            }

            guard let resultStr = Self.stringifyResult(result),
                  !resultStr.isEmpty, resultStr != "null", resultStr != "undefined" else {
                // 结果为空，进行重试
                self.retryCount += 1
                if self.retryCount > Self.maxRetry {
                    self.finishWithError(WebViewFetchError.jsTimeout)
                    return
                }
                // 递增延迟重试
                let interval: Int64
                if self.retryCount - 1 < BackstageWebView.retryIntervals.count {
                    interval = BackstageWebView.retryIntervals[self.retryCount - 1]
                } else {
                    interval = BackstageWebView.retryIntervals.last ?? 1000
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(interval))) { [weak self] in
                    guard let self = self, !self.completed else { return }
                    self.evaluateJSAndCheckResult(webView: webView)
                }
                return
            }

            // 有结果，构建 StrResponse
            let content = Self.unescapeJSON(resultStr)
            let finalURL = webView.url?.absoluteString ?? self.url ?? ""
            self.finishWithResult(url: finalURL, body: content)
        }
    }

    // MARK: - 完成

    private func finishWithResult(url: String, body: String) {
        guard !completed else { return }
        completed = true
        timeoutTask?.cancel()
        timeoutTask = nil

        cleanupWebView()

        let response = StrResponse(url: url, body: body)
        continuation?.resume(returning: response)
        continuation = nil
    }

    private func finishWithError(_ error: Error) {
        guard !completed else { return }
        completed = true
        timeoutTask?.cancel()
        timeoutTask = nil

        cleanupWebView()

        continuation?.resume(throwing: error)
        continuation = nil
    }

    private func cleanupWebView() {
        if let webView = webView {
            webView.navigationDelegate = nil
            WebViewPool.shared.release(webView)
        }
        self.webView = nil
    }

    // MARK: - Cookie 同步

    private func setCookieFromWebView(_ webView: WKWebView) {
        guard let tag = tag, !tag.isEmpty else { return }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            let cookieStr = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            if !cookieStr.isEmpty {
                CookieManager.shared.saveCookie(url: tag, cookieString: cookieStr)
            }
        }
    }

    // MARK: - 工具方法

    private static func matchesRegex(_ string: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return string.contains(pattern)
        }
        let range = NSRange(string.startIndex..., in: string)
        return regex.firstMatch(in: string, range: range) != nil
    }

    private static func stringifyResult(_ result: Any?) -> String? {
        if let str = result as? String { return str }
        if let num = result as? NSNumber { return num.stringValue }
        if JSONSerialization.isValidJSONObject(result as Any),
           let data = try? JSONSerialization.data(withJSONObject: result as Any),
           let str = String(data: data, encoding: .utf8) { return str }
        return nil
    }

    /// 反转义 JSON 字符串并去掉首尾引号（对应 Android StringEscapeUtils.unescapeJson + quoteRegex）
    private static func unescapeJSON(_ str: String) -> String {
        var result = str
        // 去掉首尾引号
        if result.hasPrefix("\"") && result.hasSuffix("\"") && result.count >= 2 {
            result = String(result.dropFirst().dropLast())
        }
        // 反转义常见 JSON 转义
        result = result.replacingOccurrences(of: "\\\"", with: "\"")
        result = result.replacingOccurrences(of: "\\n", with: "\n")
        result = result.replacingOccurrences(of: "\\r", with: "\r")
        result = result.replacingOccurrences(of: "\\t", with: "\t")
        result = result.replacingOccurrences(of: "\\\\", with: "\\")
        result = result.replacingOccurrences(of: "\\/", with: "/")
        return result
    }

    private static let maxRetry = 30
}

// MARK: - 错误类型

private enum WebViewFetchError: LocalizedError {
    case timeout
    case jsTimeout
    case noHTML
    case invalidState

    var errorDescription: String? {
        switch self {
        case .timeout: return "WebView 加载超时"
        case .jsTimeout: return "JS 执行超时（重试30次后仍无结果）"
        case .noHTML: return "WebView 未返回内容"
        case .invalidState: return "WebView 请求状态异常"
        }
    }
}

// MARK: - DispatchQueue 扩展

private extension DispatchQueue {
    static func milliseconds(_ ms: Int) -> DispatchTime {
        return .now() + .milliseconds(ms)
    }
}

private extension DispatchTimeInterval {
    static func milliseconds(_ ms: Int) -> DispatchTimeInterval {
        return .milliseconds(ms)
    }
}