//
//  SourceRule.swift
//  Legado-iOS
//
//  规则解析类 - 对标 Android AnalyzeRule.SourceRule
//

import Foundation

/// 规则模式
enum RuleMode {
    case xpath      // XPath 规则
    case json       // JSONPath 规则
    case css        // CSS 选择器
    case js         // JavaScript 规则
    case regex      // 正则规则
    case `default`  // 默认规则
}

/// 规则解析结果
class SourceRule {
    var mode: RuleMode = .default
    var rule: String = ""
    var replaceRegex: String = ""
    var replacement: String = ""
    var replaceFirst: Bool = false
    var putMap: [String: String] = [:]
    
    private var ruleParam: [String] = []
    private var ruleType: [Int] = []
    
    private let getRuleType = -2
    private let jsRuleType = -1
    private let defaultRuleType = 0
    
    init(ruleStr: String, mode: RuleMode = .default, isJSON: Bool = false) {
        parse(ruleStr: ruleStr, initialMode: mode, isJSON: isJSON)
    }
    
    // MARK: - 解析
    
    private func parse(ruleStr: String, initialMode: RuleMode, isJSON: Bool) {
        var currentMode = initialMode
        
        // 确定规则模式
        if currentMode == .js || currentMode == .regex {
            rule = ruleStr
        } else if ruleStr.lowercased().hasPrefix("@css:") {
            currentMode = .css
            rule = String(ruleStr.dropFirst(5))
        } else if ruleStr.hasPrefix("@@") {
            currentMode = .default
            rule = String(ruleStr.dropFirst(2))
        } else if ruleStr.lowercased().hasPrefix("@xpath:") {
            currentMode = .xpath
            rule = String(ruleStr.dropFirst(7))
        } else if ruleStr.lowercased().hasPrefix("@json:") {
            currentMode = .json
            rule = String(ruleStr.dropFirst(6))
        } else if isJSON || ruleStr.hasPrefix("$.") || ruleStr.hasPrefix("$[") {
            currentMode = .json
            rule = ruleStr
        } else if ruleStr.hasPrefix("/") {
            currentMode = .xpath
            rule = ruleStr
        } else {
            rule = ruleStr
        }
        
        self.mode = currentMode
        
        // 分离 @put 规则
        rule = splitPutRule(rule)
        
        // 解析 @get, {{ }}, 和正则
        parseEvalAndRegex(rule)
    }
    
    /// 分离 @put 规则
    private func splitPutRule(_ ruleStr: String) -> String {
        var result = ruleStr
        let putPattern = #"@put:\s*(\{[^}]+?\})"#
        
        guard let regex = try? NSRegularExpression(pattern: putPattern, options: .caseInsensitive) else {
            return result
        }
        
        let range = NSRange(result.startIndex..., in: result)
        var matches: [NSTextCheckingResult] = []
        regex.enumerateMatches(in: result, range: range) { match, _, _ in
            if let match = match { matches.append(match) }
        }
        
        // 从后往前替换，避免索引变化
        for match in matches.reversed() {
            if let jsonRange = Range(match.range(at: 1), in: result) {
                let jsonStr = String(result[jsonRange])
                if let dict = parsePutJson(jsonStr) {
                    putMap.merge(dict) { (_, new) in new }
                }
            }
            if let fullRange = Range(match.range, in: result) {
                result.removeSubrange(fullRange)
            }
        }
        
        return result
    }
    
    /// 解析 @put JSON
    private func parsePutJson(_ jsonStr: String) -> [String: String]? {
        guard let data = jsonStr.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            // 尝试非标准 JSON
            let cleaned = jsonStr
                .replacingOccurrences(of: "'", with: "\"")
                .replacingOccurrences(of: "(\\w+):", with: "\"$1\":", options: .regularExpression)
            guard let data = cleaned.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                return nil
            }
            return dict
        }
        return dict
    }
    
    /// 解析 @get, {{ }} 和正则
    private func parseEvalAndRegex(_ ruleStr: String) {
        var start = 0
        var result = ruleStr
        
        // 匹配 @get:{...} 或 {{...}}
        let evalPattern = #"@get:\{[^}]+?\}|\{\{[\w\W]*?\}\}"#
        
        guard let regex = try? NSRegularExpression(pattern: evalPattern, options: .caseInsensitive) else {
            splitRegex(ruleStr)
            return
        }
        
        let range = NSRange(ruleStr.startIndex..., in: ruleStr)
        var matches: [(NSTextCheckingResult, String)] = []
        
        regex.enumerateMatches(in: ruleStr, range: range) { match, _, _ in
            if let match = match {
                if let matchRange = Range(match.range, in: ruleStr) {
                    matches.append((match, String(ruleStr[matchRange])))
                }
            }
        }
        
        for (match, matchedStr) in matches {
            if match.range.location > start {
                let beforeMatch = ruleStr[ruleStr.index(ruleStr.startIndex, offsetBy: start)..<ruleStr.index(ruleStr.startIndex, offsetBy: match.range.location)]
                splitRegex(String(beforeMatch))
            }
            
            if matchedStr.lowercased().hasPrefix("@get:") {
                ruleType.append(getRuleType)
                let key = String(matchedStr.dropFirst(6).dropLast())
                ruleParam.append(key)
            } else if matchedStr.hasPrefix("{{") && matchedStr.hasSuffix("}}") {
                ruleType.append(jsRuleType)
                let jsCode = String(matchedStr.dropFirst(2).dropLast(2))
                ruleParam.append(jsCode)
            } else {
                splitRegex(matchedStr)
            }
            
            start = match.range.location + match.range.length
        }
        
        if start < ruleStr.count {
            let remaining = String(ruleStr[ruleStr.index(ruleStr.startIndex, offsetBy: start)...])
            splitRegex(remaining)
        }
    }
    
    /// 拆分 $数字 的正则捕获组
    private func splitRegex(_ ruleStr: String) {
        let parts = RuleSplitter.splitTopLevel(ruleStr, token: "##") ?? [ruleStr]
        let firstPart = parts.first ?? ""
        
        // 匹配 $1, $2, ... $99
        let regexPattern = #"\$(\d{1,2})"#
        guard let regex = try? NSRegularExpression(pattern: regexPattern) else {
            ruleType.append(defaultRuleType)
            ruleParam.append(firstPart)
            return
        }
        
        var start = 0
        let range = NSRange(firstPart.startIndex..., in: firstPart)
        var matches: [NSTextCheckingResult] = []
        
        regex.enumerateMatches(in: firstPart, range: range) { match, _, _ in
            if let match = match { matches.append(match) }
        }
        
        if matches.isEmpty {
            ruleType.append(defaultRuleType)
            ruleParam.append(firstPart)
        } else {
            for match in matches {
                if match.range.location > start {
                    let before = firstPart[firstPart.index(firstPart.startIndex, offsetBy: start)..<firstPart.index(firstPart.startIndex, offsetBy: match.range.location)]
                    ruleType.append(defaultRuleType)
                    ruleParam.append(String(before))
                }
                
                if let groupRange = Range(match.range(at: 1), in: firstPart),
                   let groupNum = Int(firstPart[groupRange]) {
                    ruleType.append(groupNum)
                    if let fullRange = Range(match.range, in: firstPart) {
                        ruleParam.append(String(firstPart[fullRange]))
                    }
                }
                
                start = match.range.location + match.range.length
            }
            
            if start < firstPart.count {
                let remaining = String(firstPart[firstPart.index(firstPart.startIndex, offsetBy: start)...])
                ruleType.append(defaultRuleType)
                ruleParam.append(remaining)
            }
        }
        
        // 处理 ## 分隔的替换部分
        if parts.count > 1 {
            replaceRegex = parts[1]
        }
        if parts.count > 2 {
            replacement = parts[2]
        }
        if parts.count > 3 {
            replaceFirst = true
        }
    }
    
    // MARK: - 规则组装
    
    /// 组装规则（替换 @get, {{ }} 等）
    func makeUpRule(result: Any?, context: RuleExecutionContext) {
        guard !ruleParam.isEmpty else { return }
        
        var infoVal = ""
        var index = ruleParam.count
        
        while index > 0 {
            index -= 1
            let regType = ruleType[index]
            
            switch regType {
            case let groupNum where groupNum > defaultRuleType:
                // $N 捕获组引用
                if let list = result as? [String], list.count > groupNum {
                    infoVal = list[groupNum] + infoVal
                } else {
                    infoVal = ruleParam[index] + infoVal
                }
                
            case jsRuleType:
                // {{js}} 内嵌 JS
                let jsCode = ruleParam[index]
                if isRule(jsCode) {
                    // 递归解析规则
                    let subRule = SourceRule(ruleStr: jsCode, isJSON: false)
                    if let resolved = context.resolveRule(subRule) {
                        infoVal = resolved + infoVal
                    }
                } else {
                    if let jsResult = context.evalJS(jsCode, result: result) {
                        infoVal = jsResult + infoVal
                    }
                }
                
            case getRuleType:
                // @get:{key} 获取变量
                let key = ruleParam[index]
                infoVal = context.getVariable(key) + infoVal
                
            default:
                infoVal = ruleParam[index] + infoVal
            }
        }
        
        rule = infoVal
        
        // 分离正则表达式
        let parts = RuleSplitter.splitTopLevel(rule, token: "##") ?? [rule]
        rule = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if parts.count > 1 {
            replaceRegex = parts[1]
        }
        if parts.count > 2 {
            replacement = parts[2]
        }
        if parts.count > 3 {
            replaceFirst = true
        }
    }
    
    /// 判断是否为规则字符串
    private func isRule(_ str: String) -> Bool {
        return str.hasPrefix("@") ||
               str.hasPrefix("$.") ||
               str.hasPrefix("$[") ||
               str.hasPrefix("//")
    }
    
    /// 获取参数数量
    func getParamSize() -> Int {
        return ruleParam.count
    }
}

// MARK: - 规则执行上下文协议

protocol RuleExecutionContext {
    func getVariable(_ key: String) -> String
    func setVariable(_ key: String, value: String)
    func evalJS(_ jsCode: String, result: Any?) -> String?
    func resolveRule(_ rule: SourceRule) -> String?
}

// MARK: - 规则解析器

class SourceRuleParser {
    
    /// 规则缓存
    private var ruleCache: [String: [SourceRule]] = [:]
    private let maxCacheSize = 64
    
    /// 解析规则字符串
    func parse(_ ruleStr: String, isJSON: Bool = false) -> [SourceRule] {
        if let cached = ruleCache[ruleStr] {
            return cached
        }
        
        let rules = splitSourceRule(ruleStr, isJSON: isJSON)
        
        // 缓存管理
        if ruleCache.count >= maxCacheSize {
            ruleCache.removeAll()
        }
        ruleCache[ruleStr] = rules
        
        return rules
    }
    
    /// 分解规则生成规则列表
    private func splitSourceRule(_ ruleStr: String, isJSON: Bool) -> [SourceRule] {
        var rules: [SourceRule] = []
        var mode: RuleMode = .default
        var start = 0
        
        // 检查是否以 : 开头（AllInOne 模式）
        if ruleStr.hasPrefix(":") {
            mode = .regex
            start = 1
        }
        
        // 匹配 <js>...</js> 或 {{js}}
        let jsPattern = #"<js>[\w\W]*?</js>|\{\{[\w\W]*?\}\}"#
        
        guard let regex = try? NSRegularExpression(pattern: jsPattern) else {
            let remaining = String(ruleStr[ruleStr.index(ruleStr.startIndex, offsetBy: start)...])
            if !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                rules.append(SourceRule(ruleStr: remaining, mode: mode, isJSON: isJSON))
            }
            return rules
        }
        
        let range = NSRange(ruleStr.startIndex..., in: ruleStr)
        var matches: [NSTextCheckingResult] = []
        
        regex.enumerateMatches(in: ruleStr, range: range) { match, _, _ in
            if let match = match { matches.append(match) }
        }
        
        var currentMode = mode
        
        for match in matches {
            if match.range.location > start {
                let before = ruleStr[ruleStr.index(ruleStr.startIndex, offsetBy: start)..<ruleStr.index(ruleStr.startIndex, offsetBy: match.range.location)]
                let trimmed = before.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    rules.append(SourceRule(ruleStr: trimmed, mode: currentMode, isJSON: isJSON))
                }
            }
            
            if let matchRange = Range(match.range, in: ruleStr) {
                let jsCode = String(ruleStr[matchRange])
                rules.append(SourceRule(ruleStr: jsCode, mode: .js, isJSON: isJSON))
            }
            
            start = match.range.location + match.range.length
        }
        
        if start < ruleStr.count {
            let remaining = String(ruleStr[ruleStr.index(ruleStr.startIndex, offsetBy: start)...])
            let trimmed = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                rules.append(SourceRule(ruleStr: trimmed, mode: currentMode, isJSON: isJSON))
            }
        }
        
        return rules
    }
    
    /// 清除缓存
    func clearCache() {
        ruleCache.removeAll()
    }
}
