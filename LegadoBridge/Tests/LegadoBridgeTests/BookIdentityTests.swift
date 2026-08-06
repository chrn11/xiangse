import Foundation
import XCTest
@testable import LegadoBridge

final class BookIdentityTests: XCTestCase {
    func testFixedTokenVectors() throws {
        let cases: [(String, String, String)] = [
            (
                "https://source.example/a",
                "https://book.example/1",
                "lb2_5d4b252724b4e84437e9f2e5cf93941b35bd6efeb4ac144d409a18883c726158"
            ),
            (
                "源://甲",
                "书://同一本",
                "lb2_da9d3d58d11fb91db0bee700dd13419ee7461b5a939b7e598d05c1be630688d9"
            ),
            (
                "https://A.example:443/x?q=1#F",
                "BOOK",
                "lb2_b3fccd6d7fc0d42befe72297843e48d0d36058f72643cdc5be87012cb17d30f0"
            ),
        ]
        for (source, book, expected) in cases {
            let identity = try BookIdentity(exactSourceUrl: source, exactBookUrl: book)
            XCTAssertEqual(identity.bridgeTokenV2, expected)
            XCTAssertEqual(identity.sourceUrl, source)
            XCTAssertEqual(identity.bookUrl, book)
        }
    }

    func testUnicodeAndDelimiterPreserved() throws {
        let identity = try BookIdentity(exactSourceUrl: "源://甲", exactBookUrl: "书://同一本")
        XCTAssertEqual(identity.sourceUrl, "源://甲")
        XCTAssertEqual(identity.bookUrl, "书://同一本")
        XCTAssertTrue(identity.bridgeTokenV2.hasPrefix("lb2_"))
        XCTAssertEqual(identity.bridgeTokenV2.count, 4 + 64)
    }

    func testCasePortQueryFragmentPreserved() throws {
        let source = "https://A.example:443/x?q=1#F"
        let book = "BOOK"
        let identity = try BookIdentity(exactSourceUrl: source, exactBookUrl: book)
        XCTAssertEqual(identity.sourceUrl, source)
        XCTAssertEqual(identity.bookUrl, book)
        // 不得规范化大小写或剥 fragment
        XCTAssertNotEqual(identity.sourceUrl.lowercased(), identity.sourceUrl)
        XCTAssertTrue(identity.sourceUrl.contains("#F"))
        XCTAssertTrue(identity.sourceUrl.contains(":443"))
    }

    func testTrimsWhitespaceOnly() throws {
        let identity = try BookIdentity(
            exactSourceUrl: "  https://source.example/a\n",
            exactBookUrl: "\thttps://book.example/1  "
        )
        XCTAssertEqual(identity.sourceUrl, "https://source.example/a")
        XCTAssertEqual(identity.bookUrl, "https://book.example/1")
    }

    func testEmptyFieldsThrowTypedError() {
        XCTAssertThrowsError(try BookIdentity(exactSourceUrl: "  ", exactBookUrl: "b")) { err in
            XCTAssertEqual(err as? BookIdentityError, .emptySourceUrl)
        }
        XCTAssertThrowsError(try BookIdentity(exactSourceUrl: "s", exactBookUrl: "\n")) { err in
            XCTAssertEqual(err as? BookIdentityError, .emptyBookUrl)
        }
    }

    func testTokenIsPureFunctionIndependentOfStore() throws {
        let a = try BookIdentity(exactSourceUrl: "https://s/a", exactBookUrl: "https://b/1")
        let b = try BookIdentity(exactSourceUrl: "https://s/a", exactBookUrl: "https://b/1")
        XCTAssertEqual(a.bridgeTokenV2, b.bridgeTokenV2)
        XCTAssertEqual(a, b)
    }
}
