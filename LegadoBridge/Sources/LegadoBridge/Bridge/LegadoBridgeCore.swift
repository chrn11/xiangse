import Foundation
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif
import LegadoRuleCore
import LegadoBridgeHooks

/// 一次性 claim 标志（超时竞赛用，不可嵌在泛型函数内）
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// 单源搜索结果盒（信号量超时路径）
private final class SearchOutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<[SearchBookResult], Error>?
    func set(_ v: Result<[SearchBookResult], Error>) {
        lock.lock(); value = v; lock.unlock()
    }
    func get() -> Result<[SearchBookResult], Error>? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

/// LegadoBridge 对外门面 — Swift 与 ObjC Hook 层统一入口
@objc public final class LegadoBridgeCore: NSObject {
    @objc public static let shared = LegadoBridgeCore()
    @objc public static let bridgeVersion = "1.0.0-mvp"

    /// 会话缓存按 BookIdentity 索引；禁止 bookUrl-only 猜源。
    private var bookCache: [BookIdentity: BridgeBook] = [:]
    /// `restorePersistedSources` may be reached by more than one launch hook;
    /// the same restored registry must invalidate the coordinator only once.
    private var didBumpRestoreRegistryGeneration = false
    private let restoreGenerationLock = NSLock()
    private let queue = DispatchQueue(label: "com.xiangse.legado-bridge", qos: .userInitiated)
    /// 搜索 marker 文件写锁（超时线程与搜索线程并发追加）
    private let searchMarkerLock = NSLock()
    /// 并发 explore 世代号：后发请求作废先发的 clear/inject（委托 SourceSessionCoordinator）。
    private var sExploreGeneration: UInt64 = 0
    private var sExploreGenerationSourceUrl: String = ""
    /// explore 防抖：同源短时间只执行最后一次（切源回调+深链+原生回调并发触发）
    private var sLastExploreKey: String = ""
    private var sLastExploreAt: TimeInterval = 0
    /// 发现分类缓存：sourceUrl → (exploreUrl 指纹, JSON)
    /// - Note: TC-05 起持久 last-good 由 ExploreCatalogStore 承担；此内存表仅作过渡 facade。
    private var exploreKindsCache: [String: (fingerprint: String, json: String)] = [:]
    private var exploreKindsWarming: Set<String> = []
    /// 预热失败（空分类）节流：sourceUrl → 失败时间；30s 内不重复预热
    private var exploreKindsWarmFailedAt: [String: TimeInterval] = [:]
    /// Per-source cancellation epochs invalidate an in-flight JS warmup even
    /// when its worker started before the registry mutation was observed.
    private var exploreKindsCancellationEpoch: [String: UInt64] = [:]
    private let exploreKindsCacheQueue = DispatchQueue(label: "com.xiangse.legado-bridge.explore-kinds")
    /// UserDefaults is thread-safe for individual operations, but a getter
    /// that clears a stale selection can otherwise race a picker setter and
    /// erase a newly selected source.  Serialize the read/validate/clear
    /// transaction as one critical section.
    private let selectedExploreSourceLock = NSLock()
    /// 分类预热完成（userInfo: sourceUrl）
    @objc public static let exploreKindsDidUpdateNotification = Notification.Name("LegadoExploreKindsDidUpdate")
    /// ObjC / KVO 用通知名字符串
    @objc public static let exploreKindsDidUpdateNotificationName = "LegadoExploreKindsDidUpdate"

    /// 注入用 ExploreCatalogStore（测试可替换）；默认 Application Support 子目录。
    public var exploreCatalogStore: ExploreCatalogStore = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("LegadoBridge", isDirectory: true)
        return ExploreCatalogStore(persistenceRoot: root)
    }()


    // MARK: - Explore catalog typed last-good (Swift Core phase A)

    /// Stable disk identity for one Legado explore first page.  No process
    /// permit is embedded here; publication still requires a fresh coordinator
    /// issuance after cold read.
    func exploreCatalogLookupKey(
        for session: SourceSessionToken
    ) -> ExploreCatalogStore.CacheLookupKey? {
        guard session.sourceKind == .legado,
              let nodeID = session.nodeID, !nodeID.isEmpty else {
            return nil
        }
        return ExploreCatalogStore.CacheLookupKey(
            canonicalID: session.canonicalID,
            exactURL: session.exactSourceUrl,
            nodeID: nodeID,
            page: max(session.page, 1)
        )
    }

    /// Issue a one-shot persist authorization **before** the network first page
    /// is admitted.  After `requestPublishPermit` succeeds the coordinator
    /// clears the live slot, so the captured token is what `writeLastGood`
    /// must retain.  Mode is fixed to `.cacheFallback` — callers cannot pick.
    func issueExploreCatalogPersistPermit(
        for session: SourceSessionToken
    ) -> CachePermitToken? {
        guard session.page == 1,
              let key = exploreCatalogLookupKey(for: session) else {
            return nil
        }
        let envelopeKeyHash = ExploreCatalogStore.stableFilename(for: key)
        switch SourceSessionCoordinator.shared.issueCachePermit(
            for: session,
            mode: .cacheFallback,
            envelopeKeyHash: envelopeKeyHash
        ) {
        case .success(let token):
            return token
        case .failure:
            return nil
        }
    }

    /// Persist a network-admitted first page under the pre-issued typed permit.
    /// Empty books are refused by the store; failures are marker-only and must
    /// not undo the already-published network UI.
    @discardableResult
    func persistExploreCatalogLastGood(
        session: SourceSessionToken,
        books: [[String: Any]],
        permit: CachePermitToken
    ) -> Bool {
        guard session.page == 1,
              !books.isEmpty,
              let key = exploreCatalogLookupKey(for: session),
              JSONSerialization.isValidJSONObject(books),
              let payload = try? JSONSerialization.data(withJSONObject: books) else {
            return false
        }
        do {
            _ = try exploreCatalogStore.writeLastGood(
                key: key,
                token: permit,
                payload: payload
            )
            writeSearchMarker(
                "explore catalog persist ok node=\(key.nodeID) n=\(books.count)"
            )
            return true
        } catch {
            writeSearchMarker(
                "explore catalog persist fail \(error.localizedDescription)"
            )
            return false
        }
    }

    /// Cold read only.  The persisted permit is never reusable for publication;
    /// callers must ask the coordinator for a fresh `.coldLastGood` issuance.
    func readExploreCatalogColdLastGood(
        for session: SourceSessionToken,
        now: Date = Date()
    ) -> ExploreCatalogStore.CacheEnvelope? {
        guard let key = exploreCatalogLookupKey(for: session) else { return nil }
        return exploreCatalogStore.readColdLastGood(key: key, now: now)
    }

    /// Scene decides mode.  Callers outside Core cannot pick `.cacheFallback`
    /// vs `.coldLastGood`.
    enum ExploreCatalogCacheScene {
        case coldStart
        case networkFallback

        var mode: ExplorePublishMode {
            switch self {
            case .coldStart: return .coldLastGood
            case .networkFallback: return .cacheFallback
            }
        }
    }

    func issueExploreCatalogCachePublishPermit(
        for session: SourceSessionToken,
        scene: ExploreCatalogCacheScene
    ) -> CachePermitToken? {
        guard session.page == 1,
              let key = exploreCatalogLookupKey(for: session) else {
            return nil
        }
        let envelopeKeyHash = ExploreCatalogStore.stableFilename(for: key)
        switch SourceSessionCoordinator.shared.issueCachePermit(
            for: session,
            mode: scene.mode,
            envelopeKeyHash: envelopeKeyHash
        ) {
        case .success(let token):
            return token
        case .failure:
            return nil
        }
    }

    func decodeExploreCatalogBooks(
        _ envelope: ExploreCatalogStore.CacheEnvelope
    ) -> [[String: Any]]? {
        guard let obj = try? JSONSerialization.jsonObject(with: envelope.payload),
              let books = obj as? [[String: Any]],
              !books.isEmpty else {
            return nil
        }
        return books
    }

    func prepareExploreCatalogCacheHit(
        session: SourceSessionToken,
        scene: ExploreCatalogCacheScene
    ) -> (permit: CachePermitToken, books: [[String: Any]])? {
        guard session.page == 1,
              let envelope = readExploreCatalogColdLastGood(for: session),
              let books = decodeExploreCatalogBooks(envelope),
              let permit = issueExploreCatalogCachePublishPermit(
                for: session,
                scene: scene
              ) else {
            return nil
        }
        return (permit, books)
    }

    /// Store → fresh typed permit → exact owner/session → cache UI lane.
    @discardableResult
    func publishExploreCatalogCacheHit(
        session: SourceSessionToken,
        scene: ExploreCatalogCacheScene
    ) -> Bool {
        guard let prepared = prepareExploreCatalogCacheHit(
            session: session,
            scene: scene
        ) else {
            return false
        }
        LBApplySearchResultsToUIWithCapturedCacheToken(
            prepared.books,
            "explore",
            LBSharedSourceRouter.cachePermitDictionary(prepared.permit)
        )
        writeSearchMarker(
            "explore catalog cache hit mode=\(prepared.permit.mode.rawValue) n=\(prepared.books.count)"
        )
        return true
    }

    private override init() {
        super.init()
        // 禁止在 init 内 restore / sync：
        // 1) restore → JSONSerialization → JSON Hook → 再取 shared，重入 static let 的 dispatch_once → SIGTRAP
        // 2) sync → dicModelList Hook → 再取 shared，同上
        // 磁盘恢复改由 didFinishLaunching 的 restorePersistedSources（shared 已就绪后）触发。
    }

    /// 供 ObjC 在触发 shared 前做轻量探测，避免无关键 JSON 解析路径拉起 Core
    @objc(probeLegadoJSONData:)
    public class func probeLegadoJSONData(_ data: Data) -> Bool {
        SourceRegistry.isLegadoJSONData(data)
    }

    /// 供 ObjC Hook 在 didFinishLaunching 显式触发恢复（与 init 幂等）
    @objc(restorePersistedSources)
    @discardableResult
    public func restorePersistedSources() -> Int {
        Self.wireBrowserAwaitIfNeeded()
        let count = SourceRegistry.shared.restoreFromDiskIfNeeded()
        let shouldBumpRestoreGeneration: Bool = {
            restoreGenerationLock.lock()
            defer { restoreGenerationLock.unlock() }
            if count > 0, !didBumpRestoreRegistryGeneration {
                didBumpRestoreRegistryGeneration = true
                return true
            }
            if count == 0 {
                // A missing/invalid file is retryable; do not consume the
                // generation bump until a later hook actually restores data.
                didBumpRestoreRegistryGeneration = false
            }
            return false
        }()
        if shouldBumpRestoreGeneration {
            // Restoring the registry invalidates captured Legado permits and
            // any in-memory explore definition derived from an older source.
            // Keep this as one batch bump for the whole restore.
            noteRegistryMutation(invalidateAllExploreKinds: true)
        }
        // 书籍绑定与书源分文件；启动时一并恢复，避免重启串源
        _ = BookBindingStore.shared.restoreFromDiskIfNeeded()
        _ = ReplaceRuleStore.shared.restoreFromDiskIfNeeded()
        BookVariableStore.restoreFromDiskIfNeeded()
        ReplaceRuleStore.shared.installPresetsIfEmpty()
        if count > 0 {
            let enabled = SourceRegistry.shared.allSources().filter {
                SourceRegistry.shared.isEnabled(url: $0.bookSourceUrl)
            }
            // D0/TC-06：禁止启动写 manager；只刷新 ephemeral projection
            NativeSourceInjector.syncToNativeManagerWhenReady(sources: enabled)
        }
        return count
    }

    /// 把香色可见 WebView 接到 java.startBrowserAwait
    private static func wireBrowserAwaitIfNeeded() {
        guard BrowserAwaitGate.handler == nil else { return }
        BrowserAwaitGate.handler = { url, title, sourceUrl in
            LBStartBrowserAwait(url, sourceUrl, title, 180) ?? ""
        }
    }

    // MARK: - 书籍绑定（native-flow）

    /// 搜索/详情记住 pair↔token；落盘后重启可反查。空 key 返回空串（typed error，不再 lb_invalid）。
    @objc(rememberBookBindingWithBookUrl:sourceUrl:sourceName:name:author:coverUrl:bridgeToken:)
    @discardableResult
    public func rememberBookBinding(
        bookUrl: String,
        sourceUrl: String,
        sourceName: String?,
        name: String?,
        author: String?,
        coverUrl: String?,
        bridgeToken: String?
    ) -> String {
        do {
            let identity = try BookIdentity(exactSourceUrl: sourceUrl, exactBookUrl: bookUrl)
            let now = Date()
            var v2 = BookBindingV2(
                identity: identity,
                bridgeToken: identity.bridgeTokenV2,
                sourceNameSnapshot: sourceName,
                name: name,
                author: author,
                coverUrl: coverUrl,
                sourceAvailable: true,
                createdAt: now,
                updatedAt: now
            )
            if let token = bridgeToken, !token.isEmpty, token == identity.bridgeTokenV2 {
                v2.bridgeToken = token
            }
            switch BookBindingStore.shared.upsertAndFlushSync(v2) {
            case .success(let saved):
                let book = BridgeBook(
                    name: saved.name ?? "",
                    author: saved.author ?? "",
                    bookUrl: saved.bookUrl,
                    coverUrl: saved.coverUrl ?? "",
                    intro: "",
                    sourceUrl: saved.sourceUrl,
                    sourceName: saved.sourceNameSnapshot ?? ""
                )
                bookCache[identity] = book
                return saved.bridgeToken
            case .failure:
                return ""
            }
        } catch {
            return ""
        }
    }

    /// bookUrl-only：仅唯一 legacy 命中时返回；歧义失败。
    @objc(sourceUrlForBookUrl:)
    public func sourceUrl(forBookUrl bookUrl: String) -> String? {
        switch BookBindingStore.shared.uniqueLegacyBinding(forBookUrl: bookUrl) {
        case .success(let binding):
            return binding.sourceUrl
        case .failure:
            return nil
        }
    }

    @objc(sourceUrlForBridgeToken:)
    public func sourceUrl(forBridgeToken token: String) -> String? {
        switch BookBindingStore.shared.binding(forToken: token) {
        case .success(let binding):
            return binding.sourceUrl
        case .failure:
            return nil
        }
    }

    /// 去掉空串/空白，避免 ObjC 传入 "" 时短路 `??` 回退链
    private static func nonEmptyURL(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// §24.2 resolver：token → 显式 pair → legacy 唯一 bookUrl。禁止 originURL / bookCache-by-url / 活动源猜源。
    private func resolveEnabledSource(
        token: String? = nil,
        requested: String?,
        bookUrl: String
    ) -> MemoryBridgeBookSource? {
        if let requested,
           requested.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Explicit empty is malformed identity; only nil may use the
            // binding/book-url convenience resolution below.
            return nil
        }
        let store = BookBindingStore.shared
        switch store.resolveBinding(
            token: token,
            exactSourceUrl: requested,
            bookUrl: bookUrl.isEmpty ? nil : bookUrl
        ) {
        case .success(let binding):
            if let source = SourceRegistry.shared.exactSource(forUrl: binding.sourceUrl),
               SourceRegistry.shared.isEnabled(url: source.bookSourceUrl) {
                return source
            }
            return nil
        case .failure(let err):
            // 显式完整 pair 尚未 durable：用 pair 自身 sourceUrl 精确取源（非 fallback 猜源）
            if err == .notFound || err == .storeNotReady,
               let src = Self.nonEmptyURL(requested),
               let book = Self.nonEmptyURL(bookUrl),
               (try? BookIdentity(exactSourceUrl: src, exactBookUrl: book)) != nil,
               let source = SourceRegistry.shared.exactSource(forUrl: src),
               SourceRegistry.shared.isEnabled(url: source.bookSourceUrl) {
                return source
            }
            return nil
        }
    }

    private func cachedBook(for identity: BookIdentity) -> BridgeBook? {
        bookCache[identity]
    }

    /// 仅当该 bookUrl 在会话缓存中唯一 identity 时返回。
    private func cachedBookUnique(forBookUrl bookUrl: String) -> BridgeBook? {
        let hits = bookCache.filter { $0.key.bookUrl == bookUrl }
        return hits.count == 1 ? hits.first?.value : nil
    }

    @objc(bridgeTokenForBookUrl:)
    public func bridgeToken(forBookUrl bookUrl: String) -> String? {
        switch BookBindingStore.shared.uniqueLegacyBinding(forBookUrl: bookUrl) {
        case .success(let b): return b.bridgeToken
        case .failure: return nil
        }
    }

    @objc(detailDictForBookUrl:)
    public func detailDict(forBookUrl bookUrl: String) -> NSDictionary? {
        switch BookBindingStore.shared.uniqueLegacyBinding(forBookUrl: bookUrl) {
        case .success(let binding):
            return XiangseAdapter.detailDict(from: binding) as NSDictionary
        case .failure:
            return nil
        }
    }

    @objc(isBookSourceAvailable:)
    public func isBookSourceAvailable(_ bookUrl: String) -> Bool {
        switch BookBindingStore.shared.uniqueLegacyBinding(forBookUrl: bookUrl) {
        case .success(let b): return b.sourceAvailable
        case .failure(.ambiguous): return false
        case .failure: return true
        }
    }

    /// 删源策略：0=保留书籍并标记不可用（默认）；1=清除桥接层绑定
    @objc public var sourceDeletePolicyRaw: Int {
        get { BookBindingStore.deletePolicy.rawValue }
        set { BookBindingStore.deletePolicy = SourceDeletePolicy(rawValue: newValue) ?? .keepBooksMarkUnavailable }
    }

    // MARK: - 导入

    @objc(isLegadoJSONData:)
    public func isLegadoJSONData(_ data: Data) -> Bool {
        SourceRegistry.isLegadoJSONData(data)
    }

    @objc(importLegadoJSONData:error:)
    @discardableResult
    public func importLegadoJSONData(_ data: Data, error: NSErrorPointer) -> Int {
        do {
            return try importLegadoJSONDataThrowing(data)
        } catch let err as NSError {
            error?.pointee = err
            return 0
        }
    }

    @discardableResult
    public func importLegadoJSONDataThrowing(_ data: Data) throws -> Int {
        let importedSourceUrls = SourceRegistry.sourceURLs(in: data)
        let count = try SourceRegistry.shared.importJSONData(data)
        if count > 0 {
            noteRegistryMutation(sourceUrls: importedSourceUrls)
        }
        let enabled = SourceRegistry.shared.allSources().filter {
            SourceRegistry.shared.isEnabled(url: $0.bookSourceUrl)
        }
        // 重新导入同源后，恢复此前「书源不可用」标记的绑定
        for s in enabled {
            _ = BookBindingStore.shared.markSourceAvailabilitySync(
                exactSourceUrl: s.bookSourceUrl,
                available: true
            )
        }
        NativeSourceInjector.syncToNativeManager(sources: enabled)
        postNotification(
            XiangseAdapter.notifyUpdateSourceList,
            userInfo: XiangseAdapter.sourceListPayload(sources: enabled)
        )
        return count
    }

    // MARK: - 原生站点列表桥接（供 ObjC Hook 查询）

    @objc(allLegadoSourceNames)
    public func allLegadoSourceNames() -> [String] {
        // 无原生上下文时退回 display 名；合并路径请用 allLegadoListKeysWithNativeNames:
        NativeSourceInjector.allLegadoSourceNames()
    }

    /// 列表合并键：与 nativeNames 冲突时用 projectionKey，禁止 ·Legado 徽章。
    @objc(allLegadoListKeysWithNativeNames:)
    public func allLegadoListKeys(withNativeNames nativeNames: [String]?) -> [String] {
        NativeSourceInjector.listKeys(nativeNames: nativeNames ?? [])
    }

    @objc(isLegadoSourceName:)
    public func isLegadoSourceName(_ name: String) -> Bool {
        NativeSourceInjector.isLegadoSourceName(name)
    }

    @objc(legadoNativeModelForSourceName:)
    public func legadoNativeModel(forSourceName name: String) -> NSDictionary? {
        guard let model = NativeSourceInjector.nativeModel(forSourceName: name) else { return nil }
        return model as NSDictionary
    }

    @objc(displayNameForLegadoListKey:)
    public func displayNameForLegadoListKey(_ key: String) -> String {
        if let model = NativeSourceInjector.nativeModel(forSourceName: key),
           let title = model["title"] as? String, !title.isEmpty {
            return title
        }
        if NativeSourceListProjection.isProjectionKey(key) {
            return NativeSourceInjector.enabledProjections()
                .first(where: { $0.projectionKey == key })?
                .displaySourceName ?? key
        }
        return key
    }

    // MARK: - 书源管理（增删改）

    @objc(removeSource:)
    public func removeSource(_ url: String) {
        let names = SourceRegistry.shared.allSources()
            .filter { $0.bookSourceUrl == url }
            .map(\.bookSourceName)
        let removed = SourceRegistry.shared.removeSource(url: url)
        // Clear a persisted exact selection even when the remove request is
        // already idempotent (the source may have disappeared in another
        // registry owner).
        if selectedExploreSourceUrl == url {
            selectedExploreSourceUrl = nil
        }
        if removed {
            noteRegistryMutation(sourceUrls: Set([url]), invalidateLegadoURLs: Set([url]))
        } else {
            // Another registry owner may already have removed the row.  Still
            // freeze this exact route without manufacturing a second
            // generation bump.
            SourceSessionCoordinator.shared.invalidateLegadoSource(exactSourceUrl: url)
            invalidateExploreKindsCache(forSourceUrl: url)
        }
        // TC-06：生产删源不写 manager；只失效投影
        NativeSourceInjector.removeFromNativeManager(names: names, allowLegacyMigration: false)
        // 删源策略：只标记 sourceAvailable；不删 binding。会话缓存可清该源条目。
        _ = BookBindingStore.shared.markSourceAvailabilitySync(exactSourceUrl: url, available: false)
        bookCache = bookCache.filter { $0.key.sourceUrl != url }
        resyncNativeList()
    }

    @objc(setSourceEnabled:enabled:)
    public func setSourceEnabled(_ url: String, enabled: Bool) {
        let changed = SourceRegistry.shared.setEnabled(url: url, enabled: enabled)
        if !enabled, selectedExploreSourceUrl == url {
            // Selection cleanup is independent of the generation bump: a
            // repeated disable must not retain a stale exact URL in defaults.
            selectedExploreSourceUrl = nil
        }
        if changed {
            noteRegistryMutation(
                sourceUrls: Set([url]),
                invalidateLegadoURLs: enabled ? [] : Set([url])
            )
        }
        // 停用只改 sourceAvailable；不删 binding
        _ = BookBindingStore.shared.markSourceAvailabilitySync(exactSourceUrl: url, available: enabled)
        if changed {
            if enabled {
                resyncNativeList()
            } else {
                let names = SourceRegistry.shared.allSources()
                    .filter { $0.bookSourceUrl == url }
                    .map(\.bookSourceName)
                NativeSourceInjector.removeFromNativeManager(names: names, allowLegacyMigration: false)
            }
        }
    }

    @objc(isSourceEnabled:)
    public func isSourceEnabled(_ url: String) -> Bool {
        SourceRegistry.shared.isEnabled(url: url)
    }

    @objc(sourceJSON:)
    public func sourceJSON(_ url: String) -> String? {
        SourceRegistry.shared.sourceJSON(url: url)
    }

    /// 保存完整 JSON（结构化/JSON 编辑器）；校验通过后落盘并同步原生列表
    @objc(updateSourceJSON:forUrl:error:)
    @discardableResult
    public func updateSourceJSON(_ data: Data, forUrl expectedUrl: String?, error: NSErrorPointer) -> Bool {
        do {
            let newUrl = try SourceRegistry.shared.updateSourceJSON(data, forUrl: expectedUrl)
            var invalidated = Set<String>()
            if let expectedUrl, !expectedUrl.isEmpty {
                invalidated.insert(expectedUrl)
                if expectedUrl != newUrl, selectedExploreSourceUrl == expectedUrl {
                    // The old exact identity no longer exists after a URL
                    // edit; never leave a stale selected source behind.
                    selectedExploreSourceUrl = nil
                }
            }
            invalidated.insert(newUrl)
            noteRegistryMutation(sourceUrls: invalidated)
            resyncNativeList()
            postNotification(
                XiangseAdapter.notifyUpdateSourceList,
                userInfo: XiangseAdapter.sourceListPayload(
                    sources: SourceRegistry.shared.allSources().filter {
                        SourceRegistry.shared.isEnabled(url: $0.bookSourceUrl)
                    }
                )
            )
            _ = newUrl
            return true
        } catch let err as NSError {
            error?.pointee = err
            return false
        }
    }

    /// 结构化字段更新
    @objc(updateStructuredFieldsForUrl:name:searchUrl:group:error:)
    @discardableResult
    public func updateStructuredFields(
        forUrl url: String,
        name: String?,
        searchUrl: String?,
        group: String?,
        error: NSErrorPointer
    ) -> Bool {
        do {
            _ = try SourceRegistry.shared.updateStructuredFields(
                url: url,
                name: name,
                searchUrl: searchUrl,
                group: group
            )
            noteRegistryMutation(sourceUrls: Set([url]))
            resyncNativeList()
            return true
        } catch let err as NSError {
            error?.pointee = err
            return false
        }
    }

    /// 订阅安全更新：保留本地启停；远端消失只标记不删除
    @objc(applySubscriptionJSONData:subscriptionURL:error:)
    @discardableResult
    public func applySubscriptionJSONData(
        _ data: Data,
        subscriptionURL: String,
        error: NSErrorPointer
    ) -> NSDictionary? {
        do {
            let result = try SourceRegistry.shared.applySubscriptionUpdate(
                data: data,
                subscriptionUrl: subscriptionURL
            )
            if result.mutated {
                // A subscription may mark a source missing that is not
                // present in the incoming payload, so invalidate all
                // in-memory explore definitions for this successful batch.
                noteRegistryMutation(invalidateAllExploreKinds: true)
            }
            resyncNativeList()
            return [
                "added": result.added,
                "updated": result.updated,
                "markedMissing": result.markedMissing,
                "unchanged": result.unchanged
            ] as NSDictionary
        } catch let err as NSError {
            error?.pointee = err
            return nil
        }
    }

    /// 所有已注册书源摘要，供管理 VC 列表展示
    @objc public var allSourcesInfo: NSArray {
        SourceRegistry.shared.allSourcesInfoDicts().map { $0 as NSDictionary } as NSArray
    }

    /// 按分组筛选书源摘要；`group` 为空或 `__all__` 表示全部；`__ungrouped__` 表示无分组
    @objc(sourcesInfoFilteredByGroup:)
    public func sourcesInfoFiltered(byGroup group: String?) -> NSArray {
        SourceRegistry.shared.allSourcesInfoDicts(groupFilter: group)
            .map { $0 as NSDictionary } as NSArray
    }

    /// 去重分组名列表
    @objc public var allSourceGroups: [String] {
        SourceRegistry.shared.allGroups()
    }

    private func resyncNativeList() {
        let enabled = SourceRegistry.shared.allSources().filter {
            SourceRegistry.shared.isEnabled(url: $0.bookSourceUrl)
        }
        NativeSourceInjector.syncToNativeManager(sources: enabled)
    }

    /// Record a successful Legado registry mutation without touching the XBS
    /// manager.  Registry generations invalidate captured Legado permits;
    /// explore definition caches are cleared for only the changed identities
    /// unless the operation can affect the whole subscription set.
    private func noteRegistryMutation(
        sourceUrls: Set<String> = [],
        invalidateLegadoURLs: Set<String> = [],
        invalidateAllExploreKinds: Bool = false
    ) {
        for url in invalidateLegadoURLs where !url.isEmpty {
            SourceSessionCoordinator.shared.invalidateLegadoSource(exactSourceUrl: url)
        }
        SourceSessionCoordinator.shared.bumpRegistryGeneration()
        if invalidateAllExploreKinds {
            invalidateExploreKindsCache(forSourceUrl: nil)
        } else {
            for url in sourceUrls where !url.isEmpty {
                invalidateExploreKindsCache(forSourceUrl: url)
            }
        }
    }

    // MARK: - 换源

    /// 纯逻辑章节匹配（夹具 / ObjC 可读结果字典）
    @objc(matchChapterWithTitle:index:chapterTitles:chapterUrls:)
    public func matchChapter(
        title: String?,
        index: Int,
        chapterTitles: [String],
        chapterUrls: [String]
    ) -> NSDictionary? {
        let count = min(chapterTitles.count, chapterUrls.count)
        guard count > 0 else { return nil }
        var chapters: [BridgeChapter] = []
        chapters.reserveCapacity(count)
        for i in 0..<count {
            chapters.append(BridgeChapter(title: chapterTitles[i], url: chapterUrls[i], index: i))
        }
        let idx: Int? = index >= 0 ? index : nil
        guard let match = ChapterMatcher.match(
            currentTitle: title,
            currentIndex: idx,
            chapters: chapters
        ) else { return nil }
        return [
            "index": match.index,
            "title": match.title,
            "url": match.url,
            "score": match.score,
            "strategy": match.strategy
        ] as NSDictionary
    }

    /// 换源：重绑定 bookUrl↔sourceUrl，并对齐章节；异步结果经通知 `LegadoBridgeSourceSwitched`
    @objc(switchBookSourceWithOldBookUrl:newBookUrl:newSourceUrl:chapterTitle:chapterIndex:)
    public func switchBookSource(
        oldBookUrl: String,
        newBookUrl: String,
        newSourceUrl: String,
        chapterTitle: String?,
        chapterIndex: Int
    ) {
        Task {
            do {
                guard let source = SourceRegistry.shared.exactSource(forUrl: newSourceUrl),
                      SourceRegistry.shared.isEnabled(url: source.bookSourceUrl) else {
                    throw LegadoBridgeError.sourceNotFound
                }
                let oldCached = self.cachedBookUnique(forBookUrl: oldBookUrl)
                let old: BookBinding? = {
                    switch BookBindingStore.shared.uniqueLegacyBinding(forBookUrl: oldBookUrl) {
                    case .success(let v2): return BookBinding(from: v2)
                    case .failure: return nil
                    }
                }()
                var book = BridgeBook(
                    name: old?.name ?? oldCached?.name ?? "",
                    author: old?.author ?? oldCached?.author ?? "",
                    bookUrl: newBookUrl,
                    coverUrl: old?.coverUrl ?? oldCached?.coverUrl ?? "",
                    sourceUrl: source.bookSourceUrl,
                    sourceName: source.bookSourceName
                )
                _ = try await BridgeWebBook.getBookInfo(source: source, book: &book)
                let chapters = try await BridgeWebBook.getChapterList(source: source, book: book)
                let match = ChapterMatcher.match(
                    currentTitle: chapterTitle,
                    currentIndex: chapterIndex >= 0 ? chapterIndex : nil,
                    chapters: chapters
                )
                // 换源成功：新增/更新新 pair，旧 pair 保留（不删、不强制不可用）
                let binding = try BookBindingStore.shared.bind(
                    bookUrl: newBookUrl,
                    sourceUrl: source.bookSourceUrl,
                    sourceName: source.bookSourceName,
                    name: book.name.isEmpty ? (old?.name ?? "") : book.name,
                    author: book.author.isEmpty ? (old?.author ?? "") : book.author,
                    coverUrl: book.coverUrl.isEmpty ? (old?.coverUrl ?? "") : book.coverUrl
                )
                if let identity = try? BookIdentity(exactSourceUrl: source.bookSourceUrl, exactBookUrl: newBookUrl) {
                    bookCache[identity] = book
                }
                var info: [String: Any] = [
                    "oldBookUrl": oldBookUrl,
                    "newBookUrl": newBookUrl,
                    "sourceUrl": source.bookSourceUrl,
                    "bridgeToken": binding.bridgeToken,
                    "chapterCount": chapters.count,
                    XiangseAdapter.legadoMarkerKey: XiangseAdapter.legadoMarkerValue
                ]
                if let match {
                    info["matchedIndex"] = match.index
                    info["matchedTitle"] = match.title
                    info["matchedUrl"] = match.url
                    info["matchScore"] = match.score
                    info["matchStrategy"] = match.strategy
                }
                postNotification("LegadoBridgeSourceSwitched", userInfo: info)
                writeSearchMarker(
                    "switch ok \(oldBookUrl) -> \(newBookUrl) src=\(source.bookSourceUrl) match=\(match?.index ?? -1)"
                )
                Self.writeB4SwitchEvidence(
                    book: book.name,
                    oldUrl: oldBookUrl,
                    newUrl: newBookUrl,
                    sourceUrl: source.bookSourceUrl,
                    match: match,
                    chapterCount: chapters.count,
                    error: nil
                )
            } catch {
                postNotification(
                    "LegadoBridgeSourceSwitched",
                    userInfo: [
                        "error": error.localizedDescription,
                        "oldBookUrl": oldBookUrl,
                        "newBookUrl": newBookUrl,
                        XiangseAdapter.legadoMarkerKey: XiangseAdapter.legadoMarkerValue
                    ]
                )
                Self.writeB4SwitchEvidence(
                    book: "",
                    oldUrl: oldBookUrl,
                    newUrl: newBookUrl,
                    sourceUrl: newSourceUrl,
                    match: nil,
                    chapterCount: 0,
                    error: error.localizedDescription
                )
            }
        }
    }

    /// B4：阅读换源 — 按书名在新源搜索，再绑定并对齐章节
    @objc(switchReadingSourceWithBookName:author:oldBookUrl:newSourceUrl:chapterTitle:chapterIndex:)
    public func switchReadingSource(
        bookName: String,
        author: String?,
        oldBookUrl: String,
        newSourceUrl: String,
        chapterTitle: String?,
        chapterIndex: Int
    ) {
        let key = bookName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            postNotification(
                "LegadoBridgeSourceSwitched",
                userInfo: ["error": "书名为空", "oldBookUrl": oldBookUrl, "sourceUrl": newSourceUrl]
            )
            Self.writeB4SwitchEvidence(
                book: "", oldUrl: oldBookUrl, newUrl: "", sourceUrl: newSourceUrl,
                match: nil, chapterCount: 0, error: "书名为空"
            )
            return
        }
        Task {
            do {
                guard let source = SourceRegistry.shared.exactSource(forUrl: newSourceUrl),
                      SourceRegistry.shared.isEnabled(url: source.bookSourceUrl) else {
                    throw LegadoBridgeError.sourceNotFound
                }
                let results = try await BridgeWebBook.searchBook(source: source, key: key)
                let authorNeedle = (author ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let picked: SearchBookResult? = {
                    if !authorNeedle.isEmpty {
                        if let hit = results.first(where: {
                            $0.author.localizedCaseInsensitiveContains(authorNeedle)
                                || authorNeedle.localizedCaseInsensitiveContains($0.author)
                        }) {
                            return hit
                        }
                    }
                    if let hit = results.first(where: {
                        $0.name.localizedCaseInsensitiveContains(key)
                            || key.localizedCaseInsensitiveContains($0.name)
                    }) {
                        return hit
                    }
                    return results.first
                }()
                guard let best = picked, !best.bookUrl.isEmpty else {
                    throw LegadoBridgeError.engineError("新源未搜到《\(key)》")
                }
                writeSearchMarker(
                    "switch search hit name=\(best.name) url=\(best.bookUrl) src=\(source.bookSourceUrl) total=\(results.count)"
                )
                var book = BridgeBook(
                    name: best.name.isEmpty ? key : best.name,
                    author: best.author.isEmpty ? (author ?? "") : best.author,
                    bookUrl: best.bookUrl,
                    coverUrl: best.coverUrl ?? "",
                    sourceUrl: source.bookSourceUrl,
                    sourceName: source.bookSourceName
                )
                _ = try await BridgeWebBook.getBookInfo(source: source, book: &book)
                let chapters = try await BridgeWebBook.getChapterList(source: source, book: book)
                let match = ChapterMatcher.match(
                    currentTitle: chapterTitle,
                    currentIndex: chapterIndex >= 0 ? chapterIndex : nil,
                    chapters: chapters
                )
                if oldBookUrl != best.bookUrl {
                    // 旧 pair 保留；新 pair 另写入
                }
                let binding = try BookBindingStore.shared.bind(
                    bookUrl: book.bookUrl,
                    sourceUrl: source.bookSourceUrl,
                    sourceName: source.bookSourceName,
                    name: book.name,
                    author: book.author,
                    coverUrl: book.coverUrl
                )
                if let identity = try? BookIdentity(exactSourceUrl: source.bookSourceUrl, exactBookUrl: book.bookUrl) {
                    bookCache[identity] = book
                }
                var info: [String: Any] = [
                    "oldBookUrl": oldBookUrl,
                    "newBookUrl": book.bookUrl,
                    "sourceUrl": source.bookSourceUrl,
                    "sourceName": source.bookSourceName,
                    "bridgeToken": binding.bridgeToken,
                    "chapterCount": chapters.count,
                    XiangseAdapter.legadoMarkerKey: XiangseAdapter.legadoMarkerValue
                ]
                if let match {
                    info["matchedIndex"] = match.index
                    info["matchedTitle"] = match.title
                    info["matchedUrl"] = match.url
                    info["matchScore"] = match.score
                    info["matchStrategy"] = match.strategy
                }
                if let first = chapters.first {
                    info["firstTitle"] = first.title
                    info["firstUrl"] = first.url
                }
                postNotification("LegadoBridgeSourceSwitched", userInfo: info)
                writeSearchMarker(
                    "switch ok \(oldBookUrl) -> \(book.bookUrl) src=\(source.bookSourceUrl) match=\(match?.index ?? -1) strategy=\(match?.strategy ?? "-")"
                )
                Self.writeB4SwitchEvidence(
                    book: key,
                    oldUrl: oldBookUrl,
                    newUrl: book.bookUrl,
                    sourceUrl: source.bookSourceUrl,
                    match: match,
                    chapterCount: chapters.count,
                    error: nil
                )
            } catch {
                postNotification(
                    "LegadoBridgeSourceSwitched",
                    userInfo: [
                        "error": error.localizedDescription,
                        "oldBookUrl": oldBookUrl,
                        "sourceUrl": newSourceUrl,
                        "bookName": key
                    ]
                )
                writeSearchMarker("switch reading err \(error.localizedDescription)")
                Self.writeB4SwitchEvidence(
                    book: key,
                    oldUrl: oldBookUrl,
                    newUrl: "",
                    sourceUrl: newSourceUrl,
                    match: nil,
                    chapterCount: 0,
                    error: error.localizedDescription
                )
            }
        }
    }

    private static func writeB4SwitchEvidence(
        book: String,
        oldUrl: String,
        newUrl: String,
        sourceUrl: String,
        match: ChapterMatchResult?,
        chapterCount: Int,
        error: String?
    ) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let body: String
        if let error, !error.isEmpty {
            body = "ts=\(ts)\nerror=\(error)\nbook=\(book)\nold=\(oldUrl)\nsrc=\(sourceUrl)\n"
        } else {
            body = """
            ts=\(ts)
            book=\(book)
            old=\(oldUrl)
            new=\(newUrl)
            src=\(sourceUrl)
            matchIndex=\(match?.index ?? -1)
            matchTitle=\(match?.title ?? "")
            matchStrategy=\(match?.strategy ?? "")
            chapterCount=\(chapterCount)
            """
        }
        let path = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Documents/legado_b4_switch.txt")
        try? body.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - 发现

    /// 当前发现源（点「切换」后写入）；未选择时由 nil 请求按 exact
    /// selection/首个可发现源顺序解析，显式空字符串不参与 fallback。
    @objc public var selectedExploreSourceUrl: String? {
        get {
            selectedExploreSourceLock.lock()
            defer { selectedExploreSourceLock.unlock() }
            guard let selected = UserDefaults.standard.string(forKey: "legado_selected_explore_source"),
                  !selected.isEmpty else {
                return nil
            }
            // Persisted selection is an exact identity.  A removed or
            // disabled source must not silently turn into the current/first
            // source when callers resolve the selection later.
            guard SourceRegistry.shared.exactSource(forUrl: selected) != nil else {
                UserDefaults.standard.removeObject(forKey: "legado_selected_explore_source")
                return nil
            }
            return selected
        }
        set {
            selectedExploreSourceLock.lock()
            defer { selectedExploreSourceLock.unlock() }
            let candidate = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // A persisted selection is an exact, enabled registry identity;
            // never persist an empty, removed, or disabled URL which would
            // later look like an implicit fallback.
            if !candidate.isEmpty,
               SourceRegistry.shared.exactSource(forUrl: candidate) != nil {
                UserDefaults.standard.set(candidate, forKey: "legado_selected_explore_source")
            } else {
                UserDefaults.standard.removeObject(forKey: "legado_selected_explore_source")
            }
        }
    }

    /// 某源 exploreUrl 解析出的分类标签：[{title,url},…]
    /// 顶层 JS 源：只读缓存；未命中则异步预热并返回 `[]`（完成后发通知）。
    /// 非 JS 源：同步结构解析并写缓存。
    @objc(exploreKindsJSONForSourceUrl:)
    public func exploreKindsJSON(forSourceUrl sourceUrl: String?) -> String {
        guard let resolved = resolveExploreSource(sourceUrl),
              let raw = resolved.exploreUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return "[]"
        }
        let cacheKey = resolved.bookSourceUrl
        let fingerprint = raw

        if let cached = exploreKindsCacheQueue.sync(execute: { exploreKindsCache[cacheKey] }),
           cached.fingerprint == fingerprint {
            return cached.json
        }

        if RuleWebBook.isTopLevelExploreJS(raw) {
            warmupExploreKinds(forSourceUrl: cacheKey)
            return "[]"
        }

        let kinds = RuleWebBook.parseExploreKinds(raw, source: resolved, evaluateJS: false)
        let json = encodeExploreKindsJSON(kinds, baseUrl: resolved.bookSourceUrl)
        // 空分类不写缓存：允许下次重试（避免一次性失败被永久缓存成「无分类」）
        if !kinds.isEmpty {
            storeExploreKindsCache(key: cacheKey, fingerprint: fingerprint, json: json)
        }
        return json
    }

    /// Resolve the exact catalog identity for a selected node.  A missing
    /// snapshot/node is intentional fail-closed input for the shared router;
    /// callers must not synthesize an identity from a display title.
    @objc(exploreContextJSONForSourceUrl:nodeUrl:)
    public func exploreContextJSON(forSourceUrl sourceUrl: String?, nodeUrl: String?) -> String {
        guard let resolved = resolveExploreSource(sourceUrl),
              let raw = resolved.exploreUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return "{}" }
        let exact = resolved.bookSourceUrl
        let snapshot: ExploreCatalogSnapshot
        if RuleWebBook.isTopLevelExploreJS(raw) {
            guard let cached = exploreKindsCacheQueue.sync(execute: { exploreKindsCache[exact] }),
                  cached.fingerprint == raw,
                  let data = cached.json.data(using: .utf8),
                  let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  !rows.isEmpty else { return "{}" }
            snapshot = Self.snapshotFromLegacyKinds(rows, exactSourceUrl: exact, exploreRaw: raw)
        } else {
            snapshot = RuleWebBook.parseExploreCatalog(
                raw, exactSourceUrl: exact, sourceNameSnapshot: resolved.bookSourceName,
                source: resolved, evaluateJS: false
            )
        }
        let wanted = nodeUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let node = snapshot.channels.flatMap(\.nodes).first { n in
            guard !wanted.isEmpty else { return false }
            return n.rawTarget == wanted ||
                RuleWebBook.absoluteExploreURL(baseUrl: exact, path: n.rawTarget) == wanted
        }
        let obj: [String: Any] = [
            "definitionFingerprint": snapshot.definitionFingerprint,
            "snapshotID": snapshot.snapshotID,
            "nodeID": node?.nodeID ?? "",
            "runtimeEpoch": snapshot.runtimeContextEpoch,
        ]
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    /// TC-07 / §24.6：sanitized snapshot metadata JSON（无 raw target / Cookie / requestInfo）。
    @objc(exploreSnapshotMetadataJSONForSourceUrl:)
    public func exploreSnapshotMetadataJSON(forSourceUrl sourceUrl: String?) -> String {
        let envelope: [String: Any]
        defer {}
        guard let resolved = resolveExploreSource(sourceUrl) else {
            return Self.encodeSanitizedExploreMetadata(
                sourceIdentityHash: "",
                snapshot: nil,
                state: ExploreCatalogStore.ExploreUIState.failedWithoutCache.rawValue
            )
        }
        let exact = resolved.bookSourceUrl
        let sourceHash = Self.stableSourceIdentityHash(exact)
        guard let raw = resolved.exploreUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return Self.encodeSanitizedExploreMetadata(
                sourceIdentityHash: sourceHash,
                snapshot: nil,
                state: ExploreCatalogStore.ExploreUIState.emptySuccess.rawValue
            )
        }
        // 同步结构解析；顶层 JS 未求值 → coldLoading（异步路径另发通知）
        if RuleWebBook.isTopLevelExploreJS(raw) {
            if let cached = exploreKindsCacheQueue.sync(execute: { exploreKindsCache[exact] }),
               cached.fingerprint == raw,
               let data = cached.json.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               !arr.isEmpty {
                // Legacy cache rows are upgraded while retaining exact targets internally.
                let snap = Self.snapshotFromLegacyKinds(arr, exactSourceUrl: exact, exploreRaw: raw)
                return Self.encodeSanitizedExploreMetadata(
                    sourceIdentityHash: sourceHash,
                    snapshot: snap,
                    state: ExploreCatalogStore.ExploreUIState.ready.rawValue
                )
            }
            return Self.encodeSanitizedExploreMetadata(
                sourceIdentityHash: sourceHash,
                snapshot: nil,
                state: ExploreCatalogStore.ExploreUIState.coldLoading.rawValue
            )
        }
        let snap = RuleWebBook.parseExploreCatalog(
            raw,
            exactSourceUrl: exact,
            sourceNameSnapshot: resolved.bookSourceName,
            source: resolved,
            evaluateJS: false
        )
        let state: String
        if snap.channels.isEmpty {
            state = ExploreCatalogStore.ExploreUIState.emptySuccess.rawValue
        } else {
            state = ExploreCatalogStore.ExploreUIState.ready.rawValue
        }
        return Self.encodeSanitizedExploreMetadata(
            sourceIdentityHash: sourceHash,
            snapshot: snap,
            state: state
        )
    }

    private static func stableSourceIdentityHash(_ sourceUrl: String) -> String {
        let digest = SHA256.hash(data: Data(sourceUrl.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func snapshotFromLegacyKinds(
        _ kinds: [[String: Any]],
        exactSourceUrl: String,
        exploreRaw: String
    ) -> ExploreCatalogSnapshot {
        // Keep the cached exact target for identity binding; sanitized JSON
        // still strips rawTarget before crossing the UI boundary.
        var diagnostics = ExploreCatalogDiagnostics()
        diagnostics.codes.append("legacyKindsSanitized")
        let fingerprint = ExploreCatalogID.definitionFingerprint(
            exactSourceUrl: exactSourceUrl,
            exploreRaw: exploreRaw
        )
        let channelID = ExploreCatalogID.channelID(
            sourceUrl: exactSourceUrl,
            definitionFingerprint: fingerprint,
            indexPath: [0],
            rawTitle: ""
        )
        var nodes: [ExploreNode] = []
        for (idx, item) in kinds.enumerated() {
            let title = (item["title"] as? String) ?? ""
            let target = (item["url"] as? String) ?? ""
            let nodeID = ExploreCatalogID.nodeID(
                sourceUrl: exactSourceUrl,
                definitionFingerprint: fingerprint,
                channelID: channelID,
                indexPath: [0, idx],
                kind: .url,
                rawTitle: title,
                rawTarget: target
            )
            nodes.append(
                ExploreNode(
                    nodeID: nodeID,
                    kind: .url,
                    rawTitle: title,
                    displayTitle: title,
                    rawTarget: target,
                    originalOrder: idx,
                    selectable: !title.isEmpty
                )
            )
        }
        var snap = ExploreCatalogSnapshot(
            exactSourceUrl: exactSourceUrl,
            sourceNameSnapshot: nil,
            definitionFingerprint: fingerprint,
            runtimeContextEpoch: 0,
            snapshotID: "",
            channels: [
                ExploreChannel(
                    channelID: channelID,
                    rawTitle: "",
                    displayTitle: "发现",
                    rawStyle: nil,
                    originalOrder: 0,
                    nodes: nodes
                )
            ],
            defaultChannelID: channelID,
            defaultNodeID: nodes.first?.nodeID,
            diagnostics: diagnostics
        )
        if let sid = try? ExploreCatalogID.snapshotID(for: snap) {
            snap.snapshotID = sid
        }
        return snap
    }

    private static func encodeSanitizedExploreMetadata(
        sourceIdentityHash: String,
        snapshot: ExploreCatalogSnapshot?,
        state: String
    ) -> String {
        var channels: [[String: Any]] = []
        if let snapshot {
            for ch in snapshot.channels {
                var nodes: [[String: Any]] = []
                for n in ch.nodes {
                    nodes.append([
                        "nodeID": n.nodeID,
                        "title": n.displayTitle,
                        "kind": n.kind.rawValue,
                        "selectable": n.selectable,
                    ])
                }
                var chObj: [String: Any] = [
                    "channelID": ch.channelID,
                    "title": ch.displayTitle,
                    "nodes": nodes,
                ]
                if let style = ch.rawStyle {
                    // 仅透传已结构化 styleHints 形态；ExploreJSONValue → 简表
                    chObj["styleHints"] = ["layout": "native-default"]
                    _ = style
                }
                channels.append(chObj)
            }
        }
        let obj: [String: Any] = [
            "schemaVersion": 1,
            "sourceIdentityHash": sourceIdentityHash,
            "snapshotID": snapshot?.snapshotID ?? "",
            "state": state,
            "channels": channels,
        ]
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
              let s = String(data: data, encoding: .utf8) else {
            return #"{"schemaVersion":1,"sourceIdentityHash":"","snapshotID":"","state":"failedWithoutCache","channels":[]}"#
        }
        return s
    }

    /// 异步预热某源分类缓存（切源时调用；完成后发 `exploreKindsDidUpdateNotification`）。
    @objc(warmupExploreKindsForSourceUrl:)
    public func warmupExploreKinds(forSourceUrl sourceUrl: String?) {
        guard let resolved = resolveExploreSource(sourceUrl),
              let raw = resolved.exploreUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              SourceRegistry.shared.exactSource(forUrl: resolved.bookSourceUrl) != nil,
              SourceRegistry.shared.isEnabled(url: resolved.bookSourceUrl) else {
            return
        }
        let cacheKey = resolved.bookSourceUrl
        let fingerprint = raw
        let capturedRegistryGeneration = SourceSessionCoordinator.shared.currentRegistryGeneration()
        var capturedCancellationEpoch: UInt64 = 0
        let shouldStart: Bool = exploreKindsCacheQueue.sync {
            // Always materialize an epoch entry before the worker starts so a
            // concurrent mutation can invalidate this exact in-flight task.
            if exploreKindsCancellationEpoch[cacheKey] == nil {
                exploreKindsCancellationEpoch[cacheKey] = 0
            }
            capturedCancellationEpoch = exploreKindsCancellationEpoch[cacheKey] ?? 0
            if let cached = exploreKindsCache[cacheKey], cached.fingerprint == fingerprint {
                return false
            }
            if exploreKindsWarming.contains(cacheKey) { return false }
            // 失败节流：30s 内不重复预热（防刷新风暴反复跑 12s JS）
            if let failedAt = exploreKindsWarmFailedAt[cacheKey],
               Date().timeIntervalSince1970 - failedAt < 30 {
                return false
            }
            exploreKindsWarming.insert(cacheKey)
            return true
        }
        guard shouldStart else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            defer {
                self.exploreKindsCacheQueue.sync { _ = self.exploreKindsWarming.remove(cacheKey) }
            }
            let kinds = RuleWebBook.parseExploreKinds(
                raw,
                source: resolved,
                evaluateJS: true,
                jsTimeoutSeconds: 12
            )
            let json = self.encodeExploreKindsJSON(kinds, baseUrl: resolved.bookSourceUrl)
            // A worker may finish after source disable/remove, re-import,
            // definition edit, or another refresh.  Commit validation is
            // serialized with cache invalidation so stale results cannot write
            // last-good data or notify the UI for the old source definition.
            guard self.commitExploreKindsWarmup(
                exactSourceUrl: cacheKey,
                fingerprint: fingerprint,
                registryGeneration: capturedRegistryGeneration,
                cancellationEpoch: capturedCancellationEpoch,
                json: json,
                failed: kinds.isEmpty
            ) else {
                self.writeSearchMarker("exploreKinds warm stale drop src=\(cacheKey)")
                return
            }
            // 空分类（JS 失败/超时）不写缓存：记失败时间节流；仍通知 UI 清掉「分类加载中」并给失败文案
            guard !kinds.isEmpty else {
                self.writeSearchMarker("exploreKinds warm fail src=\(cacheKey)")
                DispatchQueue.main.async {
                    guard self.isExploreKindsWarmupStillCurrent(
                        exactSourceUrl: cacheKey,
                        fingerprint: fingerprint,
                        registryGeneration: capturedRegistryGeneration,
                        cancellationEpoch: capturedCancellationEpoch
                    ) else {
                        self.writeSearchMarker("exploreKinds warm notify stale drop src=\(cacheKey)")
                        return
                    }
                    NotificationCenter.default.post(
                        name: Self.exploreKindsDidUpdateNotification,
                        object: self,
                        userInfo: ["sourceUrl": cacheKey, "failed": true]
                    )
                    LBShowDiscoverExploreEmptyHint("分类加载失败，请稍后重试或切换书源")
                }
                return
            }
            DispatchQueue.main.async {
                guard self.isExploreKindsWarmupStillCurrent(
                    exactSourceUrl: cacheKey,
                    fingerprint: fingerprint,
                    registryGeneration: capturedRegistryGeneration,
                    cancellationEpoch: capturedCancellationEpoch
                ) else {
                    self.writeSearchMarker("exploreKinds warm notify stale drop src=\(cacheKey)")
                    return
                }
                NotificationCenter.default.post(
                    name: Self.exploreKindsDidUpdateNotification,
                    object: self,
                    userInfo: ["sourceUrl": cacheKey]
                )
            }
        }
    }

    /// Current per-source cancellation epoch.  Internal visibility keeps the
    /// mutation-during-warmup contract deterministic in XCTest without
    /// exposing a production API or requiring a real JS/WebView worker.
    func exploreKindsCancellationEpochForSourceUrl(_ sourceUrl: String) -> UInt64 {
        let exact = sourceUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        return exploreKindsCacheQueue.sync {
            exploreKindsCancellationEpoch[exact] ?? 0
        }
    }

    /// Delivery-side guard for a completed asynchronous warmup.  A result may
    /// have passed the worker commit gate and still be queued on the main
    /// thread while the exact source is disabled/removed, re-imported, or its
    /// explore definition changes.  Re-check every captured identity before
    /// posting a notification or touching the discover empty hint; the
    /// observer currently routes by host and can otherwise refresh the wrong
    /// source when it ignores `sourceUrl` in the notification payload.
    func isExploreKindsWarmupStillCurrent(
        exactSourceUrl: String,
        fingerprint: String,
        registryGeneration: UInt64,
        cancellationEpoch: UInt64
    ) -> Bool {
        let exact = exactSourceUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedFingerprint = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !exact.isEmpty, !expectedFingerprint.isEmpty,
              let source = SourceRegistry.shared.exactSource(forUrl: exact),
              SourceRegistry.shared.isEnabled(url: exact),
              source.exploreUrl?.trimmingCharacters(in: .whitespacesAndNewlines) == expectedFingerprint,
              SourceSessionCoordinator.shared.currentRegistryGeneration() == registryGeneration else {
            return false
        }
        return exploreKindsCacheQueue.sync {
            exploreKindsCancellationEpoch[exact] == cancellationEpoch
        }
    }

    /// Commit a warmup result only while the exact source definition and
    /// registry route captured at launch are still current.  The validation
    /// and write share `exploreKindsCacheQueue` with invalidation, so a
    /// mutation either wins before this closure (and fails validation) or
    /// wins immediately after it (and removes the just-written cache).
    @discardableResult
    func commitExploreKindsWarmup(
        exactSourceUrl: String,
        fingerprint: String,
        registryGeneration: UInt64,
        cancellationEpoch: UInt64,
        json: String,
        failed: Bool,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> Bool {
        let exact = exactSourceUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !exact.isEmpty else { return false }
        guard let source = SourceRegistry.shared.exactSource(forUrl: exact),
              SourceRegistry.shared.isEnabled(url: exact),
              source.exploreUrl?.trimmingCharacters(in: .whitespacesAndNewlines) == fingerprint,
              SourceSessionCoordinator.shared.currentRegistryGeneration() == registryGeneration else {
            return false
        }
        return exploreKindsCacheQueue.sync {
            guard exploreKindsCancellationEpoch[exact] == cancellationEpoch else { return false }
            if failed {
                exploreKindsWarmFailedAt[exact] = now
            } else {
                _ = exploreKindsWarmFailedAt.removeValue(forKey: exact)
                exploreKindsCache[exact] = (fingerprint: fingerprint, json: json)
            }
            return true
        }
    }

    /// 分类预热是否处于失败节流窗口（30s 内勿再盖「分类加载中」）
    @objc(isExploreKindsWarmFailedRecentlyForSourceUrl:)
    public func isExploreKindsWarmFailedRecently(forSourceUrl sourceUrl: String?) -> Bool {
        let key = (sourceUrl?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? resolveExploreSource(sourceUrl)?.bookSourceUrl
        guard let key, !key.isEmpty else { return false }
        return exploreKindsCacheQueue.sync {
            guard let failedAt = exploreKindsWarmFailedAt[key] else { return false }
            return Date().timeIntervalSince1970 - failedAt < 30
        }
    }

    /// 清除某源（或全部）分类缓存。
    @objc(invalidateExploreKindsCacheForSourceUrl:)
    public func invalidateExploreKindsCache(forSourceUrl sourceUrl: String?) {
        exploreKindsCacheQueue.sync {
            if let sourceUrl {
                let exact = sourceUrl.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !exact.isEmpty else { return }
                exploreKindsCancellationEpoch[exact, default: 0] &+= 1
                exploreKindsCache.removeValue(forKey: exact)
                exploreKindsWarming.remove(exact)
                exploreKindsWarmFailedAt.removeValue(forKey: exact)
            } else {
                var keys = Set(exploreKindsCancellationEpoch.keys)
                keys.formUnion(exploreKindsCache.keys)
                keys.formUnion(exploreKindsWarming)
                keys.formUnion(exploreKindsWarmFailedAt.keys)
                for key in keys {
                    exploreKindsCancellationEpoch[key, default: 0] &+= 1
                }
                exploreKindsCache.removeAll()
                exploreKindsWarming.removeAll()
                exploreKindsWarmFailedAt.removeAll()
            }
        }
    }

    private func resolveExploreSource(_ sourceUrl: String?) -> MemoryBridgeBookSource? {
        if let sourceUrl {
            guard !sourceUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                // An explicit empty argument is not the same as nil.  It is a
                // malformed identity and must not fall through to selected or
                // first-source convenience resolution.
                return nil
            }
            return SourceRegistry.shared.source(forUrl: sourceUrl)
        }
        if let sel = selectedExploreSourceUrl, !sel.isEmpty {
            return SourceRegistry.shared.exactSource(forUrl: sel)
        }
        return SourceRegistry.shared.exploreCapableSources().first
    }

    private func storeExploreKindsCache(key: String, fingerprint: String, json: String) {
        exploreKindsCacheQueue.sync {
            exploreKindsCache[key] = (fingerprint: fingerprint, json: json)
        }
    }

    /// 编码分类 JSON：相对 URL 绝对化 + 按 (title,url) 去重。
    private func encodeExploreKindsJSON(
        _ kinds: [RuleWebBook.ExploreKind],
        baseUrl: String
    ) -> String {
        var rows: [[String: String]] = kinds.map { kind in
            let abs = RuleWebBook.absoluteExploreURL(baseUrl: baseUrl, path: kind.url)
            return ["title": kind.title, "url": abs]
        }
        // B-03：按 (title, url) 去重，同名不同 URL 均保留
        var seen = Set<String>()
        rows = rows.filter { row in
            let t = (row["title"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let u = (row["url"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let key = "\(t)\u{1F}\(u)"
            if t.isEmpty && u.isEmpty { return false }
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rows),
              let s = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return s
    }

    /// 可发现源摘要：[{name,url,type},…]；type=bookSourceType（0文本/1音频/2图片/3文件）
    @objc public var exploreCapableSourcesJSON: String {
        let rows: [[String: Any]] = SourceRegistry.shared.switchableSources().map { src in
            var row: [String: Any] = [
                "name": src.bookSourceName ?? src.bookSourceUrl,
                "url": src.bookSourceUrl
            ]
            if let t = src.bookSourceType {
                row["type"] = t
            }
            return row
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rows),
              let s = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return s
    }

    /// 触发发现请求；结果走搜索响应通知（带 fromExplore）
    @objc(handleExploreRequestWithSourceUrl:exploreUrl:page:)
    public func handleExploreRequest(sourceUrl: String?, exploreUrl: String?, page: Int) {
        // 同源+同 kind 防抖：切源/深链/原生回调会连打多次。
        // 重复调用只忽略，禁止 bump generation（否则进行中的 Task 被作废且无后继 → 永不灌书/空态）。
        let debounceKey = "\(sourceUrl ?? "")|\(exploreUrl ?? "")|\(max(page, 1))"
        let now = Date().timeIntervalSince1970
        if sLastExploreKey == debounceKey, now - sLastExploreAt < 2.5 {
            writeSearchMarker("explore debounce skip key=\(debounceKey)")
            return
        }
        sLastExploreKey = debounceKey
        sLastExploreAt = now
        let exploreUrlCopy = exploreUrl
        let sourceUrlCopy = sourceUrl
        // 并发 explore：世代号归 SourceSessionCoordinator 所有；保留 sExploreGeneration 作兼容镜像
        let srcKey: String
        if let requested = sourceUrlCopy {
            let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                writeSearchMarker("explore reject explicit empty source")
                return
            }
            srcKey = trimmed
        } else {
            // nil is the only convenience form: use the persisted exact
            // selection, never an arbitrary active/first source for a
            // publish-capable request.
            guard let selected = selectedExploreSourceUrl, !selected.isEmpty else {
                writeSearchMarker("explore reject nil source without selected exact source")
                return
            }
            srcKey = selected
        }
        guard let sessionToken = SourceSessionCoordinator.shared.prepareLegadoExplorePageIfSelected(
            exactSourceUrl: srcKey,
            page: max(page, 1)
        ) else {
            writeSearchMarker("explore reject missing exact legado selection src=\(srcKey.isEmpty ? "-" : srcKey)")
            return
        }
        guard let owner = sessionToken.ownerControllerIdentity, !owner.isEmpty,
              let fingerprint = sessionToken.definitionFingerprint, !fingerprint.isEmpty,
              let snapshotID = sessionToken.snapshotID, !snapshotID.isEmpty,
              let nodeID = sessionToken.nodeID, !nodeID.isEmpty else {
            writeSearchMarker("explore reject missing bound context src=\(srcKey)")
            return
        }
        sExploreGeneration = sessionToken.contentGeneration
        sExploreGenerationSourceUrl = srcKey
        let capturedSessionToken = sessionToken
        let capturedExploreSourceUrl = srcKey
        // Cold last-good UI first (consumes a one-shot cold permit).  Persist
        // authorization is issued afterwards so writeLastGood still has a live
        // cacheFallback nonce after the cache lane is done.
        let didPublishExploreCache = capturedSessionToken.page == 1
            && publishExploreCatalogCacheHit(
                session: capturedSessionToken,
                scene: .coldStart
            )
        let capturedPersistPermit: CachePermitToken? = {
            guard capturedSessionToken.page == 1 else { return nil }
            return issueExploreCatalogPersistPermit(for: capturedSessionToken)
        }()
        func exploreCaptureStillActive() -> Bool {
            SourceSessionCoordinator.shared.isStillActiveLegadoPublishContext(capturedSessionToken)
                && capturedExploreSourceUrl == sExploreGenerationSourceUrl
        }
        writeSearchMarker("explore start gen=\(capturedSessionToken.contentGeneration) src=\(sourceUrl ?? "-") kind=\(exploreUrl ?? "-")")
        // 已有明确 kind：清掉「分类加载中」占位，避免超时后仍盖住失败/列表
        if let exploreUrlCopy, !exploreUrlCopy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            DispatchQueue.main.async {
                LBClearDiscoverExploreEmptyHint()
            }
        }
        Task {
            var publishedCache = didPublishExploreCache
            let targets: [MemoryBridgeBookSource]
            if let sourceUrl = sourceUrlCopy,
               let one = SourceRegistry.shared.source(forUrl: sourceUrl.trimmingCharacters(in: .whitespacesAndNewlines)),
               one.supportsExplore {
                    targets = [one]
                    selectedExploreSourceUrl = one.bookSourceUrl
                    // 指定源 explore：先把发现宿主切到该源（清 XBS 态），
                    // 否则 LBIsDiscoverNativeXBSMode 会丢弃 explore 结果（发现页不出书）
                    await MainActor.run {
                        // 已在该源发现宿主时禁止再 switch（会连环 nativeSwitch→explore→冲掉灌书）
                        let wantName = one.bookSourceName ?? one.bookSourceUrl
                        if !LBDiscoverHostAlreadyShowingSource(wantName) {
                            LBSwitchDiscoverToSourceName(wantName)
                        }
                    }
            } else if let sourceUrl = sourceUrlCopy {
                // An explicit URL is fail-closed: missing/disabled sources do
                // not fall through to the selected or first source.
                targets = []
                writeSearchMarker("explore reject explicit source unavailable src=\(sourceUrl)")
            } else if let sel = selectedExploreSourceUrl, !sel.isEmpty,
                      let one = SourceRegistry.shared.source(forUrl: sel),
                      one.supportsExplore {
                targets = [one]
            } else {
                // No selected exact source means the preflight above should
                // already have rejected.  Keep the task fail-closed if the
                // registry changes between preflight and execution.
                targets = []
            }
            guard !targets.isEmpty else {
                writeSearchMarker("explore reject no enabled target src=\(srcKey)")
                await MainActor.run {
                    guard exploreCaptureStillActive() else { return }
                    LBShowDiscoverExploreEmptyHint("暂无可发现书源")
                }
                return
            }
            guard exploreCaptureStillActive() else { return }
            var total = 0
            for source in targets {
                guard exploreCaptureStillActive() else { return }
                do {
                    // kinds 未就绪时勿用 nil kind 进 exploreBook（会再跑顶层 JS 并报「未产出分类」）
                    var kindForFetch = exploreUrlCopy
                    let kindTrim = kindForFetch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if kindTrim.isEmpty {
                        let cachedJSON = exploreKindsJSON(forSourceUrl: source.bookSourceUrl)
                        if let data = cachedJSON.data(using: .utf8),
                           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                            // 禁止默认落到 fqbookshelf（我的书架常空）；优先个性推荐
                            if let u = Self.preferredExploreKindURL(from: arr), !u.isEmpty {
                                kindForFetch = u
                            }
                        }
                        if (kindForFetch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty,
                           RuleWebBook.isTopLevelExploreJS(source.exploreUrl ?? "") {
                            writeSearchMarker("explore defer JS kinds warming src=\(source.bookSourceUrl)")
                            let coolFail = self.isExploreKindsWarmFailedRecently(
                                forSourceUrl: source.bookSourceUrl
                            )
                            if !coolFail {
                                warmupExploreKinds(forSourceUrl: source.bookSourceUrl)
                            }
                            let cacheAlreadyShown = publishedCache
                            await MainActor.run {
                                guard exploreCaptureStillActive() else { return }
                                LBDismissDiscoverLoadingHUD()
                                if cacheAlreadyShown {
                                    LBClearDiscoverExploreEmptyHint()
                                } else if coolFail {
                                    LBShowDiscoverExploreEmptyHint("分类加载失败，请稍后重试或切换书源")
                                } else {
                                    LBShowDiscoverExploreEmptyHint("分类加载中，请稍后…")
                                }
                            }
                            continue
                        }
                    }
                    let kindResolved = kindForFetch
                    // 与搜索同级的硬超时：explore 源挂起时禁止「章节加载中」卡死（验收发现页）
                    let results = try await Self.withTimeout(seconds: 20) {
                        try await BridgeWebBook.exploreBook(
                            source: source,
                            url: kindResolved,
                            page: max(page, 1)
                        )
                    }
                    guard exploreCaptureStillActive() else { return }
                    var ephemeralByBookUrl: [String: EphemeralBookDTO] = [:]
                    for r in results {
                        let book = BridgeBook(
                            name: r.name,
                            author: r.author,
                            bookUrl: r.bookUrl,
                            coverUrl: r.coverUrl ?? "",
                            intro: r.intro ?? "",
                            sourceUrl: r.sourceUrl,
                            sourceName: r.sourceName
                        )
                        // 展示结果：仅 ephemeral DTO + 会话 cache；禁止 durable upsert
                        if let dto = XiangseAdapter.ephemeralDTO(from: r) {
                            ephemeralByBookUrl[r.bookUrl] = dto
                            bookCache[dto.identity] = book
                        }
                    }
                    total += results.count
                    // 批量灌入，避免逐本 merge 刷屏
                    let books: [[String: Any]] = results.map { r in
                        XiangseAdapter.searchBookDict(r, ephemeral: ephemeralByBookUrl[r.bookUrl])
                    }
                    if !books.isEmpty {
                        await MainActor.run {
                            guard exploreCaptureStillActive() else { return }
                            LBApplySearchResultsToUIWithCapturedToken(
                                books,
                                "explore",
                                LBSharedSourceRouter.tokenDictionary(capturedSessionToken),
                                capturedSessionToken.page == 1
                            )
                            if let persistPermit = capturedPersistPermit,
                               capturedSessionToken.page == 1 {
                                _ = self.persistExploreCatalogLastGood(
                                    session: capturedSessionToken,
                                    books: books,
                                    permit: persistPermit
                                )
                            }
                        }
                    }
                    if results.isEmpty {
                        writeSearchMarker("explore empty src=\(source.bookSourceUrl)")
                        let emptyHint = Self.exploreEmptyHint(
                            source: source,
                            exploreUrl: exploreUrlCopy,
                            errorMessage: nil
                        )
                        let cacheAlreadyShown = publishedCache
                        publishedCache = await MainActor.run { () -> Bool in
                            guard exploreCaptureStillActive() else { return cacheAlreadyShown }
                            var shown = cacheAlreadyShown
                            if capturedSessionToken.page == 1, !shown {
                                shown = self.publishExploreCatalogCacheHit(
                                    session: capturedSessionToken,
                                    scene: .networkFallback
                                )
                            }
                            if shown {
                                LBDismissDiscoverLoadingHUD()
                                LBClearDiscoverExploreEmptyHint()
                                return shown
                            }
                            LBApplySearchResultsToUIWithCapturedToken(
                                [],
                                "explore",
                                LBSharedSourceRouter.tokenDictionary(capturedSessionToken),
                                capturedSessionToken.page == 1
                            )
                            guard exploreCaptureStillActive() else { return shown }
                            LBDismissDiscoverLoadingHUD()
                            LBShowDiscoverExploreEmptyHint(emptyHint)
                            return shown
                        }
                    }
                } catch {
                    writeSearchMarker("explore err src=\(source.bookSourceUrl) \(error.localizedDescription)")
                    // 失败/超时：摘掉「章节加载中」残留，避免发现页永久挂起
                    if let bridgeErr = error as? LegadoBridgeError, case .timeout = bridgeErr {
                        writeSearchMarker("explore timeout src=\(source.bookSourceUrl)")
                    }
                    let hint = Self.exploreEmptyHint(
                        source: source,
                        exploreUrl: exploreUrlCopy,
                        errorMessage: error.localizedDescription
                    )
                    let cacheAlreadyShown = publishedCache
                    publishedCache = await MainActor.run { () -> Bool in
                        guard exploreCaptureStillActive() else { return cacheAlreadyShown }
                        var shown = cacheAlreadyShown
                        if capturedSessionToken.page == 1, !shown {
                            shown = self.publishExploreCatalogCacheHit(
                                session: capturedSessionToken,
                                scene: .networkFallback
                            )
                        }
                        LBDismissDiscoverLoadingHUD()
                        if shown {
                            LBClearDiscoverExploreEmptyHint()
                            return shown
                        }
                        LBShowDiscoverExploreEmptyHint(hint)
                        return shown
                    }
                }
            }
            // 空结果也收尾：摘「章节加载中」；勿再用笼统文案盖掉上面按源判定的提示
            if total == 0 {
                await MainActor.run {
                    guard exploreCaptureStillActive() else { return }
                    LBDismissDiscoverLoadingHUD()
                }
            }
            writeSearchMarker("explore ok total=\(total) sources=\(targets.count) gen=\(capturedSessionToken.contentGeneration)")
        }
    }

    // MARK: - 替换净化

    @objc(importReplaceRulesJSON:error:)
    @discardableResult
    public func importReplaceRulesJSON(_ json: String, error: NSErrorPointer) -> Int {
        do {
            return try ReplaceRuleStore.shared.importJSON(json, merge: true)
        } catch let err as NSError {
            error?.pointee = err
            return 0
        }
    }

    @objc(purifyContent:bookUrl:chapterUrl:)
    public func purifyContent(_ text: String, bookUrl: String?, chapterUrl: String?) -> String {
        ReplaceRuleStore.shared.purify(text, bookUrl: bookUrl, chapterUrl: chapterUrl)
    }

    @objc public var replaceRulesCount: Int {
        ReplaceRuleStore.shared.allRules().count
    }

    /// 净化规则列表（管理页）
    @objc public func allReplaceRulesInfo() -> [[String: Any]] {
        ReplaceRuleStore.shared.allRulesInfo()
    }

    @objc(setReplaceRuleEnabledWithId:enabled:)
    @discardableResult
    public func setReplaceRuleEnabled(id: String, enabled: Bool) -> Bool {
        guard let uuid = UUID(uuidString: id) else { return false }
        return ReplaceRuleStore.shared.setEnabled(id: uuid, enabled: enabled)
    }

    @objc(removeReplaceRuleWithId:)
    @discardableResult
    public func removeReplaceRule(id: String) -> Bool {
        guard let uuid = UUID(uuidString: id) else { return false }
        return ReplaceRuleStore.shared.remove(id: uuid)
    }

    @objc public func exportReplaceRulesJSON() -> String {
        ReplaceRuleStore.shared.exportJSONString()
    }

    // MARK: - 搜索

    public func search(keyword: String, sourceUrl: String?) async throws -> [SearchBookResult] {
        guard let source = SourceRegistry.shared.source(forUrl: sourceUrl) else {
            throw LegadoBridgeError.sourceNotFound
        }
        return try await BridgeWebBook.searchBook(source: source, key: keyword)
    }

    @objc(handleSearchRequestWithKeyword:sourceUrl:)
    public func handleSearchRequest(keyword: String, sourceUrl: String?) {
        // 入口即写标记，便于验收区分「UI 未进 Hook」与「引擎失败」
        writeSearchMarker("enter key=\(keyword) url=\(sourceUrl ?? "all")")
        // 必须 detached：从主线程 LBTriggerMixedSearch 进来时 Task{} 会继承主线程上下文，
        // 后续若再同步碰主线程 UI 易与 Frida/系统主线程互锁。
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let targets: [MemoryBridgeBookSource]
            if let sourceUrl {
                // Explicit search identity is strict; never search the
                // active/all sources after a missing or disabled URL.
                if sourceUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.appendSearchMarker("err explicit empty source key=\(keyword)")
                    targets = []
                } else if let one = SourceRegistry.shared.source(forUrl: sourceUrl) {
                    targets = [one]
                } else {
                    self.appendSearchMarker("err explicit source unavailable src=\(sourceUrl) key=\(keyword)")
                    targets = []
                }
            } else {
                // nil：全部启用源并行搜，避免只吃第一个；显式空字符串
                // 在上面的 identity 分支中已经 fail-closed。
                targets = SourceRegistry.shared.allSources().filter {
                    SourceRegistry.shared.isEnabled(url: $0.bookSourceUrl)
                }
            }
            guard !targets.isEmpty else {
                self.appendSearchMarker("err no enabled sources key=\(keyword)")
                self.postNotification(
                    XiangseAdapter.notifySearchResponse,
                    userInfo: [
                        "error": LegadoBridgeError.sourceNotFound.localizedDescription,
                        "keyword": keyword,
                        "fromLegadoBridge": true,
                        XiangseAdapter.legadoMarkerKey: XiangseAdapter.legadoMarkerValue
                    ]
                )
                return
            }

            // fail-open：串行。超时用独立 pthread+sleep（GCD asyncAfter 在 JS 堵死时真机不触发）。
            let perSourceTimeoutSeconds: TimeInterval = 20
            var totalCount = 0
            for source in targets {
                let srcUrl = source.bookSourceUrl
                self.appendSearchMarker("start src=\(srcUrl)")
                let outcome: Result<[SearchBookResult], Error> = await withCheckedContinuation { cont in
                    let flag = OnceFlag()
                    Task.detached(priority: .userInitiated) {
                        do {
                            let results = try await BridgeWebBook.searchBook(source: source, key: keyword)
                            if flag.claim() {
                                cont.resume(returning: .success(results))
                            }
                        } catch {
                            if flag.claim() {
                                cont.resume(returning: .failure(error))
                            }
                        }
                    }
                    // 独立线程硬超时：不依赖协作线程池 / 主队列 / 被 JS 占满的 GCD 工作队列
                    Thread.detachNewThread {
                        Thread.sleep(forTimeInterval: perSourceTimeoutSeconds)
                        self.appendSearchMarker("tick src=\(srcUrl)")
                        if flag.claim() {
                            self.appendSearchMarker("partial err src=\(srcUrl) 单源搜索超时")
                            cont.resume(returning: .failure(LegadoBridgeError.timeout))
                        } else {
                            self.appendSearchMarker("tick-miss src=\(srcUrl)")
                        }
                    }
                }
                switch outcome {
                case .success(let results):
                    self.appendSearchMarker("got src=\(srcUrl) n=\(results.count)")
                    totalCount += results.count
                    // 通知/UI 一律异步，搜索循环绝不在此同步等待主线程
                    let books: [[String: Any]] = results.compactMap { r in
                        // 搜索列表 ephemeral：不调 durable upsert
                        let dto = XiangseAdapter.ephemeralDTO(from: r)
                        let book = BridgeBook(
                            name: r.name,
                            author: r.author,
                            bookUrl: r.bookUrl,
                            coverUrl: r.coverUrl ?? "",
                            intro: r.intro ?? "",
                            sourceUrl: r.sourceUrl,
                            sourceName: r.sourceName
                        )
                        if let identity = dto?.identity {
                            self.bookCache[identity] = book
                        }
                        let dict = XiangseAdapter.searchBookDict(r, ephemeral: dto)
                        guard Self.isSafeSearchBookDict(dict) else { return nil }
                        return dict
                    }
                    let sourceName = results.first?.sourceName
                        ?? SourceRegistry.shared.exactSource(forUrl: srcUrl)?.bookSourceName
                        ?? ""
                    DispatchQueue.main.async {
                        for dict in books {
                            let payload = XiangseAdapter.searchResultNotifyPayload(
                                book: dict,
                                keyword: keyword,
                                sourceUrl: srcUrl,
                                sourceName: (dict["sourceName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? sourceName
                            )
                            self.postNotification(XiangseAdapter.notifySearchResponse, userInfo: payload)
                            LBApplySearchResultsToUI([dict], keyword)
                        }
                    }
                    self.appendSearchMarker("done src=\(srcUrl) n=\(results.count)")
                case .failure(let error):
                    if case LegadoBridgeError.timeout = error {
                        // already logged in timer
                    } else {
                        self.appendSearchMarker("partial err src=\(srcUrl) \(error.localizedDescription)")
                    }
                }
            }
            self.appendSearchMarker("ok total=\(totalCount) sources=\(targets.count) key=\(keyword)")
        }
    }

    /// 给单源搜索/拉取加硬超时（保留给其它调用方；搜索主路径已改信号量）。
    private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let flag = OnceFlag()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            Task.detached(priority: .userInitiated) {
                do {
                    let value = try await operation()
                    if flag.claim() {
                        cont.resume(returning: value)
                    }
                } catch {
                    if flag.claim() {
                        cont.resume(throwing: error)
                    }
                }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + max(seconds, 0.1)) {
                if flag.claim() {
                    cont.resume(throwing: LegadoBridgeError.timeout)
                }
            }
        }
    }

    /// 通知/灌入前校验：拒绝空 bookUrl、非字符串关键字段
    private static func isSafeSearchBookDict(_ book: [String: Any]) -> Bool {
        let url = (book["bookUrl"] as? String) ?? (book["url"] as? String) ?? ""
        let name = (book["bookName"] as? String) ?? (book["name"] as? String) ?? ""
        guard !url.isEmpty || !name.isEmpty else { return false }
        if let sb = book["searchBook"], !(sb is [String: Any]) { return false }
        return true
    }

    private func appendSearchMarker(_ msg: String) {
        writeSearchMarker(msg)
    }

    private func writeSearchMarker(_ msg: String) {
        searchMarkerLock.lock()
        defer { searchMarkerLock.unlock() }
        let path = (NSHomeDirectory() as NSString).appendingPathComponent("Documents/legado_search_last.txt")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) \(msg)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: path),
               let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? line.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: - 目录

    @objc(handleCatalogRequestWithBookUrl:sourceUrl:)
    public func handleCatalogRequest(bookUrl: String, sourceUrl: String?) {
        Task {
            do {
                let resolved = BookBindingStore.shared.resolveBinding(
                    token: nil,
                    exactSourceUrl: sourceUrl,
                    bookUrl: bookUrl
                )
                let bindingV2: BookBindingV2? = {
                    switch resolved {
                    case .success(let b): return b
                    case .failure: return nil
                    }
                }()
                if let bindingV2, !bindingV2.sourceAvailable {
                    throw LegadoBridgeError.engineError("书源不可用，请重新导入或换源后重试")
                }
                guard let source = resolveEnabledSource(requested: sourceUrl, bookUrl: bookUrl) else {
                    throw LegadoBridgeError.sourceNotFound
                }
                // 目录请求 = 用户点开：导航前 upsert 一次
                let cached = cachedBookUnique(forBookUrl: bookUrl)
                    ?? (try? BookIdentity(exactSourceUrl: source.bookSourceUrl, exactBookUrl: bookUrl)).flatMap { bookCache[$0] }
                let ensured = try BookBindingStore.shared.bind(
                    bookUrl: bookUrl,
                    sourceUrl: source.bookSourceUrl,
                    sourceName: {
                        if let bindingV2, let n = bindingV2.sourceNameSnapshot, !n.isEmpty { return n }
                        return source.bookSourceName
                    }(),
                    name: bindingV2?.name ?? cached?.name ?? "",
                    author: bindingV2?.author ?? cached?.author ?? "",
                    coverUrl: bindingV2?.coverUrl ?? cached?.coverUrl ?? "",
                    bridgeToken: bindingV2?.bridgeToken
                )
                var book = cached ?? BridgeBook(
                    name: ensured.name,
                    author: ensured.author,
                    bookUrl: bookUrl,
                    coverUrl: ensured.coverUrl,
                    sourceUrl: source.bookSourceUrl,
                    sourceName: source.bookSourceName
                )
                book.sourceUrl = source.bookSourceUrl
                book.sourceName = source.bookSourceName
                // 搜索缓存常无 tocUrl；getBookInfo 失败时也会把 tocUrl 写成 bookUrl，须重跑资料页
                // 详情偶发空体/Cloudflare：领域书库等源目录与详情同页，软失败后仍用 bookUrl 拉 TOC
                if book.tocUrl.isEmpty || book.tocUrl == book.bookUrl {
                    do {
                        _ = try await BridgeWebBook.getBookInfo(source: source, book: &book)
                    } catch {
                        writeCatalogMarker(
                            "bookInfo softFail book=\(bookUrl) \(error.localizedDescription); continue toc=bookUrl"
                        )
                        if book.tocUrl.isEmpty {
                            book.tocUrl = book.bookUrl
                        }
                    }
                }
                var chapters: [BridgeChapter]
                do {
                    chapters = try await BridgeWebBook.getChapterList(source: source, book: book)
                } catch {
                    // 单次空响应常见于连续 explore+详情；短等后重试一次
                    try await Task.sleep(nanoseconds: 700_000_000)
                    chapters = try await BridgeWebBook.getChapterList(source: source, book: book)
                }
                if let identity = try? BookIdentity(exactSourceUrl: source.bookSourceUrl, exactBookUrl: bookUrl) {
                    bookCache[identity] = book
                }
                let tocOneLine = book.tocUrl
                    .components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                    .joined()
                writeCatalogMarker(
                    "ok book=\(bookUrl) toc=\(tocOneLine) chapters=\(chapters.count) first=\(chapters.first?.title ?? "")"
                )
                let payload = XiangseAdapter.catalogPayload(
                    chapters: chapters,
                    bookUrl: bookUrl,
                    binding: ensured,
                    bookDetail: XiangseAdapter.detailDict(from: ensured)
                )
                postNotification(XiangseAdapter.notifyCatalogResponse, userInfo: payload)
                // 通知 alone 常不填 CatalogCon.arrCatalog；对齐搜索灌入路径
                let chapterMaps = chapters.map { XiangseAdapter.chapterDict($0) }
                LBApplyCatalogToUI(chapterMaps as [Any], bookUrl)
            } catch {
                writeCatalogMarker("err book=\(bookUrl) \(error.localizedDescription)")
                // 8.5：目录网络失败时尝试盘缓存（与 C 侧 LBCatalogCacheSafeKey 对齐：hash+头尾）
                let cacheDir = (NSHomeDirectory() as NSString)
                    .appendingPathComponent("Documents/legado_catalog_cache")
                let allowed = CharacterSet.alphanumerics
                var safe = ""
                for ch in bookUrl.unicodeScalars {
                    safe.append(allowed.contains(ch) ? Character(ch) : "_")
                }
                let h = UInt(bitPattern: Int((bookUrl as NSString).hash))
                let head = safe.count > 24 ? String(safe.prefix(24)) : safe
                let tail = safe.count > 24 ? String(safe.suffix(24)) : ""
                let key = String(format: "%08lx_%@_%@", h, head, tail)
                let file = (cacheDir as NSString).appendingPathComponent("\(key).json")
                if let data = try? Data(contentsOf: URL(fileURLWithPath: file)),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let chapters = obj["chapters"] as? [[String: Any]], !chapters.isEmpty {
                    writeCatalogMarker("ok-offline-cache book=\(bookUrl) chapters=\(chapters.count)")
                    LBApplyCatalogToUI(chapters as [Any], bookUrl)
                } else {
                    postNotification(
                        XiangseAdapter.notifyCatalogResponse,
                        userInfo: [
                            "error": error.localizedDescription,
                            "bookUrl": bookUrl,
                            XiangseAdapter.legadoMarkerKey: XiangseAdapter.legadoMarkerValue
                        ]
                    )
                }
            }
        }
    }

    private func writeCatalogMarker(_ msg: String) {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent("Documents/legado_catalog_last.txt")
        try? msg.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - 正文

    @objc(handleContentRequestWithChapterUrl:bookUrl:sourceUrl:)
    public func handleContentRequest(chapterUrl: String, bookUrl: String, sourceUrl: String?) {
        // 必须 detached：主线程 Task{} 会继承 MainActor，导致 BackstageWebView 的 main.async{start}
        // 与 await 互锁（真机只有 phase=enter / hop，无 didFinish）。
        Task.detached(priority: .userInitiated) {
            do {
                let resolved = BookBindingStore.shared.resolveBinding(
                    token: nil,
                    exactSourceUrl: sourceUrl,
                    bookUrl: bookUrl
                )
                let bindingV2: BookBindingV2? = {
                    switch resolved {
                    case .success(let b): return b
                    case .failure: return nil
                    }
                }()
                if let bindingV2, !bindingV2.sourceAvailable {
                    throw LegadoBridgeError.engineError("书源不可用，请重新导入或换源后重试")
                }
                guard let source = self.resolveEnabledSource(requested: sourceUrl, bookUrl: bookUrl) else {
                    throw LegadoBridgeError.sourceNotFound
                }
                let cached = self.cachedBookUnique(forBookUrl: bookUrl)
                    ?? (try? BookIdentity(exactSourceUrl: source.bookSourceUrl, exactBookUrl: bookUrl)).flatMap { self.bookCache[$0] }
                var ensured = try {
                    if let bindingV2 {
                        return BookBinding(from: bindingV2)
                    }
                    return try BookBindingStore.shared.bind(
                        bookUrl: bookUrl,
                        sourceUrl: source.bookSourceUrl,
                        sourceName: source.bookSourceName,
                        name: cached?.name ?? "",
                        author: cached?.author ?? "",
                        coverUrl: cached?.coverUrl ?? ""
                    )
                }()
                // 旧绑定可能无书名；正文 payload 必须带真名，否则 hooks 会落到斗破目录
                if ensured.name.isEmpty, let cached, !cached.name.isEmpty {
                    ensured = try BookBindingStore.shared.bind(
                        bookUrl: bookUrl,
                        sourceUrl: ensured.sourceUrl.isEmpty ? source.bookSourceUrl : ensured.sourceUrl,
                        sourceName: ensured.sourceName.isEmpty ? source.bookSourceName : ensured.sourceName,
                        name: cached.name,
                        author: ensured.author.isEmpty ? (cached.author) : ensured.author,
                        coverUrl: ensured.coverUrl.isEmpty ? (cached.coverUrl ?? "") : ensured.coverUrl,
                        bridgeToken: ensured.bridgeToken,
                        sourceAvailable: ensured.sourceAvailable
                    )
                }
                let book = cached ?? BridgeBook(
                    bookUrl: bookUrl,
                    sourceUrl: source.bookSourceUrl,
                    sourceName: source.bookSourceName
                )
                let chapter = BridgeChapter(title: "", url: chapterUrl, index: 0)
                // 与搜索同级硬超时：避免「章节加载中」挂死（验收 J-03 / user-journey J2）
                let contentTimeoutSeconds: TimeInterval = 20
                var content = try await Self.withTimeout(seconds: contentTimeoutSeconds) {
                    try await BridgeWebBook.getContent(source: source, book: book, chapter: chapter)
                }
                // 书源 ruleContent.replaceRegex：再落一次，防 getContent 映射遗漏；写对照标记供 8.6 验收
                if let rr = source.getContentRule()?.replaceRegex?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !rr.isEmpty {
                    let before = content
                    content = RuleWebBook.applyReplaceRegex(content, regex: rr)
                    let marker = [
                        "ts=\(ISO8601DateFormatter().string(from: Date()))",
                        "replaceRegex=\(rr)",
                        "beforeLen=\(before.count)",
                        "afterLen=\(content.count)",
                        "beforeHasAd=\(before.contains("【广告】"))",
                        "afterHasAd=\(content.contains("【广告】"))",
                        "beforeHasNoise=\(before.contains("XYZ999"))",
                        "afterHasNoise=\(content.contains("XYZ999"))",
                    ].joined(separator: "\n")
                    let path = (NSHomeDirectory() as NSString)
                        .appendingPathComponent("Documents/legado_purify_debug.txt")
                    try? marker.write(toFile: path, atomically: true, encoding: .utf8)
                }
                // 全局/书本级替换净化（书源内 replaceRegex 已在 RuleWebBook 处理）
                content = ReplaceRuleStore.shared.purify(
                    content,
                    bookUrl: bookUrl,
                    chapterUrl: chapterUrl
                )
                // 从目录缓存补齐标题/索引，便于原生 dicContents / divisionText
                //（BridgeBook 无 chapters 字段；由 LBNoteResetContentPosted 用 sPendingCatalog 补）
                let payload = XiangseAdapter.contentPayload(
                    content: content,
                    chapterUrl: chapterUrl,
                    binding: ensured
                )
                self.postNotification(XiangseAdapter.notifyResetContent, userInfo: payload)
                // 阅读页可能尚未注册监听：缓存并由 ReadVC appear / delay 再投
                LBNoteResetContentPosted(payload)
            } catch {
                var errText = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                if let bridgeErr = error as? LegadoBridgeError, case .timeout = bridgeErr {
                    errText = "正文加载超时，请换源或稍后重试"
                }
                if errText.isEmpty {
                    errText = String(describing: error)
                }
                if errText.isEmpty {
                    errText = "getContent failed"
                }
                let errPayload: [String: Any] = [
                    "error": errText,
                    "chapterUrl": chapterUrl,
                    XiangseAdapter.legadoMarkerKey: XiangseAdapter.legadoMarkerValue
                ]
                self.postNotification(
                    XiangseAdapter.notifyResetContent,
                    userInfo: errPayload
                )
                LBNoteResetContentPosted(errPayload)
            }
        }
    }

    // MARK: - CookieJar（可见 WebView / 登录回灌）

    /// 将网页 Cookie 写入内存 CookieJar，供后续 AnalyzeUrl 请求注入。
    @objc(saveCookieJarForUrl:cookieString:)
    public func saveCookieJar(forUrl url: String, cookieString: String) {
        let key: String
        if let host = URL(string: url)?.host, !host.isEmpty {
            key = host
        } else {
            key = url
        }
        guard !key.isEmpty, !cookieString.isEmpty else { return }
        let existing = CookieManager.shared.getCookie(for: key) ?? ""
        let merged = CookieManager.shared.mergeCookies(existing, cookieString)
        CookieManager.shared.saveCookie(url: key, cookieString: merged)
        // 同步用书源 URL 再存一份，兼容 enabledCookieJar 按 bookSourceUrl 取
        if key != url, url.contains("://") {
            let ex2 = CookieManager.shared.getCookie(for: url) ?? ""
            CookieManager.shared.saveCookie(
                url: url,
                cookieString: CookieManager.shared.mergeCookies(ex2, cookieString)
            )
        }
        // 书山等 exploreUrl 把 session 写进 kind URL：Cookie 变了必须重算分类缓存
        invalidateExploreKindsCache(forSourceUrl: nil)

        // 番茄 WebView 回灌：把 sessionid 写入当前发现源「番茄登录Token」，并自动重刷发现
        if Self.hostLooksFanqie(key) || Self.hostLooksFanqie(url),
           let sid = Self.extractSessionId(from: merged), !sid.isEmpty {
            let tokenValue = "sessionid=\(sid)"
            var targets: [String] = []
            if let sel = selectedExploreSourceUrl, !sel.isEmpty { targets.append(sel) }
            // 常见书山根站
            for u in ["https://v1.vossc.com", "https://v2.vossc.com", "https://v3.vossc.com", "https://v4.vossc.com"] {
                if SourceRegistry.shared.source(forUrl: u) != nil { targets.append(u) }
            }
            for src in Set(targets) {
                var map = LoginCredentialStore.infoMap(sourceUrl: src)
                map["番茄登录Token"] = tokenValue
                if let data = try? JSONSerialization.data(withJSONObject: map),
                   let json = String(data: data, encoding: .utf8) {
                    LoginCredentialStore.putInfo(json, sourceUrl: src)
                }
            }
            // 登录完成后自动重拉当前发现源
            let exploreSrc = selectedExploreSourceUrl ?? targets.first
            if let exploreSrc, !exploreSrc.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.handleExploreRequest(sourceUrl: exploreSrc, exploreUrl: nil, page: 1)
                }
            }
        }
    }

    private static func hostLooksFanqie(_ raw: String) -> Bool {
        let lower = raw.lowercased()
        return lower.contains("fanqienovel") || lower.contains("snssdk") || lower.contains("toutiao")
    }

    private static func extractSessionId(from cookieHeader: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"sessionid=([^;\s]+)"#, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(cookieHeader.startIndex..., in: cookieHeader)
        guard let match = regex.firstMatch(in: cookieHeader, options: [], range: range),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: cookieHeader) else {
            return nil
        }
        let sid = String(cookieHeader[r]).trimmingCharacters(in: .whitespacesAndNewlines)
        return sid.isEmpty ? nil : sid
    }

    @objc(cookieJarForUrl:)
    public func cookieJar(forUrl url: String) -> String? {
        if let host = URL(string: url)?.host, !host.isEmpty,
           let c = CookieManager.shared.getCookie(for: host), !c.isEmpty {
            return c
        }
        return CookieManager.shared.getCookie(for: url)
    }

    /// 发现空/失败文案。
    /// loginUi/loginUrl 只表示「能登录」，多数源可选登录；空结果不能仅凭字段就提示需登录。
    /// 仅在硬证据时提登录：session 空、错误文案含登录/login。
    /// 默认发现分类 URL：优先个性推荐 / read_recommend，跳过 fqbookshelf
    private static func preferredExploreKindURL(from kinds: [[String: Any]]) -> String? {
        var fallbackSession: String?
        var fallbackOther: String?
        for item in kinds {
            guard let url = (item["url"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else { continue }
            let ul = url.lowercased()
            let title = (item["title"] as? String) ?? ""
            if ul.contains("fanqienovel.com/fqbookshelf") { continue }
            if ul.contains("read_recommend") || title.contains("个性推荐") {
                return url
            }
            if fallbackSession == nil, ul.contains("session="),
               (ul.contains("/read_") || ul.contains("vossc") || ul.contains("gyks")) {
                fallbackSession = url
            }
            if fallbackOther == nil { fallbackOther = url }
        }
        return fallbackSession ?? fallbackOther
    }

    private static func exploreEmptyHint(
        source: MemoryBridgeBookSource,
        exploreUrl: String?,
        errorMessage: String?
    ) -> String {
        _ = source // 保留参数供后续 loginCheckJs 等扩展
        // 番茄类分类：session 参数为空 → 明确要番茄登录
        if let exploreUrl, exploreUrl.contains("session="),
           exploreUrl.hasSuffix("session=") || exploreUrl.contains("session=&") {
            return "需要番茄登录后才能发现书籍（session 为空）"
        }
        let err = (errorMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if err.contains("登录") || err.lowercased().contains("login") {
            return "需要登录后才能发现书籍"
        }
        if err.isEmpty {
            return "暂无书籍"
        }
        if err.contains("JS") || err.contains("URL") {
            return "发现地址解析失败：\(String(err.prefix(80)))"
        }
        if err.contains("空") || err.lowercased().contains("empty") {
            return "暂无书籍（接口无内容）"
        }
        if err.lowercased().contains("timeout") || err.contains("超时") {
            return "发现加载超时，请稍后重试"
        }
        return "发现加载失败：\(String(err.prefix(80)))"
    }

    /// 解析书源 loginUrl（相对路径相对 bookSourceUrl）
    @objc(loginUrlForSourceUrl:)
    public func loginUrl(forSourceUrl sourceUrl: String?) -> String? {
        guard let sourceUrl, !sourceUrl.isEmpty,
              let src = SourceRegistry.shared.source(forUrl: sourceUrl) else {
            return nil
        }
        guard let raw = src.loginUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        // JS 登录脚本不是可导航 URL；交由 loginUi / 源站回退
        let lower = raw.lowercased()
        if lower.hasPrefix("@js") || lower.hasPrefix("<js")
            || (lower.hasPrefix("//") && lower.contains("function ")) {
            return nil
        }
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            // 少数源把 `@js:` 误写成绝对路径后缀
            if raw.contains("/@js") || raw.hasSuffix("@js:") {
                return nil
            }
            return raw
        }
        if let base = URL(string: src.bookSourceUrl),
           let abs = URL(string: raw, relativeTo: base)?.absoluteString {
            if abs.contains("/@js") || abs.hasSuffix("@js:") {
                return nil
            }
            return abs
        }
        return raw
    }

    /// 书源显示名（登录表单标题用）
    @objc(sourceNameForSourceUrl:)
    public func sourceName(forSourceUrl sourceUrl: String?) -> String {
        guard let sourceUrl, !sourceUrl.isEmpty,
              let src = SourceRegistry.shared.source(forUrl: sourceUrl) else {
            return ""
        }
        let name = src.bookSourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? sourceUrl : name
    }

    /// 书源 loginUi JSON（可能为空）；供 hooks 探针与表单回退
    @objc(loginUiForSourceUrl:)
    public func loginUi(forSourceUrl sourceUrl: String?) -> String? {
        guard let sourceUrl, !sourceUrl.isEmpty,
              let src = SourceRegistry.shared.source(forUrl: sourceUrl) else {
            return nil
        }
        let raw = src.loginUi?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? nil : raw
    }

    /// 规范化后的 loginUi 行数组 JSON：[{name,type,action},...]
    @objc(loginUiRowsJSONForSourceUrl:)
    public func loginUiRowsJSON(forSourceUrl sourceUrl: String?) -> String {
        guard let sourceUrl, !sourceUrl.isEmpty,
              let src = SourceRegistry.shared.source(forUrl: sourceUrl) else {
            return "[]"
        }
        return LoginUiExecutor.rowsJSON(for: src)
    }

    /// 已保存的登录表单 JSON
    @objc(loginInfoJSONForSourceUrl:)
    public func loginInfoJSON(forSourceUrl sourceUrl: String?) -> String {
        guard let sourceUrl, !sourceUrl.isEmpty else { return "" }
        return LoginCredentialStore.getInfo(sourceUrl: sourceUrl)
    }

    /// 已保存的 loginHeader JSON（书山等登录成功后写 apiKey/Cookie）
    @objc(loginHeaderJSONForSourceUrl:)
    public func loginHeaderJSON(forSourceUrl sourceUrl: String?) -> String {
        guard let sourceUrl, !sourceUrl.isEmpty else { return "" }
        return LoginCredentialStore.getHeader(sourceUrl: sourceUrl)
    }

    /// 登录态摘要：有无 info/header/cookie，供 UI 显示证据而非只靠 ok 文案
    @objc(loginStatusSummaryForSourceUrl:)
    public func loginStatusSummary(forSourceUrl sourceUrl: String?) -> String {
        guard let sourceUrl, !sourceUrl.isEmpty else { return "无 sourceUrl" }
        let info = LoginCredentialStore.getInfo(sourceUrl: sourceUrl)
        let header = LoginCredentialStore.getHeader(sourceUrl: sourceUrl)
        let cookie = cookieJar(forUrl: sourceUrl) ?? ""
        var infoKeys: [String] = []
        if let data = info.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            infoKeys = obj.keys.sorted()
        }
        let hasHeader = !header.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasCookie = !cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // 书山等：真登录写 loginHeader(api_key)；仅 cookie 可能是假页残留，不算数
        let verdict: String
        if hasHeader {
            verdict = "已登录痕迹"
        } else if !info.isEmpty && hasCookie {
            verdict = "仅有表单+cookie，无 loginHeader（未真正账号登录）"
        } else if !info.isEmpty {
            verdict = "仅有账号表单，未见 loginHeader"
        } else {
            verdict = "未登录"
        }
        return "\(verdict) | infoKeys=\(infoKeys.joined(separator: ",")) infoLen=\(info.count) headerLen=\(header.count) cookieLen=\(cookie.count)"
    }

    /// 执行 loginUi 按钮 action（formJSON 为字段 map）；返回状态文案
    @objc(runLoginUiActionForSourceUrl:action:formJSON:)
    public func runLoginUiAction(
        forSourceUrl sourceUrl: String?,
        action: String?,
        formJSON: String?
    ) -> String {
        guard let sourceUrl, !sourceUrl.isEmpty,
              let src = SourceRegistry.shared.source(forUrl: sourceUrl) else {
            return "无书源"
        }
        let act = (action ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !act.isEmpty else { return "空 action" }
        let msg = LoginUiExecutor.run(source: src, action: act, formJSON: formJSON, putInfoBeforeEval: true)
        #if DEBUG
        let redacted = BridgeDiagnosticRedactor.redact(.source(url: sourceUrl, name: src.bookSourceName))
        let line = redacted.compactLine(tag: "loginUi")
        let path = (NSHomeDirectory() as NSString).appendingPathComponent("Documents/legado_login_ui_action.txt")
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: path), let fh = FileHandle(forWritingAtPath: path) {
                fh.seekToEndOfFile(); fh.write(data); try? fh.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
        #endif
        return msg
    }

    private func postNotification(_ name: String, userInfo: [String: Any]) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: Notification.Name(name),
                object: nil,
                userInfo: userInfo
            )
        }
    }

    // MARK: - Wave0 能力：封面解密 / 书评 / 听书

    @objc(bookVariableJSONForBookUrl:)
    public func bookVariableJSON(forBookUrl bookUrl: String) -> String {
        BookVariableStore.jsonString(for: bookUrl)
    }

    @objc(putBookVariableForBookUrl:key:value:)
    public func putBookVariable(forBookUrl bookUrl: String, key: String, value: String) {
        BookVariableStore.put(key, value: value, bookUrl: bookUrl)
    }

    @objc(fetchReviewsForBookUrl:completion:)
    public func fetchReviews(forBookUrl bookUrl: String, completion: @escaping (String) -> Void) {
        let sourceUrl: String? = {
            switch BookBindingStore.shared.uniqueLegacyBinding(forBookUrl: bookUrl) {
            case .success(let b): return b.sourceUrl
            case .failure: return nil
            }
        }()
        Task {
            let json = fetchReviewsJSON(bookUrl: bookUrl, sourceUrl: sourceUrl)
            await MainActor.run { completion(json) }
        }
    }

    @objc(isAudioURL:)
    public func isAudioURL(_ url: String) -> Bool {
        HttpTTSEngine.isAudioURL(url)
    }

    @objc(buildHttpTTSURLWithConfigJSON:speakText:)
    public func buildHttpTTSURL(configJSON: String, speakText: String) -> String {
        guard let data = configJSON.data(using: .utf8),
              let cfg = try? JSONDecoder().decode(HttpTTSConfig.self, from: data) else {
            return ""
        }
        return HttpTTSEngine.buildRequestURL(config: cfg, speakText: speakText)
    }

    @objc(fetchAudioToTempFileWithURL:completion:)
    public func fetchAudioToTempFile(url: String, completion: @escaping (String) -> Void) {
        queue.async {
            let data = HttpTTSEngine.fetchAudioData(from: url)
            guard let data, !data.isEmpty else {
                DispatchQueue.main.async { completion("") }
                return
            }
            let path = NSTemporaryDirectory() + "lb_tts_\(abs(url.hashValue)).mp3"
            do {
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
                DispatchQueue.main.async { completion(path) }
            } catch {
                DispatchQueue.main.async { completion("") }
            }
        }
    }

    /// 封面 URL 解密（coverDecodeJs）
    @objc(decodeCoverURL:sourceUrl:)
    public func decodeCoverURL(_ url: String, sourceUrl: String?) -> String {
        let src = sourceUrl.flatMap { SourceRegistry.shared.source(forUrl: $0) }
        let base = src?.bookSourceUrl ?? sourceUrl ?? ""
        return CoverDecodeHelper.decodeCoverURL(
            url,
            decodeJs: src?.coverDecodeJs,
            baseUrl: base,
            source: src
        )
    }

    /// 拉取书评并返回 JSON 数组字符串
    @objc(fetchReviewsJSONForBookUrl:sourceUrl:)
    public func fetchReviewsJSON(bookUrl: String, sourceUrl: String?) -> String {
        final class OutBox: @unchecked Sendable {
            var value = "[]"
        }
        let box = OutBox()
        let sem = DispatchSemaphore(value: 0)
        Task {
            defer { sem.signal() }
            do {
                guard let source = resolveEnabledSource(requested: sourceUrl, bookUrl: bookUrl) else {
                    throw LegadoBridgeError.sourceNotFound
                }
                let reviews = try await BridgeWebBook.fetchReviews(source: source, bookUrl: bookUrl)
                let rows: [[String: String]] = reviews.map {
                    ["avatar": $0.avatar, "content": $0.content, "raw": $0.raw]
                }
                if let data = try? JSONSerialization.data(withJSONObject: rows),
                   let s = String(data: data, encoding: .utf8) {
                    box.value = s
                }
            } catch {
                let msg = error.localizedDescription
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                box.value = #"[{"content":"错误: \#(msg)","avatar":"","raw":""}]"#
            }
        }
        _ = sem.wait(timeout: .now() + 30)
        return box.value
    }

    /// 异步拉取书评并弹出列表（ObjC 入口）
    @objc(presentReviewsForBookUrl:sourceUrl:)
    public func presentReviews(bookUrl: String, sourceUrl: String?) {
        Task {
            // 禁止在此调用 fetchReviewsJSON：其内部 Task+信号量，嵌套在外层 Task 会死锁。
            var json = "[]"
            do {
                guard let source = resolveEnabledSource(requested: sourceUrl, bookUrl: bookUrl) else {
                    throw LegadoBridgeError.sourceNotFound
                }
                let reviews = try await BridgeWebBook.fetchReviews(source: source, bookUrl: bookUrl)
                let rows: [[String: String]] = reviews.map {
                    ["avatar": $0.avatar, "content": $0.content, "raw": $0.raw]
                }
                if let data = try? JSONSerialization.data(withJSONObject: rows),
                   let s = String(data: data, encoding: .utf8) {
                    json = s
                }
            } catch {
                let msg = error.localizedDescription
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                json = #"[{"content":"错误: \#(msg)","avatar":"","raw":""}]"#
            }
            let payload = json
            await MainActor.run {
                LBPresentBookReviewsJSON(bookUrl, payload)
            }
        }
    }

    /// 直链播放音频 URL
    @objc(playAudioURL:)
    @discardableResult
    public func playAudioURL(_ url: String) -> Bool {
        let ok = LBAudioPlayer.shared.prepare(url: url)
        if ok { LBAudioPlayer.shared.play() }
        return ok
    }

    /// 打开听书播控页；优先直链，否则用 HttpTTS 模板合成
    @objc(openTTSForBookUrl:chapterUrl:chapterTitle:speakText:ttsURLTemplate:)
    public func openTTS(
        bookUrl: String,
        chapterUrl: String,
        chapterTitle: String?,
        speakText: String?,
        ttsURLTemplate: String?
    ) {
        Task { @MainActor in
            let vc = LBAudioPlayerVC()
            vc.bookUrl = bookUrl
            vc.chapterTitle = chapterTitle ?? ""
            let player = LBAudioPlayer.shared

            // 1) 直链：章节 URL 或正文
            if HttpTTSEngine.isDirectAudioURL(chapterUrl) {
                _ = player.prepare(url: chapterUrl)
                player.play()
                presentAudioVC(vc)
                return
            }

            // 2) HttpTTS 模板
            if let tpl = ttsURLTemplate?.trimmingCharacters(in: .whitespacesAndNewlines),
               !tpl.isEmpty,
               let text = speakText?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                do {
                    let config = HttpTTSConfig(url: tpl)
                    let data = try await HttpTTSEngine.fetchAudio(config: config, speakText: text)
                    if player.prepare(data: data) {
                        player.play()
                        presentAudioVC(vc)
                        return
                    }
                } catch {
                    DebugLogger.shared.log("[openTTS] \(error)")
                }
            }

            // 3) 回退：把章节 URL 当直链再试一次
            if !chapterUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = player.prepare(url: chapterUrl)
                player.play()
            }
            // 无论音频是否就绪都弹出播控页（失败时仍可看到标题/关闭）
            if vc.chapterTitle.isEmpty {
                vc.chapterTitle = "听书"
            }
            presentAudioVC(vc)
        }
    }

    @objc(presentAudioPlayerForBookUrl:chapterUrl:chapterTitle:)
    public func presentAudioPlayer(bookUrl: String, chapterUrl: String, chapterTitle: String?) {
        openTTS(
            bookUrl: bookUrl,
            chapterUrl: chapterUrl,
            chapterTitle: chapterTitle,
            speakText: nil,
            ttsURLTemplate: nil
        )
    }

    private func presentAudioVC(_ vc: LBAudioPlayerVC) {
#if canImport(UIKit)
        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .formSheet
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let root = scene.windows.first?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        top.present(nav, animated: true)
#endif
    }
}
