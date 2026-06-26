import Foundation

/// 将 Legado 书源同步到香色闺阁原生 BookSourceModelManager，使「站点管理」可见
enum NativeSourceInjector {
    private static let managerClassName = "BookSourceModelManager"
    private static let legadoSourceType = "LEGADO"

    static func syncToNativeManager(sources: [MemoryBridgeBookSource]) {
        guard !sources.isEmpty,
              let manager = sharedManager() else { return }

        let models = sources.map { nativeModel(for: $0) }
        let ok = invokeAddModels(on: manager, models: models)
        if ok {
            postNativeListUpdate()
        }
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
