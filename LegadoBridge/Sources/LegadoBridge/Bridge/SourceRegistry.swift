import Foundation
import LegadoRuleCore

/// 订阅更新结果（安全更新：保留本地启停，远端消失只标记不删除）
struct SubscriptionUpdateResult {
    let added: Int
    let updated: Int
    let markedMissing: Int
    let unchanged: Int
}

/// Legado 书源注册表 — 与香色闺阁 XBS 源并行存储
/// 内存表 + Documents/legado_bridge_sources.json 持久化，避免重启后引擎空、原生列表仍有壳条目。
final class SourceRegistry {
    static let shared = SourceRegistry()

    /// 落盘时使用的 Bridge 元数据键（不影响引擎解析）
    private static let metaSubscriptionKey = "_lb_subscriptionUrl"
    private static let metaRemoteMissingKey = "_lb_remoteMissing"
    private static let metaUpdatedAtKey = "_lb_updatedAt"

    private var sourcesByUrl: [String: MemoryBridgeBookSource] = [:]
    /// 原始 Legado JSON，用于落盘与重启恢复
    private var rawJsonByUrl: [String: [String: Any]] = [:]
    /// 启用/禁用状态（默认 true），同步持久化到 rawJsonByUrl["enabled"]
    private var enabledByUrl: [String: Bool] = [:]
    /// 来自哪条订阅 URL（空表示手动导入）
    private var subscriptionUrlBySource: [String: String] = [:]
    /// 远端订阅中已消失，本地仅标记，不自动删除
    private var remoteMissingByUrl: [String: Bool] = [:]
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
            // 磁盘恢复：直接信任落盘的 enabled / 订阅元数据 / 远端缺失标记
            let count = try importJSONData(
                data,
                persist: false,
                preserveLocalEnabled: false,
                subscriptionUrl: nil,
                clearRemoteMissing: false
            )
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

    /// 导入书源。`preserveLocalEnabled` 为 true 时，已存在源保留本地启停，不被远端 JSON 覆盖。
    @discardableResult
    func importJSONData(
        _ data: Data,
        persist: Bool = true,
        preserveLocalEnabled: Bool = true,
        subscriptionUrl: String? = nil,
        clearRemoteMissing: Bool = true
    ) throws -> Int {
        let object = try JSONSerialization.jsonObject(with: data)
        var count = 0
        if let dict = object as? [String: Any], Self.isLegadoSource(dict) {
            _ = register(
                json: dict,
                preserveLocalEnabled: preserveLocalEnabled,
                subscriptionUrl: subscriptionUrl,
                clearRemoteMissing: clearRemoteMissing
            )
            count = 1
        } else if let array = object as? [[String: Any]] {
            for item in array where Self.isLegadoSource(item) {
                _ = register(
                    json: item,
                    preserveLocalEnabled: preserveLocalEnabled,
                    subscriptionUrl: subscriptionUrl,
                    clearRemoteMissing: clearRemoteMissing
                )
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

    /// 订阅安全更新：按 bookSourceUrl 合并；保留本地 enabled；本订阅内远端消失的源只标记 `_lb_remoteMissing`，不删除。
    @discardableResult
    func applySubscriptionUpdate(data: Data, subscriptionUrl: String) throws -> SubscriptionUpdateResult {
        let trimmed = subscriptionUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LegadoBridgeError.engineError("订阅 URL 为空") }

        let object = try JSONSerialization.jsonObject(with: data)
        var remoteItems: [[String: Any]] = []
        if let dict = object as? [String: Any], Self.isLegadoSource(dict) {
            remoteItems = [dict]
        } else if let array = object as? [[String: Any]] {
            remoteItems = array.filter { Self.isLegadoSource($0) }
        }
        if remoteItems.isEmpty {
            throw LegadoBridgeError.notLegadoFormat
        }

        let remoteUrls = Set(remoteItems.compactMap { $0["bookSourceUrl"] as? String }.filter { !$0.isEmpty })
        var added = 0
        var updated = 0
        var unchanged = 0

        for item in remoteItems {
            guard let url = item["bookSourceUrl"] as? String, !url.isEmpty else { continue }
            lock.lock()
            let existed = sourcesByUrl[url] != nil
            let oldJson = rawJsonByUrl[url]
            lock.unlock()

            _ = register(
                json: item,
                preserveLocalEnabled: true,
                subscriptionUrl: trimmed,
                clearRemoteMissing: true
            )

            lock.lock()
            let newJson = rawJsonByUrl[url]
            lock.unlock()
            if !existed {
                added += 1
            } else if Self.areCoreFieldsEqual(oldJson, newJson) {
                unchanged += 1
            } else {
                updated += 1
            }
        }

        // 同订阅下远端消失：只标记，不删除
        var markedMissing = 0
        lock.lock()
        for (url, sub) in subscriptionUrlBySource where sub == trimmed {
            if !remoteUrls.contains(url), remoteMissingByUrl[url] != true {
                remoteMissingByUrl[url] = true
                rawJsonByUrl[url]?[Self.metaRemoteMissingKey] = true
                markedMissing += 1
            }
        }
        lock.unlock()

        persistToDisk()
        return SubscriptionUpdateResult(
            added: added,
            updated: updated,
            markedMissing: markedMissing,
            unchanged: unchanged
        )
    }

    /// 用完整 JSON 覆盖单个源（结构化/JSON 编辑器保存）；保留订阅元数据与本地缺失标记策略由调用方决定。
    @discardableResult
    func updateSourceJSON(_ data: Data, forUrl expectedUrl: String?) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dict = object as? [String: Any], Self.isLegadoSource(dict) else {
            throw LegadoBridgeError.notLegadoFormat
        }
        guard let newUrl = dict["bookSourceUrl"] as? String, !newUrl.isEmpty else {
            throw LegadoBridgeError.notLegadoFormat
        }
        if let expectedUrl, !expectedUrl.isEmpty, expectedUrl != newUrl {
            // 允许改 URL：删旧键再写入
            lock.lock()
            let oldEnabled = enabledByUrl[expectedUrl]
            let oldSub = subscriptionUrlBySource[expectedUrl]
            let oldMissing = remoteMissingByUrl[expectedUrl]
            sourcesByUrl.removeValue(forKey: expectedUrl)
            rawJsonByUrl.removeValue(forKey: expectedUrl)
            enabledByUrl.removeValue(forKey: expectedUrl)
            subscriptionUrlBySource.removeValue(forKey: expectedUrl)
            remoteMissingByUrl.removeValue(forKey: expectedUrl)
            if activeSourceUrl == expectedUrl { activeSourceUrl = newUrl }
            lock.unlock()

            var mutable = dict
            if let oldEnabled { mutable["enabled"] = oldEnabled }
            if let oldSub { mutable[Self.metaSubscriptionKey] = oldSub }
            if let oldMissing { mutable[Self.metaRemoteMissingKey] = oldMissing }
            _ = register(json: mutable, preserveLocalEnabled: false, subscriptionUrl: oldSub, clearRemoteMissing: oldMissing != true)
        } else {
            lock.lock()
            let oldSub = subscriptionUrlBySource[newUrl]
            let oldMissing = remoteMissingByUrl[newUrl]
            lock.unlock()
            _ = register(
                json: dict,
                preserveLocalEnabled: true,
                subscriptionUrl: oldSub,
                clearRemoteMissing: oldMissing != true
            )
        }
        persistToDisk()
        return newUrl
    }

    private func register(
        json: [String: Any],
        preserveLocalEnabled: Bool,
        subscriptionUrl: String?,
        clearRemoteMissing: Bool
    ) -> MemoryBridgeBookSource {
        let source = try! MemoryBridgeBookSource(json: json)
        lock.lock()
        let url = source.bookSourceUrl
        let previousEnabled = enabledByUrl[url]
        let previousSub = subscriptionUrlBySource[url]
        let previousMissing = remoteMissingByUrl[url]

        sourcesByUrl[url] = source
        var mutableJson = json

        let resolvedEnabled: Bool
        if preserveLocalEnabled, let previousEnabled {
            resolvedEnabled = previousEnabled
        } else {
            resolvedEnabled = Self.isTruthy(mutableJson["enabled"], default: previousEnabled ?? true)
        }
        mutableJson["enabled"] = resolvedEnabled
        enabledByUrl[url] = resolvedEnabled

        let resolvedSub = subscriptionUrl ?? (mutableJson[Self.metaSubscriptionKey] as? String) ?? previousSub
        if let resolvedSub, !resolvedSub.isEmpty {
            subscriptionUrlBySource[url] = resolvedSub
            mutableJson[Self.metaSubscriptionKey] = resolvedSub
        } else {
            subscriptionUrlBySource.removeValue(forKey: url)
            mutableJson.removeValue(forKey: Self.metaSubscriptionKey)
        }

        if clearRemoteMissing {
            remoteMissingByUrl[url] = false
            mutableJson[Self.metaRemoteMissingKey] = false
        } else {
            let missing = Self.isTruthy(mutableJson[Self.metaRemoteMissingKey], default: previousMissing ?? false)
            remoteMissingByUrl[url] = missing
            mutableJson[Self.metaRemoteMissingKey] = missing
        }

        mutableJson[Self.metaUpdatedAtKey] = ISO8601DateFormatter().string(from: Date())
        rawJsonByUrl[url] = mutableJson
        activeSourceUrl = url
        lock.unlock()
        return source
    }

    private static func areCoreFieldsEqual(_ a: [String: Any]?, _ b: [String: Any]?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        let skip: Set<String> = [
            "enabled", metaSubscriptionKey, metaRemoteMissingKey, metaUpdatedAtKey
        ]
        let keys = Set(a.keys).union(b.keys).subtracting(skip)
        for key in keys {
            let va = a[key]
            let vb = b[key]
            if String(describing: va ?? NSNull()) != String(describing: vb ?? NSNull()) {
                return false
            }
        }
        return true
    }

    /// 兼容 Bool / NSNumber / "1"/"0"/"true" 等落盘形态
    private static func isTruthy(_ value: Any?, default defaultValue: Bool) -> Bool {
        guard let value else { return defaultValue }
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        if let s = value as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["1", "true", "yes", "y", "on"].contains(t) { return true }
            if ["0", "false", "no", "n", "off"].contains(t) { return false }
        }
        return defaultValue
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

    /// 严格按 URL 查找，禁止回退到 active/第一个源（目录/正文绑定解析用，防串源）
    func exactSource(forUrl url: String?) -> MemoryBridgeBookSource? {
        guard let url, !url.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return sourcesByUrl[url]
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
        subscriptionUrlBySource.removeValue(forKey: url)
        remoteMissingByUrl.removeValue(forKey: url)
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

    func isRemoteMissing(url: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return remoteMissingByUrl[url] ?? false
    }

    func subscriptionUrl(forSourceUrl url: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return subscriptionUrlBySource[url]
    }

    /// 管理页摘要：含分组、订阅、远端缺失标记、发现能力
    func allSourcesInfoDicts(groupFilter: String? = nil) -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        let filter = groupFilter?.trimmingCharacters(in: .whitespacesAndNewlines)
        return sourcesByUrl.values.compactMap { source -> [String: Any]? in
            let url = source.bookSourceUrl
            let raw = rawJsonByUrl[url] ?? [:]
            let group = (raw["bookSourceGroup"] as? String)
                ?? source.bookSourceGroup
                ?? ""
            if let filter, !filter.isEmpty, filter != "__all__" {
                if filter == "__ungrouped__" {
                    if !group.isEmpty { return nil }
                } else if group != filter {
                    return nil
                }
            }
            return [
                "bookSourceName": source.bookSourceName,
                "bookSourceUrl": url,
                "enabled": enabledByUrl[url] ?? true,
                "bookSourceGroup": group,
                "subscriptionUrl": subscriptionUrlBySource[url] ?? "",
                "remoteMissing": remoteMissingByUrl[url] ?? false,
                "searchUrl": (raw["searchUrl"] as? String) ?? (source.searchUrl ?? ""),
                "exploreUrl": (raw["exploreUrl"] as? String) ?? (source.exploreUrl ?? ""),
                "exploreSupported": source.supportsExplore
            ]
        }
        .sorted { ($0["bookSourceName"] as? String ?? "") < ($1["bookSourceName"] as? String ?? "") }
    }

    /// 去重后的分组名列表（不含空分组）
    func allGroups() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var set = Set<String>()
        for source in sourcesByUrl.values {
            let url = source.bookSourceUrl
            let raw = rawJsonByUrl[url] ?? [:]
            let group = ((raw["bookSourceGroup"] as? String) ?? source.bookSourceGroup ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !group.isEmpty { set.insert(group) }
        }
        return set.sorted()
    }

    /// 具备发现能力且已启用的书源
    func exploreCapableSources(groupFilter: String? = nil) -> [MemoryBridgeBookSource] {
        allSources().filter { source in
            guard isEnabled(url: source.bookSourceUrl), source.supportsExplore else { return false }
            guard let filter = groupFilter?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !filter.isEmpty, filter != "__all__" else { return true }
            let group = (source.bookSourceGroup ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if filter == "__ungrouped__" { return group.isEmpty }
            return group == filter
        }
    }

    /// 返回指定源的原始 JSON（格式化），供管理 VC 查看/编辑
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

    /// 结构化字段补丁（名称/搜索 URL/分组）；bookSourceUrl 不变
    @discardableResult
    func updateStructuredFields(
        url: String,
        name: String?,
        searchUrl: String?,
        group: String?
    ) throws -> Bool {
        lock.lock()
        guard var dict = rawJsonByUrl[url] else {
            lock.unlock()
            throw LegadoBridgeError.sourceNotFound
        }
        lock.unlock()
        if let name { dict["bookSourceName"] = name }
        if let searchUrl { dict["searchUrl"] = searchUrl }
        if let group { dict["bookSourceGroup"] = group }
        guard JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict) else {
            throw LegadoBridgeError.notLegadoFormat
        }
        _ = try updateSourceJSON(data, forUrl: url)
        return true
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

    /// 测试专用：清空内存表；可选删除持久化文件，以便验证磁盘恢复。
    func resetForTesting(clearPersistFile: Bool = true) {
        lock.lock()
        sourcesByUrl.removeAll()
        rawJsonByUrl.removeAll()
        enabledByUrl.removeAll()
        subscriptionUrlBySource.removeAll()
        remoteMissingByUrl.removeAll()
        activeSourceUrl = nil
        didRestoreFromDisk = false
        lock.unlock()
        if clearPersistFile {
            try? FileManager.default.removeItem(at: Self.persistFileURL)
        }
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
