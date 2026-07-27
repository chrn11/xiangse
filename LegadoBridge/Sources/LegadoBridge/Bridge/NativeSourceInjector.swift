import Foundation
import LegadoRuleCore

/// 将 Legado 书源同步到香色闺阁原生 BookSourceModelManager，使「站点管理」可见。
/// D0：落盘守卫——禁止空表/半表 save 吞掉原生 XBS；同名不覆盖 XBS。
enum NativeSourceInjector {
    private static let managerClassName = "BookSourceModelManager"
    private static let legadoSourceType = "DOM"
    private static let hwmPath = (NSHomeDirectory() as NSString)
        .appendingPathComponent("Documents/legado_native_table_hwm.txt")
    private static let skipPath = (NSHomeDirectory() as NSString)
        .appendingPathComponent("Documents/legado_native_skip.txt")
    private static let conflictPath = (NSHomeDirectory() as NSString)
        .appendingPathComponent("Documents/legado_name_conflicts.txt")
    private static let readyPath = (NSHomeDirectory() as NSString)
        .appendingPathComponent("Documents/legado_native_ready.txt")

    /// 冷启动：等原生表就绪后再 sync；超时放弃（不带空表 save）
    static func syncToNativeManagerWhenReady(sources: [MemoryBridgeBookSource]) {
        guard !sources.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            let maxRounds = 40
            var lastCount = -1
            var stableHits = 0
            var ready = false
            for round in 0..<maxRounds {
                let snap = nativeBaseSnapshot()
                let count = snap.totalCount
                if count > 0, count == lastCount {
                    stableHits += 1
                } else {
                    stableHits = 0
                }
                lastCount = count
                // 连续两次非零且稳定，或已见过较高水位的底表
                if stableHits >= 2, count > 0 {
                    ready = true
                    break
                }
                if snap.nativeCount > 0, snap.nativeCount == lastCount, stableHits >= 1 {
                    ready = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.25)
                _ = round
            }
            let msg: String
            if ready {
                msg = "ready total=\(lastCount) -> sync"
                try? msg.write(toFile: readyPath, atomically: true, encoding: .utf8)
                DispatchQueue.main.async {
                    syncToNativeManager(sources: sources)
                }
            } else {
                msg = "TIMEOUT_SKIP_SYNC lastTotal=\(lastCount) hwm=\(readHwm())"
                try? msg.write(toFile: readyPath, atomically: true, encoding: .utf8)
                try? "SKIP_TIMEOUT_NO_SYNC \(msg)".write(toFile: skipPath, atomically: true, encoding: .utf8)
            }
        }
    }

    static func syncToNativeManager(sources: [MemoryBridgeBookSource]) {
        guard !sources.isEmpty,
              let manager = sharedManager() else { return }

        let models = sources.map { nativeModel(for: $0, manager: manager) }
        // 真机 Frida：addModels 对完整 DOM 模板也恒返回 NO 且不入库；
        // 以 merge+save 为权威落盘路径（verified 表示 merge 写入成功）。
        let added = invokeAddModels(on: manager, models: models)
        let verified = mergeModelsIntoManager(manager, models: models)
        // D0：仅 merge 成功时 save，禁止空表/半表固化
        if verified {
            invokeSave(on: manager)
        }
        writeDebugMarker(count: sources.count, added: added, verified: verified)
        if verified {
            postNativeListUpdate()
        }
    }

    /// 仅返回已启用的书源名（供搜索/原生列表 Hook 合并，禁用源不进入可用站点）
    static func allLegadoSourceNames() -> [String] {
        SourceRegistry.shared.allSources()
            .filter { SourceRegistry.shared.isEnabled(url: $0.bookSourceUrl) }
            .map(\.bookSourceName)
    }

    /// 是否应按 Legado 路径处理该站点名。
    /// 优先看原生表里该键是否带 legadoBridge 标记，避免同名 XBS 被误判。
    static func isLegadoSourceName(_ name: String) -> Bool {
        if let marked = nativeEntryMarker(forName: name) {
            return marked
        }
        // 带消歧后缀的键
        if name.hasSuffix("·Legado") {
            let base = String(name.dropLast("·Legado".count))
            return SourceRegistry.shared.allSources().contains { $0.bookSourceName == base }
        }
        // 无表可读时退回 Registry 名（导入瞬间）
        return SourceRegistry.shared.allSources().contains { $0.bookSourceName == name }
    }

    static func nativeModel(forSourceName name: String) -> [String: Any]? {
        let lookup = name.hasSuffix("·Legado")
            ? String(name.dropLast("·Legado".count))
            : name
        guard let source = SourceRegistry.shared.allSources().first(where: { $0.bookSourceName == lookup }) else {
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
        var also = Set<String>()
        for n in names {
            also.insert(n)
            also.insert(n + "·Legado")
        }
        for key in merged.allKeys {
            guard let name = key as? String else { continue }
            guard nameSet.contains(name) || also.contains(name) else { continue }
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

    private struct BaseSnapshot {
        let totalCount: Int
        let nativeCount: Int
        let legadoCount: Int
    }

    private static func nativeBaseSnapshot() -> BaseSnapshot {
        guard let manager = sharedManager() else {
            return BaseSnapshot(totalCount: 0, nativeCount: 0, legadoCount: 0)
        }
        let listSel = NSSelectorFromString("dicModelList")
        guard manager.responds(to: listSel) else {
            return BaseSnapshot(totalCount: 0, nativeCount: 0, legadoCount: 0)
        }
        let raw = manager.perform(listSel)?.takeUnretainedValue()
        let current = (raw as? NSDictionary) ?? [:]
        var native = 0
        var legado = 0
        current.enumerateKeysAndObjects { _, value, _ in
            if let model = value as? NSDictionary,
               let marker = model[XiangseAdapter.legadoMarkerKey] as? String,
               marker == XiangseAdapter.legadoMarkerValue {
                legado += 1
            } else {
                native += 1
            }
        }
        return BaseSnapshot(totalCount: current.count, nativeCount: native, legadoCount: legado)
    }

    private static func nativeEntryMarker(forName name: String) -> Bool? {
        guard let manager = sharedManager() else { return nil }
        let listSel = NSSelectorFromString("dicModelList")
        guard manager.responds(to: listSel) else { return nil }
        let raw = manager.perform(listSel)?.takeUnretainedValue()
        guard let current = raw as? NSDictionary,
              let model = current[name] as? NSDictionary else { return nil }
        if let marker = model[XiangseAdapter.legadoMarkerKey] as? String,
           marker == XiangseAdapter.legadoMarkerValue {
            return true
        }
        return false
    }

    private static func readHwm() -> Int {
        guard let s = try? String(contentsOfFile: hwmPath, encoding: .utf8),
              let n = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return 0
        }
        return max(0, n)
    }

    private static func updateHwm(observedTotal: Int) {
        let prev = readHwm()
        guard observedTotal > prev else { return }
        try? "\(observedTotal)".write(toFile: hwmPath, atomically: true, encoding: .utf8)
    }

    /// 底表是否安全可写：非空，且不低于历史水位的一半（防竞态半表）
    private static func isBaseSafeToWrite(snapshot: BaseSnapshot) -> Bool {
        if snapshot.totalCount == 0 {
            return false
        }
        let hwm = readHwm()
        // 水位未建立：允许写（首启仅 Legado），但靠后续 hwm 抬升
        if hwm <= 0 {
            return true
        }
        // 用 nativeCount 更准：Hook 并入 Registry 后 total 可能虚高/虚低
        // 竞态空盘时常：native=0、legado≈3
        if snapshot.nativeCount == 0, hwm >= 10 {
            return false
        }
        if snapshot.totalCount < max(1, hwm / 2) {
            return false
        }
        return true
    }

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
        var nativeN = 0
        var legadoN = 0
        current.enumerateKeysAndObjects { _, value, _ in
            if let model = value as? NSDictionary,
               let marker = model[XiangseAdapter.legadoMarkerKey] as? String,
               marker == XiangseAdapter.legadoMarkerValue {
                legadoN += 1
            } else {
                nativeN += 1
            }
        }
        let snapFull = BaseSnapshot(
            totalCount: current.count,
            nativeCount: nativeN,
            legadoCount: legadoN
        )

        if !isBaseSafeToWrite(snapshot: snapFull) {
            let skip = "SKIP_UNSAFE_BASE total=\(snapFull.totalCount) native=\(snapFull.nativeCount) legado=\(snapFull.legadoCount) hwm=\(readHwm())"
            try? skip.write(toFile: skipPath, atomically: true, encoding: .utf8)
            let mergeMsg = "SKIP \(skip)"
            let path = (NSHomeDirectory() as NSString).appendingPathComponent("Documents/legado_native_merge.txt")
            try? mergeMsg.write(toFile: path, atomically: true, encoding: .utf8)
            return false
        }

        let merged = NSMutableDictionary(dictionary: current)
        var wrote = 0
        var conflicts: [String] = []
        for model in models {
            guard let name = model["sourceName"] as? String, !name.isEmpty else { continue }
            let entry = NSMutableDictionary(dictionary: model)
            entry["enable"] = "1"
            entry["enabled"] = true
            entry["sourceType"] = legadoSourceType
            entry[XiangseAdapter.legadoMarkerKey] = XiangseAdapter.legadoMarkerValue

            var key = name
            if let existing = merged[name] as? NSDictionary {
                let marker = existing[XiangseAdapter.legadoMarkerKey] as? String
                if marker != XiangseAdapter.legadoMarkerValue {
                    // 同名 XBS：不覆盖，改用后缀键
                    key = name + "·Legado"
                    entry["sourceName"] = key
                    entry["title"] = key
                    conflicts.append("\(name) -> \(key)")
                }
            }
            merged[key] = entry
            wrote += 1
        }
        guard wrote > 0 else { return false }

        if !conflicts.isEmpty {
            let line = conflicts.joined(separator: "\n")
            try? line.write(toFile: conflictPath, atomically: true, encoding: .utf8)
        }

        let setSel = NSSelectorFromString("setDicModelList:")
        if manager.responds(to: setSel) {
            _ = manager.perform(setSel, with: merged)
        } else {
            manager.setValue(merged, forKey: "dicModelList")
        }
        updateHwm(observedTotal: merged.count)

        let enableFlags = models.map { m -> String in
            let name = m["sourceName"] as? String ?? "?"
            let key = (merged[name] != nil) ? name : (name + "·Legado")
            let en = (merged[key] as? NSDictionary)?["enable"] as? String ?? "nil"
            return "\(key):enable=\(en)"
        }.joined(separator: ",")
        let msg = "merged=\(merged.count) wrote=\(wrote) conflicts=\(conflicts.count) \(enableFlags)"
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
        // U0-F3：禁止 replace=true。真机曾用 replace 成功写入 → sourceModelList.xbs
        // 从约 22MB/960 站被截成仅 Legado 壳（注入包实测 12KB / 站点(3)）。
        // 权威落盘仍是下方 mergeModelsIntoManager + save；此处只作非替换尽力调用。
        let combos: [(Bool, Bool, Bool, Bool, Bool)] = [
            // replace, showTip, autoSave, updateOnly, fromCloud
            (false, false, true, false, true),
            (false, false, true, false, false),
            (false, false, false, false, false)
        ]
        for (replace, showTip, autoSave, updateOnly, fromCloud) in combos {
            if replace {
                continue // 硬禁：永不整表替换原生 XBS
            }
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
