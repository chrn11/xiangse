import Foundation
import XCTest
@testable import LegadoBridge
import LegadoRuleCore

/// BookBindingStore 确定性门禁：绑定 / 持久化 / 删源策略 / 不串源。
/// 需在 macOS/CI 的 iOS 目标上执行：`swift test --package-path LegadoBridge`
/// Windows 无 iOS SDK 时由 `.test_tools/validate_baseline_and_tests.py` 校验本文件存在性与语义镜像。
final class BookBindingStoreTests: XCTestCase {
    private let store = BookBindingStore.shared

    override func setUp() {
        super.setUp()
        store.resetForTesting(clearPersistFile: true)
    }

    override func tearDown() {
        store.resetForTesting(clearPersistFile: true)
        super.tearDown()
    }

    func testBindAndLookupByBookUrlAndToken() {
        let binding = store.bind(
            bookUrl: "https://book.example/a",
            sourceUrl: "https://source.example/a",
            sourceName: "源A",
            name: "书名A",
            author: "作者"
        )
        XCTAssertFalse(binding.bridgeToken.isEmpty)
        XCTAssertEqual(store.sourceUrl(forBookUrl: "https://book.example/a"), "https://source.example/a")
        XCTAssertEqual(store.binding(forToken: binding.bridgeToken)?.bookUrl, "https://book.example/a")
        XCTAssertTrue(binding.sourceAvailable)
    }

    func testPersistAcrossRestoreDoesNotMixSources() {
        _ = store.bind(
            bookUrl: "https://book.example/1",
            sourceUrl: "https://source.example/1",
            sourceName: "源1",
            name: "书1"
        )
        _ = store.bind(
            bookUrl: "https://book.example/2",
            sourceUrl: "https://source.example/2",
            sourceName: "源2",
            name: "书2"
        )

        store.resetForTesting(clearPersistFile: false)
        XCTAssertEqual(store.allBindings().count, 0)

        let restored = store.restoreFromDiskIfNeeded()
        XCTAssertEqual(restored, 2)
        XCTAssertEqual(store.sourceUrl(forBookUrl: "https://book.example/1"), "https://source.example/1")
        XCTAssertEqual(store.sourceUrl(forBookUrl: "https://book.example/2"), "https://source.example/2")
        XCTAssertNotEqual(
            store.binding(forBookUrl: "https://book.example/1")?.bridgeToken,
            store.binding(forBookUrl: "https://book.example/2")?.bridgeToken
        )
    }

    func testDeletePolicyKeepBooksMarkUnavailable() {
        BookBindingStore.deletePolicy = .keepBooksMarkUnavailable
        _ = store.bind(
            bookUrl: "https://book.example/k",
            sourceUrl: "https://source.example/k",
            name: "保留书"
        )
        store.applySourceDeleted(sourceUrl: "https://source.example/k")
        let binding = store.binding(forBookUrl: "https://book.example/k")
        XCTAssertNotNil(binding)
        XCTAssertEqual(binding?.sourceUrl, "https://source.example/k")
        XCTAssertFalse(binding?.sourceAvailable ?? true)
    }

    func testDeletePolicyClearBridgeBindings() {
        BookBindingStore.deletePolicy = .clearBridgeBindings
        _ = store.bind(
            bookUrl: "https://book.example/c",
            sourceUrl: "https://source.example/c",
            name: "清除书"
        )
        store.applySourceDeleted(sourceUrl: "https://source.example/c")
        XCTAssertNil(store.binding(forBookUrl: "https://book.example/c"))
    }

    func testRebindSameBookUrlUpdatesSource() {
        _ = store.bind(
            bookUrl: "https://book.example/x",
            sourceUrl: "https://source.example/old",
            name: "旧"
        )
        let newer = store.bind(
            bookUrl: "https://book.example/x",
            sourceUrl: "https://source.example/new",
            name: "新"
        )
        XCTAssertEqual(store.allBindings().count, 1)
        XCTAssertEqual(store.sourceUrl(forBookUrl: "https://book.example/x"), "https://source.example/new")
        XCTAssertEqual(store.binding(forToken: newer.bridgeToken)?.name, "新")
    }

    func testExactSourceDoesNotFallbackToActive() throws {
        let registry = SourceRegistry.shared
        registry.resetForTesting(clearPersistFile: true)
        let a = try Self.jsonData(Self.sampleSource(url: "https://source.example/a", name: "A"))
        let b = try Self.jsonData(Self.sampleSource(url: "https://source.example/b", name: "B"))
        XCTAssertEqual(try registry.importJSONData(a), 1)
        XCTAssertEqual(try registry.importJSONData(b), 1)
        registry.setActiveSourceUrl("https://source.example/b")

        XCTAssertNil(registry.exactSource(forUrl: "https://source.example/missing"))
        XCTAssertEqual(registry.exactSource(forUrl: "https://source.example/a")?.bookSourceName, "A")
        // 对比：宽松查找在缺失时会回退
        XCTAssertNotNil(registry.source(forUrl: "https://source.example/missing"))
    }

    func testAdapterSearchDictCarriesBridgeToken() {
        var r = SearchBookResult()
        r.name = "书"
        r.bookUrl = "https://book.example/s"
        r.sourceUrl = "https://source.example/s"
        r.sourceName = "源"
        let binding = store.bind(bookUrl: r.bookUrl, sourceUrl: r.sourceUrl, sourceName: r.sourceName, name: r.name)
        let dict = XiangseAdapter.searchBookDict(r, binding: binding)
        XCTAssertEqual(dict[XiangseAdapter.bridgeTokenKey] as? String, binding.bridgeToken)
        XCTAssertEqual(dict[XiangseAdapter.legadoMarkerKey] as? String, XiangseAdapter.legadoMarkerValue)
        XCTAssertEqual(dict["canAddBookShelf"] as? Bool, true)
        XCTAssertEqual(dict["sourceUrl"] as? String, r.sourceUrl)
    }

    /// 回归：原生 onSearchBookSourceResponse 消费 queryBook（字典），
    /// 旧实现把 [dict] 塞进 searchBook 会导致有引擎结果但列表空。
    func testSearchNotifyPayloadUsesQueryBookDict() {
        var r = SearchBookResult()
        r.name = "斗破苍穹"
        r.author = "天蚕土豆"
        r.bookUrl = "http://mock.local/book/doupo.html"
        r.sourceUrl = "http://mock.local"
        r.sourceName = "本地静态测试源"
        let binding = store.bind(
            bookUrl: r.bookUrl,
            sourceUrl: r.sourceUrl,
            sourceName: r.sourceName,
            name: r.name,
            author: r.author
        )
        let book = XiangseAdapter.searchBookDict(r, binding: binding)
        let payload = XiangseAdapter.searchResultNotifyPayload(
            book: book,
            keyword: "斗破",
            sourceUrl: r.sourceUrl,
            sourceName: r.sourceName
        )
        XCTAssertTrue(payload["queryBook"] is [String: Any])
        XCTAssertTrue(payload["searchBook"] is [String: Any])
        XCTAssertEqual((payload["queryBook"] as? [String: Any])?["bookName"] as? String, "斗破苍穹")
        XCTAssertEqual(payload["querySourceName"] as? String, "本地静态测试源")
        XCTAssertEqual(payload["sourceName"] as? String, "本地静态测试源")
        XCTAssertEqual((payload["arrSearchItems"] as? [[String: Any]])?.count, 1)

        let batch = XiangseAdapter.searchResultsPayload(
            results: [r],
            keyword: "斗破",
            sourceUrl: r.sourceUrl,
            bindings: [r.bookUrl: binding]
        )
        XCTAssertTrue(batch["queryBook"] is [String: Any], "单本批量载荷的 queryBook 须为字典")
        XCTAssertTrue(batch["searchBook"] is [String: Any], "单本时 searchBook 须为字典而非数组")
    }

    // MARK: - fixtures

    private static func sampleSource(url: String, name: String) -> [String: Any] {
        [
            "bookSourceUrl": url,
            "bookSourceName": name,
            "bookSourceType": 0,
            "enabled": true,
            "searchUrl": "\(url)/search?q={{key}}",
            "ruleSearch": [
                "bookList": ".bookbox",
                "name": "h4@text",
                "author": ".author@text",
                "bookUrl": "a@href",
            ],
        ]
    }

    private static func jsonData(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }
}
