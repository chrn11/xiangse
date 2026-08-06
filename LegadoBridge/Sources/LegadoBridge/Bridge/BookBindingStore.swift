import Foundation
import CryptoKit

/// 删源后对已绑定书籍的处理策略。v2 合同：删除/停用只改 sourceAvailable，永不删 binding。
@objc public enum SourceDeletePolicy: Int {
    case keepBooksMarkUnavailable = 0
    /// 历史枚举保留；行为与 keep 相同（仅标记不可用，不删 binding）。
    case clearBridgeBindings = 1
}

/// v2 restore 状态机：notStarted → restoring → readyV2 | readOnlyV1 | corruptedBlocked
enum BookBindingRestoreState: Equatable, Sendable {
    case notStarted
    case restoring
    case readyV2
    case readOnlyV1
    case corruptedBlocked
}

struct BookBindingMigrationReport: Equatable, Sendable {
    var migratedCount: Int
    var duplicateCount: Int
    var ambiguityCount: Int
    /// v1 文件内容 hash；不记录 URL。
    var sourceContentSHA256: String
}

struct BookBindingV2Envelope: Codable, Equatable {
    var schemaVersion: Int
    var generation: UInt64
    var createdAt: String
    var checksumAlgorithm: String
    var payloadSHA256: String
    var bindings: [BookBindingV2]
}

/// 可注入的文件写入，测试可拦截真实 Documents。
protocol BookBindingFileWriting: AnyObject {
    func createDirectoryIfNeeded(at url: URL) throws
    func fileExists(at url: URL) -> Bool
    func readData(at url: URL) throws -> Data
    func writeData(_ data: Data, to url: URL) throws
    func removeItem(at url: URL) throws
    /// 写唯一 temp → 关闭 → 读回由调用方验证 → 原子 replace。
    func replaceItemAtomically(tempURL: URL, destinationURL: URL) throws
}

final class DefaultBookBindingFileWriter: BookBindingFileWriting {
    func createDirectoryIfNeeded(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func readData(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func writeData(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
    }

    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    func replaceItemAtomically(tempURL: URL, destinationURL: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destinationURL.path) {
            _ = try fm.replaceItemAt(destinationURL, withItemAt: tempURL)
        } else {
            try fm.moveItem(at: tempURL, to: destinationURL)
        }
    }
}

/// bookUrl / sourceUrl / bridgeToken 持久映射（v2）。
/// 主索引：byIdentity / identityByToken / identitiesByBookUrl。
/// 所有 mutate/restore 在 private serial state queue 上执行。
final class BookBindingStore {
    static let shared = BookBindingStore()

    private static let deletePolicyDefaultsKey = "LegadoBridgeSourceDeletePolicy"
    static let checksumAlgorithm = "sha256-json-sortedKeys-v1"
    static let schemaVersion = 2
    static let v2FileName = "book-bindings-v2.json"
    static let v1FileName = "legado_bridge_books.json"
    static let migrationReportFileName = "book-bindings-migration-report.json"

    private let stateQueue = DispatchQueue(label: "com.xiangse.legado-bridge.book-binding-store")
    private var byIdentity: [BookIdentity: BookBindingV2] = [:]
    private var identityByToken: [String: BookIdentity] = [:]
    private var identitiesByBookUrl: [String: Set<BookIdentity>] = [:]
    private var restoreState: BookBindingRestoreState = .notStarted
    private var generation: UInt64 = 0
    private var lastMigrationReport: BookBindingMigrationReport?
    private var tokenCollisionDetected = false

    private let persistenceRoot: URL
    private let clock: () -> Date
    private let fileWriter: BookBindingFileWriting
    private let usesLegacyDocumentsV1Fallback: Bool

    private var v2FileURL: URL {
        persistenceRoot.appendingPathComponent(Self.v2FileName)
    }

    private var v1FileURL: URL {
        persistenceRoot.appendingPathComponent(Self.v1FileName)
    }

    private var migrationReportURL: URL {
        persistenceRoot.appendingPathComponent(Self.migrationReportFileName)
    }

    /// 生产路径：Application Support/LegadoBridge/
    private static func defaultPersistenceRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("LegadoBridge", isDirectory: true)
    }

    private static func legacyDocumentsV1URL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        return docs.appendingPathComponent(v1FileName)
    }

    private init() {
        self.persistenceRoot = Self.defaultPersistenceRoot()
        self.clock = { Date() }
        self.fileWriter = DefaultBookBindingFileWriter()
        self.usesLegacyDocumentsV1Fallback = true
    }

    /// 测试注入：不得指向真实 Documents / Application Support。
    init(
        persistenceRoot: URL,
        clock: @escaping () -> Date = { Date() },
        fileWriter: BookBindingFileWriting = DefaultBookBindingFileWriter(),
        usesLegacyDocumentsV1Fallback: Bool = false
    ) {
        self.persistenceRoot = persistenceRoot
        self.clock = clock
        self.fileWriter = fileWriter
        self.usesLegacyDocumentsV1Fallback = usesLegacyDocumentsV1Fallback
    }

    static var deletePolicy: SourceDeletePolicy {
        get {
            let raw = UserDefaults.standard.integer(forKey: deletePolicyDefaultsKey)
            return SourceDeletePolicy(rawValue: raw) ?? .keepBooksMarkUnavailable
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: deletePolicyDefaultsKey)
        }
    }

    var currentRestoreState: BookBindingRestoreState {
        stateQueue.sync { restoreState }
    }

    var currentGeneration: UInt64 {
        stateQueue.sync { generation }
    }

    var migrationReport: BookBindingMigrationReport? {
        stateQueue.sync { lastMigrationReport }
    }

    var durableCount: Int {
        stateQueue.sync { byIdentity.count }
    }

    // MARK: - Lookups（API 固定）

    func binding(for identity: BookIdentity) -> BookBindingV2? {
        stateQueue.sync {
            guard restoreState == .readyV2 || restoreState == .readOnlyV1 else { return nil }
            return byIdentity[identity]
        }
    }

    func binding(forToken token: String) -> Result<BookBindingV2, BookBindingLookupError> {
        stateQueue.sync {
            if tokenCollisionDetected || restoreState == .corruptedBlocked {
                return .failure(.tokenCollision)
            }
            guard restoreState == .readyV2 || restoreState == .readOnlyV1 else {
                return .failure(.storeNotReady)
            }
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .failure(.emptyKey) }
            guard let identity = identityByToken[trimmed],
                  let binding = byIdentity[identity] else {
                return .failure(.notFound)
            }
            if binding.bridgeToken != trimmed {
                return .failure(.tokenCollision)
            }
            return .success(binding)
        }
    }

    func bindings(forBookUrl bookUrl: String) -> [BookBindingV2] {
        stateQueue.sync {
            guard restoreState == .readyV2 || restoreState == .readOnlyV1 else { return [] }
            let trimmed = bookUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let set = identitiesByBookUrl[trimmed] else { return [] }
            return set.compactMap { byIdentity[$0] }
        }
    }

    func uniqueLegacyBinding(forBookUrl bookUrl: String) -> Result<BookBindingV2, BookBindingLookupError> {
        let list = bindings(forBookUrl: bookUrl)
        if list.isEmpty { return .failure(.notFound) }
        if list.count > 1 { return .failure(.ambiguous) }
        return .success(list[0])
    }

    /// §24.2 resolver：token → 显式 pair → legacy 唯一 bookUrl。禁止活动源 / originURL / bookCache 猜源。
    func resolveBinding(
        token: String?,
        exactSourceUrl: String?,
        bookUrl: String?
    ) -> Result<BookBindingV2, BookBindingLookupError> {
        if let rawToken = token?.trimmingCharacters(in: .whitespacesAndNewlines), !rawToken.isEmpty {
            switch binding(forToken: rawToken) {
            case .success(let hit):
                if let src = exactSourceUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !src.isEmpty,
                   src != hit.sourceUrl {
                    return .failure(.identityMismatch)
                }
                if let book = bookUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !book.isEmpty,
                   book != hit.bookUrl {
                    return .failure(.identityMismatch)
                }
                return .success(hit)
            case .failure(let err):
                return .failure(err)
            }
        }

        if let src = exactSourceUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !src.isEmpty,
           let book = bookUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !book.isEmpty {
            do {
                let identity = try BookIdentity(exactSourceUrl: src, exactBookUrl: book)
                if let hit = binding(for: identity) {
                    return .success(hit)
                }
                return .failure(.notFound)
            } catch {
                return .failure(.emptyKey)
            }
        }

        if let book = bookUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !book.isEmpty {
            return uniqueLegacyBinding(forBookUrl: book)
        }
        return .failure(.emptyKey)
    }

    func allBindingsV2() -> [BookBindingV2] {
        stateQueue.sync { Array(byIdentity.values) }
    }

    // MARK: - Mutate

    func upsertAndFlush(binding: BookBindingV2, completion: ((Result<BookBindingV2, BookBindingUpsertError>) -> Void)? = nil) {
        stateQueue.async {
            let result = self.upsertAndFlushLocked(binding: binding)
            completion?(result)
        }
    }

    /// 同步 upsert（测试 / Core 桥接）；仍在 serial queue 上执行。
    @discardableResult
    func upsertAndFlushSync(_ binding: BookBindingV2) -> Result<BookBindingV2, BookBindingUpsertError> {
        stateQueue.sync {
            upsertAndFlushLocked(binding: binding)
        }
    }

    func markSourceAvailability(exactSourceUrl: String, available: Bool) {
        stateQueue.async {
            _ = self.markSourceAvailabilityLocked(exactSourceUrl: exactSourceUrl, available: available)
        }
    }

    @discardableResult
    func markSourceAvailabilitySync(exactSourceUrl: String, available: Bool) -> Bool {
        stateQueue.sync {
            markSourceAvailabilityLocked(exactSourceUrl: exactSourceUrl, available: available)
        }
    }

    /// 删源入口：只改 sourceAvailable，不删 binding / shelf / progress。
    func applySourceDeleted(sourceUrl: String, policy: SourceDeletePolicy = BookBindingStore.deletePolicy) {
        _ = policy
        markSourceAvailability(exactSourceUrl: sourceUrl, available: false)
    }

    // MARK: - Restore

    @discardableResult
    func restoreFromDiskIfNeeded() -> Int {
        stateQueue.sync {
            switch restoreState {
            case .readyV2, .readOnlyV1, .corruptedBlocked:
                return byIdentity.count
            case .restoring:
                return byIdentity.count
            case .notStarted:
                break
            }
            return performRestoreLocked()
        }
    }

    /// 必须在 stateQueue 内调用。
    @discardableResult
    private func performRestoreLocked() -> Int {
        restoreState = .restoring
        clearIndexesLocked()
        tokenCollisionDetected = false
        lastMigrationReport = nil

        do {
            try fileWriter.createDirectoryIfNeeded(at: persistenceRoot)
        } catch {
            restoreState = .corruptedBlocked
            return 0
        }

        if fileWriter.fileExists(at: v2FileURL) {
            do {
                let data = try fileWriter.readData(at: v2FileURL)
                let envelope = try Self.decodeEnvelope(data)
                try Self.verifyChecksum(envelope)
                try installBindingsLocked(envelope.bindings, expectedGeneration: envelope.generation)
                generation = envelope.generation
                restoreState = .readyV2
                return byIdentity.count
            } catch let err as BookBindingLookupError where err == .tokenCollision {
                tokenCollisionDetected = true
                restoreState = .corruptedBlocked
                return byIdentity.count
            } catch {
                // v2 损坏：保留原文件，尝试只读 v1，阻止 durable mutation
                if loadV1ReadOnlyLocked() {
                    restoreState = .readOnlyV1
                } else {
                    restoreState = .corruptedBlocked
                }
                return byIdentity.count
            }
        }

        // v2 不存在：尝试 v1 迁移（v1 永不删除）
        if let report = migrateFromV1IfNeededLocked() {
            lastMigrationReport = report
            persistMigrationReportLocked(report)
            if restoreState == .restoring {
                restoreState = .readyV2
            }
            return byIdentity.count
        }

        generation = 0
        restoreState = .readyV2
        return 0
    }

    // MARK: - Legacy compat helpers（Core / 旧测试）

    /// 旧 API 兼容：空 key 改为 typed error（不再返回 lb_invalid 占位）。
    @discardableResult
    func bind(
        bookUrl: String,
        sourceUrl: String,
        sourceName: String = "",
        name: String = "",
        author: String = "",
        coverUrl: String = "",
        bridgeToken: String? = nil,
        sourceAvailable: Bool = true
    ) throws -> BookBinding {
        let identity: BookIdentity
        do {
            identity = try BookIdentity(exactSourceUrl: sourceUrl, exactBookUrl: bookUrl)
        } catch {
            throw BookBindingUpsertError.emptyKey
        }
        let now = clock()
        var v2 = BookBindingV2(
            identity: identity,
            bridgeToken: (bridgeToken?.isEmpty == false) ? bridgeToken : identity.bridgeTokenV2,
            sourceNameSnapshot: sourceName.isEmpty ? nil : sourceName,
            name: name.isEmpty ? nil : name,
            author: author.isEmpty ? nil : author,
            coverUrl: coverUrl.isEmpty ? nil : coverUrl,
            sourceAvailable: sourceAvailable,
            createdAt: now,
            updatedAt: now
        )
        if let existing = binding(for: identity) {
            v2.createdAt = existing.createdAt
            if v2.name == nil { v2.name = existing.name }
            if v2.author == nil { v2.author = existing.author }
            if v2.coverUrl == nil { v2.coverUrl = existing.coverUrl }
            if v2.sourceNameSnapshot == nil { v2.sourceNameSnapshot = existing.sourceNameSnapshot }
        }
        switch upsertAndFlushSync(v2) {
        case .success(let saved):
            return BookBinding(from: saved)
        case .failure(let err):
            throw err
        }
    }

    func binding(forBookUrl bookUrl: String) -> BookBinding? {
        switch uniqueLegacyBinding(forBookUrl: bookUrl) {
        case .success(let v2): return BookBinding(from: v2)
        case .failure: return nil
        }
    }

    func sourceUrl(forBookUrl bookUrl: String) -> String? {
        switch uniqueLegacyBinding(forBookUrl: bookUrl) {
        case .success(let v2): return v2.sourceUrl
        case .failure: return nil
        }
    }

    func allBindings() -> [BookBinding] {
        allBindingsV2().map { BookBinding(from: $0) }
    }

    func markSourceUnavailable(sourceUrl: String) {
        markSourceAvailability(exactSourceUrl: sourceUrl, available: false)
    }

    func markSourceAvailable(sourceUrl: String) {
        markSourceAvailability(exactSourceUrl: sourceUrl, available: true)
    }

    /// v2 合同禁止按源删除 binding；保留方法签名为空操作并改为 mark unavailable。
    func removeBindings(forSourceUrl sourceUrl: String) {
        markSourceAvailability(exactSourceUrl: sourceUrl, available: false)
    }

    func removeBinding(bookUrl: String) {
        // 不再支持按 bookUrl 删除（可能歧义）；保留 no-op 以免调用方崩溃。
        _ = bookUrl
    }

    /// 旧短 token（仅兼容读；新写入一律 v2）。
    static func makeToken(bookUrl: String, sourceUrl: String) -> String {
        (try? BookIdentity(exactSourceUrl: sourceUrl, exactBookUrl: bookUrl))?.bridgeTokenV2
            ?? "lb2_invalid"
    }

    func resetForTesting(clearPersistFile: Bool = true) {
        stateQueue.sync {
            clearIndexesLocked()
            restoreState = .notStarted
            generation = 0
            lastMigrationReport = nil
            tokenCollisionDetected = false
            if clearPersistFile {
                try? fileWriter.removeItem(at: v2FileURL)
                try? fileWriter.removeItem(at: migrationReportURL)
                // 不删除 v1（合同：v1 永不删除）；测试自备 isolation root 时可整目录清掉
                if !usesLegacyDocumentsV1Fallback {
                    try? fileWriter.removeItem(at: v1FileURL)
                }
            }
        }
        UserDefaults.standard.removeObject(forKey: Self.deletePolicyDefaultsKey)
    }

    // MARK: - Locked helpers

    private func clearIndexesLocked() {
        byIdentity.removeAll()
        identityByToken.removeAll()
        identitiesByBookUrl.removeAll()
    }

    private func upsertAndFlushLocked(binding: BookBindingV2) -> Result<BookBindingV2, BookBindingUpsertError> {
        if restoreState == .notStarted {
            _ = performRestoreLocked()
        }
        switch restoreState {
        case .readyV2:
            break
        case .readOnlyV1:
            return .failure(.readOnly)
        case .corruptedBlocked:
            return .failure(.corrupted)
        case .notStarted, .restoring:
            return .failure(.storeNotReady)
        }

        var next = binding
        let now = clock()
        if let old = byIdentity[binding.identity] {
            next.createdAt = old.createdAt
            next.updatedAt = now
            if next.bridgeToken.isEmpty {
                next.bridgeToken = old.bridgeToken
            }
        } else {
            next.createdAt = now
            next.updatedAt = now
            if next.bridgeToken.isEmpty {
                next.bridgeToken = next.identity.bridgeTokenV2
            }
        }

        // token 必须与 identity 一致；冲突则拒绝
        let expected = next.identity.bridgeTokenV2
        if next.bridgeToken != expected {
            return .failure(.persistFailed)
        }
        if let existingIdentity = identityByToken[next.bridgeToken], existingIdentity != next.identity {
            tokenCollisionDetected = true
            restoreState = .corruptedBlocked
            return .failure(.corrupted)
        }

        indexInsertLocked(next)
        generation &+= 1
        do {
            try persistV2Locked()
            return .success(next)
        } catch {
            // 回滚内存？保持 generation 与磁盘一致：失败则标记并返回错误
            return .failure(.persistFailed)
        }
    }

    private func markSourceAvailabilityLocked(exactSourceUrl: String, available: Bool) -> Bool {
        let trimmed = exactSourceUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard restoreState == .readyV2 else { return false }
        var changed = false
        let now = clock()
        for (identity, var binding) in byIdentity where identity.sourceUrl == trimmed {
            if binding.sourceAvailable != available {
                binding.sourceAvailable = available
                binding.updatedAt = now
                byIdentity[identity] = binding
                changed = true
            }
        }
        if changed {
            generation &+= 1
            try? persistV2Locked()
        }
        return changed
    }

    private func indexInsertLocked(_ binding: BookBindingV2) {
        if let old = byIdentity[binding.identity], old.bridgeToken != binding.bridgeToken {
            identityByToken.removeValue(forKey: old.bridgeToken)
        }
        byIdentity[binding.identity] = binding
        identityByToken[binding.bridgeToken] = binding.identity
        var set = identitiesByBookUrl[binding.bookUrl] ?? []
        set.insert(binding.identity)
        identitiesByBookUrl[binding.bookUrl] = set
    }

    private func installBindingsLocked(_ bindings: [BookBindingV2], expectedGeneration: UInt64) throws {
        clearIndexesLocked()
        var seenToken: [String: BookIdentity] = [:]
        for binding in bindings {
            if let prior = seenToken[binding.bridgeToken], prior != binding.identity {
                tokenCollisionDetected = true
                throw BookBindingLookupError.tokenCollision
            }
            // token 与 identity 不一致视为损坏
            if binding.bridgeToken != binding.identity.bridgeTokenV2 {
                throw BookBindingLookupError.corrupted
            }
            seenToken[binding.bridgeToken] = binding.identity
            indexInsertLocked(binding)
        }
        generation = expectedGeneration
    }

    private func persistV2Locked() throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let sorted = byIdentity.values.sorted { a, b in
            if a.sourceUrl != b.sourceUrl { return a.sourceUrl < b.sourceUrl }
            return a.bookUrl < b.bookUrl
        }
        let payloadSHA = try Self.payloadSHA256(bindings: sorted)
        let envelope = BookBindingV2Envelope(
            schemaVersion: Self.schemaVersion,
            generation: generation,
            createdAt: iso.string(from: clock()),
            checksumAlgorithm: Self.checksumAlgorithm,
            payloadSHA256: payloadSHA,
            bindings: sorted
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(envelope)

        try fileWriter.createDirectoryIfNeeded(at: persistenceRoot)
        let tempName = "book-bindings-v2.\(generation).\(UUID().uuidString).tmp"
        let tempURL = persistenceRoot.appendingPathComponent(tempName)
        try fileWriter.writeData(data, to: tempURL)

        // 读回验证
        let readBack = try fileWriter.readData(at: tempURL)
        let decoded = try Self.decodeEnvelope(readBack)
        try Self.verifyChecksum(decoded)
        guard decoded.generation == generation, decoded.bindings.count == sorted.count else {
            try? fileWriter.removeItem(at: tempURL)
            throw BookBindingUpsertError.persistFailed
        }

        do {
            try fileWriter.replaceItemAtomically(tempURL: tempURL, destinationURL: v2FileURL)
        } catch {
            try? fileWriter.removeItem(at: tempURL)
            throw BookBindingUpsertError.persistFailed
        }
        // 残留 temp 清理（replace 成功后 temp 应已不存在）
        if fileWriter.fileExists(at: tempURL) {
            try? fileWriter.removeItem(at: tempURL)
        }
    }

    private func migrateFromV1IfNeededLocked() -> BookBindingMigrationReport? {
        let candidates: [URL] = {
            var list = [v1FileURL]
            if usesLegacyDocumentsV1Fallback {
                list.append(Self.legacyDocumentsV1URL())
            }
            return list
        }()

        var data: Data?
        var sourceURL: URL?
        for url in candidates {
            if fileWriter.fileExists(at: url),
               let d = try? fileWriter.readData(at: url), !d.isEmpty {
                data = d
                sourceURL = url
                break
            }
        }
        guard let data, sourceURL != nil else { return nil }

        let contentHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let arr = object as? [[String: Any]] else {
            return BookBindingMigrationReport(
                migratedCount: 0,
                duplicateCount: 0,
                ambiguityCount: 0,
                sourceContentSHA256: contentHash
            )
        }

        var migrated = 0
        var duplicates = 0
        var ambiguity = 0
        var bookUrlCounts: [String: Int] = [:]
        let now = clock()

        for item in arr {
            guard let bookUrl = item["bookUrl"] as? String,
                  let sourceUrl = item["sourceUrl"] as? String,
                  let identity = try? BookIdentity(exactSourceUrl: sourceUrl, exactBookUrl: bookUrl) else {
                continue
            }
            bookUrlCounts[identity.bookUrl, default: 0] += 1
            if byIdentity[identity] != nil {
                duplicates += 1
                continue
            }
            let token = identity.bridgeTokenV2
            if let existing = identityByToken[token], existing != identity {
                tokenCollisionDetected = true
                restoreState = .corruptedBlocked
                return BookBindingMigrationReport(
                    migratedCount: migrated,
                    duplicateCount: duplicates,
                    ambiguityCount: ambiguity,
                    sourceContentSHA256: contentHash
                )
            }
            let available: Bool = {
                if let b = item["sourceAvailable"] as? Bool { return b }
                if let n = item["sourceAvailable"] as? NSNumber { return n.boolValue }
                return true
            }()
            let updatedAt: Date = {
                if let t = item["updatedAt"] as? TimeInterval {
                    return Date(timeIntervalSince1970: t)
                }
                if let n = item["updatedAt"] as? NSNumber {
                    return Date(timeIntervalSince1970: n.doubleValue)
                }
                return now
            }()
            let binding = BookBindingV2(
                identity: identity,
                bridgeToken: token,
                sourceNameSnapshot: item["sourceName"] as? String,
                name: item["name"] as? String,
                author: item["author"] as? String,
                coverUrl: item["coverUrl"] as? String,
                sourceAvailable: available,
                createdAt: updatedAt,
                updatedAt: updatedAt
            )
            indexInsertLocked(binding)
            migrated += 1
        }

        for (_, count) in bookUrlCounts where count > 1 {
            ambiguity += 1
        }

        generation = 1
        do {
            try persistV2Locked()
        } catch {
            // 迁移写失败：保留内存索引但标 readOnly，避免丢 v1
            restoreState = .readOnlyV1
        }

        return BookBindingMigrationReport(
            migratedCount: migrated,
            duplicateCount: duplicates,
            ambiguityCount: ambiguity,
            sourceContentSHA256: contentHash
        )
    }

    private func loadV1ReadOnlyLocked() -> Bool {
        let candidates: [URL] = {
            var list = [v1FileURL]
            if usesLegacyDocumentsV1Fallback {
                list.append(Self.legacyDocumentsV1URL())
            }
            return list
        }()
        for url in candidates {
            guard fileWriter.fileExists(at: url),
                  let data = try? fileWriter.readData(at: url),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let arr = object as? [[String: Any]] else { continue }
            clearIndexesLocked()
            for item in arr {
                guard let bookUrl = item["bookUrl"] as? String,
                      let sourceUrl = item["sourceUrl"] as? String,
                      let identity = try? BookIdentity(exactSourceUrl: sourceUrl, exactBookUrl: bookUrl) else {
                    continue
                }
                let token = identity.bridgeTokenV2
                let binding = BookBindingV2(
                    identity: identity,
                    bridgeToken: token,
                    sourceNameSnapshot: item["sourceName"] as? String,
                    name: item["name"] as? String,
                    author: item["author"] as? String,
                    coverUrl: item["coverUrl"] as? String,
                    sourceAvailable: true,
                    createdAt: clock(),
                    updatedAt: clock()
                )
                indexInsertLocked(binding)
            }
            return !byIdentity.isEmpty
        }
        return false
    }

    private func persistMigrationReportLocked(_ report: BookBindingMigrationReport) {
        let obj: [String: Any] = [
            "migratedCount": report.migratedCount,
            "duplicateCount": report.duplicateCount,
            "ambiguityCount": report.ambiguityCount,
            "sourceContentSHA256": report.sourceContentSHA256
        ]
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else {
            return
        }
        try? fileWriter.writeData(data, to: migrationReportURL)
    }

    // MARK: - Checksum

    static func payloadSHA256(bindings: [BookBindingV2]) throws -> String {
        let sorted = bindings.sorted { a, b in
            if a.sourceUrl != b.sourceUrl { return a.sourceUrl < b.sourceUrl }
            return a.bookUrl < b.bookUrl
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(sorted)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func decodeEnvelope(_ data: Data) throws -> BookBindingV2Envelope {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BookBindingV2Envelope.self, from: data)
    }

    static func verifyChecksum(_ envelope: BookBindingV2Envelope) throws {
        guard envelope.schemaVersion == schemaVersion else {
            throw BookBindingLookupError.corrupted
        }
        guard envelope.checksumAlgorithm == checksumAlgorithm else {
            throw BookBindingLookupError.corrupted
        }
        let actual = try payloadSHA256(bindings: envelope.bindings)
        guard actual == envelope.payloadSHA256 else {
            throw BookBindingLookupError.corrupted
        }
    }
}
