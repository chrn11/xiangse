import Foundation

public struct BridgeBook {
    public var name: String = ""
    public var author: String = ""
    public var bookUrl: String = ""
    public var tocUrl: String = ""
    public var coverUrl: String = ""
    public var intro: String = ""
    public var kind: String = ""
    public var latestChapterTitle: String = ""
    public var wordCount: String = ""
    public var tocHtml: String?
    public var sourceUrl: String = ""
    public var sourceName: String = ""

    public init() {}

    public init(
        name: String = "",
        author: String = "",
        bookUrl: String = "",
        coverUrl: String = "",
        intro: String = "",
        sourceUrl: String = "",
        sourceName: String = ""
    ) {
        self.name = name
        self.author = author
        self.bookUrl = bookUrl
        self.coverUrl = coverUrl
        self.intro = intro
        self.sourceUrl = sourceUrl
        self.sourceName = sourceName
    }
}

public struct BridgeChapter {
    public var title: String = ""
    public var url: String = ""
    public var index: Int = 0

    public init(title: String = "", url: String = "", index: Int = 0) {
        self.title = title
        self.url = url
        self.index = index
    }
}
