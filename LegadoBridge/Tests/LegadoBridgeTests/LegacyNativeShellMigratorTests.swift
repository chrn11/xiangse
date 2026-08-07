import XCTest
@testable import LegadoBridge

/// TC-10：legacy shell dry-run / apply 安全边界（不触达真机 apply）。
final class LegacyNativeShellMigratorTests: XCTestCase {
    private let contractBuild = LegacyNativeShellMigrator.FirstSeenBuild(
        appVersion: "2.56.1",
        nativeExecutableSHA256: "04f780eb59f86c9104f8c8c3c04fb24278f521d0a43e401b3773d2a47890dea7"
    )

    // MARK: - canonical JSON

    func testCanonicalJSONKeyOrderStable() {
        let obj: [String: Any] = ["z": 1, "a": true, "m": "x"]
        XCTAssertEqual(
            LegacyNativeShellMigrator.canonicalJSONString(obj),
            #"{"a":true,"m":"x","z":1}"#
        )
    }

    func testCanonicalSHA256Deterministic() {
        let model: [String: Any] = [
            "sourceName": "壳",
            "sourceType": "0",
            "sourceUrl": "https://example.com/s",
        ]
        let h1 = LegacyNativeShellMigrator.canonicalSHA256(model)
        let h2 = LegacyNativeShellMigrator.canonicalSHA256(model)
        XCTAssertEqual(h1, h2)
        XCTAssertEqual(h1?.count, 64)
    }

    // MARK: - classification

    func testPristineNativeNeverDeletionCandidate() throws {
        let pristine: [String: Any] = [
            "sourceName": "番茄小说官方api",
            "bookWorld": [
                "男频": [
                    "actionID": "bookWorld",
                    "parserID": "dom",
                    "requestInfo": "@js:",
                    "list": [],
                ] as [String: Any],
            ] as [String: Any],
        ]
        XCTAssertTrue(LegacyNativeShellMigrator.isPristineNative(pristine))

        let snapshot = ["番茄小说官方api": pristine]
        let result = try LegacyNativeShellMigrator.dryRun(
            rawManagerSnapshot: snapshot,
            allowlist: emptyAllowlist()
        )
        XCTAssertEqual(result.pristineCount, 1)
        XCTAssertTrue(result.candidates.isEmpty)
    }

    func testMarkedLegadoShellIsCandidateWithoutAllowlistMatch() throws {
        let shell: [String: Any] = [
            XiangseAdapter.legadoMarkerKey: XiangseAdapter.legadoMarkerValue,
            "sourceName": "测试",
            "sourceType": "0",
            "sourceUrl": "https://legado.example/bookSource",
        ]
        let snapshot = ["测试": shell]
        let result = try LegacyNativeShellMigrator.dryRun(
            rawManagerSnapshot: snapshot,
            allowlist: emptyAllowlist()
        )
        XCTAssertTrue(result.candidates.isEmpty, "空 allowlist 不得删除")

        let doc = try LegacyNativeShellMigrator.loadBundledAllowlist()
        let withItems = LegacyNativeShellMigrator.AllowlistDocument(
            schemaVersion: doc.schemaVersion,
            contractID: doc.contractID,
            selectedBranch: doc.selectedBranch,
            hashAlgorithm: doc.hashAlgorithm,
            firstSeenBuild: doc.firstSeenBuild,
            evidencePath: doc.evidencePath,
            evidenceSHA256: doc.evidenceSHA256,
            items: [syntheticItem(name: "测试", model: shell, markerExpected: true)]
        )
        let run = try LegacyNativeShellMigrator.dryRun(
            rawManagerSnapshot: snapshot,
            allowlist: withItems
        )
        XCTAssertEqual(run.candidates.count, 1)
        XCTAssertEqual(run.candidates[0].classification, .markedLegadoShell)
        XCTAssertFalse(run.candidates[0].allowlistItemMatched)
    }

    func testUnmarkedThreeKeyRequiresFullAllowlistMatch() throws {
        let shell: [String: Any] = [
            "sourceName": "历史壳",
            "sourceType": "0",
            "sourceUrl": "https://legacy.example/x",
        ]
        let fp = LegacyNativeShellMigrator.fingerprint(entryName: "历史壳", model: shell)
        XCTAssertEqual(fp.classification, .unmarkedThreeKeyShell)

        let snapshot = ["历史壳": shell]
        let partial = LegacyNativeShellMigrator.AllowlistItem(
            entryName: "历史壳",
            topLevelKeysSorted: fp.topLevelKeysSorted,
            entrySHA256: fp.entrySHA256,
            bookWorldSHA256: fp.bookWorldSHA256,
            firstSeenBuild: contractBuild,
            evidencePath: ".artifacts/reverse-xiangse/locator-complete/gap_pack_GAP-08_locator-complete.json",
            evidenceSHA256: "b7c9baabe70ff8e9c1ce8cbdb5ea32df3dc9374f457e51b0ca43d3c9c5a3dafc",
            markerExpected: true
        )
        var doc = try LegacyNativeShellMigrator.loadBundledAllowlist()
        doc.items = [partial]
        let miss = try LegacyNativeShellMigrator.dryRun(rawManagerSnapshot: snapshot, allowlist: doc)
        XCTAssertTrue(miss.candidates.isEmpty, "markerExpected 不一致不得命中")

        let full = syntheticItem(name: "历史壳", model: shell, markerExpected: false)
        doc.items = [full]
        let hit = try LegacyNativeShellMigrator.dryRun(rawManagerSnapshot: snapshot, allowlist: doc)
        XCTAssertEqual(hit.candidates.count, 1)
        XCTAssertEqual(hit.candidates[0].classification, .allowlistAuthorized)
        XCTAssertTrue(hit.candidates[0].allowlistItemMatched)
    }

    func testHashOneBitMismatchDoesNotMatch() throws {
        let shell: [String: Any] = [
            "sourceName": "壳A",
            "sourceType": "0",
            "sourceUrl": "https://legacy.example/a",
        ]
        let fp = LegacyNativeShellMigrator.fingerprint(entryName: "壳A", model: shell)
        var badHash = fp.entrySHA256
        if let last = badHash.popLast() {
            badHash.append(last == "a" ? "b" : "a")
        }
        var doc = try LegacyNativeShellMigrator.loadBundledAllowlist()
        doc.items = [
            LegacyNativeShellMigrator.AllowlistItem(
                entryName: fp.entryName,
                topLevelKeysSorted: fp.topLevelKeysSorted,
                entrySHA256: badHash,
                bookWorldSHA256: fp.bookWorldSHA256,
                firstSeenBuild: contractBuild,
                evidencePath: doc.evidencePath,
                evidenceSHA256: doc.evidenceSHA256,
                markerExpected: false
            ),
        ]
        let run = try LegacyNativeShellMigrator.dryRun(
            rawManagerSnapshot: ["壳A": shell],
            allowlist: doc
        )
        XCTAssertTrue(run.candidates.isEmpty)
    }

    // MARK: - empty allowlist noop

    func testBundledEmptyAllowlistNoop() throws {
        let doc = try LegacyNativeShellMigrator.loadBundledAllowlist()
        XCTAssertTrue(doc.items.isEmpty)
        XCTAssertEqual(doc.selectedBranch, "empty-unmarked-allowlist-noop")

        let shell: [String: Any] = [
            "sourceName": "x",
            "sourceType": "0",
            "sourceUrl": "https://x",
        ]
        let run = try LegacyNativeShellMigrator.dryRun(
            rawManagerSnapshot: ["x": shell],
            allowlist: doc
        )
        XCTAssertEqual(run.allowlistItemCount, 0)
        XCTAssertTrue(run.candidates.isEmpty)

        let apply = try LegacyNativeShellMigrator.apply(
            dryRunResult: run,
            backup: nil,
            rawManagerSnapshot: ["x": shell],
            allowlist: doc
        )
        XCTAssertEqual(apply, .noopEmptyAllowlist)
    }

    // MARK: - apply safety (不调用真机 migration)

    func testApplyRejectedWithoutBackup() throws {
        let shell: [String: Any] = [
            XiangseAdapter.legadoMarkerKey: XiangseAdapter.legadoMarkerValue,
            "sourceName": "m",
            "sourceType": "0",
            "sourceUrl": "https://m",
        ]
        var doc = try LegacyNativeShellMigrator.loadBundledAllowlist()
        doc.items = [syntheticItem(name: "m", model: shell, markerExpected: true)]
        let snapshot = ["m": shell]
        let dry = try LegacyNativeShellMigrator.dryRun(rawManagerSnapshot: snapshot, allowlist: doc)
        XCTAssertFalse(dry.candidates.isEmpty)

        let result = try LegacyNativeShellMigrator.apply(
            dryRunResult: dry,
            backup: nil,
            rawManagerSnapshot: snapshot,
            allowlist: doc
        )
        XCTAssertEqual(result, .rejectedMissingBackup)
    }

    func testApplyRejectedChecksumMismatch() throws {
        let shell: [String: Any] = [
            XiangseAdapter.legadoMarkerKey: XiangseAdapter.legadoMarkerValue,
            "sourceName": "m",
            "sourceType": "0",
            "sourceUrl": "https://m",
        ]
        var doc = try LegacyNativeShellMigrator.loadBundledAllowlist()
        doc.items = [syntheticItem(name: "m", model: shell, markerExpected: true)]
        let snapshot = ["m": shell]
        let dry = try LegacyNativeShellMigrator.dryRun(rawManagerSnapshot: snapshot, allowlist: doc)
        let backup = try LegacyNativeShellMigrator.makeBackup(rawManagerSnapshot: ["other": shell])
        let result = try LegacyNativeShellMigrator.apply(
            dryRunResult: dry,
            backup: backup,
            rawManagerSnapshot: snapshot,
            allowlist: doc
        )
        XCTAssertEqual(result, .rejectedChecksumMismatch)
    }

    func testApplyNoopWhenNoCandidates() throws {
        let snapshot = ["x": ["a": 1] as [String: Any]]
        var doc = try LegacyNativeShellMigrator.loadBundledAllowlist()
        doc.items = [
            LegacyNativeShellMigrator.AllowlistItem(
                entryName: "ghost",
                topLevelKeysSorted: ["a"],
                entrySHA256: "00",
                bookWorldSHA256: nil,
                firstSeenBuild: contractBuild,
                evidencePath: doc.evidencePath,
                evidenceSHA256: doc.evidenceSHA256,
                markerExpected: false
            ),
        ]
        let dry = try LegacyNativeShellMigrator.dryRun(rawManagerSnapshot: snapshot, allowlist: doc)
        XCTAssertTrue(dry.candidates.isEmpty)
        let backup = try LegacyNativeShellMigrator.makeBackup(rawManagerSnapshot: snapshot)
        let result = try LegacyNativeShellMigrator.apply(
            dryRunResult: dry,
            backup: backup,
            rawManagerSnapshot: snapshot,
            allowlist: doc
        )
        XCTAssertEqual(result, .noopNoCandidates)
    }

    // MARK: - helpers

    private func emptyAllowlist() -> LegacyNativeShellMigrator.AllowlistDocument {
        LegacyNativeShellMigrator.AllowlistDocument(
            schemaVersion: 1,
            contractID: "legacy-shell-identity",
            selectedBranch: "empty-unmarked-allowlist-noop",
            hashAlgorithm: LegacyNativeShellMigrator.checksumAlgorithm,
            firstSeenBuild: contractBuild,
            evidencePath: ".artifacts/reverse-xiangse/locator-complete/gap_pack_GAP-08_locator-complete.json",
            evidenceSHA256: "b7c9baabe70ff8e9c1ce8cbdb5ea32df3dc9374f457e51b0ca43d3c9c5a3dafc",
            items: []
        )
    }

    private func syntheticItem(
        name: String,
        model: [String: Any],
        markerExpected: Bool
    ) -> LegacyNativeShellMigrator.AllowlistItem {
        let fp = LegacyNativeShellMigrator.fingerprint(entryName: name, model: model)
        return LegacyNativeShellMigrator.AllowlistItem(
            entryName: fp.entryName,
            topLevelKeysSorted: fp.topLevelKeysSorted,
            entrySHA256: fp.entrySHA256,
            bookWorldSHA256: fp.bookWorldSHA256,
            firstSeenBuild: contractBuild,
            evidencePath: ".artifacts/reverse-xiangse/locator-complete/gap_pack_GAP-08_locator-complete.json",
            evidenceSHA256: "b7c9baabe70ff8e9c1ce8cbdb5ea32df3dc9374f457e51b0ca43d3c9c5a3dafc",
            markerExpected: markerExpected
        )
    }
}
