import Foundation
import LegadoRuleCore
import LegadoBridgeHooks

/// LegadoBridge 对外门面 — Swift 与 ObjC Hook 层统一入口
@objc public final class LegadoBridgeCore: NSObject {
    @objc public static let shared = LegadoBridgeCore()
    @objc public static let bridgeVersion = "1.0.0-mvp"

    private var bookCache: [String: BridgeBook] = [:]
    private let queue = DispatchQueue(label: "com.xiangse.legado-bridge", qos: .userInitiated)
    /// 并发 explore 世代号：后发请求作废先发的 clear/inject
    private var sExploreGeneration: UInt64 = 0

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
        // 书籍绑定与书源分文件；启动时一并恢复，避免重启串源
        _ = BookBindingStore.shared.restoreFromDiskIfNeeded()
        _ = ReplaceRuleStore.shared.restoreFromDiskIfNeeded()
        ReplaceRuleStore.shared.installPresetsIfEmpty()
        if count > 0 {
            let enabled = SourceRegistry.shared.allSources().filter {
                SourceRegistry.shared.isEnabled(url: $0.bookSourceUrl)
            }
            // D0：延后 sync，等原生站点表就绪后再 merge；超时放弃而非空表 save
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

    /// 搜索/详情记住 bookUrl↔sourceUrl↔token；落盘后重启可反查
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
        let binding = BookBindingStore.shared.bind(
            bookUrl: bookUrl,
            sourceUrl: sourceUrl,
            sourceName: sourceName ?? "",
            name: name ?? "",
            author: author ?? "",
            coverUrl: coverUrl ?? "",
            bridgeToken: bridgeToken
        )
        let book = BridgeBook(
            name: binding.name,
            author: binding.author,
            bookUrl: binding.bookUrl,
            coverUrl: binding.coverUrl,
            intro: "",
            sourceUrl: binding.sourceUrl,
            sourceName: binding.sourceName
        )
        bookCache[binding.bookUrl] = book
        return binding.bridgeToken
    }

    @objc(sourceUrlForBookUrl:)
    public func sourceUrl(forBookUrl bookUrl: String) -> String? {
        // 优先返回「注册表里真实存在」的源，避免陈旧 binding（如错误端口）把正文打成 sourceNotFound
        if let source = resolveEnabledSource(requested: nil, bookUrl: bookUrl) {
            return source.bookSourceUrl
        }
        if let url = BookBindingStore.shared.sourceUrl(forBookUrl: bookUrl) {
            return url
        }
        return bookCache[bookUrl]?.sourceUrl
    }

    /// 去掉空串/空白，避免 ObjC 传入 "" 时短路 `??` 回退链
    private static func nonEmptyURL(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// 从 bookUrl / 任意 URL 取 scheme://host[:port]，用于 mock 源端口纠偏
    private static func originURL(from raw: String?) -> String? {
        guard let raw = nonEmptyURL(raw), let u = URL(string: raw),
              let scheme = u.scheme, let host = u.host, !scheme.isEmpty, !host.isEmpty else {
            return nil
        }
        if let port = u.port {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    /// 按候选顺序解析已启用书源：请求 > binding > 缓存 > bookUrl 源站
    private func resolveEnabledSource(requested: String?, bookUrl: String) -> MemoryBridgeBookSource? {
        let binding = BookBindingStore.shared.binding(forBookUrl: bookUrl)
        var candidates: [String] = []
        let rawList: [String?] = [
            Self.nonEmptyURL(requested),
            Self.nonEmptyURL(binding?.sourceUrl),
            Self.nonEmptyURL(bookCache[bookUrl]?.sourceUrl),
            Self.originURL(from: bookUrl),
            Self.originURL(from: requested),
            Self.originURL(from: binding?.sourceUrl),
        ]
        for item in rawList {
            guard let item, !candidates.contains(item) else { continue }
            candidates.append(item)
        }
        var hit: MemoryBridgeBookSource?
        for url in candidates {
            if let source = SourceRegistry.shared.exactSource(forUrl: url),
               SourceRegistry.shared.isEnabled(url: source.bookSourceUrl) {
                hit = source
                break
            }
        }
        let marker = [
            "ts=\(ISO8601DateFormatter().string(from: Date()))",
            "book=\(bookUrl)",
            "requested=\(Self.nonEmptyURL(requested) ?? "-")",
            "binding=\(Self.nonEmptyURL(binding?.sourceUrl) ?? "-")",
            "candidates=\(candidates.joined(separator: ","))",
            "hit=\(hit?.bookSourceUrl ?? "-")",
            "regCount=\(SourceRegistry.shared.allSources().count)",
        ].joined(separator: " ")
        let path = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Documents/legado_source_resolve.txt")
        try? marker.write(toFile: path, atomically: true, encoding: .utf8)
        return hit
    }

    @objc(bridgeTokenForBookUrl:)
    public func bridgeToken(forBookUrl bookUrl: String) -> String? {
        BookBindingStore.shared.binding(forBookUrl: bookUrl)?.bridgeToken
    }

    @objc(detailDictForBookUrl:)
    public func detailDict(forBookUrl bookUrl: String) -> NSDictionary? {
        guard let binding = BookBindingStore.shared.binding(forBookUrl: bookUrl) else { return nil }
        return XiangseAdapter.detailDict(from: binding) as NSDictionary
    }

    @objc(isBookSourceAvailable:)
    public func isBookSourceAvailable(_ bookUrl: String) -> Bool {
        BookBindingStore.shared.binding(forBookUrl: bookUrl)?.sourceAvailable ?? true
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
        let count = try SourceRegistry.shared.importJSONData(data)
        let enabled = SourceRegistry.shared.allSources().filter {
            SourceRegistry.shared.isEnabled(url: $0.bookSourceUrl)
        }
        // 重新导入同源后，恢复此前「书源不可用」标记的绑定
        for s in enabled {
            BookBindingStore.shared.markSourceAvailable(sourceUrl: s.bookSourceUrl)
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
        NativeSourceInjector.allLegadoSourceNames()
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

    // MARK: - 书源管理（增删改）

    @objc(removeSource:)
    public func removeSource(_ url: String) {
        let names = SourceRegistry.shared.allSources()
            .filter { $0.bookSourceUrl == url }
            .map(\.bookSourceName)
        SourceRegistry.shared.removeSource(url: url)
        NativeSourceInjector.removeFromNativeManager(names: names)
        // 删源策略：默认保留书籍绑定并标记书源不可用（待 iOS MCP 复核原版语义后可切换）
        BookBindingStore.shared.applySourceDeleted(sourceUrl: url)
        // 清内存缓存中依赖该源的书，避免继续用已删源拉目录
        bookCache = bookCache.filter { $0.value.sourceUrl != url }
        resyncNativeList()
    }

    @objc(setSourceEnabled:enabled:)
    public func setSourceEnabled(_ url: String, enabled: Bool) {
        let wasEnabled = SourceRegistry.shared.isEnabled(url: url)
        SourceRegistry.shared.setEnabled(url: url, enabled: enabled)
        if wasEnabled != enabled {
            if enabled {
                resyncNativeList()
            } else {
                let names = SourceRegistry.shared.allSources()
                    .filter { $0.bookSourceUrl == url }
                    .map(\.bookSourceName)
                NativeSourceInjector.removeFromNativeManager(names: names)
            }
        }
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
                let old = BookBindingStore.shared.binding(forBookUrl: oldBookUrl)
                var book = BridgeBook(
                    name: old?.name ?? bookCache[oldBookUrl]?.name ?? "",
                    author: old?.author ?? bookCache[oldBookUrl]?.author ?? "",
                    bookUrl: newBookUrl,
                    coverUrl: old?.coverUrl ?? bookCache[oldBookUrl]?.coverUrl ?? "",
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
                // 旧 bookUrl 与新不同时，保留旧记录但标记不可用，写入新绑定
                if oldBookUrl != newBookUrl,
                   let stale = BookBindingStore.shared.binding(forBookUrl: oldBookUrl) {
                    _ = BookBindingStore.shared.bind(
                        bookUrl: stale.bookUrl,
                        sourceUrl: stale.sourceUrl,
                        sourceName: stale.sourceName,
                        name: stale.name,
                        author: stale.author,
                        coverUrl: stale.coverUrl,
                        bridgeToken: stale.bridgeToken,
                        sourceAvailable: false
                    )
                }
                let binding = BookBindingStore.shared.bind(
                    bookUrl: newBookUrl,
                    sourceUrl: source.bookSourceUrl,
                    sourceName: source.bookSourceName,
                    name: book.name.isEmpty ? (old?.name ?? "") : book.name,
                    author: book.author.isEmpty ? (old?.author ?? "") : book.author,
                    coverUrl: book.coverUrl.isEmpty ? (old?.coverUrl ?? "") : book.coverUrl
                )
                bookCache[newBookUrl] = book
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
            }
        }
    }

    // MARK: - 发现

    /// 当前发现源（点「切换」后写入）；空则用第一个可发现源
    @objc public var selectedExploreSourceUrl: String? {
        get { UserDefaults.standard.string(forKey: "legado_selected_explore_source") }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: "legado_selected_explore_source")
            } else {
                UserDefaults.standard.removeObject(forKey: "legado_selected_explore_source")
            }
        }
    }

    /// 某源 exploreUrl 解析出的分类标签：[{title,url},…]
    @objc(exploreKindsJSONForSourceUrl:)
    public func exploreKindsJSON(forSourceUrl sourceUrl: String?) -> String {
        let src: MemoryBridgeBookSource?
        if let sourceUrl, !sourceUrl.isEmpty {
            src = SourceRegistry.shared.source(forUrl: sourceUrl)
        } else if let sel = selectedExploreSourceUrl, !sel.isEmpty {
            src = SourceRegistry.shared.source(forUrl: sel)
        } else {
            src = SourceRegistry.shared.exploreCapableSources().first
        }
        guard let src, let raw = src.exploreUrl, !raw.isEmpty else {
            return "[]"
        }
        var kinds = RuleWebBook.parseExploreKinds(raw).map { ["title": $0.title, "url": $0.url] }
        // 领域书库：源里常只配单条玄幻 URL，按站点固定分类表展开（与书源注释一致）
        if kinds.count == 1 {
            let key = (sourceUrl?.isEmpty == false ? sourceUrl! : src.bookSourceUrl).lowercased()
            if key.contains("lysxh.com") {
                let fenlei: [(String, String)] = [
                    ("玄幻", "/fenlei/xuanhuan/{{page}}/"),
                    ("武侠", "/fenlei/wuxia/{{page}}/"),
                    ("都市", "/fenlei/dushi/{{page}}/"),
                    ("历史", "/fenlei/lishi/{{page}}/"),
                    ("网游", "/fenlei/wangyou/{{page}}/"),
                    ("科幻", "/fenlei/kehuan/{{page}}/"),
                    ("女生", "/fenlei/nvsheng/{{page}}/")
                ]
                kinds = fenlei.map { ["title": $0.0, "url": $0.1] }
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: kinds),
              let s = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return s
    }

    /// 可发现源摘要：[{name,url,type},…]；type=bookSourceType（0文本/1音频/2图片/3文件）
    @objc public var exploreCapableSourcesJSON: String {
        let rows: [[String: Any]] = SourceRegistry.shared.exploreCapableSources().map { src in
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
        // 并发 explore 用世代号丢弃过期结果，避免后发 clear 清掉先发 inject
        sExploreGeneration &+= 1
        let generation = sExploreGeneration
        Task {
            let targets: [MemoryBridgeBookSource]
            if let sourceUrl, !sourceUrl.isEmpty,
               let one = SourceRegistry.shared.source(forUrl: sourceUrl),
               SourceRegistry.shared.isEnabled(url: one.bookSourceUrl) {
                targets = [one]
                selectedExploreSourceUrl = one.bookSourceUrl
            } else if let sel = selectedExploreSourceUrl, !sel.isEmpty,
                      let one = SourceRegistry.shared.source(forUrl: sel),
                      SourceRegistry.shared.isEnabled(url: one.bookSourceUrl),
                      one.supportsExplore {
                targets = [one]
            } else {
                // 发现页按「当前源」拉书，不再一次扫全部源摊平
                if let first = SourceRegistry.shared.exploreCapableSources().first {
                    targets = [first]
                    selectedExploreSourceUrl = first.bookSourceUrl
                } else {
                    targets = []
                }
            }
            guard !targets.isEmpty else {
                postNotification(
                    XiangseAdapter.notifySearchResponse,
                    userInfo: [
                        "error": "无可用发现源",
                        "fromExplore": true,
                        "fromLegadoBridge": true,
                        XiangseAdapter.legadoMarkerKey: XiangseAdapter.legadoMarkerValue
                    ]
                )
                return
            }
            // 换分类/换源：先清空再灌，避免旧书残留
            await MainActor.run {
                guard generation == sExploreGeneration else { return }
                LBClearDiscoverExploreBooks()
            }
            guard generation == sExploreGeneration else { return }
            var total = 0
            for source in targets {
                guard generation == sExploreGeneration else { return }
                do {
                    let results = try await BridgeWebBook.exploreBook(
                        source: source,
                        url: exploreUrl,
                        page: max(page, 1)
                    )
                    guard generation == sExploreGeneration else { return }
                    var bindings: [String: BookBinding] = [:]
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
                        bookCache[r.bookUrl] = book
                        bindings[r.bookUrl] = BookBindingStore.shared.bind(
                            bookUrl: r.bookUrl,
                            sourceUrl: r.sourceUrl,
                            sourceName: r.sourceName,
                            name: r.name,
                            author: r.author,
                            coverUrl: r.coverUrl ?? ""
                        )
                    }
                    total += results.count
                    // 批量灌入，避免逐本 merge 刷屏
                    let books: [[String: Any]] = results.map { r in
                        XiangseAdapter.searchBookDict(r, binding: bindings[r.bookUrl])
                    }
                    if !books.isEmpty {
                        for r in results {
                            let book = XiangseAdapter.searchBookDict(r, binding: bindings[r.bookUrl])
                            var payload = XiangseAdapter.searchResultNotifyPayload(
                                book: book,
                                keyword: "explore",
                                sourceUrl: source.bookSourceUrl,
                                sourceName: r.sourceName
                            )
                            payload["fromExplore"] = true
                            postNotification(XiangseAdapter.notifySearchResponse, userInfo: payload)
                        }
                        await MainActor.run {
                            guard generation == sExploreGeneration else { return }
                            LBApplySearchResultsToUI(books, "explore")
                        }
                    }
                    if results.isEmpty {
                        writeSearchMarker("explore empty src=\(source.bookSourceUrl)")
                    }
                } catch {
                    writeSearchMarker("explore err src=\(source.bookSourceUrl) \(error.localizedDescription)")
                }
            }
            writeSearchMarker("explore ok total=\(total) sources=\(targets.count)")
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
        Task {
            let targets: [MemoryBridgeBookSource]
            if let sourceUrl, !sourceUrl.isEmpty,
               let one = SourceRegistry.shared.source(forUrl: sourceUrl),
               SourceRegistry.shared.isEnabled(url: one.bookSourceUrl) {
                targets = [one]
            } else {
                // nil / 空：全部启用源并行搜，避免只吃第一个
                targets = SourceRegistry.shared.allSources().filter {
                    SourceRegistry.shared.isEnabled(url: $0.bookSourceUrl)
                }
            }
            guard !targets.isEmpty else {
                writeSearchMarker("err no enabled sources key=\(keyword)")
                postNotification(
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

            // fail-open：串行单飞，避免多源并发通知/UI 灌入打崩原生 UITableView
            let maxConcurrent = 1
            var nextIndex = 0
            var totalCount = 0
            await withTaskGroup(of: (String, Result<[SearchBookResult], Error>).self) { group in
                var inFlight = 0
                while nextIndex < targets.count || inFlight > 0 {
                    while inFlight < maxConcurrent && nextIndex < targets.count {
                        let source = targets[nextIndex]
                        nextIndex += 1
                        inFlight += 1
                        group.addTask {
                            do {
                                let results = try await BridgeWebBook.searchBook(source: source, key: keyword)
                                return (source.bookSourceUrl, .success(results))
                            } catch {
                                return (source.bookSourceUrl, .failure(error))
                            }
                        }
                    }
                    guard let finished = await group.next() else { break }
                    inFlight -= 1
                    let (srcUrl, result) = finished
                    switch result {
                    case .success(let results):
                        var bindings: [String: BookBinding] = [:]
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
                            self.bookCache[r.bookUrl] = book
                            let binding = BookBindingStore.shared.bind(
                                bookUrl: r.bookUrl,
                                sourceUrl: r.sourceUrl,
                                sourceName: r.sourceName,
                                name: r.name,
                                author: r.author,
                                coverUrl: r.coverUrl ?? ""
                            )
                            bindings[r.bookUrl] = binding
                        }
                        totalCount += results.count
                        // 逐本增量通知：原生 onSearchBookSourceResponse 消费 queryBook（字典）
                        let sourceName = results.first?.sourceName
                            ?? SourceRegistry.shared.exactSource(forUrl: srcUrl)?.bookSourceName
                            ?? ""
                        for r in results {
                            let book = XiangseAdapter.searchBookDict(r, binding: bindings[r.bookUrl])
                            guard Self.isSafeSearchBookDict(book) else {
                                self.writeSearchMarker("skip unsafe book src=\(srcUrl)")
                                continue
                            }
                            let payload = XiangseAdapter.searchResultNotifyPayload(
                                book: book,
                                keyword: keyword,
                                sourceUrl: srcUrl,
                                sourceName: r.sourceName.isEmpty ? sourceName : r.sourceName
                            )
                            self.postNotification(XiangseAdapter.notifySearchResponse, userInfo: payload)
                            // 直接灌入 arrBaseData：通知 handler 不在搜索页，仅靠通知 UI 永远空
                            LBApplySearchResultsToUI([book], keyword)
                        }
                        // 空结果：不 post 含 searchBook=[] 的批量载荷（原生 objectForKey 易崩）
                    case .failure(let error):
                        // 单源失败不阻断其他源
                        self.writeSearchMarker("partial err src=\(srcUrl) \(error.localizedDescription)")
                    }
                }
            }
            writeSearchMarker("ok total=\(totalCount) sources=\(targets.count) key=\(keyword)")
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

    private func writeSearchMarker(_ msg: String) {
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
                let binding = BookBindingStore.shared.binding(forBookUrl: bookUrl)
                if let binding, !binding.sourceAvailable {
                    throw LegadoBridgeError.engineError("书源不可用，请重新导入或换源后重试")
                }
                guard let source = resolveEnabledSource(requested: sourceUrl, bookUrl: bookUrl) else {
                    throw LegadoBridgeError.sourceNotFound
                }
                // 目录请求侧再次落盘，防止仅内存映射丢失
                let ensured = BookBindingStore.shared.bind(
                    bookUrl: bookUrl,
                    sourceUrl: source.bookSourceUrl,
                    sourceName: {
                        if let binding, !binding.sourceName.isEmpty { return binding.sourceName }
                        return source.bookSourceName
                    }(),
                    name: binding?.name ?? bookCache[bookUrl]?.name ?? "",
                    author: binding?.author ?? bookCache[bookUrl]?.author ?? "",
                    coverUrl: binding?.coverUrl ?? bookCache[bookUrl]?.coverUrl ?? "",
                    bridgeToken: binding?.bridgeToken
                )
                var book = bookCache[bookUrl] ?? BridgeBook(
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
                if book.tocUrl.isEmpty || book.tocUrl == book.bookUrl {
                    _ = try await BridgeWebBook.getBookInfo(source: source, book: &book)
                }
                let chapters = try await BridgeWebBook.getChapterList(source: source, book: book)
                bookCache[bookUrl] = book
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
                // 8.5：目录网络失败时尝试盘缓存（与 C 侧 LBCatalogCachePath 规则对齐）
                let cacheDir = (NSHomeDirectory() as NSString)
                    .appendingPathComponent("Documents/legado_catalog_cache")
                let allowed = CharacterSet.alphanumerics
                var safe = ""
                for ch in bookUrl.unicodeScalars {
                    safe.append(allowed.contains(ch) ? Character(ch) : "_")
                }
                if safe.count > 120 {
                    safe = String(safe.suffix(120))
                }
                let file = (cacheDir as NSString).appendingPathComponent("\(safe).json")
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
                let binding = BookBindingStore.shared.binding(forBookUrl: bookUrl)
                if let binding, !binding.sourceAvailable {
                    throw LegadoBridgeError.engineError("书源不可用，请重新导入或换源后重试")
                }
                guard let source = self.resolveEnabledSource(requested: sourceUrl, bookUrl: bookUrl) else {
                    throw LegadoBridgeError.sourceNotFound
                }
                let ensured = binding ?? BookBindingStore.shared.bind(
                    bookUrl: bookUrl,
                    sourceUrl: source.bookSourceUrl,
                    sourceName: source.bookSourceName,
                    name: self.bookCache[bookUrl]?.name ?? "",
                    author: self.bookCache[bookUrl]?.author ?? "",
                    coverUrl: self.bookCache[bookUrl]?.coverUrl ?? ""
                )
                let book = self.bookCache[bookUrl] ?? BridgeBook(
                    bookUrl: bookUrl,
                    sourceUrl: source.bookSourceUrl,
                    sourceName: source.bookSourceName
                )
                let chapter = BridgeChapter(title: "", url: chapterUrl, index: 0)
                var content = try await BridgeWebBook.getContent(source: source, book: book, chapter: chapter)
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
        let path = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Documents/legado_cookie_jar.txt")
        let line = "save key=\(key) len=\(merged.count) src=\(url)\n"
        if let data = line.data(using: .utf8) {
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? line.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }

    @objc(cookieJarForUrl:)
    public func cookieJar(forUrl url: String) -> String? {
        if let host = URL(string: url)?.host, !host.isEmpty,
           let c = CookieManager.shared.getCookie(for: host), !c.isEmpty {
            return c
        }
        return CookieManager.shared.getCookie(for: url)
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
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            return raw
        }
        if let base = URL(string: src.bookSourceUrl),
           let abs = URL(string: raw, relativeTo: base)?.absoluteString {
            return abs
        }
        return raw
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

    private func postNotification(_ name: String, userInfo: [String: Any]) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: Notification.Name(name),
                object: nil,
                userInfo: userInfo
            )
        }
    }
}
