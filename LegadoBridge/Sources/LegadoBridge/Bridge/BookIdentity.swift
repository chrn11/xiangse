import Foundation
import CryptoKit

// MARK: - Errors

enum BookIdentityError: Error, Equatable, Sendable {
    case emptySourceUrl
    case emptyBookUrl
}

enum BookBindingLookupError: Error, Equatable, Sendable {
    case ambiguous
    case notFound
    case tokenCollision
    case identityMismatch
    case storeNotReady
    case readOnly
    case corrupted
    case emptyKey
}

enum BookBindingUpsertError: Error, Equatable, Sendable {
    case emptyKey
    case storeNotReady
    case readOnly
    case corrupted
    case persistFailed
    case generationStale
}

// MARK: - BookIdentity

/// 书源 URL + 书籍 URL 的复合身份；token 为纯函数，不依赖 store / 活动源。
struct BookIdentity: Hashable, Codable, Sendable {
    let sourceUrl: String
    let bookUrl: String

    /// 只移除首尾 Unicode whitespace/newline；保留大小写、端口、query、fragment、重复斜杠与 percent encoding。
    init(exactSourceUrl: String, exactBookUrl: String) throws {
        let source = exactSourceUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let book = exactBookUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { throw BookIdentityError.emptySourceUrl }
        guard !book.isEmpty else { throw BookIdentityError.emptyBookUrl }
        self.sourceUrl = source
        self.bookUrl = book
    }

    /// `lb2_` + lowercaseHex(SHA256(LBID2\\0 || lenBE(source) || source || lenBE(book) || book))
    var bridgeTokenV2: String {
        Self.bridgeTokenV2(sourceUrl: sourceUrl, bookUrl: bookUrl)
    }

    static func bridgeTokenV2(sourceUrl: String, bookUrl: String) -> String {
        var frame = Data("LBID2\0".utf8)
        let sourceData = Data(sourceUrl.utf8)
        let bookData = Data(bookUrl.utf8)
        frame.append(Self.uint32BE(UInt32(sourceData.count)))
        frame.append(sourceData)
        frame.append(Self.uint32BE(UInt32(bookData.count)))
        frame.append(bookData)
        let digest = SHA256.hash(data: frame)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "lb2_" + hex
    }

    private static func uint32BE(_ value: UInt32) -> Data {
        var be = value.bigEndian
        return Data(bytes: &be, count: MemoryLayout<UInt32>.size)
    }
}

// MARK: - BookBindingV2

struct BookBindingV2: Equatable, Codable, Sendable {
    var identity: BookIdentity
    var bridgeToken: String
    var sourceNameSnapshot: String?
    var name: String?
    var author: String?
    var coverUrl: String?
    var intro: String?
    var kind: String?
    var lastChapterTitle: String?
    var wordCount: String?
    var sourceAvailable: Bool
    var createdAt: Date
    var updatedAt: Date

    var sourceUrl: String { identity.sourceUrl }
    var bookUrl: String { identity.bookUrl }

    init(
        identity: BookIdentity,
        bridgeToken: String? = nil,
        sourceNameSnapshot: String? = nil,
        name: String? = nil,
        author: String? = nil,
        coverUrl: String? = nil,
        intro: String? = nil,
        kind: String? = nil,
        lastChapterTitle: String? = nil,
        wordCount: String? = nil,
        sourceAvailable: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.identity = identity
        self.bridgeToken = bridgeToken ?? identity.bridgeTokenV2
        self.sourceNameSnapshot = sourceNameSnapshot
        self.name = name
        self.author = author
        self.coverUrl = coverUrl
        self.intro = intro
        self.kind = kind
        self.lastChapterTitle = lastChapterTitle
        self.wordCount = wordCount
        self.sourceAvailable = sourceAvailable
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// 搜索/发现列表用的 ephemeral DTO；不触发 durable upsert。
struct EphemeralBookDTO: Equatable, Sendable {
    let identity: BookIdentity
    let bridgeToken: String
    var name: String = ""
    var author: String = ""
    var coverUrl: String?
    var intro: String?
    var kind: String?
    var lastChapter: String?
    var wordCount: String?
    var sourceName: String = ""

    init(identity: BookIdentity, displayName: String = "", author: String = "", sourceName: String = "") {
        self.identity = identity
        self.bridgeToken = identity.bridgeTokenV2
        self.name = displayName
        self.author = author
        self.sourceName = sourceName
    }

    init?(exactSourceUrl: String, exactBookUrl: String) {
        guard let identity = try? BookIdentity(exactSourceUrl: exactSourceUrl, exactBookUrl: exactBookUrl) else {
            return nil
        }
        self.init(identity: identity)
    }
}

/// 兼容旧 `BookBinding` 字段名的轻量视图（adapter / 旧测试迁移用）。
struct BookBinding: Equatable {
    var bookUrl: String
    var sourceUrl: String
    var bridgeToken: String
    var sourceName: String
    var name: String
    var author: String
    var coverUrl: String
    var sourceAvailable: Bool
    var updatedAt: TimeInterval

    init(from v2: BookBindingV2) {
        bookUrl = v2.bookUrl
        sourceUrl = v2.sourceUrl
        bridgeToken = v2.bridgeToken
        sourceName = v2.sourceNameSnapshot ?? ""
        name = v2.name ?? ""
        author = v2.author ?? ""
        coverUrl = v2.coverUrl ?? ""
        sourceAvailable = v2.sourceAvailable
        updatedAt = v2.updatedAt.timeIntervalSince1970
    }

    init(
        bookUrl: String,
        sourceUrl: String,
        bridgeToken: String,
        sourceName: String,
        name: String,
        author: String,
        coverUrl: String,
        sourceAvailable: Bool,
        updatedAt: TimeInterval
    ) {
        self.bookUrl = bookUrl
        self.sourceUrl = sourceUrl
        self.bridgeToken = bridgeToken
        self.sourceName = sourceName
        self.name = name
        self.author = author
        self.coverUrl = coverUrl
        self.sourceAvailable = sourceAvailable
        self.updatedAt = updatedAt
    }

    func toV2() throws -> BookBindingV2 {
        let identity = try BookIdentity(exactSourceUrl: sourceUrl, exactBookUrl: bookUrl)
        let ts = Date(timeIntervalSince1970: updatedAt)
        return BookBindingV2(
            identity: identity,
            bridgeToken: bridgeToken.isEmpty ? identity.bridgeTokenV2 : bridgeToken,
            sourceNameSnapshot: sourceName.isEmpty ? nil : sourceName,
            name: name.isEmpty ? nil : name,
            author: author.isEmpty ? nil : author,
            coverUrl: coverUrl.isEmpty ? nil : coverUrl,
            sourceAvailable: sourceAvailable,
            createdAt: ts,
            updatedAt: ts
        )
    }
}

// MARK: - Shelf adapter（TC-03A selected branch 最小结构；调用留给 TC-09）

/// 与 TC-03A 合同对齐的选型枚举。无设计产物时默认 `persistedToken`（token 即 Bridge 权威身份）。
enum NativeShelfIdentityStrategy: String, Codable, Sendable {
    case persistedToken
    case verifiedNativeRecordHandleSidecar
    case verifiedSourceScopedNativeBookKey
    case unsupportedNativeBookKeyCollision
}

/// 最小 shelf sidecar：只映射 Bridge token ↔ identity，不替代原生 bookKey。
struct ShelfIdentitySidecar: Codable, Equatable, Sendable {
    var bridgeToken: String
    var identity: BookIdentity
    var nativeBookKey: String?
    var updatedAt: Date
}

enum ShelfIdentityAdapter {
    /// TC-03A 未产出 `shelf-identity-design.json` 时，按 token 权威路径提供 API，供 TC-09 接线。
    static let selectedStrategy: NativeShelfIdentityStrategy = .persistedToken
    static let nativeKeyStrategy = "appConfigBookKey"
    static let implementationReady = true

    static func makeSidecar(
        binding: BookBindingV2,
        nativeBookKey: String?,
        now: Date = Date()
    ) -> ShelfIdentitySidecar {
        ShelfIdentitySidecar(
            bridgeToken: binding.bridgeToken,
            identity: binding.identity,
            nativeBookKey: nativeBookKey,
            updatedAt: now
        )
    }

    static func resolveIdentity(
        bridgeToken: String,
        store: BookBindingStore = .shared
    ) -> Result<BookIdentity, BookBindingLookupError> {
        switch store.binding(forToken: bridgeToken) {
        case .success(let binding):
            return .success(binding.identity)
        case .failure(let err):
            return .failure(err)
        }
    }
}
