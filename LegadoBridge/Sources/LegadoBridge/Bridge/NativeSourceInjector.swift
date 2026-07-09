import Foundation

/// 将 Legado 书源同步到香色闺阁原生 BookSourceModelManager，使「站点管理」可见
enum NativeSourceInjector {
    private static let managerClassName = "BookSourceModelManager"
    private static let legadoSourceType = "DOM"

    static func syncToNativeManager(sources: [MemoryBridgeBookSource]) {
        guard !sources.isEmpty,
              let manager = sharedManager() else { return }

        let models = sources.map { nativeModel(for: $0, manager: manager) }
        // 真机 Frida：addModels 对完整 DOM 模板也恒返回 NO 且不入库；
        // 以 merge+save 为权威落盘路径（verified 表示 merge 写入成功）。
        let added = invokeAddModels(on: manager, models: models)
        let verified = mergeModelsIntoManager(manager, models: models)
        invokeSave(on: manager)
        writeDebugMarker(count: sources.count, added: added, verified: verified)
        postNativeListUpdate()
    }

    /// 仅返回已启用的书源名（供搜索/原生列表 Hook 合并，禁用源不进入可用站点）
    static func allLegadoSourceNames() -> [String] {
        SourceRegistry.shared.allSources()
            .filter { SourceRegistry.shared.isEnabled(url: $0.bookSourceUrl) }
            .map(\.bookSourceName)
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

    /// 从原生 dicModelList 移除指定 legadoBridge=1 条目，save 后通知刷新
    static func removeFromNativeManager(names: [String]) {
        guard !names.isEmpty,
              let manager = sharedManager() else { return }
        let listSel = NSSelectorFromString("dicModelList")
        guard manager.responds(to: listSel) else { return }
        let raw = manager.perform(listSel)?.takeUnretainedValue()
        let current = (raw as? NSDictionary) ?? [:]
        let merged = NSMutableDictionary(dictionary: current)
        let nameSet = Set(names)
        for key in merged.allKeys {
            guard let name = key as? String, nameSet.contains(name) else { continue }
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
        invokeSave(on: manager)
        postNativeListUpdate()
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

    @discardableResult
    private static func mergeModelsIntoManager(_ manager: NSObject, models: [[String: Any]]) -> Bool {
        let listSel = NSSelectorFromString("dicModelList")
        guard manager.responds(to: listSel) else { return false }
        // 注意：dicModelList 的 getter 已被 Hook，会并入 Registry；此处仍用于拿到可变底表再写回
        let raw = manager.perform(listSel)?.takeUnretainedValue()
        let current = (raw as? NSDictionary) ?? [:]
        let merged = NSMutableDictionary(dictionary: current)
        var wrote = 0
        for model in models {
            guard let name = model["sourceName"] as? String, !name.isEmpty else { continue }
            // 存 NSMutableDictionary，避免 Swift Dictionary 桥接成不可变 Deferred 字典后原生改写失败
            let entry = NSMutableDictionary(dictionary: model)
            entry["enable"] = "1"
            entry["enabled"] = true
            entry["sourceType"] = legadoSourceType
            merged[name] = entry
            wrote += 1
        }
        guard wrote > 0 else { return false }
        let setSel = NSSelectorFromString("setDicModelList:")
        if manager.responds(to: setSel) {
            _ = manager.perform(setSel, with: merged)
        } else {
            manager.setValue(merged, forKey: "dicModelList")
        }
        let enableFlags = models.map { m -> String in
            let name = m["sourceName"] as? String ?? "?"
            let en = (merged[name] as? NSDictionary)?["enable"] as? String ?? "nil"
            return "\(name):enable=\(en)"
        }.joined(separator: ",")
        let msg = "merged=\(merged.count) wrote=\(wrote) \(enableFlags)"
        let path = (NSHomeDirectory() as NSString).appendingPathComponent("Documents/legado_native_merge.txt")
        try? msg.write(toFile: path, atomically: true, encoding: .utf8)
        return true
    }

    private static func invokeSave(on manager: NSObject) {
        let sel = NSSelectorFromString("save")
        if manager.responds(to: sel) {
            _ = manager.perform(sel)
        }
    }

    private static func writeDebugMarker(count: Int, added: Bool, verified: Bool) {
        // verified=OK 表示 merge 后 dicModelList 已含目标源（搜索可用的真实判据）
        let msg = "sources=\(count) addModels=\(added ? "OK" : "FAIL") verified=\(verified ? "OK" : "FAIL")"
        let path = (NSHomeDirectory() as NSString).appendingPathComponent("Documents/legado_native_sync.txt")
        try? msg.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private static func invokeAddModels(on manager: NSObject, models: [[String: Any]]) -> Bool {
        let sel = NSSelectorFromString("addModels:replace:showTip:autoSave:updateOnly:fromCloud:")
        guard manager.responds(to: sel),
              let methodPtr = manager.method(for: sel) else { return false }
        // 编码 B44@0:8@16B24B28B32B36B40；真机对 DOM 壳/模板均常返回 NO，仅作尽力调用
        let arr = NSMutableArray(array: models.map { NSMutableDictionary(dictionary: $0) })
        typealias Fn = @convention(c) (AnyObject, Selector, NSArray, Bool, Bool, Bool, Bool, Bool) -> Bool
        let fn = unsafeBitCast(methodPtr, to: Fn.self)
        // replace=true / autoSave=true；fromCloud=true 贴近 AppDelegate 打开文件导入路径
        let combos: [(Bool, Bool, Bool, Bool, Bool)] = [
            (true, false, true, false, true),
            (true, false, true, false, false),
            (false, false, true, false, false)
        ]
        for (replace, showTip, autoSave, updateOnly, fromCloud) in combos {
            if fn(manager, sel, arr, replace, showTip, autoSave, updateOnly, fromCloud) {
                return true
            }
        }
        return false
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
