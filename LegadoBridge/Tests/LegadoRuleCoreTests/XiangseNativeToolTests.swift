import XCTest
@testable import LegadoRuleCore

/// 香色 nativeTool / @js: requestInfo 形态适配
final class XiangseNativeToolTests: XCTestCase {

    func testNativeToolCacheRoundTrip() {
        let analyzed = AnalyzeUrl.analyze(
            ruleUrl: #"""
            @js:
            params.nativeTool.setCache("xs_k", "xs_v");
            result = params.nativeTool.getCache("xs_k");
            """#,
            key: nil,
            page: 1,
            baseUrl: "https://example.com",
            source: nil
        )
        XCTAssertEqual(analyzed.url, "xs_v")
    }

    func testNativeToolMd5AndBase64() {
        let analyzed = AnalyzeUrl.analyze(
            ruleUrl: #"""
            @js:
            var m = params.nativeTool.md5Encode("abc");
            var b = params.nativeTool.base64Encode("hi");
            result = m + "|" + b;
            """#,
            key: nil,
            page: 1,
            baseUrl: "https://example.com",
            source: nil
        )
        XCTAssertEqual(
            analyzed.url,
            "900150983cd24fb0d6963f7d28e17f72|aGk="
        )
    }

    func testParamsKeyWordAlias() {
        let analyzed = AnalyzeUrl.analyze(
            ruleUrl: #"@js:result="q="+encodeURIComponent(params.keyWord);"#,
            key: "斗破",
            page: 2,
            baseUrl: "https://example.com",
            source: nil
        )
        XCTAssertTrue(
            analyzed.url.contains("斗破") || analyzed.url.contains("%"),
            "应带上 params.keyWord，实际: \(analyzed.url)"
        )
        XCTAssertFalse(analyzed.url.hasPrefix("@js:"))
    }

    func testXiangseReturnObjectToUrl() {
        let analyzed = AnalyzeUrl.analyze(
            ruleUrl: #"""
            @js:
            let KEY = encodeURI(params.keyWord);
            return {url: "https://api.example.com/s?q=" + KEY};
            """#,
            key: "abc",
            page: 1,
            baseUrl: "https://example.com",
            source: nil
        )
        XCTAssertTrue(
            analyzed.url.contains("https://api.example.com/s?q="),
            "应展开香色 {url} 对象，实际: \(analyzed.url)"
        )
        XCTAssertTrue(analyzed.url.contains("abc"))
        XCTAssertFalse(analyzed.url.hasPrefix("@js:"))
    }

    func testXiangseReturnObjectPost() {
        let analyzed = AnalyzeUrl.analyze(
            ruleUrl: #"""
            @js:
            return {
              url: "/e/search/index.php",
              POST: true,
              httpParams: {"keyboard": params.keyWord}
            };
            """#,
            key: "测试",
            page: 1,
            baseUrl: "https://novel.example.com",
            source: nil
        )
        XCTAssertTrue(
            analyzed.url.contains("/e/search/index.php"),
            "实际: \(analyzed.url)"
        )
        // AnalyzeUrl 会解析 method；至少不得残留 @js:
        XCTAssertFalse(analyzed.url.hasPrefix("@js:"))
        XCTAssertEqual(analyzed.method, .POST)
    }

    func testGlobalNativeToolVisible() {
        let analyzed = AnalyzeUrl.analyze(
            ruleUrl: #"@js:result=typeof nativeTool + "-" + typeof params.nativeTool;"#,
            key: nil,
            page: 1,
            baseUrl: "https://example.com",
            source: nil
        )
        XCTAssertEqual(analyzed.url, "object-object")
    }
}
