//
//  XiangseJSExecute.swift
//  LegadoRuleCore
//
//  对齐香色 LCJSExecute：脚本定义 function functionName(config, params, result|response)，
//  引擎在 evaluate 后主动调用并取返回值（DOM 解析后的 JSParser 后处理 / responseJavascript）。
//

import Foundation
import JavaScriptCore
import LegadoObjCSupport

/// 香色三参（或两参）JSParser 执行入口
enum XiangseJSExecute {

    private static let functionNamePattern = try! NSRegularExpression(
        pattern: #"function\s+functionName\s*\("#,
        options: []
    )

    /// 是否为香色 `function functionName(...)` 形态
    static func looksLikeXiangseFunction(_ script: String) -> Bool {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        return functionNamePattern.firstMatch(in: trimmed, range: range) != nil
    }

    /// 在已注入 bridge（含 nativeTool）的上下文中执行香色脚本，返回字符串化结果
    /// - Parameters:
    ///   - script: 含 `function functionName(...)` 的完整脚本
    ///   - jsContext: 已 inject 的 JSContext
    ///   - config: 书源/请求配置字典（可空）
    ///   - extraParams: 合并进 params（如 responseUrl / keyWord）
    static func execute(
        script: String,
        in jsContext: JSContext,
        config: [String: Any]? = nil,
        extraParams: [String: Any]? = nil
    ) throws -> String {
        var jsError: String?
        jsContext.exceptionHandler = { _, ex in jsError = ex?.toString() }

        prepareGlobals(in: jsContext, config: config, extraParams: extraParams)
        if let jsError, !jsError.isEmpty {
            throw RuleError.executionFailed(jsError)
        }

        // 定义 functionName
        var objcErr: NSString?
        _ = ObjCExceptionCatch.evaluateScript(script, in: jsContext, error: &objcErr)
        if let objcErr {
            throw RuleError.executionFailed(objcErr as String)
        }
        if let jsError, !jsError.isEmpty {
            throw RuleError.executionFailed(jsError)
        }

        // 若 result 是 JSON 文本或 ObjC 桥接不可变对象，升成可变 JS 对象
        // （香色样例常 result.list.shift() / result.posts.map）
        ensureMutableResult(in: jsContext)

        let invoke = """
        (function () {
          if (typeof functionName !== 'function') {
            throw new Error('xiangse: functionName 未定义');
          }
          var cfg = (typeof config !== 'undefined' && config) ? config : {};
          var p = (typeof params !== 'undefined' && params) ? params : {};
          if (typeof nativeTool !== 'undefined' && nativeTool) {
            p.nativeTool = nativeTool;
          }
          var r = (typeof result !== 'undefined') ? result
                : ((typeof response !== 'undefined') ? response : null);
          return functionName(cfg, p, r);
        })();
        """
        jsError = nil
        let out = ObjCExceptionCatch.evaluateScript(invoke, in: jsContext, error: &objcErr)
        if let objcErr {
            throw RuleError.executionFailed(objcErr as String)
        }
        if let jsError, !jsError.isEmpty {
            throw RuleError.executionFailed(jsError)
        }
        guard let text = stringify(out), !text.isEmpty else {
            return ""
        }
        return text
    }

    // MARK: - helpers

    private static func prepareGlobals(
        in jsContext: JSContext,
        config: [String: Any]?,
        extraParams: [String: Any]?
    ) {
        let cfg = (config ?? [:]) as NSDictionary
        jsContext.setObject(cfg, forKeyedSubscript: "config" as NSString)
        jsContext.globalObject?.setObject(cfg, forKeyedSubscript: "config" as NSString)

        _ = ObjCExceptionCatch.evaluateScript("""
        (function (g) {
          if (typeof g.params !== 'object' || g.params === null) { g.params = {}; }
          if (typeof g.nativeTool !== 'undefined' && g.nativeTool) {
            g.params.nativeTool = g.nativeTool;
          }
        })(this);
        """, in: jsContext, error: nil)

        if let extraParams {
            for (k, v) in extraParams {
                if let s = v as? String {
                    jsContext.objectForKeyedSubscript("params")?.setObject(s, forKeyedSubscript: k as NSString)
                } else if let n = v as? NSNumber {
                    jsContext.objectForKeyedSubscript("params")?.setObject(n, forKeyedSubscript: k as NSString)
                } else if JSONSerialization.isValidJSONObject(v) {
                    jsContext.objectForKeyedSubscript("params")?.setObject(v as Any, forKeyedSubscript: k as NSString)
                } else {
                    jsContext.objectForKeyedSubscript("params")?.setObject(String(describing: v), forKeyedSubscript: k as NSString)
                }
            }
        }
    }

    /// 字符串 result 若为 JSON object/array，则替换为可变 JS 对象（勿用 NSArray 注入，否则 shift 等会失败）
    private static func promoteResultJSONIfNeeded(in jsContext: JSContext) {
        guard let bound = jsContext.objectForKeyedSubscript("result" as NSString),
              !bound.isUndefined, !bound.isNull,
              bound.isString,
              let text = bound.toString()?.trimmingCharacters(in: .whitespacesAndNewlines),
              (text.hasPrefix("{") || text.hasPrefix("[")),
              let data = text.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else {
            return
        }
        var err: NSString?
        var jsonErr: NSString?
        guard let lit = ObjCExceptionCatch.jsonStringLiteral(text, error: &jsonErr) as String? else {
            return
        }
        _ = ObjCExceptionCatch.evaluateScript(
            "result = JSON.parse(\(lit));",
            in: jsContext,
            error: &err
        )
    }

    /// 统一保证 result 可被 JS 原地修改
    private static func ensureMutableResult(in jsContext: JSContext) {
        promoteResultJSONIfNeeded(in: jsContext)
        _ = ObjCExceptionCatch.evaluateScript("""
        (function () {
          if (typeof result === 'object' && result !== null) {
            try { result = JSON.parse(JSON.stringify(result)); } catch (e) {}
          }
        })();
        """, in: jsContext, error: nil)
    }

    static func stringify(_ value: JSValue?) -> String? {
        guard let value, !value.isUndefined, !value.isNull else { return nil }
        if value.isString || value.isNumber || value.isBoolean {
            let s = value.toString() ?? ""
            if s == "undefined" || s == "null" { return nil }
            return s
        }
        if value.isObject {
            if let obj = value.toObject(),
               JSONSerialization.isValidJSONObject(obj),
               let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
               let s = String(data: data, encoding: .utf8) {
                return s
            }
            let s = value.toString() ?? ""
            if s == "[object Object]" || s.isEmpty { return nil }
            return s
        }
        return value.toString()
    }
}
