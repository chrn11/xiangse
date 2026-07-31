//
//  RuleEngine.swift
//  Legado-iOS
//
//  书源规则解析引擎
//

import Foundation
import JavaScriptCore
import SwiftSoup
import Kanna

// MARK: - 辅助函数

func resolveUrl(_ url: String, baseUrl: String?) -> String {
    if url.hasPrefix("http") { return url }
    guard let base = baseUrl, let baseURL = URL(string: base) else { return url }
    return URL(string: url, relativeTo: baseURL)?.absoluteString ?? url
}

/// 把 String 编成 JS/JSON 字符串字面量。
/// 裸 String 不是合法 JSON 顶层，`dataWithJSONObject:` 会抛 NSInvalidArgumentException，
/// Swift `try?` 捕不到 → 正文 `#content@html@js` 直接崩（legado_catalog_openreader UNCAUGHT）。
func legadoJSONEncodeStringLiteral(_ value: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
          let wrapped = String(data: data, encoding: .utf8),
          wrapped.count >= 2 else {
        return "\"\""
    }
    // ["..."] → "..."
    return String(wrapped.dropFirst().dropLast())
}

/// Legado CSS 扩展选择器：`text.` / `class.` / `id.` / `tag.`（Android AnalyzeByJSoup 同款前缀）
/// SwiftSoup 原生不识 `text.目录`，直接 select 会空结果 → tocUrl 回落 bookUrl → 目录空。
enum LegadoCSSSelect {
    static func elements(in root: SwiftSoup.Element, selector: String) throws -> [SwiftSoup.Element] {
        let s = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return [root] }

        if s.hasPrefix("text.") {
            let needle = String(s.dropFirst(5))
            guard !needle.isEmpty else { return [] }
            return try root.getAllElements().array().filter { el in
                let own = (try? el.ownText()) ?? ""
                if own.contains(needle) { return true }
                // 部分节点 ownText 为空，回退完整 text（精确或包含）
                if own.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let full = (try? el.text()) ?? ""
                    return full == needle || full.contains(needle)
                }
                return false
            }
        }
        if s.hasPrefix("class.") {
            // `class.foo.0`：末段纯数字为下标（Android AnalyzeByJSoup 同款）
            let (className, index) = parseClassRule(String(s.dropFirst(6)))
            guard !className.isEmpty else { return [] }
            var found = try root.getElementsByClass(className).array()
            // 部分畸形 HTML 下 getElementsByClass 会空，回落 CSS `.className`
            if found.isEmpty {
                let escaped = NSRegularExpression.escapedPattern(for: className)
                found = try root.select(".\(escaped)").array()
            }
            if found.isEmpty {
                found = try root.select("[class~=\"\(className)\"]").array()
            }
            if let index {
                // Android：.-1 取最后一个
                let resolved = index >= 0 ? index : found.count + index
                guard resolved >= 0, resolved < found.count else { return [] }
                return [found[resolved]]
            }
            return found
        }
        if s.hasPrefix("id.") {
            let (idName, index) = parseClassRule(String(s.dropFirst(3)))
            guard !idName.isEmpty else { return [] }
            if let el = try root.getElementById(idName) {
                if let index {
                    let resolved = index >= 0 ? index : (index == -1 ? 0 : -1)
                    return resolved == 0 ? [el] : []
                }
                return [el]
            }
            return []
        }
        if s.hasPrefix("tag.") {
            let (tagName, index) = parseClassRule(String(s.dropFirst(4)))
            guard !tagName.isEmpty else { return [] }
            var found = try root.getElementsByTag(tagName).array()
            if let index {
                let resolved = index >= 0 ? index : found.count + index
                guard resolved >= 0, resolved < found.count else { return [] }
                return [found[resolved]]
            }
            return found
        }
        // 普通 CSS；SwiftSoup 对部分 data-* 属性选择器会空，补属性回落
        do {
            let found = try root.select(s).array()
            if !found.isEmpty { return found }
        } catch {
            // fall through
        }
        if let attrSel = parseAttrSelector(s) {
            var found = try root.getElementsByAttribute(attrSel.attr).array()
            if let tag = attrSel.tag, !tag.isEmpty, tag != "*" {
                found = found.filter { ($0.tagName() ?? "").lowercased() == tag.lowercased() }
            }
            return found
        }
        return []
    }

    /// `a[data-bid]` / `[data-bid]` / `a[data-bid=1]` → tag + attr（忽略等值，只按属性名）
    private static func parseAttrSelector(_ raw: String) -> (tag: String?, attr: String)? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = s.firstIndex(of: "["), let close = s.firstIndex(of: "]"), open < close else {
            return nil
        }
        let tagPart = String(s[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
        let inside = String(s[s.index(after: open)..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inside.isEmpty else { return nil }
        let attrName: String
        if let eq = inside.firstIndex(of: "=") {
            attrName = String(inside[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            attrName = inside
        }
        guard !attrName.isEmpty else { return nil }
        return (tagPart.isEmpty ? nil : tagPart, attrName)
    }

    /// `res-book-item` / `book-info-title.0` → (name, optionalIndex)
    private static func parseClassRule(_ raw: String) -> (String, Int?) {
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let last = parts.last, parts.count >= 2, let idx = Int(last), String(idx) == last else {
            return (raw, nil)
        }
        return (parts.dropLast().joined(separator: "."), idx)
    }
}

// MARK: - 元素上下文（用于列表项提取）
class ElementContext {
    var element: Any      // SwiftSoup.Element, JSON dict, 或 String
    var baseUrl: String?
    
    init(element: Any, baseUrl: String? = nil) {
        self.element = element
        self.baseUrl = baseUrl
    }
}

// MARK: - 结果类型
enum RuleResult {
    case string(String)
    case list([String])
    case none
    
    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }
    
    var list: [String]? {
        if case .list(let value) = self { return value }
        return nil
    }
}

// MARK: - 执行上下文
class ExecutionContext {
    var document: Any?
    var jsonString: String?
    var jsonDict: [String: Any]?
    var jsonValue: Any?
    var baseURL: URL?
    var source: (any BridgeSourceProtocol)?
    /// 非空时 java.put/get 走书本级 BookVariableStore（与源级 SourceSessionStore 分离）
    var bookUrl: String?
    var bookName: String?
    var variables: [String: String] = [:]
    var lastResult: RuleResult = .none
    /// AnalyzeRule 当前正文（java.setContent / getElement）
    var analyzeContent: String = ""
    var analyzeBaseUrl: String?
    /// 最近一次 java.getElement 的结果（JS 未显式返回时回落）
    var lastElementContexts: [ElementContext] = []
    weak var ruleEngine: RuleEngine?
    /// 必须强引用：JS 块里是 weak self，仅靠局部变量会在 lazy 初始化结束后释放，导致 getElement 空跑
    var jsBridge: JSBridge?

    lazy var jsContext: JSContext = {
        let context = JSContext()!

        let bridge = JSBridge()
        bridge.context = self
        bridge.ruleEngine = self.ruleEngine
        self.jsBridge = bridge
        bridge.inject(into: context)

        // 注入getVar/setVar
        context.setValue({ [weak self] (key: String) -> String in
            self?.variables[key] ?? ""
        }, forKey: "getVar")

        context.setValue({ [weak self] (key: String, value: String) in
            self?.variables[key] = value
        }, forKey: "setVar")

        // 注入 result
        context.setValue({ [weak self] () -> String? in
            self?.lastResult.string
        }, forKey: "result")

        return context
    }()
}

private final class SourceRuleContextAdapter: RuleExecutionContext {
    private let ruleEngine: RuleEngine
    private let executionContext: ExecutionContext

    init(ruleEngine: RuleEngine, executionContext: ExecutionContext) {
        self.ruleEngine = ruleEngine
        self.executionContext = executionContext
    }

    func getVariable(_ key: String) -> String {
        executionContext.variables[key] ?? ""
    }

    func setVariable(_ key: String, value: String) {
        executionContext.variables[key] = value
    }

    func evalJS(_ jsCode: String, result: Any?) -> String? {
        executionContext.jsContext.setValue(result, forKey: "result")
        executionContext.jsContext.setValue(executionContext.baseURL?.absoluteString, forKey: "baseUrl")
        // 若 lazy 初始化时 source 尚未挂上，此处补注 jsLib
        JSBridge.evaluateJsLib(of: executionContext.source, into: executionContext.jsContext)
        return executionContext.jsContext.evaluateScript(jsCode)?.toString()
    }

    func resolveRule(_ rule: SourceRule) -> String? {
        do {
            let result = try ruleEngine.executeSingle(rule: rule.rule, context: executionContext)
            switch result {
            case .string(let value):
                return value
            case .list(let values):
                return values.joined(separator: "\n")
            case .none:
                return nil
            }
        } catch {
            return nil
        }
    }
}

// MARK: - 解析器协议
protocol RuleExecutor {
    var kind: RuleKind { get }
    func canExecute(_ rule: String) -> Bool
    func execute(_ rule: String, context: ExecutionContext) throws -> RuleResult
}

enum RuleKind: String, CaseIterable {
    case jsonPath = "json"
    case xpath = "xpath"
    case css = "css"
    case regex = "regex"
    case js = "js"
}

// MARK: - 规则引擎
class RuleEngine {
    private var executors: [RuleExecutor] = []
    /// 当前绑定的书本上下文（详情/目录/正文解析时由 RuleWebBook 设置）
    var boundBookUrl: String?
    var boundBookName: String?
    var boundSource: (any BridgeSourceProtocol)?
    
    init() {
        // 按优先级注册解析器
        executors.append(JSONPathParser())
        executors.append(XPathParser())
        executors.append(CSSParser())
        executors.append(RegexParser())
        executors.append(JavaScriptParser())
    }

    /// 绑定书本级变量上下文；结束后务必 clearBoundBook()
    func bindBook(bookUrl: String?, bookName: String? = nil, source: (any BridgeSourceProtocol)? = nil) {
        boundBookUrl = bookUrl
        boundBookName = bookName
        boundSource = source
    }

    func clearBoundBook() {
        boundBookUrl = nil
        boundBookName = nil
        boundSource = nil
    }
    
    func execute(
        rules: [String],
        context: ExecutionContext
    ) throws -> RuleResult {
        var lastResult: RuleResult = .none
        
        for rule in rules {
            do {
                lastResult = try executeWithSplit(rule, context: context)
                context.lastResult = lastResult
            } catch {
                print("规则执行错误 [\(rule)]: \(error)")
            }
        }
        
        return lastResult
    }
    
    func executeSingle(
        rule: String,
        context: ExecutionContext
    ) throws -> RuleResult {
        let result = try executeWithSplit(rule, context: context)
        context.lastResult = result
        return result
    }

    private func executeWithSplit(_ rule: String, context: ExecutionContext) throws -> RuleResult {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }

        if TemplateEngine.parsePut(trimmed) != nil {
            guard TemplateEngine.executePut(trimmed, context: context, ruleEngine: self) else {
                throw RuleError.executionFailed("@put 执行失败：\(trimmed)")
            }
            return context.lastResult
        }

        if let key = TemplateEngine.parseGet(trimmed) {
            let value = TemplateEngine.executeGet(key, context: context)
            return value.isEmpty ? .none : .string(value)
        }

        let operators = RuleSplitter.parseOperators(trimmed)

        if let segments = operators.first(where: { $0.operator == .or })?.segments,
           segments.count > 1 {
            return try executeOr(segments: segments, context: context)
        }

        if let segments = operators.first(where: { $0.operator == .and })?.segments,
           segments.count > 1 {
            return try executeAnd(segments: segments, context: context)
        }

        if let segments = operators.first(where: { $0.operator == .format })?.segments,
           segments.count > 1 {
            return try executeFormat(segments: segments, context: context)
        }

        guard let splitRule = RuleSplitter.split(trimmed).first else {
            throw RuleError.unsupportedRule(trimmed)
        }

        return try executeSplitRule(splitRule, context: context)
    }

    private func executeSplitRule(_ splitRule: SplitRule, context: ExecutionContext) throws -> RuleResult {
        let sourceRule = SourceRule(
            ruleStr: splitRule.rule,
            mode: sourceRuleMode(for: splitRule.type),
            isJSON: splitRule.type == .jsonPath || context.jsonString != nil || context.jsonValue != nil
        )

        if !sourceRule.putMap.isEmpty {
            for (key, rule) in sourceRule.putMap {
                let resolved = try executeWithSplit(rule, context: context)
                context.variables[key] = flatten(resolved).joined(separator: "\n")
                context.lastResult = resolved
            }
        }

        let adapter = SourceRuleContextAdapter(ruleEngine: self, executionContext: context)
        sourceRule.makeUpRule(result: sourceRuleInput(from: context), context: adapter)

        let effectiveRule = sourceRule.rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !effectiveRule.isEmpty else {
            return .none
        }

        let effectiveKind = ruleKind(for: sourceRule.mode, fallback: splitRule.type)
        let executor = executors.first(where: { $0.kind == effectiveKind })
            ?? executors.first(where: { $0.canExecute(effectiveRule) })

        guard let executor else {
            throw RuleError.unsupportedRule(effectiveRule)
        }

        let result = try executor.execute(effectiveRule, context: context)
        let replace = sourceRule.replaceRegex.isEmpty
            ? splitRule.replace
            : (pattern: sourceRule.replaceRegex, replacement: sourceRule.replacement, firstOnly: sourceRule.replaceFirst)
        return try applyReplace(replace, to: result)
    }

    private func sourceRuleInput(from context: ExecutionContext) -> Any? {
        switch context.lastResult {
        case .string(let value):
            return value
        case .list(let values):
            return values
        case .none:
            return context.jsonValue ?? context.jsonDict ?? context.document ?? context.jsonString
        }
    }

    private func sourceRuleMode(for kind: RuleKind) -> RuleMode {
        switch kind {
        case .jsonPath:
            return .json
        case .xpath:
            return .xpath
        case .css:
            return .css
        case .regex:
            return .regex
        case .js:
            return .js
        }
    }

    private func ruleKind(for mode: RuleMode, fallback: RuleKind) -> RuleKind {
        switch mode {
        case .json:
            return .jsonPath
        case .xpath:
            return .xpath
        case .css:
            return .css
        case .default:
            return fallback
        case .regex:
            return .regex
        case .js:
            return .js
        }
    }

    private func executeAnd(segments: [String], context: ExecutionContext) throws -> RuleResult {
        if let input = sourceRuleInput(from: context) {
            let values = evaluateChainedRule(segments.joined(separator: "&&"), inputs: [input], baseUrl: context.baseURL?.absoluteString)
            let strings = values.compactMap { stringifyOutput($0) }
            if strings.count == 1, let first = strings.first {
                return .string(first)
            }
            if !strings.isEmpty {
                return .list(strings)
            }
        }

        var finalResult: RuleResult = .none
        for segment in segments {
            finalResult = try executeWithSplit(segment, context: context)
            context.lastResult = finalResult
            if isEmpty(finalResult) {
                break
            }
        }
        return finalResult
    }

    private func executeOr(segments: [String], context: ExecutionContext) throws -> RuleResult {
        for segment in segments {
            let result = try executeWithSplit(segment, context: context)
            context.lastResult = result
            if !isEmpty(result) {
                return result
            }
        }

        return .none
    }

    private func executeFormat(segments: [String], context: ExecutionContext) throws -> RuleResult {
        guard let source = segments.first else { return .none }

        let sourceResult = try executeWithSplit(source, context: context)
        var value = flatten(sourceResult).joined()

        if value.isEmpty {
            return .none
        }

        for template in segments.dropFirst() {
            value = applyFormat(template, value: value)
        }

        return value.isEmpty ? .none : .string(value)
    }

    private func applyFormat(_ template: String, value: String) -> String {
        if template.contains("{0}") {
            return template.replacingOccurrences(of: "{0}", with: value)
        }
        if template.contains("{{result}}") {
            return template.replacingOccurrences(of: "{{result}}", with: value)
        }
        if template.contains("%@") {
            return String(format: template, value)
        }
        if template.contains("%s") {
            return template.replacingOccurrences(of: "%s", with: value)
        }
        return template + value
    }

    private func applyReplace(
        _ replace: (pattern: String, replacement: String, firstOnly: Bool)?,
        to result: RuleResult
    ) throws -> RuleResult {
        guard let replace else { return result }

        guard let regex = try? NSRegularExpression(pattern: replace.pattern) else {
            throw RuleError.invalidRule("无效替换正则：\(replace.pattern)")
        }

        let replacement = replace.replacement

        switch result {
        case .string(let value):
            return .string(applyReplace(in: value, regex: regex, replacement: replacement, firstOnly: replace.firstOnly))
        case .list(let values):
            let replacedValues = values.map { item in
                applyReplace(in: item, regex: regex, replacement: replacement, firstOnly: replace.firstOnly)
            }
            return .list(replacedValues)
        case .none:
            return .none
        }
    }

    private func applyReplace(
        in value: String,
        regex: NSRegularExpression,
        replacement: String,
        firstOnly: Bool
    ) -> String {
        let range = NSRange(value.startIndex..., in: value)

        if firstOnly {
            guard let match = regex.firstMatch(in: value, range: range),
                  let matchRange = Range(match.range, in: value) else {
                return ""
            }
            let first = String(value[matchRange])
            let firstRange = NSRange(first.startIndex..., in: first)
            return regex.stringByReplacingMatches(in: first, range: firstRange, withTemplate: replacement)
        }

        return regex.stringByReplacingMatches(in: value, range: range, withTemplate: replacement)
    }

    private func flatten(_ result: RuleResult) -> [String] {
        switch result {
        case .string(let value):
            return value.isEmpty ? [] : [value]
        case .list(let values):
            return values.filter { !$0.isEmpty }
        case .none:
            return []
        }
    }

    private func isEmpty(_ result: RuleResult) -> Bool {
        flatten(result).isEmpty
    }

    private func object(from result: RuleResult) -> Any? {
        switch result {
        case .string(let value):
            return value
        case .list(let values):
            return values
        case .none:
            return nil
        }
    }

    private func buildExecutionContext(
        for input: Any?,
        baseUrl: String?,
        sourceContext: ExecutionContext? = nil
    ) -> ExecutionContext {
        let context = ExecutionContext()
        context.variables = sourceContext?.variables ?? [:]
        context.source = sourceContext?.source ?? boundSource
        context.baseURL = URL(string: baseUrl ?? sourceContext?.baseURL?.absoluteString ?? "")
        context.lastResult = sourceContext?.lastResult ?? .none
        context.bookUrl = sourceContext?.bookUrl ?? boundBookUrl
        context.bookName = sourceContext?.bookName ?? boundBookName
        if let bookUrl = context.bookUrl, !bookUrl.isEmpty {
            for (k, v) in BookVariableStore.variables(for: bookUrl) {
                if context.variables[k] == nil {
                    context.variables[k] = v
                }
            }
        }
        context.ruleEngine = self

        guard let input else {
            return context
        }

        if let jsonObject = input as? [String: Any] {
            context.jsonDict = jsonObject
            context.jsonValue = jsonObject
        } else if let stringGroups = input as? [String] {
            // AllInOne 捕获组数组
            context.lastResult = .list(stringGroups)
            context.document = stringGroups.first
        } else if let jsonArray = input as? [Any] {
            context.jsonValue = jsonArray
        } else if let string = input as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
                context.jsonString = string
            } else {
                context.document = string
            }
        } else {
            context.document = input
        }

        return context
    }
    
    // MARK: - 从 HTML/JSON 中提取元素列表
    
    /// 提取元素列表（用于书籍列表、章节列表等）
    /// - Parameters:
    ///   - ruleStr: 列表规则，如 CSS 选择器 "div.book-item" 或 JSONPath "$.list"
    ///   - body: HTML 或 JSON 字符串
    ///   - baseUrl: 基础 URL
    ///   - source: 书源（JS 列表规则需要会话变量 / startBrowserAwait）
    /// - Returns: 元素上下文数组
    func getElements(
        ruleStr: String?,
        body: String,
        baseUrl: String?,
        source: (any BridgeSourceProtocol)? = nil
    ) throws -> [ElementContext] {
        guard let ruleStr = ruleStr, !ruleStr.isEmpty else { return [] }

        let trimmed = ruleStr.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("<js>") || trimmed.lowercased().hasPrefix("@js:") || trimmed.contains("{{js") {
            return try getJsElements(ruleStr: trimmed, body: body, baseUrl: baseUrl, source: source)
        }

        // 正则 AllInOne：必须以 `:` 开头（可前缀 `-` 倒序 / `+`）
        if let allInOne = Self.parseAllInOneRegexRule(trimmed) {
            return try getRegexAllInOneElements(
                pattern: allInOne.pattern,
                body: body,
                baseUrl: baseUrl,
                reverse: allInOne.reverse
            )
        }

        let isJson = body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") ||
                     body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[")

        if isJson {
            return try getJsonElements(ruleStr: ruleStr, body: body)
        } else {
            return try getHtmlElements(ruleStr: ruleStr, body: body, baseUrl: baseUrl)
        }
    }

    /// 解析 `-:` / `+:` / `:` AllInOne 列表规则
    private static func parseAllInOneRegexRule(_ rule: String) -> (pattern: String, reverse: Bool)? {
        var s = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        var reverse = false
        if s.hasPrefix("-") {
            reverse = true
            s = String(s.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if s.hasPrefix("+") {
            s = String(s.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard s.hasPrefix(":") else { return nil }
        let pattern = String(s.dropFirst())
        guard !pattern.isEmpty else { return nil }
        return (pattern, reverse)
    }

    /// AllInOne 正则：每个匹配 → `[完整匹配, $1, $2, …]`，供 chapterName=`$2` 等取值
    private func getRegexAllInOneElements(
        pattern: String,
        body: String,
        baseUrl: String?,
        reverse: Bool
    ) throws -> [ElementContext] {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators]
        ) else {
            throw RuleError.invalidRule("无效 AllInOne 正则：\(pattern)")
        }
        let range = NSRange(body.startIndex..., in: body)
        let matches = regex.matches(in: body, options: [], range: range)
        var elements: [ElementContext] = []
        elements.reserveCapacity(matches.count)
        for match in matches {
            var groups: [String] = []
            groups.reserveCapacity(match.numberOfRanges)
            for i in 0..<match.numberOfRanges {
                let gr = match.range(at: i)
                if gr.location != NSNotFound, let sr = Range(gr, in: body) {
                    groups.append(String(body[sr]))
                } else {
                    groups.append("")
                }
            }
            elements.append(ElementContext(element: groups, baseUrl: baseUrl))
        }
        if reverse { elements.reverse() }
        return elements
    }

    /// 列表规则为 JS 时：跑桥接（含 getElement / startBrowserAwait），再取元素
    private func getJsElements(
        ruleStr: String,
        body: String,
        baseUrl: String?,
        source: (any BridgeSourceProtocol)?
    ) throws -> [ElementContext] {
        let exec = ExecutionContext()
        exec.source = source
        exec.analyzeContent = body
        exec.analyzeBaseUrl = baseUrl
        exec.baseURL = baseUrl.flatMap { URL(string: $0) }
        exec.document = body
        exec.ruleEngine = self
        exec.lastResult = .string(body)
        if let sourceUrl = source?.bookSourceUrl {
            exec.variables = SourceSessionStore.variables(for: sourceUrl)
        }

        let jsCode: String
        if ruleStr.lowercased().hasPrefix("@js:") {
            jsCode = String(ruleStr.dropFirst(4))
        } else if let regex = try? NSRegularExpression(pattern: #"<js>([\s\S]*?)</js>"#, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: ruleStr, range: NSRange(ruleStr.startIndex..., in: ruleStr)),
                  let range = Range(match.range(at: 1), in: ruleStr) {
            jsCode = String(ruleStr[range])
        } else if ruleStr.lowercased().hasPrefix("<js>") {
            // 兼容未闭合 </js> 的书源（yckceo / 本地夹具常见）
            jsCode = String(ruleStr.dropFirst(4))
        } else {
            jsCode = ruleStr
        }

        // 先写 ruleEngine，再触达 lazy jsContext（内部强持有 JSBridge，避免 weak self 空跑）
        _ = exec.jsContext
        if let retained = exec.jsBridge {
            retained.context = exec
            retained.ruleEngine = self
            retained.inject(into: exec.jsContext)
        } else {
            let bridge = JSBridge()
            bridge.context = exec
            bridge.ruleEngine = self
            exec.jsBridge = bridge
            bridge.inject(into: exec.jsContext)
        }

        exec.jsContext.setValue(body, forKey: "result")
        exec.jsContext.setValue(baseUrl, forKey: "baseUrl")
        // reinject 后再次确保 jsLib（source 可能在 lazy 之后才绑定）
        JSBridge.evaluateJsLib(of: source, into: exec.jsContext)

        var jsError: String?
        exec.jsContext.exceptionHandler = { _, ex in jsError = ex?.toString() }
        let value = exec.jsContext.evaluateScript(jsCode)
        if let jsError, !jsError.isEmpty {
            DebugLogger.shared.log("[getJsElements] \(jsError)")
        }
        if let sourceUrl = source?.bookSourceUrl {
            SourceSessionStore.merge(exec.variables, for: sourceUrl)
        }

        if !exec.lastElementContexts.isEmpty {
            return exec.lastElementContexts
        }

        // JS 若返回 HTML 片段列表 / 选择器字符串，再解析一次
        if let value, !value.isUndefined, !value.isNull {
            if let arr = Self.jsArrayLikeItems(value) {
                let mapped: [ElementContext] = arr.compactMap { item -> ElementContext? in
                    if let s = item as? String, !s.isEmpty {
                        // outerHtml 字符串再解析成 Element，供后续 class.xxx.0@ 规则使用
                        if s.contains("<"), let frag = try? SwiftSoup.parseBodyFragment(s).body() {
                            return ElementContext(element: frag, baseUrl: baseUrl)
                        }
                        return ElementContext(element: s, baseUrl: baseUrl)
                    }
                    if let jv = item as? JSValue, let s = jv.toString(), !s.isEmpty, s != "undefined", s != "null" {
                        if s.contains("<"), let frag = try? SwiftSoup.parseBodyFragment(s).body() {
                            return ElementContext(element: frag, baseUrl: baseUrl)
                        }
                        return ElementContext(element: s, baseUrl: baseUrl)
                    }
                    return ElementContext(element: item as Any, baseUrl: baseUrl)
                }
                if !mapped.isEmpty { return mapped }
            }
            if let str = value.toString(), !str.isEmpty, str != "undefined", str != "null" {
                if str.contains("<"), let doc = try? SwiftSoup.parse(str) {
                    return [ElementContext(element: doc, baseUrl: baseUrl)]
                }
                let fromSelector = try getHtmlElements(ruleStr: str, body: exec.analyzeContent, baseUrl: baseUrl)
                if !fromSelector.isEmpty { return fromSelector }
            }
        }

        // 起点 bookList：JS 常不 return；getElement 失败时从 path='…' 回落
        if let fallbackPath = Self.extractJsElementPath(jsCode) {
            let fallback = try getHtmlElements(ruleStr: fallbackPath, body: exec.analyzeContent, baseUrl: baseUrl)
            if !fallback.isEmpty {
                DebugLogger.shared.log("[getJsElements] fallback path=\(fallbackPath) count=\(fallback.count)")
                return fallback
            }
        }

        return exec.lastElementContexts
    }

    /// J1/R9：JSC 桥接下 `isArray`/`toArray` 偶发失败；按 length 索引兜底
    private static func jsArrayLikeItems(_ value: JSValue) -> [Any]? {
        if value.isArray, let arr = value.toArray(), !arr.isEmpty {
            return arr
        }
        guard value.isObject,
              let lenVal = value.objectForKeyedSubscript("length" as NSString),
              lenVal.isNumber,
              let lenNum = lenVal.toNumber() else {
            return nil
        }
        let len = lenNum.intValue
        guard len > 0, len < 100_000 else { return nil }
        var items: [Any] = []
        items.reserveCapacity(len)
        for i in 0..<len {
            guard let item = value.objectAtIndexedSubscript(i), !item.isUndefined, !item.isNull else { continue }
            if let obj = item.toObject() {
                items.append(obj)
            } else if let s = item.toString() {
                items.append(s)
            } else {
                items.append(item)
            }
        }
        return items.isEmpty ? nil : items
    }

    /// 从起点类 bookList JS 抽出 `path='class.xxx'` 或 `getElement('…')`
    private static func extractJsElementPath(_ jsCode: String) -> String? {
        let patterns = [
            #"path\s*=\s*['"]([^'"]+)['"]"#,
            #"getElement\s*\(\s*['"]([^'"]+)['"]\s*\)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(jsCode.startIndex..., in: jsCode)
            if let match = regex.firstMatch(in: jsCode, range: range),
               let r = Range(match.range(at: 1), in: jsCode) {
                let path = String(jsCode[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty { return path }
            }
        }
        return nil
    }
    
    /// 从 HTML 提取元素列表
    private func getHtmlElements(ruleStr: String, body: String, baseUrl: String?) throws -> [ElementContext] {
        let doc = try SwiftSoup.parse(body)
        if let base = baseUrl { try? doc.setBaseUri(base) }
        
        // 处理反向列表（以 - 开头）
        var rule = ruleStr
        var reverse = false
        if rule.hasPrefix("-") {
            reverse = true
            rule = String(rule.dropFirst())
        }
        if rule.hasPrefix("+") {
            rule = String(rule.dropFirst())
        }

        // 支持 XPath 和 CSS
        var elements: [ElementContext]
        if rule.hasPrefix("//") {
            // XPath
            let kannaDoc = try Kanna.HTML(html: body, encoding: .utf8)
            elements = kannaDoc.xpath(rule).compactMap { node -> ElementContext? in
                guard let html = node.toHTML else { return nil }
                return ElementContext(element: html, baseUrl: baseUrl)
            }
        } else if rule.contains("@"),
                  !rule.lowercased().hasPrefix("@css:"),
                  !rule.hasPrefix("@@") {
            // `class.section-box.-1@class.section-list@tag.li` 必须按段选；
            // 整串丢给 LegadoCSSSelect 会把 `@…` 拼进 class 名再 select → SwiftSoup.Exception
            elements = try getHtmlElementsAtChain(rule: rule, root: doc, baseUrl: baseUrl)
        } else {
            // CSS（含 Legado text./class./id./tag.）
            let selected = try LegadoCSSSelect.elements(in: doc, selector: rule)
            elements = selected.map { ElementContext(element: $0, baseUrl: baseUrl) }
        }

        if reverse { elements.reverse() }
        return elements
    }

    /// 列表规则 `@` 链：逐段 LegadoCSSSelect，保留元素列表（末段勿当 text 属性）
    private func getHtmlElementsAtChain(
        rule: String,
        root: SwiftSoup.Element,
        baseUrl: String?
    ) throws -> [ElementContext] {
        let parts = (RuleSplitter.splitTopLevel(rule, token: "@") ?? [rule])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return [] }

        var elements: [SwiftSoup.Element] = [root]
        for part in parts {
            let lower = part.lowercased()
            // 列表规则末段若是 text/html/href，不再当选择器（属性由 chapterName/Url 另取）
            let looksLikeSelector =
                lower.hasPrefix("class.") || lower.hasPrefix("tag.") || lower.hasPrefix("id.")
                || lower.hasPrefix("text.") || part.hasPrefix(".") || part.hasPrefix("#")
                || part.contains("[") || part.contains(">") || part.contains(" ")
            if !looksLikeSelector,
               ["text", "html", "href", "src", "owntext", "all"].contains(lower) {
                break
            }
            var next: [SwiftSoup.Element] = []
            next.reserveCapacity(elements.count)
            for el in elements {
                next.append(contentsOf: try LegadoCSSSelect.elements(in: el, selector: part))
            }
            elements = next
            if elements.isEmpty { break }
        }
        return elements.map { ElementContext(element: $0, baseUrl: baseUrl) }
    }
    
    /// 从 JSON 提取元素列表
    private func getJsonElements(ruleStr: String, body: String) throws -> [ElementContext] {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            throw RuleError.noDocument
        }

        var rule = ruleStr.trimmingCharacters(in: .whitespacesAndNewlines)
        var reverse = false
        if rule.hasPrefix("-") {
            reverse = true
            rule = String(rule.dropFirst())
        }
        if rule.hasPrefix("+") {
            rule = String(rule.dropFirst())
        }

        let path = normalizeJSONPath(rule)
        let values = JSONPathParser.evaluate(path: path, root: json)

        let contexts: [ElementContext]
        if values.count == 1, let array = values.first as? [Any] {
            contexts = array.map { ElementContext(element: $0) }
        } else {
            contexts = values.map { ElementContext(element: $0) }
        }

        if reverse {
            return Array(contexts.reversed())
        }

        return contexts
    }

    private func normalizeJSONPath(_ rule: String) -> String {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("$") { return trimmed }
        if trimmed.hasPrefix("[") { return "$\(trimmed)" }
        return "$.\(trimmed)"
    }
    
    // MARK: - 在元素上下文中提取字符串
    
    /// 从单个元素中提取字符串（用于从列表项中提取书名、作者等）
    func getString(ruleStr: String?, elementContext: ElementContext, baseUrl: String? = nil) -> String {
        guard let ruleStr = ruleStr, !ruleStr.isEmpty else { return "" }

        let effectiveBaseUrl = baseUrl ?? elementContext.baseUrl

        // AllInOne 匹配组：`$2` / `$1@js:…` / `$4##\".*"` / `@js:…$3…`
        if let groups = elementContext.element as? [String] {
            if let resolved = resolveRegexGroupRule(
                ruleStr,
                groups: groups,
                baseUrl: effectiveBaseUrl
            ) {
                return resolved
            }
        }

        if RuleSplitter.splitTopLevel(ruleStr, token: "&&") != nil {
            let values = evaluateChainedRule(ruleStr, inputs: [elementContext.element], baseUrl: effectiveBaseUrl)
            return values.compactMap { stringifyOutput($0) }.joined(separator: "\n")
        }

        do {
            let context = buildExecutionContext(for: elementContext.element, baseUrl: effectiveBaseUrl)
            if let groups = elementContext.element as? [String] {
                context.lastResult = .list(groups)
                context.document = groups.first
            }
            let result = try executeSingle(rule: ruleStr, context: context)
            switch result {
            case .string(let value):
                return value
            case .list(let values):
                return values.joined(separator: "\n")
            case .none:
                return ""
            }
        } catch {
            print("getString 错误 [\(ruleStr)]: \(error)")
        }
        
        return ""
    }

    /// 解析 AllInOne 捕获组规则；无法识别时返回 nil（回落通用路径）
    private func resolveRegexGroupRule(
        _ ruleStr: String,
        groups: [String],
        baseUrl: String?
    ) -> String? {
        let trimmed = ruleStr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 纯 `$N`
        if let num = Self.leadingCaptureGroupIndex(trimmed),
           trimmed == "$\(num)",
           num < groups.count {
            return groups[num]
        }

        // `$N##pattern##replacement` / `$N##pattern`
        if let num = Self.leadingCaptureGroupIndex(trimmed),
           trimmed.hasPrefix("$\(num)##"),
           num < groups.count {
            let rest = String(trimmed.dropFirst(2 + "\(num)".count)) // drop `$N`
            return applyHashReplace(to: groups[num], hashRule: rest)
        }

        // `$N@js:…`
        if let num = Self.leadingCaptureGroupIndex(trimmed),
           trimmed.hasPrefix("$\(num)@"),
           num < groups.count {
            let afterAt = String(trimmed.dropFirst(2 + "\(num)".count)) // after `$N@`
            let lower = afterAt.lowercased()
            if lower.hasPrefix("js:") {
                let jsCode = String(afterAt.dropFirst(3))
                let groupVal = groups[num]
                if let swiftOut = Self.evalSimpleResultReplaceChain(jsCode, result: groupVal) {
                    return swiftOut
                }
                return evalJSWithResult(jsCode, result: groupVal, baseUrl: baseUrl, groups: groups)
            }
        }

        // 整段 `@js:`：先替换 `$N` 再执行（起点 chapterUrl）
        if trimmed.lowercased().hasPrefix("@js:") {
            let jsCode = substituteCaptureGroups(String(trimmed.dropFirst(4)), groups: groups)
            if let swiftOut = Self.evalQidianChapterUrlJS(jsCode, baseUrl: baseUrl) {
                return swiftOut
            }
            if let swiftOut = Self.evalSimpleResultReplaceChain(jsCode, result: groups.first ?? "") {
                return swiftOut
            }
            return evalJSWithResult(jsCode, result: groups.first ?? "", baseUrl: baseUrl, groups: groups)
        }

        return nil
    }

    /// 起点 chapterUrl：`var bid=baseUrl.match(/\d+/);…'https://vipreader…/'+bid+'/<id>/'`
    private static func evalQidianChapterUrlJS(_ jsCode: String, baseUrl: String?) -> String? {
        let compact = jsCode.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        guard compact.contains("vipreader.qidian.com/chapter/"),
              compact.contains("baseUrl.match"),
              let base = baseUrl, !base.isEmpty else { return nil }
        guard let bidRegex = try? NSRegularExpression(pattern: #"\d+"#),
              let bidMatch = bidRegex.firstMatch(in: base, range: NSRange(base.startIndex..., in: base)),
              let bidRange = Range(bidMatch.range, in: base) else { return nil }
        let bid = String(base[bidRange])

        let idPatterns = [
            #"\+bid\+'/(\d+)/'"#,
            #"chapter/'[^']*'/(\d+)/'"#,
            #"/(\d+)/'\s*;?\s*$"#
        ]
        for pattern in idPatterns {
            guard let idRegex = try? NSRegularExpression(pattern: pattern),
                  let idMatch = idRegex.firstMatch(in: compact, range: NSRange(compact.startIndex..., in: compact)),
                  let idRange = Range(idMatch.range(at: 1), in: compact) else { continue }
            let chapterId = String(compact[idRange])
            guard !chapterId.isEmpty else { continue }
            return "https://vipreader.qidian.com/chapter/\(bid)/\(chapterId)/"
        }
        return nil
    }

    /// `result.replace(/1.*/,'false').replace(/0.*/,'true')` 一类链式替换（无 JSC）
    private static func evalSimpleResultReplaceChain(_ jsCode: String, result: String) -> String? {
        let trimmed = jsCode.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
        guard trimmed.contains("result.replace(") else { return nil }
        // 必须整段都是 result.replace… 链式，避免误伤复杂脚本
        guard let head = trimmed.range(of: #"^\s*result(?:\.replace\([^)]*\))+\s*$"#, options: .regularExpression) else {
            return nil
        }
        _ = head
        guard let callRegex = try? NSRegularExpression(
            pattern: #"\.replace\(\s*/([^/]*)/\s*,\s*'([^']*)'\s*\)"#
        ) else { return nil }
        var value = result
        let ns = trimmed as NSString
        let matches = callRegex.matches(in: trimmed, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }
        for match in matches {
            let pat = ns.substring(with: match.range(at: 1))
            let rep = ns.substring(with: match.range(at: 2))
            guard let regex = try? NSRegularExpression(pattern: pat) else { return nil }
            value = regex.stringByReplacingMatches(
                in: value,
                options: [],
                range: NSRange(value.startIndex..., in: value),
                withTemplate: rep
            )
        }
        return value
    }

    private static func leadingCaptureGroupIndex(_ rule: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"^\$(\d{1,2})"#),
              let match = regex.firstMatch(in: rule, range: NSRange(rule.startIndex..., in: rule)),
              let r = Range(match.range(at: 1), in: rule) else { return nil }
        return Int(rule[r])
    }

    private func substituteCaptureGroups(_ text: String, groups: [String]) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\$(\d{1,2})"#) else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var result = ""
        var last = 0
        for match in matches {
            let full = match.range
            if full.location > last {
                result += ns.substring(with: NSRange(location: last, length: full.location - last))
            }
            let num = Int(ns.substring(with: match.range(at: 1))) ?? -1
            if num >= 0, num < groups.count {
                result += groups[num]
            } else {
                result += ns.substring(with: full)
            }
            last = full.location + full.length
        }
        if last < ns.length {
            result += ns.substring(from: last)
        }
        return result
    }

    /// hashRule 形如 `##pattern` 或 `##pattern##replacement`（可再跟任意标记表示只替第一次）
    private func applyHashReplace(to value: String, hashRule: String) -> String {
        let body = hashRule.hasPrefix("##") ? String(hashRule.dropFirst(2)) : hashRule
        let parts = RuleSplitter.splitTopLevel(body, token: "##") ?? [body]
        guard let pattern = parts.first, !pattern.isEmpty else { return value }
        let replacement = parts.count > 1 ? parts[1] : ""
        let firstOnly = parts.count > 2
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        let full = NSRange(value.startIndex..., in: value)
        if firstOnly, let match = regex.firstMatch(in: value, range: full) {
            return regex.stringByReplacingMatches(
                in: value,
                options: [],
                range: match.range,
                withTemplate: replacement
            )
        }
        return regex.stringByReplacingMatches(
            in: value,
            options: [],
            range: full,
            withTemplate: replacement
        )
    }

    private func evalJSWithResult(
        _ jsCode: String,
        result: String,
        baseUrl: String?,
        groups: [String]
    ) -> String {
        let context = ExecutionContext()
        context.baseURL = baseUrl.flatMap { URL(string: $0) }
        context.lastResult = .list(groups)
        context.document = groups.first
        context.ruleEngine = self
        _ = context.jsContext
        let resultLiteral = jsonStringLiteralForJS(result)
        let baseLiteral = jsonStringLiteralForJS(baseUrl ?? "")
        context.jsContext.evaluateScript("var result = \(resultLiteral); var baseUrl = \(baseLiteral);")
        // 书源常把 match() 数组直接 java.put；强制 String() 避免 JSC→Swift 桥接抛错
        context.jsContext.evaluateScript("""
        (function(){
          if (typeof java === 'undefined' || !java || !java.put) return;
          var _put = java.put;
          java.put = function(k, v) {
            try { return _put(String(k), (v === undefined || v === null) ? '' : String(v)); }
            catch (e) { return ''; }
          };
        })();
        """)
        JSBridge.evaluateJsLib(of: context.source ?? boundSource, into: context.jsContext)
        var jsError: String?
        context.jsContext.exceptionHandler = { _, ex in jsError = ex?.toString() }
        let out = context.jsContext.evaluateScript(jsCode)?.toString() ?? ""
        if let jsError, !jsError.isEmpty {
            DebugLogger.shared.log("[getString/@js] \(jsError)")
            return ""
        }
        if out == "undefined" || out == "null" { return "" }
        return out
    }

    private func jsonStringLiteralForJS(_ value: String) -> String {
        legadoJSONEncodeStringLiteral(value)
    }
    
    /// 从 SwiftSoup Element 中提取字符串
    private func getStringFromElement(ruleStr: String, element: SwiftSoup.Element, baseUrl: String?) throws -> String {
        // 解析 CSS 选择器和属性
        var rule = ruleStr
        var attr = "text"
        
        // 检查 @attr 后缀
        if let atRange = rule.range(of: "@", options: .backwards) {
            let possibleAttr = String(rule[atRange.upperBound...])
            // 确保不是 CSS 选择器中的 @ 符号
            if !possibleAttr.contains(" ") && !possibleAttr.contains(".") {
                attr = possibleAttr
                rule = String(rule[..<atRange.lowerBound])
            }
        }
        
        // 空选择器直接从当前元素取
        if rule.isEmpty {
            return try extractAttr(element: element, attr: attr, baseUrl: baseUrl)
        }
        
        // 执行选择器（含 Legado text./class./id./tag. 前缀）
        guard let found = try LegadoCSSSelect.elements(in: element, selector: rule).first else {
            return ""
        }
        
        return try extractAttr(element: found, attr: attr, baseUrl: baseUrl)
    }
    
    /// 从元素提取指定属性
    private func extractAttr(element: SwiftSoup.Element, attr: String, baseUrl: String?) throws -> String {
        switch attr.lowercased() {
        case "text":
            return try element.text()
        case "textnodes":
            return element.textNodes().map { $0.text() }.joined(separator: "\n")
        case "html", "innerhtml":
            return try element.html()
        case "outerhtml":
            return try element.outerHtml()
        case "href":
            let href = try element.attr("href")
            return resolveUrl(href, baseUrl: baseUrl)
        case "src":
            let src = try element.attr("src")
            return resolveUrl(src, baseUrl: baseUrl)
        case "abs:href":
            return try element.attr("abs:href")
        case "abs:src":
            return try element.attr("abs:src")
        default:
            return try element.attr(attr)
        }
    }
    
    /// 从 JSON 字典中提取字符串
    private func getStringFromJson(ruleStr: String, json: [String: Any]) -> String {
        let path = normalizeJSONPath(ruleStr)
        let values = JSONPathParser.evaluate(path: path, root: json)
        guard let first = values.first else { return "" }
        return JSONPathParser.stringify(first) ?? ""
    }
    
    // MARK: - 获取字符串列表
    
    /// 获取字符串列表（用于目录列表等）
    func getStringList(ruleStr: String?, body: String, baseUrl: String?, isUrl: Bool = false) throws -> [String] {
        guard let ruleStr = ruleStr, !ruleStr.isEmpty else { return [] }

        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let rootInput: Any
        if trimmedBody.hasPrefix("{") || trimmedBody.hasPrefix("[") {
            rootInput = try JSONSerialization.jsonObject(with: body.data(using: .utf8) ?? Data())
        } else {
            rootInput = try SwiftSoup.parse(body)
        }

        if RuleSplitter.splitTopLevel(ruleStr, token: "&&") != nil {
            let values = evaluateChainedRule(ruleStr, inputs: [rootInput], baseUrl: baseUrl)
                .compactMap { stringifyOutput($0) }
            guard isUrl else { return values }
            return values.map { resolveUrl($0, baseUrl: baseUrl) }
        }
        
        let context = ExecutionContext()
        let isJson = trimmedBody.hasPrefix("{") || trimmedBody.hasPrefix("[")
        
        if isJson {
            context.jsonString = body
        } else {
            context.document = try SwiftSoup.parse(body)
        }
        context.baseURL = baseUrl.flatMap { URL(string: $0) }
        
        let result = try executeSingle(rule: ruleStr, context: context)
        let values = result.list ?? (result.string.map { [$0] } ?? [])
        guard isUrl else { return values }
        return values.map { resolveUrl($0, baseUrl: baseUrl) }
    }

    private func evaluateChainedRule(_ rule: String, inputs: [Any], baseUrl: String?) -> [Any] {
        let segments = RuleSplitter.splitTopLevel(rule, token: "&&") ?? [rule]
        var currentInputs = inputs

        for (index, rawSegment) in segments.enumerated() {
            let segment = rawSegment.trimmingCharacters(in: .whitespacesAndNewlines)
            let isTerminal = index == segments.count - 1
            currentInputs = currentInputs.flatMap { applyChainedSegment(segment, input: $0, baseUrl: baseUrl, terminal: isTerminal) }

            if currentInputs.isEmpty {
                break
            }
        }

        return currentInputs
    }

    private func applyChainedSegment(_ segment: String, input: Any, baseUrl: String?, terminal: Bool) -> [Any] {
        if let orSegments = RuleSplitter.splitTopLevel(segment, token: "||") {
            for item in orSegments {
                let values = applyChainedSegment(item.trimmingCharacters(in: .whitespacesAndNewlines), input: input, baseUrl: baseUrl, terminal: terminal)
                if !values.isEmpty {
                    return values
                }
            }
            return []
        }

        if terminal {
            do {
                let context = buildExecutionContext(for: input, baseUrl: baseUrl)
                let result = try executeSingle(rule: segment, context: context)
                switch result {
                case .string(let value):
                    return value.isEmpty ? [] : [value]
                case .list(let values):
                    return values
                case .none:
                    return []
                }
            } catch {
                return []
            }
        }

        if looksLikeJSONRule(segment) {
            return chainedJSONValues(for: segment, input: input)
        }

        if looksLikeXPathRule(segment) {
            return chainedXPathValues(for: segment, input: input)
        }

        return chainedCSSValues(for: segment, input: input, baseUrl: baseUrl)
    }

    private func looksLikeJSONRule(_ rule: String) -> Bool {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("@json:") || trimmed.hasPrefix("$")
    }

    private func looksLikeXPathRule(_ rule: String) -> Bool {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.lowercased().hasPrefix("@xpath:") || trimmed.hasPrefix("/")
    }

    private func chainedJSONValues(for rule: String, input: Any) -> [Any] {
        let normalizedRule: String
        if rule.lowercased().hasPrefix("@json:") {
            normalizedRule = String(rule.dropFirst(6))
        } else {
            normalizedRule = rule
        }

        let root: Any
        if let string = input as? String,
           let data = string.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            root = json
        } else {
            root = input
        }

        return JSONPathParser.evaluate(path: normalizedRule, root: root)
    }

    private func chainedXPathValues(for rule: String, input: Any) -> [Any] {
        let xpathRule = rule.lowercased().hasPrefix("@xpath:") ? String(rule.dropFirst(7)) : rule
        let html: String

        do {
            if let string = input as? String {
                html = string
            } else if let document = input as? SwiftSoup.Document {
                html = try document.outerHtml()
            } else if let element = input as? SwiftSoup.Element {
                html = try element.outerHtml()
            } else {
                return []
            }

            let doc = try Kanna.HTML(html: html, encoding: .utf8)
            return doc.xpath(xpathRule).compactMap { node in
                if let html = node.toHTML {
                    return html
                }
                return node.text
            }
        } catch {
            return []
        }
    }

    private func chainedCSSValues(for rule: String, input: Any, baseUrl: String?) -> [Any] {
        let (selector, attr) = parseChainedCSSSelector(rule)

        do {
            if let document = input as? SwiftSoup.Document {
                let elements = try LegadoCSSSelect.elements(in: document, selector: selector)
                return mapCSSElements(elements, attr: attr, baseUrl: baseUrl)
            }

            if let element = input as? SwiftSoup.Element {
                let elements = try LegadoCSSSelect.elements(in: element, selector: selector)
                return mapCSSElements(elements, attr: attr, baseUrl: baseUrl)
            }

            if let string = input as? String {
                let document = try SwiftSoup.parse(string)
                let elements = try LegadoCSSSelect.elements(in: document, selector: selector)
                return mapCSSElements(elements, attr: attr, baseUrl: baseUrl)
            }
        } catch {
            return []
        }

        return []
    }

    private func parseChainedCSSSelector(_ rule: String) -> (selector: String, attr: String?) {
        guard let atRange = rule.range(of: "@", options: .backwards) else {
            return (rule, nil)
        }

        let candidate = String(rule[atRange.upperBound...])
        if candidate.contains(" ") || candidate.contains(".") || candidate.contains("/") {
            return (rule, nil)
        }

        return (String(rule[..<atRange.lowerBound]), candidate)
    }

    private func mapCSSElements(_ elements: [SwiftSoup.Element], attr: String?, baseUrl: String?) -> [Any] {
        guard let attr, !attr.isEmpty else {
            return elements
        }

        return elements.compactMap { element in
            switch attr.lowercased() {
            case "text":
                return try? element.text()
            case "html", "innerhtml":
                return try? element.html()
            case "outerhtml":
                return try? element.outerHtml()
            case "href":
                guard let href = try? element.attr("href") else { return nil }
                return resolveUrl(href, baseUrl: baseUrl)
            case "src":
                guard let src = try? element.attr("src") else { return nil }
                return resolveUrl(src, baseUrl: baseUrl)
            default:
                return try? element.attr(attr)
            }
        }
    }

    private func stringifyOutput(_ value: Any) -> String? {
        if let string = value as? String {
            return string
        }
        if let element = value as? SwiftSoup.Element {
            return try? element.text()
        }
        return JSONPathParser.stringify(value)
    }
}

// MARK: - CSS 解析器 (SwiftSoup)
class CSSParser: RuleExecutor {
    var kind: RuleKind { .css }
    
    func canExecute(_ rule: String) -> Bool {
        return !rule.hasPrefix("//") && !rule.hasPrefix("$") && !rule.hasPrefix("{{")
    }
    
    func execute(_ rule: String, context: ExecutionContext) throws -> RuleResult {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        // Legado 目录常见 chapterName/Url 写作裸 `text` / `href`（相对当前元素取属性），
        // 不可当 CSS 选择器，否则 select("text") 空 → chapters=0。
        if Self.isTerminalAttr(trimmed) {
            let baseUrl = context.baseURL?.absoluteString
            let elements: [SwiftSoup.Element]
            if let document = context.document as? SwiftSoup.Document {
                elements = [document]
            } else if let element = context.document as? SwiftSoup.Element {
                elements = [element]
            } else if let html = context.document as? String {
                elements = [try SwiftSoup.parse(html)]
            } else {
                throw RuleError.noDocument
            }
            let values = try elements.map { try extractCSSValue(from: $0, attr: trimmed, baseUrl: baseUrl) }
                .filter { !$0.isEmpty }
            if values.count == 1 { return .string(values[0]) }
            if !values.isEmpty { return .list(values) }
            return .none
        }
        // Legado 默认规则用 `@` 串联选择器 / 属性 / js（如 class.x.0@tag.a.0@text）
        if trimmed.contains("@"), !trimmed.lowercased().hasPrefix("@css:"), !trimmed.hasPrefix("@@") {
            return try executeAtChain(trimmed, context: context)
        }

        let (selector, attr) = parseSelector(trimmed)
        let elements: [SwiftSoup.Element]
        let baseUrl = context.baseURL?.absoluteString

        if let document = context.document as? SwiftSoup.Document {
            elements = try LegadoCSSSelect.elements(in: document, selector: selector)
        } else if let element = context.document as? SwiftSoup.Element {
            elements = try LegadoCSSSelect.elements(in: element, selector: selector)
        } else if let html = context.document as? String {
            let document = try SwiftSoup.parse(html)
            elements = try LegadoCSSSelect.elements(in: document, selector: selector)
        } else {
            throw RuleError.noDocument
        }

        let values = try elements.map { element in
            try extractCSSValue(from: element, attr: attr, baseUrl: baseUrl)
        }

        if values.count == 1, let first = values.first {
            return .string(first)
        } else if !values.isEmpty {
            return .list(values)
        }

        return .none
    }

    /// `sel1@sel2@attr` / `a[data-bid]@data-bid@js:'…'+result`
    private func executeAtChain(_ rule: String, context: ExecutionContext) throws -> RuleResult {
        // 必须用括号/引号安全切分：RuleAnalyzer 对 `a[data-bid]@…@js:'…'` 常切不开，
        // 会把整串当选择器再取 text，bookUrl 变成书名+简介。
        let parts = (RuleSplitter.splitTopLevel(rule, token: "@") ?? [rule])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return .none }

        let root: SwiftSoup.Element
        if let document = context.document as? SwiftSoup.Document {
            root = document
        } else if let element = context.document as? SwiftSoup.Element {
            root = element
        } else if let html = context.document as? String {
            root = try SwiftSoup.parse(html)
        } else {
            throw RuleError.noDocument
        }

        let baseUrl = context.baseURL?.absoluteString
        var elements: [SwiftSoup.Element] = [root]
        var stringResult: String?

        for (idx, part) in parts.enumerated() {
            let isLast = idx == parts.count - 1
            let lower = part.lowercased()

            if lower.hasPrefix("js:") || lower.hasPrefix("@js:") {
                let jsCode = lower.hasPrefix("@js:") ? String(part.dropFirst(4)) : String(part.dropFirst(3))
                let input = stringResult
                    ?? (try? elements.first.map { try $0.text() } ?? "")
                    ?? ""
                // 常见书源写法：'https://m.qidian.com/book/'+result+'/' —— 不依赖 JSC 全局注入
                if let swiftOut = Self.evalSimpleResultConcat(jsCode, result: input) {
                    stringResult = swiftOut
                } else {
                    stringResult = Self.evalAtChainJS(jsCode, result: input, baseUrl: baseUrl)
                }
                elements = []
                continue
            }

            if isLast && Self.isTerminalAttr(part) {
                if let s = stringResult { return s.isEmpty ? .none : .string(s) }
                let values = try elements.map { try extractCSSValue(from: $0, attr: part, baseUrl: baseUrl) }
                    .filter { !$0.isEmpty }
                if values.count == 1 { return .string(values[0]) }
                if !values.isEmpty { return .list(values) }
                return .none
            }

            // 中间段若已是字符串（如 data-bid），不可再当选择器
            if stringResult != nil {
                if isLast { return stringResult!.isEmpty ? .none : .string(stringResult!) }
                continue
            }

            // 中间段 text/html/…：先抽成字符串，供后续 @js（领域：#content@html@js:…）。
            // 不可当 CSS 选择器，否则 select("html") 空结果 → 正文 beforeLen=0。
            if !isLast && Self.isValueExtractMidAttr(part) {
                let values = try elements.map { try extractCSSValue(from: $0, attr: part, baseUrl: baseUrl) }
                    .filter { !$0.isEmpty }
                stringResult = values.joined(separator: "\n")
                elements = []
                continue
            }

            // 纯属性段（非末段）：把元素收成属性字符串，供后续 @js 使用。
            // 仅认「像属性」的名字（href/data-bid 等）；勿把标签名 a/div/li 当成属性，
            // 否则 `a@text` / `tag.a@href` 中间段会空结果 → 目录 chapters=0。
            if Self.isMidChainAttributeName(part) {
                let values = try elements.map { try extractCSSValue(from: $0, attr: part, baseUrl: baseUrl) }
                    .filter { !$0.isEmpty }
                var bid = values.first ?? ""
                // 选择结果无属性时，回落当前根节点（li[data-bid]）
                if bid.isEmpty, let v = try? root.attr(part), !v.isEmpty {
                    bid = v
                }
                stringResult = bid
                elements = []
                continue
            }

            var next: [SwiftSoup.Element] = []
            for el in elements {
                next.append(contentsOf: try LegadoCSSSelect.elements(in: el, selector: part))
            }
            elements = next
            // 选择器空且非末段：勿直接失败，尝试从当前节点取同名属性（li[data-bid]）
            if elements.isEmpty && !isLast {
                if let attrSel = Self.parseLooseAttrName(part),
                   let v = try? root.attr(attrSel), !v.isEmpty {
                    stringResult = v
                    continue
                }
                return .none
            }
        }

        if let s = stringResult {
            return s.isEmpty ? .none : .string(s)
        }
        let values = try elements.map { try extractCSSValue(from: $0, attr: "text", baseUrl: baseUrl) }
            .filter { !$0.isEmpty }
        if values.count == 1 { return .string(values[0]) }
        if !values.isEmpty { return .list(values) }
        return .none
    }

    private static func parseLooseAttrName(_ part: String) -> String? {
        // a[data-bid] / [data-bid]
        if let open = part.firstIndex(of: "["), let close = part.firstIndex(of: "]"), open < close {
            let inside = String(part[part.index(after: open)..<close])
            let name = inside.split(separator: "=").first.map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty ? nil : name
        }
        return nil
    }

    private static func isTerminalAttr(_ part: String) -> Bool {
        let lower = part.lowercased()
        // 含 `@` 的是链式规则（a@text / a@href / #list dd@html），必须走 executeAtChain；
        // 整串当属性名会 el.attr("a@text")=="" → 章名空 → chapters=0 卡死 nativeRead（6dad7d1 回归）。
        if part.contains("@") { return false }
        if lower.hasPrefix("js:") || lower.hasPrefix("@js:") { return false }
        if lower.hasPrefix("class.") || lower.hasPrefix("tag.") || lower.hasPrefix("id.") || lower.hasPrefix("text.") {
            return false
        }
        if part.contains("[") || part.contains(">") || part.contains(" ") { return false }
        if part.hasPrefix(".") || part.hasPrefix("#") || part.hasPrefix("//") { return false }
        // text / html / href / src / data-bid 等
        return true
    }

    /// 中间段值抽取：`#content@html@js:` / `div@text@js:`（非 CSS 选择器）。
    private static func isValueExtractMidAttr(_ part: String) -> Bool {
        let lower = part.lowercased()
        return [
            "text", "html", "innerhtml", "outerhtml",
            "owntext", "textnodes", "all",
        ].contains(lower)
    }

    /// 非末段何时当属性：含 `-`（data-bid）或常见属性名；排除 a/div/span 等标签名。
    private static func isMidChainAttributeName(_ part: String) -> Bool {
        let lower = part.lowercased()
        if isValueExtractMidAttr(part) { return false }
        if !isTerminalAttr(part) { return false }
        if lower.contains("-") { return true }
        let known: Set<String> = [
            "href", "src", "id", "class", "value", "title", "alt", "name", "type",
            "content", "outerhtml", "innerhtml", "owntext", "textnodes", "all",
            "checked", "selected", "disabled", "placeholder", "action", "method",
        ]
        return known.contains(lower)
    }

    /// `'prefix'+result+'suffix'` / `"prefix"+result+"suffix"`（可省略一侧）
    private static func evalSimpleResultConcat(_ jsCode: String, result: String) -> String? {
        let trimmed = jsCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("result") else { return nil }
        let pattern = #"^\s*(?:'([^']*)'|"([^"]*)")\s*\+\s*result\s*(?:\+\s*(?:'([^']*)'|"([^"]*)"))?\s*;?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, range: range) else { return nil }
        func group(_ idx: Int) -> String {
            guard let r = Range(match.range(at: idx), in: trimmed) else { return "" }
            return String(trimmed[r])
        }
        let prefix = group(1).isEmpty ? group(2) : group(1)
        let suffix = group(3).isEmpty ? group(4) : group(3)
        return prefix + result + suffix
    }

    /// @ 链内嵌 js：用 JSON 字面量注入 result/baseUrl，避免 setValue:forKey 未落到 JS 全局
    private static func evalAtChainJS(_ jsCode: String, result: String, baseUrl: String?) -> String {
        guard let jsCtx = JSContext() else { return "" }
        var jsError: String?
        jsCtx.exceptionHandler = { _, exc in jsError = exc?.toString() }
        let resultLiteral = jsonStringLiteral(result)
        let baseLiteral = jsonStringLiteral(baseUrl ?? "")
        jsCtx.evaluateScript("var result = \(resultLiteral); var baseUrl = \(baseLiteral);")
        if let jsError, !jsError.isEmpty {
            return ""
        }
        let out = jsCtx.evaluateScript(jsCode)?.toString() ?? ""
        if let jsError, !jsError.isEmpty {
            return ""
        }
        if out == "undefined" || out == "null" { return "" }
        return out
    }

    private static func jsonStringLiteral(_ value: String) -> String {
        legadoJSONEncodeStringLiteral(value)
    }
    
    private func parseSelector(_ rule: String) -> (String, String) {
        var selector = rule
        var attr = "text"
        
        if let range = rule.range(of: "@") {
            selector = String(rule[..<range.lowerBound])
            attr = String(rule[range.upperBound...])
        }

        return (selector, attr)
    }

    private func extractCSSValue(from element: SwiftSoup.Element, attr: String, baseUrl: String?) throws -> String {
        switch attr.lowercased() {
        case "text":
            return try element.text()
        case "textnodes":
            return element.textNodes().map { $0.text() }.joined(separator: "\n")
        case "html", "innerhtml":
            return try element.html()
        case "outerhtml":
            return try element.outerHtml()
        case "href":
            return resolveUrl(try element.attr("href"), baseUrl: baseUrl)
        case "src":
            return resolveUrl(try element.attr("src"), baseUrl: baseUrl)
        case "abs:href":
            return resolveUrl(try element.attr("href"), baseUrl: baseUrl)
        case "abs:src":
            return resolveUrl(try element.attr("src"), baseUrl: baseUrl)
        default:
            return try element.attr(attr)
        }
    }
}

// MARK: - XPath 解析器 (Kanna)
class XPathParser: RuleExecutor {
    var kind: RuleKind { .xpath }
    
    func canExecute(_ rule: String) -> Bool {
        return rule.hasPrefix("//")
    }
    
    func execute(_ rule: String, context: ExecutionContext) throws -> RuleResult {
        let html: String
        if let string = context.document as? String {
            html = string
        } else if let document = context.document as? SwiftSoup.Document {
            html = try document.outerHtml()
        } else if let element = context.document as? SwiftSoup.Element {
            html = try element.outerHtml()
        } else {
            throw RuleError.noDocument
        }

        let doc = try Kanna.HTML(html: html, encoding: .utf8)
        
        var results: [String] = []
        for node in doc.xpath(rule) {
            if let text = node.text {
                results.append(text)
            }
        }
        
        if results.count == 1 {
            return .string(results[0])
        } else if !results.isEmpty {
            return .list(results)
        }
        
        return .none
    }
}

// MARK: - JSONPath 解析器
class JSONPathParser: RuleExecutor {
    var kind: RuleKind { .jsonPath }
    
    func canExecute(_ rule: String) -> Bool {
        return rule.hasPrefix("$")
    }
    
    func execute(_ rule: String, context: ExecutionContext) throws -> RuleResult {
        let root = try loadJSONRoot(from: context)
        let values = Self.evaluate(path: rule, root: root)
        return Self.toRuleResult(values)
    }

    static func evaluate(path: String, root: Any) -> [Any] {
        let resolvedPath = resolveInnerRules(in: path, root: root)
        return JSONPathEvaluator.evaluate(path: resolvedPath, root: root)
    }

    static func stringify(_ value: Any) -> String? {
        JSONPathEvaluator.stringify(value)
    }

    private func loadJSONRoot(from context: ExecutionContext) throws -> Any {
        if let cached = context.jsonValue {
            return cached
        }

        if let dict = context.jsonDict {
            context.jsonValue = dict
            return dict
        }

        if let jsonString = context.jsonString,
           let data = jsonString.data(using: .utf8) {
            let object = try JSONSerialization.jsonObject(with: data)
            context.jsonValue = object
            if let dict = object as? [String: Any] {
                context.jsonDict = dict
            }
            return object
        }

        throw RuleError.noDocument
    }

    private static func resolveInnerRules(in path: String, root: Any, depth: Int = 0) -> String {
        guard depth < 10 else { return path }

        let analyzer = RuleAnalyzer(data: path, code: true)
        let resolved = analyzer.innerRule(inner: "{$.") { innerRule in
            let nestedPath = resolveInnerRules(in: innerRule, root: root, depth: depth + 1)
            let values = JSONPathEvaluator.evaluate(path: nestedPath, root: root)
            guard let first = values.first else { return "" }
            return stringify(first) ?? ""
        }

        return resolved.isEmpty ? path : resolved
    }

    private static func toRuleResult(_ values: [Any]) -> RuleResult {
        guard !values.isEmpty else { return .none }

        if values.count == 1, let array = values[0] as? [Any] {
            let strings = array.compactMap { stringify($0) }
            guard !strings.isEmpty else { return .none }
            if strings.count == 1 {
                return .string(strings[0])
            }
            return .list(strings)
        }

        if values.count == 1, let string = stringify(values[0]) {
            return .string(string)
        }

        let strings = values.compactMap { stringify($0) }
        guard !strings.isEmpty else { return .none }
        if strings.count == 1 {
            return .string(strings[0])
        }
        return .list(strings)
    }
}

private enum JSONPathEvaluator {
    private enum Segment {
        case key(String)
        case wildcard
        case index(Int)
        case slice(Int?, Int?)
        case filter(FilterExpression)
    }

    private struct FilterExpression {
        let keyPath: [String]
        let `operator`: FilterOperator
        let expected: FilterValue
    }

    private enum FilterOperator: String {
        case equal = "=="
        case notEqual = "!="
        case lessThan = "<"
        case lessThanOrEqual = "<="
        case greaterThan = ">"
        case greaterThanOrEqual = ">="
    }

    private enum FilterValue: Equatable {
        case string(String)
        case number(Double)
        case bool(Bool)
        case null
    }

    static func evaluate(path: String, root: Any) -> [Any] {
        guard let segments = parse(path: path) else { return [] }

        var current: [Any] = [root]
        for segment in segments {
            current = apply(segment: segment, to: current)
            if current.isEmpty { break }
        }
        return current
    }

    static func stringify(_ value: Any) -> String? {
        if let string = value as? String { return string }
        if let bool = boolValue(from: value) { return bool ? "true" : "false" }
        if let number = numberValue(from: value) { return number.stringValue }
        if value is NSNull { return "null" }

        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let jsonString = String(data: data, encoding: .utf8) {
            return jsonString
        }

        return nil
    }

    private static func parse(path: String) -> [Segment]? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("$") else { return nil }
        if trimmed == "$" { return [] }

        var segments: [Segment] = []
        var index = trimmed.index(after: trimmed.startIndex)

        while index < trimmed.endIndex {
            let char = trimmed[index]

            if char == "." {
                index = trimmed.index(after: index)
                guard index < trimmed.endIndex else { return nil }

                if trimmed[index] == "*" {
                    segments.append(.wildcard)
                    index = trimmed.index(after: index)
                    continue
                }

                let keyStart = index
                while index < trimmed.endIndex {
                    let currentChar = trimmed[index]
                    if currentChar == "." || currentChar == "[" { break }
                    index = trimmed.index(after: index)
                }

                let key = String(trimmed[keyStart..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { return nil }
                segments.append(.key(key))
                continue
            }

            if char == "[" {
                guard let closeIndex = findClosingBracket(in: trimmed, from: index) else { return nil }
                let rawContent = String(trimmed[trimmed.index(after: index)..<closeIndex])
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                guard let segment = parseBracketSegment(rawContent) else { return nil }
                segments.append(segment)
                index = trimmed.index(after: closeIndex)
                continue
            }

            let keyStart = index
            while index < trimmed.endIndex {
                let currentChar = trimmed[index]
                if currentChar == "." || currentChar == "[" { break }
                index = trimmed.index(after: index)
            }

            let key = String(trimmed[keyStart..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return nil }
            segments.append(.key(key))
        }

        return segments
    }

    private static func findClosingBracket(in path: String, from openIndex: String.Index) -> String.Index? {
        var index = path.index(after: openIndex)
        var inSingleQuote = false
        var inDoubleQuote = false
        var parenthesesDepth = 0

        while index < path.endIndex {
            let char = path[index]

            if char == "\\" {
                index = path.index(after: index)
                if index < path.endIndex {
                    index = path.index(after: index)
                }
                continue
            }

            if char == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
                index = path.index(after: index)
                continue
            }

            if char == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
                index = path.index(after: index)
                continue
            }

            if !inSingleQuote && !inDoubleQuote {
                if char == "(" {
                    parenthesesDepth += 1
                } else if char == ")" && parenthesesDepth > 0 {
                    parenthesesDepth -= 1
                } else if char == "]" && parenthesesDepth == 0 {
                    return index
                }
            }

            index = path.index(after: index)
        }

        return nil
    }

    private static func parseBracketSegment(_ content: String) -> Segment? {
        if content == "*" {
            return .wildcard
        }

        if content.hasPrefix("?("), content.hasSuffix(")") {
            let filterExpr = String(content.dropFirst(2).dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let filter = parseFilter(filterExpr) else { return nil }
            return .filter(filter)
        }

        if content.contains(":") {
            let parts = content.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }

            let startText = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let endText = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)

            let start = startText.isEmpty ? nil : Int(startText)
            let end = endText.isEmpty ? nil : Int(endText)

            if (!startText.isEmpty && start == nil) || (!endText.isEmpty && end == nil) {
                return nil
            }
            if start == nil && end == nil {
                return nil
            }

            return .slice(start, end)
        }

        if let quotedKey = parseQuotedString(content) {
            return .key(quotedKey)
        }

        if let index = Int(content) {
            return .index(index)
        }

        if !content.isEmpty {
            return .key(content)
        }

        return nil
    }

    private static func parseQuotedString(_ input: String) -> String? {
        guard input.count >= 2,
              let first = input.first,
              let last = input.last,
              first == last,
              first == "'" || first == "\"" else {
            return nil
        }

        var value = String(input.dropFirst().dropLast())
        if first == "'" {
            value = value.replacingOccurrences(of: "\\'", with: "'")
        } else {
            value = value.replacingOccurrences(of: "\\\"", with: "\"")
        }
        value = value.replacingOccurrences(of: "\\\\", with: "\\")
        return value
    }

    private static func parseFilter(_ expression: String) -> FilterExpression? {
        let pattern = #"^@\.(.+?)\s*(==|!=|<=|>=|<|>)\s*(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: expression,
                range: NSRange(expression.startIndex..., in: expression)
              ),
              let pathRange = Range(match.range(at: 1), in: expression),
              let opRange = Range(match.range(at: 2), in: expression),
              let expectedRange = Range(match.range(at: 3), in: expression) else {
            return nil
        }

        let keyPath = expression[pathRange]
            .split(separator: ".")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !keyPath.isEmpty else { return nil }

        guard let op = FilterOperator(rawValue: String(expression[opRange])) else {
            return nil
        }

        let expectedText = String(expression[expectedRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let expected = parseFilterValue(expectedText) else { return nil }

        return FilterExpression(keyPath: keyPath, operator: op, expected: expected)
    }

    private static func parseFilterValue(_ input: String) -> FilterValue? {
        if let quoted = parseQuotedString(input) {
            return .string(quoted)
        }

        switch input.lowercased() {
        case "true":
            return .bool(true)
        case "false":
            return .bool(false)
        case "null":
            return .null
        default:
            break
        }

        if let number = Double(input) {
            return .number(number)
        }

        if !input.isEmpty {
            return .string(input)
        }

        return nil
    }

    private static func apply(segment: Segment, to values: [Any]) -> [Any] {
        switch segment {
        case .key(let key):
            return values.compactMap { applyKey($0, key: key) }

        case .wildcard:
            return values.flatMap { value in
                if let dict = value as? [String: Any] {
                    return Array(dict.values)
                }
                if let array = value as? [Any] {
                    return array
                }
                return []
            }

        case .index(let index):
            return values.compactMap { value in
                guard let array = value as? [Any] else { return nil }
                return valueAtIndex(array, index: index)
            }

        case .slice(let start, let end):
            return values.flatMap { value in
                guard let array = value as? [Any] else { return [] }
                return slice(array, start: start, end: end)
            }

        case .filter(let filter):
            return values.flatMap { value in
                guard let array = value as? [Any] else { return [] }
                return array.filter { matchesFilter(item: $0, filter: filter) }
            }
        }
    }

    private static func applyKey(_ value: Any, key: String) -> Any? {
        if let dict = value as? [String: Any] {
            return dict[key]
        }

        if let array = value as? [Any], let index = Int(key) {
            return valueAtIndex(array, index: index)
        }

        return nil
    }

    private static func valueAtIndex(_ array: [Any], index: Int) -> Any? {
        let resolvedIndex = index >= 0 ? index : array.count + index
        guard resolvedIndex >= 0, resolvedIndex < array.count else { return nil }
        return array[resolvedIndex]
    }

    private static func slice(_ array: [Any], start: Int?, end: Int?) -> [Any] {
        guard !array.isEmpty else { return [] }

        let lowerBound = normalizedSliceBound(start, count: array.count, defaultValue: 0)
        let upperBound = normalizedSliceBound(end, count: array.count, defaultValue: array.count)

        guard lowerBound < upperBound else { return [] }
        return Array(array[lowerBound..<upperBound])
    }

    private static func normalizedSliceBound(_ value: Int?, count: Int, defaultValue: Int) -> Int {
        guard let value else { return defaultValue }
        let resolved = value >= 0 ? value : count + value
        return min(max(resolved, 0), count)
    }

    private static func matchesFilter(item: Any, filter: FilterExpression) -> Bool {
        guard let value = value(at: filter.keyPath, in: item),
              let lhs = filterValue(from: value) else {
            return false
        }

        return compare(lhs: lhs, rhs: filter.expected, op: filter.operator)
    }

    private static func value(at keyPath: [String], in item: Any) -> Any? {
        var current: Any? = item

        for key in keyPath {
            guard let value = current else { return nil }

            if let dict = value as? [String: Any] {
                current = dict[key]
                continue
            }

            if let array = value as? [Any], let index = Int(key) {
                current = valueAtIndex(array, index: index)
                continue
            }

            return nil
        }

        return current
    }

    private static func filterValue(from value: Any) -> FilterValue? {
        if value is NSNull { return .null }
        if let string = value as? String { return .string(string) }
        if let bool = boolValue(from: value) { return .bool(bool) }
        if let number = numberValue(from: value) { return .number(number.doubleValue) }
        return nil
    }

    private static func compare(lhs: FilterValue, rhs: FilterValue, op: FilterOperator) -> Bool {
        switch op {
        case .equal:
            return lhs == rhs
        case .notEqual:
            return lhs != rhs
        case .lessThan, .lessThanOrEqual, .greaterThan, .greaterThanOrEqual:
            return compareOrdered(lhs: lhs, rhs: rhs, op: op)
        }
    }

    private static func compareOrdered(
        lhs: FilterValue,
        rhs: FilterValue,
        op: FilterOperator
    ) -> Bool {
        switch (lhs, rhs) {
        case (.number(let left), .number(let right)):
            switch op {
            case .lessThan:
                return left < right
            case .lessThanOrEqual:
                return left <= right
            case .greaterThan:
                return left > right
            case .greaterThanOrEqual:
                return left >= right
            default:
                return false
            }

        case (.string(let left), .string(let right)):
            let result = left.compare(right)
            switch op {
            case .lessThan:
                return result == .orderedAscending
            case .lessThanOrEqual:
                return result == .orderedAscending || result == .orderedSame
            case .greaterThan:
                return result == .orderedDescending
            case .greaterThanOrEqual:
                return result == .orderedDescending || result == .orderedSame
            default:
                return false
            }

        default:
            return false
        }
    }

    private static func boolValue(from value: Any) -> Bool? {
        if let bool = value as? Bool { return bool }
        guard let number = value as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue
        }
        return nil
    }

    private static func numberValue(from value: Any) -> NSNumber? {
        if value is Bool { return nil }
        guard let number = value as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return nil
        }
        return number
    }
}

// MARK: - 正则解析器
class RegexParser: RuleExecutor {
    var kind: RuleKind { .regex }
    
    func canExecute(_ rule: String) -> Bool {
        return rule.hasPrefix("regex:") || rule.contains("{{regex")
    }
    
    func execute(_ rule: String, context: ExecutionContext) throws -> RuleResult {
        guard let input = context.lastResult.string ?? (context.document as? String) else {
            throw RuleError.noDocument
        }
        
        let pattern = rule.replacingOccurrences(of: "regex:", with: "")
        
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            throw RuleError.invalidRule("无效正则：\(pattern)")
        }
        
        let range = NSRange(input.startIndex..., in: input)
        var results: [String] = []
        
        for match in regex.matches(in: input, range: range) {
            if let matchRange = Range(match.range, in: input) {
                results.append(String(input[matchRange]))
            }
        }
        
        if results.count == 1 {
            return .string(results[0])
        } else if !results.isEmpty {
            return .list(results)
        }
        
        return .none
    }
}

// MARK: - JavaScript 解析器
class JavaScriptParser: RuleExecutor {
    var kind: RuleKind { .js }
    
    func canExecute(_ rule: String) -> Bool {
        let lower = rule.lowercased()
        return lower.contains("{{js") || lower.contains("<js>") || lower.hasPrefix("@js:")
    }
    
    func execute(_ rule: String, context: ExecutionContext) throws -> RuleResult {
        let jsCode = extractJS(rule)
        // JSON 字面量注入，避免 setValue:forKey 未落到 JS 全局（同 @ 链修复）
        let resultText: String = {
            if case .string(let s) = context.lastResult { return s }
            if case .list(let vals) = context.lastResult { return vals.first ?? "" }
            return (context.document as? String) ?? ""
        }()
        let resultLiteral = jsonLiteral(resultText)
        let baseLiteral = jsonLiteral(context.baseURL?.absoluteString ?? "")
        _ = context.jsContext
        context.jsContext.evaluateScript("var result = \(resultLiteral); var baseUrl = \(baseLiteral);")
        JSBridge.evaluateJsLib(of: context.source, into: context.jsContext)
        var jsError: String?
        context.jsContext.exceptionHandler = { _, ex in jsError = ex?.toString() }
        let jsValue = context.jsContext.evaluateScript(jsCode)
        if let jsError, !jsError.isEmpty {
            throw RuleError.executionFailed(jsError)
        }
        if let string = jsValue?.toString(), string != "undefined", string != "null" {
            return .string(string)
        }
        return .none
    }

    private func jsonLiteral(_ value: String) -> String {
        legadoJSONEncodeStringLiteral(value)
    }
    
    private func extractJS(_ rule: String) -> String {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("@js:") {
            return String(trimmed.dropFirst(4))
        }
        let patterns = [
            #"{{js(.*?)}}"#,
            #"<js>(.*?)</js>"#
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
               let match = regex.firstMatch(
                in: rule,
                range: NSRange(rule.startIndex..., in: rule)
               ),
               let range = Range(match.range(at: 1), in: rule) {
                return String(rule[range]).trimmingCharacters(in: .whitespaces)
            }
        }
        
        return rule
    }
}

// MARK: - 错误类型
enum RuleError: LocalizedError {
    case noDocument
    case invalidRule(String)
    case unsupportedRule(String)
    case executionFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .noDocument: return "缺少文档"
        case .invalidRule(let rule): return "无效规则：\(rule)"
        case .unsupportedRule(let rule): return "不支持的规则：\(rule)"
        case .executionFailed(let error): return "执行失败：\(error)"
        }
    }
}
