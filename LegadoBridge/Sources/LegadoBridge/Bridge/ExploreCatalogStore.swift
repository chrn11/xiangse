import Foundation
import CryptoKit

/// 发现分类 / 书单 last-good 持久化（计划 §24.5）。
public final class ExploreCatalogStore: @unchecked Sendable {
    public struct Config: Equatable, Sendable {
        public var totalBudgetBytes: Int
        public var maxNodesPerSource: Int
        public var maxPagesPerNode: Int
        public var maxSnapshotBytes: Int

        public static let `default` = Config(
            totalBudgetBytes: 64 * 1024 * 1024,
            maxNodesPerSource: 16,
            maxPagesPerNode: 3,
            maxSnapshotBytes: 4 * 1024 * 1024
        )

        public init(
            totalBudgetBytes: Int,
            maxNodesPerSource: Int,
            maxPagesPerNode: Int,
            maxSnapshotBytes: Int
        ) {
            self.totalBudgetBytes = totalBudgetBytes
            self.maxNodesPerSource = maxNodesPerSource
            self.maxPagesPerNode = maxPagesPerNode
            self.maxSnapshotBytes = maxSnapshotBytes
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

    public struct CacheEnvelope: Codable, Equatable, Sendable {
        public var schemaVersion: Int
        public var sourceHash: String
        public var definitionFingerprint: String
        public var runtimeContextEpoch: Int
        public var snapshotID: String
        public var nodeID: String
        public var page: Int
        public var uiGeneration: UInt64
        public var definitionGeneration: UInt64
        public var contentGeneration: UInt64
        public var createdAt: Date
        public var lastSuccessAt: Date
        public var lastAccessAt: Date
        public var payloadSHA256: String
        public var payload: Data
    }

    public struct ExploreStateFile: Codable, Equatable, Sendable {
        public var schemaVersion: Int
        public var lastSourceUrl: String?
        public var perSource: [String: PerSourceState]

        public struct PerSourceState: Codable, Equatable, Sendable {
            public var lastChannelID: String?
            public var lastNodeID: String?
            public var definitionFingerprint: String?
        }
    }

    private let root: URL
    private let config: Config
    private let queue = DispatchQueue(label: "com.xiangse.legado-bridge.explore-catalog-store")
    private let fileManager: FileManager

    public init(persistenceRoot: URL, config: Config = .default, fileManager: FileManager = .default) {
        self.root = persistenceRoot
        self.config = config
        self.fileManager = fileManager
    }

    private var stateURL: URL {
        root.appendingPathComponent("explore-state-v1.json", isDirectory: false)
    }

    private var cacheRoot: URL {
        root.appendingPathComponent("Explore", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }

    public static func sourceHash(exactSourceUrl: String) -> String {
        let digest = SHA256.hash(data: Data(exactSourceUrl.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public func loadState() -> ExploreStateFile {
        queue.sync {
            guard let data = try? Data(contentsOf: stateURL),
                  let decoded = try? JSONDecoder().decode(ExploreStateFile.self, from: data)
            else {
                return ExploreStateFile(schemaVersion: 1, lastSourceUrl: nil, perSource: [:])
            }
            return decoded
        }
    }

    public func saveState(_ state: ExploreStateFile) throws {
        try queue.sync {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            let data = try enc.encode(state)
            let tmp = root.appendingPathComponent("explore-state-v1.\(UUID().uuidString).tmp")
            try data.write(to: tmp, options: .atomic)
            _ = try Data(contentsOf: tmp)
            if fileManager.fileExists(atPath: stateURL.path) {
                try fileManager.removeItem(at: stateURL)
            }
            try fileManager.moveItem(at: tmp, to: stateURL)
        }
    }

    public func writeLastGood(
        exactSourceUrl: String,
        definitionFingerprint: String,
        runtimeContextEpoch: Int,
        snapshotID: String,
        nodeID: String,
        page: Int,
        token: SourceSessionToken,
        payload: Data,
        now: Date = Date()
    ) throws {
        try queue.sync {
            if payload.count > config.maxSnapshotBytes {
                throw StoreError.snapshotTooLarge
            }
            let sh = Self.sourceHash(exactSourceUrl: exactSourceUrl)
            let dir = cacheRoot.appendingPathComponent(sh, isDirectory: true)
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            let payloadSHA = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
            let env = CacheEnvelope(
                schemaVersion: 1,
                sourceHash: sh,
                definitionFingerprint: definitionFingerprint,
                runtimeContextEpoch: runtimeContextEpoch,
                snapshotID: snapshotID,
                nodeID: nodeID,
                page: page,
                uiGeneration: token.uiGeneration,
                definitionGeneration: token.definitionGeneration,
                contentGeneration: token.contentGeneration,
                createdAt: now,
                lastSuccessAt: now,
                lastAccessAt: now,
                payloadSHA256: payloadSHA,
                payload: payload
            )
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            let data = try enc.encode(env)
            let name = "\(nodeID.hashValue)-\(page).json"
            let url = dir.appendingPathComponent(name)
            let tmp = dir.appendingPathComponent("\(UUID().uuidString).tmp")
            try data.write(to: tmp, options: .atomic)
            let readBack = try Data(contentsOf: tmp)
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            let decoded = try dec.decode(CacheEnvelope.self, from: readBack)
            guard decoded.payloadSHA256 == payloadSHA else { throw StoreError.checksumMismatch }
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            try fileManager.moveItem(at: tmp, to: url)
            try enforceLRULocked()
        }
    }

    public func readLastGood(
        exactSourceUrl: String,
        definitionFingerprint: String,
        runtimeContextEpoch: Int,
        nodeID: String,
        page: Int,
        now: Date = Date()
    ) -> CacheEnvelope? {
        queue.sync {
            let sh = Self.sourceHash(exactSourceUrl: exactSourceUrl)
            let dir = cacheRoot.appendingPathComponent(sh, isDirectory: true)
            guard let files = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
                return nil
            }
            for url in files where url.pathExtension == "json" {
                guard let data = try? Data(contentsOf: url),
                      var env = try? {
                          let d = JSONDecoder()
                          d.dateDecodingStrategy = .iso8601
                          return try d.decode(CacheEnvelope.self, from: data)
                      }()
                else { continue }
                let payloadSHA = SHA256.hash(data: env.payload).map { String(format: "%02x", $0) }.joined()
                guard payloadSHA == env.payloadSHA256 else { continue }
                guard env.definitionFingerprint == definitionFingerprint else { continue }
                guard env.runtimeContextEpoch == runtimeContextEpoch else { continue }
                guard env.nodeID == nodeID, env.page == page else { continue }
                env.lastAccessAt = now
                if let encoded = try? JSONEncoder().encode(env) {
                    try? encoded.write(to: url, options: .atomic)
                }
                return env
            }
            return nil
        }
    }

    public enum StoreError: Error, Equatable {
        case snapshotTooLarge
        case checksumMismatch
    }

    private func enforceLRULocked() throws {
        // 粗粒度：超总预算时按 lastAccessAt 删最旧 cache json；不触碰 binding/shelf/registry。
        var entries: [(url: URL, access: Date, size: Int)] = []
        guard let sourceDirs = try? fileManager.contentsOfDirectory(
            at: cacheRoot,
            includingPropertiesForKeys: nil
        ) else { return }
        for dir in sourceDirs {
            guard let files = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else {
                continue
            }
            for url in files where url.pathExtension == "json" {
                guard let data = try? Data(contentsOf: url),
                      let env = try? {
                          let d = JSONDecoder()
                          d.dateDecodingStrategy = .iso8601
                          return try d.decode(CacheEnvelope.self, from: data)
                      }()
                else { continue }
                entries.append((url, env.lastAccessAt, data.count))
            }
        }
        var total = entries.reduce(0) { $0 + $1.size }
        if total <= config.totalBudgetBytes { return }
        entries.sort { $0.access < $1.access }
        for e in entries {
            if total <= config.totalBudgetBytes { break }
            try? fileManager.removeItem(at: e.url)
            total -= e.size
        }
    }
}
