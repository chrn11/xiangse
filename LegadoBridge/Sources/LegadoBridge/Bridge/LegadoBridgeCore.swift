import Foundation

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
        if count > 0 {
            NativeSourceInjector.syncToNativeManager(sources: SourceRegistry.shared.allSources())
        }
        return count
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
        let sources = SourceRegistry.shared.allSources()
        NativeSourceInjector.syncToNativeManager(sources: sources)
        postNotification(
            XiangseAdapter.notifyUpdateSourceList,
            userInfo: XiangseAdapter.sourceListPayload(sources: sources)
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

    // MARK: - 搜索

    public func search(keyword: String, sourceUrl: String?) async throws -> [SearchBookResult] {
        guard let source = SourceRegistry.shared.source(forUrl: sourceUrl) else {
            throw LegadoBridgeError.sourceNotFound
        }
        return try await BridgeWebBook.searchBook(source: source, key: keyword)
    }

    @objc(handleSearchRequestWithKeyword:sourceUrl:)
    public func handleSearchRequest(keyword: String, sourceUrl: String?) {
        Task {
            do {
                let activeSource = SourceRegistry.shared.source(forUrl: sourceUrl)
                guard activeSource != nil || sourceUrl != nil else {
                    throw LegadoBridgeError.sourceNotFound
                }
                let results = try await self.search(keyword: keyword, sourceUrl: sourceUrl)
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
                }
                let payload = XiangseAdapter.searchResultsPayload(
                    results: results,
                    keyword: keyword,
                    sourceUrl: sourceUrl ?? activeSource?.bookSourceUrl ?? ""
                )
                self.writeSearchMarker("ok count=\(results.count) key=\(keyword)")
                self.postNotification(XiangseAdapter.notifySearchResponse, userInfo: payload)
            } catch {
                self.writeSearchMarker("err \(error.localizedDescription) key=\(keyword)")
                self.postNotification(
                    XiangseAdapter.notifySearchResponse,
                    userInfo: [
                        "error": error.localizedDescription,
                        "keyword": keyword,
                        "fromLegadoBridge": true,
                        XiangseAdapter.legadoMarkerKey: XiangseAdapter.legadoMarkerValue
                    ]
                )
            }
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
                guard let source = SourceRegistry.shared.source(forUrl: sourceUrl) else {
                    throw LegadoBridgeError.sourceNotFound
                }
                var book = bookCache[bookUrl] ?? BridgeBook(
                    bookUrl: bookUrl,
                    sourceUrl: source.bookSourceUrl,
                    sourceName: source.bookSourceName
                )
                let chapters = try await BridgeWebBook.getChapterList(source: source, book: book)
                bookCache[bookUrl] = book
                let payload = XiangseAdapter.catalogPayload(chapters: chapters, bookUrl: bookUrl)
                postNotification(XiangseAdapter.notifyCatalogResponse, userInfo: payload)
            } catch {
                postNotification(
                    XiangseAdapter.notifyCatalogResponse,
                    userInfo: ["error": error.localizedDescription, "bookUrl": bookUrl]
                )
            }
        }
    }

    // MARK: - 正文

    @objc(handleContentRequestWithChapterUrl:bookUrl:sourceUrl:)
    public func handleContentRequest(chapterUrl: String, bookUrl: String, sourceUrl: String?) {
        Task {
            do {
                guard let source = SourceRegistry.shared.source(forUrl: sourceUrl) else {
                    throw LegadoBridgeError.sourceNotFound
                }
                let book = bookCache[bookUrl] ?? BridgeBook(bookUrl: bookUrl, sourceUrl: source.bookSourceUrl)
                let chapter = BridgeChapter(title: "", url: chapterUrl, index: 0)
                let content = try await BridgeWebBook.getContent(source: source, book: book, chapter: chapter)
                let payload = XiangseAdapter.contentPayload(content: content, chapterUrl: chapterUrl)
                postNotification(XiangseAdapter.notifyResetContent, userInfo: payload)
            } catch {
                postNotification(
                    XiangseAdapter.notifyResetContent,
                    userInfo: ["error": error.localizedDescription, "chapterUrl": chapterUrl]
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
