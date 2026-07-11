import XCTest
@testable import LegadoBridge

final class PostCoreBridgeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SourceRegistry.shared.resetForTesting(clearPersistFile: true)
        BookBindingStore.shared.resetForTesting(clearPersistFile: true)
        ReplaceRuleStore.shared.resetForTesting(clearPersistFile: true)
    }

    override func tearDown() {
        SourceRegistry.shared.resetForTesting(clearPersistFile: true)
        BookBindingStore.shared.resetForTesting(clearPersistFile: true)
        ReplaceRuleStore.shared.resetForTesting(clearPersistFile: true)
        super.tearDown()
    }

    func testGroupFilterAndExploreFlag() throws {
        let a: [String: Any] = [
            "bookSourceUrl": "https://example.com/g1",
            "bookSourceName": "分组源",
            "bookSourceGroup": "玄幻",
            "searchUrl": "https://example.com/s?q={{key}}",
            "exploreUrl": "https://example.com/explore",
            "enabledExplore": true,
            "ruleSearch": ["bookList": ".item"],
            "ruleExplore": ["bookList": ".item", "name": ".n"]
        ]
        let b: [String: Any] = [
            "bookSourceUrl": "https://example.com/g2",
            "bookSourceName": "无分组源",
            "searchUrl": "https://example.com/s2?q={{key}}",
            "ruleSearch": ["bookList": ".item"]
        ]
        let data = try JSONSerialization.data(withJSONObject: [a, b])
        XCTAssertEqual(try SourceRegistry.shared.importJSONData(data), 2)

        let groups = SourceRegistry.shared.allGroups()
        XCTAssertEqual(groups, ["玄幻"])

        let filtered = SourceRegistry.shared.allSourcesInfoDicts(groupFilter: "玄幻")
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0]["bookSourceName"] as? String, "分组源")
        XCTAssertEqual(filtered[0]["exploreSupported"] as? Bool, true)

        let ungrouped = SourceRegistry.shared.allSourcesInfoDicts(groupFilter: "__ungrouped__")
        XCTAssertEqual(ungrouped.count, 1)
        XCTAssertEqual(ungrouped[0]["bookSourceName"] as? String, "无分组源")

        let explore = SourceRegistry.shared.exploreCapableSources()
        XCTAssertEqual(explore.count, 1)
        XCTAssertEqual(explore.first?.bookSourceUrl, "https://example.com/g1")
    }

    func testMatchChapterViaCore() {
        let core = LegadoBridgeCore.shared
        let dict = core.matchChapter(
            title: "第二章",
            index: -1,
            chapterTitles: ["第一章", "第二章", "第三章"],
            chapterUrls: ["u1", "u2", "u3"]
        )
        XCTAssertEqual(dict?["index"] as? Int, 1)
        XCTAssertEqual(dict?["url"] as? String, "u2")
    }

    func testReplaceRuleStoreImportAndPurify() throws {
        let json = #"[{"name":"去广告","pattern":"广告位","replacement":"","isRegex":false}]"#
        XCTAssertEqual(try ReplaceRuleStore.shared.importJSON(json), 1)
        let out = ReplaceRuleStore.shared.purify("正文广告位尾")
        XCTAssertEqual(out, "正文尾")
        XCTAssertEqual(LegadoBridgeCore.shared.replaceRulesCount, 1)
    }

    func testSwitchRebindsBookSource() {
        let old = BookBindingStore.shared.bind(
            bookUrl: "https://book/old",
            sourceUrl: "https://src/old",
            sourceName: "旧源",
            name: "测试书",
            author: "作者"
        )
        XCTAssertTrue(old.sourceAvailable)
        // 模拟换源后的新绑定（网络路径由真机测；此处验 Store 语义）
        _ = BookBindingStore.shared.bind(
            bookUrl: "https://book/old",
            sourceUrl: "https://src/old",
            sourceName: "旧源",
            name: "测试书",
            author: "作者",
            bridgeToken: old.bridgeToken,
            sourceAvailable: false
        )
        let neu = BookBindingStore.shared.bind(
            bookUrl: "https://book/new",
            sourceUrl: "https://src/new",
            sourceName: "新源",
            name: "测试书",
            author: "作者"
        )
        XCTAssertEqual(neu.sourceUrl, "https://src/new")
        XCTAssertEqual(BookBindingStore.shared.binding(forBookUrl: "https://book/old")?.sourceAvailable, false)
        XCTAssertEqual(BookBindingStore.shared.binding(forBookUrl: "https://book/new")?.sourceAvailable, true)
    }
}
