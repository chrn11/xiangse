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
import Kanna
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

        // XPath：对齐香色 LCJSTool.XPathParserWithSource: → TFHpple
        // JS: var doc = nativeTool.XPathParserWithSource(html);
        //     doc.searchWithXPathQuery(xpath) / peekAtSearchWithXPathQuery / queryWithXPath
        // 注意：JSC 对 @convention(block) 返回 JSValue 桥接不稳，须用 AnyObject?
        let xpathBlock: @convention(block) (String) -> AnyObject? = { source in
            if let forwarded = Self.forwardXPathDocument(source: source, into: jsContext) {
                return forwarded
            }
            return Self.makeXPathDocument(source: source, in: jsContext)
        }
        obj?.setObject(xpathBlock, forKeyedSubscript: "XPathParserWithSource" as NSString)

        return obj
    }

    // MARK: - XPath (TFHpple 兼容壳)

    /// 真机有 LCJSTool 时直接返回其 TFHpple（JSExport 已暴露查询方法）
    private static func forwardXPathDocument(source: String, into jsContext: JSContext) -> JSValue? {
        guard let tool = lcjsToolShared() else { return nil }
        let sel = NSSelectorFromString("XPathParserWithSource:")
        guard tool.responds(to: sel) else { return nil }
        guard let unmanaged = tool.perform(sel, with: source) else { return nil }
        let hpple = unmanaged.takeUnretainedValue()
        return JSValue(object: hpple, in: jsContext)
    }

    /// 纯 Swift：Kanna 实现与 TFHpple 同名的 JS 方法面
    private static func makeXPathDocument(source: String, in jsContext: JSContext) -> JSValue {
        let docVal = JSValue(newObjectIn: jsContext) ?? JSValue(nullIn: jsContext)
        let html = source

        let searchBlock: @convention(block) (String) -> AnyObject? = { query in
            Self.jsArray(from: Self.xpathNodes(in: html, query: query), context: jsContext)
        }
        docVal?.setObject(searchBlock, forKeyedSubscript: "searchWithXPathQuery" as NSString)
        docVal?.setObject(searchBlock, forKeyedSubscript: "queryWithXPath" as NSString)

        let peekBlock: @convention(block) (String) -> AnyObject? = { query in
            let nodes = Self.xpathNodes(in: html, query: query)
            guard let first = nodes.first else {
                return NSNull()
            }
            return Self.makeXPathElement(first, in: jsContext)
        }
        docVal?.setObject(peekBlock, forKeyedSubscript: "peekAtSearchWithXPathQuery" as NSString)

        return docVal ?? JSValue(nullIn: jsContext)
    }

    private static func xpathNodes(in html: String, query: String) -> [Kanna.XMLElement] {
        guard let doc = try? Kanna.HTML(html: html, encoding: .utf8) else { return [] }
        return Array(doc.xpath(query))
    }

    private static func jsArray(from nodes: [Kanna.XMLElement], context: JSContext) -> JSValue {
        let arr = JSValue(newArrayIn: context) ?? JSValue(nullIn: context)
        for (idx, node) in nodes.enumerated() {
            arr?.setObject(makeXPathElement(node, in: context), atIndexedSubscript: idx)
        }
        return arr ?? JSValue(nullIn: context)
    }

    private static func makeXPathElement(_ node: Kanna.XMLElement, in jsContext: JSContext) -> JSValue {
        let el = JSValue(newObjectIn: jsContext) ?? JSValue(nullIn: jsContext)
        let tag = node.tagName ?? ""
        let content = nodeContent(node)
        let text = node.text ?? content
        let raw = node.toHTML ?? content

        el?.setObject(content, forKeyedSubscript: "content" as NSString)
        el?.setObject(text, forKeyedSubscript: "text" as NSString)
        el?.setObject(tag, forKeyedSubscript: "tagName" as NSString)
        el?.setObject(raw, forKeyedSubscript: "raw" as NSString)

        // Kanna 5.2 无统一 attributes 属性，用下标收集常见键 + @* xpath
        var attrs: [String: String] = [:]
        for key in ["href", "src", "class", "id", "title", "name", "value", "type"] {
            if let v = node[key], !v.isEmpty {
                attrs[key] = v
            }
        }
        for attr in node.xpath("@*") {
            let name = attr.tagName ?? ""
            guard !name.isEmpty else { continue }
            let val = attr.content ?? attr.text ?? ""
            if !val.isEmpty {
                attrs[name] = val
            }
        }
        el?.setObject(attrs, forKeyedSubscript: "attributes" as NSString)

        let objectForKeyBlock: @convention(block) (String) -> String = { key in
            if let v = attrs[key] { return v }
            return node[key] ?? ""
        }
        el?.setObject(objectForKeyBlock, forKeyedSubscript: "objectForKey" as NSString)

        // 子树查询：以元素 outer HTML 为文档再 xpath（对齐 TFHppleElement.search*）
        let frag = raw
        let nestedSearch: @convention(block) (String) -> AnyObject? = { query in
            Self.jsArray(from: Self.xpathNodes(in: frag, query: query), context: jsContext)
        }
        el?.setObject(nestedSearch, forKeyedSubscript: "searchWithXPathQuery" as NSString)
        el?.setObject(nestedSearch, forKeyedSubscript: "queryWithXPath" as NSString)

        let nestedPeek: @convention(block) (String) -> AnyObject? = { query in
            let nodes = Self.xpathNodes(in: frag, query: query)
            guard let first = nodes.first else { return NSNull() }
            return Self.makeXPathElement(first, in: jsContext)
        }
        el?.setObject(nestedPeek, forKeyedSubscript: "peekAtSearchWithXPathQuery" as NSString)

        return el ?? JSValue(nullIn: jsContext)
    }

    private static func nodeContent(_ node: Kanna.XMLElement) -> String {
        // 文本节点 / 属性节点：优先 content；元素节点：text
        if let c = node.content, !c.isEmpty { return c }
        if let t = node.text, !t.isEmpty { return t }
        return ""
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
