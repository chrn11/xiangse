import Foundation
import XCTest
@testable import LegadoBridge

final class SourceSessionCoordinatorTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SourceSessionCoordinator.shared.resetForTests()
    }

    func testSwitchBumpsUIAndContent() {
        let c = SourceSessionCoordinator.shared
        let t1 = c.apply(.switchDiscoverSource(exactSourceUrl: "https://a"))
        XCTAssertEqual(t1.uiGeneration, 1)
        XCTAssertEqual(t1.contentGeneration, 1)
        let t2 = c.apply(.manualRefreshFirstPage(exactSourceUrl: "https://a"))
        XCTAssertEqual(t2.uiGeneration, 1)
        XCTAssertEqual(t2.contentGeneration, 2)
    }

    func testLoadMoreDoesNotBumpContent() {
        let c = SourceSessionCoordinator.shared
        _ = c.apply(.switchDiscoverSource(exactSourceUrl: "https://a"))
        let t = c.apply(.loadMore(exactSourceUrl: "https://a", page: 2))
        XCTAssertEqual(t.contentGeneration, 1)
        XCTAssertEqual(t.page, 2)
    }

    func testStalePublishRejected() {
        let c = SourceSessionCoordinator.shared
        let tA = c.apply(.switchDiscoverSource(exactSourceUrl: "https://a"))
        _ = c.apply(.switchDiscoverSource(exactSourceUrl: "https://b"))
        let r = c.requestPublishPermit(for: tA, isFirstPage: true)
        guard case .failure(let reason) = r else {
            return XCTFail("expected failure")
        }
        // token A still matches session A generations, but after switch to B,
        // session A still exists — switchDiscoverSource on B doesn't invalidate A.
        // Re-test A→B on same url:
        let t1 = c.apply(.switchDiscoverSource(exactSourceUrl: "https://x"))
        _ = c.apply(.manualRefreshFirstPage(exactSourceUrl: "https://x"))
        let stale = c.requestPublishPermit(for: t1, isFirstPage: true)
        guard case .failure(let r2) = stale else {
            return XCTFail("expected content mismatch")
        }
        XCTAssertEqual(r2, .contentGenerationMismatch)
        _ = reason
    }

    func testPaginationContiguous() {
        let c = SourceSessionCoordinator.shared
        var t = c.apply(.switchDiscoverSource(exactSourceUrl: "https://p"))
        t = SourceSessionToken(
            exactSourceUrl: t.exactSourceUrl,
            uiGeneration: t.uiGeneration,
            definitionGeneration: t.definitionGeneration,
            contentGeneration: t.contentGeneration,
            snapshotID: t.snapshotID,
            nodeID: t.nodeID,
            page: 1
        )
        XCTAssertNotNil(try? c.requestPublishPermit(for: t, isFirstPage: true).get())
        var p2 = t
        p2.page = 2
        // need loadMore to set page without bump; permit checks against lastAccepted
        _ = c.apply(.loadMore(exactSourceUrl: "https://p", page: 2))
        let cur = c.currentToken(exactSourceUrl: "https://p")!
        var req = cur
        req.page = 2
        let ok = c.requestPublishPermit(for: req, isFirstPage: false)
        XCTAssertNoThrow(try ok.get())
        var p4 = req
        p4.page = 4
        let bad = c.requestPublishPermit(for: p4, isFirstPage: false)
        guard case .failure(let reason) = bad else {
            return XCTFail("expected pageNotContiguous")
        }
        XCTAssertEqual(reason, .pageNotContiguous)
    }
}
