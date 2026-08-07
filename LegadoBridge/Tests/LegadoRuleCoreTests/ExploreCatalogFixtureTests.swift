import Foundation
import XCTest
@testable import LegadoRuleCore

final class ExploreCatalogFixtureTests: XCTestCase {
    func testLingyuFixtureExactShape() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "lingyu", withExtension: "json", subdirectory: "Fixtures/Explore")
            ?? Bundle.module.url(forResource: "lingyu", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let explore = try XCTUnwrap(obj?["exploreUrl"] as? String)
        let sourceUrl = try XCTUnwrap(obj?["exactSourceUrl"] as? String)
        let expected = try XCTUnwrap(obj?["expected"] as? [String: Any])
        let snap = ExploreCatalogBuilder.build(exactSourceUrl: sourceUrl, exploreRaw: explore)
        XCTAssertEqual(snap.channels.count, expected["channelCount"] as? Int)
        let nodes = snap.channels.flatMap(\.nodes)
        XCTAssertEqual(nodes.count, expected["nodeCount"] as? Int)
        let titles = expected["titles"] as? [String]
        XCTAssertEqual(nodes.map(\.displayTitle), titles)
        XCTAssertTrue(nodes.allSatisfy { $0.kind == .url && $0.selectable })
        // rawTarget 逐字：不得 trim
        for n in nodes {
            XCTAssertTrue(n.rawTarget.hasPrefix("/fenlei/"))
            XCTAssertTrue(n.rawTarget.contains("{{page}}"))
        }
        XCTAssertFalse(snap.snapshotID.isEmpty)
        XCTAssertTrue(snap.snapshotID.hasPrefix("lbs1_"))
    }

    func testLexerMatrixFixture() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "lexer-matrix", withExtension: "json", subdirectory: "Fixtures/Explore")
            ?? Bundle.module.url(forResource: "lexer-matrix", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let emptyStyle = try XCTUnwrap(obj?["empty_url_style"] as? String)
        let parsed = ExploreCatalogLexer.parseItem(emptyStyle)
        XCTAssertEqual(parsed.rawTitle, "标题")
        XCTAssertEqual(parsed.rawTarget, "")
        XCTAssertEqual(parsed.rawStyle, .number(1))

        let jsonStyles = try XCTUnwrap(obj?["json_styles"] as? String)
        var diag = ExploreCatalogDiagnostics()
        let channels = ExploreCatalogBuilder.normalizeJSON(
            text: jsonStyles,
            sourceUrl: "https://s.example",
            fingerprint: "fp",
            diagnostics: &diag
        )
        XCTAssertFalse(channels.isEmpty)
        // nested children → multi channel
        XCTAssertGreaterThanOrEqual(channels.count, 1)
    }

    /// 1751：真实源含凭证，夹具仅脱敏结构（未求值 @js + 求值后空 URL group）。
    func test1751SanitizedFixtureExactShape() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "1751-sanitized", withExtension: "json", subdirectory: "Fixtures/Explore")
                ?? Bundle.module.url(forResource: "1751-sanitized", withExtension: "json")
        )
        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let sourceUrl = try XCTUnwrap(obj?["exactSourceUrl"] as? String)
        let uneval = try XCTUnwrap(obj?["unevaluatedExploreUrl"] as? String)
        let expectedU = try XCTUnwrap(obj?["expectedUnevaluated"] as? [String: Any])
        let snapU = ExploreCatalogBuilder.build(exactSourceUrl: sourceUrl, exploreRaw: uneval)
        XCTAssertEqual(snapU.channels.count, expectedU["channelCount"] as? Int)
        XCTAssertTrue(snapU.diagnostics.codes.contains("topLevelJSUnevaluated"))
        XCTAssertTrue(RuleWebBook.isTopLevelExploreJS(uneval))

        let evaluatedJSON = try XCTUnwrap(obj?["evaluatedJSON"] as? String)
        let expectedE = try XCTUnwrap(obj?["expectedEvaluated"] as? [String: Any])
        var diag = ExploreCatalogDiagnostics()
        let channels = ExploreCatalogBuilder.normalizeJSON(
            text: evaluatedJSON,
            sourceUrl: sourceUrl,
            fingerprint: "fp-1751",
            diagnostics: &diag
        )
        XCTAssertEqual(channels.count, expectedE["channelCount"] as? Int)
        XCTAssertEqual(channels.map(\.displayTitle), expectedE["channelTitles"] as? [String])
        let nodes = channels.flatMap(\.nodes)
        XCTAssertEqual(nodes.count, expectedE["nodeCount"] as? Int)
        XCTAssertEqual(nodes.map(\.displayTitle), expectedE["nodeTitles"] as? [String])
        XCTAssertTrue(nodes.allSatisfy { $0.kind == .url && $0.selectable })
        // 空 URL 只在 channel 层；子 node 必须有可请求 target
        for n in nodes {
            XCTAssertFalse(n.rawTarget.isEmpty)
            XCTAssertTrue(n.rawTarget.contains("{{page}}"))
        }
        // 夹具不得夹带真实凭证片段
        let blob = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(blob.lowercased().contains("cookie"))
        XCTAssertFalse(blob.contains("Map(\"token\")"))
    }
}
