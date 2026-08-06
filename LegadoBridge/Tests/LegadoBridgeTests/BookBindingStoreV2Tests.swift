import Foundation
import XCTest
@testable import LegadoBridge

private final class ControllableFileWriter: BookBindingFileWriting {
    var files: [String: Data] = [:]
    var failReplace = false
    var failWriteTemp = false
    var replaceCallCount = 0

    func createDirectoryIfNeeded(at url: URL) throws {}

    func fileExists(at url: URL) -> Bool {
        files[url.path] != nil
    }

    func readData(at url: URL) throws -> Data {
        guard let data = files[url.path] else {
            throw NSError(domain: "test", code: 1)
        }
        return data
    }

    func writeData(_ data: Data, to url: URL) throws {
        if failWriteTemp, url.path.contains(".tmp") {
            throw NSError(domain: "test", code: 2)
        }
        files[url.path] = data
    }

    func removeItem(at url: URL) throws {
        files.removeValue(forKey: url.path)
    }

    func replaceItemAtomically(tempURL: URL, destinationURL: URL) throws {
        replaceCallCount += 1
        if failReplace {
            throw NSError(domain: "test", code: 3)
        }
        guard let data = files[tempURL.path] else {
            throw NSError(domain: "test", code: 4)
        }
        files[destinationURL.path] = data
        files.removeValue(forKey: tempURL.path)
    }
}

final class BookBindingStoreV2Tests: XCTestCase {
    private var root: URL!
    private var writer: ControllableFileWriter!
    private var store: BookBindingStore!
    private var now: Date = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lb-binding-v2-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        writer = ControllableFileWriter()
        store = BookBindingStore(
            persistenceRoot: root,
            clock: { [unowned self] in self.now },
            fileWriter: writer,
            usesLegacyDocumentsV1Fallback: false
        )
        _ = store.restoreFromDiskIfNeeded()
    }

    override func tearDown() {
        store.resetForTesting(clearPersistFile: true)
        try? FileManager.default.removeItem(at: root)
        // 确认未触碰真实 Documents
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        XCTAssertNotNil(docs)
        XCTAssertFalse(root.path.hasPrefix(docs!.path))
        super.tearDown()
    }

    func testSameBookUrlDifferentSourcesCoexist() throws {
        let a = try BookIdentity(exactSourceUrl: "https://source.a", exactBookUrl: "https://book/x")
        let b = try BookIdentity(exactSourceUrl: "https://source.b", exactBookUrl: "https://book/x")
        _ = try store.bind(bookUrl: a.bookUrl, sourceUrl: a.sourceUrl, name: "A")
        _ = try store.bind(bookUrl: b.bookUrl, sourceUrl: b.sourceUrl, name: "B")
        XCTAssertEqual(store.durableCount, 2)
        let list = store.bindings(forBookUrl: "https://book/x")
        XCTAssertEqual(list.count, 2)
        switch store.uniqueLegacyBinding(forBookUrl: "https://book/x") {
        case .failure(.ambiguous): break
        default: XCTFail("expected ambiguous")
        }
        switch store.binding(forToken: a.bridgeTokenV2) {
        case .success(let hit):
            XCTAssertEqual(hit.name, "A")
        case .failure(let err):
            XCTFail("token A \(err)")
        }
        switch store.binding(forToken: b.bridgeTokenV2) {
        case .success(let hit):
            XCTAssertEqual(hit.name, "B")
        case .failure(let err):
            XCTFail("token B \(err)")
        }
    }

    func testTokenCollisionBlocksStore() throws {
        // 手工写入损坏 envelope：同 token 不同 pair
        let idA = try BookIdentity(exactSourceUrl: "https://s/a", exactBookUrl: "https://b/1")
        let idB = try BookIdentity(exactSourceUrl: "https://s/b", exactBookUrl: "https://b/2")
        var badA = BookBindingV2(identity: idA, name: "A")
        var badB = BookBindingV2(identity: idB, name: "B")
        badB.bridgeToken = badA.bridgeToken // 强制碰撞
        let payload = try BookBindingStore.payloadSHA256(bindings: [badA, badB])
        let env = BookBindingV2Envelope(
            schemaVersion: 2,
            generation: 1,
            createdAt: "2020-01-01T00:00:00Z",
            checksumAlgorithm: BookBindingStore.checksumAlgorithm,
            payloadSHA256: payload,
            bindings: [badA, badB]
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(env)
        let v2URL = root.appendingPathComponent(BookBindingStore.v2FileName)
        writer.files[v2URL.path] = data

        let store2 = BookBindingStore(
            persistenceRoot: root,
            clock: { Date() },
            fileWriter: writer,
            usesLegacyDocumentsV1Fallback: false
        )
        _ = store2.restoreFromDiskIfNeeded()
        XCTAssertTrue(
            store2.currentRestoreState == .corruptedBlocked || store2.currentRestoreState == .readOnlyV1
        )
        // 不得覆盖：原 v2 文件仍在
        XCTAssertNotNil(writer.files[v2URL.path])
        switch store2.upsertAndFlushSync(BookBindingV2(identity: idA)) {
        case .failure(.corrupted), .failure(.readOnly):
            break
        default:
            XCTFail("mutation must be blocked")
        }
    }

    func testEphemeralSearchDoesNotGrowDurableCount() throws {
        XCTAssertEqual(store.durableCount, 0)
        var dtos: [EphemeralBookDTO] = []
        for i in 0..<100 {
            let id = try BookIdentity(
                exactSourceUrl: "https://source.example/\(i % 3)",
                exactBookUrl: "https://book.example/\(i)"
            )
            dtos.append(EphemeralBookDTO(identity: id, displayName: "书\(i)"))
        }
        XCTAssertEqual(dtos.count, 100)
        XCTAssertEqual(store.durableCount, 0)

        // 点击模拟 1 条
        let clicked = dtos[42]
        switch store.upsertAndFlushSync(BookBindingV2(identity: clicked.identity, name: clicked.name)) {
        case .success:
            break
        case .failure(let err):
            XCTFail("\(err)")
        }
        XCTAssertEqual(store.durableCount, 1)

        // 分页/刷新再造 100 ephemeral
        for i in 0..<100 {
            _ = try BookIdentity(
                exactSourceUrl: "https://source.example/\(i % 3)",
                exactBookUrl: "https://book.example/\(i)"
            ).bridgeTokenV2
        }
        XCTAssertEqual(store.durableCount, 1)
    }

    func testConcurrentUpsert1000Determinate() throws {
        let identity = try BookIdentity(exactSourceUrl: "https://s/conc", exactBookUrl: "https://b/conc")
        let group = DispatchGroup()
        let queues = (0..<4).map { DispatchQueue(label: "upsert-\($0)") }
        for i in 0..<1000 {
            group.enter()
            queues[i % 4].async {
                var binding = BookBindingV2(identity: identity, name: "n\(i)")
                _ = self.store.upsertAndFlushSync(binding)
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)
        XCTAssertEqual(store.durableCount, 1)
        XCTAssertEqual(store.currentGeneration, 1000)
        let final = store.binding(for: identity)
        XCTAssertNotNil(final)
        XCTAssertTrue(final!.name?.hasPrefix("n") == true)
    }

    func testDeleteSourceADoesNotAffectB() throws {
        let a = try BookIdentity(exactSourceUrl: "https://source.a", exactBookUrl: "https://book/1")
        let b = try BookIdentity(exactSourceUrl: "https://source.b", exactBookUrl: "https://book/1")
        _ = try store.bind(bookUrl: a.bookUrl, sourceUrl: a.sourceUrl, name: "A")
        _ = try store.bind(bookUrl: b.bookUrl, sourceUrl: b.sourceUrl, name: "B")
        store.markSourceAvailabilitySync(exactSourceUrl: a.sourceUrl, available: false)
        XCTAssertEqual(store.durableCount, 2)
        XCTAssertFalse(store.binding(for: a)?.sourceAvailable ?? true)
        XCTAssertTrue(store.binding(for: b)?.sourceAvailable ?? false)
        // 重导 A 恢复
        store.markSourceAvailabilitySync(exactSourceUrl: a.sourceUrl, available: true)
        XCTAssertTrue(store.binding(for: a)?.sourceAvailable ?? false)
    }

    func testEmptyKeyTypedErrorNotLbInvalid() {
        XCTAssertThrowsError(
            try store.bind(bookUrl: "", sourceUrl: "https://s")
        ) { err in
            XCTAssertEqual(err as? BookBindingUpsertError, .emptyKey)
        }
    }

    func testAtomicReplaceFailureLeavesPrevious() throws {
        let id = try BookIdentity(exactSourceUrl: "https://s/ok", exactBookUrl: "https://b/ok")
        _ = try store.bind(bookUrl: id.bookUrl, sourceUrl: id.sourceUrl, name: "first")
        let v2Path = root.appendingPathComponent(BookBindingStore.v2FileName).path
        let before = writer.files[v2Path]
        XCTAssertNotNil(before)
        writer.failReplace = true
        switch store.upsertAndFlushSync(BookBindingV2(identity: id, name: "second")) {
        case .failure(.persistFailed):
            break
        default:
            XCTFail("expected persistFailed")
        }
        // active 文件仍为旧内容
        XCTAssertEqual(writer.files[v2Path], before)
    }

    func testResidualTempDoesNotBecomeActive() throws {
        let tempPath = root.appendingPathComponent("book-bindings-v2.stale.tmp").path
        writer.files[tempPath] = Data("garbage".utf8)
        let id = try BookIdentity(exactSourceUrl: "https://s/t", exactBookUrl: "https://b/t")
        _ = try store.bind(bookUrl: id.bookUrl, sourceUrl: id.sourceUrl, name: "ok")
        let v2Path = root.appendingPathComponent(BookBindingStore.v2FileName).path
        XCTAssertNotNil(writer.files[v2Path])
        XCTAssertNotEqual(writer.files[v2Path], Data("garbage".utf8))
    }
}
