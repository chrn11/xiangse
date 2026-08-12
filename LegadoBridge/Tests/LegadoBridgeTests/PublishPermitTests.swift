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

    func testTypedCachePermitDoesNotConsumeFirstPageSequence() {
        let c = SourceSessionCoordinator.shared
        let url = "https://cache-first"
        _ = c.apply(.switchDiscoverSource(exactSourceUrl: url))
        _ = c.bindTestLegadoPublishIdentity(exactSourceUrl: url)
        let token = c.currentToken(exactSourceUrl: url)!

        let issued = try! c.issueCachePermit(
            for: token,
            mode: .coldLastGood,
            envelopeKeyHash: "env-cache-first"
        ).get()
        XCTAssertEqual(issued.sourceKind, .legado)
        XCTAssertEqual(issued.exactSourceUrl, url)
        let cache = c.requestCacheHitPermit(for: issued, mode: .coldLastGood)
        XCTAssertNoThrow(try cache.get())
        XCTAssertEqual(c.currentToken(exactSourceUrl: url)?.requestSequence, 0)

        let network = c.apply(.manualRefreshFirstPage(exactSourceUrl: url))
        XCTAssertNoThrow(try c.requestPublishPermit(for: network, isFirstPage: true).get())
    }

    func testTypedCachePermitReplayRejectedAndNetworkPageCannotBeOverwritten() {
        let c = SourceSessionCoordinator.shared
        let url = "https://cache-stale"
        _ = c.apply(.switchDiscoverSource(exactSourceUrl: url))
        _ = c.bindTestLegadoPublishIdentity(exactSourceUrl: url)
        let session = c.currentToken(exactSourceUrl: url)!
        let consumed = try! c.issueCachePermit(
            for: session,
            mode: .coldLastGood,
            envelopeKeyHash: "env-cache-consumed"
        ).get()
        XCTAssertNoThrow(try c.requestCacheHitPermit(for: consumed, mode: .coldLastGood).get())
        guard case .failure(let replayReason) = c.requestCacheHitPermit(for: consumed, mode: .coldLastGood) else {
            return XCTFail("a cache permit nonce must be one-shot")
        }
        XCTAssertEqual(replayReason, .cachePermitMissing)

        let stale = try! c.issueCachePermit(
            for: c.currentToken(exactSourceUrl: url)!,
            mode: .cacheFallback,
            envelopeKeyHash: "env-cache-stale"
        ).get()

        let network = c.currentToken(exactSourceUrl: url)!
        XCTAssertEqual(c.cachePermitStateCountForTests(), 1)
        XCTAssertNoThrow(try c.requestPublishPermit(for: network, isFirstPage: true).get())
        XCTAssertEqual(c.cachePermitStateCountForTests(), 0)

        let result = c.requestCacheHitPermit(for: stale, mode: .cacheFallback)
        guard case .failure(let reason) = result else {
            return XCTFail("cache fallback must not overwrite an accepted network first page")
        }
        // The accepted network page revoked the nonce, so the stale envelope is
        // reported exactly like an unknown one rather than leaking which
        // identity field drifted.
        XCTAssertEqual(reason, .cachePermitMissing)
    }

    func testNetworkFirstPageAdmissionRevokesOutstandingCachePermit() {
        let c = SourceSessionCoordinator.shared
        let url = "https://cache-revoked-by-network"
        _ = c.applySelection(SelectionToken(sourceKind: .legado, canonicalID: url))
        _ = c.bindTestLegadoPublishIdentity(exactSourceUrl: url)
        let session = c.currentToken(exactSourceUrl: url)!
        let permit = try! c.issueCachePermit(
            for: session,
            mode: .cacheFallback,
            envelopeKeyHash: "env-revoked-by-network"
        ).get()
        XCTAssertEqual(c.cachePermitStateCountForTests(), 1)

        // A rejected publish must not revoke a permit that is still usable.
        var replayed = session
        replayed.requestSequence = 7
        XCTAssertEqual(
            c.requestPublishPermit(for: replayed, isFirstPage: true),
            .failure(.requestSequenceMismatch)
        )
        XCTAssertEqual(c.cachePermitStateCountForTests(), 1)

        XCTAssertNoThrow(try c.requestPublishPermit(for: session, isFirstPage: true).get())
        XCTAssertEqual(c.cachePermitStateCountForTests(), 0)
        XCTAssertEqual(
            c.requestCacheHitPermit(for: permit, mode: .cacheFallback),
            .failure(.cachePermitMissing)
        )

        // Revocation is not a loophole for re-issuing: once a network page has
        // been accepted, the session cannot mint a fresh cache envelope until a
        // selection/refresh transition resets it.
        XCTAssertEqual(
            c.issueCachePermit(
                for: c.currentToken(exactSourceUrl: url)!,
                mode: .cacheFallback,
                envelopeKeyHash: "env-after-network"
            ),
            .failure(.cacheNetworkAlreadyAccepted)
        )
        XCTAssertEqual(c.cachePermitStateCountForTests(), 0)
    }

    func testTypedCachePermitIsLegadoOnlyAndOrdinaryTokenCannotEnterCache() {
        let c = SourceSessionCoordinator.shared
        let url = "https://cache-typed-only"
        let selected = c.applySelection(SelectionToken(sourceKind: .legado, canonicalID: url))
        _ = c.bindTestLegadoPublishIdentity(exactSourceUrl: url)

        let ordinary = c.requestCacheHitPermit(for: selected)
        guard case .failure(let ordinaryReason) = ordinary else {
            return XCTFail("ordinary SourceSessionToken must never enter cache permit path")
        }
        XCTAssertEqual(ordinaryReason, .routeFailClosed)

        let typed = try! c.issueCachePermit(
            for: c.currentToken(exactSourceUrl: url)!,
            mode: .cacheFallback,
            envelopeKeyHash: "env-typed-only"
        ).get()
        var xbs = typed
        xbs.sourceKind = .xbs
        guard case .failure(let xbsReason) = c.requestCacheHitPermit(for: xbs) else {
            return XCTFail("sourceKind=1 cache token must be rejected")
        }
        XCTAssertEqual(xbsReason, .sourceKindMismatch)
    }

    func testTypedCachePermitRejectsModeNonceAndEnvelopeMismatches() {
        let c = SourceSessionCoordinator.shared
        let url = "https://cache-identity"
        _ = c.apply(.switchDiscoverSource(exactSourceUrl: url))
        _ = c.bindTestLegadoPublishIdentity(exactSourceUrl: url)
        let issued = try! c.issueCachePermit(
            for: c.currentToken(exactSourceUrl: url)!,
            mode: .cacheFallback,
            envelopeKeyHash: "env-identity"
        ).get()

        guard case .failure(let modeReason) = c.requestCacheHitPermit(for: issued, mode: .coldLastGood) else {
            return XCTFail("cache mode mismatch must fail closed")
        }
        XCTAssertEqual(modeReason, .cacheModeMismatch)

        var wrongHash = issued
        wrongHash.envelopeKeyHash = "env-other"
        guard case .failure(let hashReason) = c.requestCacheHitPermit(for: wrongHash, mode: .cacheFallback) else {
            return XCTFail("envelope key mismatch must fail closed")
        }
        XCTAssertEqual(hashReason, .cacheEnvelopeKeyMismatch)

        var wrongNonce = issued
        wrongNonce.permitNonce = "nonce-other"
        guard case .failure(let nonceReason) = c.requestCacheHitPermit(for: wrongNonce, mode: .cacheFallback) else {
            return XCTFail("unknown nonce must fail closed")
        }
        XCTAssertEqual(nonceReason, .cachePermitMissing)
    }

    func testTypedCachePermitRejectsMissingIdentityAndGenerationDrift() {
        let c = SourceSessionCoordinator.shared
        let url = "https://cache-generations"
        _ = c.apply(.switchDiscoverSource(exactSourceUrl: url))
        _ = c.bindTestLegadoPublishIdentity(exactSourceUrl: url)
        let issued = try! c.issueCachePermit(
            for: c.currentToken(exactSourceUrl: url)!,
            mode: .coldLastGood,
            envelopeKeyHash: "env-generations"
        ).get()

        var missingOwner = issued
        missingOwner.ownerControllerIdentity = nil
        guard case .failure(let ownerReason) = c.requestCacheHitPermit(for: missingOwner) else {
            return XCTFail("missing owner identity must be rejected")
        }
        XCTAssertEqual(ownerReason, .ownerMismatch)

        // Re-issue because every cache permit is one-shot even on a successful
        // validation path; the original remains available after rejection.
        let fresh = try! c.issueCachePermit(
            for: c.currentToken(exactSourceUrl: url)!,
            mode: .coldLastGood,
            envelopeKeyHash: "env-generations-2"
        ).get()
        c.bumpRegistryGeneration()
        guard case .failure(let registryReason) = c.requestCacheHitPermit(for: fresh) else {
            return XCTFail("registry generation drift must reject cache token")
        }
        XCTAssertEqual(registryReason, .cachePermitMissing)
        XCTAssertEqual(c.cachePermitStateCountForTests(), 0)

        let rebound = c.apply(.switchDiscoverSource(exactSourceUrl: url))
        _ = c.bindTestLegadoPublishIdentity(exactSourceUrl: url)
        let runtimeIssued = try! c.issueCachePermit(
            for: c.currentToken(exactSourceUrl: url)!,
            mode: .cacheFallback,
            envelopeKeyHash: "env-runtime"
        ).get()
        _ = c.apply(.runtimeContextChanged(exactSourceUrl: url))
        guard case .failure(let runtimeReason) = c.requestCacheHitPermit(for: runtimeIssued) else {
            return XCTFail("runtime invalidation must reject cache token")
        }
        XCTAssertEqual(runtimeReason, .cachePermitMissing)
        XCTAssertGreaterThan(rebound.contentGeneration, 0)
    }

    func testTypedCachePermitRequiresActiveExactLegadoSession() {
        let c = SourceSessionCoordinator.shared
        let urlA = "https://cache-active-a"
        let urlB = "https://cache-active-b"
        _ = c.applySelection(SelectionToken(sourceKind: .legado, canonicalID: urlA))
        _ = c.bindTestLegadoPublishIdentity(exactSourceUrl: urlA)
        let a = c.currentToken(exactSourceUrl: urlA)!

        _ = c.applySelection(SelectionToken(sourceKind: .legado, canonicalID: urlB))
        let inactive = c.issueCachePermit(for: a, mode: .cacheFallback, envelopeKeyHash: "env-inactive")
        guard case .failure(let inactiveReason) = inactive else {
            return XCTFail("cache permit issuance must require active exact Legado session")
        }
        XCTAssertEqual(inactiveReason, .routeFailClosed)

        _ = c.bindTestLegadoPublishIdentity(exactSourceUrl: urlB)
        let issuedBeforeXBS = try! c.issueCachePermit(
            for: c.currentToken(exactSourceUrl: urlB)!,
            mode: .cacheFallback,
            envelopeKeyHash: "env-b"
        ).get()
        let xbs = c.applySelection(SelectionToken(sourceKind: .xbs, canonicalID: "番茄官网"))
        XCTAssertEqual(xbs.sourceKind, .xbs)
        let stale = c.requestCacheHitPermit(for: issuedBeforeXBS)
        XCTAssertEqual(stale, .failure(.cachePermitMissing))
    }

    func testLegadoInvalidationRevokesOldCacheNonceAcrossFreshSelection() {
        let c = SourceSessionCoordinator.shared
        let url = "https://cache-revoked"
        _ = c.applySelection(SelectionToken(sourceKind: .legado, canonicalID: url))
        _ = c.bindTestLegadoPublishIdentity(exactSourceUrl: url)
        let issued = try! c.issueCachePermit(
            for: c.currentToken(exactSourceUrl: url)!,
            mode: .coldLastGood,
            envelopeKeyHash: "env-revoked"
        ).get()

        c.invalidateLegadoSource(exactSourceUrl: url)
        _ = c.applySelection(SelectionToken(sourceKind: .legado, canonicalID: url))
        _ = c.bindTestLegadoPublishIdentity(exactSourceUrl: url)
        guard case .failure(let reason) = c.requestCacheHitPermit(for: issued) else {
            return XCTFail("registry/host invalidation must revoke the old nonce even after re-selection")
        }
        XCTAssertEqual(reason, .cachePermitMissing)
    }

    func testTypedCachePermitRejectsNetworkFirstMode() {
        let c = SourceSessionCoordinator.shared
        let url = "https://cache-network-first"
        _ = c.applySelection(SelectionToken(sourceKind: .legado, canonicalID: url))
        _ = c.bindTestLegadoPublishIdentity(exactSourceUrl: url)
        let result = c.issueCachePermit(
            for: c.currentToken(exactSourceUrl: url)!,
            mode: .networkFirst,
            envelopeKeyHash: "env-network-first"
        )
        XCTAssertEqual(result, .failure(.cacheModeMismatch))
        XCTAssertEqual(c.cachePermitStateCountForTests(), 0)
    }

    func testNewCacheIssuanceRevokesPriorNonceAndModesAreExclusive() {
        let c = SourceSessionCoordinator.shared
        let url = "https://cache-latest-only"
        _ = c.applySelection(SelectionToken(sourceKind: .legado, canonicalID: url))
        _ = c.bindTestLegadoPublishIdentity(exactSourceUrl: url)
        let session = c.currentToken(exactSourceUrl: url)!

        let first = try! c.issueCachePermit(
            for: session,
            mode: .cacheFallback,
            envelopeKeyHash: "env-fallback"
        ).get()
        let second = try! c.issueCachePermit(
            for: session,
            mode: .coldLastGood,
            envelopeKeyHash: "env-cold"
        ).get()

        XCTAssertEqual(c.cachePermitStateCountForTests(), 1)
        XCTAssertEqual(
            c.requestCacheHitPermit(for: first, mode: .cacheFallback),
            .failure(.cachePermitMissing)
        )
        XCTAssertNoThrow(try c.requestCacheHitPermit(for: second, mode: .coldLastGood).get())
        XCTAssertEqual(c.cachePermitStateCountForTests(), 0)
    }

    func testCachePermitStateRemainsBoundedUnderIssuanceStress() {
        let c = SourceSessionCoordinator.shared
        let url = "https://cache-stress"
        _ = c.applySelection(SelectionToken(sourceKind: .legado, canonicalID: url))
        _ = c.bindTestLegadoPublishIdentity(exactSourceUrl: url)
        let session = c.currentToken(exactSourceUrl: url)!

        for index in 0..<1000 {
            _ = try! c.issueCachePermit(
                for: session,
                mode: index.isMultiple(of: 2) ? .cacheFallback : .coldLastGood,
                envelopeKeyHash: "env-stress-\(index)"
            ).get()
            XCTAssertEqual(c.cachePermitStateCountForTests(), 1)
        }
        XCTAssertEqual(c.cachePermitStateCountForTests(), 1)
    }

    func testCachePermitStateClearsAcrossSourceAndRegistryInvalidation() {
        let c = SourceSessionCoordinator.shared
        let urlA = "https://cache-cleanup-a"
        let urlB = "https://cache-cleanup-b"

        _ = c.applySelection(SelectionToken(sourceKind: .legado, canonicalID: urlA))
        _ = c.bindTestLegadoPublishIdentity(exactSourceUrl: urlA)
        _ = try! c.issueCachePermit(
            for: c.currentToken(exactSourceUrl: urlA)!,
            mode: .cacheFallback,
            envelopeKeyHash: "env-cleanup-a"
        ).get()
        XCTAssertEqual(c.cachePermitStateCountForTests(), 1)

        _ = c.applySelection(SelectionToken(sourceKind: .legado, canonicalID: urlB))
        XCTAssertEqual(c.cachePermitStateCountForTests(), 0)
        _ = c.bindTestLegadoPublishIdentity(exactSourceUrl: urlB)
        _ = try! c.issueCachePermit(
            for: c.currentToken(exactSourceUrl: urlB)!,
            mode: .coldLastGood,
            envelopeKeyHash: "env-cleanup-b"
        ).get()
        XCTAssertEqual(c.cachePermitStateCountForTests(), 1)

        c.bumpRegistryGeneration()
        XCTAssertEqual(c.cachePermitStateCountForTests(), 0)
        c.invalidateLegadoSource(exactSourceUrl: urlB)
        XCTAssertEqual(c.cachePermitStateCountForTests(), 0)
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
