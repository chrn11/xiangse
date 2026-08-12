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

/// The transport lane used by an explore publication.  Cache publication is
/// deliberately represented by a distinct token type below; a
/// `SourceSessionToken` can only authorize the network lane.
public enum ExplorePublishMode: String, Equatable, Sendable, Codable {
    case networkFirst
    case cacheFallback
    case coldLastGood
}

/// Coordinator-issued authorization for a single Legado cache envelope.
///
/// This is intentionally not convertible from (or interchangeable with) a
/// `SourceSessionToken` at the call boundary.  A cache token carries the
/// complete native/session identity as well as a one-shot nonce.  The
/// coordinator records the exact issued value and consumes the nonce when the
/// cache publication is admitted, so mutating/replaying a captured value is
/// fail-closed.
public struct CachePermitToken: Equatable, Sendable, Codable {
    public var mode: ExplorePublishMode
    public var permitNonce: String
    public var envelopeKeyHash: String
    /// Legado is the ABI source-kind value 2.  The Swift enum keeps the
    /// existing dual-lane vocabulary while the raw value is exposed below for
    /// ObjC/tests that need to inspect the locked numeric contract.
    public var sourceKind: SourceKind
    public var canonicalID: String
    public var exactSourceUrl: String
    public var nodeID: String?
    public var snapshotID: String?
    public var definitionFingerprint: String?
    public var page: Int
    public var requestSequence: UInt64
    public var runtimeEpoch: UInt64
    public var managerOrRegistryGeneration: UInt64
    public var selectionGeneration: UInt64
    public var uiGeneration: UInt64
    public var definitionGeneration: UInt64
    public var contentGeneration: UInt64
    public var ownerControllerIdentity: String?

    public init(
        mode: ExplorePublishMode,
        permitNonce: String,
        envelopeKeyHash: String,
        sourceKind: SourceKind = .legado,
        canonicalID: String,
        exactSourceUrl: String,
        nodeID: String?,
        snapshotID: String?,
        definitionFingerprint: String?,
        page: Int = 1,
        requestSequence: UInt64 = 0,
        runtimeEpoch: UInt64,
        managerOrRegistryGeneration: UInt64,
        selectionGeneration: UInt64,
        uiGeneration: UInt64,
        definitionGeneration: UInt64,
        contentGeneration: UInt64,
        ownerControllerIdentity: String?
    ) {
        self.mode = mode
        self.permitNonce = permitNonce
        self.envelopeKeyHash = envelopeKeyHash
        self.sourceKind = sourceKind
        self.canonicalID = canonicalID
        self.exactSourceUrl = exactSourceUrl
        self.nodeID = nodeID
        self.snapshotID = snapshotID
        self.definitionFingerprint = definitionFingerprint
        self.page = page
        self.requestSequence = requestSequence
        self.runtimeEpoch = runtimeEpoch
        self.managerOrRegistryGeneration = managerOrRegistryGeneration
        self.selectionGeneration = selectionGeneration
        self.uiGeneration = uiGeneration
        self.definitionGeneration = definitionGeneration
        self.contentGeneration = contentGeneration
        self.ownerControllerIdentity = ownerControllerIdentity
    }

    /// Convenience initializer for callers that use the Objective-C spelling
    /// `exactURL` in their envelope model.
    public init(
        mode: ExplorePublishMode,
        permitNonce: String,
        envelopeKeyHash: String,
        sourceKind: SourceKind = .legado,
        canonicalID: String,
        exactURL: String,
        nodeID: String?,
        snapshotID: String?,
        definitionFingerprint: String?,
        page: Int = 1,
        requestSequence: UInt64 = 0,
        runtimeEpoch: UInt64,
        registryGeneration: UInt64,
        selectionGeneration: UInt64,
        uiGeneration: UInt64,
        definitionGeneration: UInt64,
        contentGeneration: UInt64,
        ownerControllerIdentity: String?
    ) {
        self.init(
            mode: mode,
            permitNonce: permitNonce,
            envelopeKeyHash: envelopeKeyHash,
            sourceKind: sourceKind,
            canonicalID: canonicalID,
            exactSourceUrl: exactURL,
            nodeID: nodeID,
            snapshotID: snapshotID,
            definitionFingerprint: definitionFingerprint,
            page: page,
            requestSequence: requestSequence,
            runtimeEpoch: runtimeEpoch,
            managerOrRegistryGeneration: registryGeneration,
            selectionGeneration: selectionGeneration,
            uiGeneration: uiGeneration,
            definitionGeneration: definitionGeneration,
            contentGeneration: contentGeneration,
            ownerControllerIdentity: ownerControllerIdentity
        )
    }

    /// Build a typed envelope identity from a validated session snapshot.
    public init(
        mode: ExplorePublishMode,
        permitNonce: String,
        envelopeKeyHash: String,
        session: SourceSessionToken
    ) {
        self.init(
            mode: mode,
            permitNonce: permitNonce,
            envelopeKeyHash: envelopeKeyHash,
            sourceKind: session.sourceKind,
            canonicalID: session.canonicalID,
            exactSourceUrl: session.exactSourceUrl,
            nodeID: session.nodeID,
            snapshotID: session.snapshotID,
            definitionFingerprint: session.definitionFingerprint,
            page: session.page,
            requestSequence: session.requestSequence,
            runtimeEpoch: session.runtimeEpoch,
            managerOrRegistryGeneration: session.managerOrRegistryGeneration,
            selectionGeneration: session.selectionGeneration,
            uiGeneration: session.uiGeneration,
            definitionGeneration: session.definitionGeneration,
            contentGeneration: session.contentGeneration,
            ownerControllerIdentity: session.ownerControllerIdentity
        )
    }

    /// ABI numeric source-kind required by the typed cache envelope contract.
    public var sourceKindCode: Int {
        switch sourceKind {
        case .legado: return 2
        case .xbs: return 1
        case .unknown: return 0
        }
    }

    public var sourceKindRaw: Int { sourceKindCode }

    /// Alias used by cache envelope models that call this field `exactURL`.
    public var exactURL: String {
        get { exactSourceUrl }
        set { exactSourceUrl = newValue }
    }

    public var runtime: UInt64 {
        get { runtimeEpoch }
        set { runtimeEpoch = newValue }
    }

    /// Alias used by typed cache tests/bridges for the Legado registry lane.
    public var registryGeneration: UInt64 {
        get { managerOrRegistryGeneration }
        set { managerOrRegistryGeneration = newValue }
    }

    public var registry: UInt64 {
        get { managerOrRegistryGeneration }
        set { managerOrRegistryGeneration = newValue }
    }

    /// Stable source/session identity; display names are intentionally absent.
    public var sessionKey: String {
        SelectionToken.sessionKey(sourceKind: sourceKind, canonicalID: canonicalID)
    }

    public var sessionIdentity: String { sessionKey }
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
    case cachePermitRequired
    case cachePermitMissing
    case cachePermitReplay
    case cacheModeMismatch
    case cacheEnvelopeKeyMissing
    case cacheEnvelopeKeyMismatch
    case cacheNetworkAlreadyAccepted
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
    /// URLs observed in the real Legado registry.  Coordinator unit tests
    /// intentionally use synthetic URLs, so an unknown URL remains usable in
    /// isolation; once a URL is known to the registry, disabled/removed state
    /// is fail-closed for selection, callbacks, and permits.
    private var knownManagedLegadoSourceURLs: Set<String> = []
    private var unavailableLegadoSourceURLs: Set<String> = []
    /// At most one typed cache envelope may be live at a time.  Cache
    /// publication is only issuable for the active Legado session, so a
    /// single slot is enough and makes stale issuance state strictly bounded:
    /// issuing a new permit atomically revokes the previous nonce, including
    /// when the mode changes between fallback and cold-last-good.
    private var latestCachePermit: CachePermitToken?

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
            // Any outstanding Legado cache envelope was issued against the
            // previous registry generation and must not survive the drift.
            if latestCachePermit?.sourceKind == .legado {
                latestCachePermit = nil
            }
            for (key, var s) in sessions where s.sourceKind == .legado {
                s.managerOrRegistryGeneration = registryGeneration
                sessions[key] = s
            }
        }
    }

    /// Freeze one Legado identity after a destructive registry mutation.
    ///
    /// Generation bumps alone are insufficient: they leave the old route
    /// active and let `currentToken` mint a fresh-looking token for a source
    /// that was just disabled or removed.  This operation marks the exact URL
    /// unavailable, clears it as the active route, and retains the tombstone
    /// until a fresh exact `applySelection` explicitly reactivates it.
    public func invalidateLegadoSource(exactSourceUrl: String) {
        let trimmed = exactSourceUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queue.sync {
            let key = legacySessionKey(trimmed)
            knownManagedLegadoSourceURLs.insert(trimmed)
            unavailableLegadoSourceURLs.insert(trimmed)
            if activeSessionKey == key {
                activeSessionKey = nil
            }
            if latestCachePermit?.sourceKind == .legado,
               latestCachePermit?.exactSourceUrl == trimmed {
                latestCachePermit = nil
            }
            // Keep a frozen state only long enough for stale callbacks to be
            // rejected by the unavailable set; no caller can obtain it via
            // currentToken while the tombstone is present.
            sessions.removeValue(forKey: key)
        }
    }

    public func apply(_ event: SourceSessionEvent) -> SourceSessionToken {
        queue.sync {
            switch event {
            case .selectDiscoverSource(let sel):
                latestCachePermit = nil
                let token = applySelect(sel, isReselect: false)
                activeSessionKey = token.sourceKind == .unknown ? nil : token.sessionKey
                return token
            case .reselectSameDiscoverSource(let sel):
                latestCachePermit = nil
                let token = applySelect(sel, isReselect: true)
                activeSessionKey = token.sourceKind == .unknown ? nil : token.sessionKey
                return token

            case .switchDiscoverSource(let url),
                 .hostControllerRebuilt(let url),
                 .crossModeSwitch(let url):
                guard legadoSourceCanCreateSession(url) else {
                    return invalidToken(for: url)
                }
                latestCachePermit = nil
                let token = applyLegacySwitch(url: url, bumpUI: true)
                activeSessionKey = token.sessionKey
                return token

            case .ruleDefinitionChanged(let url),
                 .runtimeContextChanged(let url):
                guard legadoSourceCanCreateSession(url) else {
                    return invalidToken(for: url)
                }
                latestCachePermit = nil
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
                guard legadoSourceCanCreateSession(url) else {
                    return invalidToken(for: url)
                }
                latestCachePermit = nil
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
                guard legadoSourceCanCreateSession(url) else {
                    return invalidToken(for: url)
                }
                latestCachePermit = nil
                let key = legacySessionKey(url)
                var s = sessions[key] ?? legacySessionState(url: url)
                s.contentGeneration &+= 1
                s.page = 1
                s.lastAcceptedPage = 0
                s.requestSequence = 0
                sessions[key] = s
                return token(from: s)

            case .loadMore(let url, let page):
                guard legadoSourceCanCreateSession(url) else {
                    return invalidToken(for: url)
                }
                latestCachePermit = nil
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
            latestCachePermit = nil
            let token = applySelect(selection, isReselect: isReselect)
            activeSessionKey = token.sourceKind == .unknown ? nil : token.sessionKey
            return token
        }
    }

    public func currentToken(sourceKind: SourceKind, canonicalID: String) -> SourceSessionToken? {
        let key = SelectionToken.sessionKey(sourceKind: sourceKind, canonicalID: canonicalID)
        return queue.sync {
            if sourceKind == .legado, !legadoSourceIsAvailable(canonicalID) {
                return nil
            }
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
            guard legadoSourceIsAvailable(exactSourceUrl) else { return nil }
            let key = SelectionToken.sessionKey(sourceKind: .legado, canonicalID: exactSourceUrl)
            guard activeSessionKey == key, var s = sessions[key], s.sourceKind == .legado,
                  s.exactSourceUrl == exactSourceUrl else { return nil }
            latestCachePermit = nil
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
            guard legadoSourceIsAvailable(exactSourceUrl) else { return nil }
            let key = SelectionToken.sessionKey(sourceKind: .legado, canonicalID: exactSourceUrl)
            guard activeSessionKey == key, var s = sessions[key],
                  s.sourceKind == .legado, s.exactSourceUrl == exactSourceUrl else { return nil }
            let ownerChanged = s.ownerControllerIdentity != ownerControllerIdentity
            let definitionChanged = s.definitionFingerprint != definitionFingerprint
            let catalogChanged = s.snapshotID != snapshotID || s.nodeID != nodeID || s.runtimeEpoch != runtimeEpoch
            if ownerChanged { s.uiGeneration &+= 1 }
            if definitionChanged { s.definitionGeneration &+= 1 }
            if ownerChanged || definitionChanged || catalogChanged {
                latestCachePermit = nil
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

    /// Legacy cache-token helper retained only for source compatibility.  A
    /// normal session token is not a cache authorization and must never be
    /// handed to a cache publication caller.
    @available(*, deprecated, message: "Use issueCachePermit(for:mode:envelopeKeyHash:) to obtain a typed cache token")
    public func tokenForCacheHit(sourceKind: SourceKind, canonicalID: String) -> SourceSessionToken? {
        nil
    }

    @available(*, deprecated, message: "Use issueCachePermit(for:mode:envelopeKeyHash:) to obtain a typed cache token")
    public func tokenForCacheHit(exactSourceUrl: String) -> SourceSessionToken? {
        nil
    }

    public func requestPublishPermit(
        for request: SourceSessionToken,
        isFirstPage: Bool
    ) -> Result<PublishPermit, PublishRejectReason> {
        queue.sync {
            let key = request.sessionKey
            if request.sourceKind == .legado, !legadoSourceIsAvailable(request.exactSourceUrl) {
                return .failure(.routeFailClosed)
            }
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
                // Admitting a network first page revokes any outstanding cache
                // envelope.  The permit was issued against the pre-network
                // session state, so leaving the slot populated would let a
                // late cache callback reach the full identity comparison and
                // fail with an identity-drift reason instead of the intended
                // "this nonce no longer exists".  Revocation only happens on
                // success: a rejected publish must not destroy a permit that
                // is still legitimately consumable.
                latestCachePermit = nil
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

    /// Issue a one-shot typed cache authorization from the active exact
    /// Legado session.  This is the only creation path for `CachePermitToken`.
    public func issueCachePermit(
        for request: SourceSessionToken,
        mode: ExplorePublishMode,
        envelopeKeyHash: String
    ) -> Result<CachePermitToken, PublishRejectReason> {
        queue.sync {
            guard request.sourceKind == .legado else {
                return .failure(.sourceKindMismatch)
            }
            guard mode == .cacheFallback || mode == .coldLastGood else {
                // `networkFirst` is the ordinary publication lane.  It is
                // intentionally not representable as a cache permit.
                return .failure(.cacheModeMismatch)
            }
            guard !envelopeKeyHash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(.cacheEnvelopeKeyMissing)
            }
            guard request.page == 1 else {
                return .failure(.pageMismatch)
            }
            guard legadoSourceIsAvailable(request.exactSourceUrl) else {
                return .failure(.routeFailClosed)
            }
            let key = request.sessionKey
            guard activeSessionKey == key else {
                return .failure(.routeFailClosed)
            }
            guard let session = sessions[key], session.sourceKind == .legado,
                  session.exactSourceUrl == request.exactSourceUrl else {
                return .failure(.sessionMissing)
            }
            if let reason = validateLegadoPublishIdentity(request) {
                return .failure(reason)
            }
            if let reason = validate(request: request, against: session) {
                return .failure(reason)
            }
            // A cache fallback is only eligible before a network first page
            // has been accepted.  This prevents a late cache callback from
            // replacing fresh network data in the same session.
            guard request.requestSequence == session.requestSequence else {
                return .failure(.requestSequenceMismatch)
            }
            guard session.page == 1 else {
                return .failure(.pageMismatch)
            }
            guard session.lastAcceptedPage == 0, session.requestSequence == 0 else {
                return .failure(.cacheNetworkAlreadyAccepted)
            }
            let nonce = UUID().uuidString
            let typed = CachePermitToken(
                mode: mode,
                permitNonce: nonce,
                envelopeKeyHash: envelopeKeyHash,
                session: request
            )
            // Replacing this single slot revokes any earlier nonce
            // atomically.  It also makes cacheFallback/coldLastGood mutually
            // exclusive for a session and prevents two permits from both
            // being consumed.
            latestCachePermit = typed
            return .success(typed)
        }
    }

    /// Naming alias for callers that model issuance as a token factory.
    public func issueCachePermitToken(
        for request: SourceSessionToken,
        mode: ExplorePublishMode,
        envelopeKeyHash: String
    ) -> Result<CachePermitToken, PublishRejectReason> {
        issueCachePermit(for: request, mode: mode, envelopeKeyHash: envelopeKeyHash)
    }

    /// Validate and consume a typed cache authorization.  Consumption is
    /// atomic with the one-shot nonce check on the coordinator's serial queue.
    public func requestCacheHitPermit(
        for request: CachePermitToken
    ) -> Result<PublishPermit, PublishRejectReason> {
        requestCacheHitPermit(for: request, expectedMode: nil)
    }

    /// Explicit mode overload used by callers that keep transport mode outside
    /// the envelope.  The token's embedded mode and this expected value must
    /// agree exactly.
    public func requestCacheHitPermit(
        for request: CachePermitToken,
        mode: ExplorePublishMode
    ) -> Result<PublishPermit, PublishRejectReason> {
        requestCacheHitPermit(for: request, expectedMode: mode)
    }

    public func requestCacheHitPermit(
        for request: CachePermitToken,
        expectedMode: ExplorePublishMode?
    ) -> Result<PublishPermit, PublishRejectReason> {
        queue.sync {
            guard request.sourceKind == .legado else {
                return .failure(.sourceKindMismatch)
            }
            if let expectedMode, request.mode != expectedMode {
                return .failure(.cacheModeMismatch)
            }
            guard let issued = latestCachePermit,
                  issued.permitNonce == request.permitNonce else {
                // Unknown, revoked, and replayed nonces are deliberately
                // indistinguishable.  No unbounded consumed-nonce tombstone
                // is retained merely to report replay history.
                return .failure(.cachePermitMissing)
            }
            // Check the mode before full equality so a caller gets a stable
            // mode-specific failure for a tampered transport envelope.
            guard issued.mode == request.mode else {
                return .failure(.cacheModeMismatch)
            }
            guard issued.envelopeKeyHash == request.envelopeKeyHash else {
                return .failure(.cacheEnvelopeKeyMismatch)
            }
            guard issued == request else {
                if let reason = cacheTokenDifferenceReason(request, from: issued) {
                    return .failure(reason)
                }
                // Every remaining field is a typed source/session identity;
                // route through the normal field validators below where
                // possible, otherwise fail closed without consuming the nonce.
                let key = request.sessionKey
                guard let session = sessions[key] else {
                    return .failure(.sessionMissing)
                }
                if let reason = validateCacheIdentity(request, against: session) {
                    return .failure(reason)
                }
                return .failure(.routeFailClosed)
            }
            guard !request.envelopeKeyHash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(.cacheEnvelopeKeyMissing)
            }
            guard request.page == 1 else {
                return .failure(.pageMismatch)
            }
            guard legadoSourceIsAvailable(request.exactSourceUrl) else {
                return .failure(.routeFailClosed)
            }
            guard activeSessionKey == request.sessionKey else {
                return .failure(.routeFailClosed)
            }
            guard let session = sessions[request.sessionKey], session.sourceKind == .legado,
                  session.exactSourceUrl == request.exactSourceUrl else {
                return .failure(.sessionMissing)
            }
            if let reason = validateCacheIdentity(request, against: session) {
                return .failure(reason)
            }
            // A network first page already admitted in this session wins over
            // any cache fallback issued before it.
            guard session.lastAcceptedPage == 0, session.requestSequence == 0 else {
                return .failure(.cacheNetworkAlreadyAccepted)
            }

            latestCachePermit = nil
            let networkToken = SourceSessionToken(
                sourceKind: .legado,
                canonicalID: request.canonicalID,
                exactSourceUrl: request.exactSourceUrl,
                uiGeneration: request.uiGeneration,
                definitionGeneration: request.definitionGeneration,
                contentGeneration: request.contentGeneration,
                selectionGeneration: request.selectionGeneration,
                managerOrRegistryGeneration: request.managerOrRegistryGeneration,
                snapshotID: request.snapshotID,
                nodeID: request.nodeID,
                page: request.page,
                requestSequence: request.requestSequence,
                ownerControllerIdentity: request.ownerControllerIdentity,
                definitionFingerprint: request.definitionFingerprint,
                runtimeEpoch: request.runtimeEpoch
            )
            return .success(PublishPermit(token: networkToken, replaceFirstPage: true, appendPage: false))
        }
    }

    /// Compatibility overload: ordinary session tokens are deliberately
    /// rejected rather than upgraded into typed cache authorization.
    @available(*, deprecated, message: "A SourceSessionToken cannot authorize cache publication")
    public func requestCacheHitPermit(
        for request: SourceSessionToken
    ) -> Result<PublishPermit, PublishRejectReason> {
        .failure(.routeFailClosed)
    }

    /// 异步副作用核对：captured token 须仍为 active route 且与当前 session 全字段一致。
    public func isStillActiveLegadoPublishContext(_ captured: SourceSessionToken) -> Bool {
        queue.sync {
            guard legadoSourceIsAvailable(captured.exactSourceUrl) else { return false }
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
            knownManagedLegadoSourceURLs.removeAll()
            unavailableLegadoSourceURLs.removeAll()
            latestCachePermit = nil
        }
    }

    /// Internal test-only diagnostic.  The permit state is intentionally a
    /// single slot, so this value is always 0 or 1 and cannot grow with
    /// replay attempts or issuance churn.
    internal func cachePermitStateCountForTests() -> Int {
        queue.sync { latestCachePermit == nil ? 0 : 1 }
    }

    // MARK: - private

    private func invalidToken(for exactSourceUrl: String) -> SourceSessionToken {
        SourceSessionToken(
            sourceKind: .unknown,
            canonicalID: exactSourceUrl,
            exactSourceUrl: "",
            uiGeneration: 0,
            definitionGeneration: 0,
            contentGeneration: 0
        )
    }

    /// Selection is the only operation allowed to reactivate a URL that was
    /// previously disabled/removed.  Refresh, callback, and permit paths
    /// remain fail-closed until a fresh exact selection is made.
    private func legadoSourceCanCreateSession(
        _ exactSourceUrl: String,
        allowReactivation: Bool = false
    ) -> Bool {
        guard !exactSourceUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        if SourceRegistry.shared.isLegadoSourceRetired(url: exactSourceUrl) {
            unavailableLegadoSourceURLs.insert(exactSourceUrl)
            return false
        }
        let managed = SourceRegistry.shared.isLegadoManaged(url: exactSourceUrl)
        if managed {
            knownManagedLegadoSourceURLs.insert(exactSourceUrl)
            guard SourceRegistry.shared.isEnabled(url: exactSourceUrl) else {
                unavailableLegadoSourceURLs.insert(exactSourceUrl)
                return false
            }
            if unavailableLegadoSourceURLs.contains(exactSourceUrl) {
                guard allowReactivation else { return false }
                unavailableLegadoSourceURLs.remove(exactSourceUrl)
                let key = legacySessionKey(exactSourceUrl)
                sessions.removeValue(forKey: key)
                if activeSessionKey == key { activeSessionKey = nil }
            }
            return true
        }
        if unavailableLegadoSourceURLs.contains(exactSourceUrl) {
            guard allowReactivation else { return false }
            unavailableLegadoSourceURLs.remove(exactSourceUrl)
            knownManagedLegadoSourceURLs.remove(exactSourceUrl)
            let key = legacySessionKey(exactSourceUrl)
            sessions.removeValue(forKey: key)
            if activeSessionKey == key { activeSessionKey = nil }
        }
        // Synthetic URLs used by the pure coordinator tests are not registry
        // identities.  A URL once observed in the registry, however, remains
        // retired after deletion and cannot silently become a new route.
        return !knownManagedLegadoSourceURLs.contains(exactSourceUrl)
            && !unavailableLegadoSourceURLs.contains(exactSourceUrl)
    }

    private func legadoSourceIsAvailable(_ exactSourceUrl: String) -> Bool {
        guard !exactSourceUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        if SourceRegistry.shared.isLegadoSourceRetired(url: exactSourceUrl) {
            unavailableLegadoSourceURLs.insert(exactSourceUrl)
            return false
        }
        let managed = SourceRegistry.shared.isLegadoManaged(url: exactSourceUrl)
        if managed {
            knownManagedLegadoSourceURLs.insert(exactSourceUrl)
            if !SourceRegistry.shared.isEnabled(url: exactSourceUrl) {
                unavailableLegadoSourceURLs.insert(exactSourceUrl)
                return false
            }
        }
        if unavailableLegadoSourceURLs.contains(exactSourceUrl) { return false }
        return managed || !knownManagedLegadoSourceURLs.contains(exactSourceUrl)
    }

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

    private func validateCacheIdentity(
        _ request: CachePermitToken,
        against session: SessionState
    ) -> PublishRejectReason? {
        guard request.sourceKind == .legado else { return .sourceKindMismatch }
        if request.canonicalID != session.canonicalID { return .canonicalIDMismatch }
        if request.exactSourceUrl != session.exactSourceUrl { return .sourceMismatch }
        guard let owner = request.ownerControllerIdentity, !owner.isEmpty else {
            return .ownerMismatch
        }
        guard let fingerprint = request.definitionFingerprint, !fingerprint.isEmpty else {
            return .definitionFingerprintMismatch
        }
        guard let snapshot = request.snapshotID, !snapshot.isEmpty else {
            return .snapshotMismatch
        }
        guard let node = request.nodeID, !node.isEmpty else {
            return .nodeMismatch
        }
        if request.selectionGeneration != session.selectionGeneration {
            return .selectionGenerationMismatch
        }
        if request.managerOrRegistryGeneration != session.managerOrRegistryGeneration {
            return .managerOrRegistryGenerationMismatch
        }
        if request.uiGeneration != session.uiGeneration {
            return .uiGenerationMismatch
        }
        if request.definitionGeneration != session.definitionGeneration {
            return .definitionGenerationMismatch
        }
        if request.contentGeneration != session.contentGeneration {
            return .contentGenerationMismatch
        }
        if node != session.nodeID { return .nodeMismatch }
        if snapshot != session.snapshotID { return .snapshotMismatch }
        if owner != session.ownerControllerIdentity { return .ownerMismatch }
        if fingerprint != session.definitionFingerprint {
            return .definitionFingerprintMismatch
        }
        if request.runtimeEpoch != session.runtimeEpoch {
            return .runtimeEpochMismatch
        }
        if request.page != session.page { return .pageMismatch }
        if request.requestSequence != session.requestSequence {
            return .requestSequenceMismatch
        }
        return nil
    }

    private func cacheTokenDifferenceReason(
        _ request: CachePermitToken,
        from issued: CachePermitToken
    ) -> PublishRejectReason? {
        if request.sourceKind != issued.sourceKind { return .sourceKindMismatch }
        if request.canonicalID != issued.canonicalID { return .canonicalIDMismatch }
        if request.exactSourceUrl != issued.exactSourceUrl { return .sourceMismatch }
        if request.nodeID != issued.nodeID { return .nodeMismatch }
        if request.snapshotID != issued.snapshotID { return .snapshotMismatch }
        if request.definitionFingerprint != issued.definitionFingerprint {
            return .definitionFingerprintMismatch
        }
        if request.page != issued.page { return .pageMismatch }
        if request.requestSequence != issued.requestSequence {
            return .requestSequenceMismatch
        }
        if request.runtimeEpoch != issued.runtimeEpoch { return .runtimeEpochMismatch }
        if request.managerOrRegistryGeneration != issued.managerOrRegistryGeneration {
            return .managerOrRegistryGenerationMismatch
        }
        if request.selectionGeneration != issued.selectionGeneration {
            return .selectionGenerationMismatch
        }
        if request.uiGeneration != issued.uiGeneration {
            return .uiGenerationMismatch
        }
        if request.definitionGeneration != issued.definitionGeneration {
            return .definitionGenerationMismatch
        }
        if request.contentGeneration != issued.contentGeneration {
            return .contentGenerationMismatch
        }
        if request.ownerControllerIdentity != issued.ownerControllerIdentity {
            return .ownerMismatch
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
            return invalidToken(for: sel.canonicalID)
        }
        if sel.sourceKind == .legado,
           !legadoSourceCanCreateSession(sel.canonicalID, allowReactivation: true) {
            return invalidToken(for: sel.canonicalID)
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
        // Untyped session dictionaries cannot be upgraded.  Mode is taken
        // only from the typed envelope; the C caller cannot pick it.
        guard let request = Self.cachePermit(from: token) else {
            return [
                "ok": false,
                "reason": PublishRejectReason.cachePermitRequired.rawValue,
                "cacheHit": true
            ]
        }
        switch SourceSessionCoordinator.shared.requestCacheHitPermit(for: request) {
        case .success(let permit):
            return [
                "ok": true,
                "token": Self.tokenDictionary(permit.token),
                "replaceFirstPage": permit.replaceFirstPage,
                "appendPage": permit.appendPage,
                "cacheHit": true,
                "mode": request.mode.rawValue
            ]
        case .failure(let reason):
            return [
                "ok": false,
                "reason": reason.rawValue,
                "cacheHit": true
            ]
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

    static func sessionToken(from cache: CachePermitToken) -> SourceSessionToken {
        SourceSessionToken(
            sourceKind: cache.sourceKind,
            canonicalID: cache.canonicalID,
            exactSourceUrl: cache.exactSourceUrl,
            uiGeneration: cache.uiGeneration,
            definitionGeneration: cache.definitionGeneration,
            contentGeneration: cache.contentGeneration,
            selectionGeneration: cache.selectionGeneration,
            managerOrRegistryGeneration: cache.managerOrRegistryGeneration,
            snapshotID: cache.snapshotID,
            nodeID: cache.nodeID,
            page: cache.page,
            requestSequence: cache.requestSequence,
            ownerControllerIdentity: cache.ownerControllerIdentity,
            definitionFingerprint: cache.definitionFingerprint,
            runtimeEpoch: cache.runtimeEpoch
        )
    }

    static func cachePermitDictionary(_ token: CachePermitToken) -> [String: Any] {
        var dict = tokenDictionary(sessionToken(from: token))
        dict["mode"] = token.mode.rawValue
        dict["permitNonce"] = token.permitNonce
        dict["envelopeKeyHash"] = token.envelopeKeyHash
        return dict
    }

    static func cachePermit(from dict: NSDictionary) -> CachePermitToken? {
        guard let modeRaw = dict["mode"] as? String,
              let mode = ExplorePublishMode(rawValue: modeRaw),
              mode == .cacheFallback || mode == .coldLastGood,
              let nonce = dict["permitNonce"] as? String,
              !nonce.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let envelopeKeyHash = dict["envelopeKeyHash"] as? String,
              !envelopeKeyHash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let session = token(from: dict) else {
            return nil
        }
        return CachePermitToken(
            mode: mode,
            permitNonce: nonce,
            envelopeKeyHash: envelopeKeyHash,
            session: session
        )
    }

    private static func token(from dict: NSDictionary) -> SourceSessionToken? {
        guard let canonicalID = dict["canonicalID"] as? String, !canonicalID.isEmpty,
              let exact = dict["exactSourceUrl"] as? String, !exact.isEmpty,
              let rawKind = intValue(dict["sourceKind"]) else { return nil }
        let kind = Self.kind(from: rawKind)
        guard kind != .unknown,
              let ui = uint64Value(dict["uiGeneration"]),
              let definition = uint64Value(dict["definitionGeneration"]),
              let content = uint64Value(dict["contentGeneration"]),
              let selection = uint64Value(dict["selectionGeneration"]),
              let registry = uint64Value(dict["managerOrRegistryGeneration"]),
              let page = intValue(dict["page"]),
              page > 0,
              let sequence = uint64Value(dict["requestSequence"]),
              let epoch = uint64Value(dict["runtimeEpoch"]) else { return nil }
        return SourceSessionToken(
            sourceKind: kind,
            canonicalID: canonicalID,
            exactSourceUrl: exact,
            uiGeneration: ui,
            definitionGeneration: definition,
            contentGeneration: content,
            selectionGeneration: selection,
            managerOrRegistryGeneration: registry,
            snapshotID: (dict["snapshotID"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            nodeID: (dict["nodeID"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            page: page,
            requestSequence: sequence,
            ownerControllerIdentity: (dict["ownerControllerIdentity"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            definitionFingerprint: (dict["definitionFingerprint"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            runtimeEpoch: epoch
        )
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let number = raw as? NSNumber { return number.intValue }
        if let value = raw as? Int { return value }
        return nil
    }

    private static func uint64Value(_ raw: Any?) -> UInt64? {
        if let number = raw as? NSNumber { return number.uint64Value }
        if let value = raw as? UInt64 { return value }
        if let value = raw as? Int, value >= 0 { return UInt64(value) }
        return nil
    }
}
