import Foundation

// MARK: - SourceKind / SelectionToken（共享路由身份；TC-08I）

public enum SourceKind: String, Equatable, Sendable, Codable {
    case unknown
    case xbs
    case legado
}

/// 不可变选择令牌：路由只认 (SourceKind, canonicalID) + generation。
public struct SelectionToken: Equatable, Sendable {
    public var sourceKind: SourceKind
    /// XBS = raw manager exact sourceName；Legado = exactSourceUrl。
    public var canonicalID: String
    /// 仅展示；禁止参与身份匹配。
    public var displayName: String?
    public var selectionGeneration: UInt64
    public var managerOrRegistryGeneration: UInt64
    public var ownerControllerIdentity: String?

    public init(
        sourceKind: SourceKind,
        canonicalID: String,
        displayName: String? = nil,
        selectionGeneration: UInt64 = 0,
        managerOrRegistryGeneration: UInt64 = 0,
        ownerControllerIdentity: String? = nil
    ) {
        self.sourceKind = sourceKind
        self.canonicalID = canonicalID
        self.displayName = displayName
        self.selectionGeneration = selectionGeneration
        self.managerOrRegistryGeneration = managerOrRegistryGeneration
        self.ownerControllerIdentity = ownerControllerIdentity
    }

    public var sessionKey: String {
        Self.sessionKey(sourceKind: sourceKind, canonicalID: canonicalID)
    }

    public static func sessionKey(sourceKind: SourceKind, canonicalID: String) -> String {
        "\(sourceKind.rawValue)|\(canonicalID)"
    }
}

/// 不可变会话令牌；ObjC 只能持有，不能直接改 generation。
public struct SourceSessionToken: Equatable, Sendable {
    public var sourceKind: SourceKind
    public var canonicalID: String
    public var exactSourceUrl: String
    public var uiGeneration: UInt64
    public var definitionGeneration: UInt64
    public var contentGeneration: UInt64
    public var selectionGeneration: UInt64
    public var managerOrRegistryGeneration: UInt64
    public var snapshotID: String?
    public var nodeID: String?
    public var page: Int
    public var requestSequence: UInt64
    public var ownerControllerIdentity: String?
    public var definitionFingerprint: String?
    public var runtimeEpoch: UInt64

    public init(
        sourceKind: SourceKind = .legado,
        canonicalID: String? = nil,
        exactSourceUrl: String,
        uiGeneration: UInt64,
        definitionGeneration: UInt64,
        contentGeneration: UInt64,
        selectionGeneration: UInt64 = 0,
        managerOrRegistryGeneration: UInt64 = 0,
        snapshotID: String? = nil,
        nodeID: String? = nil,
        page: Int = 1,
        requestSequence: UInt64 = 0,
        ownerControllerIdentity: String? = nil,
        definitionFingerprint: String? = nil,
        runtimeEpoch: UInt64 = 0
    ) {
        let cid = canonicalID ?? exactSourceUrl
        self.sourceKind = sourceKind
        self.canonicalID = cid
        self.exactSourceUrl = exactSourceUrl
        self.uiGeneration = uiGeneration
        self.definitionGeneration = definitionGeneration
        self.contentGeneration = contentGeneration
        self.selectionGeneration = selectionGeneration
        self.managerOrRegistryGeneration = managerOrRegistryGeneration
        self.snapshotID = snapshotID
        self.nodeID = nodeID
        self.page = page
        self.requestSequence = requestSequence
        self.ownerControllerIdentity = ownerControllerIdentity
        self.definitionFingerprint = definitionFingerprint
        self.runtimeEpoch = runtimeEpoch
    }

    public var sessionKey: String {
        SelectionToken.sessionKey(sourceKind: sourceKind, canonicalID: canonicalID)
    }
}

public enum PublishRejectReason: String, Error, Equatable, Sendable {
    case sourceMismatch
    case sourceKindMismatch
    case canonicalIDMismatch
    case snapshotMismatch
    case uiGenerationMismatch
    case definitionGenerationMismatch
    case contentGenerationMismatch
    case selectionGenerationMismatch
    case managerOrRegistryGenerationMismatch
    case nodeMismatch
    case pageMismatch
    case pageNotContiguous
    case requestSequenceMismatch
    case ownerMismatch
    case definitionFingerprintMismatch
    case runtimeEpochMismatch
    case sessionMissing
    case routeFailClosed
}

public struct PublishPermit: Equatable, Sendable {
    public var token: SourceSessionToken
    public var replaceFirstPage: Bool
    public var appendPage: Bool

    public init(token: SourceSessionToken, replaceFirstPage: Bool, appendPage: Bool) {
        self.token = token
        self.replaceFirstPage = replaceFirstPage
        self.appendPage = appendPage
    }
}

public enum SourceSessionEvent: Equatable, Sendable {
    case switchDiscoverSource(exactSourceUrl: String)
    case hostControllerRebuilt(exactSourceUrl: String)
    case crossModeSwitch(exactSourceUrl: String)
    case ruleDefinitionChanged(exactSourceUrl: String)
    case runtimeContextChanged(exactSourceUrl: String)
    case selectChannelOrNode(exactSourceUrl: String, snapshotID: String?, nodeID: String?)
    case manualRefreshFirstPage(exactSourceUrl: String)
    case loadMore(exactSourceUrl: String, page: Int)
    /// 共享路由：按 SelectionToken 切源或 A→A 重选。
    case selectDiscoverSource(SelectionToken)
    case reselectSameDiscoverSource(SelectionToken)
}

/// 唯一会话 owner（串行 queue）；实现计划 §24.4 + TC-08I 双车道 sessionKey。
public final class SourceSessionCoordinator: @unchecked Sendable {
    public static let shared = SourceSessionCoordinator()

    private let queue = DispatchQueue(label: "com.xiangse.legado-bridge.source-session")
    private var sessions: [String: SessionState] = [:]
    private var managerGeneration: UInt64 = 0
    private var registryGeneration: UInt64 = 0

    public init() {}

    private struct SessionState {
        var sourceKind: SourceKind
        var canonicalID: String
        var exactSourceUrl: String
        var uiGeneration: UInt64 = 0
        var definitionGeneration: UInt64 = 0
        var contentGeneration: UInt64 = 0
        var selectionGeneration: UInt64 = 0
        var managerOrRegistryGeneration: UInt64 = 0
        var snapshotID: String?
        var nodeID: String?
        var lastAcceptedPage: Int = 0
        var page: Int = 1
        var requestSequence: UInt64 = 0
        var ownerControllerIdentity: String?
        var definitionFingerprint: String?
        var runtimeEpoch: UInt64 = 0

        var sessionKey: String {
            SelectionToken.sessionKey(sourceKind: sourceKind, canonicalID: canonicalID)
        }
    }

    public func currentManagerGeneration() -> UInt64 {
        queue.sync { managerGeneration }
    }

    public func currentRegistryGeneration() -> UInt64 {
        queue.sync { registryGeneration }
    }

    /// XBS raw manager 列表变更（import / 启停 / 删除）。
    public func bumpManagerGeneration() {
        queue.sync {
            managerGeneration &+= 1
            for (key, var s) in sessions where s.sourceKind == .xbs {
                s.managerOrRegistryGeneration = managerGeneration
                sessions[key] = s
            }
        }
    }

    /// Legado registry 变更（import / 删除 / 启停）。
    public func bumpRegistryGeneration() {
        queue.sync {
            registryGeneration &+= 1
            for (key, var s) in sessions where s.sourceKind == .legado {
                s.managerOrRegistryGeneration = registryGeneration
                sessions[key] = s
            }
        }
    }

    public func apply(_ event: SourceSessionEvent) -> SourceSessionToken {
        queue.sync {
            switch event {
            case .selectDiscoverSource(let sel):
                return applySelect(sel, isReselect: false)
            case .reselectSameDiscoverSource(let sel):
                return applySelect(sel, isReselect: true)

            case .switchDiscoverSource(let url),
                 .hostControllerRebuilt(let url),
                 .crossModeSwitch(let url):
                return applyLegacySwitch(url: url, bumpUI: true)

            case .ruleDefinitionChanged(let url),
                 .runtimeContextChanged(let url):
                let key = legacySessionKey(url)
                var s = sessions[key] ?? legacySessionState(url: url)
                s.definitionGeneration &+= 1
                s.contentGeneration &+= 1
                s.page = 1
                s.lastAcceptedPage = 0
                s.requestSequence = 0
                sessions[key] = s
                return token(from: s)

            case .selectChannelOrNode(let url, let snapshotID, let nodeID):
                let key = legacySessionKey(url)
                var s = sessions[key] ?? legacySessionState(url: url)
                s.contentGeneration &+= 1
                s.snapshotID = snapshotID
                s.nodeID = nodeID
                s.page = 1
                s.lastAcceptedPage = 0
                s.requestSequence = 0
                sessions[key] = s
                return token(from: s)

            case .manualRefreshFirstPage(let url):
                let key = legacySessionKey(url)
                var s = sessions[key] ?? legacySessionState(url: url)
                s.contentGeneration &+= 1
                s.page = 1
                s.lastAcceptedPage = 0
                s.requestSequence = 0
                sessions[key] = s
                return token(from: s)

            case .loadMore(let url, let page):
                let key = legacySessionKey(url)
                var s = sessions[key] ?? legacySessionState(url: url)
                s.page = page
                sessions[key] = s
                return token(from: s)
            }
        }
    }

    public func applySelection(_ selection: SelectionToken, isReselect: Bool = false) -> SourceSessionToken {
        queue.sync { applySelect(selection, isReselect: isReselect) }
    }

    public func currentToken(sourceKind: SourceKind, canonicalID: String) -> SourceSessionToken? {
        let key = SelectionToken.sessionKey(sourceKind: sourceKind, canonicalID: canonicalID)
        return queue.sync {
            guard let s = sessions[key] else { return nil }
            return token(from: s)
        }
    }

    public func currentToken(exactSourceUrl: String) -> SourceSessionToken? {
        currentToken(sourceKind: .legado, canonicalID: exactSourceUrl)
    }

    /// cache hit 发布：不递增任何 generation。
    public func tokenForCacheHit(sourceKind: SourceKind, canonicalID: String) -> SourceSessionToken? {
        currentToken(sourceKind: sourceKind, canonicalID: canonicalID)
    }

    public func tokenForCacheHit(exactSourceUrl: String) -> SourceSessionToken? {
        tokenForCacheHit(sourceKind: .legado, canonicalID: exactSourceUrl)
    }

    public func requestPublishPermit(
        for request: SourceSessionToken,
        isFirstPage: Bool
    ) -> Result<PublishPermit, PublishRejectReason> {
        queue.sync {
            let key = request.sessionKey
            guard let s = sessions[key] else {
                return .failure(.sessionMissing)
            }
            if request.sourceKind != s.sourceKind { return .failure(.sourceKindMismatch) }
            if request.canonicalID != s.canonicalID { return .failure(.canonicalIDMismatch) }
            if request.exactSourceUrl != s.exactSourceUrl { return .failure(.sourceMismatch) }
            if request.selectionGeneration != s.selectionGeneration {
                return .failure(.selectionGenerationMismatch)
            }
            if request.managerOrRegistryGeneration != s.managerOrRegistryGeneration {
                return .failure(.managerOrRegistryGenerationMismatch)
            }
            if let want = request.snapshotID, want != s.snapshotID { return .failure(.snapshotMismatch) }
            if request.uiGeneration != s.uiGeneration { return .failure(.uiGenerationMismatch) }
            if request.definitionGeneration != s.definitionGeneration {
                return .failure(.definitionGenerationMismatch)
            }
            if request.contentGeneration != s.contentGeneration {
                return .failure(.contentGenerationMismatch)
            }
            if let want = request.nodeID, want != s.nodeID { return .failure(.nodeMismatch) }
            if let want = request.ownerControllerIdentity, want != s.ownerControllerIdentity {
                return .failure(.ownerMismatch)
            }
            if let want = request.definitionFingerprint, want != s.definitionFingerprint {
                return .failure(.definitionFingerprintMismatch)
            }
            if request.runtimeEpoch != s.runtimeEpoch { return .failure(.runtimeEpochMismatch) }

            if isFirstPage {
                if request.page != 1 { return .failure(.pageMismatch) }
                var next = s
                next.lastAcceptedPage = 1
                next.page = 1
                next.requestSequence &+= 1
                sessions[key] = next
                var granted = request
                granted.requestSequence = next.requestSequence
                return .success(PublishPermit(token: granted, replaceFirstPage: true, appendPage: false))
            }

            if request.page != s.lastAcceptedPage + 1 {
                return .failure(.pageNotContiguous)
            }
            let expectedSeq = s.requestSequence + 1
            if request.requestSequence != 0 && request.requestSequence != expectedSeq {
                return .failure(.requestSequenceMismatch)
            }
            var next = s
            next.lastAcceptedPage = request.page
            next.page = request.page
            next.requestSequence = expectedSeq
            sessions[key] = next
            var granted = request
            granted.requestSequence = next.requestSequence
            return .success(PublishPermit(token: granted, replaceFirstPage: false, appendPage: true))
        }
    }

    /// 测试复位。
    public func resetForTests() {
        queue.sync {
            sessions.removeAll()
            managerGeneration = 0
            registryGeneration = 0
        }
    }

    // MARK: - private

    private func legacySessionKey(_ exactSourceUrl: String) -> String {
        SelectionToken.sessionKey(sourceKind: .legado, canonicalID: exactSourceUrl)
    }

    private func legacySessionState(url: String) -> SessionState {
        SessionState(
            sourceKind: .legado,
            canonicalID: url,
            exactSourceUrl: url,
            managerOrRegistryGeneration: registryGeneration
        )
    }

    private func applyLegacySwitch(url: String, bumpUI: Bool) -> SourceSessionToken {
        let key = legacySessionKey(url)
        var s = sessions[key] ?? legacySessionState(url: url)
        if bumpUI { s.uiGeneration &+= 1 }
        s.contentGeneration &+= 1
        s.selectionGeneration &+= 1
        s.managerOrRegistryGeneration = registryGeneration
        s.page = 1
        s.lastAcceptedPage = 0
        s.requestSequence = 0
        sessions[key] = s
        return token(from: s)
    }

    private func applySelect(_ sel: SelectionToken, isReselect: Bool) -> SourceSessionToken {
        guard sel.sourceKind != .unknown, !sel.canonicalID.isEmpty else {
            return SourceSessionToken(
                sourceKind: .unknown,
                canonicalID: sel.canonicalID,
                exactSourceUrl: "",
                uiGeneration: 0,
                definitionGeneration: 0,
                contentGeneration: 0
            )
        }
        let key = sel.sessionKey
        let laneGen = sel.sourceKind == .xbs ? managerGeneration : registryGeneration
        let existed = sessions[key] != nil
        var s = sessions[key] ?? SessionState(
            sourceKind: sel.sourceKind,
            canonicalID: sel.canonicalID,
            exactSourceUrl: sel.canonicalID,
            managerOrRegistryGeneration: laneGen
        )
        s.sourceKind = sel.sourceKind
        s.canonicalID = sel.canonicalID
        s.exactSourceUrl = sel.canonicalID
        if let owner = sel.ownerControllerIdentity { s.ownerControllerIdentity = owner }

        if isReselect || existed {
            // A→A：只抬 selectionGeneration，不抬 ui/content
            s.selectionGeneration &+= 1
        } else {
            s.uiGeneration &+= 1
            s.contentGeneration &+= 1
            s.selectionGeneration = 1
            s.page = 1
            s.lastAcceptedPage = 0
            s.requestSequence = 0
        }
        s.managerOrRegistryGeneration = laneGen
        sessions[key] = s
        return token(from: s)
    }

    private func token(from s: SessionState) -> SourceSessionToken {
        SourceSessionToken(
            sourceKind: s.sourceKind,
            canonicalID: s.canonicalID,
            exactSourceUrl: s.exactSourceUrl,
            uiGeneration: s.uiGeneration,
            definitionGeneration: s.definitionGeneration,
            contentGeneration: s.contentGeneration,
            selectionGeneration: s.selectionGeneration,
            managerOrRegistryGeneration: s.managerOrRegistryGeneration,
            snapshotID: s.snapshotID,
            nodeID: s.nodeID,
            page: s.page,
            requestSequence: s.requestSequence,
            ownerControllerIdentity: s.ownerControllerIdentity,
            definitionFingerprint: s.definitionFingerprint,
            runtimeEpoch: s.runtimeEpoch
        )
    }
}

// MARK: - ObjC 共享路由桥（hooks 经 CExports / 直接 @objc 类名调用）

@objc(LBSharedSourceRouter)
public final class LBSharedSourceRouter: NSObject {
    @objc public static let shared = LBSharedSourceRouter()

    @objc public static let sourceKindUnknown = 0
    @objc public static let sourceKindXBS = 1
    @objc public static let sourceKindLegado = 2

    private static func kind(from raw: Int) -> SourceKind {
        switch raw {
        case Self.sourceKindXBS: return .xbs
        case Self.sourceKindLegado: return .legado
        default: return .unknown
        }
    }

    private static func kindRaw(_ kind: SourceKind) -> Int {
        switch kind {
        case .xbs: return sourceKindXBS
        case .legado: return sourceKindLegado
        case .unknown: return sourceKindUnknown
        }
    }

    @objc(bumpManagerGeneration)
    public func bumpManagerGeneration() {
        SourceSessionCoordinator.shared.bumpManagerGeneration()
    }

    @objc(bumpRegistryGeneration)
    public func bumpRegistryGeneration() {
        SourceSessionCoordinator.shared.bumpRegistryGeneration()
    }

    @objc(currentManagerGeneration)
    public func currentManagerGeneration() -> UInt64 {
        SourceSessionCoordinator.shared.currentManagerGeneration()
    }

    @objc(currentRegistryGeneration)
    public func currentRegistryGeneration() -> UInt64 {
        SourceSessionCoordinator.shared.currentRegistryGeneration()
    }

    @objc(applySelectionWithSourceKind:canonicalID:displayName:ownerIdentity:isReselect:)
    public func applySelection(
        sourceKind rawKind: Int,
        canonicalID: String,
        displayName: String?,
        ownerIdentity: String?,
        isReselect: Bool
    ) -> NSDictionary {
        let kind = Self.kind(from: rawKind)
        let laneGen = kind == .xbs
            ? SourceSessionCoordinator.shared.currentManagerGeneration()
            : SourceSessionCoordinator.shared.currentRegistryGeneration()
        let sel = SelectionToken(
            sourceKind: kind,
            canonicalID: canonicalID,
            displayName: displayName,
            managerOrRegistryGeneration: laneGen,
            ownerControllerIdentity: ownerIdentity
        )
        let token = SourceSessionCoordinator.shared.applySelection(sel, isReselect: isReselect)
        return Self.tokenDictionary(token)
    }

    @objc(requestPublishPermitWithToken:isFirstPage:)
    public func requestPublishPermit(token: NSDictionary, isFirstPage: Bool) -> NSDictionary {
        guard let req = Self.token(from: token) else {
            return ["ok": false, "reason": PublishRejectReason.routeFailClosed.rawValue]
        }
        switch SourceSessionCoordinator.shared.requestPublishPermit(for: req, isFirstPage: isFirstPage) {
        case .success(let permit):
            return [
                "ok": true,
                "token": Self.tokenDictionary(permit.token),
                "replaceFirstPage": permit.replaceFirstPage,
                "appendPage": permit.appendPage
            ]
        case .failure(let reason):
            return ["ok": false, "reason": reason.rawValue]
        }
    }

    @objc(tokenDictionaryForSourceKind:canonicalID:)
    public func currentTokenDictionary(sourceKind rawKind: Int, canonicalID: String) -> NSDictionary? {
        let kind = Self.kind(from: rawKind)
        guard let token = SourceSessionCoordinator.shared.currentToken(sourceKind: kind, canonicalID: canonicalID) else {
            return nil
        }
        return Self.tokenDictionary(token)
    }

    private static func tokenDictionary(_ token: SourceSessionToken) -> NSDictionary {
        [
            "sourceKind": kindRaw(token.sourceKind),
            "canonicalID": token.canonicalID,
            "exactSourceUrl": token.exactSourceUrl,
            "selectionGeneration": token.selectionGeneration,
            "managerOrRegistryGeneration": token.managerOrRegistryGeneration,
            "uiGeneration": token.uiGeneration,
            "definitionGeneration": token.definitionGeneration,
            "contentGeneration": token.contentGeneration,
            "snapshotID": token.snapshotID ?? "",
            "nodeID": token.nodeID ?? "",
            "page": token.page,
            "requestSequence": token.requestSequence,
            "ownerControllerIdentity": token.ownerControllerIdentity ?? "",
            "definitionFingerprint": token.definitionFingerprint ?? "",
            "runtimeEpoch": token.runtimeEpoch
        ] as NSDictionary
    }

    private static func token(from dict: NSDictionary) -> SourceSessionToken? {
        guard let canonicalID = dict["canonicalID"] as? String, !canonicalID.isEmpty else { return nil }
        let rawKind = (dict["sourceKind"] as? NSNumber)?.intValue ?? sourceKindLegado
        let kind = Self.kind(from: rawKind)
        let exact = (dict["exactSourceUrl"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? canonicalID
        return SourceSessionToken(
            sourceKind: kind,
            canonicalID: canonicalID,
            exactSourceUrl: exact,
            uiGeneration: (dict["uiGeneration"] as? NSNumber)?.uint64Value ?? 0,
            definitionGeneration: (dict["definitionGeneration"] as? NSNumber)?.uint64Value ?? 0,
            contentGeneration: (dict["contentGeneration"] as? NSNumber)?.uint64Value ?? 0,
            selectionGeneration: (dict["selectionGeneration"] as? NSNumber)?.uint64Value ?? 0,
            managerOrRegistryGeneration: (dict["managerOrRegistryGeneration"] as? NSNumber)?.uint64Value ?? 0,
            snapshotID: (dict["snapshotID"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            nodeID: (dict["nodeID"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            page: (dict["page"] as? NSNumber)?.intValue ?? 1,
            requestSequence: (dict["requestSequence"] as? NSNumber)?.uint64Value ?? 0,
            ownerControllerIdentity: (dict["ownerControllerIdentity"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            definitionFingerprint: (dict["definitionFingerprint"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            runtimeEpoch: (dict["runtimeEpoch"] as? NSNumber)?.uint64Value ?? 0
        )
    }
}
