import CryptoKit
import Foundation

/// TC-10：旧 native manager 壳条目迁移（仅 allowlist / marker 授权；本卡不触达真机 apply）。
public enum LegacyNativeShellMigrator {
    // MARK: - 公开类型

    public static let checksumAlgorithm = "sha256-canonical-json-v1"

    public struct AllowlistItem: Codable, Equatable, Sendable {
        public var entryName: String
        public var topLevelKeysSorted: [String]
        public var entrySHA256: String
        public var bookWorldSHA256: String?
        public var firstSeenBuild: FirstSeenBuild
        public var evidencePath: String
        public var evidenceSHA256: String
        public var markerExpected: Bool
    }

    public struct FirstSeenBuild: Codable, Equatable, Sendable {
        public var appVersion: String
        public var nativeExecutableSHA256: String
    }

    public struct AllowlistDocument: Codable, Equatable, Sendable {
        public var schemaVersion: Int
        public var contractID: String
        public var selectedBranch: String
        public var hashAlgorithm: String
        public var firstSeenBuild: FirstSeenBuild
        public var evidencePath: String
        public var evidenceSHA256: String
        public var items: [AllowlistItem]
    }

    public enum EntryClassification: String, Sendable {
        case pristineNative
        case markedLegadoShell
        case unmarkedThreeKeyShell
        case allowlistAuthorized
        case excludedAmbiguous
        case noopEmptyAllowlist
    }

    public struct EntryFingerprint: Equatable, Sendable {
        public var entryName: String
        public var topLevelKeysSorted: [String]
        public var entrySHA256: String
        public var bookWorldSHA256: String?
        public var markerExpected: Bool
        public var classification: EntryClassification
    }

    public struct DeletionCandidate: Equatable, Sendable {
        public var entryIndex: Int
        public var entryName: String
        public var classification: EntryClassification
        public var fingerprint: EntryFingerprint
        public var allowlistItemMatched: Bool
    }

    public struct DryRunResult: Equatable, Sendable {
        public var selectedBranch: String
        public var allowlistItemCount: Int
        public var scannedEntryCount: Int
        public var pristineCount: Int
        public var candidates: [DeletionCandidate]
        public var fingerprints: [EntryFingerprint]
        public var snapshotSHA256: String

        public var unmarkedDeletionCount: Int {
            candidates.filter { $0.classification == .unmarkedThreeKeyShell || $0.classification == .allowlistAuthorized }.count
        }
    }

    public struct MigrationBackup: Equatable, Sendable {
        public var checksumAlgorithm: String
        public var snapshotSHA256: String
        public var entryCount: Int
        public var createdAt: Date
    }

    public enum ApplyResult: Equatable, Sendable {
        case noopEmptyAllowlist
        case noopNoCandidates
        case rejectedMissingBackup
        case rejectedChecksumMismatch
        case applied(deletedNames: [String])
    }

    // MARK: - 加载

    public static func loadBundledAllowlist() throws -> AllowlistDocument {
        // 不依赖 Bundle.module（部分 Xcode/SPM 组合不生成 resource_bundle_accessor）
        let bridgeDir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let candidates = [
            bridgeDir.deletingLastPathComponent().appendingPathComponent("Resources/LegacyNativeShellAllowlist.json"),
            bridgeDir.appendingPathComponent("LegacyNativeShellAllowlist.json"),
        ]
        for url in candidates {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(AllowlistDocument.self, from: data)
        }
        throw NSError(domain: "LegacyNativeShellMigrator", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "缺少 LegacyNativeShellAllowlist.json",
        ])
    }

    // MARK: - dry-run

    /// 只读 dry-run：不修改 snapshot；空 allowlist 时 candidates 恒为空。
    public static func dryRun(
        rawManagerSnapshot: [String: [String: Any]],
        allowlist: AllowlistDocument? = nil
    ) throws -> DryRunResult {
        let doc = try allowlist ?? loadBundledAllowlist()
        let orderedNames = rawManagerSnapshot.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        var fingerprints: [EntryFingerprint] = []
        var candidates: [DeletionCandidate] = []
        var pristineCount = 0

        let allowlistEmpty = doc.items.isEmpty
        for (index, name) in orderedNames.enumerated() {
            guard let model = rawManagerSnapshot[name] else { continue }
            let fp = fingerprint(entryName: name, model: model)
            fingerprints.append(fp)

            if fp.classification == .pristineNative {
                pristineCount += 1
                continue
            }
            if allowlistEmpty {
                continue
            }
            if let candidate = evaluateDeletionCandidate(
                index: index,
                fingerprint: fp,
                allowlistItems: doc.items
            ) {
                candidates.append(candidate)
            }
        }

        let snapshotSHA = try snapshotSHA256(rawManagerSnapshot)
        return DryRunResult(
            selectedBranch: doc.selectedBranch,
            allowlistItemCount: doc.items.count,
            scannedEntryCount: orderedNames.count,
            pristineCount: pristineCount,
            candidates: candidates,
            fingerprints: fingerprints,
            snapshotSHA256: snapshotSHA
        )
    }

    // MARK: - backup / apply

    public static func makeBackup(
        rawManagerSnapshot: [String: [String: Any]],
        createdAt: Date = Date()
    ) throws -> MigrationBackup {
        MigrationBackup(
            checksumAlgorithm: checksumAlgorithm,
            snapshotSHA256: try snapshotSHA256(rawManagerSnapshot),
            entryCount: rawManagerSnapshot.count,
            createdAt: createdAt
        )
    }

    /// apply 默认安全：空 allowlist 或空 candidates 均为 noop；需 backup 形状匹配。
    public static func apply(
        dryRunResult: DryRunResult,
        backup: MigrationBackup?,
        rawManagerSnapshot: [String: [String: Any]],
        allowlist: AllowlistDocument? = nil
    ) throws -> ApplyResult {
        let doc = try allowlist ?? loadBundledAllowlist()
        guard !doc.items.isEmpty else { return .noopEmptyAllowlist }
        guard !dryRunResult.candidates.isEmpty else { return .noopNoCandidates }
        guard let backup else { return .rejectedMissingBackup }
        let currentSHA = try snapshotSHA256(rawManagerSnapshot)
        guard backup.snapshotSHA256 == currentSHA,
              backup.snapshotSHA256 == dryRunResult.snapshotSHA256,
              backup.checksumAlgorithm == checksumAlgorithm else {
            return .rejectedChecksumMismatch
        }

        let names = dryRunResult.candidates.map(\.entryName)
        NativeSourceInjector.removeFromNativeManager(names: names, allowLegacyMigration: true)
        return .applied(deletedNames: names)
    }

    // MARK: - 指纹 / 分类

    public static func fingerprint(entryName: String, model: [String: Any]) -> EntryFingerprint {
        let keys = model.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        let entrySHA = canonicalSHA256(model) ?? ""
        let bwSHA: String?
        if let bw = model["bookWorld"] {
            bwSHA = canonicalSHA256(bw)
        } else {
            bwSHA = nil
        }
        let markerExpected = hasLegadoMarker(model)
        let classification = classify(model: model, markerExpected: markerExpected)
        return EntryFingerprint(
            entryName: entryName,
            topLevelKeysSorted: keys,
            entrySHA256: entrySHA,
            bookWorldSHA256: bwSHA,
            markerExpected: markerExpected,
            classification: classification
        )
    }

    static func classify(model: [String: Any], markerExpected: Bool) -> EntryClassification {
        if isPristineNative(model) {
            return .pristineNative
        }
        if markerExpected {
            return .markedLegadoShell
        }
        if looksUnmarkedThreeKeyShell(model) {
            return .unmarkedThreeKeyShell
        }
        return .excludedAmbiguous
    }

    /// pristine：含非空 bookWorld 且至少一条完整 XBS 通道（actionID/parser/request/list）。
    public static func isPristineNative(_ model: [String: Any]) -> Bool {
        guard let bw = model["bookWorld"] as? [String: Any], !bw.isEmpty else { return false }
        for (_, entryAny) in bw {
            guard let entry = entryAny as? [String: Any] else { continue }
            let action = (entry["actionID"] as? String) ?? (entry["actionId"] as? String)
            guard action == "bookWorld" else { continue }
            let parser = entry["parserID"] ?? entry["parserId"] ?? entry["parser"]
            let request = entry["requestInfo"]
            let list = entry["list"]
            let parserOK = parser != nil && (!(parser is String) || !((parser as? String)?.isEmpty ?? true))
            let requestOK = request != nil && (!(request is String) || !((request as? String)?.isEmpty ?? true))
            let listOK = list != nil
            if parserOK && requestOK && listOK { return true }
        }
        return false
    }

    static func looksUnmarkedThreeKeyShell(_ model: [String: Any]) -> Bool {
        let keys = Set(model.keys)
        let three = Set(["sourceName", "sourceType", "sourceUrl"])
        guard three.isSubset(of: keys) else { return false }
        if hasLegadoMarker(model) { return false }
        if let bw = model["bookWorld"] as? [String: Any], !bw.isEmpty { return false }
        if keys.count > 8 { return false }
        return true
    }

    static func hasLegadoMarker(_ model: [String: Any]) -> Bool {
        if let m = model[XiangseAdapter.legadoMarkerKey] as? String, m == XiangseAdapter.legadoMarkerValue {
            return true
        }
        if let t = model["_lb_sourceType"] as? String, t == "legado" { return true }
        if model["_lb_adapter"] != nil { return true }
        return false
    }

    static func matchesAllowlistItem(_ fp: EntryFingerprint, item: AllowlistItem) -> Bool {
        guard fp.entryName == item.entryName else { return false }
        guard fp.topLevelKeysSorted == item.topLevelKeysSorted else { return false }
        guard fp.entrySHA256 == item.entrySHA256 else { return false }
        guard fp.bookWorldSHA256 == item.bookWorldSHA256 else { return false }
        guard fp.markerExpected == item.markerExpected else { return false }
        return true
    }

    private static func evaluateDeletionCandidate(
        index: Int,
        fingerprint fp: EntryFingerprint,
        allowlistItems: [AllowlistItem]
    ) -> DeletionCandidate? {
        switch fp.classification {
        case .pristineNative, .excludedAmbiguous, .noopEmptyAllowlist:
            return nil
        case .markedLegadoShell:
            return DeletionCandidate(
                entryIndex: index,
                entryName: fp.entryName,
                classification: .markedLegadoShell,
                fingerprint: fp,
                allowlistItemMatched: false
            )
        case .unmarkedThreeKeyShell:
            let matched = allowlistItems.contains { matchesAllowlistItem(fp, item: $0) }
            guard matched else { return nil }
            return DeletionCandidate(
                entryIndex: index,
                entryName: fp.entryName,
                classification: .allowlistAuthorized,
                fingerprint: fp,
                allowlistItemMatched: true
            )
        case .allowlistAuthorized:
            return nil
        }
    }

    // MARK: - Canonical JSON

    public static func canonicalJSONString(_ value: Any) -> String? {
        guard let normalized = normalizeJSONValue(value) else { return nil }
        return serializeCanonical(normalized)
    }

    public static func canonicalSHA256(_ value: Any) -> String? {
        guard let s = canonicalJSONString(value) else { return nil }
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func snapshotSHA256(_ snapshot: [String: [String: Any]]) throws -> String {
        let names = snapshot.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        var envelope: [String: Any] = [:]
        for name in names {
            envelope[name] = snapshot[name] as Any
        }
        guard let sha = canonicalSHA256(envelope) else {
            throw NSError(domain: "LegacyNativeShellMigrator", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "snapshot canonical hash 失败",
            ])
        }
        return sha
    }

    private static func normalizeJSONValue(_ value: Any) -> Any? {
        switch value {
        case is NSNull:
            return NSNull()
        case let b as Bool:
            return b
        case let i as Int:
            return i
        case let i as Int8:
            return Int(i)
        case let i as Int16:
            return Int(i)
        case let i as Int32:
            return Int(i)
        case let i as Int64:
            return Int(i)
        case let u as UInt:
            return Int(u)
        case let d as Double:
            return d
        case let f as Float:
            return Double(f)
        case let s as String:
            return s
        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            for (k, v) in dict {
                guard let nv = normalizeJSONValue(v) else { return nil }
                out[k] = nv
            }
            return out
        case let dict as NSDictionary:
            var out: [String: Any] = [:]
            for (k, v) in dict {
                guard let key = k as? String, let nv = normalizeJSONValue(v) else { return nil }
                out[key] = nv
            }
            return out
        case let arr as [Any]:
            return arr.compactMap { normalizeJSONValue($0) }
        case let arr as NSArray:
            return arr.compactMap { normalizeJSONValue($0) }
        default:
            return nil
        }
    }

    private static func serializeCanonical(_ value: Any) -> String? {
        switch value {
        case is NSNull:
            return "null"
        case let b as Bool:
            return b ? "true" : "false"
        case let i as Int:
            return String(i)
        case let d as Double:
            if d.rounded() == d && abs(d) < 9_007_199_254_740_992 {
                return String(Int(d))
            }
            return String(d)
        case let s as String:
            return jsonStringLiteral(s)
        case let dict as [String: Any]:
            let keys = dict.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            var parts: [String] = []
            for key in keys {
                guard let child = dict[key], let cs = serializeCanonical(child) else { return nil }
                parts.append("\(jsonStringLiteral(key)):\(cs)")
            }
            return "{\(parts.joined(separator: ","))}"
        case let arr as [Any]:
            let items = arr.compactMap { serializeCanonical($0) }
            guard items.count == arr.count else { return nil }
            return "[\(items.joined(separator: ","))]"
        default:
            return nil
        }
    }

    private static func jsonStringLiteral(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x00 ... 0x1F:
                out += String(format: "\\u%04x", ch.value)
            default:
                out.append(Character(ch))
            }
        }
        out += "\""
        return out
    }
}
