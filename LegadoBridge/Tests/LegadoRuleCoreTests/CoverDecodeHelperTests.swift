import XCTest
@testable import LegadoRuleCore

final class CoverDecodeHelperTests: XCTestCase {
    func testDecodeJsReplacesCipherPrefix() {
        let js = "result = src.replace('cipher:','https://');"
        let out = CoverDecodeHelper.decodeCoverURL(
            "cipher://fixture.local/cover.jpg",
            decodeJs: js,
            baseUrl: "https://fixture.local/",
            source: nil
        )
        XCTAssertEqual(out, "https://fixture.local/cover.jpg")
    }

    func testEmptyDecodeJsReturnsOriginal() {
        let url = "https://example.com/a.jpg"
        XCTAssertEqual(
            CoverDecodeHelper.decodeCoverURL(url, decodeJs: nil, baseUrl: nil, source: nil),
            url
        )
    }

    func testDecodeJsAssignsResultVariable() {
        let js = "result = 'https://cdn.example/cover.png';"
        let out = CoverDecodeHelper.decodeCoverURL(
            "opaque-token",
            decodeJs: js,
            baseUrl: "https://fixture.local/",
            source: nil
        )
        XCTAssertEqual(out, "https://cdn.example/cover.png")
    }
}
