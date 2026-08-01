//
//  JSBridge.swift
//  Legado-iOS
//
//  JS 桥接扩展 - 参考原版 JsExtensions.kt（1199行）+ JsEncodeUtils.kt（518行）
//  1:1 移植 Android io.legado.app.help.JsExtensions + JsEncodeUtils
//  在 JS 中通过 java 变量调用（如 java.ajax(url)、java.base64Decode(str)）
//

import Foundation
import JavaScriptCore
import CommonCrypto
import SwiftSoup
import LegadoObjCSupport

// MARK: - JSBridge 主类

/// JS 桥接类 - 对应 Android JsExtensions interface 实现
class JSBridge: JsEncodeUtils {

    weak var context: ExecutionContext?
    weak var ruleEngine: RuleEngine?

    /// 注入所有桥接对象到 JSContext
    func inject(into jsContext: JSContext) {
        Self.injectES6ConstructorCompat(into: jsContext)
        injectJavaObject(into: jsContext)
        injectSourceObject(into: jsContext)
        injectCookieObject(into: jsContext)
        injectNetworkObject(into: jsContext)
        injectCacheObject(into: jsContext)
        denyForbiddenNativeAPIs(into: jsContext)
        // 书源 jsLib：共享函数须在业务脚本之前落入同一上下文（对标 Android jsLib，只执行一次语义由调用方复用 context）
        Self.evaluateJsLib(of: context?.source, into: jsContext, headers: parseSourceHeaders())
    }

    /// J1：JSC 要求 `new Map()`，Android V8 容忍 `Map()`。包装后两种写法皆可。
    static func injectES6ConstructorCompat(into jsContext: JSContext) {
        _ = ObjCExceptionCatch.evaluateScript("""
        (function (g) {
          function wrapCtor(Native, name) {
            if (typeof Native !== 'function') return;
            if (Native.__legadoWrapped) return;
            function Wrapped() {
              var args = Array.prototype.slice.call(arguments);
              if (typeof Reflect !== 'undefined' && Reflect.construct) {
                return Reflect.construct(Native, args, Wrapped);
              }
              args.unshift(null);
              return new (Function.prototype.bind.apply(Native, args))();
            }
            Wrapped.prototype = Native.prototype;
            try { Object.setPrototypeOf(Wrapped, Native); } catch (e) {}
            try { Object.defineProperty(Wrapped, 'name', { value: name }); } catch (e2) {}
            Wrapped.__legadoWrapped = true;
            g[name] = Wrapped;
          }
          wrapCtor(g.Map, 'Map');
          wrapCtor(g.Set, 'Set');
          wrapCtor(g.WeakMap, 'WeakMap');
          wrapCtor(g.WeakSet, 'WeakSet');
        })(this);
        """, in: jsContext, error: nil)
    }

    /// 将书源 `jsLib` 注入当前 JSContext。纯 http(s) URL 则先拉取再执行。
    static func evaluateJsLib(
        of source: (any BridgeSourceProtocol)?,
        into jsContext: JSContext,
        headers: [String: String]? = nil
    ) {
        guard let raw = source?.jsLib?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return
        }
        let script: String
        if Self.isRemoteScriptURL(raw) {
            script = JSBridgeHTTPClient.syncGet(url: raw, headers: headers)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if script.isEmpty {
                DebugLogger.shared.log("[jsLib] 远程拉取失败 url=\(raw.prefix(120))")
                return
            }
        } else {
            script = raw
        }
        var jsError: String?
        let previous = jsContext.exceptionHandler
        jsContext.exceptionHandler = { _, ex in jsError = ex?.toString() }
        var objcError: NSString?
        _ = ObjCExceptionCatch.evaluateScript(script, in: jsContext, error: &objcError)
        jsContext.exceptionHandler = previous
        if let objcError {
            DebugLogger.shared.log("[jsLib] objc \(objcError)")
        }
        if let jsError, !jsError.isEmpty {
            DebugLogger.shared.log("[jsLib] \(jsError)")
        }
    }

    /// 单行 http(s) URL → 视为远程脚本地址（非内联 JS）
    private static func isRemoteScriptURL(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: { $0.isNewline }) else { return false }
        guard trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") else {
            return false
        }
        // 含空格或典型 JS 关键字则当作内联脚本，避免误拉
        if trimmed.contains(" ") { return false }
        let lower = trimmed.lowercased()
        if lower.contains("function") || lower.contains("var ") || lower.contains("let ")
            || lower.contains("const ") || lower.contains("=>") {
            return false
        }
        return URL(string: trimmed) != nil
    }

    // MARK: - java 对象注入

    private func injectJavaObject(into jsContext: JSContext) {
        let javaObject = JSValue(newObjectIn: jsContext)

        // ====== 网络函数 ======

        let ajaxBlock: @convention(block) (String) -> String = { [weak self] url in
            guard let self = self, !url.isEmpty else { return "" }
            return self.ajaxViaAnalyzeUrl(url) 
        }
        javaObject?.setObject(ajaxBlock, forKeyedSubscript: "ajax" as NSString)

        // 对标 Android java.importScript：拉取远程 JS 并 eval 进当前上下文（jsLib / 备注共用库常用）
        let importScriptBlock: @convention(block) (String) -> String = { [weak self, weak jsContext] url in
            guard let jsContext, !url.isEmpty else { return "" }
            let body = JSBridgeHTTPClient.syncGet(url: url, headers: self?.parseSourceHeaders()) ?? ""
            guard !body.isEmpty else { return "" }
            var jsError: String?
            let previous = jsContext.exceptionHandler
            jsContext.exceptionHandler = { _, ex in jsError = ex?.toString() }
            _ = ObjCExceptionCatch.evaluateScript(body, in: jsContext, error: nil)
            jsContext.exceptionHandler = previous
            if let jsError, !jsError.isEmpty {
                DebugLogger.shared.log("[importScript] \(jsError)")
            }
            return body
        }
        javaObject?.setObject(importScriptBlock, forKeyedSubscript: "importScript" as NSString)

        let getStringBlock: @convention(block) (String) -> String = { url in ajaxBlock(url) }
        javaObject?.setObject(getStringBlock, forKeyedSubscript: "getString" as NSString)

        let getStringAsyncBlock: @convention(block) (String) -> Void = { [weak self] url in
            guard !url.isEmpty else { return }
            let headers = self?.parseSourceHeaders()
            JSBridgeHTTPClient.asyncGet(url: url, headers: headers) { result in
                DispatchQueue.main.async { self?.context?.variables["result"] = result ?? "" }
            }
        }
        javaObject?.setObject(getStringAsyncBlock, forKeyedSubscript: "getStringAsync" as NSString)

        let connectBlock: @convention(block) (String) -> String = { [weak self] urlStr in
            guard let self = self, !urlStr.isEmpty else { return "" }
            return JSBridgeHTTPClient.syncGet(url: urlStr, headers: self.parseSourceHeaders()) ?? ""
        }
        javaObject?.setObject(connectBlock, forKeyedSubscript: "connect" as NSString)

        let connectHeaderBlock: @convention(block) (String, String) -> String = { [weak self] urlStr, header in
            guard !urlStr.isEmpty else { return "" }
            var headers = self?.parseSourceHeaders() ?? [:]
            if let data = header.data(using: .utf8),
               let custom = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                headers.merge(custom) { _, new in new }
            }
            return JSBridgeHTTPClient.syncGet(url: urlStr, headers: headers) ?? ""
        }
        javaObject?.setObject(connectHeaderBlock, forKeyedSubscript: "connect" as NSString)

        // ====== 变量存取 ======
        // bookUrl 非空 → 书本级 BookVariableStore；否则 → 源级 SourceSessionStore

        let putBlock: @convention(block) (String, String) -> String = { [weak self] key, value in
            self?.context?.variables[key] = value
            if let bookUrl = self?.context?.bookUrl, !bookUrl.isEmpty {
                BookVariableStore.put(key, value: value, bookUrl: bookUrl)
            } else if let sourceUrl = self?.context?.source?.bookSourceUrl {
                SourceSessionStore.put(key, value: value, sourceUrl: sourceUrl)
            }
            return value
        }
        javaObject?.setObject(putBlock, forKeyedSubscript: "put" as NSString)

        let getBlock: @convention(block) (String) -> String = { [weak self] key in
            if let local = self?.context?.variables[key], !local.isEmpty { return local }
            if let bookUrl = self?.context?.bookUrl, !bookUrl.isEmpty {
                let fromBook = BookVariableStore.get(key, bookUrl: bookUrl)
                if !fromBook.isEmpty { return fromBook }
            }
            return SourceSessionStore.get(key, sourceUrl: self?.context?.source?.bookSourceUrl)
        }
        javaObject?.setObject(getBlock, forKeyedSubscript: "get" as NSString)

        // ====== 正文 / 选元素（AnalyzeRule） ======

        let setContentBlock: @convention(block) (String) -> Void = { [weak self] html in
            self?.context?.analyzeContent = html
            self?.context?.document = html
            self?.context?.lastResult = .string(html)
        }
        javaObject?.setObject(setContentBlock, forKeyedSubscript: "setContent" as NSString)

        let getElementBlock: @convention(block) (String) -> JSValue = { [weak self, weak jsContext] path in
            guard let jsContext = jsContext else {
                return JSValue(nullIn: JSContext())!
            }
            let empty = JSValue(newArrayIn: jsContext)!
            empty.setValue(0, forKey: "length")
            guard let self = self else { return empty }
            let html = self.context?.analyzeContent
                ?? self.context?.lastResult.string
                ?? (self.context?.document as? String)
                ?? ""
            let base = self.context?.analyzeBaseUrl ?? self.context?.baseURL?.absoluteString
            let engine = self.ruleEngine ?? self.context?.ruleEngine ?? RuleEngine()
            let elements: [ElementContext]
            do {
                elements = try engine.getElements(ruleStr: path, body: html, baseUrl: base, source: self.context?.source)
            } catch {
                elements = []
            }
            self.context?.lastElementContexts = elements
            // 返回带 length 的类数组，供 `c.length` 判断（显式写 length，避免 JSC 桥接漏计）
            let arr = JSValue(newArrayIn: jsContext)!
            for (idx, el) in elements.enumerated() {
                if let soup = el.element as? Element {
                    arr.setObject((try? soup.outerHtml()) ?? "", atIndexedSubscript: idx)
                } else if let s = el.element as? String {
                    arr.setObject(s, atIndexedSubscript: idx)
                } else {
                    arr.setObject(String(describing: el.element), atIndexedSubscript: idx)
                }
            }
            arr.setValue(elements.count, forKey: "length")
            return arr
        }
        javaObject?.setObject(getElementBlock, forKeyedSubscript: "getElement" as NSString)
        // 阅读文档亦提供 getElements；与 getElement 同实现（均返回列表）
        javaObject?.setObject(getElementBlock, forKeyedSubscript: "getElements" as NSString)

        // ====== 可见浏览器等待（起点 Cookie 验证等） ======

        let startBrowserAwaitBlock: @convention(block) (String, String) -> String = { [weak self] url, title in
            let sourceUrl = self?.context?.source?.bookSourceUrl
            let html = BrowserAwaitGate.startBrowserAwait(url: url, title: title, sourceUrl: sourceUrl)
            if !html.isEmpty {
                self?.context?.analyzeContent = html
                self?.context?.document = html
            }
            return html
        }
        javaObject?.setObject(startBrowserAwaitBlock, forKeyedSubscript: "startBrowserAwait" as NSString)

        let startBrowserBlock: @convention(block) (String, String) -> Void = { [weak self] url, title in
            let sourceUrl = self?.context?.source?.bookSourceUrl
            _ = BrowserAwaitGate.startBrowserAwait(url: url, title: title, sourceUrl: sourceUrl)
        }
        javaObject?.setObject(startBrowserBlock, forKeyedSubscript: "startBrowser" as NSString)

        // ====== 编码函数 ======

        let base64DecodeBlock: @convention(block) (String) -> String = { str in
            guard let data = Data(base64Encoded: str, options: [.ignoreUnknownCharacters]) else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
        javaObject?.setObject(base64DecodeBlock, forKeyedSubscript: "base64Decode" as NSString)

        let base64DecodeCharsetBlock: @convention(block) (String, String) -> String = { str, charset in
            guard let data = Data(base64Encoded: str, options: [.ignoreUnknownCharacters]) else { return "" }
            let encoding = Self.charsetNameToEncoding(charset) ?? .utf8
            return String(data: data, encoding: encoding) ?? ""
        }
        javaObject?.setObject(base64DecodeCharsetBlock, forKeyedSubscript: "base64Decode" as NSString)

        let base64EncodeBlock: @convention(block) (String) -> String = { str in
            guard let data = str.data(using: .utf8) else { return "" }
            return data.base64EncodedString()
        }
        javaObject?.setObject(base64EncodeBlock, forKeyedSubscript: "base64Encode" as NSString)

        let base64EncodeFlagsBlock: @convention(block) (String, Int) -> String = { str, flags in
            guard let data = str.data(using: .utf8) else { return "" }
            let options: Data.Base64EncodingOptions = flags == 0 ? [] : [.lineLength64Characters]
            return data.base64EncodedString(options: options)
        }
        javaObject?.setObject(base64EncodeFlagsBlock, forKeyedSubscript: "base64Encode" as NSString)

        let hexDecodeStrBlock: @convention(block) (String) -> String = { hex in
            guard let data = hexToData(hex) else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
        javaObject?.setObject(hexDecodeStrBlock, forKeyedSubscript: "hexDecodeToString" as NSString)

        let hexEncodeStrBlock: @convention(block) (String) -> String = { utf8 in
            guard let data = utf8.data(using: .utf8) else { return "" }
            return dataToHex(data)
        }
        javaObject?.setObject(hexEncodeStrBlock, forKeyedSubscript: "hexEncodeToString" as NSString)

        let encodeURIBlock: @convention(block) (String) -> String = { str in
            return str.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        }
        javaObject?.setObject(encodeURIBlock, forKeyedSubscript: "encodeURI" as NSString)

        let htmlFormatBlock: @convention(block) (String) -> String = { str in
            return str.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        }
        javaObject?.setObject(htmlFormatBlock, forKeyedSubscript: "htmlFormat" as NSString)

        // ====== 时间函数 ======

        let timeFormatUTCBlock: @convention(block) (Double, String, Int) -> String = { time, format, sh in
            let date = Date(timeIntervalSince1970: time / 1000.0)
            let formatter = DateFormatter()
            formatter.dateFormat = format
            formatter.timeZone = TimeZone(secondsFromGMT: sh * 3600)
            return formatter.string(from: date)
        }
        javaObject?.setObject(timeFormatUTCBlock, forKeyedSubscript: "timeFormatUTC" as NSString)

        let timeFormatBlock: @convention(block) (Double) -> String = { time in
            let date = Date(timeIntervalSince1970: time / 1000.0)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return formatter.string(from: date)
        }
        javaObject?.setObject(timeFormatBlock, forKeyedSubscript: "timeFormat" as NSString)

        // ====== 中文转换 ======
        // 注意：kCFStringTransformTraditionalChineseSimplified / kCFStringTransformSimplifiedChineseTraditional
        // 在 iOS 上不可用（仅 macOS），使用 CFStringTransform 的 Unicode 标识符名称替代

        let t2sBlock: @convention(block) (String) -> String = { text in
            let str = NSMutableString(string: text)
            CFStringTransform(str, nil, "zh-Hant-Hanzi zh-Hans-Hanzi" as CFString, false)
            return str as String
        }
        javaObject?.setObject(t2sBlock, forKeyedSubscript: "t2s" as NSString)

        let s2tBlock: @convention(block) (String) -> String = { text in
            let str = NSMutableString(string: text)
            CFStringTransform(str, nil, "zh-Hans-Hanzi zh-Hant-Hanzi" as CFString, false)
            return str as String
        }
        javaObject?.setObject(s2tBlock, forKeyedSubscript: "s2t" as NSString)

        // ====== MD5 ======

        let md5EncodeBlock: @convention(block) (String) -> String = { [weak self] str in self?.md5Encode(str) ?? "" }
        javaObject?.setObject(md5EncodeBlock, forKeyedSubscript: "md5Encode" as NSString)

        let md5Encode16Block: @convention(block) (String) -> String = { [weak self] str in self?.md5Encode16(str) ?? "" }
        javaObject?.setObject(md5Encode16Block, forKeyedSubscript: "md5Encode16" as NSString)

        // ====== 摘要 ======

        let digestHexBlock: @convention(block) (String, String) -> String = { [weak self] data, algorithm in
            self?.digestHex(data, algorithm: algorithm) ?? ""
        }
        javaObject?.setObject(digestHexBlock, forKeyedSubscript: "digestHex" as NSString)

        let digestBase64Block: @convention(block) (String, String) -> String = { [weak self] data, algorithm in
            self?.digestBase64Str(data, algorithm: algorithm) ?? ""
        }
        javaObject?.setObject(digestBase64Block, forKeyedSubscript: "digestBase64Str" as NSString)

        let hmacHexBlock: @convention(block) (String, String, String) -> String = { [weak self] data, algorithm, key in
            self?.HMacHex(data, algorithm: algorithm, key: key) ?? ""
        }
        javaObject?.setObject(hmacHexBlock, forKeyedSubscript: "HMacHex" as NSString)

        let hmacBase64Block: @convention(block) (String, String, String) -> String = { [weak self] data, algorithm, key in
            self?.HMacBase64(data, algorithm: algorithm, key: key) ?? ""
        }
        javaObject?.setObject(hmacBase64Block, forKeyedSubscript: "HMacBase64" as NSString)

        // ====== 对称加密工厂 ======

        let createSymCryptoBlock: @convention(block) (String, String, String?) -> JSValue = { [weak self, weak jsContext] transformation, key, iv in
            guard let self = self, let jsContext = jsContext else { return JSValue(nullIn: jsContext) }
            let crypto = self.createSymmetricCrypto(transformation: transformation, key: key, iv: iv)
            let obj = JSValue(newObjectIn: jsContext)
            obj?.setObject({ (d: String) -> String in crypto.encryptBase64(d) ?? "" }, forKeyedSubscript: "encryptBase64" as NSString)
            obj?.setObject({ (d: String) -> String in crypto.encryptHex(d) ?? "" }, forKeyedSubscript: "encryptHex" as NSString)
            obj?.setObject({ (d: String) -> String in crypto.decryptStr(d) ?? "" }, forKeyedSubscript: "decryptStr" as NSString)
            return obj ?? JSValue(nullIn: jsContext)
        }
        javaObject?.setObject(createSymCryptoBlock, forKeyedSubscript: "createSymmetricCrypto" as NSString)

        // ====== AES 兼容旧接口 ======

        let aesDecodeBlock: @convention(block) (String, String, String, String) -> String = { [weak self] str, key, t, iv in
            self?.aesDecodeToString(str, key: key, transformation: t, iv: iv) ?? ""
        }
        javaObject?.setObject(aesDecodeBlock, forKeyedSubscript: "aesDecodeToString" as NSString)

        let aesBase64DecodeBlock: @convention(block) (String, String, String, String) -> String = { [weak self] str, key, t, iv in
            self?.aesBase64DecodeToString(str, key: key, transformation: t, iv: iv) ?? ""
        }
        javaObject?.setObject(aesBase64DecodeBlock, forKeyedSubscript: "aesBase64DecodeToString" as NSString)

        let aesEncodeBase64Block: @convention(block) (String, String, String, String) -> String = { [weak self] data, key, t, iv in
            self?.aesEncodeToBase64String(data, key: key, transformation: t, iv: iv) ?? ""
        }
        javaObject?.setObject(aesEncodeBase64Block, forKeyedSubscript: "aesEncodeToBase64String" as NSString)

        // ====== DES 兼容旧接口 ======

        let desDecodeBlock: @convention(block) (String, String, String, String) -> String = { [weak self] data, key, t, iv in
            self?.desDecodeToString(data, key: key, transformation: t, iv: iv) ?? ""
        }
        javaObject?.setObject(desDecodeBlock, forKeyedSubscript: "desDecodeToString" as NSString)

        let desEncodeBase64Block: @convention(block) (String, String, String, String) -> String = { [weak self] data, key, t, iv in
            self?.desEncodeToBase64String(data, key: key, transformation: t, iv: iv) ?? ""
        }
        javaObject?.setObject(desEncodeBase64Block, forKeyedSubscript: "desEncodeToBase64String" as NSString)

        // ====== 工具函数 ======

        let logBlock: @convention(block) (String) -> String = { message in print("[JsExt] \(message)"); return message }
        javaObject?.setObject(logBlock, forKeyedSubscript: "log" as NSString)

        let toastBlock: @convention(block) (String) -> Void = { msg in print("[Toast] \(msg)") }
        javaObject?.setObject(toastBlock, forKeyedSubscript: "toast" as NSString)
        javaObject?.setObject(toastBlock, forKeyedSubscript: "longToast" as NSString)

        let uuidBlock: @convention(block) () -> String = { UUID().uuidString }
        javaObject?.setObject(uuidBlock, forKeyedSubscript: "randomUUID" as NSString)

        let webViewUABlock: @convention(block) () -> String = {
            "Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.5 Mobile/15E148 Safari/604.1"
        }
        javaObject?.setObject(webViewUABlock, forKeyedSubscript: "getWebViewUA" as NSString)

        #if canImport(UIKit)
        let androidIdBlock: @convention(block) () -> String = {
            UIDevice.current.identifierForVendor?.uuidString ?? ""
        }
        javaObject?.setObject(androidIdBlock, forKeyedSubscript: "androidId" as NSString)
        #endif

        // 真机：JSContext.setValue(_:forKey:) 写入的全局对 evaluateScript 不可见
        // （曾表现为 Can't find variable: baseUrl / java；起点 searchUrl 靠 recover 才通）。
        // 必须用 setObject:forKeyedSubscript: 挂到上下文与 globalObject。
        Self.bindGlobal(javaObject, name: "java", into: jsContext)
    }

    /// 把桥接对象挂到 JSContext，保证真机 evaluateScript 能读到同名全局
    private static func bindGlobal(_ value: JSValue?, name: String, into jsContext: JSContext) {
        guard let value else { return }
        jsContext.setObject(value, forKeyedSubscript: name as NSString)
        jsContext.globalObject?.setObject(value, forKeyedSubscript: name as NSString)
    }

    // MARK: - source 对象注入

    private func injectSourceObject(into jsContext: JSContext) {
        let sourceObject = JSValue(newObjectIn: jsContext)

        sourceObject?.setObject({ [weak self] in self?.context?.source?.bookSourceUrl ?? "" }, forKeyedSubscript: "bookSourceUrl" as NSString)
        sourceObject?.setObject({ [weak self] in self?.context?.source?.bookSourceName ?? "" }, forKeyedSubscript: "bookSourceName" as NSString)
        sourceObject?.setObject({ [weak self] in self?.context?.source?.loginUrl ?? "" }, forKeyedSubscript: "loginUrl" as NSString)
        sourceObject?.setObject({ [weak self] in self?.context?.source?.header ?? "" }, forKeyedSubscript: "header" as NSString)
        sourceObject?.setObject({ [weak self] in self?.context?.source?.variable ?? "" }, forKeyedSubscript: "variable" as NSString)
        sourceObject?.setObject({ [weak self] in self?.context?.source?.enabledCookieJar ?? false }, forKeyedSubscript: "enabledCookieJar" as NSString)
        sourceObject?.setObject({ [weak self] in self?.context?.source?.concurrentRate ?? "" }, forKeyedSubscript: "concurrentRate" as NSString)
        // Android BaseSource.getKey() == bookSourceUrl
        let getKeyBlock: @convention(block) () -> String = { [weak self] in
            self?.context?.source?.bookSourceUrl ?? ""
        }
        sourceObject?.setObject(getKeyBlock, forKeyedSubscript: "getKey" as NSString)
        sourceObject?.setObject(getKeyBlock, forKeyedSubscript: "getTag" as NSString)

        Self.bindGlobal(sourceObject, name: "source", into: jsContext)
        injectBookObject(into: jsContext)
    }

    // MARK: - book 对象注入（书本级变量）

    private func injectBookObject(into jsContext: JSContext) {
        let bookObject = JSValue(newObjectIn: jsContext)

        bookObject?.setObject({ [weak self] in self?.context?.bookUrl ?? "" }, forKeyedSubscript: "bookUrl" as NSString)
        bookObject?.setObject({ [weak self] in self?.context?.bookName ?? "" }, forKeyedSubscript: "name" as NSString)

        let getKeyBlock: @convention(block) () -> String = { [weak self] in
            self?.context?.bookUrl ?? ""
        }
        bookObject?.setObject(getKeyBlock, forKeyedSubscript: "getKey" as NSString)

        let getVariableBlock: @convention(block) (String) -> String = { [weak self] key in
            if let local = self?.context?.variables[key], !local.isEmpty { return local }
            return BookVariableStore.get(key, bookUrl: self?.context?.bookUrl)
        }
        bookObject?.setObject(getVariableBlock, forKeyedSubscript: "getVariable" as NSString)

        let putVariableBlock: @convention(block) (String, String) -> String = { [weak self] key, value in
            self?.context?.variables[key] = value
            if let bookUrl = self?.context?.bookUrl, !bookUrl.isEmpty {
                BookVariableStore.put(key, value: value, bookUrl: bookUrl)
            }
            return value
        }
        bookObject?.setObject(putVariableBlock, forKeyedSubscript: "putVariable" as NSString)

        Self.bindGlobal(bookObject, name: "book", into: jsContext)
    }

    // MARK: - cookie 对象注入

    private func injectCookieObject(into jsContext: JSContext) {
        let cookieObject = JSValue(newObjectIn: jsContext)

        let getCookieBlock: @convention(block) (String) -> String = { url in
            guard let cookieURL = URL(string: url), let cookies = HTTPCookieStorage.shared.cookies(for: cookieURL), !cookies.isEmpty else { return "" }
            return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }

        let getCookieKeyBlock: @convention(block) (String, String) -> String = { tag, key in
            let cookie = CookieManager.shared.getCookie(for: tag) ?? ""
            for pair in cookie.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 && parts[0] == key { return parts[1] }
            }
            return ""
        }

        let setCookieBlock: @convention(block) (String, String) -> Void = { url, cookie in
            guard let cookieURL = URL(string: url), !cookie.isEmpty else { return }
            let parsed = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": cookie], for: cookieURL)
            if parsed.isEmpty {
                if let simple = Self.makeSimpleCookie(cookie, for: cookieURL) { HTTPCookieStorage.shared.setCookie(simple) }
            } else {
                for item in parsed { HTTPCookieStorage.shared.setCookie(item) }
            }
        }

        let removeCookieBlock: @convention(block) (String) -> Void = { url in
            guard let cookieURL = URL(string: url), let cookies = HTTPCookieStorage.shared.cookies(for: cookieURL) else { return }
            for item in cookies { HTTPCookieStorage.shared.deleteCookie(item) }
            CookieManager.shared.removeCookie(for: url)
        }

        cookieObject?.setObject(getCookieBlock, forKeyedSubscript: "get" as NSString)
        cookieObject?.setObject(getCookieKeyBlock, forKeyedSubscript: "getKey" as NSString)
        cookieObject?.setObject(setCookieBlock, forKeyedSubscript: "set" as NSString)
        cookieObject?.setObject(removeCookieBlock, forKeyedSubscript: "remove" as NSString)
        // 起点书源写的是 cookie.removeCookie(source.getKey())
        cookieObject?.setObject(removeCookieBlock, forKeyedSubscript: "removeCookie" as NSString)

        Self.bindGlobal(cookieObject, name: "cookie", into: jsContext)
    }

    // MARK: - network 对象注入（阅读约定）

    private func injectNetworkObject(into jsContext: JSContext) {
        let networkObject = JSValue(newObjectIn: jsContext)

        let ajaxBlock: @convention(block) (String) -> String = { [weak self] url in
            guard let self = self, !url.isEmpty else { return "" }
            return self.ajaxViaAnalyzeUrl(url)
        }
        networkObject?.setObject(ajaxBlock, forKeyedSubscript: "ajax" as NSString)

        let getBlock: @convention(block) (String) -> String = { url in ajaxBlock(url) }
        networkObject?.setObject(getBlock, forKeyedSubscript: "get" as NSString)

        let postBlock: @convention(block) (String, String) -> String = { [weak self] url, body in
            guard let self = self, !url.isEmpty else { return "" }
            return JSBridgeHTTPClient.syncPost(url: url, body: body, headers: self.parseSourceHeaders()) ?? ""
        }
        networkObject?.setObject(postBlock, forKeyedSubscript: "post" as NSString)

        Self.bindGlobal(networkObject, name: "network", into: jsContext)
    }

    /// 禁止协议外原生能力：钥匙串、香色私有文件等
    private func denyForbiddenNativeAPIs(into jsContext: JSContext) {
        let deny: @convention(block) (String) -> String = { name in
            DebugLogger.shared.log("[JS] 拒绝协议外原生能力: \(name)")
            return ""
        }
        jsContext.setObject(deny, forKeyedSubscript: "__denyNative" as NSString)
        jsContext.globalObject?.setObject(deny, forKeyedSubscript: "__denyNative" as NSString)
        _ = ObjCExceptionCatch.evaluateScript("""
        (function(){
          var blocked = ['SecItem','keychain','xiangsePrivateFile','LAContext'];
          blocked.forEach(function(n){
            try { this[n] = function(){ return __denyNative(n); }; } catch(e) {}
          });
        })();
        """, in: jsContext, error: nil)
    }

    // MARK: - cache 对象注入

    private func injectCacheObject(into jsContext: JSContext) {
        let cacheObject = JSValue(newObjectIn: jsContext)

        cacheObject?.setObject({ (key: String) -> String in CacheStore.get(key) ?? "" }, forKeyedSubscript: "get" as NSString)
        cacheObject?.setObject({ (key: String, value: String) -> Void in CacheStore.put(key, value: value) }, forKeyedSubscript: "put" as NSString)
        cacheObject?.setObject({ (key: String) -> String in CacheStore.get(key) ?? "" }, forKeyedSubscript: "getFromMemory" as NSString)

        Self.bindGlobal(cacheObject, name: "cache", into: jsContext)
    }

    // MARK: - 辅助方法

    /// 经 AnalyzeUrl 发请求（支持 `url,{json}` 选项串，与 Android ajax 一致）
    private func ajaxViaAnalyzeUrl(_ url: String) -> String {
        let source = context?.source
        let base = context?.baseURL?.absoluteString ?? source?.bookSourceUrl ?? ""
        let analyzed = AnalyzeUrl.analyze(
            ruleUrl: url,
            baseUrl: base,
            source: source
        )
        let semaphore = DispatchSemaphore(value: 0)
        let box = AjaxBodyBox()
        Task {
            do {
                let (respBody, _) = try await AnalyzeUrl.getResponseBody(
                    analyzedUrl: analyzed,
                    source: source
                )
                box.value = respBody
            } catch {
                DebugLogger.shared.log("[JS.ajax] \(error)")
                box.value = ""
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 30)
        return box.value
    }

    private final class AjaxBodyBox: @unchecked Sendable {
        var value = ""
    }

    private func parseSourceHeaders() -> [String: String]? {
        guard let headerString = context?.source?.header,
              let data = headerString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let headers = json as? [String: String] { return headers }
        if let dict = json as? [String: Any] {
            var h: [String: String] = [:]
            for (k, v) in dict { h[k] = "\(v)" }
            return h.isEmpty ? nil : h
        }
        return nil
    }

    private static func makeSimpleCookie(_ cookie: String, for url: URL) -> HTTPCookie? {
        guard let rawPair = cookie.split(separator: ";", maxSplits: 1).first else { return nil }
        let pair = rawPair.trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = pair.split(separator: "=", maxSplits: 1).map(String.init)
        guard segments.count == 2, let host = url.host, !segments[0].isEmpty else { return nil }
        return HTTPCookie(properties: [.name: segments[0], .value: segments[1], .domain: host, .path: "/"])
    }

    private static func charsetNameToEncoding(_ name: String) -> String.Encoding? {
        switch name.lowercased() {
        case "utf-8", "utf8": return .utf8
        case "gbk", "gb2312", "gb18030":
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        case "big5":
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue)))
        case "iso-8859-1", "latin1": return .isoLatin1
        default: return nil
        }
    }
}

// MARK: - CacheStore

/// 简单缓存管理器 - 对应 Android CacheManager 内存部分
class CacheStore {
    private static var memoryCache: [String: String] = [:]
    private static let lock = NSLock()

    static func get(_ key: String) -> String? { lock.lock(); defer { lock.unlock() }; return memoryCache[key] }
    static func put(_ key: String, value: String, saveTime: Int = 0) { lock.lock(); defer { lock.unlock() }; memoryCache[key] = value }
    static func delete(_ key: String) { lock.lock(); defer { lock.unlock() }; memoryCache.removeValue(forKey: key) }
}

// MARK: - JSBridgeHTTPClient

class JSBridgeHTTPClient: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    private static let shared = JSBridgeHTTPClient()

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // J4：书源外网常遇非标准证书；允许继续（仅本会话，供 jsLib/ajax/导入）
        return URLSession(configuration: config, delegate: shared, delegateQueue: nil)
    }()

    private func acceptServerTrust(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        acceptServerTrust(challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        acceptServerTrust(challenge, completionHandler: completionHandler)
    }

    static func syncGet(url: String, headers: [String: String]?) -> String? {
        guard let request = makeRequest(url: url, headers: headers, method: "GET", body: nil) else { return nil }
        let semaphore = DispatchSemaphore(value: 0)
        var output: String?
        var task: URLSessionDataTask?
        task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if error != nil { return }
            guard let data else { return }
            if let resp = response as? HTTPURLResponse, !(200..<300).contains(resp.statusCode) { return }
            output = decode(data: data, response: response)
        }
        task?.resume()
        if semaphore.wait(timeout: DispatchTime.now() + .seconds(15)) == .timedOut { task?.cancel(); return nil }
        return output
    }

    static func asyncGet(url: String, headers: [String: String]?, completion: @escaping (String?) -> Void) {
        guard let request = makeRequest(url: url, headers: headers, method: "GET", body: nil) else { completion(nil); return }
        session.dataTask(with: request) { data, response, error in
            if error != nil { completion(nil); return }
            guard let data else { completion(nil); return }
            if let resp = response as? HTTPURLResponse, !(200..<300).contains(resp.statusCode) { completion(nil); return }
            completion(decode(data: data, response: response))
        }.resume()
    }

    static func syncPost(url: String, body: String, headers: [String: String]?) -> String? {
        guard let request = makeRequest(url: url, headers: headers, method: "POST", body: body) else { return nil }
        let semaphore = DispatchSemaphore(value: 0)
        var output: String?
        var task: URLSessionDataTask?
        task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if error != nil { return }
            guard let data else { return }
            if let resp = response as? HTTPURLResponse, !(200..<300).contains(resp.statusCode) { return }
            output = decode(data: data, response: response)
        }
        task?.resume()
        if semaphore.wait(timeout: DispatchTime.now() + .seconds(15)) == .timedOut { task?.cancel(); return nil }
        return output
    }

    private static func makeRequest(url: String, headers: [String: String]?, method: String = "GET", body: String? = nil) -> URLRequest? {
        guard let targetURL = URL(string: url) else { return nil }
        var request = URLRequest(url: targetURL)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.5 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        headers?.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        if let body {
            request.httpBody = body.data(using: .utf8)
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            }
        }
        return request
    }

    private static func decode(data: Data, response: URLResponse?) -> String? {
        if let httpResponse = response as? HTTPURLResponse, let encodingName = httpResponse.textEncodingName {
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(encodingName as CFString)
            if cfEncoding != kCFStringEncodingInvalidId {
                let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
                if let text = String(data: data, encoding: String.Encoding(rawValue: nsEncoding)) { return text }
            }
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(data: data, encoding: .isoLatin1)
    }
}

#if canImport(UIKit)
import UIKit
#endif