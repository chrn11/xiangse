import Foundation

struct BridgeBook {
    var name: String = ""
    var author: String = ""
    var bookUrl: String = ""
    var tocUrl: String = ""
    var coverUrl: String = ""
    var intro: String = ""
    var kind: String = ""
    var latestChapterTitle: String = ""
    var wordCount: String = ""
    var tocHtml: String?
    var sourceUrl: String = ""
    var sourceName: String = ""
}

struct BridgeChapter {
    var title: String = ""
    var url: String = ""
    var index: Int = 0
}
