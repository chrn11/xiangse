import Foundation
import CryptoKit

/// 源列表 ephemeral 投影（计划 TC-06 / §24.6）。
/// 不含 bookWorld / requestInfo / parser / list。
public struct NativeSourceListProjection: Equatable, Sendable {
    public var projectionKey: String
    public var exactSourceUrl: String
    public var displaySourceName: String
    public var enabled: Bool
    public var sourceType: String
    public var marker: String
    public var schema: String

    public static let keyPrefix = "__lb_src_v2_"
    public static let sourceTypeLegado = "legado"
    public static let schemaV2 = "lb-src-proj-v2"

    public init(
        projectionKey: String,
        exactSourceUrl: String,
        displaySourceName: String,
        enabled: Bool,
        sourceType: String = sourceTypeLegado,
        // 默认值须为字面量：public 默认参数不能引用 internal XiangseAdapter
        marker: String = "1",
        schema: String = schemaV2
    ) {
        self.projectionKey = projectionKey
        self.exactSourceUrl = exactSourceUrl
        self.displaySourceName = displaySourceName
        self.enabled = enabled
        self.sourceType = sourceType
        self.marker = marker
        self.schema = schema
    }

    public static func make(exactSourceUrl: String, displaySourceName: String, enabled: Bool) -> NativeSourceListProjection {
        NativeSourceListProjection(
            projectionKey: projectionKey(for: exactSourceUrl),
            exactSourceUrl: exactSourceUrl,
            displaySourceName: displaySourceName,
            enabled: enabled,
            marker: XiangseAdapter.legadoMarkerValue
        )
    }

    public static func projectionKey(for exactSourceUrl: String) -> String {
        let digest = SHA256.hash(data: Data(exactSourceUrl.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return keyPrefix + hex
    }

    public static func isProjectionKey(_ name: String) -> Bool {
        name.hasPrefix(keyPrefix)
    }

    /// 列表 getter 用的最小字典：无 bookWorld / requestInfo。
    public func ephemeralListDictionary() -> [String: Any] {
        [
            "sourceName": displaySourceName,
            "bookSourceName": displaySourceName,
            "title": displaySourceName,
            "sourceUrl": exactSourceUrl,
            "bookSourceUrl": exactSourceUrl,
            "legadoBookSourceUrl": exactSourceUrl,
            "legadoBookSourceName": displaySourceName,
            "sourceType": "text",
            "enable": enabled ? "1" : "0",
            "enabled": enabled,
            "weight": 50,
            XiangseAdapter.legadoMarkerKey: marker,
            "_lb_projectionKey": projectionKey,
            "_lb_schema": schema,
            "_lb_sourceType": sourceType,
            // 占位 searchBook 仅结构常量，无可执行 requestInfo
            "searchBook": [
                "actionID": "searchBook",
                "parserID": "DOM"
            ]
        ]
    }
}

/// Debug 计数：Bridge 请求 manager save / addModels 的次数（Release 目标为 0）。
public enum NativeManagerPersistenceGuard {
    private static let lock = NSLock()
    private static var _saveAttempts: Int = 0
    private static var _addModelsAttempts: Int = 0
    private static var _syncAttempts: Int = 0

    public static func recordSaveAttempt() {
        lock.lock(); _saveAttempts += 1; lock.unlock()
    }

    public static func recordAddModelsAttempt() {
        lock.lock(); _addModelsAttempts += 1; lock.unlock()
    }

    public static func recordSyncAttempt() {
        lock.lock(); _syncAttempts += 1; lock.unlock()
    }

    public static func snapshot() -> (save: Int, addModels: Int, sync: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (_saveAttempts, _addModelsAttempts, _syncAttempts)
    }

    public static func resetForTests() {
        lock.lock()
        _saveAttempts = 0
        _addModelsAttempts = 0
        _syncAttempts = 0
        lock.unlock()
    }
}
