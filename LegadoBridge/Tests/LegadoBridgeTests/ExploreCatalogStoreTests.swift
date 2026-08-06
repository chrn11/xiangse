import Foundation
import XCTest
@testable import LegadoBridge

final class ExploreCatalogStoreTests: XCTestCase {
    func testWriteReadLastGoodAndChecksum() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("explore-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ExploreCatalogStore(persistenceRoot: root)
        let token = SourceSessionToken(
            exactSourceUrl: "https://s.example",
            uiGeneration: 1,
            definitionGeneration: 1,
            contentGeneration: 1,
            snapshotID: "lbs1_x",
            nodeID: "lbn1_y",
            page: 1
        )
        let payload = Data(#"{"books":[1]}"#.utf8)
        try store.writeLastGood(
            exactSourceUrl: "https://s.example",
            definitionFingerprint: "fp1",
            runtimeContextEpoch: 0,
            snapshotID: "lbs1_x",
            nodeID: "lbn1_y",
            page: 1,
            token: token,
            payload: payload
        )
        let hit = store.readLastGood(
            exactSourceUrl: "https://s.example",
            definitionFingerprint: "fp1",
            runtimeContextEpoch: 0,
            nodeID: "lbn1_y",
            page: 1
        )
        XCTAssertEqual(hit?.payload, payload)
        let miss = store.readLastGood(
            exactSourceUrl: "https://s.example",
            definitionFingerprint: "fp-changed",
            runtimeContextEpoch: 0,
            nodeID: "lbn1_y",
            page: 1
        )
        XCTAssertNil(miss)
    }

    func testRejectOversizedSnapshot() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("explore-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cfg = ExploreCatalogStore.Config(
            totalBudgetBytes: 1024,
            maxNodesPerSource: 2,
            maxPagesPerNode: 1,
            maxSnapshotBytes: 16
        )
        let store = ExploreCatalogStore(persistenceRoot: root, config: cfg)
        let token = SourceSessionToken(
            exactSourceUrl: "https://s.example",
            uiGeneration: 1,
            definitionGeneration: 1,
            contentGeneration: 1
        )
        XCTAssertThrowsError(
            try store.writeLastGood(
                exactSourceUrl: "https://s.example",
                definitionFingerprint: "fp",
                runtimeContextEpoch: 0,
                snapshotID: "s",
                nodeID: "n",
                page: 1,
                token: token,
                payload: Data(repeating: 1, count: 64)
            )
        ) { err in
            XCTAssertEqual(err as? ExploreCatalogStore.StoreError, .snapshotTooLarge)
        }
    }
}
