import Foundation
import XCTest
@testable import LegadoBridge

final class BookBindingResolverTests: XCTestCase {
    private var root: URL!
    private var store: BookBindingStore!

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lb-res-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = BookBindingStore(
            persistenceRoot: root,
            clock: { Date() },
            fileWriter: DefaultBookBindingFileWriter(),
            usesLegacyDocumentsV1Fallback: false
        )
        _ = store.restoreFromDiskIfNeeded()
    }

    override func tearDown() {
        store.resetForTesting(clearPersistFile: true)
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testResolverOrderTokenThenPairThenLegacy() throws {
        let a = try BookIdentity(exactSourceUrl: "https://source.a", exactBookUrl: "https://book/x")
        let b = try BookIdentity(exactSourceUrl: "https://source.b", exactBookUrl: "https://book/x")
        _ = try store.bind(bookUrl: a.bookUrl, sourceUrl: a.sourceUrl, name: "A")
        _ = try store.bind(bookUrl: b.bookUrl, sourceUrl: b.sourceUrl, name: "B")

        // 1) token 精确
        switch store.resolveBinding(token: a.bridgeTokenV2, exactSourceUrl: nil, bookUrl: nil) {
        case .success(let hit):
            XCTAssertEqual(hit.name, "A")
        case .failure(let e):
            XCTFail("\(e)")
        }

        // 2) 显式 pair
        switch store.resolveBinding(
            token: nil,
            exactSourceUrl: b.sourceUrl,
            bookUrl: b.bookUrl
        ) {
        case .success(let hit):
            XCTAssertEqual(hit.name, "B")
        case .failure(let e):
            XCTFail("\(e)")
        }

        // 3) bookUrl-only 歧义
        switch store.resolveBinding(token: nil, exactSourceUrl: nil, bookUrl: "https://book/x") {
        case .failure(.ambiguous): break
        default: XCTFail("expected ambiguous")
        }
    }

    func testIdentityMismatchWhenRequestedDiffersFromToken() throws {
        let a = try BookIdentity(exactSourceUrl: "https://source.a", exactBookUrl: "https://book/1")
        _ = try store.bind(bookUrl: a.bookUrl, sourceUrl: a.sourceUrl, name: "A")
        switch store.resolveBinding(
            token: a.bridgeTokenV2,
            exactSourceUrl: "https://source.other",
            bookUrl: a.bookUrl
        ) {
        case .failure(.identityMismatch): break
        default: XCTFail("expected identityMismatch")
        }
    }

    func testActiveSourceChangeDoesNotAffectResolver() throws {
        let a = try BookIdentity(exactSourceUrl: "https://source.a", exactBookUrl: "https://book/1")
        let b = try BookIdentity(exactSourceUrl: "https://source.b", exactBookUrl: "https://book/2")
        _ = try store.bind(bookUrl: a.bookUrl, sourceUrl: a.sourceUrl, name: "A")
        _ = try store.bind(bookUrl: b.bookUrl, sourceUrl: b.sourceUrl, name: "B")

        // 模拟「活动源变化」：不写入 store，仅本地变量
        var activeSource = "https://source.b"
        switch store.resolveBinding(token: a.bridgeTokenV2, exactSourceUrl: nil, bookUrl: nil) {
        case .success(let hit):
            XCTAssertEqual(hit.sourceUrl, a.sourceUrl)
            XCTAssertNotEqual(hit.sourceUrl, activeSource)
        case .failure(let e):
            XCTFail("\(e)")
        }
        activeSource = "https://source.a"
        switch store.resolveBinding(token: b.bridgeTokenV2, exactSourceUrl: nil, bookUrl: nil) {
        case .success(let hit):
            XCTAssertEqual(hit.sourceUrl, b.sourceUrl)
            XCTAssertNotEqual(hit.sourceUrl, activeSource)
        case .failure(let e):
            XCTFail("\(e)")
        }
    }

    func testNoURLFallbackStaticScanInStoreAPI() {
        // 静态扫描：resolver / store 公开路径不得依赖 originURL 猜源符号
        let storeSource = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LegadoBridge/Bridge/BookBindingStore.swift")
        let coreSource = storeSource
            .deletingLastPathComponent()
            .appendingPathComponent("LegadoBridgeCore.swift")
        for url in [storeSource, coreSource] {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                XCTFail("missing \(url.lastPathComponent)")
                continue
            }
            // Core 允许在注释中提到禁止项；禁止可执行调用 originURL(
            let withoutComments = text
                .split(separator: "\n")
                .filter { line in
                    let t = line.trimmingCharacters(in: .whitespaces)
                    return !t.hasPrefix("//") && !t.hasPrefix("///") && !t.hasPrefix("*")
                }
                .joined(separator: "\n")
            XCTAssertFalse(
                withoutComments.contains("originURL("),
                "\(url.lastPathComponent) must not call originURL("
            )
            XCTAssertFalse(
                withoutComments.contains("bookCache[bookUrl]"),
                "\(url.lastPathComponent) must not use bookCache[bookUrl]"
            )
        }
    }

    func testShelfAdapterPersistedTokenAPI() throws {
        XCTAssertEqual(ShelfIdentityAdapter.selectedStrategy, .persistedToken)
        let id = try BookIdentity(exactSourceUrl: "https://s", exactBookUrl: "https://b")
        let binding = BookBindingV2(identity: id, name: "n")
        _ = store.upsertAndFlushSync(binding)
        let side = ShelfIdentityAdapter.makeSidecar(binding: binding, nativeBookKey: "name_author")
        XCTAssertEqual(side.bridgeToken, id.bridgeTokenV2)
        switch ShelfIdentityAdapter.resolveIdentity(bridgeToken: id.bridgeTokenV2, store: store) {
        case .success(let got):
            XCTAssertEqual(got, id)
        case .failure(let e):
            XCTFail("\(e)")
        }
    }
}
