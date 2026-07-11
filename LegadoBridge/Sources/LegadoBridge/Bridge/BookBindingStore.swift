import Foundation

/// 删源后对已绑定书籍的处理策略（可切换；默认保留书籍并标记书源不可用）。
/// 原版香色删源是否连带删书尚无真机取证，见 docs/ios-mcp-acceptance.md「删源语义待复核」。
@objc public enum SourceDeletePolicy: Int {
    /// 保留书籍绑定与阅读进度/缓存（由香色原生机制持有），仅标记书源不可用
    case keepBooksMarkUnavailable = 0
    /// 同时清除本桥接层对该源的书籍绑定（不主动删香色原生书架文件，避免无取证时误伤）
    case clearBridgeBindings = 1
}

/// 单本书的持久绑定：bookUrl ↔ sourceUrl ↔ bridgeToken，避免重启后串源。
struct BookBinding: Equatable {
    var bookUrl: String
    var sourceUrl: String
    var bridgeToken: String
    var sourceName: String
    var name: String
    var author: String
    var coverUrl: String
    /// 对应书源被删除或标记不可用时为 false；书籍记录仍保留
    var sourceAvailable: Bool
    var updatedAt: TimeInterval

    func toDictionary() -> [String: Any] {
        [
            "bookUrl": bookUrl,
            "sourceUrl": sourceUrl,
            "bridgeToken": bridgeToken,
            "sourceName": sourceName,
            "name": name,
            "author": author,
            "coverUrl": coverUrl,
            "sourceAvailable": sourceAvailable,
            "updatedAt": updatedAt
        ]
    }

    static func fromDictionary(_ dict: [String: Any]) -> BookBinding? {
        guard let bookUrl = dict["bookUrl"] as? String, !bookUrl.isEmpty,
              let sourceUrl = dict["sourceUrl"] as? String, !sourceUrl.isEmpty else {
            return nil
        }
        let token: String
        if let t = dict["bridgeToken"] as? String, !t.isEmpty {
            token = t
        } else {
            token = BookBindingStore.makeToken(bookUrl: bookUrl, sourceUrl: sourceUrl)
        }
        let available: Bool
        if let b = dict["sourceAvailable"] as? Bool {
            available = b
        } else if let n = dict["sourceAvailable"] as? NSNumber {
            available = n.boolValue
        } else {
            available = true
        }
        return BookBinding(
            bookUrl: bookUrl,
            sourceUrl: sourceUrl,
            bridgeToken: token,
            sourceName: (dict["sourceName"] as? String) ?? "",
            name: (dict["name"] as? String) ?? "",
            author: (dict["author"] as? String) ?? "",
            coverUrl: (dict["coverUrl"] as? String) ?? "",
            sourceAvailable: available,
            updatedAt: (dict["updatedAt"] as? TimeInterval)
                ?? (dict["updatedAt"] as? NSNumber)?.doubleValue
                ?? Date().timeIntervalSince1970
        )
    }
}

/// bookUrl / sourceUrl / bridgeToken 持久映射，落盘 Documents/legado_bridge_books.json。
/// 进度、章节缓存仍走香色原生机制；本 Store 只保证引擎侧不串源。
final class BookBindingStore {
    static let shared = BookBindingStore()

    private static let deletePolicyDefaultsKey = "LegadoBridgeSourceDeletePolicy"

    private var byBookUrl: [String: BookBinding] = [:]
    private var byToken: [String: String] = [:] // token → bookUrl
    private let lock = NSLock()
    private var didRestoreFromDisk = false

    private static var persistFileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        return docs.appendingPathComponent("legado_bridge_books.json")
    }

    private init() {}

    /// 当前删源策略（UserDefaults，可运行时切换）
    static var deletePolicy: SourceDeletePolicy {
        get {
            let raw = UserDefaults.standard.integer(forKey: deletePolicyDefaultsKey)
            return SourceDeletePolicy(rawValue: raw) ?? .keepBooksMarkUnavailable
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: deletePolicyDefaultsKey)
        }
    }

    static func makeToken(bookUrl: String, sourceUrl: String) -> String {
        let raw = "\(bookUrl)|\(sourceUrl)"
        let digest = raw.data(using: .utf8).map { data -> String in
            // 稳定短 token，避免把完整 URL 暴露到通知里过长
            var hash: UInt64 = 5381
            for b in data {
                hash = ((hash << 5) &+ hash) &+ UInt64(b)
            }
            return String(hash, radix: 16)
        } ?? UUID().uuidString
        return "lb_\(digest)"
    }

    @discardableResult
    func restoreFromDiskIfNeeded() -> Int {
        lock.lock()
        if didRestoreFromDisk {
            let n = byBookUrl.count
            lock.unlock()
            return n
        }
        didRestoreFromDisk = true
        lock.unlock()

        let url = Self.persistFileURL
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            writeDebugMarker("restore=0 missing")
            return 0
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let arr = object as? [[String: Any]] else {
            writeDebugMarker("restore=0 decode")
            return 0
        }
        lock.lock()
        byBookUrl.removeAll()
        byToken.removeAll()
        for item in arr {
            guard let binding = BookBinding.fromDictionary(item) else { continue }
            byBookUrl[binding.bookUrl] = binding
            byToken[binding.bridgeToken] = binding.bookUrl
        }
        let count = byBookUrl.count
        lock.unlock()
        writeDebugMarker("restore=\(count) ok")
        return count
    }

    /// 写入或更新绑定；同一 bookUrl 以最新 sourceUrl 为准（用户从搜索点开新结果）。
    @discardableResult
    func bind(
        bookUrl: String,
        sourceUrl: String,
        sourceName: String = "",
        name: String = "",
        author: String = "",
        coverUrl: String = "",
        bridgeToken: String? = nil,
        sourceAvailable: Bool = true
    ) -> BookBinding {
        let trimmedBook = bookUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSource = sourceUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBook.isEmpty, !trimmedSource.isEmpty else {
            // 无效输入时返回占位，避免 precondition 在生产路径崩溃
            return BookBinding(
                bookUrl: trimmedBook,
                sourceUrl: trimmedSource,
                bridgeToken: bridgeToken ?? "lb_invalid",
                sourceName: sourceName,
                name: name,
                author: author,
                coverUrl: coverUrl,
                sourceAvailable: sourceAvailable,
                updatedAt: Date().timeIntervalSince1970
            )
        }

        let token = bridgeToken?.isEmpty == false
            ? bridgeToken!
            : Self.makeToken(bookUrl: trimmedBook, sourceUrl: trimmedSource)

        lock.lock()
        if let old = byBookUrl[trimmedBook], old.bridgeToken != token {
            byToken.removeValue(forKey: old.bridgeToken)
        }
        let binding = BookBinding(
            bookUrl: trimmedBook,
            sourceUrl: trimmedSource,
            bridgeToken: token,
            sourceName: sourceName,
            name: name,
            author: author,
            coverUrl: coverUrl,
            sourceAvailable: sourceAvailable,
            updatedAt: Date().timeIntervalSince1970
        )
        byBookUrl[trimmedBook] = binding
        byToken[token] = trimmedBook
        lock.unlock()
        persistToDisk()
        return binding
    }

    func binding(forBookUrl bookUrl: String) -> BookBinding? {
        lock.lock()
        defer { lock.unlock() }
        return byBookUrl[bookUrl]
    }

    func binding(forToken token: String) -> BookBinding? {
        lock.lock()
        defer { lock.unlock() }
        guard let bookUrl = byToken[token] else { return nil }
        return byBookUrl[bookUrl]
    }

    func sourceUrl(forBookUrl bookUrl: String) -> String? {
        binding(forBookUrl: bookUrl)?.sourceUrl
    }

    func allBindings() -> [BookBinding] {
        lock.lock()
        defer { lock.unlock() }
        return Array(byBookUrl.values)
    }

    /// 删源策略入口：默认保留绑定并标记不可用；可选清除桥接层绑定。
    func applySourceDeleted(sourceUrl: String, policy: SourceDeletePolicy = BookBindingStore.deletePolicy) {
        switch policy {
        case .keepBooksMarkUnavailable:
            markSourceUnavailable(sourceUrl: sourceUrl)
        case .clearBridgeBindings:
            removeBindings(forSourceUrl: sourceUrl)
        }
    }

    func markSourceUnavailable(sourceUrl: String) {
        lock.lock()
        var changed = false
        for (key, var binding) in byBookUrl where binding.sourceUrl == sourceUrl {
            if binding.sourceAvailable {
                binding.sourceAvailable = false
                binding.updatedAt = Date().timeIntervalSince1970
                byBookUrl[key] = binding
                changed = true
            }
        }
        lock.unlock()
        if changed { persistToDisk() }
    }

    func markSourceAvailable(sourceUrl: String) {
        lock.lock()
        var changed = false
        for (key, var binding) in byBookUrl where binding.sourceUrl == sourceUrl {
            if !binding.sourceAvailable {
                binding.sourceAvailable = true
                binding.updatedAt = Date().timeIntervalSince1970
                byBookUrl[key] = binding
                changed = true
            }
        }
        lock.unlock()
        if changed { persistToDisk() }
    }

    func removeBindings(forSourceUrl sourceUrl: String) {
        lock.lock()
        let victims = byBookUrl.filter { $0.value.sourceUrl == sourceUrl }
        for (bookUrl, binding) in victims {
            byBookUrl.removeValue(forKey: bookUrl)
            byToken.removeValue(forKey: binding.bridgeToken)
        }
        lock.unlock()
        if !victims.isEmpty { persistToDisk() }
    }

    func removeBinding(bookUrl: String) {
        lock.lock()
        if let old = byBookUrl.removeValue(forKey: bookUrl) {
            byToken.removeValue(forKey: old.bridgeToken)
        }
        lock.unlock()
        persistToDisk()
    }

    private func persistToDisk() {
        lock.lock()
        let values = byBookUrl.values.map { $0.toDictionary() }
        lock.unlock()
        guard JSONSerialization.isValidJSONObject(values),
              let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted]) else {
            writeDebugMarker("persist=fail encode")
            return
        }
        do {
            try data.write(to: Self.persistFileURL, options: .atomic)
            writeDebugMarker("persist=\(values.count) ok")
        } catch {
            writeDebugMarker("persist=fail \(error.localizedDescription)")
        }
    }

    private func writeDebugMarker(_ msg: String) {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent("Documents/legado_binding_persist.txt")
        try? msg.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// 测试专用
    func resetForTesting(clearPersistFile: Bool = true) {
        lock.lock()
        byBookUrl.removeAll()
        byToken.removeAll()
        didRestoreFromDisk = false
        lock.unlock()
        if clearPersistFile {
            try? FileManager.default.removeItem(at: Self.persistFileURL)
        }
        UserDefaults.standard.removeObject(forKey: Self.deletePolicyDefaultsKey)
    }
}
