import Foundation

/// hook103 语义参考夹具 — 仅用系统/开源能力复现，不复制无源码 dylib
public enum CompatibilityFixtures {

    // MARK: - AES（对齐阅读 java.aes* / SymmetricCrypto 语义）

    public static func aesEncryptBase64(
        plain: String,
        key: String,
        transformation: String = "AES/CBC/PKCS5Padding",
        iv: String
    ) -> String? {
        SymmetricCrypto(transformation: transformation, key: key, iv: iv).encryptBase64(plain)
    }

    public static func aesDecryptBase64(
        cipherBase64: String,
        key: String,
        transformation: String = "AES/CBC/PKCS5Padding",
        iv: String
    ) -> String? {
        SymmetricCrypto(transformation: transformation, key: key, iv: iv).decryptStr(cipherBase64)
    }

    // MARK: - 解压识别（gzip/deflate；RAR 明确返回不支持）

    public enum CompressionKind: String, Equatable {
        case gzip
        case deflate
        case zlib
        case rar
        case unknown
    }

    public static func detectCompression(of data: Data) -> CompressionKind {
        guard data.count >= 2 else { return .unknown }
        let b0 = data[0], b1 = data[1]
        if b0 == 0x1f && b1 == 0x8b { return .gzip }
        if b0 == 0x78 && (b1 == 0x01 || b1 == 0x9c || b1 == 0xda) { return .zlib }
        if data.count >= 4,
           data[0] == 0x52, data[1] == 0x61, data[2] == 0x72, data[3] == 0x21 {
            return .rar
        }
        return .unknown
    }

    public static func decompress(_ data: Data) throws -> Data {
        switch detectCompression(of: data) {
        case .gzip:
            return try data.gunzipped()
        case .zlib, .deflate:
            return try data.inflateData()
        case .rar:
            throw RuleCapabilityError.ruleGap(
                feature: "rar_decompress",
                detail: "首版不内置密码 RAR；参考 hook103 但不复制无源码实现"
            )
        case .unknown:
            throw RuleCapabilityError.ruleGap(feature: "decompress", detail: "无法识别压缩格式")
        }
    }

    // MARK: - HTML 编码修复

    public static func repairHTMLEncoding(_ data: Data, charset: String? = nil) -> String {
        HTMLToTextConverter.repairEncoding(data, hintedCharset: charset)
    }

    // MARK: - 换源章节匹配（纯逻辑夹具）

    public static func matchChapter(
        currentTitle: String?,
        currentIndex: Int?,
        chapters: [BridgeChapter],
        minimumScore: Double = 0.55
    ) -> ChapterMatchResult? {
        ChapterMatcher.match(
            currentTitle: currentTitle,
            currentIndex: currentIndex,
            chapters: chapters,
            minimumScore: minimumScore
        )
    }

    // MARK: - 替换净化（无 CoreData）

    public static func purifyContent(_ text: String, rules: [ReplaceRuleItem]) -> String {
        ReplaceEngine.purify(content: text, items: rules)
    }

    // MARK: - 协议外能力拒绝

    public static func assertAllowedJSAPI(_ name: String) throws {
        let forbidden = [
            "keychain", "SecItem", "xiangsePrivateFile", "NSFileManager",
            "UIPasteboard", "LAContext", "LocalAuthentication"
        ]
        if forbidden.contains(where: { name.localizedCaseInsensitiveContains($0) }) {
            throw RuleCapabilityError.nativeCapabilityForbidden(name: name)
        }
    }
}
