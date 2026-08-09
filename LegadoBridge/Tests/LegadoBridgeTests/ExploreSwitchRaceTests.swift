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
        let b1 = c.apply(.switchDiscoverSource(exactSourceUrl: "https://b"))
        // A 迟到回包：仍可对 A session 申请 permit（A 会话未改）
        XCTAssertNoThrow(try c.requestPublishPermit(for: a1, isFirstPage: true).get())
        // 但 B 当前 token 与 A 不同源
        XCTAssertNotEqual(a1.exactSourceUrl, b1.exactSourceUrl)
        let a2 = c.apply(.switchDiscoverSource(exactSourceUrl: "https://a"))
        XCTAssertEqual(a2.uiGeneration, a1.uiGeneration + 1)
        let staleA1 = c.requestPublishPermit(for: a1, isFirstPage: true)
        guard case .failure(let reason) = staleA1 else {
            return XCTFail("old A token must fail after A re-switch")
        }
        // TC-08I：切源同时抬 selectionGeneration；校验顺序先命中 selection
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
