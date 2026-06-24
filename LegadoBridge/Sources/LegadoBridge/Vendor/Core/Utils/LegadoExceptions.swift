//
//  LegadoExceptions.swift
//  Legado-iOS
//
//  异常类体系 (GAP-P1-15)
//  对标 Android: ContentEmptyException, RegexTimeoutException, TocEmptyException 等 8 个
//

import Foundation

// MARK: - 基础异常
class LegadoException: Error, LocalizedError {
    let message: String
    let underlyingError: Error?
    
    init(_ message: String, underlyingError: Error? = nil) {
        self.message = message
        self.underlyingError = underlyingError
    }
    
    var errorDescription: String? { message }
}

// MARK: - 1. 内容为空异常 (Android ContentEmptyException)
class ContentEmptyException: LegadoException {
    let bookName: String
    let chapterTitle: String
    
    init(bookName: String, chapterTitle: String) {
        self.bookName = bookName
        self.chapterTitle = chapterTitle
        super.init("《\(bookName)》- \(chapterTitle) 章节内容为空")
    }
}

// MARK: - 2. 正则超时异常 (Android RegexTimeoutException)
class RegexTimeoutException: LegadoException {
    let pattern: String
    let timeout: TimeInterval
    
    init(pattern: String, timeout: TimeInterval = 3.0) {
        self.pattern = pattern
        self.timeout = timeout
        super.init("正则表达式执行超时: \(pattern) (\(timeout)秒)")
    }
}

// MARK: - 3. 目录为空异常 (Android TocEmptyException)
class TocEmptyException: LegadoException {
    let bookName: String
    let bookUrl: String
    
    init(bookName: String, bookUrl: String) {
        self.bookName = bookName
        self.bookUrl = bookUrl
        super.init("《\(bookName)》获取目录失败，URL: \(bookUrl)")
    }
}

// MARK: - 4. 网络连接异常
class NetworkException: LegadoException {
    let url: String?
    let statusCode: Int
    
    init(url: String? = nil, statusCode: Int = 0, underlyingError: Error? = nil) {
        self.url = url
        self.statusCode = statusCode
        var msg = "网络请求失败"
        if let url = url { msg += ": \(url)" }
        if statusCode > 0 { msg += " (HTTP \(statusCode))" }
        super.init(msg, underlyingError: underlyingError)
    }
}

// MARK: - 5. 书源规则异常
class SourceRuleException: LegadoException {
    let sourceName: String
    let ruleType: String
    
    init(sourceName: String, ruleType: String, message: String) {
        self.sourceName = sourceName
        self.ruleType = ruleType
        super.init("书源《\(sourceName)》\(ruleType)规则错误: \(message)")
    }
}

// MARK: - 6. 解密/编码异常
class DecodeException: LegadoException {
    let encoding: String?
    
    init(encoding: String? = nil, underlyingError: Error? = nil) {
        self.encoding = encoding
        var msg = "内容解码失败"
        if let enc = encoding { msg += " (编码: \(enc))" }
        super.init(msg, underlyingError: underlyingError)
    }
}

// MARK: - 7. 存储/IO 异常
class StorageException: LegadoException {
    let path: String?
    let operation: String
    
    init(operation: String, path: String? = nil, underlyingError: Error? = nil) {
        self.operation = operation
        self.path = path
        var msg = "存储操作失败: \(operation)"
        if let path = path { msg += " (路径: \(path))" }
        super.init(msg, underlyingError: underlyingError)
    }
}

// MARK: - 8. TTS 朗读异常
class TTSException: LegadoException {
    let engine: String
    let text: String?
    
    init(engine: String, text: String? = nil, underlyingError: Error? = nil) {
        self.engine = engine
        self.text = text
        var msg = "TTS 朗读失败 [\(engine)]"
        if let text = text { msg += ": \(text.prefix(50))\(text.count > 50 ? "..." : "")" }
        super.init(msg, underlyingError: underlyingError)
    }
}

// MARK: - 9. 缓存异常
class CacheException: LegadoException {
    let cacheType: String
    
    init(cacheType: String, message: String, underlyingError: Error? = nil) {
        self.cacheType = cacheType
        super.init("缓存错误 [\(cacheType)]: \(message)", underlyingError: underlyingError)
    }
}

// MARK: - 10. WebSocket 异常
class WebSocketException: LegadoException {
    let url: String
    let closeCode: Int?
    
    init(url: String, closeCode: Int? = nil, underlyingError: Error? = nil) {
        self.url = url
        self.closeCode = closeCode
        var msg = "WebSocket 连接失败: \(url)"
        if let code = closeCode { msg += " (关闭码: \(code))" }
        super.init(msg, underlyingError: underlyingError)
    }
}

// MARK: - 异常处理器
@MainActor
class ExceptionHandler {
    static let shared = ExceptionHandler()
    
    /// 全局异常回调
    var onError: ((LegadoException) -> Void)?
    
    func handle(_ error: Error, context: String? = nil) {
        let legadoError: LegadoException
        if let e = error as? LegadoException {
            legadoError = e
        } else {
            legadoError = LegadoException(context ?? error.localizedDescription, underlyingError: error)
        }
        
        // 记录日志
        DebugLogger.shared.log("[\(type(of: legadoError))] \(legadoError.message)")
        
        // 上报
        onError?(legadoError)
        
        #if DEBUG
        // Debug 模式打印详细堆栈
        print("=== LegadoException ===")
        print("类型: \(type(of: legadoError))")
        print("消息: \(legadoError.message)")
        if let underlying = legadoError.underlyingError {
            print("原始错误: \(underlying)")
        }
        print("==========")
        #endif
    }
    
    /// 简化调用
    static func log(_ error: Error, context: String? = nil) {
        Task { @MainActor in
            shared.handle(error, context: context)
        }
    }
}

// MARK: - Result 扩展
extension Result {
    func mapErrorToLegado() -> Result<Success, LegadoException> where Failure == Error {
        mapError { error in
            if let e = error as? LegadoException {
                return e
            }
            return LegadoException(error.localizedDescription, underlyingError: error)
        }
    }
}

// MARK: - throws 简化
func throwIfEmpty(_ content: String?, bookName: String, chapterTitle: String) throws {
    guard let content = content, !content.isEmpty else {
        throw ContentEmptyException(bookName: bookName, chapterTitle: chapterTitle)
    }
}

func throwIfTocEmpty(_ chapters: [BridgeChapter], bookName: String, bookUrl: String) throws {
    guard !chapters.isEmpty else {
        throw TocEmptyException(bookName: bookName, bookUrl: bookUrl)
    }
}
