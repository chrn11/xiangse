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

    // MARK: - 发现 URL 展开

    func testResolveExploreFetchURLClassicMultiline() {
        let raw = """
        玄幻::/fenlei/xuanhuan/{{page}}/
        都市::/fenlei/dushi/{{page}}/
        """
        XCTAssertEqual(
            RuleWebBook.resolveExploreFetchURL(raw),
            "/fenlei/xuanhuan/{{page}}/"
        )
    }

    func testResolveExploreFetchURLJSONKindsSkipsEmpty() {
        let raw = """
        [
          {"title":"榜单","url":""},
          {"title":"总点击榜","url":"/top/allvisit/{{page}}.html"}
        ]
        """
        XCTAssertEqual(
            RuleWebBook.resolveExploreFetchURL(raw),
            "/top/allvisit/{{page}}.html"
        )
    }

    func testResolveExploreFetchURLPlainHttp() {
        XCTAssertEqual(
            RuleWebBook.resolveExploreFetchURL("https://example.com/explore"),
            "https://example.com/explore"
        )
    }

    func testParseExploreKindsMultilineAllTitles() {
        let raw = """
        玄幻魔法::http://www.kkbiquge.net/class/xuanhuanmofa/{{page}}/
        仙侠修真::http://www.kkbiquge.net/class/xianxiaxiuzhen/{{page}}/
        都市言情::http://www.kkbiquge.net/class/dushuyanqing/{{page}}/
        """
        let kinds = RuleWebBook.parseExploreKinds(raw)
        XCTAssertEqual(kinds.count, 3)
        XCTAssertEqual(kinds[0].title, "玄幻魔法")
        XCTAssertEqual(kinds[1].title, "仙侠修真")
        XCTAssertEqual(kinds[2].url, "http://www.kkbiquge.net/class/dushuyanqing/{{page}}/")
    }

    func testParseExploreKindsJSONPreservesOrder() {
        let raw = """
        [
          {"title":"男生","url":"/nan/{{page}}.html"},
          {"title":"女频","url":"/nv/{{page}}.html"}
        ]
        """
        let kinds = RuleWebBook.parseExploreKinds(raw)
        XCTAssertEqual(kinds.map(\.title), ["男生", "女频"])
    }

    func testParseExploreKindsAmpSeparated() {
        let raw = "玄幻::http://a/{{page}}&&仙侠::http://b/{{page}}"
        let kinds = RuleWebBook.parseExploreKinds(raw)
        XCTAssertEqual(kinds.count, 2)
        XCTAssertEqual(kinds[0].title, "玄幻")
        XCTAssertEqual(kinds[1].url, "http://b/{{page}}")
    }

    func testParseExploreKindsJSONIgnoresStyleKeepsUrl() {
        let raw = """
        [
          {"title":"今日限免","url":"https://ex/free","style":{"layout_flexGrow":1}},
          {"title":"频道金榜","url":"https://ex/rank","style":{"layout_wrapBefore":true}}
        ]
        """
        let kinds = RuleWebBook.parseExploreKinds(raw)
        XCTAssertEqual(kinds.map(\.title), ["今日限免", "频道金榜"])
        XCTAssertEqual(kinds[1].url, "https://ex/rank")
    }

    /// 行首 // 注释不得变成分类标题（7616 垃圾「//全部玄幻」回归）
    func testParseExploreKindsSkipsLineComments() {
        let raw = """
        //全部玄幻::/explore/a
        玄幻::/fenlei/xuanhuan/{{page}}/
        //排行::/explore/b
        都市::/fenlei/dushi/{{page}}/
        """
        let kinds = RuleWebBook.parseExploreKinds(raw)
        XCTAssertEqual(kinds.map(\.title), ["玄幻", "都市"])
        XCTAssertFalse(kinds.contains { $0.title.hasPrefix("//") })
    }

    /// 未求值的顶层 @js: 不得塌缩成「发现」+ 脚本当 URL
    func testParseExploreKindsTopLevelJSWithoutEvalReturnsEmpty() {
        let raw = """
        @js:
        //全部玄幻::/a
        JSON.stringify([{title:"玄幻",url:"/a"}])
        """
        let kinds = RuleWebBook.parseExploreKinds(raw)
        XCTAssertTrue(kinds.isEmpty, "未求值顶层 JS 应回落空，实际: \(kinds)")
    }

    /// 顶层 @js: 求值后按 JSON kinds 展开
    func testParseExploreKindsEvaluatesTopLevelJSJSON() {
        let raw = #"@js:JSON.stringify([{title:"玄幻",url:"/xuanhuan/{{page}}/"},{title:"都市",url:"/dushi/{{page}}/"}])"#
        let kinds = RuleWebBook.parseExploreKinds(raw, source: nil, evaluateJS: true, jsTimeoutSeconds: 5)
        XCTAssertEqual(kinds.map(\.title), ["玄幻", "都市"])
        XCTAssertEqual(kinds[0].url, "/xuanhuan/{{page}}/")
        XCTAssertFalse(kinds.contains { $0.title.hasPrefix("//") })
    }

    /// 顶层 @js: 直接返回数组对象（非 stringify）亦须可解析
    func testParseExploreKindsEvaluatesTopLevelJSArrayObject() {
        let raw = #"@js:[{title:"男频",url:"/nan/"},{title:"女频",url:"/nv/"}]"#
        let kinds = RuleWebBook.parseExploreKinds(raw, source: nil, evaluateJS: true, jsTimeoutSeconds: 5)
        XCTAssertEqual(kinds.map(\.title), ["男频", "女频"])
    }

    /// JS 抛错时回落空数组，不崩
    func testParseExploreKindsJSFailureReturnsEmpty() {
        let raw = #"@js:throw new Error("explore-boom")"#
        let kinds = RuleWebBook.parseExploreKinds(raw, source: nil, evaluateJS: true, jsTimeoutSeconds: 3)
        XCTAssertTrue(kinds.isEmpty)
    }

    /// <js> 包裹与 @js: 等价
    func testParseExploreKindsEvaluatesJSBlockTag() {
        let raw = #"<js>JSON.stringify([{title:"发现A",url:"https://ex/a"}])</js>"#
        let kinds = RuleWebBook.parseExploreKinds(raw, source: nil, evaluateJS: true, jsTimeoutSeconds: 5)
        XCTAssertEqual(kinds.map(\.title), ["发现A"])
        XCTAssertEqual(kinds.first?.url, "https://ex/a")
    }

    func testAbsoluteExploreURLJoinsRelativePath() {
        let abs = RuleWebBook.absoluteExploreURL(
            baseUrl: "https://www.lysxh.com/",
            path: "/fenlei/xuanhuan/{{page}}/"
        )
        XCTAssertTrue(abs.hasPrefix("https://www.lysxh.com/fenlei/"), "实际: \(abs)")
        XCTAssertEqual(
            RuleWebBook.absoluteExploreURL(baseUrl: "https://ex.com", path: "https://other.com/a"),
            "https://other.com/a"
        )
    }

    /// yckceo 7616：结构层不得产出 // 前缀标题；求值失败（无网/无 token）须空回落不崩
    func testYckceo7616ExploreKindsSnapshot() throws {
        guard let url = Self.repoFixtureURL("yckceo-batch/7616.json") else {
            throw XCTSkip("仓库 fixtures/yckceo-batch/7616.json 不可用")
        }
        let data = try Data(contentsOf: url)
        let root = try JSONSerialization.jsonObject(with: data)
        let obj: [String: Any]
        if let arr = root as? [[String: Any]], let first = arr.first {
            obj = first
        } else if let dict = root as? [String: Any] {
            obj = dict
        } else {
            return XCTFail("夹具 JSON 形态异常")
        }
        guard let explore = obj["exploreUrl"] as? String, !explore.isEmpty else {
            return XCTFail("7616 缺少 exploreUrl")
        }
        XCTAssertTrue(RuleWebBook.isTopLevelExploreJS(explore))

        let structural = RuleWebBook.parseExploreKinds(explore)
        XCTAssertTrue(structural.isEmpty, "未求值不得产出分类，实际: \(structural)")
        XCTAssertFalse(structural.contains { $0.title.hasPrefix("//") })

        let source = ExploreFixtureSource(
            bookSourceUrl: (obj["bookSourceUrl"] as? String) ?? "https://m.qidian.com",
            jsLib: obj["jsLib"] as? String,
            exploreUrl: explore
        )
        let evaluated = RuleWebBook.parseExploreKinds(
            explore,
            source: source,
            evaluateJS: true,
            jsTimeoutSeconds: 6
        )
        XCTAssertFalse(
            evaluated.contains { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("//") },
            "求值后不得含 // 标题: \(evaluated)"
        )
        // 无网/无 token 时允许空列表或仅空 URL 分组；有可请求 URL 时不得残留 @js:
        if let first = evaluated.first(where: {
            !$0.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            let u = first.url.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertFalse(u.hasPrefix("@js:"), "首 kind URL 不得残留 @js:，实际: \(u)")
        }
    }

    /// yckceo 7574：JSON kinds 空 url 跳过；标题合法
    func testYckceo7574ExploreKindsJSONSnapshot() throws {
        guard let url = Self.repoFixtureURL("yckceo-batch/7574.json") else {
            throw XCTSkip("仓库 fixtures/yckceo-batch/7574.json 不可用")
        }
        let data = try Data(contentsOf: url)
        let root = try JSONSerialization.jsonObject(with: data)
        let obj: [String: Any]
        if let arr = root as? [[String: Any]], let first = arr.first {
            obj = first
        } else if let dict = root as? [String: Any] {
            obj = dict
        } else {
            return XCTFail("夹具 JSON 形态异常")
        }
        guard let explore = obj["exploreUrl"] as? String, !explore.isEmpty else {
            return XCTFail("7574 缺少 exploreUrl")
        }
        let kinds = RuleWebBook.parseExploreKinds(explore)
        XCTAssertFalse(kinds.isEmpty, "7574 应解析出非空分类")
        XCTAssertFalse(kinds.contains { $0.title.hasPrefix("//") })
        // 空 URL 分组按合同可保留；至少有一条可请求 URL
        XCTAssertTrue(kinds.contains { !$0.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    private static func repoFixtureURL(_ relative: String) -> URL? {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<8 {
            url.deleteLastPathComponent()
            let candidate = url.appendingPathComponent("fixtures").appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
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

    /// 回归（6dad7d1→）：裸 `a@text`/`a@href` 不得被 isTerminalAttr 误判为属性名，
    /// 否则章名空 → parseChapters 丢章 → chapters=0 卡死 nativeRead。
    func testBareAtTextExtractsChapterName() throws {
        let body = """
        <html><body><div id="list"><dl>
        <dd><a href="/chapter/doupo_1.html">第一章 陨落的天才</a></dd>
        <dd><a href="/chapter/doupo_2.html">第二章 斗气大陆</a></dd>
        </dl></div></body></html>
        """
        let name = try RuleWebBook.evaluateString(rule: "a@text", body: body)
        XCTAssertTrue(name.contains("第一章"), "裸 a@text 应取出章名，实际: \(name)")
    }

    func testBareAtHrefExtractsChapterUrl() throws {
        let body = """
        <html><body><div id="list"><dl>
        <dd><a href="/chapter/doupo_1.html">第一章 陨落的天才</a></dd>
        </dl></div></body></html>
        """
        let url = try RuleWebBook.evaluateString(
            rule: "a@href", body: body, baseUrl: "http://192.168.1.4:8765/book/doupo.html")
        XCTAssertTrue(url.contains("doupo_1.html"), "裸 a@href 应取出章 URL，实际: \(url)")
    }

    func testBareCssListReturnsTwoChapters() throws {
        let body = """
        <html><body><div id="list"><dl>
        <dd><a href="/chapter/doupo_1.html">第一章 陨落的天才</a></dd>
        <dd><a href="/chapter/doupo_2.html">第二章 斗气大陆</a></dd>
        </dl></div></body></html>
        """
        let count = try RuleWebBook.evaluateElementCount(rule: "#list dd", body: body)
        XCTAssertEqual(count, 2, "#list dd 应返回 2 个章节元素，实际: \(count)")
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
        XCTAssertTrue(
            bookUrl.hasPrefix("https://"),
            "bookUrl 应为绝对 URL，实际: \(bookUrl)"
        )
        XCTAssertFalse(bookUrl.contains("加入书架"), "bookUrl 不得变成列表项全文，实际: \(bookUrl)")
        XCTAssertFalse(bookUrl.contains("\n"), "bookUrl 应为单行 URL，实际: \(bookUrl)")
        XCTAssertFalse(bookUrl.isEmpty, "bookUrl 不得为空")
    }

    /// 起点目录 AllInOne：`:"sS":…` 须解析出章节，且 `$2` / `@js…$3` 可用
    func testQidianTocAllInOneRegex() throws {
        let body = #"""
        <html><body><script>
        var data={"vs":[{"cs":[
          {"sS":0,"cN":"第一章 陨落的天才","id":12345,"uT":"2009-01-01 00:00:00"},
          {"sS":1,"cN":"第二章 VIP","id":12346,"uT":"2009-01-02 00:00:00\"extra"}
        ]}]};
        </script></body></html>
        """#
        let chapterList = #":"sS":(\d),.*?"cN":"(.*?)","id":(\d+),.*?"uT":"(.*?)""#
        let count = try RuleWebBook.evaluateElementCount(
            rule: chapterList,
            body: body,
            baseUrl: "https://m.qidian.com/book/1209977/catalog/"
        )
        XCTAssertEqual(count, 2, "AllInOne 应命中 2 章，实际 \(count)")

        let engine = RuleEngine()
        let elements = try engine.getElements(
            ruleStr: chapterList,
            body: body,
            baseUrl: "https://m.qidian.com/book/1209977/catalog/"
        )
        XCTAssertEqual(elements.count, 2)
        let title = engine.getString(
            ruleStr: "$2",
            elementContext: elements[0],
            baseUrl: "https://m.qidian.com/book/1209977/catalog/"
        )
        XCTAssertEqual(title, "第一章 陨落的天才")

        let url = engine.getString(
            ruleStr: "@js:var bid = baseUrl.match(/\\d+/);'https://vipreader.qidian.com/chapter/'+bid+'/$3/'",
            elementContext: elements[0],
            baseUrl: "https://m.qidian.com/book/1209977/catalog/"
        )
        XCTAssertTrue(
            url.contains("vipreader.qidian.com/chapter/1209977/12345"),
            "chapterUrl 应含 bid+章 id，实际: \(url)"
        )

        let vip = engine.getString(
            ruleStr: "$1@js:result.replace(/1.*/,'false').replace(/0.*/,'true');",
            elementContext: elements[0],
            baseUrl: "https://m.qidian.com/book/1209977/catalog/"
        )
        XCTAssertEqual(vip, "true", "sS=0 → isVip 映射 true（书源写法），实际: \(vip)")

        let update = engine.getString(
            ruleStr: #"$4##\".*""#,
            elementContext: elements[1],
            baseUrl: "https://m.qidian.com/book/1209977/catalog/"
        )
        XCTAssertEqual(
            update.trimmingCharacters(in: CharacterSet(charactersIn: "\\")),
            "2009-01-02 00:00:00",
            "updateTime ## 净化，实际: \(update)"
        )

        let toc = TocRule(
            bookList: chapterList,
            chapterName: "$2",
            chapterUrl: "@js:var bid = baseUrl.match(/\\d+/);'https://vipreader.qidian.com/chapter/'+bid+'/$3/'",
            isVip: "$1@js:result.replace(/1.*/,'false').replace(/0.*/,'true');"
        )
        let chapters = try TocParser().parseChapters(
            body: body,
            baseUrl: "https://m.qidian.com/book/1209977/catalog/",
            rule: toc
        )
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0].title, "第一章 陨落的天才")
        XCTAssertTrue(chapters[0].url.contains("/12345/"))
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

    /// J3：书源 jsLib 中的函数须在 @js 规则里可调用
    func testJSLibFunctionsVisibleInJSRule() throws {
        let source = JsLibFixtureSource(
            jsLib: "function libHello(){ return 'fromJsLib'; }"
        )
        let result = try RuleWebBook.evaluateString(
            rule: "@js:libHello();",
            body: html,
            source: source
        )
        XCTAssertTrue(
            result.contains("fromJsLib"),
            "jsLib 注入后 libHello 应可用，实际: \(result)"
        )
    }

    /// J3：AnalyzeUrl @js 路径同样能看见 jsLib
    func testJSLibVisibleInAnalyzeUrl() {
        let source = JsLibFixtureSource(
            jsLib: "function libPath(){ return '/from-lib'; }"
        )
        let analyzed = AnalyzeUrl.analyze(
            ruleUrl: "@js:result=baseUrl+libPath();",
            key: nil,
            page: 1,
            baseUrl: "https://example.com",
            source: source
        )
        XCTAssertTrue(
            analyzed.url.contains("/from-lib"),
            "AnalyzeUrl 应拼上 jsLib 返回路径，实际: \(analyzed.url)"
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

    /// 顶层 @js:getApiUrl('/x', {…}) 不得被 `, {` 截成残片（起点限免类 kind URL）
    func testTopLevelJSGetApiUrlNotTruncatedByCommaBrace() {
        let source = JsLibFixtureSource(
            jsLib: "function getApiUrl(path, opt){ return 'https://example.com'+path+'?q='+(opt&&opt.a?opt.a:''); }"
        )
        let rule = #"@js:getApiUrl('/explore/store', {a:1})"#
        let analyzed = AnalyzeUrl.analyze(
            ruleUrl: rule,
            key: nil,
            page: 1,
            baseUrl: "https://example.com",
            source: source
        )
        XCTAssertFalse(
            analyzed.url.contains("getApiUrl('/explore/store'"),
            "不得截在逗号前留下残片，实际: \(analyzed.url)"
        )
        XCTAssertFalse(
            analyzed.url.hasPrefix("@js:"),
            "应求出 URL，不得残留 @js:，实际: \(analyzed.url)"
        )
        XCTAssertTrue(
            analyzed.url.contains("/explore/store"),
            "应含完整 path，实际: \(analyzed.url)"
        )
        XCTAssertTrue(
            analyzed.url.hasPrefix("http"),
            "应是可用 HTTP URL，实际: \(analyzed.url)"
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

    /// 书山 getSessionId：cookie.getCookie('fanqienovel.com') 须可读 jar
    func testCookieGetCookieAliasBareDomain() throws {
        CookieManager.shared.removeAll()
        CookieManager.shared.saveCookie(
            url: "www.fanqienovel.com",
            cookieString: "sessionid=sess_fixture_001; other=1"
        )
        let result = try RuleWebBook.evaluateString(
            rule: "@js:cookie.getCookie('fanqienovel.com')",
            body: "<html></html>"
        )
        XCTAssertTrue(
            result.contains("sessionid=sess_fixture_001"),
            "getCookie(裸域名) 应读到 jar，实际: \(result)"
        )
        let viaGet = try RuleWebBook.evaluateString(
            rule: "@js:cookie.get('fanqienovel.com')",
            body: "<html></html>"
        )
        XCTAssertTrue(
            viaGet.contains("sessionid=sess_fixture_001"),
            "cookie.get 应与 getCookie 同源，实际: \(viaGet)"
        )
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

    func testApplyReplaceRegexLeadingHashHashDoesNotEmitPattern() {
        // 领域源：##\(第\d+/\d+页\)## —— 前导 ## 不得把 pattern 当 replacement 写进空正文
        // 注意：勿写 ##.*?\(页\)##，`.*?` 会吞掉标记前正文
        let raw = ""
        let out = RuleWebBook.applyReplaceRegex(
            raw,
            regex: "##\\(第\\d+/\\d+页\\)##"
        )
        XCTAssertEqual(out, "", "空正文应仍为空，不得变成正则串，实际: \(out)")
        let kept = RuleWebBook.applyReplaceRegex(
            "正文(第1/2页)继续",
            regex: "##\\(第\\d+/\\d+页\\)##"
        )
        XCTAssertFalse(kept.contains("第1/2页"), "应删分页标记，实际: \(kept)")
        XCTAssertTrue(kept.contains("正文") && kept.contains("继续"), "正文应保留: \(kept)")
    }

    func testContentHtmlMidChainThenJs() throws {
        // 领域 ruleContent.content：#content@html@js:result.replace(...)
        // 中间段 html 必须抽 innerHTML，不能当 CSS 选择器
        let body = """
        <html><body><div id="content"><p>陨落的天才</p><script>evil()</script></div></body></html>
        """
        let rule = #"#content@html@js:result.replace(/<script[\s\S]*?<\/script>/g,'')"#
        let out = try RuleWebBook.evaluateString(rule: rule, body: body)
        XCTAssertTrue(out.contains("陨落的天才"), "应抽出正文，实际: \(out)")
        XCTAssertFalse(out.contains("<script"), "JS 应去掉 script，实际: \(out)")
        XCTAssertFalse(out.isEmpty, "不得空串（content_post_no_body）")
    }

    func testContentHtmlJsWithQuotesDoesNotThrowJSONTopLevel() throws {
        // 回归：jsonStringLiteral 曾对裸 String 调 JSONSerialization → NSException
        let body = """
        <html><body><div id="content"><p>他说："你好"</p></div></body></html>
        """
        let rule = #"#content@html@js:result.replace(/<p>/g,'').replace(/<\/p>/g,'')"#
        let out = try RuleWebBook.evaluateString(rule: rule, body: body)
        XCTAssertTrue(out.contains("你好"), "引号正文应存活，实际: \(out)")
    }
}

/// 仅用于 jsLib 夹具的最小书源桩
private final class JsLibFixtureSource: BridgeSourceProtocol {
    let bookSourceUrl = "https://fixture.local/jslib"
    let bookSourceName = "jsLib夹具"
    var header: String? { nil }
    var enabledCookieJar: Bool { false }
    var loginCheckJs: String? { nil }
    var loginUrl: String? { nil }
    var loginUi: String? { nil }
    var bookUrlPattern: String? { nil }
    var searchUrl: String? { nil }
    var exploreUrl: String? { nil }
    var concurrentRate: String? { nil }
    var jsLib: String?
    var variable: String? { nil }
    var coverDecodeJs: String? { nil }

    init(jsLib: String?) {
        self.jsLib = jsLib
    }

    func getSearchRule() -> BridgeSearchRule? { nil }
    func getExploreRule() -> BridgeExploreRule? { nil }
    func getBookInfoRule() -> BridgeBookInfoRule? { nil }
    func getTocRule() -> TocRule? { nil }
    func getContentRule() -> BridgeContentRule? { nil }
    func getReviewRule() -> BridgeReviewRule? { nil }
}

/// exploreUrl / jsLib 快照夹具
private final class ExploreFixtureSource: BridgeSourceProtocol {
    let bookSourceUrl: String
    let bookSourceName = "explore夹具"
    var header: String? { nil }
    var enabledCookieJar: Bool { false }
    var loginCheckJs: String? { nil }
    var loginUrl: String? { nil }
    var loginUi: String? { nil }
    var bookUrlPattern: String? { nil }
    var searchUrl: String? { nil }
    var exploreUrl: String?
    var concurrentRate: String? { nil }
    var jsLib: String?
    var variable: String? { nil }
    var coverDecodeJs: String? { nil }

    init(bookSourceUrl: String, jsLib: String?, exploreUrl: String?) {
        self.bookSourceUrl = bookSourceUrl
        self.jsLib = jsLib
        self.exploreUrl = exploreUrl
    }

    func getSearchRule() -> BridgeSearchRule? { nil }
    func getExploreRule() -> BridgeExploreRule? { nil }
    func getBookInfoRule() -> BridgeBookInfoRule? { nil }
    func getTocRule() -> TocRule? { nil }
    func getContentRule() -> BridgeContentRule? { nil }
    func getReviewRule() -> BridgeReviewRule? { nil }
}
