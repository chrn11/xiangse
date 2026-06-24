import Foundation

struct SplitRule {
    let type: RuleKind
    let rule: String
    let replace: (pattern: String, replacement: String, firstOnly: Bool)?
}

enum RuleOperator {
    case and
    case or
    case format
    case replace
}

class RuleSplitter {
    static func split(_ ruleString: String) -> [SplitRule] {
        let trimmed = ruleString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let operators = parseOperators(trimmed)
        let segments: [String]

        if let orSegments = operators.first(where: { $0.operator == .or })?.segments {
            segments = orSegments
        } else if let andSegments = operators.first(where: { $0.operator == .and })?.segments {
            segments = andSegments
        } else {
            segments = [trimmed]
        }

        return segments.compactMap { parseSegment($0) }
    }

    static func splitTopLevel(_ input: String, token: String) -> [String]? {
        balancedSplit(input, token: token)
    }

    static func parseOperators(_ ruleString: String) -> [(operator: RuleOperator, segments: [String])] {
        let trimmed = ruleString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var parsed: [(operator: RuleOperator, segments: [String])] = []

        if let segments = splitIfContains(trimmed, token: "&&") {
            parsed.append((.and, segments))
        }
        if let segments = splitIfContains(trimmed, token: "||") {
            parsed.append((.or, segments))
        }
        if let segments = splitIfContains(trimmed, token: "%%") {
            parsed.append((.format, segments))
        }
        if let segments = splitIfContains(trimmed, token: "##") {
            parsed.append((.replace, segments))
        }

        return parsed
    }

    private static func parseSegment(_ segment: String) -> SplitRule? {
        let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let (rulePart, replacePart) = parseReplace(trimmed)
        let (type, rule) = parseTypeAndRule(rulePart)

        return SplitRule(type: type, rule: rule, replace: replacePart)
    }

    private static func parseTypeAndRule(_ rawRule: String) -> (RuleKind, String) {
        let trimmed = rawRule.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()

        let prefixedKinds: [(prefix: String, kind: RuleKind)] = [
            ("@css:", .css),
            ("@xpath:", .xpath),
            ("@json:", .jsonPath),
            ("@js:", .js),
            ("@regex:", .regex)
        ]

        for item in prefixedKinds where lowercased.hasPrefix(item.prefix) {
            let content = String(trimmed.dropFirst(item.prefix.count))
            return (item.kind, content)
        }

        if trimmed.hasPrefix("//") {
            return (.xpath, trimmed)
        }
        if trimmed.hasPrefix("$") {
            return (.jsonPath, trimmed)
        }
        if lowercased.hasPrefix("regex:") || lowercased.contains("{{regex") {
            return (.regex, trimmed)
        }
        if lowercased.contains("{{js") || lowercased.contains("<js>") {
            return (.js, trimmed)
        }

        return (.css, trimmed)
    }

    private static func parseReplace(_ rule: String) -> (
        rule: String,
        replace: (pattern: String, replacement: String, firstOnly: Bool)?
    ) {
        let parts = balancedSplit(rule, token: "##") ?? [rule]
        guard parts.count >= 3 else {
            return (rule, nil)
        }

        let targetRule = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = parts[1]
        let replacement = parts[2]
        let firstOnly = parts.count > 3
        return (targetRule, (pattern: pattern, replacement: replacement, firstOnly: firstOnly))
    }

    private static func splitIfContains(_ input: String, token: String) -> [String]? {
        balancedSplit(input, token: token)
    }

    private static func balancedSplit(_ input: String, token: String) -> [String]? {
        guard !token.isEmpty, input.contains(token) else { return nil }

        var parts: [String] = []
        var buffer = ""
        var index = input.startIndex
        var braceDepth = 0
        var bracketDepth = 0
        var parenthesisDepth = 0
        var inSingleQuote = false
        var inDoubleQuote = false
        var escaping = false
        var jsTagDepth = 0

        while index < input.endIndex {
            if !inSingleQuote && !inDoubleQuote {
                if input[index...].hasPrefix("<js>") {
                    jsTagDepth += 1
                    buffer.append("<js>")
                    index = input.index(index, offsetBy: 4)
                    continue
                }

                if input[index...].hasPrefix("</js>") {
                    jsTagDepth = max(0, jsTagDepth - 1)
                    buffer.append("</js>")
                    index = input.index(index, offsetBy: 5)
                    continue
                }
            }

            let char = input[index]

            if escaping {
                buffer.append(char)
                escaping = false
                index = input.index(after: index)
                continue
            }

            if char == "\\" {
                buffer.append(char)
                escaping = true
                index = input.index(after: index)
                continue
            }

            if char == "\"", !inSingleQuote {
                inDoubleQuote.toggle()
                buffer.append(char)
                index = input.index(after: index)
                continue
            }

            if char == "'", !inDoubleQuote {
                inSingleQuote.toggle()
                buffer.append(char)
                index = input.index(after: index)
                continue
            }

            if !inSingleQuote && !inDoubleQuote && jsTagDepth == 0 {
                if input[index...].hasPrefix(token),
                   braceDepth == 0,
                   bracketDepth == 0,
                   parenthesisDepth == 0 {
                    let part = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !part.isEmpty {
                        parts.append(part)
                    }
                    buffer.removeAll(keepingCapacity: true)
                    index = input.index(index, offsetBy: token.count)
                    continue
                }

                switch char {
                case "{": braceDepth += 1
                case "}": braceDepth = max(0, braceDepth - 1)
                case "[": bracketDepth += 1
                case "]": bracketDepth = max(0, bracketDepth - 1)
                case "(": parenthesisDepth += 1
                case ")": parenthesisDepth = max(0, parenthesisDepth - 1)
                default: break
                }
            }

            buffer.append(char)
            index = input.index(after: index)
        }

        let tail = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            parts.append(tail)
        }

        return parts.count > 1 ? parts : nil
    }
}
