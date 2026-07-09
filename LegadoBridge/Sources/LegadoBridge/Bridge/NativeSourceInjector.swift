import Foundation

/// 将 Legado 书源同步到香色闺阁原生 BookSourceModelManager，使「站点管理」可见
enum NativeSourceInjector {
    private static let managerClassName = "BookSourceModelManager"
    private static let legadoSourceType = "DOM"

    static func syncToNativeManager(sources: [MemoryBridgeBookSource]) {
        guard !sources.isEmpty,
              let manager = sharedManager() else { return }

        let models = sources.map { nativeModel(for: $0, manager: manager) }
        // replace=true：同名源覆盖；addModels 仍可能因内部校验返回 NO，merge 兜底保证 enable 等字段落盘
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
        return nativeModel(for: source, manager: sharedManager())
    }

    // MARK: - Private

    private static func sharedManager() -> NSObject? {
        guard let cls = NSClassFromString(managerClassName) as? NSObject.Type else { return nil }
        let sel = NSSelectorFromString("sharedInstance")
        guard cls.responds(to: sel) else { return nil }
        return cls.perform(sel)?.takeUnretainedValue() as? NSObject
    }

    private static func nativeModel(for source: MemoryBridgeBookSource, manager: NSObject?) -> [String: Any] {
        // 接入 Converter：基于 dicBaseModelTemplateDom 深拷贝，并强制 enable="1"。
        // 点击仍由 didSelect/openModel Hook 拦截，避免进原生编辑页。
        if let manager {
            let converted = XiangseNativeModelConverter.nativeModel(for: source, manager: manager)
            var result: [String: Any] = [:]
            converted.enumerateKeysAndObjects { key, value, _ in
                if let k = key as? String {
                    result[k] = value
                }
            }
            return result
        }
        return minimalShellModel(for: source)
    }

    /// Manager 尚未就绪时的最小壳（仍带原生启用键 enable）
    private static func minimalShellModel(for source: MemoryBridgeBookSource) -> [String: Any] {
        [
            "sourceName": source.bookSourceName,
            "sourceType": legadoSourceType,
            "sourceUrl": source.bookSourceUrl,
            "title": source.bookSourceName,
            "enable": "1",
            "enabled": true,
            "weight": 50,
            "searchBook": [
                "actionID": "searchBook",
                "parserID": legadoSourceType
            ],
            XiangseAdapter.legadoMarkerKey: XiangseAdapter.legadoMarkerValue,
            "bookSourceUrl": source.bookSourceUrl
        ]
    }

    private static func mergeModelsIntoManager(_ manager: NSObject, models: [[String: Any]]) {
        let listSel = NSSelectorFromString("dicModelList")
        guard manager.responds(to: listSel) else { return }
        let raw = manager.perform(listSel)?.takeUnretainedValue()
        let current = (raw as? NSDictionary) ?? [:]
        let merged = NSMutableDictionary(dictionary: current)
        for model in models {
            guard let name = model["sourceName"] as? String else { continue }
            // 存 NSMutableDictionary，避免 Swift Dictionary 桥接成不可变 Deferred 字典后原生改写失败
            merged[name] = NSMutableDictionary(dictionary: model)
        }
        let setSel = NSSelectorFromString("setDicModelList:")
        if manager.responds(to: setSel) {
            _ = manager.perform(setSel, with: merged)
        } else {
            manager.setValue(merged, forKey: "dicModelList")
        }
        let enableFlags = models.map { m -> String in
            let name = m["sourceName"] as? String ?? "?"
            let en = m["enable"] as? String ?? "nil"
            return "\(name):enable=\(en)"
        }.joined(separator: ",")
        let msg = "merged=\(merged.count) \(enableFlags)"
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
        // 转为 NSMutableDictionary 数组，贴近原生入库形态
        let arr = models.map { NSMutableDictionary(dictionary: $0) } as NSArray
        typealias Fn = @convention(c) (AnyObject, Selector, NSArray, Bool, Bool, Bool, Bool, Bool) -> Bool
        let fn = unsafeBitCast(manager.method(for: sel), to: Fn.self)
        // replace=true：允许覆盖已存在的同名壳模型
        return fn(manager, sel, arr, true, false, true, false, false)
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
