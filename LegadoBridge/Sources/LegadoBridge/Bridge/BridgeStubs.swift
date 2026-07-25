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

/// Cookie 管理（内存 + Documents 落盘；替代 CoreData 版 CookieManager）
/// 可见 WebView 回灌后若进程被杀，仍需能注入后续搜索请求。
public final class CookieManager {
    public static let shared = CookieManager()
    private var store: [String: String] = [:]
    private let lock = NSLock()
    private var loadedFromDisk = false

    private static var persistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/legado_cookie_store.json")
    }

    private init() {
        loadFromDiskIfNeeded()
    }

    private func loadFromDiskIfNeeded() {
        guard !loadedFromDisk else { return }
        loadedFromDisk = true
        let url = Self.persistURL
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return }
        store = obj
    }

    private func persistLocked() {
        let url = Self.persistURL
        guard let data = try? JSONSerialization.data(withJSONObject: store, options: []) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public func getCookie(for domain: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        loadFromDiskIfNeeded()
        if let direct = store[domain], !direct.isEmpty { return direct }
        // 兼容 bookSourceUrl 全串与 host 两种 key
        if let host = URL(string: domain)?.host, let c = store[host], !c.isEmpty {
            return c
        }
        return store[domain]
    }

    public func saveCookie(url: String, cookieString: String) {
        lock.lock()
        defer { lock.unlock() }
        loadFromDiskIfNeeded()
        store[url] = cookieString
        persistLocked()
    }

    /// 删除指定 key（书源 URL / host）的 Cookie
    public func removeCookie(for url: String) {
        lock.lock()
        defer { lock.unlock() }
        loadFromDiskIfNeeded()
        store.removeValue(forKey: url)
        if let host = URL(string: url)?.host {
            store.removeValue(forKey: host)
        }
        persistLocked()
    }

    public func mergeCookies(_ existing: String, _ newValue: String) -> String {
        if existing.isEmpty { return newValue }
        if newValue.isEmpty { return existing }
        // 按 name 去重合并，避免反复回灌无限膨胀
        var map: [String: String] = [:]
        for raw in (existing + ";" + newValue).split(separator: ";") {
            let parts = raw.split(separator: "=", maxSplits: 1).map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.count == 2, !parts[0].isEmpty else { continue }
            map[parts[0]] = parts[1]
        }
        return map.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    /// 测试/夹具用：清空全部 Cookie
    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        store.removeAll()
        persistLocked()
        try? FileManager.default.removeItem(at: Self.persistURL)
    }
}
