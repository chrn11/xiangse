import Foundation

// MARK: - 规则类型（从 legado-ios BookSource 扩展提取，去除 CoreData 依赖）

public enum BridgeRuleTypes {
    public struct ExploreRule: Codable {
        public var exploreList: String?
        public var name: String?
        public var author: String?
        public var intro: String?
        public var kind: String?
        public var updateTime: String?
        public var bookUrl: String?
        public var coverUrl: String?
        public var lastChapter: String?
        public var wordCount: String?

        public init(
            exploreList: String? = nil,
            name: String? = nil,
            author: String? = nil,
            intro: String? = nil,
            kind: String? = nil,
            updateTime: String? = nil,
            bookUrl: String? = nil,
            coverUrl: String? = nil,
            lastChapter: String? = nil,
            wordCount: String? = nil
        ) {
            self.exploreList = exploreList
            self.name = name
            self.author = author
            self.intro = intro
            self.kind = kind
            self.updateTime = updateTime
            self.bookUrl = bookUrl
            self.coverUrl = coverUrl
            self.lastChapter = lastChapter
            self.wordCount = wordCount
        }

        public enum CodingKeys: String, CodingKey {
            case exploreList, bookList, name, author, intro, kind, updateTime
            case bookUrl, coverUrl, lastChapter, wordCount
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            exploreList = try c.decodeIfPresent(String.self, forKey: .exploreList)
                ?? c.decodeIfPresent(String.self, forKey: .bookList)
            name = try c.decodeIfPresent(String.self, forKey: .name)
            author = try c.decodeIfPresent(String.self, forKey: .author)
            intro = try c.decodeIfPresent(String.self, forKey: .intro)
            kind = try c.decodeIfPresent(String.self, forKey: .kind)
            updateTime = try c.decodeIfPresent(String.self, forKey: .updateTime)
            bookUrl = try c.decodeIfPresent(String.self, forKey: .bookUrl)
            coverUrl = try c.decodeIfPresent(String.self, forKey: .coverUrl)
            lastChapter = try c.decodeIfPresent(String.self, forKey: .lastChapter)
            wordCount = try c.decodeIfPresent(String.self, forKey: .wordCount)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(exploreList, forKey: .bookList)
            try c.encodeIfPresent(name, forKey: .name)
            try c.encodeIfPresent(author, forKey: .author)
            try c.encodeIfPresent(intro, forKey: .intro)
            try c.encodeIfPresent(kind, forKey: .kind)
            try c.encodeIfPresent(updateTime, forKey: .updateTime)
            try c.encodeIfPresent(bookUrl, forKey: .bookUrl)
            try c.encodeIfPresent(coverUrl, forKey: .coverUrl)
            try c.encodeIfPresent(lastChapter, forKey: .lastChapter)
            try c.encodeIfPresent(wordCount, forKey: .wordCount)
        }
    }

    public struct SearchRule: Codable {
        public var checkKeyWord: String?
        public var bookList: String?
        public var name: String?
        public var author: String?
        public var intro: String?
        public var bookUrl: String?
        public var coverUrl: String?
        public var lastChapter: String?
        public var wordCount: String?
        public var kind: String?

        public init(
            checkKeyWord: String? = nil,
            bookList: String? = nil,
            name: String? = nil,
            author: String? = nil,
            intro: String? = nil,
            bookUrl: String? = nil,
            coverUrl: String? = nil,
            lastChapter: String? = nil,
            wordCount: String? = nil,
            kind: String? = nil
        ) {
            self.checkKeyWord = checkKeyWord
            self.bookList = bookList
            self.name = name
            self.author = author
            self.intro = intro
            self.bookUrl = bookUrl
            self.coverUrl = coverUrl
            self.lastChapter = lastChapter
            self.wordCount = wordCount
            self.kind = kind
        }
    }

    public struct BookInfoRule: Codable {
        public var initRule: String?
        public var name: String?
        public var author: String?
        public var intro: String?
        public var kind: String?
        public var coverUrl: String?
        public var tocUrl: String?
        public var lastChapter: String?
        public var updateTime: String?
        public var wordCount: String?
        public var canReName: String?
        public var downloadUrls: String?

        public enum CodingKeys: String, CodingKey {
            case initRule = "init"
            case name, author, intro, kind, coverUrl, tocUrl, lastChapter
            case updateTime, wordCount, canReName, downloadUrls
        }

        public init(
            initRule: String? = nil,
            name: String? = nil,
            author: String? = nil,
            intro: String? = nil,
            kind: String? = nil,
            coverUrl: String? = nil,
            tocUrl: String? = nil,
            lastChapter: String? = nil,
            updateTime: String? = nil,
            wordCount: String? = nil,
            canReName: String? = nil,
            downloadUrls: String? = nil
        ) {
            self.initRule = initRule
            self.name = name
            self.author = author
            self.intro = intro
            self.kind = kind
            self.coverUrl = coverUrl
            self.tocUrl = tocUrl
            self.lastChapter = lastChapter
            self.updateTime = updateTime
            self.wordCount = wordCount
            self.canReName = canReName
            self.downloadUrls = downloadUrls
        }
    }

    public struct ContentRule: Codable {
        public var content: String?
        public var title: String?
        public var nextContentUrl: String?
        public var webJs: String?
        public var sourceRegex: String?
        public var replaceRegex: String?
        public var imageStyle: String?
        public var payAction: String?

        public init(
            content: String? = nil,
            title: String? = nil,
            nextContentUrl: String? = nil,
            webJs: String? = nil,
            sourceRegex: String? = nil,
            replaceRegex: String? = nil,
            imageStyle: String? = nil,
            payAction: String? = nil
        ) {
            self.content = content
            self.title = title
            self.nextContentUrl = nextContentUrl
            self.webJs = webJs
            self.sourceRegex = sourceRegex
            self.replaceRegex = replaceRegex
            self.imageStyle = imageStyle
            self.payAction = payAction
        }
    }
}

public typealias BridgeSearchRule = BridgeRuleTypes.SearchRule
public typealias BridgeExploreRule = BridgeRuleTypes.ExploreRule
public typealias BridgeBookInfoRule = BridgeRuleTypes.BookInfoRule
public typealias BridgeContentRule = BridgeRuleTypes.ContentRule
