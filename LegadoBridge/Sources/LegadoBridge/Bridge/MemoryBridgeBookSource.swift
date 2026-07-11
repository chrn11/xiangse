import Foundation
import LegadoRuleCore

/// 内存书源 — 从 Legado JSON 构建，供 BridgeWebBook / RuleWebBook 使用
final class MemoryBridgeBookSource: BridgeSourceProtocol {
    let sourceId: String
    let bookSourceUrl: String
    let bookSourceName: String
    var header: String?
    var enabledCookieJar: Bool
    var loginCheckJs: String?
    var loginUrl: String?
    var bookUrlPattern: String?
    var searchUrl: String?
    var exploreUrl: String?
    var bookSourceGroup: String?
    var enabledExplore: Bool
    var concurrentRate: String?
    var jsLib: String?
    var variable: String?

    private var ruleSearch: BridgeSearchRule?
    private var ruleExplore: BridgeExploreRule?
    private var ruleBookInfo: BridgeBookInfoRule?
    private var ruleToc: TocRule?
    private var ruleContent: BridgeContentRule?

    init(part: BookSourcePart) {
        sourceId = part.bookSourceUrl
        bookSourceUrl = part.bookSourceUrl
        bookSourceName = part.bookSourceName
        header = part.header
        enabledCookieJar = part.enabledCookieJar ?? false
        loginCheckJs = part.loginCheckJs
        loginUrl = part.loginUrl
        bookUrlPattern = part.bookUrlPattern
        searchUrl = part.searchUrl
        exploreUrl = part.exploreUrl
        bookSourceGroup = part.bookSourceGroup
        enabledExplore = part.enabledExplore ?? true
        concurrentRate = part.concurrentRate
        jsLib = part.jsLib
        variable = part.variable
        ruleSearch = part.ruleSearch.map(Self.mapSearch)
        ruleExplore = part.ruleExplore.map(Self.mapExplore)
        ruleBookInfo = part.ruleBookInfo.map(Self.mapBookInfo)
        ruleToc = part.ruleToc.map(Self.mapToc)
        ruleContent = part.ruleContent.map(Self.mapContent)
    }

    /// 是否具备发现能力（exploreUrl 或 explore 规则）
    var supportsExplore: Bool {
        let urlOk = !(exploreUrl?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let listOk = !(ruleExplore?.exploreList?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return enabledExplore && (urlOk || listOk)
    }

    convenience init(json: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: json)
        let part = try JSONDecoder().decode(BookSourcePart.self, from: data)
        self.init(part: part)
    }

    func getSearchRule() -> BridgeSearchRule? { ruleSearch }
    func getExploreRule() -> BridgeExploreRule? { ruleExplore }
    func getBookInfoRule() -> BridgeBookInfoRule? { ruleBookInfo }
    func getTocRule() -> TocRule? { ruleToc }
    func getContentRule() -> BridgeContentRule? { ruleContent }

    private static func mapSearch(_ r: BookSourcePart.SearchRulePart) -> BridgeSearchRule {
        BridgeSearchRule(
            checkKeyWord: r.checkKeyWord, bookList: r.bookList, name: r.name,
            author: r.author, intro: r.intro, bookUrl: r.bookUrl,
            coverUrl: r.coverUrl, lastChapter: r.lastChapter,
            wordCount: r.wordCount, kind: r.kind
        )
    }

    private static func mapExplore(_ r: BookSourcePart.ExploreRulePart) -> BridgeExploreRule {
        var rule = BridgeExploreRule()
        rule.exploreList = r.bookList
        rule.name = r.name
        rule.author = r.author
        rule.intro = r.intro
        rule.kind = r.kind
        rule.bookUrl = r.bookUrl
        rule.coverUrl = r.coverUrl
        rule.lastChapter = r.lastChapter
        rule.wordCount = r.wordCount
        return rule
    }

    private static func mapBookInfo(_ r: BookSourcePart.BookInfoRulePart) -> BridgeBookInfoRule {
        BridgeBookInfoRule(
            initRule: r.initRule, name: r.name, author: r.author, intro: r.intro,
            kind: r.kind, coverUrl: r.coverUrl, tocUrl: r.tocUrl,
            lastChapter: r.lastChapter, updateTime: r.updateTime,
            wordCount: r.wordCount, canReName: r.canReName, downloadUrls: r.downloadUrls
        )
    }

    private static func mapToc(_ r: BookSourcePart.TocRulePart) -> TocRule {
        TocRule(
            preUpdateJs: nil,
            bookList: r.chapterList,
            chapterName: r.chapterName,
            chapterUrl: r.chapterUrl,
            formatJs: r.formatJs,
            isVolume: r.isVolume,
            isVip: r.isVip,
            updateTime: nil,
            nextTocUrl: r.nextTocUrl,
            isPay: r.isPay
        )
    }

    private static func mapContent(_ r: BookSourcePart.ContentRulePart) -> BridgeContentRule {
        BridgeContentRule(
            content: r.content, title: nil, nextContentUrl: r.nextContentUrl,
            webJs: r.webJs, sourceRegex: r.sourceRegex, replaceRegex: r.replaceRegex,
            imageStyle: r.imageStyle, payAction: r.payAction
        )
    }
}
