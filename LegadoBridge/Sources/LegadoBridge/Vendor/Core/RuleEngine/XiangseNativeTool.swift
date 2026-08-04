//
//  XiangseNativeTool.swift
//  LegadoRuleCore
//
//  对齐香色 LCJSTool JSExport 面（params.nativeTool.*）。
//  纯 Swift 实现，单元测试无需宿主 App；真机若存在 LCJSTool 则部分方法可转发。
//

import Foundation
import JavaScriptCore
import CommonCrypto
import LegadoObjCSupport
#if canImport(UIKit)
import UIKit
#endif

/// 香色书源脚本里的 `params.nativeTool`
enum XiangseNativeTool {

    /// 注入全局 `nativeTool`，并挂好 `params.nativeTool` 初始壳（key/page 由 AnalyzeUrl 脚本再补）
    static func inject(into jsContext: JSContext, encode: JsEncodeUtils) {
        guard let tool = makeObject(in: jsContext, encode: encode) else { return }
        bindGlobal(tool, name: "nativeTool", into: jsContext)
        _ = ObjCExceptionCatch.evaluateScript("""
        (function (g) {
          if (typeof g.params !== 'object' || g.params === null) {
            g.params = {};
          }
          g.params.nativeTool = g.nativeTool;
        })(this);
        """, in: jsContext, error: nil)
    }

    /// 构造与香色 JSExport 同名的方法对象
    static func makeObject(in jsContext: JSContext, encode: JsEncodeUtils) -> JSValue? {
        let obj = JSValue(newObjectIn: jsContext)

        let logBlock: @convention(block) (JSValue?) -> Void = { v in
            DebugLogger.shared.log("[nativeTool.log] \(stringifyJS(v))")
        }
        obj?.setObject(logBlock, forKeyedSubscript: "log" as NSString)

        let logWithKeyBlock: @convention(block) (JSValue?, String) -> Void = { v, key in
            DebugLogger.shared.log("[nativeTool.logWithKey:\(key)] \(stringifyJS(v))")
        }
        obj?.setObject(logWithKeyBlock, forKeyedSubscript: "logWithKey" as NSString)

        let deviceIdBlock: @convention(block) () -> String = {
            deviceId()
        }
        obj?.setObject(deviceIdBlock, forKeyedSubscript: "deviceId" as NSString)

        let deviceIdTplBlock: @convention(block) (String, String) -> String = { template, sep in
            deviceIdWithTemplate(template, separator: sep)
        }
        obj?.setObject(deviceIdTplBlock, forKeyedSubscript: "deviceIdWithTemplateWithSeparator" as NSString)

        let md5Block: @convention(block) (String) -> String = { [encode] s in
            encode.md5Encode(s)
        }
        obj?.setObject(md5Block, forKeyedSubscript: "md5Encode" as NSString)

        let sha1Block: @convention(block) (String) -> String = { s in
            sha1Hex(s)
        }
        obj?.setObject(sha1Block, forKeyedSubscript: "sha1Encode" as NSString)

        let b64eBlock: @convention(block) (String) -> String = { s in
            Data(s.utf8).base64EncodedString()
        }
        obj?.setObject(b64eBlock, forKeyedSubscript: "base64Encode" as NSString)

        let b64eDataBlock: @convention(block) (String) -> String = { s in
            Data(s.utf8).base64EncodedString()
        }
        obj?.setObject(b64eDataBlock, forKeyedSubscript: "base64EncodeWithData" as NSString)

        let b64dBlock: @convention(block) (String) -> String = { s in
            guard let data = Data(base64Encoded: s, options: [.ignoreUnknownCharacters]) else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
        obj?.setObject(b64dBlock, forKeyedSubscript: "base64Decode" as NSString)

        let getCacheBlock: @convention(block) (String) -> String = { key in
            CacheStore.get(key) ?? ""
        }
        obj?.setObject(getCacheBlock, forKeyedSubscript: "getCache" as NSString)

        // 香色 ObjC: set:cache: → JSExport setCache(value, key) 还是 setCache(key, value)？
        // 真机探针：t.setCache('xs_probe_k', 'xs_probe_v'); t.getCache('xs_probe_k') → 成功
        // 即 setCache(key, value)
        let setCacheBlock: @convention(block) (String, String) -> Void = { key, value in
            CacheStore.put(key, value: value)
        }
        obj?.setObject(setCacheBlock, forKeyedSubscript: "setCache" as NSString)

        let cookieByKeyBlock: @convention(block) (String) -> String = { key in
            CookieManager.shared.getCookie(for: key) ?? ""
        }
        obj?.setObject(cookieByKeyBlock, forKeyedSubscript: "cookieByKey" as NSString)

        let cookiesByUrlBlock: @convention(block) (String) -> [String] = { url in
            if let c = CookieManager.shared.getCookie(for: url), !c.isEmpty {
                return [c]
            }
            return []
        }
        obj?.setObject(cookiesByUrlBlock, forKeyedSubscript: "cookiesByUrl" as NSString)

        let stringByObjectBlock: @convention(block) (JSValue?) -> String = { v in
            stringifyJS(v)
        }
        obj?.setObject(stringByObjectBlock, forKeyedSubscript: "stringByObject" as NSString)

        let readFileBlock: @convention(block) (String) -> String = { path in
            forwardLCJSToolString("readTxtFile:", arg: path)
                ?? (try? String(contentsOfFile: path, encoding: .utf8))
                ?? ""
        }
        obj?.setObject(readFileBlock, forKeyedSubscript: "readFile" as NSString)
        obj?.setObject(readFileBlock, forKeyedSubscript: "readTxtFile" as NSString)

        let allFilesBlock: @convention(block) (String) -> [String] = { path in
            (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        }
        obj?.setObject(allFilesBlock, forKeyedSubscript: "allFilesAtPath" as NSString)

        let unzipBlock: @convention(block) (String) -> String = { path in
            forwardLCJSToolString("unzipFile:", arg: path) ?? ""
        }
        obj?.setObject(unzipBlock, forKeyedSubscript: "unzipFile" as NSString)

        let unzipPwBlock: @convention(block) (String, String) -> String = { path, password in
            forwardLCJSToolTwo("unzipFile:withPassword:", a: path, b: password) ?? ""
        }
        obj?.setObject(unzipPwBlock, forKeyedSubscript: "unzipFileWithPassword" as NSString)

        // AES：香色三参（明文/Base64, key, iv），默认 AES/CBC/PKCS7
        let aesDataBlock: @convention(block) (String, String, String) -> String = { [encode] data, key, iv in
            encode.aesDecodeToString(data, key: key, transformation: "AES/CBC/PKCS7Padding", iv: iv) ?? ""
        }
        obj?.setObject(aesDataBlock, forKeyedSubscript: "dataByAesDecryptWithDataWithKeyWithIv" as NSString)

        let aesB64DataBlock: @convention(block) (String, String, String) -> String = { [encode] data, key, iv in
            encode.aesBase64DecodeToString(data, key: key, transformation: "AES/CBC/PKCS7Padding", iv: iv) ?? ""
        }
        obj?.setObject(aesB64DataBlock, forKeyedSubscript: "dataByAesDecryptWithBase64DataWithKeyWithIv" as NSString)

        let aesB64StrBlock: @convention(block) (String, String, String) -> String = { [encode] data, key, iv in
            encode.aesBase64DecodeToString(data, key: key, transformation: "AES/CBC/PKCS7Padding", iv: iv) ?? ""
        }
        obj?.setObject(aesB64StrBlock, forKeyedSubscript: "dataByAesDecryptWithBase64StringWithKeyWithIv" as NSString)

        // XPath：最小可用——返回空串；完整 DOM 解析仍走 RuleEngine
        let xpathBlock: @convention(block) (String) -> String = { _ in "" }
        obj?.setObject(xpathBlock, forKeyedSubscript: "XPathParserWithSource" as NSString)

        return obj
    }

    // MARK: - helpers

    private static func bindGlobal(_ value: JSValue?, name: String, into jsContext: JSContext) {
        guard let value else { return }
        jsContext.setObject(value, forKeyedSubscript: name as NSString)
        jsContext.globalObject?.setObject(value, forKeyedSubscript: name as NSString)
    }

    private static func stringifyJS(_ v: JSValue?) -> String {
        guard let v, !v.isUndefined, !v.isNull else { return "" }
        if v.isString || v.isNumber || v.isBoolean {
            return v.toString() ?? ""
        }
        if let json = v.toObject(),
           JSONSerialization.isValidJSONObject(json),
           let data = try? JSONSerialization.data(withJSONObject: json),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return v.toString() ?? ""
    }

    private static func deviceId() -> String {
        #if canImport(UIKit)
        let raw = UIDevice.current.identifierForVendor?.uuidString ?? "legado-native-tool"
        #else
        let raw = "legado-native-tool"
        #endif
        // 香色真机样例为 32 位 hex（md5）
        return md5Hex(raw)
    }

    private static func deviceIdWithTemplate(_ template: String, separator: String) -> String {
        let id = deviceId()
        if template.isEmpty { return id }
        // 模板里 `*` 替换为 deviceId 段（香色 deviceIdWithTemplate:withSeparator:）
        return template.replacingOccurrences(of: "*", with: id)
            .replacingOccurrences(of: " ", with: separator)
    }

    private static func md5Hex(_ str: String) -> String {
        let data = Data(str.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_MD5(ptr.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func sha1Hex(_ str: String) -> String {
        let data = Data(str.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_SHA1(ptr.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 真机有 LCJSTool 时转发单参字符串方法
    private static func forwardLCJSToolString(_ selName: String, arg: String) -> String? {
        guard let tool = lcjsToolShared() else { return nil }
        let sel = NSSelectorFromString(selName)
        guard tool.responds(to: sel) else { return nil }
        let unmanaged = tool.perform(sel, with: arg)
        return unmanaged?.takeUnretainedValue() as? String
    }

    private static func forwardLCJSToolTwo(_ selName: String, a: String, b: String) -> String? {
        guard let tool = lcjsToolShared() else { return nil }
        let sel = NSSelectorFromString(selName)
        guard tool.responds(to: sel) else { return nil }
        let unmanaged = tool.perform(sel, with: a, with: b)
        return unmanaged?.takeUnretainedValue() as? String
    }

    private static func lcjsToolShared() -> NSObject? {
        guard let cls = NSClassFromString("LCJSTool") as? NSObject.Type else { return nil }
        let sel = NSSelectorFromString("sharedInstance")
        guard cls.responds(to: sel) else { return nil }
        return cls.perform(sel)?.takeUnretainedValue() as? NSObject
    }
}
