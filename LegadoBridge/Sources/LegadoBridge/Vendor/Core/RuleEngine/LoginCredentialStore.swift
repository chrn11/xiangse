//
//  LoginCredentialStore.swift
//  书源登录凭据（对齐 Android BaseSource userInfo_ / loginHeader_）
//

import Foundation

enum LoginCredentialStore {
    private static let lock = NSLock()

    private static func fileURL(prefix: String, sourceUrl: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let digest = sourceUrl.data(using: .utf8).map { data -> String in
            var hash: UInt64 = 5381
            for b in data { hash = ((hash << 5) &+ hash) &+ UInt64(b) }
            return String(hash, radix: 16)
        } ?? "0"
        return docs.appendingPathComponent("legado_\(prefix)_\(digest).json")
    }

    static func putInfo(_ json: String, sourceUrl: String) {
        guard !sourceUrl.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        try? json.data(using: .utf8)?.write(to: fileURL(prefix: "userinfo", sourceUrl: sourceUrl), options: .atomic)
    }

    static func getInfo(sourceUrl: String) -> String {
        guard !sourceUrl.isEmpty else { return "" }
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL(prefix: "userinfo", sourceUrl: sourceUrl)),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    static func removeInfo(sourceUrl: String) {
        guard !sourceUrl.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL(prefix: "userinfo", sourceUrl: sourceUrl))
    }

    static func putHeader(_ json: String, sourceUrl: String) {
        guard !sourceUrl.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        try? json.data(using: .utf8)?.write(to: fileURL(prefix: "loginheader", sourceUrl: sourceUrl), options: .atomic)
    }

    static func getHeader(sourceUrl: String) -> String {
        guard !sourceUrl.isEmpty else { return "" }
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL(prefix: "loginheader", sourceUrl: sourceUrl)),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    static func removeHeader(sourceUrl: String) {
        guard !sourceUrl.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL(prefix: "loginheader", sourceUrl: sourceUrl))
    }

    static func infoMap(sourceUrl: String) -> [String: String] {
        let raw = getInfo(sourceUrl: sourceUrl)
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var out: [String: String] = [:]
        for (k, v) in obj {
            out[k] = "\(v)"
        }
        return out
    }
}
