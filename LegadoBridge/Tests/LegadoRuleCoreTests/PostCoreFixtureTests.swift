import XCTest
@testable import LegadoRuleCore

final class PostCoreFixtureTests: XCTestCase {

    // MARK: - 章节匹配

    func testChapterExactMatch() {
        let chapters = [
            BridgeChapter(title: "第一章 开端", url: "u1", index: 0),
            BridgeChapter(title: "第二章 旅程", url: "u2", index: 1),
            BridgeChapter(title: "第三章 归途", url: "u3", index: 2)
        ]
        let m = ChapterMatcher.match(currentTitle: "第二章 旅程", currentIndex: 0, chapters: chapters)
        XCTAssertEqual(m?.index, 1)
        XCTAssertEqual(m?.strategy, "exact")
        XCTAssertEqual(m?.score, 1.0)
    }

    func testChapterNormalizedMatch() {
        let chapters = [
            BridgeChapter(title: "第1章开端", url: "u1", index: 0),
            BridgeChapter(title: "第2章 旅程", url: "u2", index: 1)
        ]
        let m = ChapterMatcher.match(currentTitle: "第2章旅程", currentIndex: nil, chapters: chapters)
        XCTAssertEqual(m?.index, 1)
        XCTAssertTrue(m?.strategy == "normalized" || m?.strategy == "exact" || m?.strategy == "contains")
    }

    func testChapterIndexFallback() {
        let chapters = [
            BridgeChapter(title: "甲", url: "a", index: 0),
            BridgeChapter(title: "乙", url: "b", index: 1)
        ]
        let m = ChapterMatcher.match(currentTitle: "", currentIndex: 1, chapters: chapters)
        XCTAssertEqual(m?.index, 1)
        XCTAssertEqual(m?.strategy, "index")
    }

    func testCompatibilityFixtureMatchChapter() {
        let chapters = [BridgeChapter(title: "终章", url: "end", index: 0)]
        let m = CompatibilityFixtures.matchChapter(
            currentTitle: "终章",
            currentIndex: nil,
            chapters: chapters
        )
        XCTAssertEqual(m?.url, "end")
    }

    // MARK: - 替换净化

    func testReplacePlainAndRegex() {
        let rules = [
            ReplaceRuleItem(name: "plain", pattern: "广告", replacement: "", isRegex: false, priority: 5),
            ReplaceRuleItem(name: "re", pattern: #"\n{3,}"#, replacement: "\n\n", isRegex: true, priority: 1)
        ]
        let raw = "正文广告\n\n\n\n结尾"
        let out = ReplaceEngine.apply(text: raw, items: rules)
        XCTAssertFalse(out.contains("广告"))
        XCTAssertFalse(out.contains("\n\n\n"))
    }

    func testReplaceAnalyzerJSON() throws {
        let json = """
        [{"name":"去壳","pattern":"请收藏本站","replacement":"","isRegex":false,"enabled":true}]
        """
        let rules = try ReplaceAnalyzer.jsonToReplaceRules(json).get()
        XCTAssertEqual(rules.count, 1)
        let out = ReplaceEngine.purify(content: "开头请收藏本站结尾", items: rules)
        XCTAssertEqual(out, "开头结尾")
    }

    func testPurifyIgnoresDisabled() {
        let rules = [
            ReplaceRuleItem(pattern: "X", replacement: "Y", isRegex: false, enabled: false)
        ]
        XCTAssertEqual(ReplaceEngine.purify(content: "aXb", items: rules), "aXb")
    }

    func testCompatibilityPurify() {
        let rules = ReplaceEngine.presetRules
        let text = "aaa\n\n\n\nbbb"
        let out = CompatibilityFixtures.purifyContent(text, rules: rules)
        XCTAssertFalse(out.contains("\n\n\n"))
    }
}
