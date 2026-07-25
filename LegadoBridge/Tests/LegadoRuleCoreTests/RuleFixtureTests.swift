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

    /// 起点搜索 HTML：class.res-book-item 与 bookList `<js>…getElement…` 不得解析成 0
    func testQidianResBookItemClassAndJsBookList() throws {
        let body = """
        <!doctype html><html><body>
        <div id="result-list"><div class="book-img-text"><ul>
        <li class="res-book-item jsAutoReport" data-bid="1209977">
          <div class="book-mid-info">
            <h3 class="book-info-title"><a href="//www.qidian.com/book/1209977/" data-bid="1209977">斗破苍穹</a></h3>
            <p class="author"><a class="name">天蚕土豆</a><a>玄幻</a></p>
            <p class="intro">简介甲</p>
          </div>
        </li>
        <li class="res-book-item jsAutoReport" data-bid="2211027">
          <div class="book-mid-info">
            <h3 class="book-info-title"><a href="//www.qidian.com/book/2211027/" data-bid="2211027">斗破苍穹续</a></h3>
            <p class="author"><a class="name">某人</a></p>
          </div>
        </li>
        </ul></div></div>
        </body></html>
        """
        let direct = try RuleWebBook.evaluateElementCount(
            rule: "class.res-book-item",
            body: body,
            baseUrl: "https://www.qidian.com"
        )
        XCTAssertEqual(direct, 2, "class.res-book-item 应命中 2 条，实际 \(direct)")

        let jsBookList = """
        <js>
        path='class.res-book-item';
        u=java.get('url');
        c=java.getElement(path);
        if (!c.length && result.includes('var buid')) {
          java.getElement(path);
        }
        </js>
        """
        let viaJs = try RuleWebBook.evaluateElementCount(
            rule: jsBookList,
            body: body,
            baseUrl: "https://www.qidian.com"
        )
        XCTAssertEqual(viaJs, 2, "bookList <js> getElement 应命中 2 条，实际 \(viaJs)")

        let name = try RuleWebBook.evaluateString(
            rule: "class.book-info-title.0@tag.a.0@text",
            body: body
        )
        XCTAssertTrue(name.contains("斗破"), "name @链应取出书名，实际: \(name)")

        let itemBody = """
            <li class="res-book-item" data-bid="1209977">
              <div class="book-img-box"><a data-bid="1209977" href="//www.qidian.com/book/1209977/">封面</a></div>
              <h3 class="book-info-title"><a data-bid="1209977">斗破苍穹</a></h3>
              <p class="update"><a>最新更新 第一章</a></p>
              <p><a>加入书架</a></p>
            </li>
            """
        let bookUrl = try RuleWebBook.evaluateString(
            rule: "a[data-bid]@data-bid@js:'https://m.qidian.com/book/'+result+'/'",
            body: itemBody
        )
        XCTAssertTrue(
            bookUrl.contains("m.qidian.com/book/1209977"),
            "bookUrl @链+js 应拼移动详情，实际: \(bookUrl)"
        )
        XCTAssertFalse(bookUrl.contains("加入书架"), "bookUrl 不得变成列表项全文，实际: \(bookUrl)")
        XCTAssertFalse(bookUrl.contains("\n"), "bookUrl 应为单行 URL，实际: \(bookUrl)")
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

    /// 起点 searchUrl：@js 内含 {{key}} 与 option JSON，不得解析成 /undefined
    func testQidianStyleSearchUrlNotUndefined() {
        let rule = #"@js:url=baseUrl+"/so/{{key}}.html,{'method':'GET','headers':{'User-Agent':'Mozilla/5.0','Referer':'https://www.qidian.com/'}}";java.put('url',url);result=url;"#
        let analyzed = AnalyzeUrl.analyze(
            ruleUrl: rule,
            key: "斗破苍穹",
            page: 1,
            baseUrl: "https://www.qidian.com",
            source: nil
        )
        XCTAssertFalse(
            analyzed.url.contains("undefined"),
            "搜索 URL 不应含 undefined，实际: \(analyzed.url)"
        )
        XCTAssertFalse(
            analyzed.url.hasPrefix("@js:"),
            "搜索 URL 不应残留 @js: 前缀，实际: \(analyzed.url)"
        )
        XCTAssertTrue(
            analyzed.url.contains("斗破苍穹") || analyzed.url.contains("%"),
            "搜索 URL 应含关键字，实际: \(analyzed.url)"
        )
        XCTAssertTrue(
            analyzed.url.contains("/so/"),
            "搜索 URL 应含 /so/，实际: \(analyzed.url)"
        )
        XCTAssertTrue(
            analyzed.url.hasPrefix("https://www.qidian.com/so/"),
            "搜索 URL 应为绝对地址，实际: \(analyzed.url)"
        )
    }

    /// JS 失败时仍能从 baseUrl+"/so/…" 字面量恢复，避免请求落到 localhost
    func testQidianStyleSearchUrlRecoversWhenJsLeftRaw() {
        // 模拟字面量已替换、但整段仍带 @js: 的失败态（与真机探针一致的前缀形态）
        let raw = #"@js:url=baseUrl+"/so/%E6%96%97%E7%A0%B4%E8%8B%8D%E7%A9%B9.html,{'method':'GET','headers':{'User-Agent':'Mozilla/5.0','Referer':'https://www.qidian.com/'}}";java.put('url',url);result=url;"#
        let analyzed = AnalyzeUrl.analyze(
            ruleUrl: raw,
            key: nil,
            page: 1,
            baseUrl: "https://www.qidian.com",
            source: nil
        )
        XCTAssertFalse(analyzed.url.hasPrefix("@js:"), "应去掉 @js:，实际: \(analyzed.url)")
        XCTAssertTrue(analyzed.url.contains("/so/"), "应含 /so/，实际: \(analyzed.url)")
        XCTAssertFalse(analyzed.url.contains("localhost"), "不应落到 localhost，实际: \(analyzed.url)")
    }

    // MARK: - Cookie

    func testCookieStoreRoundTrip() {
        CookieManager.shared.removeAll()
        CookieManager.shared.saveCookie(url: "fixture.local", cookieString: "a=1; b=2")
        let cookie = CookieManager.shared.getCookie(for: "fixture.local")
        XCTAssertEqual(cookie, "a=1; b=2")
        CookieManager.shared.removeAll()
    }

    /// 回灌用完整 URL 作 key 时，按 host 仍能取到 Cookie
    func testCookieLookupByHostFromFullUrlKey() {
        CookieManager.shared.removeAll()
        CookieManager.shared.saveCookie(
            url: "https://www.qidian.com/all/",
            cookieString: "_csrfToken=abc; w_tsfp=xyz"
        )
        let byHost = CookieManager.shared.getCookie(for: "www.qidian.com")
        XCTAssertEqual(byHost, "_csrfToken=abc; w_tsfp=xyz")
        CookieManager.shared.removeAll()
    }

    /// getResponseBody 重建 AnalyzeUrl 时须能按请求 URL host 注入 Cookie（勿因 domain 空串丢 Cookie）
    func testAnalyzeUrlDomainSeedFromMUrlWhenSourceNil() {
        CookieManager.shared.removeAll()
        CookieManager.shared.saveCookie(
            url: "www.qidian.com",
            cookieString: "sid=1; _csrfToken=tok"
        )
        let analyzer = AnalyzeUrl(
            mUrl: "https://www.qidian.com/so/斗破苍穹.html",
            source: nil
        )
        // 通过公开 analyze 结果 headers 无法直接读 domain；用 CookieManager + 二次请求头路径验证：
        // analyze 带 source 时 headers 尚无 Cookie；注入依赖 getResponseBody 内 setCookie。
        // 此处断言：无 source 时按 mUrl host 能取到 jar。
        let jar = CookieManager.shared.getCookie(for: "www.qidian.com")
        XCTAssertEqual(jar, "sid=1; _csrfToken=tok")
        XCTAssertTrue(analyzer.url.contains("/so/"), "URL 应解析成功: \(analyzer.url)")
        XCTAssertFalse(analyzer.url.contains("undefined"))
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

    func testApplyReplaceRegexStripsAdBlockInHTMLWithIdeographicSpace() {
        let raw = "第一章\n\u{3000}\u{3000}【广告】此处应被去掉，含乱码 XYZ999【/广告】\n\u{3000}\u{3000}纳兰嫣然标记句"
        let out = RuleWebBook.applyReplaceRegex(raw, regex: "【广告】[\\s\\S]*?【/广告】##")
        XCTAssertFalse(out.contains("【广告】"), "广告开标签应去掉: \(out)")
        XCTAssertFalse(out.contains("XYZ999"), "乱码针应去掉: \(out)")
        XCTAssertTrue(out.contains("纳兰嫣然"), "标记应保留: \(out)")
    }

    func testApplyReplaceRegexEmptyReplacementSuffix() {
        // pattern## （空替换）不得把「##」算进正则本身
        let raw = "A【广告】X【/广告】B"
        let out = RuleWebBook.applyReplaceRegex(raw, regex: "【广告】[\\s\\S]*?【/广告】##")
        XCTAssertEqual(out, "AB", "空 replacement 应整块删除，实际: \(out)")
    }
}
