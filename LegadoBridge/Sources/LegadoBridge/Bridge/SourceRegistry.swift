import Foundation

/// Legado 书源注册表 — 与香色闺阁 XBS 源并行存储
/// 内存表 + Documents/legado_bridge_sources.json 持久化，避免重启后引擎空、原生列表仍有壳条目。
final class SourceRegistry {
    static let shared = SourceRegistry()

    private var sourcesByUrl: [String: MemoryBridgeBookSource] = [:]
    /// 原始 Legado JSON，用于落盘与重启恢复
    private var rawJsonByUrl: [String: [String: Any]] = [:]
    /// 启用/禁用状态（默认 true），同步持久化到 rawJsonByUrl["enabled"]
    private var enabledByUrl: [String: Bool] = [:]
    private var activeSourceUrl: String?
    private let lock = NSLock()
    private var didRestoreFromDisk = false

    private static var persistFileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        return docs.appendingPathComponent("legado_bridge_sources.json")
    }

    private init() {}

    /// 启动时从磁盘恢复；可重复调用，仅首次生效。
    @discardableResult
    func restoreFromDiskIfNeeded() -> Int {
        lock.lock()
        if didRestoreFromDisk {
            let n = sourcesByUrl.count
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
        do {
            let count = try importJSONData(data, persist: false)
            writeDebugMarker("restore=\(count) ok")
            return count
        } catch {
            writeDebugMarker("restore=0 err=\(error.localizedDescription)")
            return 0
        }
    }

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
    func importJSONData(_ data: Data, persist: Bool = true) throws -> Int {
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
        if persist {
            persistToDisk()
        }
        return count
    }

    private func register(json: [String: Any]) -> MemoryBridgeBookSource {
        let source = try! MemoryBridgeBookSource(json: json)
        lock.lock()
        sourcesByUrl[source.bookSourceUrl] = source
        var mutableJson = json
        if mutableJson["enabled"] == nil {
            mutableJson["enabled"] = true
        }
        rawJsonByUrl[source.bookSourceUrl] = mutableJson
        enabledByUrl[source.bookSourceUrl] = (mutableJson["enabled"] as? Bool) ?? true
        activeSourceUrl = source.bookSourceUrl
        lock.unlock()
        return source
    }

    private func persistToDisk() {
        lock.lock()
        let values = Array(rawJsonByUrl.values)
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
        let path = (NSHomeDirectory() as NSString).appendingPathComponent("Documents/legado_registry_persist.txt")
        try? msg.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func source(forUrl url: String?) -> MemoryBridgeBookSource? {
        lock.lock()
        defer { lock.unlock() }
        if let url, let s = sourcesByUrl[url] { return s }
        if let active = activeSourceUrl,
           let s = sourcesByUrl[active],
           enabledByUrl[active] ?? true {
            return s
        }
        return sourcesByUrl.values.first { enabledByUrl[$0.bookSourceUrl] ?? true }
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

    // MARK: - 增删改（管理 VC 调用）

    func removeSource(url: String) {
        lock.lock()
        sourcesByUrl.removeValue(forKey: url)
        rawJsonByUrl.removeValue(forKey: url)
        enabledByUrl.removeValue(forKey: url)
        if activeSourceUrl == url {
            activeSourceUrl = sourcesByUrl.keys.first
        }
        lock.unlock()
        persistToDisk()
    }

    func setEnabled(url: String, enabled: Bool) {
        lock.lock()
        guard sourcesByUrl[url] != nil else {
            lock.unlock()
            return
        }
        enabledByUrl[url] = enabled
        rawJsonByUrl[url]?["enabled"] = enabled
        lock.unlock()
        persistToDisk()
    }

    func isEnabled(url: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabledByUrl[url] ?? true
    }

    /// 返回指定源的原始 JSON（格式化），供管理 VC 查看
    func sourceJSON(url: String) -> String? {
        lock.lock()
        guard let dict = rawJsonByUrl[url] else {
            lock.unlock()
            return nil
        }
        lock.unlock()
        guard JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(
                  withJSONObject: dict,
                  options: [.prettyPrinted, .sortedKeys]
              ) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
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
