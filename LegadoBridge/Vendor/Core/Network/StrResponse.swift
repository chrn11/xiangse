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
        var request = URLRequest(url: URL(string: url) ?? URL(string: "http://localhost/")!)
        request.httpMethod = "GET"
        let syntheticURL = URL(string: url) ?? URL(string: "http://localhost/")!
        self.raw = HTTPURLResponse(
            url: syntheticURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )
        self.body = body
    }

    /// 从错误构造合成响应（对应 Android getErrStrResponse）
    init(url: String, errorMessage: String, errorCode: Int = 500) {
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

    /// 获取最终 URL（优先取重定向后的 URL）
    var url: String {
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