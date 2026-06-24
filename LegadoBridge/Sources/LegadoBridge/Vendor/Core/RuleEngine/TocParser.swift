import Foundation
import JavaScriptCore

final class TocParser {
    private let ruleEngine: RuleEngine

    init(ruleEngine: RuleEngine = RuleEngine()) {
        self.ruleEngine = ruleEngine
    }

    func parseChapters(
        body: String,
        baseUrl: String,
        rule: TocRule,
        startIndex: Int = 0
    ) throws -> [WebChapter] {
        let elements = try ruleEngine.getElements(
            ruleStr: rule.bookList,
            body: body,
            baseUrl: baseUrl
        )

        var chapters: [WebChapter] = []
        chapters.reserveCapacity(elements.count)

        for (offset, elementContext) in elements.enumerated() {
            var chapter = WebChapter()
            chapter.index = startIndex + offset
            chapter.title = ruleEngine.getString(
                ruleStr: rule.chapterName,
                elementContext: elementContext,
                baseUrl: baseUrl
            )
            chapter.url = ruleEngine.getString(
                ruleStr: rule.chapterUrl,
                elementContext: elementContext,
                baseUrl: baseUrl
            )

            if let vipRule = rule.isVip {
                let vipValue = ruleEngine.getString(ruleStr: vipRule, elementContext: elementContext)
                chapter.isVip = parseBool(vipValue)
            }

            if let payRule = rule.isPay {
                let payValue = ruleEngine.getString(ruleStr: payRule, elementContext: elementContext)
                chapter.isPay = parseBool(payValue)
            }

            if let volumeRule = rule.isVolume {
                let volumeValue = ruleEngine.getString(ruleStr: volumeRule, elementContext: elementContext)
                chapter.isVolume = parseBool(volumeValue)
            }

            if let updateRule = rule.updateTime {
                let updateValue = ruleEngine.getString(ruleStr: updateRule, elementContext: elementContext)
                chapter.updateTime = parseUpdateTime(updateValue)
            }

            if let formatJs = rule.formatJs?.trimmingCharacters(in: .whitespacesAndNewlines),
               !formatJs.isEmpty {
                chapter.title = applyFormatJS(
                    formatJs,
                    chapter: chapter,
                    displayIndex: startIndex + offset + 1
                ) ?? chapter.title
            }

            if !chapter.title.isEmpty {
                chapters.append(chapter)
            }
        }

        return chapters
    }

    func parseNextPageUrls(body: String, baseUrl: String, rule: TocRule) -> [String] {
        guard let nextRule = rule.nextTocUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
               !nextRule.isEmpty else {
            return []
        }

        do {
            let urls = try ruleEngine.getStringList(ruleStr: nextRule, body: body, baseUrl: baseUrl, isUrl: true)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0 != baseUrl }
            var unique: [String] = []
            for url in urls where !unique.contains(url) {
                unique.append(url)
            }
            return unique
        } catch {
            let rootContext = ElementContext(element: body, baseUrl: baseUrl)
            let nextUrl = ruleEngine.getString(ruleStr: nextRule, elementContext: rootContext, baseUrl: baseUrl)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return nextUrl.isEmpty ? [] : [nextUrl]
        }
    }

    private func applyFormatJS(_ js: String, chapter: WebChapter, displayIndex: Int) -> String? {
        let context = JSContext()
        context?.setValue(displayIndex, forKey: "index")
        context?.setValue(chapter.title, forKey: "title")
        context?.setValue(0, forKey: "gInt")
        context?.setValue([
            "title": chapter.title,
            "url": chapter.url,
            "index": chapter.index,
            "isVip": chapter.isVip,
            "isPay": chapter.isPay,
            "isVolume": chapter.isVolume,
            "updateTime": chapter.updateTime as Any
        ], forKey: "chapter")

        if let value = context?.evaluateScript(js)?.toString(), !value.isEmpty {
            return value
        }
        return nil
    }

    private func parseBool(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "1" ||
            normalized == "true" ||
            normalized == "yes" ||
            normalized == "y" ||
            normalized == "vip"
    }

    private func parseUpdateTime(_ value: String) -> Int64? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let timestamp = Int64(trimmed) {
            if timestamp > 1_000_000_000_000 {
                return timestamp / 1000
            }
            return timestamp
        }

        let formats = [
            "yyyy-MM-dd HH:mm:ss",
            "yyyy/MM/dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy/MM/dd HH:mm",
            "yyyy-MM-dd",
            "yyyy/MM/dd",
            "MM-dd HH:mm",
            "yyyy年MM月dd日 HH:mm:ss",
            "yyyy年MM月dd日"
        ]

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")

        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return Int64(date.timeIntervalSince1970)
            }
        }

        return nil
    }
}
