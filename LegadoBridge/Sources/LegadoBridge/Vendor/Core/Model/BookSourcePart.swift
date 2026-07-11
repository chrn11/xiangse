import Foundation

public struct BookSourcePart: Codable, Identifiable {
    public var id: String { bookSourceUrl }

    public var bookSourceUrl: String
    public var bookSourceName: String
    public var bookSourceGroup: String?
    public var bookSourceType: Int?
    public var bookUrlPattern: String?
    public var header: String?
    public var concurrentRate: String?
    public var loginUrl: String?
    public var loginUi: String?
    public var loginCheckJs: String?
    public var coverDecodeJs: String?
    public var jsLib: String?
    public var bookSourceComment: String?
    public var variableComment: String?
    public var lastUpdateTime: Int64?
    public var respondTime: Int64?
    public var weight: Int?
    public var exploreUrl: String?
    public var exploreScreen: String?
    public var searchUrl: String?
    public var enabled: Bool?
    public var enabledExplore: Bool?
    public var enabledCookieJar: Bool?
    public var ruleSearch: SearchRulePart?
    public var ruleExplore: ExploreRulePart?
    public var ruleBookInfo: BookInfoRulePart?
    public var ruleToc: TocRulePart?
    public var ruleContent: ContentRulePart?
    public var ruleReview: ReviewRulePart?
    public var variable: String?

    public struct SearchRulePart: Codable {
        public var checkKeyWord: String?
        public var bookList: String?
        public var name: String?
        public var author: String?
        public var intro: String?
        public var kind: String?
        public var lastChapter: String?
        public var updateTime: String?
        public var bookUrl: String?
        public var coverUrl: String?
        public var wordCount: String?
    }

    public struct ExploreRulePart: Codable {
        public var bookList: String?
        public var name: String?
        public var author: String?
        public var intro: String?
        public var kind: String?
        public var lastChapter: String?
        public var updateTime: String?
        public var bookUrl: String?
        public var coverUrl: String?
        public var wordCount: String?
    }

    public struct BookInfoRulePart: Codable {
        public var initRule: String?
        public var name: String?
        public var author: String?
        public var intro: String?
        public var kind: String?
        public var lastChapter: String?
        public var updateTime: String?
        public var coverUrl: String?
        public var tocUrl: String?
        public var wordCount: String?
        public var canReName: String?
        public var downloadUrls: String?
    }

    public struct TocRulePart: Codable {
        public var chapterList: String?
        public var chapterName: String?
        public var chapterUrl: String?
        public var formatJs: String?
        public var isVolume: String?
        public var isVip: String?
        public var isPay: String?
        public var nextTocUrl: String?
    }

    public struct ContentRulePart: Codable {
        public var content: String?
        public var nextContentUrl: String?
        public var webJs: String?
        public var sourceRegex: String?
        public var replaceRegex: String?
        public var imageStyle: String?
        public var imageDecode: String?
        public var payAction: String?
    }

    public struct ReviewRulePart: Codable {
        public var reviewUrl: String?
        public var avatarRule: String?
        public var contentRule: String?
        public var postUrl: String?
    }
}

public struct BookSourceCheckResult {
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
