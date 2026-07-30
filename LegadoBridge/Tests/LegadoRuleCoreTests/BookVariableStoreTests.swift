import XCTest
@testable import LegadoRuleCore

final class BookVariableStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        BookVariableStore.resetForTesting(clearPersistFile: true)
    }

    override func tearDown() {
        BookVariableStore.resetForTesting(clearPersistFile: true)
        super.tearDown()
    }

    func testPutGetPersistAcrossResetMemoryReload() {
        let bookUrl = "https://fixture.local/book/bv1"
        BookVariableStore.put("token", value: "persist-me", bookUrl: bookUrl)
        XCTAssertEqual(BookVariableStore.get("token", bookUrl: bookUrl), "persist-me")

        let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("legado_bridge_book_variables.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path), "应落盘变量文件")

        // 模拟进程重启：清内存、保留文件、再读盘
        BookVariableStore.resetForTesting(clearPersistFile: false)
        XCTAssertEqual(BookVariableStore.get("token", bookUrl: bookUrl), "persist-me")
    }

    func testJSPutGetUsesBookStoreWhenBookUrlBound() throws {
        let bookUrl = "https://fixture.local/book/bv-js"
        BookVariableStore.resetForTesting(clearPersistFile: true)

        let putResult = try RuleWebBook.evaluateString(
            rule: "@js:java.put('chapterMark','ch2'); java.get('chapterMark');",
            body: "<html><body>x</body></html>",
            bookUrl: bookUrl
        )
        XCTAssertTrue(putResult.contains("ch2"), "put/get 应返回 ch2，实际: \(putResult)")
        XCTAssertEqual(BookVariableStore.get("chapterMark", bookUrl: bookUrl), "ch2")

        // 新 context，仅靠 BookVariableStore 取回
        let getResult = try RuleWebBook.evaluateString(
            rule: "@js:java.get('chapterMark');",
            body: "<html><body>y</body></html>",
            bookUrl: bookUrl
        )
        XCTAssertTrue(getResult.contains("ch2"), "跨调用应读到书本变量，实际: \(getResult)")
    }

    func testBookPutVariableAPI() throws {
        let bookUrl = "https://fixture.local/book/bv-api"
        let result = try RuleWebBook.evaluateString(
            rule: "@js:book.putVariable('k','v'); book.getVariable('k');",
            body: "<html></html>",
            bookUrl: bookUrl
        )
        XCTAssertTrue(result.contains("v"), "book.putVariable/getVariable 应生效，实际: \(result)")
        XCTAssertEqual(BookVariableStore.get("k", bookUrl: bookUrl), "v")
    }

    func testSourceSessionUnaffectedWhenNoBookUrl() throws {
        SourceSessionStore.clear(sourceUrl: "https://src.example/")
        // 无 bookUrl 时仍走源级（source 为 nil 则只写 context.variables）
        let result = try RuleWebBook.evaluateString(
            rule: "@js:java.put('onlyLocal','L'); java.get('onlyLocal');",
            body: "<html></html>"
        )
        XCTAssertTrue(result.contains("L"), "无 bookUrl 时本地 put/get 仍可用，实际: \(result)")
        XCTAssertEqual(BookVariableStore.get("onlyLocal", bookUrl: "https://fixture.local/book/none"), "")
    }
}
