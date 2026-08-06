import Foundation

/// exploreUrl 文本 lexer：单次扫描，尊重引号/backtick/括号/`${}`/`<js>` 上下文。
public enum ExploreCatalogLexer {
    public struct ParsedItem: Equatable, Sendable {
        public var rawTitle: String
        public var rawTarget: String
        public var rawStyle: ExploreJSONValue?

        public init(rawTitle: String, rawTarget: String, rawStyle: ExploreJSONValue? = nil) {
            self.rawTitle = rawTitle
            self.rawTarget = rawTarget
            self.rawStyle = rawStyle
        }
    }

    /// 已知 style token（fixture corpus）；未知 suffix 保留在 target。
    public static let knownStyleTokens: Set<String> = [
        "layout_default", "layout_grid", "layout_list", "flex", "grid", "list", "row", "col"
    ]

    /// 在所有上下文深度为零时，把换行或 `&&` 识别为 item separator；保留空 segment。
    public static func splitItems(_ input: String) -> [String] {
        var items: [String] = []
        var buffer = ""
        var i = input.startIndex
        var state = DepthState()

        while i < input.endIndex {
            // <js> / </js>
            if !state.inQuoteOrBacktick {
                if input[i...].hasPrefix("<js>") {
                    state.jsDepth += 1
                    buffer.append("<js>")
                    i = input.index(i, offsetBy: 4)
                    continue
                }
                if input[i...].hasPrefix("</js>") {
                    state.jsDepth = max(0, state.jsDepth - 1)
                    buffer.append("</js>")
                    i = input.index(i, offsetBy: 5)
                    continue
                }
            }

            let ch = input[i]

            if state.escaping {
                buffer.append(ch)
                state.escaping = false
                i = input.index(after: i)
                continue
            }
            if ch == "\\" {
                buffer.append(ch)
                state.escaping = true
                i = input.index(after: i)
                continue
            }

            // quotes / backtick
            if ch == "\"", state.quote != .single, state.quote != .backtick {
                state.quote = (state.quote == .double) ? .none : .double
                buffer.append(ch)
                i = input.index(after: i)
                continue
            }
            if ch == "'", state.quote != .double, state.quote != .backtick {
                state.quote = (state.quote == .single) ? .none : .single
                buffer.append(ch)
                i = input.index(after: i)
                continue
            }
            if ch == "`", state.quote != .single, state.quote != .double {
                state.quote = (state.quote == .backtick) ? .none : .backtick
                buffer.append(ch)
                i = input.index(after: i)
                continue
            }

            if state.quote == .none && state.jsDepth == 0 {
                // ${ }
                if ch == "$", input.index(after: i) < input.endIndex, input[input.index(after: i)] == "{" {
                    state.braceDepth += 1
                    buffer.append("${")
                    i = input.index(i, offsetBy: 2)
                    continue
                }

                // && separator at depth 0
                if state.isFlat, input[i...].hasPrefix("&&") {
                    items.append(buffer)
                    buffer = ""
                    i = input.index(i, offsetBy: 2)
                    continue
                }
                // newline separator at depth 0
                if state.isFlat, ch == "\n" || ch == "\r" {
                    if ch == "\r", input.index(after: i) < input.endIndex, input[input.index(after: i)] == "\n" {
                        i = input.index(after: i)
                    }
                    items.append(buffer)
                    buffer = ""
                    i = input.index(after: i)
                    continue
                }

                switch ch {
                case "{": state.braceDepth += 1
                case "}": state.braceDepth = max(0, state.braceDepth - 1)
                case "[": state.bracketDepth += 1
                case "]": state.bracketDepth = max(0, state.bracketDepth - 1)
                case "(": state.parenDepth += 1
                case ")": state.parenDepth = max(0, state.parenDepth - 1)
                default: break
                }
            }

            buffer.append(ch)
            i = input.index(after: i)
        }
        items.append(buffer)
        return items
    }

    /// 解析单条 item：收集顶层 `::`；style 判定按合同 §24.3。
    public static func parseItem(_ item: String) -> ParsedItem {
        let seps = topLevelDelimiterRanges(item, delimiter: "::")
        if seps.isEmpty {
            return ParsedItem(rawTitle: item, rawTarget: "", rawStyle: nil)
        }

        let first = seps[0]
        let rawTitle = String(item[..<first.lowerBound])

        if seps.count == 1 {
            let rawTarget = String(item[first.upperBound...])
            return ParsedItem(rawTitle: rawTitle, rawTarget: rawTarget, rawStyle: nil)
        }

        // 多个顶层 :: ：检查最后一段是否 style
        let last = seps[seps.count - 1]
        let lastRight = String(item[last.upperBound...])
        let lastTrimmed = lastRight.trimmingCharacters(in: .whitespacesAndNewlines)
        if let style = classifyStyle(lastTrimmed) {
            // title = first left; target = between first.upperBound and last.lowerBound (可能为空)
            let rawTarget = String(item[first.upperBound..<last.lowerBound])
            return ParsedItem(rawTitle: rawTitle, rawTarget: rawTarget, rawStyle: style)
        }

        // 最后一段不是 style → 全部归入 target
        let rawTarget = String(item[first.upperBound...])
        return ParsedItem(rawTitle: rawTitle, rawTarget: rawTarget, rawStyle: nil)
    }

    // MARK: - Internals

    private enum QuoteKind {
        case none, single, double, backtick
    }

    private struct DepthState {
        var quote: QuoteKind = .none
        var escaping = false
        var braceDepth = 0
        var bracketDepth = 0
        var parenDepth = 0
        var jsDepth = 0

        var inQuoteOrBacktick: Bool { quote != .none }
        var isFlat: Bool {
            quote == .none
                && braceDepth == 0
                && bracketDepth == 0
                && parenDepth == 0
                && jsDepth == 0
        }
    }

    private static func topLevelDelimiterRanges(_ input: String, delimiter: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var i = input.startIndex
        var state = DepthState()
        let dCount = delimiter.count

        while i < input.endIndex {
            if !state.inQuoteOrBacktick {
                if input[i...].hasPrefix("<js>") {
                    state.jsDepth += 1
                    i = input.index(i, offsetBy: 4)
                    continue
                }
                if input[i...].hasPrefix("</js>") {
                    state.jsDepth = max(0, state.jsDepth - 1)
                    i = input.index(i, offsetBy: 5)
                    continue
                }
            }

            let ch = input[i]
            if state.escaping {
                state.escaping = false
                i = input.index(after: i)
                continue
            }
            if ch == "\\" {
                state.escaping = true
                i = input.index(after: i)
                continue
            }
            if ch == "\"", state.quote != .single, state.quote != .backtick {
                state.quote = (state.quote == .double) ? .none : .double
                i = input.index(after: i)
                continue
            }
            if ch == "'", state.quote != .double, state.quote != .backtick {
                state.quote = (state.quote == .single) ? .none : .single
                i = input.index(after: i)
                continue
            }
            if ch == "`", state.quote != .single, state.quote != .double {
                state.quote = (state.quote == .backtick) ? .none : .backtick
                i = input.index(after: i)
                continue
            }

            if state.quote == .none && state.jsDepth == 0 {
                if ch == "$", input.index(after: i) < input.endIndex, input[input.index(after: i)] == "{" {
                    state.braceDepth += 1
                    i = input.index(i, offsetBy: 2)
                    continue
                }
                if state.isFlat, input[i...].hasPrefix(delimiter) {
                    let end = input.index(i, offsetBy: dCount)
                    ranges.append(i..<end)
                    i = end
                    continue
                }
                switch ch {
                case "{": state.braceDepth += 1
                case "}": state.braceDepth = max(0, state.braceDepth - 1)
                case "[": state.bracketDepth += 1
                case "]": state.bracketDepth = max(0, state.bracketDepth - 1)
                case "(": state.parenDepth += 1
                case ")": state.parenDepth = max(0, state.parenDepth - 1)
                default: break
                }
            }
            i = input.index(after: i)
        }
        return ranges
    }

    private static func classifyStyle(_ trimmed: String) -> ExploreJSONValue? {
        if trimmed.isEmpty { return nil }
        // 十进制非负整数
        if trimmed.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) {
            if let v = Int(trimmed) {
                return .number(Double(v))
            }
        }
        // JSON object/array
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            if let data = trimmed.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data),
               JSONSerialization.isValidJSONObject(obj) || obj is [Any] || obj is [String: Any] {
                return ExploreJSONValue.fromAny(obj)
            }
        }
        if knownStyleTokens.contains(trimmed) {
            return .string(trimmed)
        }
        return nil
    }
}
