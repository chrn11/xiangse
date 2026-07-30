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
    /// 书本级变量 JSON（与 BookVariableStore 同步的可选快照）
    public var variable: String = ""

    public init() {}

    public init(
        name: String = "",
        author: String = "",
        bookUrl: String = "",
        coverUrl: String = "",
        intro: String = "",
        sourceUrl: String = "",
        sourceName: String = "",
        variable: String = ""
    ) {
        self.name = name
        self.author = author
        self.bookUrl = bookUrl
        self.coverUrl = coverUrl
        self.intro = intro
        self.sourceUrl = sourceUrl
        self.sourceName = sourceName
        self.variable = variable
    }
}

public struct BridgeChapter {
    public var title: String = ""
    public var url: String = ""
    public var index: Int = 0
    /// 直链音频（可选）；优先于正文内嵌 URL
    public var audioUrl: String?

    public init(title: String = "", url: String = "", index: Int = 0, audioUrl: String? = nil) {
        self.title = title
        self.url = url
        self.index = index
        self.audioUrl = audioUrl
    }
}
