import Foundation
import XCTest
@testable import LegadoBridge

final class NativeSourceListProjectionTests: XCTestCase {
    private let registry = SourceRegistry.shared

    override func setUp() {
        super.setUp()
        registry.resetForTesting(clearPersistFile: true)
        NativeManagerPersistenceGuard.resetForTests()
    }

    override func tearDown() {
        registry.resetForTesting(clearPersistFile: true)
        NativeManagerPersistenceGuard.resetForTests()
        super.tearDown()
    }

    func testProjectionKeyIsStableSHA256Prefix() {
        let url = "https://example.com/src-a"
        let k1 = NativeSourceListProjection.projectionKey(for: url)
        let k2 = NativeSourceListProjection.projectionKey(for: url)
        XCTAssertEqual(k1, k2)
        XCTAssertTrue(k1.hasPrefix(NativeSourceListProjection.keyPrefix))
        XCTAssertEqual(k1.count, NativeSourceListProjection.keyPrefix.count + 64)
        XCTAssertTrue(NativeSourceListProjection.isProjectionKey(k1))
        XCTAssertFalse(NativeSourceListProjection.isProjectionKey("笔趣读"))
    }

    func testEphemeralDictionaryOmitsBookWorldAndRequestInfo() throws {
        let proj = NativeSourceListProjection.make(
            exactSourceUrl: "https://example.com/a",
            displaySourceName: "源A",
            enabled: true
        )
        let dict = proj.ephemeralListDictionary()
        XCTAssertNil(dict["bookWorld"])
        XCTAssertNil(dict["requestInfo"])
        XCTAssertNil(dict["arrHeaderBtnTitle"])
        XCTAssertNil(dict["requestFilters"])
        XCTAssertEqual(dict["title"] as? String, "源A")
        XCTAssertEqual(dict["sourceName"] as? String, "源A")
        XCTAssertEqual(dict["_lb_projectionKey"] as? String, proj.projectionKey)
        XCTAssertEqual(dict[XiangseAdapter.legadoMarkerKey] as? String, XiangseAdapter.legadoMarkerValue)
        // searchBook 仅占位结构
        let sb = dict["searchBook"] as? [String: Any]
        XCTAssertEqual(sb?["actionID"] as? String, "searchBook")
        XCTAssertNil(sb?["requestInfo"])
    }

    func testListKeysDisambiguateNativeConflictWithoutLegadoBadge() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            Self.sample(url: "https://lb.example/a", name: "番茄小说"),
        ])
        XCTAssertEqual(try registry.importJSONData(data), 1)

        let keys = NativeSourceInjector.listKeys(nativeNames: ["番茄小说"])
        XCTAssertEqual(keys.count, 1)
        XCTAssertTrue(NativeSourceListProjection.isProjectionKey(keys[0]))
        XCTAssertFalse(keys[0].contains("·Legado"))

        let model = NativeSourceInjector.nativeModel(forSourceName: keys[0])
        XCTAssertEqual(model?["title"] as? String, "番茄小说")
        XCTAssertEqual(model?["bookSourceUrl"] as? String, "https://lb.example/a")
    }

    func testTwoLegadoSameDisplayNameUseProjectionKey() throws {
        let arr: [[String: Any]] = [
            Self.sample(url: "https://lb.example/1", name: "同名源"),
            Self.sample(url: "https://lb.example/2", name: "同名源"),
        ]
        XCTAssertEqual(try registry.importJSONData(try JSONSerialization.data(withJSONObject: arr)), 2)

        let keys = NativeSourceInjector.listKeys(nativeNames: [])
        XCTAssertEqual(keys.count, 2)
        let displays = keys.filter { !NativeSourceListProjection.isProjectionKey($0) }
        let projKeys = keys.filter { NativeSourceListProjection.isProjectionKey($0) }
        XCTAssertEqual(displays, ["同名源"])
        XCTAssertEqual(projKeys.count, 1)
        XCTAssertFalse(keys.contains { $0.hasSuffix("·Legado") })

        let urls = Set(keys.compactMap {
            NativeSourceInjector.nativeModel(forSourceName: $0)?["bookSourceUrl"] as? String
        })
        XCTAssertEqual(urls, Set(["https://lb.example/1", "https://lb.example/2"]))
    }

    func testSyncPathsDoNotInvokeManagerSave() {
        NativeManagerPersistenceGuard.resetForTests()
        NativeSourceInjector.syncToNativeManager(sources: [])
        NativeSourceInjector.syncToNativeManagerWhenReady(sources: [])
        NativeSourceInjector.removeFromNativeManager(names: ["x"], allowLegacyMigration: false)
        let snap = NativeManagerPersistenceGuard.snapshot()
        // sync 会计数；save/addModels 必须仍为 0（未写 manager）
        XCTAssertEqual(snap.save, 0)
        XCTAssertEqual(snap.addModels, 0)
        XCTAssertGreaterThanOrEqual(snap.sync, 2)
    }

    func testNoExploreUrlStillProjectsAsLegado() throws {
        var src = Self.sample(url: "https://lb.example/noexplore", name: "无发现")
        src.removeValue(forKey: "exploreUrl")
        XCTAssertEqual(try registry.importJSONData(try JSONSerialization.data(withJSONObject: src)), 1)
        let keys = NativeSourceInjector.listKeys(nativeNames: [])
        XCTAssertEqual(keys, ["无发现"])
        XCTAssertTrue(NativeSourceInjector.isLegadoSourceName("无发现"))
        let model = NativeSourceInjector.nativeModel(forSourceName: "无发现")
        XCTAssertEqual(model?["_lb_sourceType"] as? String, NativeSourceListProjection.sourceTypeLegado)
    }

    private static func sample(url: String, name: String) -> [String: Any] {
        [
            "bookSourceUrl": url,
            "bookSourceName": name,
            "bookSourceType": 0,
            "enabled": true,
            "searchUrl": "\(url)/search?q={{key}}",
            "ruleSearch": [
                "bookList": ".bookbox",
                "name": "h4@text",
                "author": ".author@text",
                "bookUrl": "a@href",
            ],
        ]
    }
}
