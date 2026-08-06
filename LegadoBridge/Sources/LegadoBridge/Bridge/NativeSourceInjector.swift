import Foundation
import LegadoRuleCore

/// 将 Legado 书源投影到香色站点列表（TC-06：禁止生产路径写 manager / save）。
/// 一次性 legacy shell 删除仅允许 TC-10 经 allowlist 调用 `removeFromNativeManager(allowLegacyMigration:)`。
enum NativeSourceInjector {
    private static let readyPath = (NSHomeDirectory() as NSString)
        .appendingPathComponent("Documents/legado_native_ready.txt")

    private static var projectionGeneration: UInt64 = 0
    private static let projectionLock = NSLock()

    static func invalidateProjectionCache() {
        projectionLock.lock()
        projectionGeneration &+= 1
        projectionLock.unlock()
        NotificationCenter.default.post(name: .init("LegadoSourceProjectionInvalidated"), object: nil)
    }

    static func currentProjectionGeneration() -> UInt64 {
        projectionLock.lock()
        defer { projectionLock.unlock() }
        return projectionGeneration
    }

    /// TC-06：生产启动同步已退役；只失效投影并通知列表刷新。
    static func syncToNativeManagerWhenReady(sources: [MemoryBridgeBookSource]) {
        NativeManagerPersistenceGuard.recordSyncAttempt()
        _ = sources
        invalidateProjectionCache()
        postNativeListUpdate()
        try? "TC06_NO_SYNC projection-only".write(toFile: readyPath, atomically: true, encoding: .utf8)
    }

    /// TC-06：禁止 merge/save；只刷新 ephemeral projection。
    static func syncToNativeManager(sources: [MemoryBridgeBookSource]) {
        NativeManagerPersistenceGuard.recordSyncAttempt()
        _ = sources
        invalidateProjectionCache()
        postNativeListUpdate()
    }

    static func enabledProjections() -> [NativeSourceListProjection] {
        SourceRegistry.shared.allSources()
            .filter { SourceRegistry.shared.isEnabled(url: $0.bookSourceUrl) }
            .map {
                NativeSourceListProjection.make(
                    exactSourceUrl: $0.bookSourceUrl,
                    displaySourceName: $0.bookSourceName,
                    enabled: true
                )
            }
    }

    static func allLegadoSourceNames() -> [String] {
        listKeys(nativeNames: [])
    }

    /// 列表合并键：无冲突用 displaySourceName；与原生或其它 Legado 冲突用 projectionKey（永不写 ·Legado）。
    static func listKeys(nativeNames: [String]) -> [String] {
        let nativeSet = Set(nativeNames)
        var seen = nativeSet
        var out: [String] = []
        for proj in enabledProjections() {
            if seen.contains(proj.displaySourceName) {
                out.append(proj.projectionKey)
            } else {
                out.append(proj.displaySourceName)
                seen.insert(proj.displaySourceName)
            }
        }
        return out
    }

    static func isLegadoSourceName(_ name: String) -> Bool {
        if NativeSourceListProjection.isProjectionKey(name) {
            return enabledProjections().contains { $0.projectionKey == name }
        }
        if name.hasSuffix("·Legado") {
            let base = String(name.dropLast("·Legado".count))
            return SourceRegistry.shared.allSources().contains { $0.bookSourceName == base }
        }
        return enabledProjections().contains { $0.displaySourceName == name }
            || SourceRegistry.shared.allSources().contains { $0.bookSourceName == name }
    }

    static func nativeModel(forSourceName name: String) -> [String: Any]? {
        let projections = enabledProjections()
        if let proj = projections.first(where: { $0.projectionKey == name }) {
            return proj.ephemeralListDictionary()
        }
        let lookup = name.hasSuffix("·Legado")
            ? String(name.dropLast("·Legado".count))
            : name
        if let proj = projections.first(where: { $0.displaySourceName == lookup }) {
            return proj.ephemeralListDictionary()
        }
        return nil
    }

    /// 仅 TC-10 legacy migration 可写 manager；生产删源只改 SourceRegistry。
    static func removeFromNativeManager(names: [String], allowLegacyMigration: Bool = false) {
        guard allowLegacyMigration else {
            invalidateProjectionCache()
            postNativeListUpdate()
            return
        }
        guard !names.isEmpty, let manager = sharedManager() else { return }
        NativeManagerPersistenceGuard.recordSaveAttempt()
        let listSel = NSSelectorFromString("dicModelList")
        guard manager.responds(to: listSel) else { return }
        let raw = manager.perform(listSel)?.takeUnretainedValue()
        let current = (raw as? NSDictionary) ?? [:]
        let merged = NSMutableDictionary(dictionary: current)
        var also = Set(names)
        for n in names {
            also.insert(n + "·Legado")
        }
        for key in merged.allKeys {
            guard let name = key as? String else { continue }
            guard also.contains(name) || NativeSourceListProjection.isProjectionKey(name) else { continue }
            if let model = merged[name] as? NSDictionary,
               let marker = model[XiangseAdapter.legadoMarkerKey] as? String,
               marker == XiangseAdapter.legadoMarkerValue {
                merged.removeObject(forKey: name)
            }
        }
        let setSel = NSSelectorFromString("setDicModelList:")
        if manager.responds(to: setSel) {
            _ = manager.perform(setSel, with: merged)
        } else {
            manager.setValue(merged, forKey: "dicModelList")
        }
        let saveSel = NSSelectorFromString("save")
        if manager.responds(to: saveSel) {
            _ = manager.perform(saveSel)
        }
        invalidateProjectionCache()
        postNativeListUpdate()
    }

    private static func sharedManager() -> NSObject? {
        guard let cls = NSClassFromString("BookSourceModelManager") as? NSObject.Type else { return nil }
        let sel = NSSelectorFromString("sharedInstance")
        guard cls.responds(to: sel) else { return nil }
        return cls.perform(sel)?.takeUnretainedValue() as? NSObject
    }

    private static func postNativeListUpdate() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: Notification.Name(XiangseAdapter.notifyUpdateSourceList),
                object: nil
            )
        }
    }
}
