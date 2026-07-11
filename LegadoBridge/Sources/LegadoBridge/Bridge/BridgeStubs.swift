import Foundation

/// Legado 引擎最小日志桩
public enum DebugLogger {
    public static let shared = DebugLoggerInstance()
    public struct DebugLoggerInstance {
        public func log(_ message: String) {
            #if DEBUG
            print("[LegadoRuleCore] \(message)")
            #endif
        }
    }
}

/// 与 legado-ios WebBook 兼容的章节模型
public struct WebChapter {
    public var title: String = ""
    public var url: String = ""
    public var index: Int = 0
    public var isVolume: Bool = false
    public var isVip: Bool = false
    public var isPay: Bool = false
    public var updateTime: Int64?

    public init(
        title: String = "",
        url: String = "",
        index: Int = 0,
        isVolume: Bool = false,
        isVip: Bool = false,
        isPay: Bool = false,
        updateTime: Int64? = nil
    ) {
        self.title = title
        self.url = url
        self.index = index
        self.isVolume = isVolume
        self.isVip = isVip
        self.isPay = isPay
        self.updateTime = updateTime
    }
}

/// 内存 Cookie 管理（替代 CoreData 版 CookieManager）
public final class CookieManager {
    public static let shared = CookieManager()
    private var store: [String: String] = [:]
    private let lock = NSLock()

    private init() {}

    public func getCookie(for domain: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return store[domain]
    }

    public func saveCookie(url: String, cookieString: String) {
        lock.lock()
        store[url] = cookieString
        lock.unlock()
    }

    public func mergeCookies(_ existing: String, _ newValue: String) -> String {
        if existing.isEmpty { return newValue }
        if newValue.isEmpty { return existing }
        return existing + "; " + newValue
    }

    /// 测试/夹具用：清空全部 Cookie
    public func removeAll() {
        lock.lock()
        store.removeAll()
        lock.unlock()
    }
}
