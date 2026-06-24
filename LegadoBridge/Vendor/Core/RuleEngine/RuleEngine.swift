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
    var variables: [String: String] = [:]
    var lastResult: RuleResult = .none
    
    lazy var jsContext: JSContext = {
        let context = JSContext()!

        let bridge = JSBridge()
        bridge.context = self
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
    
    init() {
        // 按优先级注册解析器
        executors.append(JSONPathParser())
        executors.append(XPathParser())
        executors.append(CSSParser())
        executors.append(RegexParser())
        executors.append(JavaScriptParser())
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
        context.source = sourceContext?.source
        context.baseURL = URL(string: baseUrl ?? sourceContext?.baseURL?.absoluteString ?? "")
        context.lastResult = sourceContext?.lastResult ?? .none

        guard let input else {
            return context
        }

        if let jsonObject = input as? [String: Any] {
            context.jsonDict = jsonObject
            context.jsonValue = jsonObject
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
    /// - Returns: 元素上下文数组
    func getElements(ruleStr: String?, body: String, baseUrl: String?) throws -> [ElementContext] {
        guard let ruleStr = ruleStr, !ruleStr.isEmpty else { return [] }
        
        let isJson = body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") ||
                     body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[")
        
        if isJson {
            return try getJsonElements(ruleStr: ruleStr, body: body)
        } else {
            return try getHtmlElements(ruleStr: ruleStr, body: body, baseUrl: baseUrl)
        }
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
        } else {
            // CSS
            let selected = try doc.select(rule)
            elements = selected.array().map { ElementContext(element: $0, baseUrl: baseUrl) }
        }
        
        if reverse { elements.reverse() }
        return elements
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

        if RuleSplitter.splitTopLevel(ruleStr, token: "&&") != nil {
            let values = evaluateChainedRule(ruleStr, inputs: [elementContext.element], baseUrl: effectiveBaseUrl)
            return values.compactMap { stringifyOutput($0) }.joined(separator: "\n")
        }

        do {
            let context = buildExecutionContext(for: elementContext.element, baseUrl: effectiveBaseUrl)
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
        
        // 执行选择器
        guard let found = try element.select(rule).first() else {
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
                let elements = selector.isEmpty ? [document] : try document.select(selector).array()
                return mapCSSElements(elements, attr: attr, baseUrl: baseUrl)
            }

            if let element = input as? SwiftSoup.Element {
                let elements = selector.isEmpty ? [element] : try element.select(selector).array()
                return mapCSSElements(elements, attr: attr, baseUrl: baseUrl)
            }

            if let string = input as? String {
                let document = try SwiftSoup.parse(string)
                let elements = selector.isEmpty ? [document] : try document.select(selector).array()
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
        let (selector, attr) = parseSelector(rule)
        let elements: [SwiftSoup.Element]
        let baseUrl = context.baseURL?.absoluteString

        if let document = context.document as? SwiftSoup.Document {
            if selector.isEmpty {
                elements = [document]
            } else {
                elements = try document.select(selector).array()
            }
        } else if let element = context.document as? SwiftSoup.Element {
            if selector.isEmpty {
                elements = [element]
            } else {
                elements = try element.select(selector).array()
            }
        } else if let html = context.document as? String {
            let document = try SwiftSoup.parse(html)
            if selector.isEmpty {
                elements = [document]
            } else {
                elements = try document.select(selector).array()
            }
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
        return rule.contains("{{js") || rule.contains("<js>")
    }
    
    func execute(_ rule: String, context: ExecutionContext) throws -> RuleResult {
        let jsCode = extractJS(rule)
        
        context.jsContext.setValue(context.lastResult.string, forKey: "result")
        context.jsContext.setValue(context.baseURL?.absoluteString, forKey: "baseUrl")
        
        let jsValue = context.jsContext.evaluateScript(jsCode)
        
        if let string = jsValue?.toString() {
            return .string(string)
        }
        
        return .none
    }
    
    private func extractJS(_ rule: String) -> String {
        let patterns = [
            #"{{js(.*?)}}"#,
            #"<js>(.*?)</js>"#
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
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
