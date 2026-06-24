//
//  JsEncodeUtils.swift
//  Legado-iOS
//
//  JS 加解密扩展 - 参考原版 JsEncodeUtils.kt（518行）
//  1:1 移植 Android io.legado.app.help.JsEncodeUtils
//  仅使用 Apple 框架：CryptoKit + CommonCrypto + Security.framework
//

import Foundation
import CryptoKit
import CommonCrypto

// MARK: - 对称加密封装

/// 对称加密器 - 对应 Android SymmetricCryptoAndroid + hutool SymmetricCrypto
/// 支持 AES/DES/3DES 各种模式和填充
class SymmetricCrypto {

    let transformation: String
    private let keyData: Data
    private let ivData: Data?
    private let algorithm: CCAlgorithm
    private let options: CCOptions
    private let blockSize: Int

    init(transformation: String, key: Data, iv: Data? = nil) {
        self.transformation = transformation
        self.keyData = key
        self.ivData = iv

        // 解析 transformation 格式：Algorithm/Mode/Padding
        let parts = transformation.split(separator: "/").map { String($0).uppercased() }
        let algo = parts.first ?? "AES"
        let mode = parts.count > 1 ? parts[1] : "ECB"
        let padding = parts.count > 2 ? parts[2] : "PKCS5PADDING"

        switch algo {
        case "AES":
            self.algorithm = CCAlgorithm(kCCAlgorithmAES)
            self.blockSize = kCCBlockSizeAES128
        case "DES":
            self.algorithm = CCAlgorithm(kCCAlgorithmDES)
            self.blockSize = kCCBlockSizeDES
        case "DESEDE", "3DES", "TRIPLEDES":
            self.algorithm = CCAlgorithm(kCCAlgorithm3DES)
            self.blockSize = kCCBlockSize3DES
        default:
            self.algorithm = CCAlgorithm(kCCAlgorithmAES)
            self.blockSize = kCCBlockSizeAES128
        }

        // CCCrypt 模式和填充选项
        var opts: CCOptions = 0
        if mode == "ECB" { opts |= CCOptions(kCCOptionECBMode) }
        if padding.hasPrefix("PKCS") || padding == "NOPADDING" {
            if padding != "NOPADDING" { opts |= CCOptions(kCCOptionPKCS7Padding) }
        }
        self.options = opts
    }

    convenience init(transformation: String, key: String, iv: String? = nil) {
        self.init(
            transformation: transformation,
            key: key.data(using: .utf8) ?? Data(),
            iv: iv?.data(using: .utf8)
        )
    }

    convenience init(transformation: String, key: String, iv: Data?) {
        self.init(
            transformation: transformation,
            key: key.data(using: .utf8) ?? Data(),
            iv: iv
        )
    }

    convenience init(transformation: String, key: Data) {
        self.init(transformation: transformation, key: key, iv: nil)
    }

    /// 设置 IV
    func setIv(_ iv: Data) -> SymmetricCrypto {
        return SymmetricCrypto(transformation: transformation, key: keyData, iv: iv)
    }

    func setIv(_ iv: String) -> SymmetricCrypto {
        return SymmetricCrypto(transformation: transformation, key: keyData, iv: iv.data(using: .utf8))
    }

    // MARK: - 加密

    /// 加密返回 Data（对应 Android encrypt(data: String) -> ByteArray）
    func encrypt(_ data: String) -> Data? {
        guard let inputData = data.data(using: .utf8) else { return nil }
        return crypt(inputData, operation: CCOperation(kCCEncrypt))
    }

    /// 加密返回 Base64 字符串
    func encryptBase64(_ data: String) -> String? {
        guard let encrypted = encrypt(data) else { return nil }
        return encrypted.base64EncodedString()
    }

    /// 加密返回 Hex 字符串
    func encryptHex(_ data: String) -> String? {
        guard let encrypted = encrypt(data) else { return nil }
        return encrypted.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 解密

    /// 解密 Base64/Hex 编码的数据返回 Data
    func decrypt(_ encoded: String) -> Data? {
        // 尝试 Base64 解码
        if let data = Data(base64Encoded: encoded, options: [.ignoreUnknownCharacters]) {
            return crypt(data, operation: CCOperation(kCCDecrypt))
        }
        // 尝试 Hex 解码
        if let data = hexToData(encoded) {
            return crypt(data, operation: CCOperation(kCCDecrypt))
        }
        // 直接当 UTF-8 解密
        if let data = encoded.data(using: .utf8) {
            return crypt(data, operation: CCOperation(kCCDecrypt))
        }
        return nil
    }

    /// 解密返回字符串（对应 Android decryptStr）
    func decryptStr(_ encoded: String) -> String? {
        guard let data = decrypt(encoded) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Core Crypt

    /// CommonCrypto 核心加解密
    private func crypt(_ data: Data, operation: CCOperation) -> Data? {
        let keyBytes = keyData
        var ivBytes: Data?
        if options & CCOptions(kCCOptionECBMode) == 0 {
            ivBytes = ivData ?? Data(repeating: 0, count: blockSize)
        }

        // 密钥长度对齐
        var alignedKey = keyBytes
        let keyLength: Int
        switch algorithm {
        case CCAlgorithm(kCCAlgorithmAES):
            keyLength = [kCCKeySizeAES128, kCCKeySizeAES192, kCCKeySizeAES256].first { $0 <= keyBytes.count } ?? kCCKeySizeAES128
            alignedKey = Data(keyBytes.prefix(keyLength))
        case CCAlgorithm(kCCAlgorithm3DES):
            keyLength = min(keyBytes.count, kCCKeySize3DES)
            alignedKey = Data(keyBytes.prefix(keyLength))
        default:
            keyLength = min(keyBytes.count, kCCKeySizeDES)
            alignedKey = Data(keyBytes.prefix(keyLength))
        }

        let inputBytes = [UInt8](data)
        let inputLength = data.count
        let outputLength = inputLength + blockSize
        var outputBytes = [UInt8](repeating: 0, count: outputLength)
        var numBytesMoved = 0

        let status: CCCryptorStatus
        if options & CCOptions(kCCOptionECBMode) != 0 {
            // ECB 模式不使用 IV
            status = CCCrypt(
                operation, algorithm, options,
                [UInt8](alignedKey), alignedKey.count,
                nil,
                inputBytes, inputLength,
                &outputBytes, outputLength,
                &numBytesMoved
            )
        } else if let iv = ivBytes {
            status = CCCrypt(
                operation, algorithm, options,
                [UInt8](alignedKey), alignedKey.count,
                [UInt8](iv),
                inputBytes, inputLength,
                &outputBytes, outputLength,
                &numBytesMoved
            )
        } else {
            status = CCCrypt(
                operation, algorithm, options,
                [UInt8](alignedKey), alignedKey.count,
                nil,
                inputBytes, inputLength,
                &outputBytes, outputLength,
                &numBytesMoved
            )
        }

        guard status == kCCSuccess else { return nil }
        return Data(bytes: outputBytes, count: numBytesMoved)
    }
}

// MARK: - 非对称加密封装

/// 非对称加密器 - 对应 Android AsymmetricCrypto
/// 使用 Security.framework 实现 RSA
class AsymmetricCrypto {

    let transformation: String
    private var privateKey: SecKey?
    private var publicKey: SecKey?

    init(transformation: String) {
        self.transformation = transformation
        generateKeyPair()
    }

    init(transformation: String, publicKeyData: Data) {
        self.transformation = transformation
        self.publicKey = Self.createPublicKey(from: publicKeyData)
    }

    init(transformation: String, privateKeyData: Data) {
        self.transformation = transformation
        self.privateKey = Self.createPrivateKey(from: privateKeyData)
    }

    /// 生成密钥对
    private func generateKeyPair() {
        let tag = "com.legado.rsakey.\(UUID().uuidString)"
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecAttrApplicationTag as String: tag.data(using: .utf8)!
        ]

        var pubKey: SecKey?
        var privKey: SecKey?
        let status = SecKeyGeneratePair(attributes as CFDictionary, &pubKey, &privKey)
        if status == errSecSuccess {
            publicKey = pubKey
            privateKey = privKey
        }
    }

    /// 加密
    func encrypt(_ data: Data) -> Data? {
        guard let pubKey = publicKey else { return nil }
        var error: Unmanaged<CFError>?
        guard let encrypted = SecKeyCreateEncryptedData(
            pubKey, .rsaEncryptionPKCS1, data as CFData, &error
        ) else { return nil }
        return encrypted as Data
    }

    /// 解密
    func decrypt(_ data: Data) -> Data? {
        guard let privKey = privateKey else { return nil }
        var error: Unmanaged<CFError>?
        guard let decrypted = SecKeyCreateDecryptedData(
            privKey, .rsaEncryptionPKCS1, data as CFData, &error
        ) else { return nil }
        return decrypted as Data
    }

    /// 签名
    func sign(_ data: Data, algorithm: SecKeyAlgorithm = .rsaSignatureDigestPKCS1v15SHA256) -> Data? {
        guard let privKey = privateKey else { return nil }
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privKey, algorithm, data as CFData, &error
        ) else { return nil }
        return signature as Data
    }

    /// 验签
    func verify(_ data: Data, signature: Data, algorithm: SecKeyAlgorithm = .rsaSignatureDigestPKCS1v15SHA256) -> Bool {
        guard let pubKey = publicKey else { return false }
        var error: Unmanaged<CFError>?
        return SecKeyVerifySignature(pubKey, algorithm, data as CFData, signature as CFData, &error)
    }

    private static func createPublicKey(from data: Data) -> SecKey? {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 2048
        ]
        return SecKeyCreateWithData(data as CFData, attributes as CFDictionary, nil)
    }

    private static func createPrivateKey(from data: Data) -> SecKey? {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 2048
        ]
        return SecKeyCreateWithData(data as CFData, attributes as CFDictionary, nil)
    }
}

// MARK: - 数字签名封装

/// 签名器 - 对应 Android Sign
class Sign {

    let algorithm: String

    init(_ algorithm: String) {
        self.algorithm = algorithm
    }

    /// 签名（使用 RSA 私钥）
    func sign(data: Data, privateKey: SecKey) -> Data? {
        var error: Unmanaged<CFError>?
        let algo = Self.mapAlgorithm(algorithm)
        return SecKeyCreateSignature(privateKey, algo, data as CFData, &error) as Data?
    }

    /// 验签
    func verify(data: Data, signature: Data, publicKey: SecKey) -> Bool {
        var error: Unmanaged<CFError>?
        let algo = Self.mapAlgorithm(algorithm)
        return SecKeyVerifySignature(publicKey, algo, data as CFData, signature as CFData, &error)
    }

    private static func mapAlgorithm(_ name: String) -> SecKeyAlgorithm {
        let upper = name.uppercased()
        if upper.contains("SHA256") { return .rsaSignatureDigestPKCS1v15SHA256 }
        if upper.contains("SHA512") { return .rsaSignatureDigestPKCS1v15SHA512 }
        if upper.contains("SHA1") { return .rsaSignatureDigestPKCS1v15SHA1 }
        if upper.contains("PSS") && upper.contains("SHA256") { return .rsaSignatureMessagePSSSHA256 }
        return .rsaSignatureDigestPKCS1v15SHA256
    }
}

// MARK: - JsEncodeUtils 协议

/// JS 加解密扩展协议 - 对应 Android JsEncodeUtils 接口
protocol JsEncodeUtils: AnyObject {

    // MARK: - MD5

    /// MD5 全量哈希（32字符）
    func md5Encode(_ str: String) -> String

    /// MD5 16字符哈希（取中间16位）
    func md5Encode16(_ str: String) -> String

    // MARK: - 对称加密工厂

    func createSymmetricCrypto(transformation: String, key: Data, iv: Data?) -> SymmetricCrypto
    func createSymmetricCrypto(transformation: String, key: Data) -> SymmetricCrypto
    func createSymmetricCrypto(transformation: String, key: String, iv: String?) -> SymmetricCrypto
    func createSymmetricCrypto(transformation: String, key: String) -> SymmetricCrypto

    // MARK: - 非对称加密工厂

    func createAsymmetricCrypto(transformation: String) -> AsymmetricCrypto

    // MARK: - 签名工厂

    func createSign(algorithm: String) -> Sign

    // MARK: - 摘要

    func digestHex(_ data: String, algorithm: String) -> String
    func digestBase64Str(_ data: String, algorithm: String) -> String
    func HMacHex(_ data: String, algorithm: String, key: String) -> String
    func HMacBase64(_ data: String, algorithm: String, key: String) -> String

    // MARK: - 兼容旧接口 AES

    func aesDecodeToString(_ str: String, key: String, transformation: String, iv: String) -> String?
    func aesBase64DecodeToString(_ str: String, key: String, transformation: String, iv: String) -> String?
    func aesEncodeToBase64String(_ data: String, key: String, transformation: String, iv: String) -> String?
    func aesDecodeArgsBase64Str(_ data: String, key: String, mode: String, padding: String, iv: String) -> String?
    func aesEncodeArgsBase64Str(_ data: String, key: String, mode: String, padding: String, iv: String) -> String?

    // MARK: - 兼容旧接口 DES

    func desDecodeToString(_ data: String, key: String, transformation: String, iv: String) -> String?
    func desBase64DecodeToString(_ data: String, key: String, transformation: String, iv: String) -> String?
    func desEncodeToString(_ data: String, key: String, transformation: String, iv: String) -> String?
    func desEncodeToBase64String(_ data: String, key: String, transformation: String, iv: String) -> String?

    // MARK: - 兼容旧接口 3DES

    func tripleDESDecodeStr(_ data: String, key: String, mode: String, padding: String, iv: String) -> String?
    func tripleDESDecodeArgsBase64Str(_ data: String, key: String, mode: String, padding: String, iv: String) -> String?
    func tripleDESEncodeBase64Str(_ data: String, key: String, mode: String, padding: String, iv: String) -> String?
    func tripleDESEncodeArgsBase64Str(_ data: String, key: String, mode: String, padding: String, iv: String) -> String?
}

// MARK: - 默认实现

extension JsEncodeUtils {

    // MARK: - MD5

    func md5Encode(_ str: String) -> String {
        let data = str.data(using: .utf8) ?? Data()
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        _ = data.withUnsafeBytes { ptr in
            CC_MD5(ptr.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func md5Encode16(_ str: String) -> String {
        let full = md5Encode(str)
        let start = full.index(full.startIndex, offsetBy: 8)
        let end = full.index(full.startIndex, offsetBy: 24)
        return String(full[start..<end])
    }

    // MARK: - 对称加密工厂

    func createSymmetricCrypto(transformation: String, key: Data, iv: Data?) -> SymmetricCrypto {
        return SymmetricCrypto(transformation: transformation, key: key, iv: iv)
    }

    func createSymmetricCrypto(transformation: String, key: Data) -> SymmetricCrypto {
        return SymmetricCrypto(transformation: transformation, key: key, iv: nil)
    }

    func createSymmetricCrypto(transformation: String, key: String, iv: String?) -> SymmetricCrypto {
        return SymmetricCrypto(transformation: transformation, key: key, iv: iv)
    }

    func createSymmetricCrypto(transformation: String, key: String) -> SymmetricCrypto {
        return createSymmetricCrypto(transformation: transformation, key: key, iv: nil)
    }

    // MARK: - 非对称加密工厂

    func createAsymmetricCrypto(transformation: String) -> AsymmetricCrypto {
        return AsymmetricCrypto(transformation: transformation)
    }

    // MARK: - 签名工厂

    func createSign(algorithm: String) -> Sign {
        return Sign(algorithm)
    }

    // MARK: - 摘要

    func digestHex(_ data: String, algorithm: String) -> String {
        guard let inputData = data.data(using: .utf8) else { return "" }
        let digest = Self.computeDigest(inputData, algorithm: algorithm)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func digestBase64Str(_ data: String, algorithm: String) -> String {
        guard let inputData = data.data(using: .utf8) else { return "" }
        let digest = Self.computeDigest(inputData, algorithm: algorithm)
        return Data(digest).base64EncodedString()
    }

    func HMacHex(_ data: String, algorithm: String, key: String) -> String {
        guard let inputData = data.data(using: .utf8),
              let keyData = key.data(using: .utf8) else { return "" }
        let hmac = Self.computeHMAC(inputData, algorithm: algorithm, key: keyData)
        return hmac.map { String(format: "%02x", $0) }.joined()
    }

    func HMacBase64(_ data: String, algorithm: String, key: String) -> String {
        guard let inputData = data.data(using: .utf8),
              let keyData = key.data(using: .utf8) else { return "" }
        let hmac = Self.computeHMAC(inputData, algorithm: algorithm, key: keyData)
        return Data(hmac).base64EncodedString()
    }

    // MARK: - AES 兼容

    func aesDecodeToString(_ str: String, key: String, transformation: String, iv: String) -> String? {
        return createSymmetricCrypto(transformation: transformation, key: key, iv: iv).decryptStr(str)
    }

    func aesBase64DecodeToString(_ str: String, key: String, transformation: String, iv: String) -> String? {
        return createSymmetricCrypto(transformation: transformation, key: key, iv: iv).decryptStr(str)
    }

    func aesEncodeToBase64String(_ data: String, key: String, transformation: String, iv: String) -> String? {
        return createSymmetricCrypto(transformation: transformation, key: key, iv: iv).encryptBase64(data)
    }

    func aesDecodeArgsBase64Str(_ data: String, key: String, mode: String, padding: String, iv: String) -> String? {
        guard let keyData = Data(base64Encoded: key),
              let ivData = Data(base64Encoded: iv) else { return nil }
        return createSymmetricCrypto(transformation: "AES/\(mode)/\(padding)", key: keyData, iv: ivData).decryptStr(data)
    }

    func aesEncodeArgsBase64Str(_ data: String, key: String, mode: String, padding: String, iv: String) -> String? {
        guard let keyData = Data(base64Encoded: key),
              let ivData = Data(base64Encoded: iv) else { return nil }
        return createSymmetricCrypto(transformation: "AES/\(mode)/\(padding)", key: keyData, iv: ivData).encryptBase64(data)
    }

    // MARK: - DES 兼容

    func desDecodeToString(_ data: String, key: String, transformation: String, iv: String) -> String? {
        return createSymmetricCrypto(transformation: transformation, key: key, iv: iv).decryptStr(data)
    }

    func desBase64DecodeToString(_ data: String, key: String, transformation: String, iv: String) -> String? {
        return createSymmetricCrypto(transformation: transformation, key: key, iv: iv).decryptStr(data)
    }

    func desEncodeToString(_ data: String, key: String, transformation: String, iv: String) -> String? {
        guard let encrypted = createSymmetricCrypto(transformation: transformation, key: key, iv: iv).encrypt(data) else { return nil }
        return String(data: encrypted, encoding: .isoLatin1)
    }

    func desEncodeToBase64String(_ data: String, key: String, transformation: String, iv: String) -> String? {
        return createSymmetricCrypto(transformation: transformation, key: key, iv: iv).encryptBase64(data)
    }

    // MARK: - 3DES 兼容

    func tripleDESDecodeStr(_ data: String, key: String, mode: String, padding: String, iv: String) -> String? {
        return createSymmetricCrypto(transformation: "DESede/\(mode)/\(padding)", key: key, iv: iv).decryptStr(data)
    }

    func tripleDESDecodeArgsBase64Str(_ data: String, key: String, mode: String, padding: String, iv: String) -> String? {
        guard let keyData = Data(base64Encoded: key) else { return nil }
        return createSymmetricCrypto(transformation: "DESede/\(mode)/\(padding)", key: keyData, iv: iv.data(using: .utf8)).decryptStr(data)
    }

    func tripleDESEncodeBase64Str(_ data: String, key: String, mode: String, padding: String, iv: String) -> String? {
        return createSymmetricCrypto(transformation: "DESede/\(mode)/\(padding)", key: key, iv: iv).encryptBase64(data)
    }

    func tripleDESEncodeArgsBase64Str(_ data: String, key: String, mode: String, padding: String, iv: String) -> String? {
        guard let keyData = Data(base64Encoded: key) else { return nil }
        return createSymmetricCrypto(transformation: "DESede/\(mode)/\(padding)", key: keyData, iv: iv.data(using: .utf8)).encryptBase64(data)
    }

    // MARK: - 内部工具

    private static func computeDigest(_ data: Data, algorithm: String) -> [UInt8] {
        let upper = algorithm.uppercased()
        switch upper {
        case "MD5":
            var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
            _ = data.withUnsafeBytes { CC_MD5($0.baseAddress, CC_LONG(data.count), &digest) }
            return digest
        case "SHA1", "SHA-1":
            var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
            _ = data.withUnsafeBytes { CC_SHA1($0.baseAddress, CC_LONG(data.count), &digest) }
            return digest
        case "SHA256", "SHA-256":
            var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            _ = data.withUnsafeBytes { CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
            return digest
        case "SHA512", "SHA-512":
            var digest = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
            _ = data.withUnsafeBytes { CC_SHA512($0.baseAddress, CC_LONG(data.count), &digest) }
            return digest
        default:
            // 默认 SHA256
            var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            _ = data.withUnsafeBytes { CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
            return digest
        }
    }

    private static func computeHMAC(_ data: Data, algorithm: String, key: Data) -> [UInt8] {
        let upper = algorithm.uppercased()
        var ccAlgorithm: CCHmacAlgorithm
        var digestLength: Int

        switch upper {
        case "MD5", "HMACMD5", "HMAC-MD5":
            ccAlgorithm = CCHmacAlgorithm(kCCHmacAlgMD5)
            digestLength = Int(CC_MD5_DIGEST_LENGTH)
        case "SHA1", "HMACSHA1", "HMAC-SHA1":
            ccAlgorithm = CCHmacAlgorithm(kCCHmacAlgSHA1)
            digestLength = Int(CC_SHA1_DIGEST_LENGTH)
        case "SHA256", "HMACSHA256", "HMAC-SHA256":
            ccAlgorithm = CCHmacAlgorithm(kCCHmacAlgSHA256)
            digestLength = Int(CC_SHA256_DIGEST_LENGTH)
        case "SHA512", "HMACSHA512", "HMAC-SHA512":
            ccAlgorithm = CCHmacAlgorithm(kCCHmacAlgSHA512)
            digestLength = Int(CC_SHA512_DIGEST_LENGTH)
        default:
            ccAlgorithm = CCHmacAlgorithm(kCCHmacAlgSHA256)
            digestLength = Int(CC_SHA256_DIGEST_LENGTH)
        }

        var hmac = [UInt8](repeating: 0, count: digestLength)
        key.withUnsafeBytes { keyPtr in
            data.withUnsafeBytes { dataPtr in
                CCHmac(ccAlgorithm, keyPtr.baseAddress, key.count, dataPtr.baseAddress, data.count, &hmac)
            }
        }
        return hmac
    }
}

// MARK: - Hex 工具

func hexToData(_ hex: String) -> Data? {
    guard hex.count % 2 == 0 else { return nil }
    var data = Data()
    var index = hex.startIndex
    while index < hex.endIndex {
        let nextIndex = hex.index(after: index)
        guard let byte = UInt8(String(hex[index...nextIndex]), radix: 16) else { return nil }
        data.append(byte)
        index = hex.index(after: nextIndex)
    }
    return data
}

func dataToHex(_ data: Data) -> String {
    return data.map { String(format: "%02x", $0) }.joined()
}