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
    private var activeSessionKey: String?

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
                let token = applySelect(sel, isReselect: false)
                activeSessionKey = token.sessionKey
                return token
            case .reselectSameDiscoverSource(let sel):
                let token = applySelect(sel, isReselect: true)
                activeSessionKey = token.sessionKey
                return token

            case .switchDiscoverSource(let url),
                 .hostControllerRebuilt(let url),
                 .crossModeSwitch(let url):
                let token = applyLegacySwitch(url: url, bumpUI: true)
                activeSessionKey = token.sessionKey
                return token

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
        queue.sync {
            let token = applySelect(selection, isReselect: isReselect)
            activeSessionKey = token.sessionKey
            return token
        }
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

    /// Prepare a Legado explore page only from an existing exact-url selection.
    /// This deliberately never creates a session for an unselected source.
    public func prepareLegadoExplorePageIfSelected(
        exactSourceUrl: String,
        page: Int
    ) -> SourceSessionToken? {
        guard !exactSourceUrl.isEmpty, page > 0 else { return nil }
        return queue.sync {
            let key = SelectionToken.sessionKey(sourceKind: .legado, canonicalID: exactSourceUrl)
            guard activeSessionKey == key, var s = sessions[key], s.sourceKind == .legado,
                  s.exactSourceUrl == exactSourceUrl else { return nil }
            if page == 1 {
                s.contentGeneration &+= 1
                s.page = 1
                s.lastAcceptedPage = 0
                s.requestSequence = 0
            } else {
                s.page = page
            }
            sessions[key] = s
            var token = token(from: s)
            if page > 1 { token.requestSequence = 0 }
            return token
        }
    }

    /// Bind the live native list/snapshot identity to an existing Legado
    /// selection.  This never creates a session: a picker must have selected
    /// the exact URL first, otherwise completion is rejected fail-closed.
    public func bindActiveLegadoContext(
        exactSourceUrl: String,
        ownerControllerIdentity: String,
        definitionFingerprint: String,
        snapshotID: String?,
        nodeID: String?,
        runtimeEpoch: UInt64
    ) -> SourceSessionToken? {
        guard !exactSourceUrl.isEmpty, !ownerControllerIdentity.isEmpty,
              !definitionFingerprint.isEmpty else { return nil }
        return queue.sync {
            let key = SelectionToken.sessionKey(sourceKind: .legado, canonicalID: exactSourceUrl)
            guard activeSessionKey == key, var s = sessions[key],
                  s.sourceKind == .legado, s.exactSourceUrl == exactSourceUrl else { return nil }
            let ownerChanged = s.ownerControllerIdentity != ownerControllerIdentity
            let definitionChanged = s.definitionFingerprint != definitionFingerprint
            let catalogChanged = s.snapshotID != snapshotID || s.nodeID != nodeID || s.runtimeEpoch != runtimeEpoch
            if ownerChanged { s.uiGeneration &+= 1 }
            if definitionChanged { s.definitionGeneration &+= 1 }
            if ownerChanged || definitionChanged || catalogChanged {
                s.contentGeneration &+= 1
                s.page = 1
                s.lastAcceptedPage = 0
                s.requestSequence = 0
            }
            s.ownerControllerIdentity = ownerControllerIdentity
            s.definitionFingerprint = definitionFingerprint
            s.snapshotID = snapshotID
            s.nodeID = nodeID
            s.runtimeEpoch = runtimeEpoch
            sessions[key] = s
            return token(from: s)
        }
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
            guard activeSessionKey == key else {
                return .failure(.routeFailClosed)
            }
            guard let s = sessions[key] else {
                return .failure(.sessionMissing)
            }
            if let reason = validateLegadoPublishIdentity(request) {
                return .failure(reason)
            }
            if let reason = validate(request: request, against: s) {
                return .failure(reason)
            }

            if isFirstPage {
                if request.page != 1 { return .failure(.pageMismatch) }
                // A first-page request starts a fresh sequence (selection or
                // manual refresh resets it to zero).  A non-zero sequence is a
                // previously granted token being replayed.
                if request.requestSequence != 0 || s.requestSequence != 0 {
                    return .failure(.requestSequenceMismatch)
                }
                var next = s
                next.lastAcceptedPage = 1
                next.page = 1
                next.requestSequence &+= 1
                sessions[key] = next
                var granted = request
                granted.requestSequence = next.requestSequence
                return .success(PublishPermit(token: granted, replaceFirstPage: true, appendPage: false))
            }

            if request.page <= 1 || request.page != s.lastAcceptedPage + 1 {
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

    /// Validate a cache-first publication without consuming the network page
    /// sequence.  A subsequent manual refresh still resets the sequence and
    /// must obtain a normal first-page permit.
    public func requestCacheHitPermit(
        for request: SourceSessionToken
    ) -> Result<PublishPermit, PublishRejectReason> {
        queue.sync {
            let key = request.sessionKey
            guard activeSessionKey == key else {
                return .failure(.routeFailClosed)
            }
            guard let s = sessions[key] else {
                return .failure(.sessionMissing)
            }
            if let reason = validateLegadoPublishIdentity(request) {
                return .failure(reason)
            }
            if let reason = validate(request: request, against: s) {
                return .failure(reason)
            }
            guard request.requestSequence == s.requestSequence else {
                return .failure(.requestSequenceMismatch)
            }
            guard request.page == 1 else {
                return .failure(.pageMismatch)
            }
            return .success(PublishPermit(token: request, replaceFirstPage: true, appendPage: false))
        }
    }

    /// 异步副作用核对：captured token 须仍为 active route 且与当前 session 全字段一致。
    public func isStillActiveLegadoPublishContext(_ captured: SourceSessionToken) -> Bool {
        queue.sync {
            guard activeSessionKey == captured.sessionKey else { return false }
            guard let s = sessions[captured.sessionKey], s.sourceKind == .legado else { return false }
            if validateLegadoPublishIdentity(captured) != nil { return false }
            if validate(request: captured, against: s) != nil { return false }
            return captured.page == s.page && captured.requestSequence == s.requestSequence
        }
    }

    /// 测试专用：为已选 Legado 源补齐 normal publish 身份字段。
    public func bindTestLegadoPublishIdentity(exactSourceUrl: String) -> SourceSessionToken? {
        bindActiveLegadoContext(
            exactSourceUrl: exactSourceUrl,
            ownerControllerIdentity: "BookListCon:tests",
            definitionFingerprint: "test-fp",
            snapshotID: "test-snap",
            nodeID: "test-node",
            runtimeEpoch: 0
        )
    }

    /// 测试复位。
    public func resetForTests() {
        queue.sync {
            sessions.removeAll()
            managerGeneration = 0
            registryGeneration = 0
            activeSessionKey = nil
        }
    }

    // MARK: - private

    /// Legado normal publish：coordinator 边界统一强制完整身份字段。
    private func validateLegadoPublishIdentity(
        _ request: SourceSessionToken
    ) -> PublishRejectReason? {
        guard request.sourceKind == .legado else { return nil }
        if request.exactSourceUrl.isEmpty { return .sourceMismatch }
        guard let owner = request.ownerControllerIdentity, !owner.isEmpty else {
            return .ownerMismatch
        }
        guard let fingerprint = request.definitionFingerprint, !fingerprint.isEmpty else {
            return .definitionFingerprintMismatch
        }
        guard let snapshotID = request.snapshotID, !snapshotID.isEmpty else {
            return .snapshotMismatch
        }
        guard let nodeID = request.nodeID, !nodeID.isEmpty else {
            return .nodeMismatch
        }
        return nil
    }

    private func validate(
        request: SourceSessionToken,
        against session: SessionState
    ) -> PublishRejectReason? {
        if request.sourceKind != session.sourceKind { return .sourceKindMismatch }
        if request.canonicalID != session.canonicalID { return .canonicalIDMismatch }
        if request.exactSourceUrl != session.exactSourceUrl { return .sourceMismatch }
        if request.selectionGeneration != session.selectionGeneration {
            return .selectionGenerationMismatch
        }
        if request.managerOrRegistryGeneration != session.managerOrRegistryGeneration {
            return .managerOrRegistryGenerationMismatch
        }
        // Optional identity fields are optional only for sessions that do not
        // select a snapshot/node/owner/fingerprint.  Once the session has a
        // value, a callback that omits it is stale/ambiguous and must fail
        // closed rather than publish into the current UI.
        if request.snapshotID != session.snapshotID { return .snapshotMismatch }
        if request.uiGeneration != session.uiGeneration { return .uiGenerationMismatch }
        if request.definitionGeneration != session.definitionGeneration {
            return .definitionGenerationMismatch
        }
        if request.contentGeneration != session.contentGeneration {
            return .contentGenerationMismatch
        }
        if request.nodeID != session.nodeID { return .nodeMismatch }
        if request.ownerControllerIdentity != session.ownerControllerIdentity {
            return .ownerMismatch
        }
        if request.definitionFingerprint != session.definitionFingerprint {
            return .definitionFingerprintMismatch
        }
        if request.runtimeEpoch != session.runtimeEpoch { return .runtimeEpochMismatch }
        return nil
    }

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
        return Self.tokenDictionary(token) as NSDictionary
    }

    @objc(bindActiveLegadoContextWithExactSourceUrl:ownerIdentity:definitionFingerprint:snapshotID:nodeID:runtimeEpoch:)
    public func bindActiveLegadoContext(
        exactSourceUrl: String,
        ownerIdentity: String,
        definitionFingerprint: String,
        snapshotID: String?,
        nodeID: String?,
        runtimeEpoch: UInt64
    ) -> NSDictionary {
        guard let token = SourceSessionCoordinator.shared.bindActiveLegadoContext(
            exactSourceUrl: exactSourceUrl,
            ownerControllerIdentity: ownerIdentity,
            definitionFingerprint: definitionFingerprint,
            snapshotID: snapshotID,
            nodeID: nodeID,
            runtimeEpoch: runtimeEpoch
        ) else {
            return ["ok": false, "reason": PublishRejectReason.routeFailClosed.rawValue]
        }
        return ["ok": true, "token": Self.tokenDictionary(token)]
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

    @objc(requestCacheHitPublishPermitWithToken:)
    public func requestCacheHitPublishPermit(token: NSDictionary) -> NSDictionary {
        guard let req = Self.token(from: token) else {
            return ["ok": false, "reason": PublishRejectReason.routeFailClosed.rawValue]
        }
        switch SourceSessionCoordinator.shared.requestCacheHitPermit(for: req) {
        case .success(let permit):
            return [
                "ok": true,
                "token": Self.tokenDictionary(permit.token),
                "replaceFirstPage": permit.replaceFirstPage,
                "appendPage": permit.appendPage,
                "cacheHit": true
            ]
        case .failure(let reason):
            return ["ok": false, "reason": reason.rawValue, "cacheHit": true]
        }
    }

    @objc(tokenDictionaryForSourceKind:canonicalID:)
    public func currentTokenDictionary(sourceKind rawKind: Int, canonicalID: String) -> NSDictionary? {
        let kind = Self.kind(from: rawKind)
        guard let token = SourceSessionCoordinator.shared.currentToken(sourceKind: kind, canonicalID: canonicalID) else {
            return nil
        }
        return Self.tokenDictionary(token) as NSDictionary
    }

    static func tokenDictionary(_ token: SourceSessionToken) -> [String: Any] {
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
        ]
    }

    private static func token(from dict: NSDictionary) -> SourceSessionToken? {
        guard let canonicalID = dict["canonicalID"] as? String, !canonicalID.isEmpty,
              let exact = dict["exactSourceUrl"] as? String, !exact.isEmpty,
              let rawKind = (dict["sourceKind"] as? NSNumber)?.intValue else { return nil }
        let kind = Self.kind(from: rawKind)
        guard kind != .unknown,
              let ui = dict["uiGeneration"] as? NSNumber,
              let definition = dict["definitionGeneration"] as? NSNumber,
              let content = dict["contentGeneration"] as? NSNumber,
              let selection = dict["selectionGeneration"] as? NSNumber,
              let registry = dict["managerOrRegistryGeneration"] as? NSNumber,
              let page = dict["page"] as? NSNumber,
              page.intValue > 0,
              let sequence = dict["requestSequence"] as? NSNumber,
              let epoch = dict["runtimeEpoch"] as? NSNumber else { return nil }
        return SourceSessionToken(
            sourceKind: kind,
            canonicalID: canonicalID,
            exactSourceUrl: exact,
            uiGeneration: ui.uint64Value,
            definitionGeneration: definition.uint64Value,
            contentGeneration: content.uint64Value,
            selectionGeneration: selection.uint64Value,
            managerOrRegistryGeneration: registry.uint64Value,
            snapshotID: (dict["snapshotID"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            nodeID: (dict["nodeID"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            page: page.intValue,
            requestSequence: sequence.uint64Value,
            ownerControllerIdentity: (dict["ownerControllerIdentity"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            definitionFingerprint: (dict["definitionFingerprint"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            runtimeEpoch: epoch.uint64Value
        )
    }
}
