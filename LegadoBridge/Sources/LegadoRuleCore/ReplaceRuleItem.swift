import Foundation

/// 替换/净化规则条目（无 CoreData，可 Codable 落盘）
public struct ReplaceRuleItem: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var pattern: String
    public var replacement: String
    /// global / book / chapter
    public var scope: String
    public var scopeId: String?
    public var isRegex: Bool
    public var enabled: Bool
    public var priority: Int
    public var order: Int

    public init(
        id: UUID = UUID(),
        name: String = "",
        pattern: String,
        replacement: String = "",
        scope: String = "global",
        scopeId: String? = nil,
        isRegex: Bool = true,
        enabled: Bool = true,
        priority: Int = 0,
        order: Int = 0
    ) {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.replacement = replacement
        self.scope = scope
        self.scopeId = scopeId
        self.isRegex = isRegex
        self.enabled = enabled
        self.priority = priority
        self.order = order
    }

    public func isValid() -> Bool {
        !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// JSON → 替换规则（兼容阅读/legado 字段别名）
public enum ReplaceAnalyzer {

    public static func jsonToReplaceRules(_ json: String) -> Result<[ReplaceRuleItem], Error> {
        Result {
            guard let data = json.data(using: .utf8) else {
                throw ReplaceAnalyzerError.invalidFormat
            }
            let object = try JSONSerialization.jsonObject(with: data)
            let items: [[String: Any]]
            if let arr = object as? [[String: Any]] {
                items = arr
            } else if let one = object as? [String: Any] {
                items = [one]
            } else {
                throw ReplaceAnalyzerError.invalidFormat
            }
            var rules: [ReplaceRuleItem] = []
            for item in items {
                let itemData = try JSONSerialization.data(withJSONObject: item)
                guard let itemJson = String(data: itemData, encoding: .utf8) else { continue }
                if case .success(let rule) = jsonToReplaceRule(itemJson), rule.isValid() {
                    rules.append(rule)
                }
            }
            return rules
        }
    }

    public static func jsonToReplaceRule(_ json: String) -> Result<ReplaceRuleItem, Error> {
        Result {
            let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = trimmed.data(using: .utf8) else {
                throw ReplaceAnalyzerError.invalidFormat
            }
            if let rule = try? JSONDecoder().decode(ReplaceRuleItem.self, from: data),
               rule.isValid() {
                return rule
            }
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ReplaceAnalyzerError.invalidFormat
            }
            let pattern = (dict["pattern"] as? String)
                ?? (dict["regex"] as? String)
                ?? ""
            guard !pattern.isEmpty else { throw ReplaceAnalyzerError.patternEmpty }

            let id: UUID
            if let s = dict["id"] as? String, let u = UUID(uuidString: s) {
                id = u
            } else {
                id = UUID()
            }

            return ReplaceRuleItem(
                id: id,
                name: (dict["name"] as? String)
                    ?? (dict["replaceSummary"] as? String)
                    ?? "",
                pattern: pattern,
                replacement: (dict["replacement"] as? String) ?? "",
                scope: (dict["scope"] as? String)
                    ?? (dict["useTo"] as? String)
                    ?? "global",
                scopeId: dict["scopeId"] as? String,
                isRegex: boolValue(dict["isRegex"]) ?? true,
                enabled: boolValue(dict["enabled"]) ?? boolValue(dict["enable"]) ?? true,
                priority: (dict["priority"] as? Int)
                    ?? (dict["priority"] as? NSNumber)?.intValue
                    ?? 0,
                order: (dict["order"] as? Int)
                    ?? (dict["serialNumber"] as? Int)
                    ?? (dict["order"] as? NSNumber)?.intValue
                    ?? 0
            )
        }
    }

    private static func boolValue(_ any: Any?) -> Bool? {
        if let b = any as? Bool { return b }
        if let n = any as? NSNumber { return n.boolValue }
        if let i = any as? Int { return i != 0 }
        return nil
    }
}

public enum ReplaceAnalyzerError: LocalizedError {
    case invalidFormat
    case patternEmpty

    public var errorDescription: String? {
        switch self {
        case .invalidFormat: return "替换规则格式无效"
        case .patternEmpty: return "替换规则 pattern 为空"
        }
    }
}
