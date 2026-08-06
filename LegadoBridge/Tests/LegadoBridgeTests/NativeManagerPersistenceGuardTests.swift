import Foundation
import XCTest
@testable import LegadoBridge

final class NativeManagerPersistenceGuardTests: XCTestCase {
    override func setUp() {
        super.setUp()
        NativeManagerPersistenceGuard.resetForTests()
    }

    override func tearDown() {
        NativeManagerPersistenceGuard.resetForTests()
        super.tearDown()
    }

    func testCountersIndependent() {
        NativeManagerPersistenceGuard.recordSaveAttempt()
        NativeManagerPersistenceGuard.recordSaveAttempt()
        NativeManagerPersistenceGuard.recordAddModelsAttempt()
        NativeManagerPersistenceGuard.recordSyncAttempt()
        NativeManagerPersistenceGuard.recordSyncAttempt()
        NativeManagerPersistenceGuard.recordSyncAttempt()
        let snap = NativeManagerPersistenceGuard.snapshot()
        XCTAssertEqual(snap.save, 2)
        XCTAssertEqual(snap.addModels, 1)
        XCTAssertEqual(snap.sync, 3)
    }

    func testResetClearsAll() {
        NativeManagerPersistenceGuard.recordSaveAttempt()
        NativeManagerPersistenceGuard.recordAddModelsAttempt()
        NativeManagerPersistenceGuard.recordSyncAttempt()
        NativeManagerPersistenceGuard.resetForTests()
        let snap = NativeManagerPersistenceGuard.snapshot()
        XCTAssertEqual(snap.save, 0)
        XCTAssertEqual(snap.addModels, 0)
        XCTAssertEqual(snap.sync, 0)
    }
}
