//
//  SourceSessionStore.swift
//  LegadoRuleCore
//
//  书源会话变量：searchUrl 里 java.put 的值要能在同一源的 bookList JS 里 java.get 到。
//

import Foundation

enum SourceSessionStore {
    private static let lock = NSLock()
    private static var store: [String: [String: String]] = [:]

    static func variables(for sourceUrl: String) -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return store[sourceUrl] ?? [:]
    }

    static func get(_ key: String, sourceUrl: String?) -> String {
        guard let sourceUrl, !sourceUrl.isEmpty else { return "" }
        lock.lock()
        defer { lock.unlock() }
        return store[sourceUrl]?[key] ?? ""
    }

    static func put(_ key: String, value: String, sourceUrl: String?) {
        guard let sourceUrl, !sourceUrl.isEmpty, !key.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var map = store[sourceUrl] ?? [:]
        map[key] = value
        store[sourceUrl] = map
    }

    static func merge(_ vars: [String: String], for sourceUrl: String) {
        guard !sourceUrl.isEmpty, !vars.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var map = store[sourceUrl] ?? [:]
        for (k, v) in vars { map[k] = v }
        store[sourceUrl] = map
    }

    static func clear(sourceUrl: String?) {
        guard let sourceUrl, !sourceUrl.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        store.removeValue(forKey: sourceUrl)
    }
}

/// 可见浏览器等待：由 LegadoBridge 在启动时注入，走香色 LCStandarConfig → WebViewController_WK。
public enum BrowserAwaitGate {
    /// (url, title, sourceUrl) -> page HTML（可为空；调用方常再 ajax）
    public static var handler: ((String, String, String?) -> String)?

    public static func startBrowserAwait(url: String, title: String, sourceUrl: String?) -> String {
        guard !url.isEmpty else { return "" }
        if let handler {
            return handler(url, title, sourceUrl)
        }
        DebugLogger.shared.log("[BrowserAwait] handler 未注入，跳过 url=\(url)")
        return ""
    }
}
