import Foundation
import XCTest
@testable import LegadoBridge

/// SourceRegistry 确定性门禁：导入 / 重复源 / 禁用 / 持久化恢复。
/// 需在 macOS/CI 的 iOS 目标上执行：`swift test --package-path LegadoBridge`
/// Windows 无 iOS SDK 时由 `.test_tools/validate_baseline_and_tests.py` 校验本文件与 Package 结构。
final class SourceRegistryTests: XCTestCase {
    private let registry = SourceRegistry.shared

    override func setUp() {
        super.setUp()
        registry.resetForTesting(clearPersistFile: true)
    }

    override func tearDown() {
        registry.resetForTesting(clearPersistFile: true)
        super.tearDown()
    }

    func testImportSingleSource() throws {
        let data = try Self.jsonData(Self.sampleSource(url: "https://example.com/a", name: "源A"))
        let count = try registry.importJSONData(data)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(registry.allSources().count, 1)
        XCTAssertEqual(registry.allSources().first?.bookSourceName, "源A")
        XCTAssertTrue(registry.isEnabled(url: "https://example.com/a"))
    }

    func testImportSourceArray() throws {
        let arr: [[String: Any]] = [
            Self.sampleSource(url: "https://example.com/a", name: "源A"),
            Self.sampleSource(url: "https://example.com/b", name: "源B"),
        ]
        let data = try JSONSerialization.data(withJSONObject: arr)
        let count = try registry.importJSONData(data)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(Set(registry.allSources().map(\.bookSourceUrl)),
                       Set(["https://example.com/a", "https://example.com/b"]))
    }

    func testDuplicateSourceOverwritesNameButPreservesDisable() throws {
        let url = "https://example.com/dup"
        let first = try Self.jsonData(Self.sampleSource(url: url, name: "旧名"))
        XCTAssertEqual(try registry.importJSONData(first), 1)
        registry.setEnabled(url: url, enabled: false)

        let second = try Self.jsonData(Self.sampleSource(url: url, name: "新名"))
        XCTAssertEqual(try registry.importJSONData(second), 1)
        XCTAssertEqual(registry.allSources().count, 1)
        XCTAssertEqual(registry.allSources().first?.bookSourceName, "新名")
        // 默认 preserveLocalEnabled：重复导入不得把本地禁用改回启用
        XCTAssertFalse(registry.isEnabled(url: url))
    }

    func testDisableSourcePersistsAcrossRestore() throws {
        let url = "https://example.com/disabled"
        let data = try Self.jsonData(Self.sampleSource(url: url, name: "可禁用"))
        XCTAssertEqual(try registry.importJSONData(data), 1)
        registry.setEnabled(url: url, enabled: false)
        XCTAssertFalse(registry.isEnabled(url: url))
        XCTAssertEqual(registry.allSources().count, 1)

        // 清内存但保留落盘文件，模拟进程重启
        registry.resetForTesting(clearPersistFile: false)
        XCTAssertEqual(registry.allSources().count, 0)

        let restored = registry.restoreFromDiskIfNeeded()
        XCTAssertEqual(restored, 1)
        XCTAssertEqual(registry.allSources().count, 1)
        XCTAssertFalse(registry.isEnabled(url: url))
        XCTAssertEqual(registry.allSources().first?.bookSourceName, "可禁用")
    }

    func testRejectNonLegadoJSON() {
        let junk = Data(#"{"foo":"bar"}"#.utf8)
        XCTAssertThrowsError(try registry.importJSONData(junk))
        XCTAssertEqual(registry.allSources().count, 0)
    }

    // MARK: - fixtures

    private static func sampleSource(url: String, name: String) -> [String: Any] {
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

    private static func jsonData(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }
}
