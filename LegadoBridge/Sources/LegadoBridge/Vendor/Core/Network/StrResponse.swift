//
//  StrResponse.swift
//  Legado-iOS
//
//  HTTP 响应封装 - 参考原版 StrResponse.kt
//  1:1 移植 Android io.legado.app.help.http.StrResponse
//

import Foundation

/// HTTP 响应封装类，兼容 OkHttp Response 接口
/// 对应 Android StrResponse.kt
class StrResponse {
    /// 原始 HTTPURLResponse（对应 Android 的 raw: Response）
    private(set) var raw: HTTPURLResponse?
    /// 当 Foundation 无法把 `data:` 等长串解析成 URL 时，仍保留逻辑 URL（避免落成 localhost）
    private var explicitURL: String?
    /// 响应体
    var body: String?
    /// 错误响应体
    var errorBody: Data?
    /// 请求耗时（毫秒）
    var callTime: Int = 0

    /// 从 HTTPURLResponse 构造
    init(response: HTTPURLResponse?, body: String?) {
        self.raw = response
        self.body = body
    }

    /// 从 URL 字符串构造合成响应（对应 Android StrResponse(url, body)）
    init(url: String, body: String?) {
        self.explicitURL = url
        if let parsed = URL(string: url) {
            self.raw = HTTPURLResponse(
                url: parsed,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )
        } else {
            // data: 超长等无法构造 URL —— raw 用占位，对外 url 仍返回原文
            self.raw = HTTPURLResponse(
                url: URL(string: "http://localhost/")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )
        }
        self.body = body
    }

    /// 从错误构造合成响应（对应 Android getErrStrResponse）
    init(url: String, errorMessage: String, errorCode: Int = 500) {
        self.explicitURL = url
        let syntheticURL = URL(string: url) ?? URL(string: "http://localhost/")!
        self.raw = HTTPURLResponse(
            url: syntheticURL,
            statusCode: errorCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )
        self.body = errorMessage
    }

    /// 从 HTTPURLResponse 和错误体构造
    init(response: HTTPURLResponse?, errorBody: Data?) {
        self.raw = response
        self.errorBody = errorBody
    }

    /// 设置请求耗时
    func putCallTime(_ callTime: Int) {
        self.callTime = callTime
    }

    /// 获取最终 URL（优先取显式 URL，再取重定向后的 URL）
    var url: String {
        if let explicitURL, !explicitURL.isEmpty {
            return explicitURL
        }
        return raw?.url?.absoluteString ?? "http://localhost/"
    }

    /// 获取状态码
    func code() -> Int {
        return raw?.statusCode ?? 0
    }

    /// 获取状态消息
    func message() -> String {
        return HTTPURLResponse.localizedString(forStatusCode: raw?.statusCode ?? 0)
    }

    /// 获取响应头
    func headers() -> [String: String] {
        guard let allHeaderFields = raw?.allHeaderFields as? [String: String] else {
            return [:]
        }
        return allHeaderFields
    }

    /// 是否成功（状态码 200-299）
    func isSuccessful() -> Bool {
        guard let code = raw?.statusCode else { return false }
        return (200...299).contains(code)
    }

    var description: String {
        return "StrResponse(url=\(url), code=\(code()), body=\(body?.prefix(200) ?? "nil"))"
    }
}