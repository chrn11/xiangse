import Foundation
import SwiftSoup

/// HTML 正文格式化 — 对齐 Android HtmlFormatter.formatKeepImg
public enum HTMLToTextConverter {

    public static func convert(html: String, baseURL: URL? = nil) -> String {
        do {
            let doc = try SwiftSoup.parse(html)
            try doc.select("script, style, nav, header, footer").remove()

            let blockElements = ["p", "div", "br", "h1", "h2", "h3", "h4", "h5", "h6", "li", "tr"]
            for tag in blockElements {
                for element in try doc.select(tag).array() {
                    try element.after("\n")
                }
            }

            var text = try doc.text()
            text = text.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
            text = text.replacingOccurrences(of: "\n[ \t]+", with: "\n", options: .regularExpression)
            text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return extractTextSimple(html: html)
        }
    }

    /// 保留 `<img>` 并绝对化 URL，供正文内联图片
    public static func formatKeepImg(html: String, baseURL: URL? = nil) -> String {
        guard !html.isEmpty else { return "" }

        var result = html
        result = result.replacingOccurrences(of: "(&nbsp;)+", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: "(&ensp;|&emsp;)", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(
            of: "(&thinsp;|&zwnj;|&zwj;|\u{2009}|\u{200C}|\u{200D})",
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "</?(?:div|p|br|hr|h\\d|article|dd|dl)[^>]*>",
            with: "\n",
            options: .regularExpression
        )
        result = result.replacingOccurrences(of: "<!--[^>]*-->", with: "", options: .regularExpression)

        let imgPattern = #"<img[^>]*\ssrc\s*=\s*['"]([^'"{>]*\{(?:[^{}]|\{[^}>]+\})+\})['"][^>]*>|<img[^>]*\s(?:data-src|src)\s*=\s*['"]([^'">]+)['"][^>]*>|<img[^>]*\sdata-[^=>]*=\s*['"]([^'">]*)['"][^>]*>"#

        guard let imgRegex = try? NSRegularExpression(pattern: imgPattern, options: [.caseInsensitive]) else {
            return result
        }

        let range = NSRange(result.startIndex..., in: result)
        let matches = imgRegex.matches(in: result, options: [], range: range)

        var processedHTML = ""
        var lastEnd = result.startIndex

        for match in matches {
            processedHTML += String(result[lastEnd..<result.index(result.startIndex, offsetBy: match.range.lowerBound)])

            var imgURL: String?
            var param = ""

            if let group1Range = Range(match.range(at: 1), in: result) {
                let templateURL = String(result[group1Range])
                if let paramMatch = templateURL.range(of: #"\?.*$"#, options: .regularExpression) {
                    param = String(templateURL[paramMatch])
                    imgURL = String(templateURL[templateURL.startIndex..<paramMatch.lowerBound])
                } else {
                    imgURL = templateURL
                }
            } else if let group2Range = Range(match.range(at: 2), in: result) {
                imgURL = String(result[group2Range])
            } else if let group3Range = Range(match.range(at: 3), in: result) {
                imgURL = String(result[group3Range])
            }

            if let imgURL, !imgURL.isEmpty {
                processedHTML += "<img src=\"\(absoluteURL(baseURL: baseURL, relativeURL: imgURL) + param)\">"
            }

            lastEnd = result.index(result.startIndex, offsetBy: match.range.upperBound)
        }

        processedHTML += String(result[lastEnd...])
        processedHTML = processedHTML.replacingOccurrences(
            of: #"</?(?!img)[a-zA-Z]+(?=[ >])[^<>]*>"#,
            with: "",
            options: .regularExpression
        )
        processedHTML = processedHTML.replacingOccurrences(of: "\\s*\\n+\\s*", with: "\n　　", options: .regularExpression)
        processedHTML = processedHTML.replacingOccurrences(of: "^[\\n\\s]+", with: "　　", options: .regularExpression)
        processedHTML = processedHTML.replacingOccurrences(of: "[\\n\\s]+$", with: "", options: .regularExpression)
        return processedHTML
    }

    /// GBK/乱码 HTML 修复夹具入口（不依赖无源码 binary）
    public static func repairEncoding(_ data: Data, hintedCharset: String? = nil) -> String {
        if let hinted = hintedCharset?.lowercased() {
            if let encoding = charsetEncoding(hinted), let text = String(data: data, encoding: encoding) {
                return text
            }
        }
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        let gbk = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        if let text = String(data: data, encoding: gbk) { return text }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    private static func absoluteURL(baseURL: URL?, relativeURL: String) -> String {
        guard let baseURL else { return relativeURL }
        if relativeURL.hasPrefix("http://") || relativeURL.hasPrefix("https://") { return relativeURL }
        return URL(string: relativeURL, relativeTo: baseURL)?.absoluteString ?? relativeURL
    }

    private static func charsetEncoding(_ name: String) -> String.Encoding? {
        switch name {
        case "utf-8", "utf8": return .utf8
        case "gbk", "gb2312", "gb18030":
            return String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
                )
            )
        case "big5":
            return String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.big5.rawValue)
                )
            )
        case "iso-8859-1", "latin1": return .isoLatin1
        default: return nil
        }
    }

    private static func extractTextSimple(html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: "(?s)<script[^>]*>.*?</script>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?s)<style[^>]*>.*?</style>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
