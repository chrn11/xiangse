import Foundation

struct BookSourcePart: Codable, Identifiable {
    var id: String { bookSourceUrl }

    var bookSourceUrl: String
    var bookSourceName: String
    var bookSourceGroup: String?
    var bookSourceType: Int?
    var bookUrlPattern: String?
    var header: String?
    var concurrentRate: String?
    var loginUrl: String?
    var loginUi: String?
    var loginCheckJs: String?
    var coverDecodeJs: String?
    var jsLib: String?
    var bookSourceComment: String?
    var variableComment: String?
    var lastUpdateTime: Int64?
    var respondTime: Int64?
    var weight: Int?
    var exploreUrl: String?
    var exploreScreen: String?
    var searchUrl: String?
    var enabled: Bool?
    var enabledExplore: Bool?
    var enabledCookieJar: Bool?
    var ruleSearch: SearchRulePart?
    var ruleExplore: ExploreRulePart?
    var ruleBookInfo: BookInfoRulePart?
    var ruleToc: TocRulePart?
    var ruleContent: ContentRulePart?
    var ruleReview: ReviewRulePart?
    var variable: String?

    struct SearchRulePart: Codable {
        var checkKeyWord: String?
        var bookList: String?
        var name: String?
        var author: String?
        var intro: String?
        var kind: String?
        var lastChapter: String?
        var updateTime: String?
        var bookUrl: String?
        var coverUrl: String?
        var wordCount: String?
    }

    struct ExploreRulePart: Codable {
        var bookList: String?
        var name: String?
        var author: String?
        var intro: String?
        var kind: String?
        var lastChapter: String?
        var updateTime: String?
        var bookUrl: String?
        var coverUrl: String?
        var wordCount: String?
    }

    struct BookInfoRulePart: Codable {
        var initRule: String?
        var name: String?
        var author: String?
        var intro: String?
        var kind: String?
        var lastChapter: String?
        var updateTime: String?
        var coverUrl: String?
        var tocUrl: String?
        var wordCount: String?
        var canReName: String?
        var downloadUrls: String?
    }

    struct TocRulePart: Codable {
        var chapterList: String?
        var chapterName: String?
        var chapterUrl: String?
        var formatJs: String?
        var isVolume: String?
        var isVip: String?
        var isPay: String?
        var nextTocUrl: String?
    }

    struct ContentRulePart: Codable {
        var content: String?
        var nextContentUrl: String?
        var webJs: String?
        var sourceRegex: String?
        var replaceRegex: String?
        var imageStyle: String?
        var imageDecode: String?
        var payAction: String?
    }

    struct ReviewRulePart: Codable {
        var reviewUrl: String?
        var avatarRule: String?
        var contentRule: String?
        var postUrl: String?
    }
}

struct BookSourceCheckResult {
    let sourceUrl: String
    let sourceName: String
    let isValid: Bool
    let searchSupported: Bool
    let exploreSupported: Bool
    let responseTime: TimeInterval
    let errorMessage: String?

    var statusText: String {
        if isValid {
            var features: [String] = []
            if searchSupported { features.append("搜索") }
            if exploreSupported { features.append("发现") }
            return "有效 (\(features.joined(separator: "/")))"
        }
        return "无效: \(errorMessage ?? "未知错误")"
    }
}

struct HttpTTSConfig: Codable {
    var id: Int64
    var name: String
    var url: String
    var header: String?
    var concurrentRate: String?
    var loginUrl: String?
    var loginUi: String?
    var loginCheckJs: String?
    var contentType: String?
    var enabled: Bool?

    init(id: Int64 = Int64(Date().timeIntervalSince1970 * 1000), name: String = "", url: String = "") {
        self.id = id
        self.name = name
        self.url = url
    }
}

struct DictRuleConfig: Codable {
    var name: String
    var urlRule: String
    var showRule: String?
    var enabled: Bool
    var sortNumber: Int?

    init(name: String = "", urlRule: String = "", showRule: String? = nil, enabled: Bool = true) {
        self.name = name
        self.urlRule = urlRule
        self.showRule = showRule
        self.enabled = enabled
    }
}

struct TxtTocRuleConfig: Codable {
    var name: String
    var rule: String
    var enabled: Bool
    var serialNumber: Int?

    init(name: String = "", rule: String = "", enabled: Bool = true) {
        self.name = name
        self.rule = rule
        self.enabled = enabled
    }
}

struct ReplaceRuleConfig: Codable {
    var id: Int64
    var name: String
    var group: String?
    var pattern: String
    var replacement: String
    var isRegex: Bool
    var scope: String?
    var enabled: Bool
    var order: Int
    var isDeleted: Bool

    init(id: Int64 = Int64(Date().timeIntervalSince1970 * 1000), name: String = "", pattern: String = "", replacement: String = "") {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.replacement = replacement
        self.isRegex = true
        self.enabled = true
        self.order = 0
        self.isDeleted = false
    }
}

struct KeyboardAssist: Codable {
    var name: String
    var value: String
    var sortNumber: Int

    init(name: String = "", value: String = "", sortNumber: Int = 0) {
        self.name = name
        self.value = value
        self.sortNumber = sortNumber
    }
}

struct SourceDebugItem: Identifiable {
    let id = UUID()
    let url: String
    let method: String
    let headers: [String: String]?
    let body: String?
    let result: String?
    let isError: Bool
    let timestamp: Date

    init(url: String, method: String = "GET", headers: [String: String]? = nil, body: String? = nil, result: String? = nil, isError: Bool = false) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.result = result
        self.isError = isError
        self.timestamp = Date()
    }
}
