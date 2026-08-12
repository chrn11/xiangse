import Foundation
import XCTest
@testable import LegadoBridge

/// Swift Core phase A: network-first-page persist under a pre-issued typed
/// cache permit, plus cold read that cannot reuse the embedded nonce.
final class ExploreCatalogCorePersistTests: XCTestCase {
    private var tempRoot: URL!
    private var core: LegadoBridgeCore!

    override func setUp() {
        super.setUp()
        SourceSessionCoordinator.shared.resetForTests()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("explore-core-persist-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        core = LegadoBridgeCore.shared
        core.exploreCatalogStore = ExploreCatalogStore(persistenceRoot: tempRoot)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        SourceSessionCoordinator.shared.resetForTests()
        super.tearDown()
    }

    private func bindSession(url: String) -> SourceSessionToken {
        let c = SourceSessionCoordinator.shared
        _ = c.applySelection(SelectionToken(sourceKind: .legado, canonicalID: url))
        guard let bound = c.bindTestLegadoPublishIdentity(exactSourceUrl: url) else {
            preconditionFailure("bind failed")
        }
        return bound
    }

    func testPersistAfterPreIssuedPermitAndColdReadRejectsStaleNonce() throws {
        let session = bindSession(url: "https://core-persist-a")
        let permit = try XCTUnwrap(core.issueExploreCatalogPersistPermit(for: session))
        XCTAssertEqual(permit.mode, .cacheFallback)
        XCTAssertEqual(SourceSessionCoordinator.shared.cachePermitStateCountForTests(), 1)

        let books: [[String: Any]] = [
            ["name": "书A", "bookUrl": "https://core-persist-a/book/1"],
            ["name": "书B", "bookUrl": "https://core-persist-a/book/2"],
        ]
        // Admit the network first page so the live cache slot is revoked the
        // same way production does after WithCapturedToken publish.
        XCTAssertNoThrow(
            try SourceSessionCoordinator.shared
                .requestPublishPermit(for: session, isFirstPage: true)
                .get()
        )
        XCTAssertEqual(SourceSessionCoordinator.shared.cachePermitStateCountForTests(), 0)

        XCTAssertTrue(
            core.persistExploreCatalogLastGood(
                session: session,
                books: books,
                permit: permit
            )
        )

        let cold = try XCTUnwrap(core.readExploreCatalogColdLastGood(for: session))
        XCTAssertEqual(cold.permit.permitNonce, permit.permitNonce)
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: cold.payload) as? [[String: Any]]
        )
        XCTAssertEqual(decoded.count, 2)

        // Embedded nonce is not a live publication authorization.
        XCTAssertEqual(
            SourceSessionCoordinator.shared.requestCacheHitPermit(for: cold.permit),
            .failure(.cachePermitMissing)
        )

        let key = try XCTUnwrap(core.exploreCatalogLookupKey(for: session))
        let current = try XCTUnwrap(
            SourceSessionCoordinator.shared.currentToken(exactSourceUrl: session.exactSourceUrl)
        )
        // Network first page already admitted: no fresh cache permit until a
        // selection/refresh resets the session.
        XCTAssertEqual(
            SourceSessionCoordinator.shared.issueCachePermit(
                for: current,
                mode: .coldLastGood,
                envelopeKeyHash: ExploreCatalogStore.stableFilename(for: key)
            ),
            .failure(.cacheNetworkAlreadyAccepted)
        )
    }

    func testNetworkAcceptedSessionCannotMintPersistPermit() {
        let session = bindSession(url: "https://core-persist-b")
        XCTAssertNoThrow(
            try SourceSessionCoordinator.shared
                .requestPublishPermit(for: session, isFirstPage: true)
                .get()
        )
        XCTAssertNil(core.issueExploreCatalogPersistPermit(
            for: SourceSessionCoordinator.shared.currentToken(exactSourceUrl: session.exactSourceUrl)!
        ))
    }

    func testEmptyBooksDoNotPersist() {
        let session = bindSession(url: "https://core-persist-c")
        let permit = core.issueExploreCatalogPersistPermit(for: session)!
        XCTAssertFalse(
            core.persistExploreCatalogLastGood(
                session: session,
                books: [],
                permit: permit
            )
        )
        XCTAssertNil(core.readExploreCatalogColdLastGood(for: session))
    }
}
