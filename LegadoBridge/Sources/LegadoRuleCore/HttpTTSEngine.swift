//
//  HttpTTSEngine.swift
//  LegadoRuleCore
//
//  HttpTTS：模板替换 + 拉取音频 Data；直链识别。
//

import Foundation

public enum HttpTTSEngine {
    /// 常见音频扩展 / content 嗅探前缀
    private static let audioExtensions = ["mp3", "m4a", "aac", "wav", "ogg", "flac", "mp4"]

    public static func isAudioURL(_ url: String) -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") || trimmed.hasPrefix("file://") else {
            return false
        }
        if let path = URL(string: trimmed)?.path.lowercased() {
            for ext in audioExtensions {
                if path.hasSuffix(".\(ext)") { return true }
            }
        }
        // 查询串含 format=mp3 等
        if trimmed.contains("format=mp3") || trimmed.contains("type=audio") { return true }
        return false
    }

    /// 将配置 URL 中的 {{speakText}} / {{text}} / {{speakVoice}} 等替换为编码后文本
    public static func buildRequestURL(config: HttpTTSConfig, speakText: String, speakVoice: String = "") -> String {
        var template = config.url
        let encoded = speakText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? speakText
        let voiceEnc = speakVoice.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? speakVoice
        let replacements: [String: String] = [
            "{{speakText}}": encoded,
            "{{text}}": encoded,
            "{{speakVoice}}": voiceEnc,
            "{{voice}}": voiceEnc
        ]
        for (k, v) in replacements {
            template = template.replacingOccurrences(of: k, with: v)
        }
        return template
    }

    public static func parseHeaders(_ headerJSON: String?) -> [String: String] {
        guard let headerJSON,
              let data = headerJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return obj
    }

    /// 同步拉取（夹具/短超时）；失败返回 nil
    public static func fetchAudioData(config: HttpTTSConfig, speakText: String, timeout: TimeInterval = 30) -> Data? {
        let urlString = buildRequestURL(config: config, speakText: speakText)
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        for (k, v) in parseHeaders(config.header) {
            request.setValue(v, forHTTPHeaderField: k)
        }
        if let ct = config.contentType, !ct.isEmpty {
            request.setValue(ct, forHTTPHeaderField: "Content-Type")
        }
        let sem = DispatchSemaphore(value: 0)
        var out: Data?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            out = data
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 1)
        return out
    }

    /// 直链拉取
    public static func fetchAudioData(from urlString: String, timeout: TimeInterval = 30) -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        let sem = DispatchSemaphore(value: 0)
        var out: Data?
        URLSession.shared.dataTask(with: url) { data, _, _ in
            out = data
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 1)
        return out
    }

    /// 与测试/Bridge 命名对齐的别名
    public static func isDirectAudioURL(_ url: String) -> Bool { isAudioURL(url) }

    public static func renderURL(template: String, speakText: String, extras: [String: String] = [:]) -> String {
        var cfg = HttpTTSConfig(url: template)
        var out = buildRequestURL(config: cfg, speakText: speakText, speakVoice: extras["voice"] ?? "")
        for (k, v) in extras where k != "voice" {
            out = out.replacingOccurrences(of: "{{\(k)}}", with: v)
        }
        return out
    }

    /// 从章节 URL 或正文识别直链音频
    public static func resolveDirectAudioURL(chapterUrl: String, content: String?) -> String? {
        if isAudioURL(chapterUrl) { return chapterUrl.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let content, !content.isEmpty else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if isAudioURL(trimmed) { return trimmed }
        let firstLine = trimmed.components(separatedBy: .newlines).first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if isAudioURL(firstLine) { return firstLine }
        return nil
    }

    /// async 拉取 TTS 音频
    public static func fetchAudio(config: HttpTTSConfig, speakText: String) async throws -> Data {
        let urlString = buildRequestURL(config: config, speakText: speakText)
        guard let url = URL(string: urlString) else {
            throw HttpTTSError.invalidURL(urlString)
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        for (k, v) in parseHeaders(config.header) {
            request.setValue(v, forHTTPHeaderField: k)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HttpTTSError.httpStatus(http.statusCode)
        }
        guard !data.isEmpty else { throw HttpTTSError.emptyBody }
        return data
    }
}

public enum HttpTTSError: LocalizedError {
    case invalidURL(String)
    case httpStatus(Int)
    case emptyBody

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let u): return "TTS URL 无效：\(u)"
        case .httpStatus(let c): return "TTS 请求失败 HTTP \(c)"
        case .emptyBody: return "TTS 响应为空"
        }
    }
}
