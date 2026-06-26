import Foundation

/// 将 Legado 书源同步到香色闺阁原生 BookSourceModelManager，使「站点管理」可见
enum NativeSourceInjector {
    private static let managerClassName = "BookSourceModelManager"
    private static let legadoSourceType = "DOM"

    static func syncToNativeManager(sources: [MemoryBridgeBookSource]) {
        guard !sources.isEmpty,
              let manager = sharedManager() else { return }

        let models = sources.map { nativeModel(for: $0) }
        let added = invokeAddModels(on: manager, models: models)
        mergeModelsIntoManager(manager, models: models)
        invokeSave(on: manager)
        writeDebugMarker(count: sources.count, added: added)
        postNativeListUpdate()
    }

    static func allLegadoSourceNames() -> [String] {
        SourceRegistry.shared.allSources().map(\.bookSourceName)
    }

    static func isLegadoSourceName(_ name: String) -> Bool {
        SourceRegistry.shared.allSources().contains { $0.bookSourceName == name }
    }

    static func nativeModel(forSourceName name: String) -> [String: Any]? {
        guard let source = SourceRegistry.shared.allSources().first(where: { $0.bookSourceName == name }) else {
            return nil
        }
        return nativeModel(for: source)
    }

    // MARK: - Private

    private static func sharedManager() -> NSObject? {
        guard let cls = NSClassFromString(managerClassName) as? NSObject.Type else { return nil }
        let sel = NSSelectorFromString("sharedInstance")
        guard cls.responds(to: sel) else { return nil }
        return cls.perform(sel)?.takeUnretainedValue() as? NSObject
    }

    private static func nativeModel(for source: MemoryBridgeBookSource) -> [String: Any] {
        var model: [String: Any] = [
            "sourceName": source.bookSourceName,
            "sourceType": legadoSourceType,
            "sourceUrl": source.bookSourceUrl,
            "title": source.bookSourceName,
            "enabled": true,
            "weight": 50,
            XiangseAdapter.legadoMarkerKey: XiangseAdapter.legadoMarkerValue,
            "bookSourceUrl": source.bookSourceUrl
        ]
        if let manager = sharedManager(),
           let template = manager.perform(NSSelectorFromString("dicBaseModelTemplateDom"))?
            .takeUnretainedValue() as? [String: Any] {
            model.merge(template) { _, new in new }
            model["sourceName"] = source.bookSourceName
            model["sourceType"] = legadoSourceType
            model["sourceUrl"] = source.bookSourceUrl
            model["title"] = source.bookSourceName
            model["enabled"] = true
            model[XiangseAdapter.legadoMarkerKey] = XiangseAdapter.legadoMarkerValue
            model["bookSourceUrl"] = source.bookSourceUrl
        }
        return model
    }

    private static func mergeModelsIntoManager(_ manager: NSObject, models: [[String: Any]]) {
        let listSel = NSSelectorFromString("dicModelList")
        guard manager.responds(to: listSel) else { return }
        let raw = manager.perform(listSel)?.takeUnretainedValue()
        let current = (raw as? NSDictionary) ?? [:]
        let merged = NSMutableDictionary(dictionary: current)
        for model in models {
            guard let name = model["sourceName"] as? String else { continue }
            merged[name] = model
        }
        let setSel = NSSelectorFromString("setDicModelList:")
        if manager.responds(to: setSel) {
            _ = manager.perform(setSel, with: merged)
        } else {
            manager.setValue(merged, forKey: "dicModelList")
        }
        let msg = "merged=\(merged.count)"
        let path = (NSHomeDirectory() as NSString).appendingPathComponent("Documents/legado_native_merge.txt")
        try? msg.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private static func invokeSave(on manager: NSObject) {
        let sel = NSSelectorFromString("save")
        if manager.responds(to: sel) {
            _ = manager.perform(sel)
        }
    }

    private static func writeDebugMarker(count: Int, added: Bool) {
        let msg = "sources=\(count) addModels=\(added ? "OK" : "FAIL")"
        let path = (NSHomeDirectory() as NSString).appendingPathComponent("Documents/legado_native_sync.txt")
        try? msg.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private static func invokeAddModels(on manager: NSObject, models: [[String: Any]]) -> Bool {
        let sel = NSSelectorFromString("addModels:replace:showTip:autoSave:updateOnly:fromCloud:")
        guard manager.responds(to: sel) else { return false }
        let arr = models as NSArray
        typealias Fn = @convention(c) (AnyObject, Selector, NSArray, Bool, Bool, Bool, Bool, Bool) -> Bool
        let fn = unsafeBitCast(manager.method(for: sel), to: Fn.self)
        return fn(manager, sel, arr, false, false, true, false, false)
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
