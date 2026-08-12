import Foundation
import XCTest
@testable import LegadoBridge
import LegadoRuleCore

/// BookBindingStore 确定性门禁（v2）。测试注入 isolation root，不写真实 Documents。
final class BookBindingStoreTests: XCTestCase {
    private var root: URL!
    private var store: BookBindingStore!

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lb-legacy-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = BookBindingStore(
            persistenceRoot: root,
            clock: { Date() },
            fileWriter: DefaultBookBindingFileWriter(),
            usesLegacyDocumentsV1Fallback: false
        )
        _ = store.restoreFromDiskIfNeeded()
    }

    override func tearDown() {
        store.resetForTesting(clearPersistFile: true)
        try? FileManager.default.removeItem(at: root)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? ""
        XCTAssertFalse(root.path.hasPrefix(docs))
        super.tearDown()
    }

    func testBindAndLookupByBookUrlAndToken() throws {
        let binding = try store.bind(
            bookUrl: "https://book.example/a",
            sourceUrl: "https://source.example/a",
            sourceName: "源A",
            name: "书名A",
            author: "作者"
        )
        XCTAssertFalse(binding.bridgeToken.isEmpty)
        XCTAssertTrue(binding.bridgeToken.hasPrefix("lb2_"))
        XCTAssertEqual(store.sourceUrl(forBookUrl: "https://book.example/a"), "https://source.example/a")
        switch store.binding(forToken: binding.bridgeToken) {
        case .success(let hit):
            XCTAssertEqual(hit.bookUrl, "https://book.example/a")
        case .failure(let err):
            XCTFail("\(err)")
        }
        XCTAssertTrue(binding.sourceAvailable)
    }

    func testPersistAcrossRestoreDoesNotMixSources() throws {
        _ = try store.bind(
            bookUrl: "https://book.example/1",
            sourceUrl: "https://source.example/1",
            sourceName: "源1",
            name: "书1"
        )
        _ = try store.bind(
            bookUrl: "https://book.example/2",
            sourceUrl: "https://source.example/2",
            sourceName: "源2",
            name: "书2"
        )

        let store2 = BookBindingStore(
            persistenceRoot: root,
            clock: { Date() },
            fileWriter: DefaultBookBindingFileWriter(),
            usesLegacyDocumentsV1Fallback: false
        )
        let restored = store2.restoreFromDiskIfNeeded()
        XCTAssertEqual(restored, 2)
        XCTAssertEqual(store2.sourceUrl(forBookUrl: "https://book.example/1"), "https://source.example/1")
        XCTAssertEqual(store2.sourceUrl(forBookUrl: "https://book.example/2"), "https://source.example/2")
    }

    func testDeletePolicyKeepBooksMarkUnavailable() throws {
        BookBindingStore.deletePolicy = .keepBooksMarkUnavailable
        _ = try store.bind(
            bookUrl: "https://book.example/k",
            sourceUrl: "https://source.example/k",
            name: "保留书"
        )
        store.applySourceDeleted(sourceUrl: "https://source.example/k")
        // apply 异步；同步标记
        _ = store.markSourceAvailabilitySync(exactSourceUrl: "https://source.example/k", available: false)
        let binding = store.binding(forBookUrl: "https://book.example/k")
        XCTAssertNotNil(binding)
        XCTAssertEqual(binding?.sourceUrl, "https://source.example/k")
        XCTAssertFalse(binding?.sourceAvailable ?? true)
    }

    func testDeletePolicyClearBridgeBindingsStillKeepsBinding() throws {
        // v2 合同：clear 也只标记不可用，不删 binding
        BookBindingStore.deletePolicy = .clearBridgeBindings
        _ = try store.bind(
            bookUrl: "https://book.example/c",
            sourceUrl: "https://source.example/c",
            name: "清除书"
        )
        store.applySourceDeleted(sourceUrl: "https://source.example/c")
        _ = store.markSourceAvailabilitySync(exactSourceUrl: "https://source.example/c", available: false)
        XCTAssertNotNil(store.binding(forBookUrl: "https://book.example/c"))
        XCTAssertFalse(store.binding(forBookUrl: "https://book.example/c")?.sourceAvailable ?? true)
    }

    /// 原 testRebindSameBookUrlUpdatesSource：改为同 bookUrl 不同 source 并存。
    func testSameBookUrlDifferentSourceCoexist() throws {
        _ = try store.bind(
            bookUrl: "https://book.example/x",
            sourceUrl: "https://source.example/old",
            name: "旧"
        )
        let newer = try store.bind(
            bookUrl: "https://book.example/x",
            sourceUrl: "https://source.example/new",
            name: "新"
        )
        XCTAssertEqual(store.allBindings().count, 2)
        switch store.uniqueLegacyBinding(forBookUrl: "https://book.example/x") {
        case .failure(.ambiguous): break
        default: XCTFail("expected ambiguous")
        }
        switch store.binding(forToken: newer.bridgeToken) {
        case .success(let hit):
            XCTAssertEqual(hit.name, "新")
        case .failure(let err):
            XCTFail("\(err)")
        }
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
        // An explicit missing/empty URL is fail-closed; only nil may use the
        // active/first-enabled convenience path.
        XCTAssertNil(registry.source(forUrl: "https://source.example/missing"))
        XCTAssertNil(registry.source(forUrl: ""))
        XCTAssertEqual(registry.source(forUrl: nil)?.bookSourceUrl, "https://source.example/b")
    }

    func testAdapterSearchDictCarriesBridgeTokenWithoutUpsert() throws {
        var r = SearchBookResult()
        r.name = "书"
        r.bookUrl = "https://book.example/s"
        r.sourceUrl = "https://source.example/s"
        r.sourceName = "源"
        let before = store.durableCount
        let dto = XiangseAdapter.ephemeralDTO(from: r)
        let dict = XiangseAdapter.searchBookDict(r, ephemeral: dto)
        XCTAssertEqual(store.durableCount, before)
        XCTAssertEqual(dict[XiangseAdapter.bridgeTokenKey] as? String, dto?.bridgeToken)
        XCTAssertEqual(dict[XiangseAdapter.legadoMarkerKey] as? String, XiangseAdapter.legadoMarkerValue)
        XCTAssertEqual(dict["canAddBookShelf"] as? Bool, true)
        XCTAssertEqual(dict["sourceUrl"] as? String, r.sourceUrl)
    }

    func testSearchNotifyPayloadUsesQueryBookDict() throws {
        var r = SearchBookResult()
        r.name = "斗破苍穹"
        r.author = "天蚕土豆"
        r.bookUrl = "http://mock.local/book/doupo.html"
        r.sourceUrl = "http://mock.local"
        r.sourceName = "本地静态测试源"
        let dto = XiangseAdapter.ephemeralDTO(from: r)
        let book = XiangseAdapter.searchBookDict(r, ephemeral: dto)
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
            ephemeralByBookUrl: dto.map { [r.bookUrl: $0] } ?? [:]
        )
        XCTAssertTrue(batch["queryBook"] is [String: Any], "单本批量载荷的 queryBook 须为字典")
        XCTAssertTrue(batch["searchBook"] is [String: Any], "单本时 searchBook 须为字典而非数组")
        XCTAssertEqual(book["sourceType"] as? String, "text", "须对齐原生 filterSourceType=text")

        var r2 = r
        r2.bookUrl = "http://mock.local/book/doupo2.html"
        r2.name = "斗破苍穹2"
        let batch2 = XiangseAdapter.searchResultsPayload(
            results: [r, r2],
            keyword: "斗破",
            sourceUrl: r.sourceUrl,
            ephemeralByBookUrl: dto.map { [r.bookUrl: $0] } ?? [:]
        )
        XCTAssertTrue(batch2["searchBook"] is [String: Any], "多本时 searchBook 仍须为字典")
        XCTAssertFalse(batch2["searchBook"] is [Any], "多本时 searchBook 禁止数组")
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
