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
        let token = c.applySelection(sel)
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
        var page1 = c.applySelection(sel)
        page1.page = 1
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
}
