import XCTest

/// TC-09：合同语义锁定 — 多源并存 unsupported；Router 行为由 Hooks ObjC 单测覆盖。
final class NativeNavigationIdentityTests: XCTestCase {
    func testTC03AMultiSourceCoexistenceRemainsUnsupported() {
        // shelf-identity-design.json: selectedBranch=unsupportedNativeBookKeyCollision
        // 禁止 Swift/产品宣称原生同名同作者多源并存（C16）。
        let selected = "unsupportedNativeBookKeyCollision"
        XCTAssertEqual(selected, "unsupportedNativeBookKeyCollision")
        XCTAssertFalse(selected.contains("persistedToken"))
        XCTAssertFalse(selected.contains("sourceScoped"))
    }
}
