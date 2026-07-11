import Foundation

/// 替换净化引擎 — 无 CoreData，供 RuleWebBook / Bridge 正文路径调用
public enum ReplaceEngine {

    /// 按 priority 降序、order 升序应用启用规则
    public static func apply(text: String, items: [ReplaceRuleItem]) -> String {
        var result = text
        let sorted = items
            .filter(\.enabled)
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
                return lhs.order < rhs.order
            }
        for item in sorted {
            result = applyOne(text: result, item: item)
        }
        return result
    }

    /// 仅全局（scope=global）净化
    public static func purify(content: String, items: [ReplaceRuleItem]) -> String {
        let globals = items.filter {
            $0.enabled && ($0.scope.isEmpty || $0.scope == "global")
        }
        return apply(text: content, items: globals)
    }

    /// 作用域过滤：global + 可选 book/chapter
    public static func applyScoped(
        text: String,
        items: [ReplaceRuleItem],
        bookScopeId: String? = nil,
        chapterScopeId: String? = nil
    ) -> String {
        var selected: [ReplaceRuleItem] = items.filter {
            $0.enabled && ($0.scope.isEmpty || $0.scope == "global")
        }
        if let bookScopeId {
            selected.append(contentsOf: items.filter {
                $0.enabled && $0.scope == "book" && $0.scopeId == bookScopeId
            })
        }
        if let chapterScopeId {
            selected.append(contentsOf: items.filter {
                $0.enabled && $0.scope == "chapter" && $0.scopeId == chapterScopeId
            })
        }
        return apply(text: text, items: selected)
    }

    public static func testRule(
        pattern: String,
        replacement: String,
        isRegex: Bool,
        testText: String
    ) -> String {
        applyOne(
            text: testText,
            item: ReplaceRuleItem(
                pattern: pattern,
                replacement: replacement,
                isRegex: isRegex,
                enabled: true
            )
        )
    }

    /// 内置轻量预设（广告壳/空白压缩），供夹具与首次导入
    public static var presetRules: [ReplaceRuleItem] {
        [
            ReplaceRuleItem(
                name: "去广告行",
                pattern: #"(?m)^.*(请收藏本站|最新章节|手机端阅读|本章未完).*$"#,
                replacement: "",
                scope: "global",
                isRegex: true,
                enabled: true,
                priority: 10,
                order: 0
            ),
            ReplaceRuleItem(
                name: "压缩多余空行",
                pattern: #"\n{3,}"#,
                replacement: "\n\n",
                scope: "global",
                isRegex: true,
                enabled: true,
                priority: 1,
                order: 1
            )
        ]
    }

    private static func applyOne(text: String, item: ReplaceRuleItem) -> String {
        if item.isRegex {
            guard let regex = try? NSRegularExpression(pattern: item.pattern, options: []) else {
                return text
            }
            let range = NSRange(text.startIndex..., in: text)
            return regex.stringByReplacingMatches(
                in: text,
                range: range,
                withTemplate: item.replacement
            )
        }
        return text.replacingOccurrences(of: item.pattern, with: item.replacement)
    }
}
