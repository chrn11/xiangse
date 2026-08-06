import Foundation
import XCTest
@testable import LegadoRuleCore

final class ExploreCatalogParserTests: XCTestCase {
    func testEmptyURLGroupWithStyle() {
        let parsed = ExploreCatalogLexer.parseItem("标题::::1")
        XCTAssertEqual(parsed.rawTitle, "标题")
        XCTAssertEqual(parsed.rawTarget, "")
        XCTAssertEqual(parsed.rawStyle, .number(1))
    }

    func testTopLevelAndInsideQuotesNotSplit() {
        let items = ExploreCatalogLexer.splitItems("\"a&&b\"::/x && 真实::/y")
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items[0].contains("a&&b"))
        let p0 = ExploreCatalogLexer.parseItem(items[0])
        XCTAssertEqual(p0.rawTarget, "/x")
        let p1 = ExploreCatalogLexer.parseItem(items[1])
        XCTAssertEqual(p1.rawTitle.trimmingCharacters(in: .whitespaces), "真实")
        XCTAssertEqual(p1.rawTarget, "/y")
    }

    func testBacktickProtectsInnerDelimiter() {
        let parsed = ExploreCatalogLexer.parseItem("`a::b`::/path")
        XCTAssertEqual(parsed.rawTitle, "`a::b`")
        XCTAssertEqual(parsed.rawTarget, "/path")
    }

    func testRawTargetNeverTrimmed() {
        let parsed = ExploreCatalogLexer.parseItem("名::  /path  ")
        XCTAssertEqual(parsed.rawTarget, "  /path  ")
    }

    func testUnknownStyleSuffixStaysInTarget() {
        let parsed = ExploreCatalogLexer.parseItem("名::/u::notAStyle")
        XCTAssertEqual(parsed.rawTarget, "/u::notAStyle")
        XCTAssertNil(parsed.rawStyle)
    }

    func testSingleURLBecomesDiscoverLeaf() {
        let snap = ExploreCatalogBuilder.build(
            exactSourceUrl: "https://s.example",
            exploreRaw: "https://book.example/list"
        )
        XCTAssertEqual(snap.channels.count, 1)
        XCTAssertEqual(snap.channels[0].nodes.count, 1)
        let n = snap.channels[0].nodes[0]
        XCTAssertEqual(n.kind, .url)
        XCTAssertEqual(n.rawTarget, "https://book.example/list")
        XCTAssertTrue(n.selectable)
    }

    func testJSONEmptyURLGroupPreserved() throws {
        let raw = #"[{"title":"男频","url":""},{"title":"书","url":"/b"}]"#
        let snap = ExploreCatalogBuilder.build(exactSourceUrl: "https://s.example", exploreRaw: raw)
        let kinds = RuleWebBook.exploreKinds(from: snap)
        XCTAssertTrue(kinds.contains(where: { $0.title == "男频" && $0.url.isEmpty }))
        XCTAssertTrue(kinds.contains(where: { $0.title == "书" && $0.url == "/b" }))
    }

    func testCodableRoundTrip() throws {
        let snap = ExploreCatalogBuilder.build(
            exactSourceUrl: "https://s.example/a",
            exploreRaw: "A::/a\nB::/b"
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(snap)
        let decoded = try JSONDecoder().decode(ExploreCatalogSnapshot.self, from: data)
        XCTAssertEqual(decoded, snap)
    }

    func testStableIDsDifferForSameTitleDifferentTarget() {
        let snap = ExploreCatalogBuilder.build(
            exactSourceUrl: "https://s.example",
            exploreRaw: "同名::/a\n同名::/b"
        )
        let ids = snap.channels[0].nodes.map(\.nodeID)
        XCTAssertEqual(ids.count, 2)
        XCTAssertNotEqual(ids[0], ids[1])
    }

    func testOldAdapterKeepsEmptyURL() {
        let kinds = RuleWebBook.parseExploreKindsStructural("分组::::1\n书::/x")
        XCTAssertTrue(kinds.contains(where: { $0.title == "分组" && $0.url.isEmpty }))
        XCTAssertTrue(kinds.contains(where: { $0.title == "书" && $0.url == "/x" }))
    }
}
