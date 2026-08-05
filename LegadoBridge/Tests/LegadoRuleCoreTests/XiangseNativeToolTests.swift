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
        // analyzeUrl 会把非 http 结果相对 baseUrl 拼绝对路径
        XCTAssertTrue(
            analyzed.url == "xs_v" || analyzed.url.hasSuffix("/xs_v"),
            "实际: \(analyzed.url)"
        )
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
        let md5 = "900150983cd24fb0d6963f7d28e17f72"
        let b64 = "aGk="
        XCTAssertTrue(
            analyzed.url.contains(md5),
            "缺 md5，实际: \(analyzed.url)"
        )
        // |/= 可能被绝对 URL 编码成 %7C / %3D
        XCTAssertTrue(
            analyzed.url.contains(b64) || analyzed.url.contains("aGk%3D"),
            "缺 base64，实际: \(analyzed.url)"
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
        XCTAssertTrue(
            analyzed.url == "object-object" || analyzed.url.hasSuffix("/object-object"),
            "nativeTool 未注入，实际: \(analyzed.url)"
        )
    }

    func testXPathParserWithSourceSearch() {
        let analyzed = AnalyzeUrl.analyze(
            ruleUrl: #"""
            @js:
            var html = '<html><body><div id="a"><p class="t">萧炎</p><a href="/c1">第一章</a></div></body></html>';
            var doc = params.nativeTool.XPathParserWithSource(html);
            var nodes = doc.searchWithXPathQuery('//p[@class="t"]');
            var a = doc.peekAtSearchWithXPathQuery('//a');
            var href = a.objectForKey('href');
            result = nodes[0].content + "|" + href + "|" + a.text;
            """#,
            key: nil,
            page: 1,
            baseUrl: "https://example.com",
            source: nil
        )
        XCTAssertTrue(
            analyzed.url.contains("萧炎"),
            "应解析出正文，实际: \(analyzed.url)"
        )
        XCTAssertTrue(
            analyzed.url.contains("/c1") || analyzed.url.contains("%2Fc1"),
            "应解析出 href，实际: \(analyzed.url)"
        )
        XCTAssertTrue(
            analyzed.url.contains("第一章") || analyzed.url.contains("%"),
            "应解析出链接文本，实际: \(analyzed.url)"
        )
    }

    func testXPathParserWithSourceQueryAliasAndTextNode() {
        let analyzed = AnalyzeUrl.analyze(
            ruleUrl: #"""
            @js:
            var html = '<html><body><p class="t">萧炎</p></body></html>';
            var doc = params.nativeTool.XPathParserWithSource(html);
            var nodes = doc.queryWithXPath('//p[@class="t"]/text()');
            result = (typeof doc) + "|" + nodes.length + "|" + nodes[0].content;
            """#,
            key: nil,
            page: 1,
            baseUrl: "https://example.com",
            source: nil
        )
        XCTAssertTrue(
            analyzed.url.contains("object"),
            "XPathParserWithSource 应返回对象，实际: \(analyzed.url)"
        )
        XCTAssertTrue(
            analyzed.url.contains("萧炎"),
            "text() 节点应有 content，实际: \(analyzed.url)"
        )
    }
}
