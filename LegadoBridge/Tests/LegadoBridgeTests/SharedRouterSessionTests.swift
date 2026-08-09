import Foundation
import XCTest
@testable import LegadoBridge

final class SharedRouterSessionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SourceSessionCoordinator.shared.resetForTests()
    }

    func testSessionKeyIsolatesXBSAndLegado() {
        let c = SourceSessionCoordinator.shared
        let xbs = SelectionToken(sourceKind: .xbs, canonicalID: "番茄小说")
        let legado = SelectionToken(sourceKind: .legado, canonicalID: "https://legado.example/bookSource")
        let tX = c.applySelection(xbs)
        let tL = c.applySelection(legado)
        XCTAssertEqual(tX.sourceKind, .xbs)
        XCTAssertEqual(tL.sourceKind, .legado)
        XCTAssertNotEqual(tX.sessionKey, tL.sessionKey)
    }

    func testAReselectBumpsSelectionGenerationOnly() {
        let c = SourceSessionCoordinator.shared
        let sel = SelectionToken(sourceKind: .xbs, canonicalID: "key-a")
        let first = c.applySelection(sel)
        let second = c.apply(.reselectSameDiscoverSource(sel))
        XCTAssertEqual(second.uiGeneration, first.uiGeneration)
        XCTAssertEqual(second.contentGeneration, first.contentGeneration)
        XCTAssertEqual(second.selectionGeneration, first.selectionGeneration + 1)
    }

    func testManagerGenerationInvalidatesStalePublish() {
        let c = SourceSessionCoordinator.shared
        let sel = SelectionToken(sourceKind: .xbs, canonicalID: "xbs-src")
        let token = c.applySelection(sel)
        c.bumpManagerGeneration()
        let fresh = c.currentToken(sourceKind: .xbs, canonicalID: "xbs-src")!
        var stale = token
        stale.managerOrRegistryGeneration = token.managerOrRegistryGeneration
        let result = c.requestPublishPermit(for: stale, isFirstPage: true)
        guard case .failure(let reason) = result else {
            return XCTFail("expected manager generation mismatch")
        }
        XCTAssertEqual(reason, .managerOrRegistryGenerationMismatch)
        XCTAssertGreaterThan(fresh.managerOrRegistryGeneration, token.managerOrRegistryGeneration)
    }
}
