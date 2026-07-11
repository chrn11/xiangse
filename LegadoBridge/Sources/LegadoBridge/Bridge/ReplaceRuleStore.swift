import Foundation
import LegadoRuleCore

/// 替换净化规则持久化 — Documents/legado_bridge_replace_rules.json
final class ReplaceRuleStore {
    static let shared = ReplaceRuleStore()

    private var rules: [ReplaceRuleItem] = []
    private let lock = NSLock()
    private var didRestore = false

    private static var persistFileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        return docs.appendingPathComponent("legado_bridge_replace_rules.json")
    }

    private init() {}

    @discardableResult
    func restoreFromDiskIfNeeded() -> Int {
        lock.lock()
        if didRestore {
            let n = rules.count
            lock.unlock()
            return n
        }
        didRestore = true
        lock.unlock()

        let url = Self.persistFileURL
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              let decoded = try? JSONDecoder().decode([ReplaceRuleItem].self, from: data) else {
            return 0
        }
        lock.lock()
        rules = decoded
        let count = rules.count
        lock.unlock()
        return count
    }

    func allRules() -> [ReplaceRuleItem] {
        restoreFromDiskIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return rules
    }

    func enabledRules(
        bookScopeId: String? = nil,
        chapterScopeId: String? = nil
    ) -> [ReplaceRuleItem] {
        allRules().filter { rule in
            guard rule.enabled else { return false }
            if rule.scope.isEmpty || rule.scope == "global" { return true }
            if rule.scope == "book", let bookScopeId, rule.scopeId == bookScopeId { return true }
            if rule.scope == "chapter", let chapterScopeId, rule.scopeId == chapterScopeId {
                return true
            }
            return false
        }
    }

    @discardableResult
    func importJSON(_ json: String, merge: Bool = true) throws -> Int {
        restoreFromDiskIfNeeded()
        switch ReplaceAnalyzer.jsonToReplaceRules(json) {
        case .failure(let error):
            throw error
        case .success(let parsed):
            lock.lock()
            if merge {
                var byId = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) })
                for item in parsed {
                    byId[item.id] = item
                }
                rules = Array(byId.values).sorted { $0.order < $1.order }
            } else {
                rules = parsed
            }
            let count = parsed.count
            lock.unlock()
            persist()
            return count
        }
    }

    func replaceAll(_ items: [ReplaceRuleItem]) {
        restoreFromDiskIfNeeded()
        lock.lock()
        rules = items
        lock.unlock()
        persist()
    }

    func installPresetsIfEmpty() {
        restoreFromDiskIfNeeded()
        lock.lock()
        let empty = rules.isEmpty
        if empty {
            rules = ReplaceEngine.presetRules
        }
        lock.unlock()
        if empty { persist() }
    }

    func purify(_ text: String, bookUrl: String? = nil, chapterUrl: String? = nil) -> String {
        let items = enabledRules(bookScopeId: bookUrl, chapterScopeId: chapterUrl)
        return ReplaceEngine.applyScoped(
            text: text,
            items: items,
            bookScopeId: bookUrl,
            chapterScopeId: chapterUrl
        )
    }

    func resetForTesting(clearPersistFile: Bool = true) {
        lock.lock()
        rules.removeAll()
        didRestore = false
        lock.unlock()
        if clearPersistFile {
            try? FileManager.default.removeItem(at: Self.persistFileURL)
        }
    }

    private func persist() {
        lock.lock()
        let snapshot = rules
        lock.unlock()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: Self.persistFileURL, options: .atomic)
    }
}
