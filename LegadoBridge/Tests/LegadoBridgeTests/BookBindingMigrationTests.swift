import Foundation
import XCTest
@testable import LegadoBridge

private final class MemoryFileWriter: BookBindingFileWriting {
    var files: [String: Data] = [:]

    func createDirectoryIfNeeded(at url: URL) throws {}
    func fileExists(at url: URL) -> Bool { files[url.path] != nil }
    func readData(at url: URL) throws -> Data {
        guard let d = files[url.path] else { throw NSError(domain: "t", code: 1) }
        return d
    }
    func writeData(_ data: Data, to url: URL) throws { files[url.path] = data }
    func removeItem(at url: URL) throws { files.removeValue(forKey: url.path) }
    func replaceItemAtomically(tempURL: URL, destinationURL: URL) throws {
        guard let data = files[tempURL.path] else { throw NSError(domain: "t", code: 2) }
        files[destinationURL.path] = data
        files.removeValue(forKey: tempURL.path)
    }
}

final class BookBindingMigrationTests: XCTestCase {
    private var root: URL!
    private var writer: MemoryFileWriter!

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lb-mig-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        writer = MemoryFileWriter()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func makeStore() -> BookBindingStore {
        BookBindingStore(
            persistenceRoot: root,
            clock: { Date(timeIntervalSince1970: 1_700_000_100) },
            fileWriter: writer,
            usesLegacyDocumentsV1Fallback: false
        )
    }

    func testV1NormalMigration() throws {
        let v1: [[String: Any]] = [
            [
                "bookUrl": "https://book/1",
                "sourceUrl": "https://source/a",
                "sourceName": "A",
                "name": "书1",
                "author": "作",
                "coverUrl": "",
                "sourceAvailable": true,
                "updatedAt": 1_700_000_000.0
            ],
            [
                "bookUrl": "https://book/2",
                "sourceUrl": "https://source/b",
                "name": "书2",
                "sourceAvailable": true,
                "updatedAt": 1_700_000_001.0
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: v1)
        writer.files[root.appendingPathComponent(BookBindingStore.v1FileName).path] = data

        let store = makeStore()
        let count = store.restoreFromDiskIfNeeded()
        XCTAssertEqual(count, 2)
        XCTAssertEqual(store.currentRestoreState, .readyV2)
        let report = store.migrationReport
        XCTAssertEqual(report?.migratedCount, 2)
        XCTAssertEqual(report?.duplicateCount, 0)
        XCTAssertNotNil(report?.sourceContentSHA256)
        // v1 永不删除
        XCTAssertNotNil(writer.files[root.appendingPathComponent(BookBindingStore.v1FileName).path])
        XCTAssertNotNil(writer.files[root.appendingPathComponent(BookBindingStore.v2FileName).path])
    }

    func testV1DuplicateAndAmbiguityCounted() throws {
        let v1: [[String: Any]] = [
            ["bookUrl": "https://book/x", "sourceUrl": "https://source/a", "name": "A1"],
            ["bookUrl": "https://book/x", "sourceUrl": "https://source/a", "name": "A2-dup"],
            ["bookUrl": "https://book/x", "sourceUrl": "https://source/b", "name": "B"],
        ]
        writer.files[root.appendingPathComponent(BookBindingStore.v1FileName).path] =
            try JSONSerialization.data(withJSONObject: v1)
        let store = makeStore()
        _ = store.restoreFromDiskIfNeeded()
        let report = store.migrationReport
        XCTAssertEqual(report?.migratedCount, 2) // a 与 b；第二次 a 为 duplicate
        XCTAssertEqual(report?.duplicateCount, 1)
        XCTAssertGreaterThanOrEqual(report?.ambiguityCount ?? 0, 1)
        switch store.uniqueLegacyBinding(forBookUrl: "https://book/x") {
        case .failure(.ambiguous): break
        default: XCTFail("expected ambiguous after multi-source migrate")
        }
    }

    func testV2ChecksumCorruptionBlocksMutation() throws {
        let id = try BookIdentity(exactSourceUrl: "https://s", exactBookUrl: "https://b")
        let binding = BookBindingV2(identity: id, name: "x")
        let goodSHA = try BookBindingStore.payloadSHA256(bindings: [binding])
        var env = BookBindingV2Envelope(
            schemaVersion: 2,
            generation: 3,
            createdAt: "2020-01-01T00:00:00Z",
            checksumAlgorithm: BookBindingStore.checksumAlgorithm,
            payloadSHA256: goodSHA,
            bindings: [binding]
        )
        env.payloadSHA256 = "deadbeef"
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        writer.files[root.appendingPathComponent(BookBindingStore.v2FileName).path] = try enc.encode(env)

        let store = makeStore()
        _ = store.restoreFromDiskIfNeeded()
        XCTAssertTrue(
            store.currentRestoreState == .corruptedBlocked || store.currentRestoreState == .readOnlyV1
        )
        switch store.upsertAndFlushSync(BookBindingV2(identity: id, name: "y")) {
        case .failure(.corrupted), .failure(.readOnly):
            break
        default:
            XCTFail("must block")
        }
        // 原损坏文件保留
        XCTAssertNotNil(writer.files[root.appendingPathComponent(BookBindingStore.v2FileName).path])
    }

    func testRepeatMigrationSkippedWhenV2Exists() throws {
        let v1: [[String: Any]] = [
            ["bookUrl": "https://book/1", "sourceUrl": "https://source/a", "name": "A"]
        ]
        writer.files[root.appendingPathComponent(BookBindingStore.v1FileName).path] =
            try JSONSerialization.data(withJSONObject: v1)
        let store = makeStore()
        XCTAssertEqual(store.restoreFromDiskIfNeeded(), 1)
        let gen1 = store.currentGeneration
        let report1 = store.migrationReport

        // 再次 restore：v2 已存在，不重复迁移
        store.resetForTesting(clearPersistFile: false)
        // reset 清了内存但 clearPersistFile=false 时 Controllable 未清 files——用新 store
        let store2 = makeStore()
        XCTAssertEqual(store2.restoreFromDiskIfNeeded(), 1)
        XCTAssertNil(store2.migrationReport) // 走 v2 路径无新 migration report
        XCTAssertEqual(store2.currentGeneration, gen1)
        _ = report1
    }
}
