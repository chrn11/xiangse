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
        // 同 URL：switch 后再 manualRefresh 抬升 contentGeneration，旧 token 应被拒
        let t1 = c.apply(.switchDiscoverSource(exactSourceUrl: "https://x"))
        _ = c.bindTestLegadoPublishIdentity(exactSourceUrl: "https://x")
        let staleToken = c.currentToken(exactSourceUrl: "https://x")!
        _ = c.apply(.manualRefreshFirstPage(exactSourceUrl: "https://x"))
        let stale = c.requestPublishPermit(for: staleToken, isFirstPage: true)
        guard case .failure(let r2) = stale else {
            return XCTFail("expected content mismatch, got \(stale)")
        }
        XCTAssertEqual(r2, .contentGenerationMismatch)
    }

    func testPaginationContiguous() {
        let c = SourceSessionCoordinator.shared
        _ = c.apply(.switchDiscoverSource(exactSourceUrl: "https://p"))
        _ = c.bindTestLegadoPublishIdentity(exactSourceUrl: "https://p")
        let page1 = c.currentToken(exactSourceUrl: "https://p")!
        XCTAssertNotNil(try? c.requestPublishPermit(for: page1, isFirstPage: true).get())
        _ = c.apply(.loadMore(exactSourceUrl: "https://p", page: 2))
        let cur = c.currentToken(exactSourceUrl: "https://p")!
        var req = cur
        req.page = 2
        // 0 = 由 coordinator 分配下一 requestSequence（勿复用首页已授予序号）
        req.requestSequence = 0
        let ok = c.requestPublishPermit(for: req, isFirstPage: false)
        XCTAssertNoThrow(try ok.get())
        var p4 = req
        p4.page = 4
        p4.requestSequence = 0
        let bad = c.requestPublishPermit(for: p4, isFirstPage: false)
        guard case .failure(let reason) = bad else {
            return XCTFail("expected pageNotContiguous")
        }
        XCTAssertEqual(reason, .pageNotContiguous)
    }

    func testDualLaneSessionKeyIsolation() {
        let c = SourceSessionCoordinator.shared
        let xbs = SelectionToken(sourceKind: .xbs, canonicalID: "番茄官网")
        let leg = SelectionToken(sourceKind: .legado, canonicalID: "https://legado.example/a")
        let tx = c.applySelection(xbs)
        let tl = c.applySelection(leg)
        XCTAssertEqual(tx.sourceKind, .xbs)
        XCTAssertEqual(tl.sourceKind, .legado)
        XCTAssertNotEqual(tx.sessionKey, tl.sessionKey)
        XCTAssertEqual(tx.canonicalID, "番茄官网")
        XCTAssertEqual(tl.canonicalID, "https://legado.example/a")
    }

    func testCapturedPublishContextRejectedAfterRouteSwitch() {
        let c = SourceSessionCoordinator.shared
        let urlA = "https://capture-a"
        let urlB = "https://capture-b"
        _ = c.applySelection(SelectionToken(sourceKind: .legado, canonicalID: urlA))
        _ = c.bindTestLegadoPublishIdentity(exactSourceUrl: urlA)
        let captured = c.currentToken(exactSourceUrl: urlA)!
        XCTAssertTrue(c.isStillActiveLegadoPublishContext(captured))
        _ = c.applySelection(SelectionToken(sourceKind: .legado, canonicalID: urlB))
        XCTAssertFalse(c.isStillActiveLegadoPublishContext(captured))
    }

    func testAtoAReselectBumpsSelectionOnly() {
        let c = SourceSessionCoordinator.shared
        let sel = SelectionToken(sourceKind: .xbs, canonicalID: "番茄官网")
        let t1 = c.applySelection(sel)
        let t2 = c.applySelection(sel, isReselect: true)
        XCTAssertEqual(t2.uiGeneration, t1.uiGeneration)
        XCTAssertEqual(t2.contentGeneration, t1.contentGeneration)
        XCTAssertEqual(t2.selectionGeneration, t1.selectionGeneration + 1)
        let stale = c.requestPublishPermit(for: t1, isFirstPage: true)
        guard case .failure(let reason) = stale else {
            return XCTFail("expected selection mismatch, got \(stale)")
        }
        XCTAssertEqual(reason, .selectionGenerationMismatch)
    }

    func testManagerGenerationInvalidatesXBSPermit() {
        let c = SourceSessionCoordinator.shared
        let sel = SelectionToken(sourceKind: .xbs, canonicalID: "番茄官网")
        let t1 = c.applySelection(sel)
        c.bumpManagerGeneration()
        let stale = c.requestPublishPermit(for: t1, isFirstPage: true)
        guard case .failure(let reason) = stale else {
            return XCTFail("expected manager generation mismatch, got \(stale)")
        }
        XCTAssertEqual(reason, .managerOrRegistryGenerationMismatch)
    }
}
