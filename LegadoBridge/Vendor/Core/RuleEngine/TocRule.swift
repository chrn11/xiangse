import Foundation

struct TocRule: Codable {
    var preUpdateJs: String?
    var bookList: String?
    var chapterName: String?
    var chapterUrl: String?
    var formatJs: String?
    var isVolume: String?
    var isVip: String?
    var updateTime: String?

    var nextTocUrl: String?
    var isPay: String?

    var chapterList: String? {
        get { bookList }
        set { bookList = newValue }
    }

    enum CodingKeys: String, CodingKey {
        case bookList
        case chapterList
        case preUpdateJs
        case chapterName
        case chapterUrl
        case formatJs
        case isVolume
        case isVip
        case updateTime
        case nextTocUrl
        case isPay
    }

    init(
        preUpdateJs: String? = nil,
        bookList: String? = nil,
        chapterName: String? = nil,
        chapterUrl: String? = nil,
        formatJs: String? = nil,
        isVolume: String? = nil,
        isVip: String? = nil,
        updateTime: String? = nil,
        nextTocUrl: String? = nil,
        isPay: String? = nil
    ) {
        self.preUpdateJs = preUpdateJs
        self.bookList = bookList
        self.chapterName = chapterName
        self.chapterUrl = chapterUrl
        self.formatJs = formatJs
        self.isVolume = isVolume
        self.isVip = isVip
        self.updateTime = updateTime
        self.nextTocUrl = nextTocUrl
        self.isPay = isPay
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.preUpdateJs = try container.decodeIfPresent(String.self, forKey: .preUpdateJs)
        self.bookList = try container.decodeIfPresent(String.self, forKey: .bookList)
            ?? container.decodeIfPresent(String.self, forKey: .chapterList)
        self.chapterName = try container.decodeIfPresent(String.self, forKey: .chapterName)
        self.chapterUrl = try container.decodeIfPresent(String.self, forKey: .chapterUrl)
        self.formatJs = try container.decodeIfPresent(String.self, forKey: .formatJs)
        self.isVolume = try container.decodeIfPresent(String.self, forKey: .isVolume)
        self.isVip = try container.decodeIfPresent(String.self, forKey: .isVip)
        self.updateTime = try container.decodeIfPresent(String.self, forKey: .updateTime)
        self.nextTocUrl = try container.decodeIfPresent(String.self, forKey: .nextTocUrl)
        self.isPay = try container.decodeIfPresent(String.self, forKey: .isPay)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(preUpdateJs, forKey: .preUpdateJs)
        try container.encodeIfPresent(bookList, forKey: .bookList)
        try container.encodeIfPresent(chapterName, forKey: .chapterName)
        try container.encodeIfPresent(chapterUrl, forKey: .chapterUrl)
        try container.encodeIfPresent(formatJs, forKey: .formatJs)
        try container.encodeIfPresent(isVolume, forKey: .isVolume)
        try container.encodeIfPresent(isVip, forKey: .isVip)
        try container.encodeIfPresent(updateTime, forKey: .updateTime)
        try container.encodeIfPresent(nextTocUrl, forKey: .nextTocUrl)
        try container.encodeIfPresent(isPay, forKey: .isPay)
    }
}
