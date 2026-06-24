//
//  ReplaceAnalyzer.swift
//  Legado-iOS
//
//  替换规则导入分析器
//  对标 Android help/ReplaceAnalyzer.kt (47 lines)
//

import Foundation

struct ReplaceAnalyzer {

    /// 从 JSON 数组解析替换规则列表
    /// 对标 Android jsonToReplaceRules
    static func jsonToReplaceRules(_ json: String) -> Result<[ReplaceRuleItem], Error> {
        return Result {
            guard let data = json.data(using: .utf8),
                  let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw ReplaceAnalyzerError.invalidFormat
            }

            var rules = [ReplaceRuleItem]()
            for item in items {
                guard let itemData = try? JSONSerialization.data(withJSONObject: item) else { continue }
                guard let itemJson = String(data: itemData, encoding: .utf8) else { continue }

                switch jsonToReplaceRule(itemJson) {
                case .success(let rule):
                    if rule.isValid() {
                        rules.append(rule)
                    }
                case .failure:
                    continue
                }
            }
            return rules
        }
    }

    /// 从单个 JSON 对象解析替换规则
    /// 对标 Android jsonToReplaceRule
    static func jsonToReplaceRule(_ json: String) -> Result<ReplaceRuleItem, Error> {
        return Result {
            let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = trimmed.data(using: .utf8) else {
                throw ReplaceAnalyzerError.invalidFormat
            }

            // 先尝试直接 Codable 解码
            if let rule = try? JSONDecoder().decode(ReplaceRuleItem.self, from: data),
               rule.isValid() {
                return rule
            }

            // 兼容旧格式: 使用 JsonPath 风格字段映射
            guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ReplaceAnalyzerError.invalidFormat
            }

            var pattern = dict["pattern"] as? String ?? dict["regex"] as? String ?? ""
            guard !pattern.isEmpty else {
                throw ReplaceAnalyzerError.patternEmpty
            }

            let rule = ReplaceRuleItem(
                id: UUID(),
                name: dict["name"] as? String ?? dict["replaceSummary"] as? String ?? "",
                pattern: pattern,
                replacement: dict["replacement"] as? String ?? "",
                scope: dict["scope"] as? String ?? dict["useTo"] as? String ?? "global",
                scopeId: dict["scopeId"] as? String,
                isRegex: dict["isRegex"] as? Bool ?? (dict["isRegex"] as? Int == 1) ?? true,
                enabled: dict["enabled"] as? Bool ?? (dict["enable"] as? Bool == true) ?? true,
                priority: dict["priority"] as? Int ?? 0,
                order: dict["order"] as? Int ?? dict["serialNumber"] as? Int ?? 0
            )
            return rule
        }
    }
}

enum ReplaceAnalyzerError: LocalizedError {
    case invalidFormat
    case patternEmpty

    var errorDescription: String? {
        switch self {
        case .invalidFormat: return "替换规则格式无效"
        case .patternEmpty: return "替换规则pattern为空"
        }
    }
}

extension ReplaceRuleItem {
    func isValid() -> Bool {
        return !pattern.isEmpty
    }
}