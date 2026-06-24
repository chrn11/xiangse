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

// MARK: - JSBridge 主类

/// JS 桥接类 - 对应 Android JsExtensions interface 实现
class JSBridge: JsEncodeUtils {

    weak var context: ExecutionContext?
    weak var ruleEngine: RuleEngine?

    /// 注入所有桥接对象到 JSContext
    func inject(into jsContext: JSContext) {
        injectJavaObject(into: jsContext)
        injectSourceObject(into: jsContext)
        injectCookieObject(into: jsContext)
        injectCacheObject(into: jsContext)
    }

    // MARK: - java 对象注入

    private func injectJavaObject(into jsContext: JSContext) {
        let javaObject = JSValue(newObjectIn: jsContext)

        // ====== 网络函数 ======

        let ajaxBlock: @convention(block) (String) -> String = { [weak self] url in
            guard let self = self, !url.isEmpty else { return "" }
            let headers = self.parseSourceHeaders()
            return JSBridgeHTTPClient.syncGet(url: url, headers: headers) ?? ""
        }
        javaObject?.setObject(ajaxBlock, forKeyedSubscript: "ajax" as NSString)

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

        let putBlock: @convention(block) (String, String) -> String = { [weak self] key, value in
            self?.context?.variables[key] = value; return value
        }
        javaObject?.setObject(putBlock, forKeyedSubscript: "put" as NSString)

        let getBlock: @convention(block) (String) -> String = { [weak self] key in
            self?.context?.variables[key] ?? ""
        }
        javaObject?.setObject(getBlock, forKeyedSubscript: "get" as NSString)

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

        jsContext.setValue(javaObject, forKey: "java")
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

        jsContext.setValue(sourceObject, forKey: "source")
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
        }

        cookieObject?.setObject(getCookieBlock, forKeyedSubscript: "get" as NSString)
        cookieObject?.setObject(getCookieKeyBlock, forKeyedSubscript: "getKey" as NSString)
        cookieObject?.setObject(setCookieBlock, forKeyedSubscript: "set" as NSString)
        cookieObject?.setObject(removeCookieBlock, forKeyedSubscript: "remove" as NSString)

        jsContext.setValue(cookieObject, forKey: "cookie")
    }

    // MARK: - cache 对象注入

    private func injectCacheObject(into jsContext: JSContext) {
        let cacheObject = JSValue(newObjectIn: jsContext)

        cacheObject?.setObject({ (key: String) -> String in CacheStore.get(key) ?? "" }, forKeyedSubscript: "get" as NSString)
        cacheObject?.setObject({ (key: String, value: String) -> Void in CacheStore.put(key, value: value) }, forKeyedSubscript: "put" as NSString)
        cacheObject?.setObject({ (key: String) -> String in CacheStore.get(key) ?? "" }, forKeyedSubscript: "getFromMemory" as NSString)

        jsContext.setValue(cacheObject, forKey: "cache")
    }

    // MARK: - 辅助方法

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

class JSBridgeHTTPClient {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    static func syncGet(url: String, headers: [String: String]?) -> String? {
        guard let request = makeRequest(url: url, headers: headers) else { return nil }
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
        guard let request = makeRequest(url: url, headers: headers) else { completion(nil); return }
        session.dataTask(with: request) { data, response, error in
            if error != nil { completion(nil); return }
            guard let data else { completion(nil); return }
            if let resp = response as? HTTPURLResponse, !(200..<300).contains(resp.statusCode) { completion(nil); return }
            completion(decode(data: data, response: response))
        }.resume()
    }

    private static func makeRequest(url: String, headers: [String: String]?) -> URLRequest? {
        guard let targetURL = URL(string: url) else { return nil }
        var request = URLRequest(url: targetURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.5 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        headers?.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
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