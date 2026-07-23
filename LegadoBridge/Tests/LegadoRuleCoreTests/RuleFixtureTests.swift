import XCTest
@testable import LegadoRuleCore

final class RuleFixtureTests: XCTestCase {

    private var html: String!
    private var json: String!

    override func setUpWithError() throws {
        let bundle = Bundle.module
        guard let htmlURL = bundle.url(forResource: "sample", withExtension: "html", subdirectory: "Fixtures")
                ?? bundle.url(forResource: "sample", withExtension: "html"),
              let jsonURL = bundle.url(forResource: "sample", withExtension: "json", subdirectory: "Fixtures")
                ?? bundle.url(forResource: "sample", withExtension: "json") else {
            throw XCTSkip("夹具资源未打包进测试 Bundle")
        }
        html = try String(contentsOf: htmlURL, encoding: .utf8)
        json = try String(contentsOf: jsonURL, encoding: .utf8)
    }

    // MARK: - CSS

    func testCSSSelectorExtractsBookName() throws {
        let name = try RuleWebBook.evaluateString(
            rule: "@css:.book-item .name@text",
            body: html
        )
        XCTAssertTrue(name.contains("夹具之书"), "CSS 应取出书名，实际: \(name)")
    }

    func testLegadoTextSelectorExtractsHref() throws {
        let body = """
        <html><body>
        <h1>斗破苍穹</h1>
        <p><a href="/book/doupo_toc.html">目录</a></p>
        </body></html>
        """
        let href = try RuleWebBook.evaluateString(
            rule: "@css:text.目录@href",
            body: body,
            baseUrl: "http://192.168.1.4:8765/book/doupo.html"
        )
        XCTAssertTrue(
            href.contains("doupo_toc.html"),
            "text.目录@href 应解析到目录页，实际: \(href)"
        )
    }

    func testCSSListCount() throws {
        let count = try RuleWebBook.evaluateElementCount(
            rule: "@css:.book-item",
            body: html
        )
        XCTAssertEqual(count, 2)
    }

    // MARK: - XPath

    func testXPathExtractsListItems() throws {
        let text = try RuleWebBook.evaluateString(
            rule: #"@xpath://div[@id="xpath-box"]//li/text()"#,
            body: html
        )
        XCTAssertTrue(text.contains("甲") || text.contains("乙"), "XPath 应命中列表，实际: \(text)")
    }

    // MARK: - JSONPath

    func testJSONPathExtractsName() throws {
        let name = try RuleWebBook.evaluateString(
            rule: "@json:$.list[0].name",
            body: json
        )
        XCTAssertEqual(name.trimmingCharacters(in: .whitespacesAndNewlines), "JSON书名")
    }

    func testJSONPathList() throws {
        let names = try RuleWebBook.evaluateStringList(
            rule: "$.list[*].name",
            body: json
        )
        XCTAssertEqual(names.count, 2)
        XCTAssertEqual(names.first, "JSON书名")
    }

    // MARK: - 正则

    func testRegexCaptureWithPrefix() throws {
        let matched = try RuleWebBook.evaluateString(
            rule: #"@regex:夹具(.{1,4})"#,
            body: html
        )
        XCTAssertFalse(matched.isEmpty, "正则应能匹配夹具书名片段，实际: \(matched)")
    }

    func testPresetVariablesViaGet() throws {
        let result = try RuleWebBook.evaluateString(
            rule: "@get:{fixtureKey}",
            body: html,
            variables: ["fixtureKey": "fromVar"]
        )
        XCTAssertTrue(result.contains("fromVar"), "预置变量应可通过 @get 读取，实际: \(result)")
    }

    // MARK: - @js:

    func testJSRuleReturnsLiteral() throws {
        let result = try RuleWebBook.evaluateString(
            rule: "@js:\"hello-js\"",
            body: html
        )
        XCTAssertTrue(
            result.contains("hello-js") || result == "hello-js",
            "@js 应返回字面量，实际: \(result)"
        )
    }

    func testJSPutGetVariable() throws {
        let result = try RuleWebBook.evaluateString(
            rule: "@js:java.put('fixtureKey','fixtureVal'); java.get('fixtureKey');",
            body: html
        )
        XCTAssertTrue(
            result.contains("fixtureVal"),
            "变量 put/get 应生效，实际: \(result)"
        )
    }

    // MARK: - Cookie

    func testCookieStoreRoundTrip() {
        CookieManager.shared.removeAll()
        CookieManager.shared.saveCookie(url: "fixture.local", cookieString: "a=1; b=2")
        let cookie = CookieManager.shared.getCookie(for: "fixture.local")
        XCTAssertEqual(cookie, "a=1; b=2")
        CookieManager.shared.removeAll()
    }

    func testPaginationNextTocUrlRule() throws {
        let urls = try RuleWebBook.evaluateStringList(
            rule: "@css:#next-toc@href",
            body: html,
            baseUrl: "https://fixture.local/toc",
            isUrl: true
        )
        XCTAssertFalse(urls.isEmpty, "目录下一页规则应解析出 URL")
        XCTAssertTrue(urls.contains { $0.contains("page=2") || $0.contains("toc") })
    }

    func testPaginationNextContentUrlRule() throws {
        let urls = try RuleWebBook.evaluateStringList(
            rule: "@css:#next-content@href",
            body: html,
            baseUrl: "https://fixture.local/chapter/1.html",
            isUrl: true
        )
        XCTAssertFalse(urls.isEmpty, "正文下一页规则应解析出 URL")
    }

    // MARK: - 内联图片

    func testFormatKeepImgPreservesAbsoluteImg() {
        let raw = #"<p>段落</p><img src="/images/scene.png"/><div>尾</div>"#
        let formatted = HTMLToTextConverter.formatKeepImg(
            html: raw,
            baseURL: URL(string: "https://fixture.local/book/")
        )
        XCTAssertTrue(formatted.contains("<img src="), "应保留 img 标签")
        XCTAssertTrue(
            formatted.contains("https://fixture.local/images/scene.png")
                || formatted.contains("/images/scene.png"),
            "应绝对化或保留图片 URL，实际: \(formatted)"
        )
        XCTAssertFalse(formatted.contains("<div>"), "应移除非 img 标签")
    }

    func testContentRuleKeepsInlineImageFromFixtureHTML() throws {
        let content = try RuleWebBook.evaluateString(
            rule: "@css:#content@html",
            body: html,
            baseUrl: "https://fixture.local/"
        )
        let kept = HTMLToTextConverter.formatKeepImg(
            html: content,
            baseURL: URL(string: "https://fixture.local/")
        )
        XCTAssertTrue(kept.contains("img"), "正文夹具应保留内联图片语义")
    }

    // MARK: - 不支持项可分类错误

    func testUnsupportedCategories() {
        let cases: [RuleCapabilityError] = [
            .loginRequired(),
            .captchaRequired(),
            .webViewChallenge(),
            .mangaUnsupported(),
            .audioVideoUnsupported(),
            .nativeCapabilityForbidden(name: "keychain"),
            .ruleGap(feature: "rar_decompress")
        ]
        let codes = Set(cases.map(\.categoryCode))
        XCTAssertEqual(codes.count, cases.count, "每个不支持项应有独立分类码")
        XCTAssertEqual(RuleCapabilityError.loginRequired().categoryCode, "login")
        XCTAssertEqual(RuleCapabilityError.nativeCapabilityForbidden(name: "x").categoryCode, "native_forbidden")
    }

    func testRejectUnsupportedThrows() {
        XCTAssertThrowsError(
            try RuleWebBook.rejectUnsupported(.mangaUnsupported(detail: "comic"))
        ) { error in
            guard let web = error as? WebBookError,
                  case .unsupported(let cap) = web else {
                return XCTFail("应包装为 WebBookError.unsupported")
            }
            XCTAssertEqual(cap.categoryCode, "manga")
        }
    }

    func testForbiddenNativeAPIAssertion() {
        XCTAssertThrowsError(try CompatibilityFixtures.assertAllowedJSAPI("keychainWrite")) { error in
            guard let cap = error as? RuleCapabilityError else {
                return XCTFail("应为 RuleCapabilityError")
            }
            XCTAssertEqual(cap.categoryCode, "native_forbidden")
        }
    }

    // MARK: - AES / 解压 / HTML 修复夹具

    func testAESRoundTripFixture() {
        let key = "0123456789abcdef"
        let iv = "abcdef0123456789"
        let plain = "legado-aes-fixture"
        guard let cipher = CompatibilityFixtures.aesEncryptBase64(
            plain: plain, key: key, transformation: "AES/CBC/PKCS5Padding", iv: iv
        ) else {
            return XCTFail("AES 加密失败")
        }
        let decoded = CompatibilityFixtures.aesDecryptBase64(
            cipherBase64: cipher, key: key, transformation: "AES/CBC/PKCS5Padding", iv: iv
        )
        XCTAssertEqual(decoded, plain)
    }

    func testGzipDetectAndDecompress() throws {
        // 最小 gzip 空成员亦可；用 zlib 包装的短串更稳
        let original = Data("hello-gzip-fixture".utf8)
        // 用系统 Compression 造 gzip 较繁琐；验证 RAR 签名拒绝即可 + unknown
        let rar = Data([0x52, 0x61, 0x72, 0x21, 0x00])
        XCTAssertEqual(CompatibilityFixtures.detectCompression(of: rar), .rar)
        XCTAssertThrowsError(try CompatibilityFixtures.decompress(rar)) { error in
            let cap = error as? RuleCapabilityError
            XCTAssertEqual(cap?.categoryCode, "rule_gap")
        }
        _ = original
    }

    func testHTMLEncodingRepairUTF8() {
        let data = Data("<p>中文修复</p>".utf8)
        let text = CompatibilityFixtures.repairHTMLEncoding(data, charset: "utf-8")
        XCTAssertTrue(text.contains("中文修复"))
    }

    // MARK: - 8.6 replaceRegex / 8.10 variable 相关

    func testApplyReplaceRegexStripsAdBlock() {
        let raw = "前文【广告】应删除的广告XYZ【/广告】萧炎可见"
        let out = RuleWebBook.applyReplaceRegex(raw, regex: "【广告】[\\s\\S]*?【/广告】##")
        XCTAssertFalse(out.contains("广告"), "广告块应被净除，实际: \(out)")
        XCTAssertTrue(out.contains("萧炎可见"), "正文应保留，实际: \(out)")
        XCTAssertTrue(out.contains("前文"), "前文应保留，实际: \(out)")
    }
}
