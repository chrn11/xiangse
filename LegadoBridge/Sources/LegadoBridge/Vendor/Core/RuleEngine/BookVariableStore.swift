//
//  BookVariableStore.swift
//  LegadoRuleCore
//
//  书本级变量：与 SourceSessionStore（源级）分离。
//  对应 Legado BaseBook.variable / putVariable / getVariable。
//

import Foundation

public enum BookVariableStore {
    private static let lock = NSLock()
    private static var store: [String: [String: String]] = [:]
    private static var didRestoreFromDisk = false

    private static var persistFileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        return docs.appendingPathComponent("legado_bridge_book_variables.json")
    }

    public static func restoreFromDiskIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !didRestoreFromDisk else { return }
        didRestoreFromDisk = true
        guard let data = try? Data(contentsOf: persistFileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]] else {
            return
        }
        store = obj
    }

    public static func variables(for bookUrl: String) -> [String: String] {
        restoreFromDiskIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return store[bookUrl] ?? [:]
    }

    public static func get(_ key: String, bookUrl: String?) -> String {
        guard let bookUrl, !bookUrl.isEmpty, !key.isEmpty else { return "" }
        restoreFromDiskIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return store[bookUrl]?[key] ?? ""
    }

    public static func put(_ key: String, value: String, bookUrl: String?) {
        guard let bookUrl, !bookUrl.isEmpty, !key.isEmpty else { return }
        restoreFromDiskIfNeeded()
        lock.lock()
        var map = store[bookUrl] ?? [:]
        map[key] = value
        store[bookUrl] = map
        persistLocked()
        lock.unlock()
    }

    public static func merge(_ vars: [String: String], for bookUrl: String) {
        guard !bookUrl.isEmpty, !vars.isEmpty else { return }
        restoreFromDiskIfNeeded()
        lock.lock()
        var map = store[bookUrl] ?? [:]
        for (k, v) in vars { map[k] = v }
        store[bookUrl] = map
        persistLocked()
        lock.unlock()
    }

    public static func clear(bookUrl: String?) {
        guard let bookUrl, !bookUrl.isEmpty else { return }
        restoreFromDiskIfNeeded()
        lock.lock()
        store.removeValue(forKey: bookUrl)
        persistLocked()
        lock.unlock()
    }

    /// 单测用：清空内存与可选落盘文件
    public static func resetForTesting(clearPersistFile: Bool = true) {
        lock.lock()
        store.removeAll()
        if clearPersistFile {
            try? FileManager.default.removeItem(at: persistFileURL)
            didRestoreFromDisk = true
        } else {
            // 保留文件，允许下次 variables/get 再读盘
            didRestoreFromDisk = false
        }
        lock.unlock()
    }

    public static func jsonString(for bookUrl: String) -> String {
        let map = variables(for: bookUrl)
        guard !map.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: map, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else {
            return ""
        }
        return s
    }

    private static func persistLocked() {
        guard let data = try? JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted]) else {
            return
        }
        try? data.write(to: persistFileURL, options: .atomic)
    }
}
