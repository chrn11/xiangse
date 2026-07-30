//
//  CoverDecodeHelper.swift
//  LegadoRuleCore
//
//  执行书源 coverDecodeJs，将加密/变形封面 URL 解成可请求地址。
//  不依赖 CoreData ImageCacheManager。
//

import Foundation
import JavaScriptCore

public enum CoverDecodeHelper {
    /// 若 decodeJs 为空则原样返回 url；失败时返回原 url（调用方可再决定占位）
    public static func decodeCoverURL(
        _ url: String,
        decodeJs: String?,
        baseUrl: String?,
        source: (any BridgeSourceProtocol)? = nil
    ) -> String {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return url }
        guard let decodeJs = decodeJs?.trimmingCharacters(in: .whitespacesAndNewlines),
              !decodeJs.isEmpty else {
            return trimmedURL
        }

        let exec = ExecutionContext()
        exec.source = source
        exec.baseURL = URL(string: baseUrl ?? source?.bookSourceUrl ?? "")
        _ = exec.jsContext
        let srcLiteral = jsonStringLiteral(trimmedURL)
        exec.jsContext.evaluateScript("var src = \(srcLiteral); var result = src;")
        var jsError: String?
        exec.jsContext.exceptionHandler = { _, ex in jsError = ex?.toString() }
        let direct = exec.jsContext.evaluateScript(decodeJs)?.toString()
        let resultValue = exec.jsContext.objectForKeyedSubscript("result")?.toString()
        if let jsError, !jsError.isEmpty {
            DebugLogger.shared.log("[coverDecodeJs] \(jsError)")
            return trimmedURL
        }
        let value = [direct, resultValue]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0 != "undefined" && $0 != "null" }
        guard let value else { return trimmedURL }

        if let base = baseUrl ?? source?.bookSourceUrl,
           let resolved = URL(string: value, relativeTo: URL(string: base))?.absoluteURL.absoluteString {
            return resolved
        }
        return value
    }

    private static func jsonStringLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: []),
              let s = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return s
    }
}
