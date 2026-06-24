//
//  RegexJsExtensions.swift
//  Legado-iOS
//
//  正则 JS 扩展 (GAP-P2-29)
//  对标 Android RegexJsExtensions
//  提供 JS 执行环境下的正则相关辅助函数
//

import Foundation
import JavaScriptCore
import JavaScriptCore

// MARK: - 正则 JS 扩展
struct RegexJsExtensions {
    
    /// 将正则表达式安全地注入 JS 上下文
    static func injectRegexHelpers(into context: JSContext) {
        // 1. reMatches - 返回所有匹配结果
        context.setObject({ (pattern: String, text: String) -> [String] in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, options: [], range: range)
            return matches.map { String(text[Range($0.range, in: text)!]) }
        } as @convention(block) (String, String) -> [String], forKeyedSubscript: "reMatches" as NSString)
        
        // 2. reMatch - 返回第一个匹配
        context.setObject({ (pattern: String, text: String) -> String? in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, options: [], range: range) {
                return String(text[Range(match.range, in: text)!])
            }
            return nil
        } as @convention(block) (String, String) -> String?, forKeyedSubscript: "reMatch" as NSString)
        
        // 3. reReplace - 替换所有匹配
        context.setObject({ (pattern: String, text: String, replacement: String) -> String in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
            let range = NSRange(text.startIndex..., in: text)
            return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
        } as @convention(block) (String, String, String) -> String, forKeyedSubscript: "reReplace" as NSString)
        
        // 4. reGroup - 返回指定捕获组
        context.setObject({ (pattern: String, text: String, groupIndex: Int) -> String? in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, options: [], range: range) {
                let groupRange = match.range(at: groupIndex)
                if groupRange.location != NSNotFound, let swiftRange = Range(groupRange, in: text) {
                    return String(text[swiftRange])
                }
            }
            return nil
        } as @convention(block) (String, String, Int) -> String?, forKeyedSubscript: "reGroup" as NSString)
        
        // 5. reTest - 测试是否匹配
        context.setObject({ (pattern: String, text: String) -> Bool in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return false }
            let range = NSRange(text.startIndex..., in: text)
            return regex.firstMatch(in: text, options: [], range: range) != nil
        } as @convention(block) (String, String) -> Bool, forKeyedSubscript: "reTest" as NSString)
        
        // 6. reSplit - 根据正则分割
        context.setObject({ (pattern: String, text: String) -> [String] in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [text] }
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, options: [], range: range)
            
            var result: [String] = []
            var lastEnd = text.startIndex
            for match in matches {
                if let matchRange = Range(match.range, in: text) {
                    result.append(String(text[lastEnd..<matchRange.lowerBound]))
                    lastEnd = matchRange.upperBound
                }
            }
            result.append(String(text[lastEnd...]))
            return result
        } as @convention(block) (String, String) -> [String], forKeyedSubscript: "reSplit" as NSString)
    }
    
    /// 从 JS 返回值中提取字符串结果
    static func extractString(from value: JSValue?) -> String? {
        guard let value = value, !value.isUndefined, !value.isNull else { return nil }
        return value.toString()
    }
    
    /// 从 JS 返回值中提取数组
    static func extractArray(from value: JSValue?) -> [String]? {
        guard let value = value, value.isArray else { return nil }
        let length = value.forProperty("length").toInt32()
        var result: [String] = []
        for i in 0..<length {
            if let item = value.forProperty("\(i)").toString() {
                result.append(item)
            }
        }
        return result
    }
}

// MARK: - String 扩展: 正则便捷方法
extension String {
    /// 安全正则匹配（带超时保护）
    func safeMatch(pattern: String, timeout: TimeInterval = 3.0) throws -> [String] {
        let startTime = Date()
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            throw RegexTimeoutException(pattern: pattern, timeout: timeout)
        }
        
        let range = NSRange(self.startIndex..., in: self)
        let matches = regex.matches(in: self, options: [], range: range)
        let result = matches.map { String(self[Range($0.range, in: self)!]) }
        
        let elapsed = Date().timeIntervalSince(startTime)
        if elapsed > timeout {
            Task { @MainActor in
                DebugLogger.shared.log("[RegexJs] 正则执行时间: \(elapsed)s")
            }
        }
        return result
    }
    
    /// 替换所有匹配
    func replacingMatches(pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return self }
        let range = NSRange(self.startIndex..., in: self)
        return regex.stringByReplacingMatches(in: self, options: [], range: range, withTemplate: replacement)
    }
    
    /// 测试是否匹配
    func matches(pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return false }
        let range = NSRange(self.startIndex..., in: self)
        return regex.firstMatch(in: self, options: [], range: range) != nil
    }
}
