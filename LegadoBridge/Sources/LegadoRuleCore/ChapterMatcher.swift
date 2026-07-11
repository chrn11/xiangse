import Foundation

/// 换源后的章节对齐结果
public struct ChapterMatchResult: Equatable {
    public let index: Int
    public let title: String
    public let url: String
    /// 0...1，1 为完全匹配
    public let score: Double
    public let strategy: String

    public init(index: Int, title: String, url: String, score: Double, strategy: String) {
        self.index = index
        self.title = title
        self.url = url
        self.score = score
        self.strategy = strategy
    }
}

/// 书籍换源时的章节标题匹配 — 纯逻辑，无网络/无 CoreData
public enum ChapterMatcher {

    /// 在新目录中为当前章节找最佳对齐项；优先精确 → 归一化相等 → 包含 → 相似度
    public static func match(
        currentTitle: String?,
        currentIndex: Int?,
        chapters: [BridgeChapter],
        minimumScore: Double = 0.55
    ) -> ChapterMatchResult? {
        guard !chapters.isEmpty else { return nil }

        let needle = (currentTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !needle.isEmpty {
            if let exact = chapters.firstIndex(where: { $0.title == needle }) {
                let ch = chapters[exact]
                return ChapterMatchResult(
                    index: exact, title: ch.title, url: ch.url, score: 1.0, strategy: "exact"
                )
            }

            let normNeedle = normalize(needle)
            if !normNeedle.isEmpty {
                if let idx = chapters.firstIndex(where: { normalize($0.title) == normNeedle }) {
                    let ch = chapters[idx]
                    return ChapterMatchResult(
                        index: idx, title: ch.title, url: ch.url, score: 0.95, strategy: "normalized"
                    )
                }

                var best: (Int, Double, String)?
                for (i, ch) in chapters.enumerated() {
                    let norm = normalize(ch.title)
                    guard !norm.isEmpty else { continue }
                    if norm.contains(normNeedle) || normNeedle.contains(norm) {
                        let score = Double(min(norm.count, normNeedle.count))
                            / Double(max(norm.count, normNeedle.count))
                        let clamped = max(0.7, min(0.9, score))
                        if best == nil || clamped > best!.1 {
                            best = (i, clamped, "contains")
                        }
                    } else {
                        let sim = similarity(normNeedle, norm)
                        if sim >= minimumScore, best == nil || sim > best!.1 {
                            best = (i, sim, "similarity")
                        }
                    }
                }
                if let best {
                    let ch = chapters[best.0]
                    return ChapterMatchResult(
                        index: best.0, title: ch.title, url: ch.url, score: best.1, strategy: best.2
                    )
                }
            }
        }

        // 标题不可用时按索引兜底（夹在合法范围内）
        if let idx = currentIndex, idx >= 0 {
            let clamped = min(idx, chapters.count - 1)
            let ch = chapters[clamped]
            return ChapterMatchResult(
                index: clamped, title: ch.title, url: ch.url, score: 0.4, strategy: "index"
            )
        }

        let ch = chapters[0]
        return ChapterMatchResult(
            index: 0, title: ch.title, url: ch.url, score: 0.2, strategy: "fallback_first"
        )
    }

    /// 归一化章节名：去空白/标点，去「第…章/回/节/卷」外壳，小写
    public static func normalize(_ title: String) -> String {
        var s = title.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        let punct = CharacterSet.punctuationCharacters
            .union(.symbols)
            .union(.illegalCharacters)
        s = s.components(separatedBy: punct).joined()
        // 常见中文章节外壳
        if let regex = try? NSRegularExpression(
            pattern: #"^第?\s*[0-9零一二三四五六七八九十百千两]+[章节回卷集部话]"#
        ) {
            let range = NSRange(s.startIndex..., in: s)
            s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
        }
        return s.lowercased()
    }

    /// Dice 系数相似度（基于 bigram），空串返回 0
    public static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        if a.isEmpty || b.isEmpty { return 0 }
        let aGrams = bigrams(a)
        let bGrams = bigrams(b)
        if aGrams.isEmpty || bGrams.isEmpty {
            return a == b ? 1 : 0
        }
        var intersection = 0
        var bCopy = bGrams
        for g in aGrams {
            if let i = bCopy.firstIndex(of: g) {
                intersection += 1
                bCopy.remove(at: i)
            }
        }
        return (2.0 * Double(intersection)) / Double(aGrams.count + bGrams.count)
    }

    private static func bigrams(_ s: String) -> [String] {
        let chars = Array(s)
        guard chars.count >= 2 else { return chars.map(String.init) }
        var out: [String] = []
        out.reserveCapacity(chars.count - 1)
        for i in 0..<(chars.count - 1) {
            out.append(String(chars[i]) + String(chars[i + 1]))
        }
        return out
    }
}
