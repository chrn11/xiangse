import Foundation
import LegadoRuleCore

/// 订阅更新结果（安全更新：保留本地启停，远端消失只标记不删除）
struct SubscriptionUpdateResult {
    let added: Int
    let updated: Int
    let markedMissing: Int
    let unchanged: Int
    /// True when the registry state changed, including subscription metadata
    /// or a remote-missing flag that was cleared.
    let mutated: Bool
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
    /// In-process tombstones let the coordinator reject a late callback or
    /// stale picker selection after removeSource, even though the row no
    /// longer exists in `sourcesByUrl`.
    private var retiredSourceURLs: Set<String> = []
    private var activeSourceUrl: String?
    private let lock = NSLock()
    private enum RestoreState {
        case idle
        case restoring
        case restored
    }
    /// Restore is reached from more than one launch hook.  A condition keeps
    /// concurrent callers from importing the same file twice, while a failed
    /// attempt returns to `.idle` so a later hook can retry after the file
    /// arrives or is repaired.
    private let restoreCondition = NSCondition()
    private var restoreState: RestoreState = .idle

    /// 与 ObjC `LBImportHooks` 的 JSON Hook 重入键一致：解析阶段置位，避免
    /// `JSONObjectWithData` Hook 再走 `Core.import` 写共享 Documents。
    private static let jsonHookReentryKey = "LegadoBridge.JSONHook.Reentry"

    /// 测试可注入独立落盘路径，避免多用例抢 `Documents/legado_bridge_sources.json`。
    var persistFileURLOverride: URL?

    private static var defaultPersistFileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        return docs.appendingPathComponent("legado_bridge_sources.json")
    }

    private var persistFileURL: URL {
        persistFileURLOverride ?? Self.defaultPersistFileURL
    }

    private init() {}

    /// 在 JSON Hook 重入保护下执行，防止 `importJSONData` 解析时触发二次导入。
    private func withJSONHookSuppressed<T>(_ body: () throws -> T) rethrows -> T {
        let td = Thread.current.threadDictionary
        let had = td[Self.jsonHookReentryKey] != nil
        if !had {
            td[Self.jsonHookReentryKey] = true
        }
        defer {
            if !had {
                td.removeObject(forKey: Self.jsonHookReentryKey)
            }
        }
        return try body()
    }

    /// 启动时从磁盘恢复；成功或确认文件不可用后闩锁；文件尚不存在时允许稍后重试。
    @discardableResult
    func restoreFromDiskIfNeeded() -> Int {
        var waitedForAnotherAttempt = false
        restoreCondition.lock()
        while restoreState == .restoring {
            waitedForAnotherAttempt = true
            restoreCondition.wait()
        }
        if restoreState == .restored {
            lock.lock()
            let n = sourcesByUrl.count
            lock.unlock()
            restoreCondition.unlock()
            return n
        }
        // A waiter observes the result of the in-flight attempt.  It must not
        // immediately start a second import after a failed attempt; the next
        // explicit launch hook is the retry boundary.
        if waitedForAnotherAttempt {
            restoreCondition.unlock()
            return 0
        }
        restoreState = .restoring
        restoreCondition.unlock()

        let result = performRestoreFromDisk()
        restoreCondition.lock()
        restoreState = result.state
        restoreCondition.broadcast()
        restoreCondition.unlock()
        return result.count
    }

    private func performRestoreFromDisk() -> (count: Int, state: RestoreState) {
        let url = persistFileURL
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            writeDebugMarker("restore=0 missing")
            // 不闩锁：测试/晚到落盘仍可再次恢复。
            return (0, .idle)
        }
        // 空数组 `[]`：视为尚无源，不闩锁、不抛「非 Legado 格式」。
        if let arr = try? withJSONHookSuppressed({
            try JSONSerialization.jsonObject(with: data)
        }) as? [Any], arr.isEmpty {
            writeDebugMarker("restore=0 empty")
            return (0, .idle)
        }

        do {
            // 磁盘恢复：直接信任落盘的 enabled / 订阅元数据 / 远端缺失标记。
            let count = try importJSONData(
                data,
                persist: false,
                preserveLocalEnabled: false,
                subscriptionUrl: nil,
                clearRemoteMissing: false
            )
            writeDebugMarker("restore=\(count) ok")
            return (count, count > 0 ? .restored : .idle)
        } catch {
            // 解析/解码失败必须回到 idle；下一次 launch hook 可以在文件
            // 被补齐后重试，而不会永久复用一次失败的状态。
            writeDebugMarker("restore=0 err=\(error.localizedDescription)")
            return (0, .idle)
        }
    }

    @discardableResult
    func register(part: BookSourcePart) -> MemoryBridgeBookSource {
        let source = MemoryBridgeBookSource(part: part)
        lock.lock()
        retiredSourceURLs.remove(source.bookSourceUrl)
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
        let object = try withJSONHookSuppressed {
            try JSONSerialization.jsonObject(with: data)
        }
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

        let object = try withJSONHookSuppressed {
            try JSONSerialization.jsonObject(with: data)
        }
        var remoteItems: [[String: Any]] = []
        if let dict = object as? [String: Any], Self.isLegadoSource(dict) {
            remoteItems = [dict]
        } else if let array = object as? [[String: Any]] {
            remoteItems = array.filter { Self.isLegadoSource($0) }
        }
        if remoteItems.isEmpty {
            throw LegadoBridgeError.notLegadoFormat
        }

        let remoteUrls = Set(
            remoteItems.compactMap { $0["bookSourceUrl"] as? String }
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        )
        var added = 0
        var updated = 0
        var unchanged = 0
        var mutated = false

        for item in remoteItems {
            guard let url = item["bookSourceUrl"] as? String,
                  !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            lock.lock()
            let existed = sourcesByUrl[url] != nil
            let oldJson = rawJsonByUrl[url]
            let oldSub = subscriptionUrlBySource[url]
            let oldMissing = remoteMissingByUrl[url] ?? false
            lock.unlock()

            _ = register(
                json: item,
                preserveLocalEnabled: true,
                subscriptionUrl: trimmed,
                clearRemoteMissing: true,
                makeActive: false
            )

            lock.lock()
            let newJson = rawJsonByUrl[url]
            lock.unlock()
            if !existed {
                added += 1
                mutated = true
            } else if Self.areCoreFieldsEqual(oldJson, newJson),
                      oldSub == trimmed,
                      !oldMissing {
                unchanged += 1
            } else {
                updated += 1
                mutated = true
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
                mutated = true
            }
        }
        lock.unlock()

        persistToDisk()
        return SubscriptionUpdateResult(
            added: added,
            updated: updated,
            markedMissing: markedMissing,
            unchanged: unchanged,
            mutated: mutated
        )
    }

    /// 用完整 JSON 覆盖单个源（结构化/JSON 编辑器保存）；保留订阅元数据与本地缺失标记策略由调用方决定。
    @discardableResult
    func updateSourceJSON(_ data: Data, forUrl expectedUrl: String?) throws -> String {
        let object = try withJSONHookSuppressed {
            try JSONSerialization.jsonObject(with: data)
        }
        guard let dict = object as? [String: Any], Self.isLegadoSource(dict) else {
            throw LegadoBridgeError.notLegadoFormat
        }
        guard let newUrl = dict["bookSourceUrl"] as? String, !newUrl.isEmpty else {
            throw LegadoBridgeError.notLegadoFormat
        }
        // This API edits an existing row, so it must carry the exact identity
        // that was shown by the editor.  Accepting nil/empty here would turn a
        // typo into an implicit import or allow a destination URL to overwrite
        // another row.  A true rename also needs an atomic cross-store
        // migration (bindings/cache/subscription metadata), which is not
        // implemented; reject it before touching either side.
        guard let expectedUrl,
              !expectedUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LegadoBridgeError.sourceNotFound
        }
        lock.lock()
        let expectedExists = sourcesByUrl[expectedUrl] != nil
        lock.unlock()
        guard expectedExists else { throw LegadoBridgeError.sourceNotFound }
        guard expectedUrl == newUrl else {
            throw LegadoBridgeError.engineError("bookSourceUrl 暂不支持修改")
        }

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
        persistToDisk()
        return newUrl
    }

    private func register(
        json: [String: Any],
        preserveLocalEnabled: Bool,
        subscriptionUrl: String?,
        clearRemoteMissing: Bool,
        makeActive: Bool = true
    ) -> MemoryBridgeBookSource {
        // yckceo 等仓常见 lastUpdateTime/respondTime 写成字符串；try! 解码失败会直接崩进程
        let sanitized = Self.sanitizeSourceJSON(json)
        let source: MemoryBridgeBookSource
        do {
            source = try MemoryBridgeBookSource(json: sanitized)
        } catch {
            // 再剥数值字段兜底一次，避免坏源拖垮冷启动
            var stripped = sanitized
            for key in ["lastUpdateTime", "respondTime", "weight", "customOrder", "bookSourceType"] {
                if stripped[key] is String { stripped.removeValue(forKey: key) }
            }
            do {
                source = try MemoryBridgeBookSource(json: stripped)
            } catch {
                // 最小可注册壳：仅 URL/名称，保证冷启动不崩
                let url = (json["bookSourceUrl"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "legado://invalid"
                let name = (json["bookSourceName"] as? String) ?? "未命名书源"
                var shell: [String: Any] = [
                    "bookSourceUrl": url,
                    "bookSourceName": name,
                ]
                if let searchUrl = json["searchUrl"] as? String, !searchUrl.isEmpty {
                    shell["searchUrl"] = searchUrl
                }
                if let ruleSearch = json["ruleSearch"] as? [String: Any] {
                    shell["ruleSearch"] = ruleSearch
                }
                if let s = try? MemoryBridgeBookSource(json: shell) {
                    source = s
                } else {
                    source = MemoryBridgeBookSource(part: BookSourcePart(bookSourceUrl: url, bookSourceName: name))
                }
            }
        }
        lock.lock()
        let url = source.bookSourceUrl
        retiredSourceURLs.remove(url)
        let previousEnabled = enabledByUrl[url]
        let previousSub = subscriptionUrlBySource[url]
        let previousMissing = remoteMissingByUrl[url]

        sourcesByUrl[url] = source
        var mutableJson = sanitized

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
        if makeActive {
            activeSourceUrl = url
        }
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
        let url = persistFileURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            writeDebugMarker("persist=\(values.count) ok")
        } catch {
            writeDebugMarker("persist=fail \(error.localizedDescription)")
        }
    }

    private func writeDebugMarker(_ msg: String) {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent("Documents/legado_registry_persist.txt")
        try? msg.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Resolve a source for a runtime operation.
    ///
    /// Any non-nil URL is an explicit identity and must be non-empty, exact,
    /// and enabled.  Only nil is allowed to use the active/first-enabled
    /// convenience path used by source-list UI callers.
    func source(forUrl url: String?) -> MemoryBridgeBookSource? {
        lock.lock()
        defer { lock.unlock() }
        if let url {
            guard !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            guard let source = sourcesByUrl[url], enabledByUrl[url] ?? true else {
                return nil
            }
            return source
        }
        if let active = activeSourceUrl,
           let s = sourcesByUrl[active],
           enabledByUrl[active] ?? true {
            return s
        }
        return sourcesByUrl.values.first { enabledByUrl[$0.bookSourceUrl] ?? true }
    }

    /// 严格按 URL 查找，禁止回退到 active/第一个源（目录/正文绑定解析用，防串源）。
    /// 运行时显式源必须同时处于 enabled 状态。
    func exactSource(forUrl url: String?) -> MemoryBridgeBookSource? {
        guard let url,
              !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let source = sourcesByUrl[url], enabledByUrl[url] ?? true else {
            return nil
        }
        return source
    }

    func setActiveSourceUrl(_ url: String) {
        lock.lock()
        guard !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              sourcesByUrl[url] != nil,
              enabledByUrl[url] ?? true else {
            lock.unlock()
            return
        }
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

    func isLegadoSourceRetired(url: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return retiredSourceURLs.contains(url)
    }

    // MARK: - 增删改（管理 VC 调用）

    @discardableResult
    func removeSource(url: String) -> Bool {
        lock.lock()
        guard sourcesByUrl[url] != nil else {
            lock.unlock()
            return false
        }
        sourcesByUrl.removeValue(forKey: url)
        rawJsonByUrl.removeValue(forKey: url)
        enabledByUrl.removeValue(forKey: url)
        subscriptionUrlBySource.removeValue(forKey: url)
        remoteMissingByUrl.removeValue(forKey: url)
        retiredSourceURLs.insert(url)
        if activeSourceUrl == url {
            activeSourceUrl = sourcesByUrl.keys.first
        }
        lock.unlock()
        persistToDisk()
        return true
    }

    @discardableResult
    func setEnabled(url: String, enabled: Bool) -> Bool {
        lock.lock()
        guard sourcesByUrl[url] != nil else {
            lock.unlock()
            return false
        }
        let changed = (enabledByUrl[url] ?? true) != enabled
        guard changed else {
            lock.unlock()
            return false
        }
        enabledByUrl[url] = enabled
        rawJsonByUrl[url]?["enabled"] = enabled
        lock.unlock()
        persistToDisk()
        return true
    }

    func isEnabled(url: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard sourcesByUrl[url] != nil else { return false }
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
        switchableSources(groupFilter: groupFilter).filter(\.supportsExplore)
    }

    /// 发现页切源列表：已启用且 exploreUrl 非空（放宽 resolve 校验，B-05/B-07）
    func switchableSources(groupFilter: String? = nil) -> [MemoryBridgeBookSource] {
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

    /// 将仓源常见的字符串数值字段收成 Int64，避免 JSONDecoder 类型不匹配触发 try! 崩进程。
    /// 同时去掉 `ruleExplore: []` 这类空数组（yckceo 常见），否则整源解码失败会退成无详情/目录规则的壳。
    private static func sanitizeSourceJSON(_ json: [String: Any]) -> [String: Any] {
        var out = json
        for key in ["lastUpdateTime", "respondTime", "weight", "customOrder", "bookSourceType"] {
            guard let raw = out[key] else { continue }
            if raw is Int || raw is Int64 || raw is NSNumber { continue }
            if let s = raw as? String {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if let v = Int64(trimmed) {
                    out[key] = v
                } else {
                    out.removeValue(forKey: key)
                }
            }
        }
        for key in ["ruleExplore", "ruleSearch", "ruleBookInfo", "ruleToc", "ruleContent", "ruleReview"] {
            if let arr = out[key] as? [Any], arr.isEmpty {
                out.removeValue(forKey: key)
            }
        }
        return out
    }

    static func isLegadoSource(_ dict: [String: Any]) -> Bool {
        guard let url = dict["bookSourceUrl"] as? String,
              !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
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

    /// Extract exact source identities from an import payload so callers can
    /// invalidate only the affected in-memory explore caches.
    static func sourceURLs(in data: Data) -> Set<String> {
        guard let object = try? SourceRegistry.shared.withJSONHookSuppressed({
            try JSONSerialization.jsonObject(with: data)
        }) else { return [] }
        let dicts: [[String: Any]]
        if let dict = object as? [String: Any] {
            dicts = [dict]
        } else if let array = object as? [[String: Any]] {
            dicts = array
        } else {
            return []
        }
        return Set(dicts.compactMap { dict in
            guard Self.isLegadoSource(dict),
                  let url = dict["bookSourceUrl"] as? String,
                  !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return url
        })
    }

    /// 测试专用：清空内存表；可选删除持久化文件，以便验证磁盘恢复。
    func resetForTesting(clearPersistFile: Bool = true) {
        // Do not clear the in-memory tables while a launch hook is importing
        // the restore file.  This is test-only but also makes a simulated
        // process reset deterministic under concurrent callbacks.
        restoreCondition.lock()
        while restoreState == .restoring {
            restoreCondition.wait()
        }
        restoreState = .idle
        restoreCondition.broadcast()
        restoreCondition.unlock()
        lock.lock()
        sourcesByUrl.removeAll()
        rawJsonByUrl.removeAll()
        enabledByUrl.removeAll()
        subscriptionUrlBySource.removeAll()
        remoteMissingByUrl.removeAll()
        retiredSourceURLs.removeAll()
        activeSourceUrl = nil
        lock.unlock()
        if clearPersistFile {
            try? FileManager.default.removeItem(at: persistFileURL)
        }
    }
}

enum LegadoBridgeError: Error, LocalizedError {
    case notLegadoFormat
    case sourceNotFound
    case engineError(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .notLegadoFormat: return "不是 Legado 书源 JSON 格式"
        case .sourceNotFound: return "未找到 Legado 书源"
        case .engineError(let msg): return msg
        case .timeout: return "请求超时，请换源或稍后重试"
        }
    }
}
