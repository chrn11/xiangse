import Foundation
import LegadoRuleCore

/// LegadoBridge 对外门面 — Swift 与 ObjC Hook 层统一入口
@objc public final class LegadoBridgeCore: NSObject {
    @objc public static let shared = LegadoBridgeCore()
    @objc public static let bridgeVersion = "1.0.0-mvp"

    private var bookCache: [String: BridgeBook] = [:]
    private let queue = DispatchQueue(label: "com.xiangse.legado-bridge", qos: .userInitiated)

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
        let count = SourceRegistry.shared.restoreFromDiskIfNeeded()
        // 书籍绑定与书源分文件；启动时一并恢复，避免重启串源
        _ = BookBindingStore.shared.restoreFromDiskIfNeeded()
        _ = ReplaceRuleStore.shared.restoreFromDiskIfNeeded()
        ReplaceRuleStore.shared.installPresetsIfEmpty()
        if count > 0 {
            let enabled = SourceRegistry.shared.allSources().filter {
                SourceRegistry.shared.isEnabled(url: $0.bookSourceUrl)
            }
            NativeSourceInjector.syncToNativeManager(sources: enabled)
        }
        return count
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
        if let url = BookBindingStore.shared.sourceUrl(forBookUrl: bookUrl) {
            return url
        }
        return bookCache[bookUrl]?.sourceUrl
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

    /// 触发发现请求；结果走搜索响应通知（带 fromExplore）
    @objc(handleExploreRequestWithSourceUrl:exploreUrl:page:)
    public func handleExploreRequest(sourceUrl: String?, exploreUrl: String?, page: Int) {
        Task {
            let targets: [MemoryBridgeBookSource]
            if let sourceUrl, !sourceUrl.isEmpty,
               let one = SourceRegistry.shared.source(forUrl: sourceUrl),
               SourceRegistry.shared.isEnabled(url: one.bookSourceUrl) {
                targets = [one]
            } else {
                targets = SourceRegistry.shared.exploreCapableSources()
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
            var total = 0
            for source in targets {
                do {
                    let results = try await BridgeWebBook.exploreBook(
                        source: source,
                        url: exploreUrl,
                        page: max(page, 1)
                    )
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
                    // 逐本 post，键对齐原生 queryBook；避免 searchBook=数组导致 UI 空列表
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
                    if results.isEmpty {
                        var empty = XiangseAdapter.searchResultsPayload(
                            results: [],
                            keyword: "explore",
                            sourceUrl: source.bookSourceUrl,
                            bindings: [:]
                        )
                        empty["fromExplore"] = true
                        postNotification(XiangseAdapter.notifySearchResponse, userInfo: empty)
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

            let maxConcurrent = 3
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
                        // 旧实现把数组塞进 searchBook → 类型不匹配 → 引擎有结果但 UITableView 空
                        let sourceName = results.first?.sourceName
                            ?? SourceRegistry.shared.exactSource(forUrl: srcUrl)?.bookSourceName
                            ?? ""
                        for r in results {
                            let book = XiangseAdapter.searchBookDict(r, binding: bindings[r.bookUrl])
                            let payload = XiangseAdapter.searchResultNotifyPayload(
                                book: book,
                                keyword: keyword,
                                sourceUrl: srcUrl,
                                sourceName: r.sourceName.isEmpty ? sourceName : r.sourceName
                            )
                            self.postNotification(XiangseAdapter.notifySearchResponse, userInfo: payload)
                        }
                        if results.isEmpty {
                            let payload = XiangseAdapter.searchResultsPayload(
                                results: [],
                                keyword: keyword,
                                sourceUrl: srcUrl,
                                bindings: [:]
                            )
                            self.postNotification(XiangseAdapter.notifySearchResponse, userInfo: payload)
                        }
                    case .failure(let error):
                        // 单源失败不阻断其他源
                        self.writeSearchMarker("partial err src=\(srcUrl) \(error.localizedDescription)")
                    }
                }
            }
            writeSearchMarker("ok total=\(totalCount) sources=\(targets.count) key=\(keyword)")
        }
    }

    private func writeSearchMarker(_ msg: String) {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent("Documents/legado_search_last.txt")
        try? msg.write(toFile: path, atomically: true, encoding: .utf8)
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
                let resolvedUrl = sourceUrl
                    ?? binding?.sourceUrl
                    ?? bookCache[bookUrl]?.sourceUrl
                guard let source = SourceRegistry.shared.exactSource(forUrl: resolvedUrl),
                      SourceRegistry.shared.isEnabled(url: source.bookSourceUrl) else {
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
                let chapters = try await BridgeWebBook.getChapterList(source: source, book: book)
                bookCache[bookUrl] = book
                let payload = XiangseAdapter.catalogPayload(
                    chapters: chapters,
                    bookUrl: bookUrl,
                    binding: ensured
                )
                postNotification(XiangseAdapter.notifyCatalogResponse, userInfo: payload)
            } catch {
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

    // MARK: - 正文

    @objc(handleContentRequestWithChapterUrl:bookUrl:sourceUrl:)
    public func handleContentRequest(chapterUrl: String, bookUrl: String, sourceUrl: String?) {
        Task {
            do {
                let binding = BookBindingStore.shared.binding(forBookUrl: bookUrl)
                if let binding, !binding.sourceAvailable {
                    throw LegadoBridgeError.engineError("书源不可用，请重新导入或换源后重试")
                }
                let resolvedUrl = sourceUrl
                    ?? binding?.sourceUrl
                    ?? bookCache[bookUrl]?.sourceUrl
                guard let source = SourceRegistry.shared.exactSource(forUrl: resolvedUrl),
                      SourceRegistry.shared.isEnabled(url: source.bookSourceUrl) else {
                    throw LegadoBridgeError.sourceNotFound
                }
                let ensured = binding ?? BookBindingStore.shared.bind(
                    bookUrl: bookUrl,
                    sourceUrl: source.bookSourceUrl,
                    sourceName: source.bookSourceName,
                    name: bookCache[bookUrl]?.name ?? "",
                    author: bookCache[bookUrl]?.author ?? "",
                    coverUrl: bookCache[bookUrl]?.coverUrl ?? ""
                )
                let book = bookCache[bookUrl] ?? BridgeBook(
                    bookUrl: bookUrl,
                    sourceUrl: source.bookSourceUrl,
                    sourceName: source.bookSourceName
                )
                let chapter = BridgeChapter(title: "", url: chapterUrl, index: 0)
                var content = try await BridgeWebBook.getContent(source: source, book: book, chapter: chapter)
                // 全局/书本级替换净化（书源内 replaceRegex 已在 RuleWebBook 处理）
                content = ReplaceRuleStore.shared.purify(
                    content,
                    bookUrl: bookUrl,
                    chapterUrl: chapterUrl
                )
                let payload = XiangseAdapter.contentPayload(
                    content: content,
                    chapterUrl: chapterUrl,
                    binding: ensured
                )
                postNotification(XiangseAdapter.notifyResetContent, userInfo: payload)
            } catch {
                postNotification(
                    XiangseAdapter.notifyResetContent,
                    userInfo: [
                        "error": error.localizedDescription,
                        "chapterUrl": chapterUrl,
                        XiangseAdapter.legadoMarkerKey: XiangseAdapter.legadoMarkerValue
                    ]
                )
            }
        }
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
