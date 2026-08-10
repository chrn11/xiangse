import Foundation
import XCTest
@testable import LegadoBridge

final class PublishPermitTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SourceSessionCoordinator.shared.resetForTests()
    }

    func testPublishPermitRequiresSelectionGeneration() {
        let c = SourceSessionCoordinator.shared
        let sel = SelectionToken(sourceKind: .legado, canonicalID: "https://a")
        _ = c.applySelection(sel)
        _ = c.bindTestLegadoPublishIdentity(exactSourceUrl: "https://a")
        let token = c.currentToken(sourceKind: .legado, canonicalID: "https://a")!
        _ = c.apply(.reselectSameDiscoverSource(sel))
        let stale = c.requestPublishPermit(for: token, isFirstPage: true)
        guard case .failure(let reason) = stale else {
            return XCTFail("expected selectionGeneration mismatch")
        }
        XCTAssertEqual(reason, .selectionGenerationMismatch)
    }

    func testPublishPermitRequiresManagerOrRegistryGeneration() {
        let c = SourceSessionCoordinator.shared
        let sel = SelectionToken(sourceKind: .legado, canonicalID: "https://b")
        var token = c.applySelection(sel)
        _ = c.bindTestLegadoPublishIdentity(exactSourceUrl: "https://b")
        token = c.currentToken(sourceKind: .legado, canonicalID: "https://b")!
        c.bumpRegistryGeneration()
        token.managerOrRegistryGeneration = 0
        let stale = c.requestPublishPermit(for: token, isFirstPage: true)
        guard case .failure(let reason) = stale else {
            return XCTFail("expected managerOrRegistryGeneration mismatch")
        }
        XCTAssertEqual(reason, .managerOrRegistryGenerationMismatch)
    }

    func testPaginationRequiresPageAndRequestSequence() {
        let c = SourceSessionCoordinator.shared
        let sel = SelectionToken(sourceKind: .legado, canonicalID: "https://p")
        _ = c.applySelection(sel)
        _ = c.bindTestLegadoPublishIdentity(exactSourceUrl: "https://p")
        var page1 = c.currentToken(sourceKind: .legado, canonicalID: "https://p")!
        XCTAssertNoThrow(try c.requestPublishPermit(for: page1, isFirstPage: true).get())
        _ = c.apply(.loadMore(exactSourceUrl: "https://p", page: 2))
        let cur = c.currentToken(sourceKind: .legado, canonicalID: "https://p")!
        var page3 = cur
        page3.page = 3
        let bad = c.requestPublishPermit(for: page3, isFirstPage: false)
        guard case .failure(let reason) = bad else {
            return XCTFail("expected pageNotContiguous")
        }
        XCTAssertEqual(reason, .pageNotContiguous)
    }

    func testDuplicateFirstPageTokenRejectedByRequestSequence() {
        let c = SourceSessionCoordinator.shared
        let sel = SelectionToken(sourceKind: .legado, canonicalID: "https://duplicate")
        _ = c.applySelection(sel)
        _ = c.bindTestLegadoPublishIdentity(exactSourceUrl: "https://duplicate")
        let token = c.currentToken(sourceKind: .legado, canonicalID: "https://duplicate")!

        XCTAssertNoThrow(try c.requestPublishPermit(for: token, isFirstPage: true).get())

        // Replaying the original (sequence 0) token after the first publish
        // must not replace the current first page a second time.
        let replay = c.requestPublishPermit(for: token, isFirstPage: true)
        guard case .failure(let reason) = replay else {
            return XCTFail("replayed first-page token must be rejected")
        }
        XCTAssertEqual(reason, .requestSequenceMismatch)
    }

    func testPublishPermitRejectsMissingSelectedIdentityFields() {
        let c = SourceSessionCoordinator.shared
        let url = "https://identity"
        _ = c.apply(.switchDiscoverSource(exactSourceUrl: url))
        _ = c.bindTestLegadoPublishIdentity(exactSourceUrl: url)
        _ = c.apply(.selectChannelOrNode(
            exactSourceUrl: url,
            snapshotID: "snapshot-a",
            nodeID: "node-a"
        ))

        var missingNode = c.currentToken(exactSourceUrl: url)!
        missingNode.nodeID = nil
        let nodeResult = c.requestPublishPermit(for: missingNode, isFirstPage: true)
        guard case .failure(let nodeReason) = nodeResult else {
            return XCTFail("missing selected node must be rejected")
        }
        XCTAssertEqual(nodeReason, .nodeMismatch)

        var missingSnapshot = c.currentToken(exactSourceUrl: url)!
        missingSnapshot.snapshotID = nil
        let snapshotResult = c.requestPublishPermit(for: missingSnapshot, isFirstPage: true)
        guard case .failure(let snapshotReason) = snapshotResult else {
            return XCTFail("missing selected snapshot must be rejected")
        }
        XCTAssertEqual(snapshotReason, .snapshotMismatch)
    }

    func testPublishPermitRejectsMissingOwnerIdentity() {
        let c = SourceSessionCoordinator.shared
        let sel = SelectionToken(
            sourceKind: .xbs,
            canonicalID: "番茄官网",
            ownerControllerIdentity: "host-A"
        )
        let token = c.applySelection(sel)
        var missingOwner = token
        missingOwner.ownerControllerIdentity = nil
        let result = c.requestPublishPermit(for: missingOwner, isFirstPage: true)
        guard case .failure(let reason) = result else {
            return XCTFail("missing owner identity must be rejected")
        }
        XCTAssertEqual(reason, .ownerMismatch)
    }

    func testCacheHitDoesNotConsumeFirstPageSequence() {
        let c = SourceSessionCoordinator.shared
        let url = "https://cache-first"
        _ = c.apply(.switchDiscoverSource(exactSourceUrl: url))
        _ = c.bindTestLegadoPublishIdentity(exactSourceUrl: url)
        let token = c.currentToken(exactSourceUrl: url)!

        let cache = c.requestCacheHitPermit(for: token)
        XCTAssertNoThrow(try cache.get())
        XCTAssertEqual(c.currentToken(exactSourceUrl: url)?.requestSequence, 0)

        let network = c.apply(.manualRefreshFirstPage(exactSourceUrl: url))
        XCTAssertNoThrow(try c.requestPublishPermit(for: network, isFirstPage: true).get())
    }

    func testStaleCacheHitRejectedAfterRefreshGenerationBump() {
        let c = SourceSessionCoordinator.shared
        let url = "https://cache-stale"
        _ = c.apply(.switchDiscoverSource(exactSourceUrl: url))
        _ = c.bindTestLegadoPublishIdentity(exactSourceUrl: url)
        let stale = c.currentToken(exactSourceUrl: url)!
        _ = c.apply(.manualRefreshFirstPage(exactSourceUrl: url))

        let result = c.requestCacheHitPermit(for: stale)
        guard case .failure(let reason) = result else {
            return XCTFail("cache from an older content generation must be rejected")
        }
        XCTAssertEqual(reason, .contentGenerationMismatch)
    }

    func testLegadoExplorePageRequiresExactSelectedSession() {
        let c = SourceSessionCoordinator.shared
        let url = "https://selected"
        XCTAssertNil(c.prepareLegadoExplorePageIfSelected(exactSourceUrl: url, page: 1))
        _ = c.applySelection(SelectionToken(sourceKind: .xbs, canonicalID: url))
        XCTAssertNil(c.prepareLegadoExplorePageIfSelected(exactSourceUrl: url, page: 1))

        let selected = c.applySelection(SelectionToken(sourceKind: .legado, canonicalID: url))
        let refreshed = c.prepareLegadoExplorePageIfSelected(exactSourceUrl: url, page: 1)
        XCTAssertEqual(refreshed?.sourceKind, .legado)
        XCTAssertEqual(refreshed?.exactSourceUrl, url)
        XCTAssertEqual(refreshed?.contentGeneration, selected.contentGeneration + 1)
        XCTAssertEqual(c.prepareLegadoExplorePageIfSelected(exactSourceUrl: url, page: 2)?.contentGeneration,
                       refreshed?.contentGeneration)
    }

    func testBindActiveLegadoContextRequiresSelectionAndBumpsChangedIdentity() {
        let c = SourceSessionCoordinator.shared
        let url = "https://bound"
        XCTAssertNil(c.bindActiveLegadoContext(
            exactSourceUrl: url, ownerControllerIdentity: "BookListCon:1",
            definitionFingerprint: "fp", snapshotID: "snap", nodeID: "node", runtimeEpoch: 1
        ))
        let selected = c.applySelection(SelectionToken(sourceKind: .legado, canonicalID: url))
        let bound = c.bindActiveLegadoContext(
            exactSourceUrl: url, ownerControllerIdentity: "BookListCon:1",
            definitionFingerprint: "fp", snapshotID: "snap", nodeID: "node", runtimeEpoch: 1
        )!
        XCTAssertGreaterThan(bound.uiGeneration, selected.uiGeneration)
        XCTAssertGreaterThan(bound.definitionGeneration, selected.definitionGeneration)
        let same = c.bindActiveLegadoContext(
            exactSourceUrl: url, ownerControllerIdentity: "BookListCon:1",
            definitionFingerprint: "fp", snapshotID: "snap", nodeID: "node", runtimeEpoch: 1
        )!
        XCTAssertEqual(same.uiGeneration, bound.uiGeneration)
        XCTAssertEqual(same.definitionGeneration, bound.definitionGeneration)
        XCTAssertEqual(same.contentGeneration, bound.contentGeneration)
        let changedOwner = c.bindActiveLegadoContext(
            exactSourceUrl: url, ownerControllerIdentity: "BookListCon:2",
            definitionFingerprint: "fp", snapshotID: "snap", nodeID: "node", runtimeEpoch: 1
        )!
        XCTAssertEqual(changedOwner.uiGeneration, same.uiGeneration + 1)
        XCTAssertGreaterThan(changedOwner.contentGeneration, same.contentGeneration)
    }

    func testLegadoNormalPublishRequiresFullIdentityAtCoordinator() {
        let c = SourceSessionCoordinator.shared
        let url = "https://legado-identity-gate"
        let sel = c.applySelection(SelectionToken(sourceKind: .legado, canonicalID: url))
        let unbound = c.requestPublishPermit(for: sel, isFirstPage: true)
        guard case .failure(let reason) = unbound else {
            return XCTFail("unbound legado token must fail at coordinator boundary")
        }
        XCTAssertEqual(reason, .ownerMismatch)
        let bound = c.bindTestLegadoPublishIdentity(exactSourceUrl: url)!
        XCTAssertNoThrow(try c.requestPublishPermit(for: bound, isFirstPage: true).get())
    }

    func testSharedRouterRejectsMalformedTokenWithoutThrowing() {
        let malformed: NSDictionary = [
            "sourceKind": NSNull(), "canonicalID": "https://malformed",
            "exactSourceUrl": "https://malformed"
        ]
        XCTAssertNoThrow({
            let result = LBSharedSourceRouter.shared.requestPublishPermit(token: malformed, isFirstPage: true)
            XCTAssertEqual(result["ok"] as? Bool, false)
        }())
    }
}
