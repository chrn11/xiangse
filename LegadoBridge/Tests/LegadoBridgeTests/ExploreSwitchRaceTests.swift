import Foundation
import XCTest
@testable import LegadoBridge

/// 确定性切源竞赛（无 sleep）：A→B、迟到回包、分页早于首页。
final class ExploreSwitchRaceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SourceSessionCoordinator.shared.resetForTests()
    }

    func testABBAContentIsolation() {
        let c = SourceSessionCoordinator.shared
        let a1 = c.apply(.switchDiscoverSource(exactSourceUrl: "https://a"))
        _ = c.bindTestLegadoPublishIdentity(exactSourceUrl: "https://a")
        let a1Token = c.currentToken(exactSourceUrl: "https://a")!
        let b1 = c.apply(.switchDiscoverSource(exactSourceUrl: "https://b"))
        _ = c.bindTestLegadoPublishIdentity(exactSourceUrl: "https://b")
        // Active-route ownership moves to B; A must fail before its session is revisited.
        let staleDuringB = c.requestPublishPermit(for: a1Token, isFirstPage: true)
        guard case .failure(let duringBReason) = staleDuringB else {
            return XCTFail("old A token must fail while B is active")
        }
        XCTAssertEqual(duringBReason, .routeFailClosed)
        XCTAssertNotEqual(a1.exactSourceUrl, b1.exactSourceUrl)
        let a2 = c.apply(.switchDiscoverSource(exactSourceUrl: "https://a"))
        _ = c.bindTestLegadoPublishIdentity(exactSourceUrl: "https://a")
        XCTAssertEqual(a2.uiGeneration, a1.uiGeneration + 1)
        let staleA1 = c.requestPublishPermit(for: a1Token, isFirstPage: true)
        guard case .failure(let reason) = staleA1 else {
            return XCTFail("old A token must fail after A re-switch")
        }
        // A→B→A leaves the original A token stale by selection generation.
        XCTAssertEqual(reason, .selectionGenerationMismatch)
    }

    func testPage2BeforePage1Rejected() {
        let c = SourceSessionCoordinator.shared
        let t = c.apply(.switchDiscoverSource(exactSourceUrl: "https://p"))
        var p2 = t
        p2.page = 2
        let r = c.requestPublishPermit(for: p2, isFirstPage: false)
        guard case .failure(let reason) = r else {
            return XCTFail("page2 before page1 must fail")
        }
        XCTAssertEqual(reason, .pageNotContiguous)
    }
}
