import XCTest
@testable import LegadoBridge

final class PostCoreBridgeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SourceSessionCoordinator.shared.resetForTests()
        LegadoBridgeCore.shared.selectedExploreSourceUrl = nil
        SourceRegistry.shared.resetForTesting(clearPersistFile: true)
        BookBindingStore.shared.resetForTesting(clearPersistFile: true)
        ReplaceRuleStore.shared.resetForTesting(clearPersistFile: true)
    }

    override func tearDown() {
        LegadoBridgeCore.shared.selectedExploreSourceUrl = nil
        SourceSessionCoordinator.shared.resetForTests()
        SourceRegistry.shared.resetForTesting(clearPersistFile: true)
        BookBindingStore.shared.resetForTesting(clearPersistFile: true)
        ReplaceRuleStore.shared.resetForTesting(clearPersistFile: true)
        super.tearDown()
    }

    func testGroupFilterAndExploreFlag() throws {
        let a: [String: Any] = [
            "bookSourceUrl": "https://example.com/g1",
            "bookSourceName": "分组源",
            "bookSourceGroup": "玄幻",
            "searchUrl": "https://example.com/s?q={{key}}",
            "exploreUrl": "https://example.com/explore",
            "enabledExplore": true,
            "ruleSearch": ["bookList": ".item"],
            "ruleExplore": ["bookList": ".item", "name": ".n"]
        ]
        let b: [String: Any] = [
            "bookSourceUrl": "https://example.com/g2",
            "bookSourceName": "无分组源",
            "searchUrl": "https://example.com/s2?q={{key}}",
            "ruleSearch": ["bookList": ".item"]
        ]
        let data = try JSONSerialization.data(withJSONObject: [a, b])
        XCTAssertEqual(try SourceRegistry.shared.importJSONData(data), 2)

        let groups = SourceRegistry.shared.allGroups()
        XCTAssertEqual(groups, ["玄幻"])

        let filtered = SourceRegistry.shared.allSourcesInfoDicts(groupFilter: "玄幻")
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0]["bookSourceName"] as? String, "分组源")
        XCTAssertEqual(filtered[0]["exploreSupported"] as? Bool, true)

        let ungrouped = SourceRegistry.shared.allSourcesInfoDicts(groupFilter: "__ungrouped__")
        XCTAssertEqual(ungrouped.count, 1)
        XCTAssertEqual(ungrouped[0]["bookSourceName"] as? String, "无分组源")

        let explore = SourceRegistry.shared.exploreCapableSources()
        XCTAssertEqual(explore.count, 1)
        XCTAssertEqual(explore.first?.bookSourceUrl, "https://example.com/g1")
    }

    func testMatchChapterViaCore() {
        let core = LegadoBridgeCore.shared
        let dict = core.matchChapter(
            title: "第二章",
            index: -1,
            chapterTitles: ["第一章", "第二章", "第三章"],
            chapterUrls: ["u1", "u2", "u3"]
        )
        XCTAssertEqual(dict?["index"] as? Int, 1)
        XCTAssertEqual(dict?["url"] as? String, "u2")
    }

    func testReplaceRuleStoreImportAndPurify() throws {
        let json = #"[{"name":"去广告","pattern":"广告位","replacement":"","isRegex":false}]"#
        XCTAssertEqual(try ReplaceRuleStore.shared.importJSON(json), 1)
        let out = ReplaceRuleStore.shared.purify("正文广告位尾")
        XCTAssertEqual(out, "正文尾")
        XCTAssertEqual(LegadoBridgeCore.shared.replaceRulesCount, 1)
    }

    func testSwitchRebindsBookSource() throws {
        let old = try BookBindingStore.shared.bind(
            bookUrl: "https://book/old",
            sourceUrl: "https://src/old",
            sourceName: "旧源",
            name: "测试书",
            author: "作者"
        )
        XCTAssertTrue(old.sourceAvailable)
        // 模拟换源后的新绑定（网络路径由真机测；此处验 Store 语义）
        _ = try BookBindingStore.shared.bind(
            bookUrl: "https://book/old",
            sourceUrl: "https://src/old",
            sourceName: "旧源",
            name: "测试书",
            author: "作者",
            bridgeToken: old.bridgeToken,
            sourceAvailable: false
        )
        let neu = try BookBindingStore.shared.bind(
            bookUrl: "https://book/new",
            sourceUrl: "https://src/new",
            sourceName: "新源",
            name: "测试书",
            author: "作者"
        )
        XCTAssertEqual(neu.sourceUrl, "https://src/new")
        XCTAssertEqual(BookBindingStore.shared.binding(forBookUrl: "https://book/old")?.sourceAvailable, false)
        XCTAssertEqual(BookBindingStore.shared.binding(forBookUrl: "https://book/new")?.sourceAvailable, true)
    }

    func testRegistryMutationsBumpGenerationAndClearSelectedExactSource() throws {
        let core = LegadoBridgeCore.shared
        let url = "https://source.example/mutation"
        let source: [String: Any] = [
            "bookSourceUrl": url,
            "bookSourceName": "变更源",
            "searchUrl": "\(url)/search?q={{key}}",
            "ruleSearch": ["bookList": ".item"]
        ]
        let data = try JSONSerialization.data(withJSONObject: source)

        let beforeImport = SourceSessionCoordinator.shared.currentRegistryGeneration()
        XCTAssertEqual(try core.importLegadoJSONDataThrowing(data), 1)
        XCTAssertEqual(
            SourceSessionCoordinator.shared.currentRegistryGeneration(),
            beforeImport + 1
        )

        core.selectedExploreSourceUrl = url
        XCTAssertEqual(core.selectedExploreSourceUrl, url)

        core.setSourceEnabled(url, enabled: false)
        XCTAssertEqual(
            SourceSessionCoordinator.shared.currentRegistryGeneration(),
            beforeImport + 2
        )
        XCTAssertNil(core.selectedExploreSourceUrl)
        XCTAssertNil(SourceRegistry.shared.source(forUrl: url))

        // Idempotent disable is not a registry mutation and must not keep
        // invalidating captured tokens.
        core.setSourceEnabled(url, enabled: false)
        XCTAssertEqual(
            SourceSessionCoordinator.shared.currentRegistryGeneration(),
            beforeImport + 2
        )

        core.setSourceEnabled(url, enabled: true)
        XCTAssertEqual(
            SourceSessionCoordinator.shared.currentRegistryGeneration(),
            beforeImport + 3
        )
        core.removeSource(url)
        XCTAssertEqual(
            SourceSessionCoordinator.shared.currentRegistryGeneration(),
            beforeImport + 4
        )
        core.removeSource(url)
        XCTAssertEqual(
            SourceSessionCoordinator.shared.currentRegistryGeneration(),
            beforeImport + 4
        )
    }

    func testCoordinatorFailsClosedForDisabledAndRemovedExactSource() throws {
        let core = LegadoBridgeCore.shared
        let c = SourceSessionCoordinator.shared
        let url = "https://source.example/coordinator-availability"
        let source: [String: Any] = [
            "bookSourceUrl": url,
            "bookSourceName": "会话源",
            "searchUrl": "\(url)/search?q={{key}}",
            "ruleSearch": ["bookList": ".item"]
        ]
        let data = try JSONSerialization.data(withJSONObject: source)
        XCTAssertEqual(try core.importLegadoJSONDataThrowing(data), 1)

        let selected = c.applySelection(SelectionToken(sourceKind: .legado, canonicalID: url))
        XCTAssertEqual(selected.sourceKind, .legado)
        let bound = c.bindTestLegadoPublishIdentity(exactSourceUrl: url)!

        core.setSourceEnabled(url, enabled: false)
        XCTAssertNil(c.currentToken(exactSourceUrl: url))
        guard case .failure(let disabledReason) = c.requestPublishPermit(for: bound, isFirstPage: true) else {
            return XCTFail("disabled source must reject the captured permit")
        }
        XCTAssertEqual(disabledReason, .routeFailClosed)

        core.setSourceEnabled(url, enabled: true)
        // Re-enabling is a registry mutation, not a new selection.  The
        // coordinator tombstone must keep the route unavailable until the
        // picker submits a fresh exact selection.
        XCTAssertNil(c.currentToken(exactSourceUrl: url))
        let reselected = c.applySelection(SelectionToken(sourceKind: .legado, canonicalID: url))
        XCTAssertEqual(reselected.sourceKind, .legado)
        core.removeSource(url)
        XCTAssertNil(c.currentToken(exactSourceUrl: url))
        guard case .failure(let removedReason) = c.requestPublishPermit(for: reselected, isFirstPage: true) else {
            return XCTFail("removed source must reject the pre-remove token")
        }
        XCTAssertEqual(removedReason, .routeFailClosed)

        // Re-importing the same exact URL does not silently reactivate the
        // old session; only another exact selection can clear the tombstone.
        XCTAssertEqual(try core.importLegadoJSONDataThrowing(data), 1)
        XCTAssertNil(c.currentToken(exactSourceUrl: url))
        let removed = c.applySelection(SelectionToken(sourceKind: .legado, canonicalID: url))
        XCTAssertEqual(removed.sourceKind, .legado)
        XCTAssertNotNil(c.currentToken(exactSourceUrl: url))
    }

    func testSelectedSourceSetterRejectsMissingAndDisabledIdentity() throws {
        let core = LegadoBridgeCore.shared
        let url = "https://source.example/selected-identity"
        let source: [String: Any] = [
            "bookSourceUrl": url,
            "bookSourceName": "选择源",
            "searchUrl": "\(url)/search?q={{key}}",
            "ruleSearch": ["bookList": ".item"]
        ]
        let data = try JSONSerialization.data(withJSONObject: source)
        XCTAssertEqual(try core.importLegadoJSONDataThrowing(data), 1)

        core.selectedExploreSourceUrl = "https://source.example/not-present"
        XCTAssertNil(core.selectedExploreSourceUrl)
        core.selectedExploreSourceUrl = url
        XCTAssertEqual(core.selectedExploreSourceUrl, url)
        core.setSourceEnabled(url, enabled: false)
        XCTAssertNil(core.selectedExploreSourceUrl)
    }

    func testWarmupCommitDropsMutationDuringInflightResult() throws {
        let core = LegadoBridgeCore.shared
        let c = SourceSessionCoordinator.shared
        let url = "https://source.example/warmup-epoch"
        let source: [String: Any] = [
            "bookSourceUrl": url,
            "bookSourceName": "预热源",
            "searchUrl": "\(url)/search?q={{key}}",
            "exploreUrl": "\(url)/explore",
            "ruleSearch": ["bookList": ".item"],
            "ruleExplore": ["bookList": ".item"]
        ]
        let data = try JSONSerialization.data(withJSONObject: source)
        XCTAssertEqual(try core.importLegadoJSONDataThrowing(data), 1)

        let capturedGeneration = c.currentRegistryGeneration()
        // Materialize the per-source epoch as a warmup would before the
        // worker starts.  No WebView/JS execution is needed for this
        // deterministic commit-gate test.
        core.invalidateExploreKindsCache(forSourceUrl: url)
        let capturedEpoch = core.exploreKindsCancellationEpochForSourceUrl(url)

        core.setSourceEnabled(url, enabled: false)
        XCTAssertFalse(core.commitExploreKindsWarmup(
            exactSourceUrl: url,
            fingerprint: "\(url)/explore",
            registryGeneration: capturedGeneration,
            cancellationEpoch: capturedEpoch,
            json: "[{\"title\":\"过期\",\"url\":\"\(url)/old\"}]",
            failed: false
        ))
        XCTAssertEqual(core.exploreKindsJSON(forSourceUrl: url), "[]")
    }

    func testWarmupDeliveryGuardDropsMutationAfterCommit() throws {
        let core = LegadoBridgeCore.shared
        let c = SourceSessionCoordinator.shared
        let url = "https://source.example/warmup-delivery-epoch"
        let fingerprint = "\(url)/explore"
        let source: [String: Any] = [
            "bookSourceUrl": url,
            "bookSourceName": "预热通知源",
            "searchUrl": "\(url)/search?q={{key}}",
            "exploreUrl": fingerprint,
            "ruleSearch": ["bookList": ".item"],
            "ruleExplore": ["bookList": ".item"]
        ]
        let data = try JSONSerialization.data(withJSONObject: source)
        XCTAssertEqual(try core.importLegadoJSONDataThrowing(data), 1)

        let capturedGeneration = c.currentRegistryGeneration()
        core.invalidateExploreKindsCache(forSourceUrl: url)
        let capturedEpoch = core.exploreKindsCancellationEpochForSourceUrl(url)
        XCTAssertTrue(core.commitExploreKindsWarmup(
            exactSourceUrl: url,
            fingerprint: fingerprint,
            registryGeneration: capturedGeneration,
            cancellationEpoch: capturedEpoch,
            json: "[{\"title\":\"新鲜\",\"url\":\"\(url)/fresh\"}]",
            failed: false
        ))
        XCTAssertTrue(core.isExploreKindsWarmupStillCurrent(
            exactSourceUrl: url,
            fingerprint: fingerprint,
            registryGeneration: capturedGeneration,
            cancellationEpoch: capturedEpoch
        ))

        // Simulate a registry mutation after the worker committed but before
        // its already-enqueued main-queue delivery runs.  The delivery guard
        // must reject the old generation/epoch, so no stale notification or
        // empty-hint side effect is allowed to reach the discover host.
        core.setSourceEnabled(url, enabled: false)
        XCTAssertFalse(core.isExploreKindsWarmupStillCurrent(
            exactSourceUrl: url,
            fingerprint: fingerprint,
            registryGeneration: capturedGeneration,
            cancellationEpoch: capturedEpoch
        ))
    }
}
