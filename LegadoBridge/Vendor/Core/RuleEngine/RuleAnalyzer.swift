//
//  RuleAnalyzer.swift
//  Legado-iOS
//
//  通用的规则切分处理 - 对标 Android RuleAnalyzer.kt
//

import Foundation

/// 规则分析器 - 处理规则字符串的切分和解析
class RuleAnalyzer {
    private var queue: String       // 被处理字符串
    private var pos: Int = 0        // 当前处理到的位置
    private var start: Int = 0      // 当前处理字段的开始
    private var startX: Int = 0     // 当前规则的开始
    
    private var rules: [String] = []  // 分割出的规则列表
    private var step: Int = 0         // 分割字符的长度
    var elementsType: String = ""     // 当前分割字符串
    
    private let isCode: Bool          // 是否为代码模式
    
    init(data: String, code: Bool = false) {
        self.queue = data
        self.isCode = code
    }
    
    // MARK: - 修剪
    
    /// 修剪当前规则之前的"@"或者空白符
    func trim() {
        if pos >= queue.count { return }
        let char = queue[queue.index(queue.startIndex, offsetBy: pos)]
        if char == "@" || char < "!" {
            pos += 1
            while pos < queue.count {
                let c = queue[queue.index(queue.startIndex, offsetBy: pos)]
                if c != "@" && c >= "!" { break }
                pos += 1
            }
            start = pos
            startX = pos
        }
    }
    
    /// 将pos重置为0，方便复用
    func reSetPos() {
        pos = 0
        startX = 0
    }
    
    // MARK: - 查找方法
    
    /// 从剩余字串中拉出一个字符串，直到但不包括匹配序列
    /// - Parameter seq: 查找的字符串（区分大小写）
    /// - Returns: 是否找到相应字段
    private func consumeTo(_ seq: String) -> Bool {
        start = pos
        guard let range = queue.range(of: seq, range: String.Index(utf16Offset: pos, in: queue)..<queue.endIndex) else {
            return false
        }
        pos = queue.distance(from: queue.startIndex, to: range.lowerBound)
        return true
    }
    
    /// 从剩余字串中拉出一个字符串，直到匹配序列中一项
    /// - Parameter seqs: 匹配字符串序列
    /// - Returns: 成功返回true并设置间隔
    private func consumeToAny(_ seqs: String...) -> Bool {
        consumeToAny(seqs)
    }

    private func consumeToAny(_ seqs: [String]) -> Bool {
        var currentPos = pos
        
        while currentPos < queue.count {
            for s in seqs {
                let startIdx = queue.index(queue.startIndex, offsetBy: currentPos)
                let endIdx = queue.index(startIdx, offsetBy: s.count, limitedBy: queue.endIndex) ?? queue.endIndex
                if queue[startIdx..<endIdx] == s {
                    step = s.count
                    pos = currentPos
                    return true
                }
            }
            currentPos += 1
        }
        return false
    }
    
    /// 查找匹配字符的位置
    /// - Parameter chars: 匹配字符序列
    /// - Returns: 匹配位置，-1表示未找到
    private func findToAny(_ chars: Character...) -> Int {
        var currentPos = pos
        
        while currentPos < queue.count {
            let c = queue[queue.index(queue.startIndex, offsetBy: currentPos)]
            for char in chars {
                if c == char { return currentPos }
            }
            currentPos += 1
        }
        return -1
    }
    
    // MARK: - 平衡组解析
    
    /// 拉出一个代码平衡组（处理转义字符）
    private func chompCodeBalanced(open: Character, close: Character) -> Bool {
        var currentPos = pos
        var depth = 0
        var otherDepth = 0
        var inSingleQuote = false
        var inDoubleQuote = false
        let esc: Character = "\\"
        
        while currentPos < queue.count {
            let c = queue[queue.index(queue.startIndex, offsetBy: currentPos)]
            currentPos += 1
            
            if c != esc {
                if c == "'" && !inDoubleQuote { inSingleQuote = !inSingleQuote }
                else if c == "\"" && !inSingleQuote { inDoubleQuote = !inDoubleQuote }
                
                if inSingleQuote || inDoubleQuote { continue }
                
                if c == "[" { depth += 1 }
                else if c == "]" { depth -= 1 }
                else if depth == 0 {
                    if c == open { otherDepth += 1 }
                    else if c == close { otherDepth -= 1 }
                }
            } else {
                currentPos += 1
            }
        }
        
        if depth > 0 || otherDepth > 0 { return false }
        pos = currentPos
        return true
    }
    
    /// 拉出一个规则平衡组（xpath和jsoup中引号内转义字符无效）
    private func chompRuleBalanced(open: Character, close: Character) -> Bool {
        var currentPos = pos
        var depth = 0
        var inSingleQuote = false
        var inDoubleQuote = false
        
        while currentPos < queue.count {
            let c = queue[queue.index(queue.startIndex, offsetBy: currentPos)]
            currentPos += 1
            
            if c == "'" && !inDoubleQuote { inSingleQuote = !inSingleQuote }
            else if c == "\"" && !inSingleQuote { inDoubleQuote = !inDoubleQuote }
            
            if inSingleQuote || inDoubleQuote { continue }
            else if c == "\\" {
                currentPos += 1
                continue
            }
            
            if c == open { depth += 1 }
            else if c == close { depth -= 1 }
        }
        
        if depth > 0 { return false }
        pos = currentPos
        return true
    }
    
    /// 平衡组解析（根据模式选择）
    private func chompBalanced(open: Character, close: Character) -> Bool {
        return isCode ? chompCodeBalanced(open: open, close: close) : chompRuleBalanced(open: open, close: close)
    }
    
    // MARK: - 规则切分
    
    /// 切分规则字符串
    /// - Parameter splits: 分隔符列表
    /// - Returns: 规则列表
    func splitRule(_ splits: String...) -> [String] {
        splitRule(splits)
    }

    func splitRule(_ splits: [String]) -> [String] {
        if splits.count == 1 {
            elementsType = splits[0]
            if !consumeTo(elementsType) {
                rules.append(String(queue[queue.index(queue.startIndex, offsetBy: startX)...]))
                return rules
            }
            step = elementsType.count
            return splitRuleNext()
        } else if !consumeToAny(splits) {
            rules.append(String(queue[queue.index(queue.startIndex, offsetBy: startX)...]))
            return rules
        }
        
        let end = pos
        pos = start
        
        repeat {
            let st = findToAny("[", "(")
            
            if st == -1 {
                rules.append(String(queue[queue.index(queue.startIndex, offsetBy: startX)..<queue.index(queue.startIndex, offsetBy: end)]))
                
                elementsType = String(queue[queue.index(queue.startIndex, offsetBy: end)..<queue.index(queue.startIndex, offsetBy: end + step)])
                pos = end + step
                
                while consumeTo(elementsType) {
                    rules.append(String(queue[queue.index(queue.startIndex, offsetBy: start)..<queue.index(queue.startIndex, offsetBy: pos)]))
                    pos += step
                }
                
                rules.append(String(queue[queue.index(queue.startIndex, offsetBy: pos)...]))
                return rules
            }
            
            if st > end {
                rules.append(String(queue[queue.index(queue.startIndex, offsetBy: startX)..<queue.index(queue.startIndex, offsetBy: end)]))
                
                elementsType = String(queue[queue.index(queue.startIndex, offsetBy: end)..<queue.index(queue.startIndex, offsetBy: end + step)])
                pos = end + step
                
                while consumeTo(elementsType) && pos < st {
                    rules.append(String(queue[queue.index(queue.startIndex, offsetBy: start)..<queue.index(queue.startIndex, offsetBy: pos)]))
                    pos += step
                }
                
                if pos > st {
                    startX = start
                    return splitRuleNext()
                } else {
                    rules.append(String(queue[queue.index(queue.startIndex, offsetBy: pos)...]))
                    return rules
                }
            }
            
            pos = st
            let next: Character = queue[queue.index(queue.startIndex, offsetBy: pos)] == "[" ? "]" : ")"
            
            if !chompBalanced(open: queue[queue.index(queue.startIndex, offsetBy: pos)], close: next) {
                print("规则错误: \(String(queue[queue.startIndex..<queue.index(queue.startIndex, offsetBy: start)])) 后未平衡")
                return rules
            }
        } while end > pos
        
        start = pos
        return splitRule(splits)
    }
    
    /// 二段匹配（内部递归使用）
    private func splitRuleNext() -> [String] {
        let end = pos
        pos = start
        
        repeat {
            let st = findToAny("[", "(")
            
            if st == -1 {
                rules.append(String(queue[queue.index(queue.startIndex, offsetBy: startX)..<queue.index(queue.startIndex, offsetBy: end)]))
                pos = end + step
                
                while consumeTo(elementsType) {
                    rules.append(String(queue[queue.index(queue.startIndex, offsetBy: start)..<queue.index(queue.startIndex, offsetBy: pos)]))
                    pos += step
                }
                
                rules.append(String(queue[queue.index(queue.startIndex, offsetBy: pos)...]))
                return rules
            }
            
            if st > end {
                rules.append(String(queue[queue.index(queue.startIndex, offsetBy: startX)..<queue.index(queue.startIndex, offsetBy: end)]))
                pos = end + step
                
                while consumeTo(elementsType) && pos < st {
                    rules.append(String(queue[queue.index(queue.startIndex, offsetBy: start)..<queue.index(queue.startIndex, offsetBy: pos)]))
                    pos += step
                }
                
                if pos > st {
                    startX = start
                    return splitRuleNext()
                } else {
                    rules.append(String(queue[queue.index(queue.startIndex, offsetBy: pos)...]))
                    return rules
                }
            }
            
            pos = st
            let next: Character = queue[queue.index(queue.startIndex, offsetBy: pos)] == "[" ? "]" : ")"
            
            if !chompBalanced(open: queue[queue.index(queue.startIndex, offsetBy: pos)], close: next) {
                print("规则错误: \(String(queue[queue.startIndex..<queue.index(queue.startIndex, offsetBy: start)])) 后未平衡")
                return rules
            }
        } while end > pos
        
        start = pos
        
        if !consumeTo(elementsType) {
            rules.append(String(queue[queue.index(queue.startIndex, offsetBy: startX)...]))
            return rules
        }
        return splitRuleNext()
    }
    
    // MARK: - 内嵌规则替换
    
    /// 替换内嵌规则（使用起始和结束标志）
    /// - Parameters:
    ///   - inner: 起始标志，如 "{$."
    ///   - startStep: 不属于规则部分的前置字符长度
    ///   - endStep: 不属于规则部分的后置字符长度
    ///   - resolver: 查找到内嵌规则时的解析函数
    /// - Returns: 替换后的字符串
    func innerRule(inner: String, startStep: Int = 1, endStep: Int = 1, resolver: (String) -> String?) -> String {
        var result = StringBuilder()
        
        while consumeTo(inner) {
            let posPre = pos
            if chompCodeBalanced(open: "{", close: "}") {
                let startIndex = queue.index(queue.startIndex, offsetBy: posPre + startStep)
                let endIndex = queue.index(queue.startIndex, offsetBy: pos - endStep)
                let innerContent = String(queue[startIndex..<endIndex])
                
                if let resolved = resolver(innerContent), !resolved.isEmpty {
                    let prefixStart = queue.index(queue.startIndex, offsetBy: startX)
                    let prefixEnd = queue.index(queue.startIndex, offsetBy: posPre)
                    result.append(String(queue[prefixStart..<prefixEnd]))
                    result.append(resolved)
                    startX = pos
                    continue
                }
            }
            pos += inner.count
        }
        
        if startX == 0 { return "" }
        
        result.append(String(queue[queue.index(queue.startIndex, offsetBy: startX)...]))
        return result.toString()
    }
    
    /// 替换内嵌规则（使用起始和结束字符串）
    func innerRule(startStr: String, endStr: String, resolver: (String) -> String?) -> String {
        var result = StringBuilder()
        
        while consumeTo(startStr) {
            pos += startStr.count
            let posPre = pos
            
            if consumeTo(endStr) {
                let startIndex = queue.index(queue.startIndex, offsetBy: posPre)
                let endIndex = queue.index(queue.startIndex, offsetBy: pos)
                let innerContent = String(queue[startIndex..<endIndex])
                
                if let resolved = resolver(innerContent) {
                    let prefixStart = queue.index(queue.startIndex, offsetBy: startX)
                    let prefixEnd = queue.index(queue.startIndex, offsetBy: posPre - startStr.count)
                    result.append(String(queue[prefixStart..<prefixEnd]))
                    result.append(resolved)
                    
                    pos += endStr.count
                    startX = pos
                }
            }
        }
        
        if startX == 0 { return queue }
        
        result.append(String(queue[queue.index(queue.startIndex, offsetBy: startX)...]))
        return result.toString()
    }
}

// MARK: - 辅助类型

/// 字符串构建器
class StringBuilder {
    private var string: String = ""
    
    var length: Int { string.count }
    
    func append(_ str: String) {
        string += str
    }
    
    func clear() {
        string = ""
    }
    
    func toString() -> String {
        return string
    }
}

// MARK: - 便捷扩展

extension RuleAnalyzer {
    
    /// 静态方法：切分规则字符串
    static func split(_ rule: String, separators: String...) -> [String] {
        let analyzer = RuleAnalyzer(data: rule)
        if separators.isEmpty {
            return analyzer.splitRule("&&", "||", "%%", "@")
        }
        return analyzer.splitRule(separators)
    }
    
    /// 静态方法：解析内嵌规则
    static func resolveInnerRules(_ rule: String, resolver: (String) -> String?) -> String {
        let analyzer = RuleAnalyzer(data: rule, code: true)
        return analyzer.innerRule(inner: "{{", startStep: 2, endStep: 2, resolver: resolver)
    }
}
