import Foundation

/// Legado 书源注册表 — 与香色闺阁 XBS 源并行存储
final class SourceRegistry {
    static let shared = SourceRegistry()

    private var sourcesByUrl: [String: MemoryBridgeBookSource] = [:]
    private var activeSourceUrl: String?
    private let lock = NSLock()

    private init() {}

    @discardableResult
    func register(part: BookSourcePart) -> MemoryBridgeBookSource {
        let source = MemoryBridgeBookSource(part: part)
        lock.lock()
        sourcesByUrl[source.bookSourceUrl] = source
        if activeSourceUrl == nil { activeSourceUrl = source.bookSourceUrl }
        lock.unlock()
        return source
    }

    @discardableResult
    func importJSONData(_ data: Data) throws -> Int {
        let object = try JSONSerialization.jsonObject(with: data)
        var count = 0
        if let dict = object as? [String: Any], Self.isLegadoSource(dict) {
            _ = register(json: dict)
            count = 1
        } else if let array = object as? [[String: Any]] {
            for item in array where Self.isLegadoSource(item) {
                _ = register(json: item)
                count += 1
            }
        }
        if count == 0 {
            throw LegadoBridgeError.notLegadoFormat
        }
        return count
    }

    private func register(json: [String: Any]) -> MemoryBridgeBookSource {
        let source = try! MemoryBridgeBookSource(json: json)
        lock.lock()
        sourcesByUrl[source.bookSourceUrl] = source
        if activeSourceUrl == nil { activeSourceUrl = source.bookSourceUrl }
        lock.unlock()
        return source
    }

    func source(forUrl url: String?) -> MemoryBridgeBookSource? {
        lock.lock()
        defer { lock.unlock() }
        if let url, let s = sourcesByUrl[url] { return s }
        if let active = activeSourceUrl { return sourcesByUrl[active] }
        return sourcesByUrl.values.first
    }

    func setActiveSourceUrl(_ url: String) {
        lock.lock()
        activeSourceUrl = url
        lock.unlock()
    }

    func allSources() -> [MemoryBridgeBookSource] {
        lock.lock()
        defer { lock.unlock() }
        return Array(sourcesByUrl.values)
    }

    func isLegadoManaged(url: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sourcesByUrl[url] != nil
    }

    static func isLegadoSource(_ dict: [String: Any]) -> Bool {
        guard let url = dict["bookSourceUrl"] as? String, !url.isEmpty else { return false }
        let hasSearch = (dict["searchUrl"] as? String)?.isEmpty == false
        let hasRuleSearch = dict["ruleSearch"] != nil
        return hasSearch || hasRuleSearch
    }

    static func isLegadoJSONData(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return false }
        if let dict = object as? [String: Any] { return isLegadoSource(dict) }
        if let array = object as? [[String: Any]] {
            return array.contains { isLegadoSource($0) }
        }
        return false
    }
}

enum LegadoBridgeError: Error, LocalizedError {
    case notLegadoFormat
    case sourceNotFound
    case engineError(String)

    var errorDescription: String? {
        switch self {
        case .notLegadoFormat: return "不是 Legado 书源 JSON 格式"
        case .sourceNotFound: return "未找到 Legado 书源"
        case .engineError(let msg): return msg
        }
    }
}
