import CryptoKit
import Foundation

/// TC-10：诊断输出脱敏。仅接受枚举字段输入，禁止透传任意 object description。
public enum BridgeDiagnosticField: String, CaseIterable, Sendable {
    case sourceUrlHash
    case sourceNameHash
    case bookTitleHash
    case bookAuthorHash
    case containerPathHash
    case chapterIndex
    case chapterTitleHash
    case requestHostHash
    case requestQueryKeyCount
    case cookieByteCount
    case authPresent
    case tokenPresent
    case generation
    case errorDomain
    case errorCode
}

/// 结构化诊断输入（非任意字符串）。
public enum BridgeDiagnosticInput: Sendable, Equatable {
    case source(url: String, name: String?)
    case book(title: String, author: String?, containerPath: String?)
    case chapter(index: Int, title: String?)
    case request(url: String, query: [String: String], cookie: String?, authHeader: String?)
    case error(domain: String, code: Int, description: String)
    case generation(UInt64)
}

public struct BridgeDiagnosticRedactedLine: Equatable, Sendable {
    public var fields: [BridgeDiagnosticField: String]

    public init(fields: [BridgeDiagnosticField: String]) {
        self.fields = fields
    }

    /// 单行短 hash 日志（Debug 可用）；不含明文 URL / 书名 / token。
    public func compactLine(tag: String) -> String {
        let body = BridgeDiagnosticField.allCases.compactMap { key -> String? in
            guard let v = fields[key] else { return nil }
            return "\(key.rawValue)=\(v)"
        }.joined(separator: " ")
        return "\(tag) \(body)\n"
    }
}

public enum BridgeDiagnosticRedactor {
    private static let salt = "legado-bridge-diag-v1"

    public static func redact(_ input: BridgeDiagnosticInput) -> BridgeDiagnosticRedactedLine {
        switch input {
        case let .source(url, name):
            var f: [BridgeDiagnosticField: String] = [
                .sourceUrlHash: saltedHash(url),
            ]
            if let name, !name.isEmpty {
                f[.sourceNameHash] = saltedHash(name)
            }
            return BridgeDiagnosticRedactedLine(fields: f)

        case let .book(title, author, containerPath):
            var f: [BridgeDiagnosticField: String] = [
                .bookTitleHash: saltedHash(title),
            ]
            if let author, !author.isEmpty {
                f[.bookAuthorHash] = saltedHash(author)
            }
            if let containerPath, !containerPath.isEmpty {
                f[.containerPathHash] = saltedHash(containerPath)
            }
            return BridgeDiagnosticRedactedLine(fields: f)

        case let .chapter(index, title):
            var f: [BridgeDiagnosticField: String] = [
                .chapterIndex: String(index),
            ]
            if let title, !title.isEmpty {
                f[.chapterTitleHash] = saltedHash(title)
            }
            return BridgeDiagnosticRedactedLine(fields: f)

        case let .request(url, query, cookie, authHeader):
            let host = URL(string: url)?.host ?? url
            var f: [BridgeDiagnosticField: String] = [
                .requestHostHash: saltedHash(host),
                .requestQueryKeyCount: String(query.keys.count),
            ]
            if let cookie, !cookie.isEmpty {
                f[.cookieByteCount] = String(cookie.utf8.count)
                f[.tokenPresent] = containsSensitiveToken(cookie) ? "1" : "0"
            }
            if let authHeader, !authHeader.isEmpty {
                f[.authPresent] = "1"
            }
            return BridgeDiagnosticRedactedLine(fields: f)

        case let .error(domain, code, _):
            return BridgeDiagnosticRedactedLine(fields: [
                .errorDomain: domain,
                .errorCode: String(code),
            ])

        case let .generation(g):
            return BridgeDiagnosticRedactedLine(fields: [
                .generation: String(g),
            ])
        }
    }

    /// 断言 redacted 文本不含敏感子串（单测用）。
    public static func containsLeak(_ text: String, forbidden: [String]) -> [String] {
        forbidden.filter { needle in
            !needle.isEmpty && text.localizedCaseInsensitiveContains(needle)
        }
    }

    private static func saltedHash(_ raw: String) -> String {
        let payload = Data((salt + "\0" + raw).utf8)
        let digest = SHA256.hash(data: payload)
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func containsSensitiveToken(_ cookie: String) -> Bool {
        let lower = cookie.lowercased()
        return lower.contains("sessionid")
            || lower.contains("token")
            || lower.contains("auth")
            || lower.contains("key=")
    }
}
