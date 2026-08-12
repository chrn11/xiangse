import Foundation
import XCTest
@testable import LegadoBridge

/// Swift Core phase B: cold/fallback cache publication uses a fresh typed
/// envelope.  Untyped session dictionaries cannot enter the cache lane.
final class ExploreCatalogCoreCachePublishTests: XCTestCase {
    private var tempRoot: URL!
    private var core: LegadoBridgeCore!

    override func setUp() {
        super.setUp()
        SourceSessionCoordinator.shared.resetForTests()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("explore-core-cache-\(UUID().uuidString)", isDirectory: true)
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

    private func persistBooks(session: SourceSessionToken, names: [String]) {
        guard let permit = core.issueExploreCatalogPersistPermit(for: session) else {
            XCTFail("persist permit missing")
            return
        }
        let books: [[String: Any]] = names.enumerated().map { index, name in
            ["name": name, "bookUrl": "\(session.exactSourceUrl)/book/\(index + 1)"]
        }
        XCTAssertTrue(
            core.persistExploreCatalogLastGood(
                session: session,
                books: books,
                permit: permit
            )
        )
    }

    func testSceneChoosesModeNotTheCaller() {
        XCTAssertEqual(
            LegadoBridgeCore.ExploreCatalogCacheScene.coldStart.mode,
            .coldLastGood
        )
        XCTAssertEqual(
            LegadoBridgeCore.ExploreCatalogCacheScene.networkFallback.mode,
            .cacheFallback
        )
    }

    func testPrepareColdHitIssuesFreshPermitAndKeepsBooks() throws {
        let session = bindSession(url: "https://core-cache-a")
        persistBooks(session: session, names: ["书A", "书B"])

        let prepared = try XCTUnwrap(
            core.prepareExploreCatalogCacheHit(
                session: session,
                scene: .coldStart
            )
        )
        XCTAssertEqual(prepared.permit.mode, .coldLastGood)
        XCTAssertEqual(prepared.books.count, 2)
        XCTAssertEqual(prepared.books[0]["name"] as? String, "书A")
        XCTAssertNotEqual(
            prepared.permit.permitNonce,
            core.readExploreCatalogColdLastGood(for: session)?.permit.permitNonce
        )
    }

    func testTypedCacheEnvelopeRoundTripViaRouter() throws {
        let session = bindSession(url: "https://core-cache-b")
        persistBooks(session: session, names: ["书C"])
        let prepared = try XCTUnwrap(
            core.prepareExploreCatalogCacheHit(
                session: session,
                scene: .networkFallback
            )
        )
        XCTAssertEqual(prepared.permit.mode, .cacheFallback)

        let dict = LBSharedSourceRouter.cachePermitDictionary(prepared.permit) as NSDictionary
        let result = LBSharedSourceRouter.shared.requestCacheHitPublishPermit(token: dict)
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["cacheHit"] as? Bool, true)
        XCTAssertEqual(result["mode"] as? String, "cacheFallback")
        XCTAssertEqual(result["replaceFirstPage"] as? Bool, true)
        XCTAssertEqual(result["appendPage"] as? Bool, false)

        let replay = LBSharedSourceRouter.shared.requestCacheHitPublishPermit(token: dict)
        XCTAssertEqual(replay["ok"] as? Bool, false)
        XCTAssertEqual(replay["reason"] as? String, PublishRejectReason.cachePermitMissing.rawValue)
    }

    func testUntypedSessionDictionaryRejectedByCacheRouter() {
        let session = bindSession(url: "https://core-cache-c")
        let dict = LBSharedSourceRouter.tokenDictionary(session) as NSDictionary
        let result = LBSharedSourceRouter.shared.requestCacheHitPublishPermit(token: dict)
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(result["reason"] as? String, PublishRejectReason.cachePermitRequired.rawValue)
        XCTAssertEqual(result["cacheHit"] as? Bool, true)
    }

    func testNetworkFirstModeCannotMintCacheEnvelope() {
        let session = bindSession(url: "https://core-cache-d")
        var dict = LBSharedSourceRouter.tokenDictionary(session)
        dict["mode"] = ExplorePublishMode.networkFirst.rawValue
        dict["permitNonce"] = "nonce-network"
        dict["envelopeKeyHash"] = "hash-network"
        XCTAssertNil(LBSharedSourceRouter.cachePermit(from: dict as NSDictionary))
    }

    func testNetworkAdmittedSessionCannotPrepareCacheHit() {
        let session = bindSession(url: "https://core-cache-e")
        persistBooks(session: session, names: ["书E"])
        XCTAssertNoThrow(
            try SourceSessionCoordinator.shared
                .requestPublishPermit(for: session, isFirstPage: true)
                .get()
        )
        XCTAssertNil(
            core.prepareExploreCatalogCacheHit(
                session: SourceSessionCoordinator.shared.currentToken(
                    exactSourceUrl: session.exactSourceUrl
                )!,
                scene: .coldStart
            )
        )
    }
}
