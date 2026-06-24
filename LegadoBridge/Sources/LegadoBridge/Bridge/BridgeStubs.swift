import Foundation

/// Legado 引擎在 Bridge 中的最小桩实现
enum DebugLogger {
    static let shared = DebugLoggerInstance()
    struct DebugLoggerInstance {
        func log(_ message: String) {
            #if DEBUG
            print("[LegadoBridge] \(message)")
            #endif
        }
    }
}

/// 与 legado-ios WebBook 兼容的章节模型
struct WebChapter {
    var title: String = ""
    var url: String = ""
    var index: Int = 0
    var isVolume: Bool = false
    var isVip: Bool = false
    var isPay: Bool = false
    var updateTime: Int64?
}

/// 内存 Cookie 管理（替代 CoreData 版 CookieManager）
final class CookieManager {
    static let shared = CookieManager()
    private var store: [String: String] = [:]
    private let lock = NSLock()

    private init() {}

    func getCookie(for domain: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return store[domain]
    }

    func saveCookie(url: String, cookieString: String) {
        lock.lock()
        store[url] = cookieString
        lock.unlock()
    }

    func mergeCookies(_ existing: String, _ newValue: String) -> String {
        if existing.isEmpty { return newValue }
        if newValue.isEmpty { return existing }
        return existing + "; " + newValue
    }
}
