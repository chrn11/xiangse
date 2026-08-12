import Foundation
import CryptoKit

/// Legado discovery last-good persistence.
///
/// This store deliberately has no XBS or untyped cache entry point.  A hot
/// read/write is accepted only when the coordinator-issued `CachePermitToken`
/// agrees
/// with the complete stable key and with the process registry/runtime
/// generations.  A cold read is a separate, explicitly named operation: it
/// uses the stable key and the envelope TTL, and therefore does not pretend
/// that a token from a previous process is still current.
public final class ExploreCatalogStore: @unchecked Sendable {
    public static let legadoSourceKind = 2
    public static let schemaVersion = 2

    public struct Config: Equatable, Sendable {
        public var totalBudgetBytes: Int
        public var maxEntries: Int
        public var maxNodesPerSource: Int
        public var maxPagesPerNode: Int
        public var maxSnapshotBytes: Int
        public var maxEntryBytes: Int
        public var ttl: TimeInterval

        public static let `default` = Config(
            totalBudgetBytes: 64 * 1024 * 1024,
            maxEntries: 256,
            maxNodesPerSource: 16,
            maxPagesPerNode: 3,
            maxSnapshotBytes: 4 * 1024 * 1024,
            maxEntryBytes: 4 * 1024 * 1024 + 128 * 1024,
            ttl: 7 * 24 * 60 * 60
        )

        /// `maxEntryBytes` protects the encoded envelope in addition to the
        /// payload limit.  The default leaves room for identity/checksum
        /// metadata while preserving the historical four MiB snapshot cap.
        public init(
            totalBudgetBytes: Int,
            maxEntries: Int = 256,
            maxNodesPerSource: Int,
            maxPagesPerNode: Int,
            maxSnapshotBytes: Int,
            maxEntryBytes: Int? = nil,
            ttl: TimeInterval = 7 * 24 * 60 * 60
        ) {
            self.totalBudgetBytes = totalBudgetBytes
            self.maxEntries = maxEntries
            self.maxNodesPerSource = maxNodesPerSource
            self.maxPagesPerNode = maxPagesPerNode
            self.maxSnapshotBytes = maxSnapshotBytes
            self.maxEntryBytes = maxEntryBytes ?? maxSnapshotBytes + 128 * 1024
            self.ttl = ttl
        }
    }

    public enum ExploreUIState: String, Codable, Equatable, Sendable {
        case ready
        case refreshingWithLastGood
        case coldLoading
        case refreshFailedWithLastGood
        case failedWithoutCache
        case emptySuccess
    }

    /// Stable cold-start lookup identity.  This type deliberately contains
    /// no process/session permit, so a cold read can never masquerade as a
    /// typed hot publication.
    public struct CacheLookupKey: Codable, Equatable, Hashable, Sendable {
        public let sourceKind: Int
        public let canonicalID: String
        public let exactURL: String
        public let nodeID: String
        public let page: Int

        public init(
            sourceKind: Int = ExploreCatalogStore.legadoSourceKind,
            canonicalID: String,
            exactURL: String,
            nodeID: String,
            page: Int
        ) {
            self.sourceKind = sourceKind
            self.canonicalID = canonicalID
            self.exactURL = exactURL
            self.nodeID = nodeID
            self.page = page
        }

        /// Compatibility spelling for the existing Swift token vocabulary.
        public init(
            sourceKind: Int = ExploreCatalogStore.legadoSourceKind,
            canonicalID: String,
            exactSourceUrl: String,
            nodeID: String,
            page: Int
        ) {
            self.init(
                sourceKind: sourceKind,
                canonicalID: canonicalID,
                exactURL: exactSourceUrl,
                nodeID: nodeID,
                page: page
            )
        }

        public var exactSourceUrl: String { exactURL }

        /// 字段逐个使用固定宽度长度前缀，字段内容中的任意分隔符都不会改变边界。
        /// 版本域同时隔离完整 key 与 source key，避免两类摘要共享输入空间。
        fileprivate var stableData: Data {
            Self.framedData([
                "ExploreCatalogStore.CacheLookupKey.v1",
                String(sourceKind),
                canonicalID,
                exactURL,
                nodeID,
                String(page)
            ])
        }

        public var stableKey: String {
            stableData.base64EncodedString()
        }

        fileprivate var sourceData: Data {
            Self.framedData([
                "ExploreCatalogStore.Source.v1",
                String(sourceKind),
                canonicalID,
                exactURL
            ])
        }

        private static func framedData(_ fields: [String]) -> Data {
            var result = Data()
            for field in fields {
                let bytes = Data(field.utf8)
                var length = UInt64(bytes.count).bigEndian
                let prefix = withUnsafeBytes(of: &length) { Array($0) }
                result.append(contentsOf: prefix)
                result.append(bytes)
            }
            return result
        }
    }

    /// Source-only compatibility spelling.  Cold APIs use the explicit
    /// `CacheLookupKey` name; this alias does not create a hot/untyped path.
    public typealias CacheKey = CacheLookupKey

    /// Provenance is kept as a deterministic string in the envelope.  It is
    /// redundant with the typed fields by design: a hand-edited JSON file
    /// cannot alter one identity component without failing provenance
    /// validation on read.
    private struct CacheProvenance: Codable, Equatable, Sendable {
        public let sourceKind: Int
        public let canonicalID: String
        public let exactURL: String
        public let nodeID: String
        public let page: Int
        public let registryGeneration: UInt64
        public let runtimeEpoch: UInt64

        public init(
            sourceKind: Int,
            canonicalID: String,
            exactURL: String,
            nodeID: String,
            page: Int,
            registryGeneration: UInt64,
            runtimeEpoch: UInt64
        ) {
            self.sourceKind = sourceKind
            self.canonicalID = canonicalID
            self.exactURL = exactURL
            self.nodeID = nodeID
            self.page = page
            self.registryGeneration = registryGeneration
            self.runtimeEpoch = runtimeEpoch
        }

        fileprivate var stableRepresentation: String {
            let object: [String: Any] = [
                "sourceKind": sourceKind,
                "canonicalID": canonicalID,
                "exactURL": exactURL,
                "nodeID": nodeID,
                "page": page,
                "registryGeneration": registryGeneration,
                "runtimeEpoch": runtimeEpoch
            ]
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
                return ""
            }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    /// A complete, self-validating cache envelope.  `payload` is the only
    /// content persisted; no cookies, headers, request rules, or live objects
    /// belong here.
    public struct CacheEnvelope: Codable, Equatable, Sendable {
        public let schemaVersion: Int
        public let lookupKey: CacheLookupKey
        /// The complete coordinator-issued identity is persisted as one typed
        /// value.  Every field (mode, nonce, key hash, source/session,
        /// snapshot, request/generation values, and owner) is checked on hot
        /// reads; no partial identity is accepted.
        public let permit: CachePermitToken
        public let provenance: String
        public let capturedAt: Date
        public let expiresAt: Date
        public let checksum: String
        public let writeNonce: String
        public let payload: Data
        public var lastAccessAt: Date

        public init(
            schemaVersion: Int = ExploreCatalogStore.schemaVersion,
            lookupKey: CacheLookupKey,
            permit: CachePermitToken,
            provenance: String,
            capturedAt: Date,
            expiresAt: Date,
            checksum: String,
            writeNonce: String,
            payload: Data,
            lastAccessAt: Date? = nil
        ) {
            self.schemaVersion = schemaVersion
            self.lookupKey = lookupKey
            self.permit = permit
            self.provenance = provenance
            self.capturedAt = capturedAt
            self.expiresAt = expiresAt
            self.checksum = checksum
            self.writeNonce = writeNonce
            self.payload = payload
            self.lastAccessAt = lastAccessAt ?? capturedAt
        }

        public var sourceKind: Int { lookupKey.sourceKind }
        public var canonicalID: String { lookupKey.canonicalID }
        public var exactURL: String { lookupKey.exactURL }
        public var exactSourceUrl: String { lookupKey.exactURL }
        public var nodeID: String { lookupKey.nodeID }
        public var page: Int { lookupKey.page }
        public var mode: ExplorePublishMode { permit.mode }
        public var permitNonce: String { permit.permitNonce }
        public var envelopeKeyHash: String { permit.envelopeKeyHash }
        public var snapshotID: String? { permit.snapshotID }
        public var definitionFingerprint: String? { permit.definitionFingerprint }
        public var registryGeneration: UInt64 { permit.managerOrRegistryGeneration }
        public var runtimeEpoch: UInt64 { permit.runtimeEpoch }
        public var selectionGeneration: UInt64 { permit.selectionGeneration }
        public var uiGeneration: UInt64 { permit.uiGeneration }
        public var definitionGeneration: UInt64 { permit.definitionGeneration }
        public var contentGeneration: UInt64 { permit.contentGeneration }
        public var requestSequence: UInt64 { permit.requestSequence }
        public var ownerControllerIdentity: String? { permit.ownerControllerIdentity }
        public var sessionKey: String { permit.sessionKey }
        public var payloadSHA256: String { checksum }
        public var createdAt: Date { capturedAt }
        public var lastSuccessAt: Date { capturedAt }
        public var runtimeEpochProvenance: String { provenance }
    }

    public enum StoreError: Error, Equatable, Sendable {
        case sourceKindMismatch
        case invalidParameter
        case tokenIdentityMismatch
        case snapshotMismatch
        case definitionFingerprintMismatch
        case registryGenerationMismatch
        case runtimeEpochMismatch
        case emptyPayload
        case snapshotTooLarge
        case entryTooLarge
        case checksumMismatch
        case expired
        case futureTimestamp
        case malformedEnvelope
        case invalidConfiguration
        case ioFailure
        case cachePermitRequired
        case cacheModeMismatch
    }

    private let root: URL
    private let config: Config
    private let queue = DispatchQueue(label: "com.xiangse.legado-bridge.explore-catalog-store")
    private let fileManager: FileManager
    private let rootLock: NSLock

    private static let rootLocksGuard = NSLock()
    private static var rootLocks: [String: NSLock] = [:]

    private static func lock(for root: URL) -> NSLock {
        let path = root.standardizedFileURL.path
        rootLocksGuard.lock()
        defer { rootLocksGuard.unlock() }
        if let existing = rootLocks[path] { return existing }
        let created = NSLock()
        rootLocks[path] = created
        return created
    }

    public init(
        persistenceRoot: URL,
        config: Config = .default,
        fileManager: FileManager = .default
    ) {
        self.root = persistenceRoot
        self.config = config
        self.fileManager = fileManager
        self.rootLock = Self.lock(for: persistenceRoot)
    }

    private var cacheRoot: URL {
        root.appendingPathComponent("Explore", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(_ string: String) -> String {
        sha256(Data(string.utf8))
    }

    /// Retained as a source-only helper; it is now a stable SHA.
    public static func sourceHash(exactSourceUrl: String) -> String {
        sha256(exactSourceUrl)
    }

    public static func stableFilename(for key: CacheKey) -> String {
        "\(sha256(key.stableData)).json"
    }

    /// Typed writer.  Cache publication is authorized only by the coordinator
    /// issued `CachePermitToken`; a normal session token cannot enter this
    /// API.  The permit is persisted in full inside the envelope.
    @discardableResult
    public func writeLastGood(
        key: CacheLookupKey,
        token: CachePermitToken,
        payload: Data,
        ttl: TimeInterval? = nil,
        expiresAt: Date? = nil,
        now: Date = Date()
    ) throws -> CacheEnvelope {
        try queue.sync {
            rootLock.lock()
            defer { rootLock.unlock() }
            try validateConfigurationLocked()
            try validateKey(key)
            try validatePermit(token, for: key)
            guard !payload.isEmpty else { throw StoreError.emptyPayload }
            guard payload.count <= config.maxSnapshotBytes else {
                throw StoreError.snapshotTooLarge
            }

            let effectiveExpiry: Date
            if let expiresAt {
                if let ttl, abs(ttl - expiresAt.timeIntervalSince(now)) > 0.000_001 {
                    throw StoreError.invalidParameter
                }
                effectiveExpiry = expiresAt
            } else {
                effectiveExpiry = now.addingTimeInterval(ttl ?? config.ttl)
            }
            guard effectiveExpiry > now else { throw StoreError.invalidParameter }

            var envelope = CacheEnvelope(
                lookupKey: key,
                permit: token,
                provenance: makeProvenance(key: key, permit: token),
                capturedAt: now,
                expiresAt: effectiveExpiry,
                checksum: Self.sha256(payload),
                writeNonce: token.permitNonce,
                payload: payload,
                lastAccessAt: now
            )
            let encoded = try Self.makeEncoder().encode(envelope)
            guard encoded.count <= config.maxEntryBytes else {
                throw StoreError.entryTooLarge
            }
            let destination = try destinationURL(for: key)
            try writeEnvelopeAtomicallyLocked(encoded: encoded, to: destination)
            // Read back the bytes written to the destination before exposing
            // the result.  This catches partial writes and date/checksum
            // strategy drift in the same process.
            let readBack = try Data(contentsOf: destination)
            envelope = try decodeAndValidateEnvelope(readBack, for: key, now: now, enforceTTL: false)
            try enforceLRULocked()
            return envelope
        }
    }

    /// Hot/process read.  Invalid input, stale generations, corrupt entries,
    /// and expired/future envelopes all fail closed as a cache miss.
    public func readLastGood(
        key: CacheLookupKey,
        token: CachePermitToken,
        now: Date = Date()
    ) -> CacheEnvelope? {
        queue.sync {
            rootLock.lock()
            defer { rootLock.unlock() }
            guard (try? validateKey(key)) != nil,
                  (try? validatePermit(token, for: key)) != nil else {
                return nil
            }
            return readEnvelopeLocked(
                key: key,
                token: token,
                now: now,
                enforceTTL: true
            )
        }
    }

    /// Cold-start read.  Only stable Legado identity and the envelope TTL are
    /// considered; an old registry/runtime generation is not a reason to
    /// discard an otherwise valid last-good snapshot during process startup.
    public func readColdLastGood(
        key: CacheLookupKey,
        now: Date = Date()
    ) -> CacheEnvelope? {
        queue.sync {
            rootLock.lock()
            defer { rootLock.unlock() }
            guard (try? validateKey(key)) != nil else { return nil }
            return readEnvelopeLocked(key: key, token: nil, now: now, enforceTTL: true)
        }
    }

    public func readColdLastGood(
        canonicalID: String,
        exactSourceUrl: String,
        nodeID: String,
        page: Int,
        now: Date = Date()
    ) -> CacheEnvelope? {
        readColdLastGood(
            key: CacheKey(
                canonicalID: canonicalID,
                exactURL: exactSourceUrl,
                nodeID: nodeID,
                page: page
            ),
            now: now
        )
    }

    /// Alternate spelling used by cold-start call sites; unlike the hot API,
    /// this operation deliberately has no token parameter.
    public func readLastGoodCold(key: CacheLookupKey, now: Date = Date()) -> CacheEnvelope? {
        readColdLastGood(key: key, now: now)
    }

    private func validateConfigurationLocked() throws {
        guard config.totalBudgetBytes > 0,
              config.maxEntries > 0,
              config.maxNodesPerSource > 0,
              config.maxPagesPerNode > 0,
              config.maxSnapshotBytes > 0,
              config.maxEntryBytes > 0,
              config.ttl > 0 else {
            throw StoreError.invalidConfiguration
        }
    }

    private func validateKey(_ key: CacheKey) throws {
        guard key.sourceKind == Self.legadoSourceKind else {
            throw StoreError.sourceKindMismatch
        }
        guard !key.canonicalID.isEmpty,
              !key.exactURL.isEmpty,
              !key.nodeID.isEmpty,
              key.page > 0,
              !key.canonicalID.contains("\u{0}"),
              !key.exactURL.contains("\u{0}"),
              !key.nodeID.contains("\u{0}") else {
            throw StoreError.invalidParameter
        }
    }

    private func validatePermit(_ token: CachePermitToken, for key: CacheLookupKey) throws {
        guard token.sourceKind == .legado,
              token.sourceKindCode == Self.legadoSourceKind else {
            throw StoreError.sourceKindMismatch
        }
        guard token.mode != .networkFirst else { throw StoreError.cacheModeMismatch }
        guard !token.permitNonce.isEmpty,
              !token.envelopeKeyHash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              token.canonicalID == key.canonicalID,
               token.exactSourceUrl == key.exactURL,
               token.nodeID == key.nodeID,
               token.page == key.page else {
            throw StoreError.tokenIdentityMismatch
        }
        guard let snapshot = token.snapshotID, !snapshot.isEmpty,
              let fingerprint = token.definitionFingerprint, !fingerprint.isEmpty,
              let node = token.nodeID, !node.isEmpty,
              let owner = token.ownerControllerIdentity, !owner.isEmpty,
              token.sessionKey == SelectionToken.sessionKey(sourceKind: .legado, canonicalID: key.canonicalID) else {
            throw StoreError.tokenIdentityMismatch
        }
    }

    private func makeProvenance(
        key: CacheLookupKey,
        permit: CachePermitToken
    ) -> String {
        CacheProvenance(
            sourceKind: Self.legadoSourceKind,
            canonicalID: key.canonicalID,
            exactURL: key.exactURL,
            nodeID: key.nodeID,
            page: key.page,
            registryGeneration: permit.managerOrRegistryGeneration,
            runtimeEpoch: permit.runtimeEpoch
        ).stableRepresentation
    }

    private func destinationURL(for key: CacheLookupKey) throws -> URL {
        try validateKey(key)
        let sourceDirectory = cacheRoot.appendingPathComponent(
            Self.sha256(key.sourceData),
            isDirectory: true
        )
        try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        return sourceDirectory.appendingPathComponent(Self.stableFilename(for: key), isDirectory: false)
    }

    private func writeEnvelopeAtomicallyLocked(
        encoded: Data,
        to destination: URL
    ) throws {
        do {
            // Foundation's atomic destination write performs the temporary
            // replace internally.  Critically, a failed write leaves the
            // existing destination untouched; never remove it first.
            try encoded.write(to: destination, options: [.atomic])
            _ = try Data(contentsOf: destination)
        } catch {
            throw StoreError.ioFailure
        }
    }

    private func readEnvelopeLocked(
        key: CacheLookupKey,
        token: CachePermitToken?,
        now: Date,
        enforceTTL: Bool
    ) -> CacheEnvelope? {
        guard let destination = try? destinationURL(for: key),
              fileManager.fileExists(atPath: destination.path),
              let values = try? destination.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize,
              fileSize <= config.maxEntryBytes,
              let data = try? Data(contentsOf: destination),
              data.count <= config.maxEntryBytes,
              var envelope = try? decodeAndValidateEnvelope(
                  data,
                  for: key,
                  now: now,
                  enforceTTL: enforceTTL
              ) else {
            return nil
        }

        if let token {
            guard token == envelope.permit else { return nil }
        }

        // Access timestamp is metadata only.  A failure to update it must not
        // turn a valid last-good hit into a miss.
        envelope.lastAccessAt = now
        if let encoded = try? Self.makeEncoder().encode(envelope) {
            try? writeEnvelopeAtomicallyLocked(encoded: encoded, to: destination)
        }
        return envelope
    }

    private func decodeAndValidateEnvelope(
        _ data: Data,
        for key: CacheLookupKey,
        now: Date,
        enforceTTL: Bool
    ) throws -> CacheEnvelope {
        guard data.count <= config.maxEntryBytes else { throw StoreError.entryTooLarge }
        let envelope: CacheEnvelope
        do {
            envelope = try Self.makeDecoder().decode(CacheEnvelope.self, from: data)
        } catch {
            throw StoreError.malformedEnvelope
        }
        guard envelope.schemaVersion == Self.schemaVersion,
              envelope.lookupKey == key,
              (try? validatePermit(envelope.permit, for: key)) != nil,
              envelope.writeNonce == envelope.permit.permitNonce,
              !envelope.checksum.isEmpty,
              !envelope.payload.isEmpty,
              envelope.payload.count <= config.maxSnapshotBytes,
              envelope.capturedAt <= envelope.expiresAt,
              envelope.lastAccessAt <= now,
              envelope.provenance == makeProvenance(
                  key: key,
                  permit: envelope.permit
              ),
              Self.sha256(envelope.payload) == envelope.checksum else {
            throw StoreError.checksumMismatch
        }
        guard !enforceTTL || now >= envelope.capturedAt else {
            throw StoreError.futureTimestamp
        }
        guard !enforceTTL || now <= envelope.expiresAt else {
            throw StoreError.expired
        }
        return envelope
    }

    private struct Entry {
        let url: URL
        let envelope: CacheEnvelope
        let size: Int
    }

    private struct SourceGroup: Hashable {
        let sourceKind: Int
        let canonicalID: String
        let exactURL: String
    }

    private struct NodeGroup: Hashable {
        let source: SourceGroup
        let nodeID: String
    }

    private func entriesLocked() -> [Entry] {
        guard let sourceDirectories = try? fileManager.contentsOfDirectory(
            at: cacheRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        var result: [Entry] = []
        for directory in sourceDirectories {
            guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey]),
                  values.isDirectory == true,
                  let files = try? fileManager.contentsOfDirectory(
                      at: directory,
                      includingPropertiesForKeys: [.fileSizeKey]
                  ) else { continue }
            for url in files where url.pathExtension == "json" {
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                      let fileSize = values.fileSize,
                      fileSize <= config.maxEntryBytes,
                      let data = try? Data(contentsOf: url),
                      data.count <= config.maxEntryBytes,
                      let envelope = try? Self.makeDecoder().decode(CacheEnvelope.self, from: data),
                      (try? validateKey(envelope.lookupKey)) != nil,
                      (try? validatePermit(envelope.permit, for: envelope.lookupKey)) != nil,
                      envelope.schemaVersion == Self.schemaVersion,
                      envelope.writeNonce == envelope.permit.permitNonce,
                      !envelope.payload.isEmpty,
                      envelope.payload.count <= config.maxSnapshotBytes,
                      Self.sha256(envelope.payload) == envelope.checksum,
                      envelope.provenance == makeProvenance(key: envelope.lookupKey, permit: envelope.permit) else {
                    continue
                }
                result.append(Entry(url: url, envelope: envelope, size: data.count))
            }
        }
        return result
    }

    private func removeEntryLocked(_ entry: Entry) {
        try? fileManager.removeItem(at: entry.url)
    }

    private func enforceLRULocked() throws {
        var entries = entriesLocked()
        guard !entries.isEmpty else { return }

        // First constrain the number of nodes per source.  Grouping uses typed
        // values rather than a delimiter-joined path, so identity strings can
        // contain any Unicode punctuation without changing ownership.
        let bySource = Dictionary(grouping: entries) {
            SourceGroup(
                sourceKind: $0.envelope.sourceKind,
                canonicalID: $0.envelope.canonicalID,
                exactURL: $0.envelope.exactURL
            )
        }
        for sourceEntries in bySource.values {
            var byNode = Dictionary(grouping: sourceEntries) { $0.envelope.nodeID }
            if byNode.count > config.maxNodesPerSource {
                let nodes = byNode.keys.sorted { lhs, rhs in
                    let l = byNode[lhs]?.map { $0.envelope.lastAccessAt }.max() ?? .distantPast
                    let r = byNode[rhs]?.map { $0.envelope.lastAccessAt }.max() ?? .distantPast
                    return l == r ? lhs < rhs : l < r
                }
                for node in nodes.prefix(max(0, byNode.count - config.maxNodesPerSource)) {
                    for entry in byNode.removeValue(forKey: node) ?? [] {
                        removeEntryLocked(entry)
                    }
                }
            }
        }

        entries = entriesLocked()
        // Then constrain pages within each source/node pair.
        let bySourceNode = Dictionary(grouping: entries) {
            NodeGroup(
                source: SourceGroup(
                    sourceKind: $0.envelope.sourceKind,
                    canonicalID: $0.envelope.canonicalID,
                    exactURL: $0.envelope.exactURL
                ),
                nodeID: $0.envelope.nodeID
            )
        }
        for nodeEntries in bySourceNode.values where nodeEntries.count > config.maxPagesPerNode {
            let ordered = nodeEntries.sorted {
                $0.envelope.lastAccessAt == $1.envelope.lastAccessAt
                    ? $0.url.path < $1.url.path
                    : $0.envelope.lastAccessAt < $1.envelope.lastAccessAt
            }
            for entry in ordered.prefix(nodeEntries.count - config.maxPagesPerNode) {
                removeEntryLocked(entry)
            }
        }

        entries = entriesLocked()
        var totalBytes = entries.reduce(0) { $0 + $1.size }
        let ordered = entries.sorted {
            $0.envelope.lastAccessAt == $1.envelope.lastAccessAt
                ? $0.url.path < $1.url.path
                : $0.envelope.lastAccessAt < $1.envelope.lastAccessAt
        }
        for entry in ordered {
            guard entries.count > config.maxEntries || totalBytes > config.totalBudgetBytes else {
                break
            }
            removeEntryLocked(entry)
            entries.removeAll { $0.url == entry.url }
            totalBytes -= entry.size
        }
    }
}
