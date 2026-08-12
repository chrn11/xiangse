import Foundation
import XCTest
@testable import LegadoBridge

final class ExploreCatalogStoreTests: XCTestCase {
    private let sourceURL = "https://legado.example/source.json"
    private let canonicalID = "https://legado.example/source.json"

    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("explore-store-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeKey(
        sourceKind: Int = ExploreCatalogStore.legadoSourceKind,
        canonicalID: String? = nil,
        exactURL: String? = nil,
        nodeID: String = "node-a",
        page: Int = 1
    ) -> ExploreCatalogStore.CacheKey {
        ExploreCatalogStore.CacheKey(
            sourceKind: sourceKind,
            canonicalID: canonicalID ?? self.canonicalID,
            exactURL: exactURL ?? sourceURL,
            nodeID: nodeID,
            page: page
        )
    }

    private func makeToken(
        sourceKind: SourceKind = .legado,
        canonicalID: String? = nil,
        exactSourceUrl: String? = nil,
        snapshotID: String? = "snapshot-1",
        nodeID: String? = "node-a",
        page: Int = 1,
        registryGeneration: UInt64 = 7,
        runtimeEpoch: UInt64 = 11,
        definitionFingerprint: String? = "definition-1",
        mode: ExplorePublishMode = .cacheFallback,
        permitNonce: String = "permit-1",
        envelopeKeyHash: String = "envelope-key-1",
        requestSequence: UInt64 = 5,
        selectionGeneration: UInt64 = 6,
        uiGeneration: UInt64 = 1,
        definitionGeneration: UInt64 = 2,
        contentGeneration: UInt64 = 3,
        ownerControllerIdentity: String? = "BookListCon:tests"
    ) -> CachePermitToken {
        CachePermitToken(
            mode: mode,
            permitNonce: permitNonce,
            envelopeKeyHash: envelopeKeyHash,
            sourceKind: sourceKind,
            canonicalID: canonicalID ?? self.canonicalID,
            exactSourceUrl: exactSourceUrl ?? sourceURL,
            nodeID: nodeID,
            snapshotID: snapshotID,
            definitionFingerprint: definitionFingerprint,
            page: page,
            requestSequence: requestSequence,
            runtimeEpoch: runtimeEpoch,
            managerOrRegistryGeneration: registryGeneration,
            selectionGeneration: selectionGeneration,
            uiGeneration: uiGeneration,
            definitionGeneration: definitionGeneration,
            contentGeneration: contentGeneration,
            ownerControllerIdentity: ownerControllerIdentity
        )
    }

    func testEnvelopeISO8601CodableSurvivesTwoRounds() throws {
        let key = makeKey()
        let permit = makeToken()
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let payload = Data("payload".utf8)
        let envelope = ExploreCatalogStore.CacheEnvelope(
            lookupKey: key,
            permit: permit,
            provenance: "provenance-v1",
            capturedAt: capturedAt,
            expiresAt: capturedAt.addingTimeInterval(300),
            checksum: ExploreCatalogStore.sha256(payload),
            writeNonce: permit.permitNonce,
            payload: payload
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let firstData = try encoder.encode(envelope)
        let firstEnvelope = try decoder.decode(ExploreCatalogStore.CacheEnvelope.self, from: firstData)
        let secondData = try encoder.encode(firstEnvelope)
        let secondEnvelope = try decoder.decode(ExploreCatalogStore.CacheEnvelope.self, from: secondData)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: secondData) as? [String: Any]
        )

        XCTAssertEqual(secondEnvelope, envelope)
        XCTAssertEqual(envelope.lastAccessAt, capturedAt)
        XCTAssertNotNil(object["capturedAt"] as? String)
        XCTAssertNotNil(object["expiresAt"] as? String)
        XCTAssertNotNil(object["lastAccessAt"] as? String)
    }

    func testTypedEnvelopeAndColdReadUseDifferentIdentityRules() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = ExploreCatalogStore(
            persistenceRoot: root,
            config: .init(
                totalBudgetBytes: 1024 * 1024,
                maxEntries: 8,
                maxNodesPerSource: 4,
                maxPagesPerNode: 2,
                maxSnapshotBytes: 1024,
                ttl: 300
            )
        )
        let key = makeKey()
        let token = makeToken()
        let payload = Data(#"{"books":[1]}"#.utf8)

        let written = try store.writeLastGood(
            key: key,
            token: token,
            payload: payload,
            now: now
        )

        XCTAssertEqual(written.sourceKind, ExploreCatalogStore.legadoSourceKind)
        XCTAssertEqual(written.canonicalID, canonicalID)
        XCTAssertEqual(written.exactURL, sourceURL)
        XCTAssertEqual(written.nodeID, "node-a")
        XCTAssertEqual(written.page, 1)
        XCTAssertEqual(written.snapshotID, "snapshot-1")
        XCTAssertEqual(written.definitionFingerprint, "definition-1")
        XCTAssertEqual(written.registryGeneration, 7)
        XCTAssertEqual(written.runtimeEpoch, 11)
        XCTAssertFalse(written.provenance.isEmpty)
        XCTAssertEqual(written.capturedAt, now)
        XCTAssertEqual(written.expiresAt.timeIntervalSince(written.capturedAt), 300, accuracy: 0.001)
        XCTAssertEqual(written.checksum, ExploreCatalogStore.sha256(payload))
        XCTAssertFalse(written.writeNonce.isEmpty)

        let strictHit = store.readLastGood(key: key, token: token, now: now.addingTimeInterval(1))
        XCTAssertEqual(strictHit?.payload, payload)

        // A new process/runtime cannot use the hot path, but cold start can
        // recover by stable source/node/page identity while the TTL is valid.
        let nextProcessToken = makeToken(registryGeneration: 99, runtimeEpoch: 100)
        XCTAssertNil(store.readLastGood(key: key, token: nextProcessToken, now: now.addingTimeInterval(1)))
        XCTAssertEqual(
            store.readColdLastGood(key: key, now: now.addingTimeInterval(1))?.payload,
            payload
        )
    }

    func testColdReadNeedsFreshCoordinatorPermitBeforePublication() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let key = makeKey()
        let store = ExploreCatalogStore(persistenceRoot: root)
        try store.writeLastGood(
            key: key,
            token: makeToken(),
            payload: Data("payload".utf8),
            now: now
        )
        let coldEnvelope = try XCTUnwrap(store.readColdLastGood(key: key, now: now))
        let coordinator = SourceSessionCoordinator()

        switch coordinator.requestCacheHitPermit(for: coldEnvelope.permit) {
        case .success:
            XCTFail("持久化 permit 不得在新 coordinator 中直接发布")
        case .failure(let reason):
            XCTAssertEqual(reason, .cachePermitMissing)
        }

        _ = coordinator.applySelection(
            SelectionToken(sourceKind: .legado, canonicalID: sourceURL)
        )
        let session = try XCTUnwrap(
            coordinator.bindActiveLegadoContext(
                exactSourceUrl: sourceURL,
                ownerControllerIdentity: "BookListCon:tests",
                definitionFingerprint: "definition-1",
                snapshotID: "snapshot-1",
                nodeID: "node-a",
                runtimeEpoch: 11
            )
        )
        let freshPermit = try coordinator.issueCachePermit(
            for: session,
            mode: .coldLastGood,
            envelopeKeyHash: ExploreCatalogStore.stableFilename(for: key)
        ).get()

        XCTAssertEqual(freshPermit.mode, .coldLastGood)
        XCTAssertNotEqual(freshPermit.permitNonce, coldEnvelope.permit.permitNonce)
    }

    func testHotReadRejectsEveryPermitIdentityDelta() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = ExploreCatalogStore(persistenceRoot: root)
        let key = makeKey()
        let permit = makeToken()
        try store.writeLastGood(
            key: key,
            token: permit,
            payload: Data("payload".utf8),
            now: now
        )
        let deltas: [(String, (inout CachePermitToken) -> Void)] = [
            ("mode", { $0.mode = .coldLastGood }),
            ("permitNonce", { $0.permitNonce = "permit-2" }),
            ("envelopeKeyHash", { $0.envelopeKeyHash = "envelope-key-2" }),
            ("sourceKind", { $0.sourceKind = .xbs }),
            ("canonicalID", { $0.canonicalID = "canonical-2" }),
            ("exactSourceUrl", { $0.exactSourceUrl = "source-2" }),
            ("nodeID", { $0.nodeID = "node-b" }),
            ("snapshotID", { $0.snapshotID = "snapshot-2" }),
            ("definitionFingerprint", { $0.definitionFingerprint = "definition-2" }),
            ("page", { $0.page = 2 }),
            ("requestSequence", { $0.requestSequence += 1 }),
            ("runtimeEpoch", { $0.runtimeEpoch += 1 }),
            ("managerOrRegistryGeneration", { $0.managerOrRegistryGeneration += 1 }),
            ("selectionGeneration", { $0.selectionGeneration += 1 }),
            ("uiGeneration", { $0.uiGeneration += 1 }),
            ("definitionGeneration", { $0.definitionGeneration += 1 }),
            ("contentGeneration", { $0.contentGeneration += 1 }),
            ("ownerControllerIdentity", { $0.ownerControllerIdentity = "BookListCon:other" })
        ]

        for (field, mutate) in deltas {
            var changed = permit
            mutate(&changed)
            XCTAssertNil(
                store.readLastGood(key: key, token: changed, now: now),
                "字段 \(field) 变化后仍命中 hot cache"
            )
        }
        XCTAssertNotNil(store.readLastGood(key: key, token: permit, now: now))
    }

    func testWriteRejectsNonLegadoEmptyAndMismatchedToken() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ExploreCatalogStore(persistenceRoot: root)
        let payload = Data("payload".utf8)

        XCTAssertThrowsError(
            try store.writeLastGood(
                key: makeKey(sourceKind: 1),
                token: makeToken(),
                payload: payload
            )
        ) { XCTAssertEqual($0 as? ExploreCatalogStore.StoreError, .sourceKindMismatch) }

        XCTAssertThrowsError(
            try store.writeLastGood(
                key: makeKey(),
                token: makeToken(sourceKind: .xbs),
                payload: payload
            )
        ) { XCTAssertEqual($0 as? ExploreCatalogStore.StoreError, .sourceKindMismatch) }

        XCTAssertThrowsError(
            try store.writeLastGood(
                key: makeKey(nodeID: "node-a"),
                token: makeToken(nodeID: "node-b"),
                payload: payload
            )
        ) { XCTAssertEqual($0 as? ExploreCatalogStore.StoreError, .tokenIdentityMismatch) }

        XCTAssertThrowsError(
            try store.writeLastGood(
                key: makeKey(),
                token: makeToken(snapshotID: ""),
                payload: payload
            )
        ) { XCTAssertEqual($0 as? ExploreCatalogStore.StoreError, .tokenIdentityMismatch) }

        XCTAssertThrowsError(
            try store.writeLastGood(
                key: makeKey(),
                token: makeToken(mode: .networkFirst),
                payload: payload
            )
        ) { XCTAssertEqual($0 as? ExploreCatalogStore.StoreError, .cacheModeMismatch) }
    }

    func testColdReadRejectsExpiredFutureCorruptAndMismatchedEntries() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = ExploreCatalogStore(
            persistenceRoot: root,
            config: .init(
                totalBudgetBytes: 1024 * 1024,
                maxEntries: 8,
                maxNodesPerSource: 4,
                maxPagesPerNode: 2,
                maxSnapshotBytes: 1024,
                ttl: 10
            )
        )
        let key = makeKey()
        let token = makeToken()
        try store.writeLastGood(
            key: key,
            token: token,
            payload: Data("payload".utf8),
            now: now
        )

        XCTAssertNil(store.readColdLastGood(key: key, now: now.addingTimeInterval(11)))
        XCTAssertNil(store.readColdLastGood(key: makeKey(nodeID: "other"), now: now))

        let files = try XCTUnwrap(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "json" }
        )
        let cacheURL = try XCTUnwrap(files.first)
        let original = try Data(contentsOf: cacheURL)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: original) as? [String: Any]
        )

        object["checksum"] = String(repeating: "0", count: 64)
        try JSONSerialization.data(withJSONObject: object).write(to: cacheURL)
        XCTAssertNil(store.readColdLastGood(key: key, now: now))

        try original.write(to: cacheURL)
        object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        object["schemaVersion"] = ExploreCatalogStore.schemaVersion - 1
        try JSONSerialization.data(withJSONObject: object).write(to: cacheURL)
        XCTAssertNil(store.readColdLastGood(key: key, now: now))

        try original.write(to: cacheURL)
        object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        object["capturedAt"] = ISO8601DateFormatter().string(from: now.addingTimeInterval(100))
        try JSONSerialization.data(withJSONObject: object).write(to: cacheURL)
        XCTAssertNil(store.readColdLastGood(key: key, now: now))
    }

    func testLengthFramingSeparatesBoundaryCollisionInputs() throws {
        let separator = "\u{1F}"
        let keyA = makeKey(
            canonicalID: "a\(separator)b",
            exactURL: "c"
        )
        let keyB = makeKey(
            canonicalID: "a",
            exactURL: "b\(separator)c"
        )
        XCTAssertNotEqual(keyA.stableKey, keyB.stableKey)
        XCTAssertNotEqual(
            ExploreCatalogStore.stableFilename(for: keyA),
            ExploreCatalogStore.stableFilename(for: keyB)
        )

        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ExploreCatalogStore(persistenceRoot: root)
        try store.writeLastGood(
            key: keyA,
            token: makeToken(
                canonicalID: keyA.canonicalID,
                exactSourceUrl: keyA.exactURL
            ),
            payload: Data("a".utf8)
        )
        try store.writeLastGood(
            key: keyB,
            token: makeToken(
                canonicalID: keyB.canonicalID,
                exactSourceUrl: keyB.exactURL
            ),
            payload: Data("b".utf8)
        )
        let files = try XCTUnwrap(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "json" }
        )
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(
            Set(files.map { $0.deletingLastPathComponent().lastPathComponent }).count,
            2
        )
    }

    func testReadRejectsOversizedFileAndDecodedPayload() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = ExploreCatalogStore(
            persistenceRoot: root,
            config: .init(
                totalBudgetBytes: 1024 * 1024,
                maxEntries: 8,
                maxNodesPerSource: 4,
                maxPagesPerNode: 2,
                maxSnapshotBytes: 8,
                maxEntryBytes: 4096,
                ttl: 300
            )
        )
        let key = makeKey()
        try store.writeLastGood(
            key: key,
            token: makeToken(),
            payload: Data("12345678".utf8),
            now: now
        )
        let files = try XCTUnwrap(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "json" }
        )
        let cacheURL = try XCTUnwrap(files.first)
        let original = try Data(contentsOf: cacheURL)

        try Data(repeating: 0, count: 4097).write(to: cacheURL, options: .atomic)
        XCTAssertNil(store.readColdLastGood(key: key, now: now))

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: original) as? [String: Any]
        )
        let oversizedPayload = Data("123456789".utf8)
        object["payload"] = oversizedPayload.base64EncodedString()
        object["checksum"] = ExploreCatalogStore.sha256(oversizedPayload)
        try JSONSerialization.data(withJSONObject: object).write(to: cacheURL, options: .atomic)
        XCTAssertNil(store.readColdLastGood(key: key, now: now))
    }

    func testStableFilenameAndAtomicReplacement() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ExploreCatalogStore(persistenceRoot: root)
        let key = makeKey()
        let token = makeToken()

        try store.writeLastGood(
            key: key,
            token: token,
            payload: Data("one".utf8)
        )
        try store.writeLastGood(
            key: key,
            token: token,
            payload: Data("two".utf8)
        )

        let files = try XCTUnwrap(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "json" }
        )
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].lastPathComponent.hasSuffix(".json"))
        XCTAssertFalse(files[0].lastPathComponent.contains("-1"))
        XCTAssertFalse(files.contains { $0.pathExtension == "tmp" })
        XCTAssertEqual(store.readColdLastGood(key: key)?.payload, Data("two".utf8))
    }

    func testLRUEnforcesNodeAndPageLimits() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = ExploreCatalogStore(
            persistenceRoot: root,
            config: .init(
                totalBudgetBytes: 1_000_000,
                maxEntries: 3,
                maxNodesPerSource: 1,
                maxPagesPerNode: 1,
                maxSnapshotBytes: 1024,
                ttl: 1000
            )
        )

        func write(node: String, page: Int, offset: TimeInterval) throws {
            let key = makeKey(nodeID: node, page: page)
            let token = makeToken(nodeID: node, page: page)
            try store.writeLastGood(
                key: key,
                token: token,
                payload: Data("\(node)-\(page)".utf8),
                now: now.addingTimeInterval(offset)
            )
        }

        try write(node: "node-a", page: 1, offset: 1)
        try write(node: "node-a", page: 2, offset: 2)
        XCTAssertNil(store.readColdLastGood(key: makeKey(nodeID: "node-a", page: 1), now: now.addingTimeInterval(3)))
        XCTAssertNotNil(store.readColdLastGood(key: makeKey(nodeID: "node-a", page: 2), now: now.addingTimeInterval(3)))

        try write(node: "node-b", page: 1, offset: 3)
        XCTAssertNil(store.readColdLastGood(key: makeKey(nodeID: "node-a", page: 2), now: now.addingTimeInterval(4)))
        XCTAssertNotNil(store.readColdLastGood(key: makeKey(nodeID: "node-b", page: 1), now: now.addingTimeInterval(4)))
    }

    func testLRUEnforcesTotalByteBudget() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let roomyStore = ExploreCatalogStore(
            persistenceRoot: root,
            config: .init(
                totalBudgetBytes: 1024 * 1024,
                maxEntries: 8,
                maxNodesPerSource: 4,
                maxPagesPerNode: 2,
                maxSnapshotBytes: 1024,
                ttl: 300
            )
        )
        let firstKey = makeKey(nodeID: "node-a")
        try roomyStore.writeLastGood(
            key: firstKey,
            token: makeToken(nodeID: firstKey.nodeID, permitNonce: "permit-a"),
            payload: Data(repeating: 1, count: 512),
            now: now
        )
        let firstFile = try XCTUnwrap(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])?
                .compactMap { $0 as? URL }
                .first { $0.pathExtension == "json" }
        )
        let firstSize = try XCTUnwrap(
            firstFile.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )
        let constrainedStore = ExploreCatalogStore(
            persistenceRoot: root,
            config: .init(
                totalBudgetBytes: firstSize + 1,
                maxEntries: 8,
                maxNodesPerSource: 4,
                maxPagesPerNode: 2,
                maxSnapshotBytes: 1024,
                ttl: 300
            )
        )
        let secondKey = makeKey(nodeID: "node-b")
        try constrainedStore.writeLastGood(
            key: secondKey,
            token: makeToken(nodeID: secondKey.nodeID, permitNonce: "permit-b"),
            payload: Data(repeating: 2, count: 512),
            now: now.addingTimeInterval(1)
        )

        XCTAssertNil(constrainedStore.readColdLastGood(key: firstKey, now: now.addingTimeInterval(2)))
        XCTAssertNotNil(constrainedStore.readColdLastGood(key: secondKey, now: now.addingTimeInterval(2)))
    }

    func testStoresSharingRootSerializeConcurrentAccess() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = ExploreCatalogStore.Config(
            totalBudgetBytes: 8 * 1024 * 1024,
            maxEntries: 32,
            maxNodesPerSource: 32,
            maxPagesPerNode: 1,
            maxSnapshotBytes: 1024,
            ttl: 300
        )
        let stores = [
            ExploreCatalogStore(persistenceRoot: root, config: config),
            ExploreCatalogStore(persistenceRoot: root, config: config)
        ]
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let keys = (0..<16).map { makeKey(nodeID: "node-\($0)") }
        let permits = keys.enumerated().map {
            makeToken(
                nodeID: $0.element.nodeID,
                permitNonce: "permit-\($0.offset)"
            )
        }
        let failures = LockedFailures()

        DispatchQueue.concurrentPerform(iterations: keys.count) { index in
            do {
                try stores[index % stores.count].writeLastGood(
                    key: keys[index],
                    token: permits[index],
                    payload: Data("payload-\(index)".utf8),
                    now: now.addingTimeInterval(TimeInterval(index))
                )
            } catch {
                failures.append(error)
            }
        }

        XCTAssertTrue(failures.messages.isEmpty, failures.messages.joined(separator: "\n"))
        for (index, key) in keys.enumerated() {
            XCTAssertEqual(
                stores[0].readColdLastGood(
                    key: key,
                    now: now.addingTimeInterval(TimeInterval(keys.count))
                )?.payload,
                Data("payload-\(index)".utf8)
            )
        }
    }
}

private final class LockedFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(String(describing: error))
    }

    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
