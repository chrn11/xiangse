import Foundation

// MARK: - 规则类型（从 legado-ios BookSource 扩展提取，去除 CoreData 依赖）

enum BridgeRuleTypes {
    struct ExploreRule: Codable {
        var exploreList: String?
        var name: String?
        var author: String?
        var intro: String?
        var kind: String?
        var updateTime: String?
        var bookUrl: String?
        var coverUrl: String?
        var lastChapter: String?
        var wordCount: String?

        init(
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

        enum CodingKeys: String, CodingKey {
            case exploreList, bookList, name, author, intro, kind, updateTime
            case bookUrl, coverUrl, lastChapter, wordCount
        }

        init(from decoder: Decoder) throws {
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

        func encode(to encoder: Encoder) throws {
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

    struct SearchRule: Codable {
        var checkKeyWord: String?
        var bookList: String?
        var name: String?
        var author: String?
        var intro: String?
        var bookUrl: String?
        var coverUrl: String?
        var lastChapter: String?
        var wordCount: String?
        var kind: String?
    }

    struct BookInfoRule: Codable {
        var initRule: String?
        var name: String?
        var author: String?
        var intro: String?
        var kind: String?
        var coverUrl: String?
        var tocUrl: String?
        var lastChapter: String?
        var updateTime: String?
        var wordCount: String?
        var canReName: String?
        var downloadUrls: String?

        enum CodingKeys: String, CodingKey {
            case initRule = "init"
            case name, author, intro, kind, coverUrl, tocUrl, lastChapter
            case updateTime, wordCount, canReName, downloadUrls
        }
    }

    struct ContentRule: Codable {
        var content: String?
        var title: String?
        var nextContentUrl: String?
        var webJs: String?
        var sourceRegex: String?
        var replaceRegex: String?
        var imageStyle: String?
        var payAction: String?
    }
}

typealias BridgeSearchRule = BridgeRuleTypes.SearchRule
typealias BridgeExploreRule = BridgeRuleTypes.ExploreRule
typealias BridgeBookInfoRule = BridgeRuleTypes.BookInfoRule
typealias BridgeContentRule = BridgeRuleTypes.ContentRule
