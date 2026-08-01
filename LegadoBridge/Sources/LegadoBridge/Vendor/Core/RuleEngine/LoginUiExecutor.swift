//
//  LoginUiExecutor.swift
//  解析 loginUi、执行按钮 action / source.login()（对齐 Android SourceLoginDialog）
//

import Foundation
import JavaScriptCore
import LegadoObjCSupport

public enum LoginUiExecutor {

    public struct Row: Equatable {
        public let name: String
        public let type: String
        public let action: String
    }

    /// 解析 loginUi JSON 数组（容错 JS 对象字面量的简单情况）
    public static func parseRows(_ raw: String?) -> [Row] {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return []
        }
        if let data = text.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return arr.compactMap { dict in
                let name = "\(dict["name"] ?? "")"
                guard !name.isEmpty else { return nil }
                let type = "\(dict["type"] ?? "text")".lowercased()
                let action = "\(dict["action"] ?? "")"
                return Row(name: name, type: type, action: action)
            }
        }
        // 粗暴容错：键加引号再试
        text = text.replacingOccurrences(
            of: #"(\{|,)\s*([A-Za-z_][A-Za-z0-9_]*)\s*:"#,
            with: "$1\"$2\":",
            options: .regularExpression
        )
        if let data = text.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return arr.compactMap { dict in
                let name = "\(dict["name"] ?? "")"
                guard !name.isEmpty else { return nil }
                return Row(
                    name: name,
                    type: "\(dict["type"] ?? "text")".lowercased(),
                    action: "\(dict["action"] ?? "")"
                )
            }
        }
        return []
    }

    public static func rowsJSON(for source: (any BridgeSourceProtocol)?) -> String {
        let rows = parseRows(source?.loginUi)
        let arr: [[String: String]] = rows.map {
            ["name": $0.name, "type": $0.type, "action": $0.action]
        }
        guard JSONSerialization.isValidJSONObject(arr),
              let data = try? JSONSerialization.data(withJSONObject: arr),
              let s = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return s
    }

    /// 从 loginUrl 抽出可 eval 的 JS（非 http 导航 URL）
    public static func loginJs(from source: (any BridgeSourceProtocol)?) -> String {
        guard let raw = source?.loginUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return ""
        }
        let lower = raw.lowercased()
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            if raw.contains("/@js") || raw.hasSuffix("@js:") { return "" }
            return ""
        }
        if lower.hasPrefix("@js:") {
            return String(raw.dropFirst(4))
        }
        if lower.hasPrefix("<js>") {
            if lower.hasSuffix("</js>") {
                return String(raw.dropFirst(4).dropLast(5))
            }
            return String(raw.dropFirst(4))
        }
        return raw
    }

    /// 执行按钮 action 或整段 `login()`；formJSON 为字段 map
    @discardableResult
    public static func run(
        source: (any BridgeSourceProtocol)?,
        action: String,
        formJSON: String?,
        putInfoBeforeEval: Bool = true
    ) -> String {
        guard let source else { return "无书源" }
        let sourceUrl = source.bookSourceUrl
        let act = action.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !act.isEmpty else { return "空 action" }

        // 绝对 URL → 交给浏览器
        if act.hasPrefix("http://") || act.hasPrefix("https://") {
            _ = BrowserAwaitGate.startBrowserAwait(url: act, title: "登录相关", sourceUrl: sourceUrl)
            return "已打开网页"
        }

        if putInfoBeforeEval, let formJSON, !formJSON.isEmpty {
            LoginCredentialStore.putInfo(formJSON, sourceUrl: sourceUrl)
        }

        let jsLib = loginJs(from: source)
        let script = jsLib.isEmpty ? act : (jsLib + "\n" + act)

        let jsContext = JSContext()!
        var jsError: String?
        jsContext.exceptionHandler = { _, ex in jsError = ex?.toString() }

        let bridge = JSBridge()
        let exec = ExecutionContext()
        exec.source = source
        exec.baseURL = URL(string: sourceUrl.hasPrefix("http") ? sourceUrl : "https://localhost/")
        if !sourceUrl.isEmpty {
            exec.variables = SourceSessionStore.variables(for: sourceUrl)
        }
        bridge.context = exec
        bridge.inject(into: jsContext)

        // result = 表单 map（Android SourceLoginDialog）
        let formMap = Self.parseFormMap(formJSON)
        jsContext.setObject(formMap as NSDictionary, forKeyedSubscript: "result" as NSString)

        var objcErr: NSString?
        let evalResult = ObjCExceptionCatch.evaluateScript(script, in: jsContext, error: &objcErr)
        if let objcErr {
            return String(objcErr)
        }
        if let jsError, !jsError.isEmpty {
            return jsError
        }
        if let sourceUrl = Optional(sourceUrl), !sourceUrl.isEmpty {
            SourceSessionStore.merge(exec.variables, for: sourceUrl)
        }

        // 登录类动作：不能只靠「无异常」当成功；书山等以 loginHeader 为准
        let actLower = act.lowercased()
        let looksLikeLogin = actLower.contains("login(") || actLower == "login()"
        if looksLikeLogin {
            let header = LoginCredentialStore.getHeader(sourceUrl: sourceUrl)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if header.isEmpty {
                let jsRet = evalResult?.toString() ?? ""
                return "登录未生效：未见 loginHeader（JS 无抛错 ≠ 登录成功）\(jsRet.isEmpty ? "" : " ret=\(jsRet.prefix(80))")"
            }
            return "ok headerLen=\(header.count)"
        }

        return "ok"
    }

    private static func parseFormMap(_ formJSON: String?) -> [String: String] {
        guard let formJSON, let data = formJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var out: [String: String] = [:]
        for (k, v) in obj { out[k] = "\(v)" }
        return out
    }
}
