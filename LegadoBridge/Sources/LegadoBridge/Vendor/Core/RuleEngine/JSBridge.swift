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
        injectOrgJsoup(into: jsContext)
        denyForbiddenNativeAPIs(into: jsContext)
        // 书源 jsLib：共享函数须在业务脚本之前落入同一上下文（对标 Android jsLib，只执行一次语义由调用方复用 context）
        Self.evaluateJsLib(of: context?.source, into: jsContext, headers: parseSourceHeaders())
        Self.injectLegadoMapLookup(into: jsContext)
    }

    /// `{{}}` lite：ES6 + java/source/cookie，不跑 jsLib（避免每段模板重复拉远程脚本）。
    func injectLite(into jsContext: JSContext) {
        Self.injectES6ConstructorCompat(into: jsContext)
        injectJavaObject(into: jsContext)
        injectSourceObject(into: jsContext)
        injectCookieObject(into: jsContext)
        denyForbiddenNativeAPIs(into: jsContext)
        Self.injectLegadoMapLookup(into: jsContext)
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

    /// 书源惯例：`Map("token")` / `Map("search")` 取登录/会话变量字符串，不是 ES6 Map。
    /// 单字符串参数 → java.get / source 变量；否则走已包装的 ES6 Map。
    static func injectLegadoMapLookup(into jsContext: JSContext) {
        _ = ObjCExceptionCatch.evaluateScript("""
        (function (g) {
          var ES6Map = g.Map;
          if (typeof ES6Map !== 'function') return;
          if (ES6Map.__legadoLookup) return;
          function LegadoMap(key) {
            if (arguments.length === 1 && (typeof key === 'string' || typeof key === 'number')) {
              var k = String(key);
              try {
                if (typeof java !== 'undefined' && java && typeof java.get === 'function') {
                  var v = java.get(k);
                  if (v !== undefined && v !== null && String(v) !== '') return String(v);
                }
              } catch (e1) {}
              try {
                if (typeof source !== 'undefined' && source) {
                  if (typeof source.get === 'function') {
                    var s = source.get(k);
                    if (s !== undefined && s !== null && String(s) !== '') return String(s);
                  }
                  if (typeof source.getVariable === 'function') {
                    var sv = source.getVariable(k);
                    if (sv !== undefined && sv !== null && String(sv) !== '') return String(sv);
                  }
                }
              } catch (e2) {}
              return '';
            }
            var args = Array.prototype.slice.call(arguments);
            if (typeof Reflect !== 'undefined' && Reflect.construct) {
              return Reflect.construct(ES6Map, args, LegadoMap);
            }
            args.unshift(null);
            return new (Function.prototype.bind.apply(ES6Map, args))();
          }
          LegadoMap.prototype = ES6Map.prototype;
          try { Object.setPrototypeOf(LegadoMap, ES6Map); } catch (e3) {}
          try { Object.defineProperty(LegadoMap, 'name', { value: 'Map' }); } catch (e4) {}
          LegadoMap.__legadoWrapped = true;
          LegadoMap.__legadoLookup = true;
          g.Map = LegadoMap;
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
        installRhinoThisProxy(into: jsContext)
        _ = ObjCExceptionCatch.evaluateScript(rhinoCompatThisBinding(script), in: jsContext, error: &objcError)
        jsContext.exceptionHandler = previous
        if let objcError {
            DebugLogger.shared.log("[jsLib] objc \(objcError)")
        }
        if let jsError, !jsError.isEmpty {
            DebugLogger.shared.log("[jsLib] \(jsError)")
        }
    }

    /// Rhino 兼容：自由函数里 `const {java}=this` 在 JSC 下 this 常为 undefined。
    /// 调用方须先 `installRhinoThisProxy(into:)`；再把 `} = this` 改成 `} = __legadoRhinoThis`。
    static func rhinoCompatThisBinding(_ script: String) -> String {
        guard script.contains("this") else { return script }
        guard let re = try? NSRegularExpression(
            pattern: #"(\})\s*=\s*this\b"#,
            options: []
        ) else { return script }
        let range = NSRange(script.startIndex..<script.endIndex, in: script)
        return re.stringByReplacingMatches(
            in: script,
            options: [],
            range: range,
            withTemplate: "$1 = __legadoRhinoThis"
        )
    }

    /// 安装解构用代理：快照当前全局的 java/source/cookie/result/baseUrl。
    /// 禁止用 getter `return java`（会与同名属性递归）。
    static func installRhinoThisProxy(into jsContext: JSContext) {
        _ = ObjCExceptionCatch.evaluateScript("""
        var __legadoRhinoThis = {
          java: (typeof java !== 'undefined' ? java : undefined),
          source: (typeof source !== 'undefined' ? source : undefined),
          cookie: (typeof cookie !== 'undefined' ? cookie : undefined),
          result: (typeof result !== 'undefined' ? result : undefined),
          baseUrl: (typeof baseUrl !== 'undefined' ? baseUrl : undefined)
        };
        """, in: jsContext, error: nil)
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
            let body = self.ajaxViaAnalyzeUrl(url)
            // 登录探针：落盘 URL 前缀 + 响应前缀，便于区分 POST 失败 / 业务 code
            if url.contains("/login") || url.contains("method") {
                let path = (NSHomeDirectory() as NSString)
                    .appendingPathComponent("Documents/legado_login_ajax_probe.txt")
                let line = "ts=\(ISO8601DateFormatter().string(from: Date())) url=\(url.prefix(180)) bodyLen=\(body.count) bodyPrefix=\(body.prefix(240))\n"
                if let data = line.data(using: .utf8) {
                    if FileManager.default.fileExists(atPath: path),
                       let fh = FileHandle(forWritingAtPath: path) {
                        fh.seekToEndOfFile(); fh.write(data); try? fh.close()
                    } else {
                        try? data.write(to: URL(fileURLWithPath: path))
                    }
                }
            }
            return body
        }
        javaObject?.setObject(ajaxBlock, forKeyedSubscript: "ajax" as NSString)

        // 对标 Android java.ajaxAll：并行拉 URL 列表，返回带 body()/url() 的响应对象数组
        let ajaxAllBlock: @convention(block) (JSValue?) -> JSValue = { [weak self, weak jsContext] urlsVal in
            guard let jsContext else {
                return JSValue(newArrayIn: JSContext())!
            }
            let out = JSValue(newArrayIn: jsContext)!
            guard let self, let urlsVal, !urlsVal.isUndefined, !urlsVal.isNull else {
                out.setValue(0, forKey: "length")
                return out
            }
            var urls: [String] = []
            if urlsVal.isArray, let arr = urlsVal.toArray() {
                urls = arr.compactMap { item -> String? in
                    if let s = item as? String, !s.isEmpty { return s }
                    return nil
                }
            } else if let lenVal = urlsVal.objectForKeyedSubscript("length" as NSString),
                      lenVal.isNumber,
                      let len = lenVal.toNumber()?.intValue,
                      len > 0 {
                for i in 0..<min(len, 50) {
                    if let item = urlsVal.objectAtIndexedSubscript(i),
                       let s = item.toString(), !s.isEmpty, s != "undefined", s != "null" {
                        urls.append(s)
                    }
                }
            }
            let pairs = self.ajaxAllViaAnalyzeUrl(urls)
            for (idx, pair) in pairs.enumerated() {
                let obj = JSValue(newObjectIn: jsContext)!
                let bodyStr = pair.body
                let urlStr = pair.url
                let bodyFn: @convention(block) () -> String = { bodyStr }
                let urlFn: @convention(block) () -> String = { urlStr }
                obj.setObject(bodyFn, forKeyedSubscript: "body" as NSString)
                obj.setObject(urlFn, forKeyedSubscript: "url" as NSString)
                out.setObject(obj, atIndexedSubscript: idx)
            }
            out.setValue(pairs.count, forKey: "length")
            return out
        }
        javaObject?.setObject(ajaxAllBlock, forKeyedSubscript: "ajaxAll" as NSString)

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
            let emptyText: @convention(block) () -> String = { "" }
            empty.setObject(emptyText, forKeyedSubscript: "text" as NSString)
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
            // 返回带 length / text() 的类数组（Android Elements.text()）
            let arr = JSValue(newArrayIn: jsContext)!
            var joinedText = ""
            for (idx, el) in elements.enumerated() {
                if let soup = el.element as? Element {
                    let outer = (try? soup.outerHtml()) ?? ""
                    arr.setObject(outer, atIndexedSubscript: idx)
                    let t = (try? soup.text()) ?? ""
                    if !t.isEmpty {
                        joinedText += (joinedText.isEmpty ? "" : " ") + t
                    }
                } else if let s = el.element as? String {
                    arr.setObject(s, atIndexedSubscript: idx)
                    if s.contains("<"), let frag = try? SwiftSoup.parseBodyFragment(s).body() {
                        let t = (try? frag.text()) ?? ""
                        if !t.isEmpty {
                            joinedText += (joinedText.isEmpty ? "" : " ") + t
                        }
                    } else if !s.isEmpty {
                        joinedText += (joinedText.isEmpty ? "" : " ") + s
                    }
                } else {
                    let desc = String(describing: el.element)
                    arr.setObject(desc, atIndexedSubscript: idx)
                    if !desc.isEmpty {
                        joinedText += (joinedText.isEmpty ? "" : " ") + desc
                    }
                }
            }
            arr.setValue(elements.count, forKey: "length")
            let textCapture = joinedText
            let textFn: @convention(block) () -> String = { textCapture }
            arr.setObject(textFn, forKeyedSubscript: "text" as NSString)
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

        let toastBlock: @convention(block) (String) -> Void = { msg in
            print("[Toast] \(msg)")
            let path = (NSHomeDirectory() as NSString).appendingPathComponent("Documents/legado_js_toast.txt")
            let line = "ts=\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: path),
                   let fh = FileHandle(forWritingAtPath: path) {
                    fh.seekToEndOfFile()
                    fh.write(data)
                    try? fh.close()
                } else {
                    try? data.write(to: URL(fileURLWithPath: path))
                }
            }
        }
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

        // 字符串字段必须挂成真正的 String：block 在 JSC 里是 function，
        // `String(source.loginUrl)` / `eval(source.loginUrl)` 会得到函数源码而非书源字段。
        let src = context?.source
        sourceObject?.setObject((src?.bookSourceUrl ?? "") as NSString, forKeyedSubscript: "bookSourceUrl" as NSString)
        sourceObject?.setObject((src?.bookSourceName ?? "") as NSString, forKeyedSubscript: "bookSourceName" as NSString)
        sourceObject?.setObject((src?.loginUrl ?? "") as NSString, forKeyedSubscript: "loginUrl" as NSString)
        sourceObject?.setObject((src?.header ?? "") as NSString, forKeyedSubscript: "header" as NSString)
        sourceObject?.setObject((src?.variable ?? "") as NSString, forKeyedSubscript: "variable" as NSString)
        sourceObject?.setObject(NSNumber(value: src?.enabledCookieJar == true), forKeyedSubscript: "enabledCookieJar" as NSString)
        sourceObject?.setObject((src?.concurrentRate ?? "") as NSString, forKeyedSubscript: "concurrentRate" as NSString)
        // Android BaseSource.getKey() == bookSourceUrl
        let getKeyBlock: @convention(block) () -> String = { [weak self] in
            self?.context?.source?.bookSourceUrl ?? ""
        }
        sourceObject?.setObject(getKeyBlock, forKeyedSubscript: "getKey" as NSString)
        sourceObject?.setObject(getKeyBlock, forKeyedSubscript: "getTag" as NSString)

        // Android BaseSource.get(key)：登录信息 / 会话变量
        let sourceGetBlock: @convention(block) (String) -> String = { [weak self] key in
            if let local = self?.context?.variables[key], !local.isEmpty { return local }
            let fromSession = SourceSessionStore.get(key, sourceUrl: self?.context?.source?.bookSourceUrl)
            if !fromSession.isEmpty { return fromSession }
            if let variable = self?.context?.source?.variable,
               let data = variable.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let val = json[key] {
                if let s = val as? String { return s }
                return String(describing: val)
            }
            return ""
        }
        sourceObject?.setObject(sourceGetBlock, forKeyedSubscript: "get" as NSString)

        let sourceGetVarBlock: @convention(block) () -> String = { [weak self] in
            // 与 setVariable 对称：先会话/本地，再落盘书源 variable
            if let local = self?.context?.variables["__variable__"], !local.isEmpty {
                return local
            }
            if let url = self?.context?.source?.bookSourceUrl {
                let fromSession = SourceSessionStore.get("__variable__", sourceUrl: url)
                if !fromSession.isEmpty { return fromSession }
            }
            return self?.context?.source?.variable ?? ""
        }
        // 部分源写 source.getVariable() 无参拿整段；部分写 source.getVariable(key)
        sourceObject?.setObject(sourceGetVarBlock, forKeyedSubscript: "getVariable" as NSString)
        let sourceGetVarKeyBlock: @convention(block) (String) -> String = { [weak self] key in
            sourceGetBlock(key)
        }
        // JSC 同名重载不稳：再挂 getVar(key)
        sourceObject?.setObject(sourceGetVarKeyBlock, forKeyedSubscript: "getVar" as NSString)

        let sourceSetVarBlock: @convention(block) (String) -> Void = { [weak self] value in
            // 源级 variable 字符串整写：仅会话侧缓存，避免改磁盘书源
            if let url = self?.context?.source?.bookSourceUrl {
                SourceSessionStore.put("__variable__", value: value, sourceUrl: url)
            }
            self?.context?.variables["__variable__"] = value
        }
        sourceObject?.setObject(sourceSetVarBlock, forKeyedSubscript: "setVariable" as NSString)

        // ====== 登录凭据（对齐 Android BaseSource） ======
        let getLoginInfoBlock: @convention(block) () -> String = { [weak self] in
            LoginCredentialStore.getInfo(sourceUrl: self?.context?.source?.bookSourceUrl ?? "")
        }
        sourceObject?.setObject(getLoginInfoBlock, forKeyedSubscript: "getLoginInfo" as NSString)

        let getLoginInfoMapBlock: @convention(block) () -> NSDictionary = { [weak self] in
            let map = LoginCredentialStore.infoMap(sourceUrl: self?.context?.source?.bookSourceUrl ?? "")
            // JSC 对 Swift Dictionary 桥接偶发丢键；显式 NSMutableDictionary 更稳
            let out = NSMutableDictionary()
            for (k, v) in map {
                out[k] = v
            }
            return out
        }
        sourceObject?.setObject(getLoginInfoMapBlock, forKeyedSubscript: "getLoginInfoMap" as NSString)

        let putLoginInfoBlock: @convention(block) (String) -> Void = { [weak self] json in
            guard let url = self?.context?.source?.bookSourceUrl, !url.isEmpty else { return }
            LoginCredentialStore.putInfo(json, sourceUrl: url)
        }
        sourceObject?.setObject(putLoginInfoBlock, forKeyedSubscript: "putLoginInfo" as NSString)

        let removeLoginInfoBlock: @convention(block) () -> Void = { [weak self] in
            LoginCredentialStore.removeInfo(sourceUrl: self?.context?.source?.bookSourceUrl ?? "")
        }
        sourceObject?.setObject(removeLoginInfoBlock, forKeyedSubscript: "removeLoginInfo" as NSString)

        let getLoginHeaderBlock: @convention(block) () -> String = { [weak self] in
            LoginCredentialStore.getHeader(sourceUrl: self?.context?.source?.bookSourceUrl ?? "")
        }
        sourceObject?.setObject(getLoginHeaderBlock, forKeyedSubscript: "getLoginHeader" as NSString)

        let getLoginHeaderMapBlock: @convention(block) () -> NSDictionary = { [weak self] in
            let raw = LoginCredentialStore.getHeader(sourceUrl: self?.context?.source?.bookSourceUrl ?? "")
            guard let data = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return NSDictionary()
            }
            var out: [String: String] = [:]
            for (k, v) in obj { out[k] = "\(v)" }
            return out as NSDictionary
        }
        sourceObject?.setObject(getLoginHeaderMapBlock, forKeyedSubscript: "getLoginHeaderMap" as NSString)

        let putLoginHeaderBlock: @convention(block) (String) -> Void = { [weak self] json in
            guard let url = self?.context?.source?.bookSourceUrl, !url.isEmpty else { return }
            LoginCredentialStore.putHeader(json, sourceUrl: url)
            // Cookie 字段写入 CookieManager（书山等）
            if let data = json.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let cookie = obj["Cookie"] as? String ?? obj["cookie"] as? String,
               !cookie.isEmpty {
                CookieManager.shared.saveCookie(url: url, cookieString: cookie)
            }
        }
        sourceObject?.setObject(putLoginHeaderBlock, forKeyedSubscript: "putLoginHeader" as NSString)

        let removeLoginHeaderBlock: @convention(block) () -> Void = { [weak self] in
            LoginCredentialStore.removeHeader(sourceUrl: self?.context?.source?.bookSourceUrl ?? "")
        }
        sourceObject?.setObject(removeLoginHeaderBlock, forKeyedSubscript: "removeLoginHeader" as NSString)

        let sourceLoginBlock: @convention(block) () -> String = { [weak self] in
            guard let source = self?.context?.source else { return "无书源" }
            return LoginUiExecutor.run(
                source: source,
                action: "login()",
                formJSON: LoginCredentialStore.getInfo(sourceUrl: source.bookSourceUrl),
                putInfoBeforeEval: false
            )
        }
        sourceObject?.setObject(sourceLoginBlock, forKeyedSubscript: "login" as NSString)

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

    /// 解析书源常用的 cookie 查询串：裸域名 / 完整 URL / CookieManager key
    private static func lookupCookieHeader(for tag: String) -> String {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        var keys: [String] = [trimmed]
        if let asURL = URL(string: trimmed), let host = asURL.host, !host.isEmpty {
            keys.append(host)
        } else if !trimmed.contains("://") {
            keys.append("https://\(trimmed)")
            keys.append("http://\(trimmed)")
            if !trimmed.hasPrefix("www.") {
                keys.append("www.\(trimmed)")
                keys.append("https://www.\(trimmed)")
            }
        }
        // 去重保序
        var seen = Set<String>()
        let uniqueKeys = keys.filter { seen.insert($0).inserted }

        for key in uniqueKeys {
            if let c = CookieManager.shared.getCookie(for: key), !c.isEmpty {
                return c
            }
        }

        // HTTPCookieStorage：裸域名补 https://
        let urlCandidates: [URL] = uniqueKeys.compactMap { key in
            if let u = URL(string: key), u.host != nil { return u }
            if !key.contains("://") { return URL(string: "https://\(key)") }
            return nil
        }
        for u in urlCandidates {
            if let cookies = HTTPCookieStorage.shared.cookies(for: u), !cookies.isEmpty {
                return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            }
        }
        return ""
    }

    private func injectCookieObject(into jsContext: JSContext) {
        let cookieObject = JSValue(newObjectIn: jsContext)

        // Android CookieStore.getCookie(url)：书山等写 cookie.getCookie('fanqienovel.com')
        let getCookieBlock: @convention(block) (String) -> String = { tag in
            Self.lookupCookieHeader(for: tag)
        }

        let getCookieKeyBlock: @convention(block) (String, String) -> String = { tag, key in
            let cookie = Self.lookupCookieHeader(for: tag)
            for pair in cookie.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 && parts[0] == key { return parts[1] }
            }
            return ""
        }

        let setCookieBlock: @convention(block) (String, String) -> Void = { url, cookie in
            guard !url.isEmpty, !cookie.isEmpty else { return }
            // 同步落盘 CookieManager（裸域名 / URL 都能取）
            let key: String
            if let host = URL(string: url)?.host, !host.isEmpty {
                key = host
            } else if !url.contains("://") {
                key = url
            } else {
                key = url
            }
            let existing = CookieManager.shared.getCookie(for: key) ?? ""
            CookieManager.shared.saveCookie(
                url: key,
                cookieString: CookieManager.shared.mergeCookies(existing, cookie)
            )
            let cookieURL = URL(string: url)
                ?? URL(string: url.contains("://") ? url : "https://\(url)")
            guard let cookieURL else { return }
            let parsed = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": cookie], for: cookieURL)
            if parsed.isEmpty {
                if let simple = Self.makeSimpleCookie(cookie, for: cookieURL) {
                    HTTPCookieStorage.shared.setCookie(simple)
                }
            } else {
                for item in parsed { HTTPCookieStorage.shared.setCookie(item) }
            }
        }

        let removeCookieBlock: @convention(block) (String) -> Void = { url in
            CookieManager.shared.removeCookie(for: url)
            if let host = URL(string: url)?.host {
                CookieManager.shared.removeCookie(for: host)
            } else if !url.contains("://") {
                CookieManager.shared.removeCookie(for: url)
            }
            let cookieURL = URL(string: url)
                ?? URL(string: url.contains("://") ? url : "https://\(url)")
            guard let cookieURL,
                  let cookies = HTTPCookieStorage.shared.cookies(for: cookieURL) else { return }
            for item in cookies { HTTPCookieStorage.shared.deleteCookie(item) }
        }

        cookieObject?.setObject(getCookieBlock, forKeyedSubscript: "get" as NSString)
        // 书山 getSessionId / fq_login：cookie.getCookie(domain)
        cookieObject?.setObject(getCookieBlock, forKeyedSubscript: "getCookie" as NSString)
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
        // 直接用同一次 AnalyzeUrl 发请求，避免 analyze→AnalyzedUrl→再 init 丢失 encodedForm
        let analyzer = AnalyzeUrl(
            mUrl: url,
            baseUrl: base,
            source: source
        )
        // 探针：确认 POST/body/encodedForm 是否解析成功
        do {
            let path = (NSHomeDirectory() as NSString)
                .appendingPathComponent("Documents/legado_login_ajax_probe.txt")
            let line = "ts=\(ISO8601DateFormatter().string(from: Date())) analyze method=\(analyzer.method) bodyLen=\(analyzer.body?.count ?? -1) formLen=\(analyzer.encodedForm?.count ?? -1) url=\(analyzer.url.prefix(100)) ctHeader=\(analyzer.headerMap["Content-Type"] ?? "-")\n"
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: path),
                   let fh = FileHandle(forWritingAtPath: path) {
                    fh.seekToEndOfFile(); fh.write(data); try? fh.close()
                } else {
                    try? data.write(to: URL(fileURLWithPath: path))
                }
            }
        }
        let semaphore = DispatchSemaphore(value: 0)
        let box = AjaxBodyBox()
        Task {
            do {
                let resp = try await analyzer.getStrResponseAwait(
                    jsStr: nil,
                    sourceRegex: nil,
                    useWebView: false
                )
                box.value = resp.body ?? ""
            } catch {
                DebugLogger.shared.log("[JS.ajax] \(error)")
                box.value = ""
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 30)
        return box.value
    }

    /// 对标 Android `java.ajaxAll`：并行请求，返回 (最终 URL, body)
    private func ajaxAllViaAnalyzeUrl(_ urls: [String]) -> [(url: String, body: String)] {
        guard !urls.isEmpty else { return [] }
        let source = context?.source
        let base = context?.baseURL?.absoluteString ?? source?.bookSourceUrl ?? ""
        let box = AjaxAllBox()
        let group = DispatchGroup()
        for (idx, url) in urls.enumerated() {
            group.enter()
            Task {
                defer { group.leave() }
                let analyzed = AnalyzeUrl.analyze(ruleUrl: url, baseUrl: base, source: source)
                do {
                    let (respBody, finalUrl) = try await AnalyzeUrl.getResponseBody(
                        analyzedUrl: analyzed,
                        source: source
                    )
                    box.append(idx: idx, url: finalUrl.isEmpty ? url : finalUrl, body: respBody)
                } catch {
                    DebugLogger.shared.log("[JS.ajaxAll] \(error)")
                    box.append(idx: idx, url: url, body: "")
                }
            }
        }
        // 每 URL 约 30s，最多约 10 本；给足并行预算
        _ = group.wait(timeout: .now() + 90)
        return box.sortedPairs()
    }

    private final class AjaxBodyBox: @unchecked Sendable {
        var value = ""
    }

    private final class AjaxAllBox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(Int, String, String)] = []

        func append(idx: Int, url: String, body: String) {
            lock.lock()
            items.append((idx, url, body))
            lock.unlock()
        }

        func sortedPairs() -> [(url: String, body: String)] {
            lock.lock()
            defer { lock.unlock() }
            return items.sorted { $0.0 < $1.0 }.map { (url: $0.1, body: $0.2) }
        }
    }

    /// `org.jsoup.Jsoup.parse(html).select(css).text()` / `.attr(name)`（SwiftSoup 代理）
    private func injectOrgJsoup(into jsContext: JSContext) {
        let jsoup = JSValue(newObjectIn: jsContext)!
        let parseBlock: @convention(block) (String) -> JSValue = { [weak jsContext] html in
            guard let jsContext else {
                return JSValue(nullIn: JSContext())!
            }
            let docObj = JSValue(newObjectIn: jsContext)!
            let parsed = try? SwiftSoup.parse(html)
            let selectBlock: @convention(block) (String) -> JSValue = { [weak jsContext] css in
                guard let jsContext else {
                    return JSValue(nullIn: JSContext())!
                }
                let elsObj = JSValue(newObjectIn: jsContext)!
                let selected = try? parsed?.select(css)
                let textFn: @convention(block) () -> String = {
                    (try? selected?.text()) ?? ""
                }
                let attrFn: @convention(block) (String) -> String = { name in
                    (try? selected?.attr(name)) ?? ""
                }
                let htmlFn: @convention(block) () -> String = {
                    (try? selected?.html()) ?? ""
                }
                let outerFn: @convention(block) () -> String = {
                    (try? selected?.outerHtml()) ?? ""
                }
                elsObj.setObject(textFn, forKeyedSubscript: "text" as NSString)
                elsObj.setObject(attrFn, forKeyedSubscript: "attr" as NSString)
                elsObj.setObject(htmlFn, forKeyedSubscript: "html" as NSString)
                elsObj.setObject(outerFn, forKeyedSubscript: "outerHtml" as NSString)
                elsObj.setValue(selected?.array().count ?? 0, forKey: "length")
                return elsObj
            }
            docObj.setObject(selectBlock, forKeyedSubscript: "select" as NSString)
            return docObj
        }
        jsoup.setObject(parseBlock, forKeyedSubscript: "parse" as NSString)
        let org = JSValue(newObjectIn: jsContext)!
        let jsoupNs = JSValue(newObjectIn: jsContext)!
        jsoupNs.setObject(jsoup, forKeyedSubscript: "Jsoup" as NSString)
        org.setObject(jsoupNs, forKeyedSubscript: "jsoup" as NSString)
        Self.bindGlobal(org, name: "org", into: jsContext)
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