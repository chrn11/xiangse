import Foundation

/// 不可变会话令牌；ObjC 只能持有，不能直接改 generation。
public struct SourceSessionToken: Equatable, Sendable {
    public var exactSourceUrl: String
    public var uiGeneration: UInt64
    public var definitionGeneration: UInt64
    public var contentGeneration: UInt64
    public var snapshotID: String?
    public var nodeID: String?
    public var page: Int

    public init(
        exactSourceUrl: String,
        uiGeneration: UInt64,
        definitionGeneration: UInt64,
        contentGeneration: UInt64,
        snapshotID: String? = nil,
        nodeID: String? = nil,
        page: Int = 1
    ) {
        self.exactSourceUrl = exactSourceUrl
        self.uiGeneration = uiGeneration
        self.definitionGeneration = definitionGeneration
        self.contentGeneration = contentGeneration
        self.snapshotID = snapshotID
        self.nodeID = nodeID
        self.page = page
    }
}

public enum PublishRejectReason: String, Error, Equatable, Sendable {
    case sourceMismatch
    case snapshotMismatch
    case uiGenerationMismatch
    case definitionGenerationMismatch
    case contentGenerationMismatch
    case nodeMismatch
    case pageMismatch
    case pageNotContiguous
    case sessionMissing
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
}

/// 唯一会话 owner（串行 queue）；实现计划 §24.4。
public final class SourceSessionCoordinator: @unchecked Sendable {
    public static let shared = SourceSessionCoordinator()

    private let queue = DispatchQueue(label: "com.xiangse.legado-bridge.source-session")
    private var sessions: [String: SessionState] = [:]

    public init() {}

    private struct SessionState {
        var exactSourceUrl: String
        var uiGeneration: UInt64 = 0
        var definitionGeneration: UInt64 = 0
        var contentGeneration: UInt64 = 0
        var snapshotID: String?
        var nodeID: String?
        var lastAcceptedPage: Int = 0
        var page: Int = 1
    }

    public func apply(_ event: SourceSessionEvent) -> SourceSessionToken {
        queue.sync {
            switch event {
            case .switchDiscoverSource(let url),
                 .hostControllerRebuilt(let url),
                 .crossModeSwitch(let url):
                var s = sessions[url] ?? SessionState(exactSourceUrl: url)
                s.uiGeneration &+= 1
                s.contentGeneration &+= 1
                s.page = 1
                s.lastAcceptedPage = 0
                sessions[url] = s
                return token(from: s)

            case .ruleDefinitionChanged(let url),
                 .runtimeContextChanged(let url):
                var s = sessions[url] ?? SessionState(exactSourceUrl: url)
                s.definitionGeneration &+= 1
                s.contentGeneration &+= 1
                s.page = 1
                s.lastAcceptedPage = 0
                sessions[url] = s
                return token(from: s)

            case .selectChannelOrNode(let url, let snapshotID, let nodeID):
                var s = sessions[url] ?? SessionState(exactSourceUrl: url)
                s.contentGeneration &+= 1
                s.snapshotID = snapshotID
                s.nodeID = nodeID
                s.page = 1
                s.lastAcceptedPage = 0
                sessions[url] = s
                return token(from: s)

            case .manualRefreshFirstPage(let url):
                var s = sessions[url] ?? SessionState(exactSourceUrl: url)
                s.contentGeneration &+= 1
                s.page = 1
                s.lastAcceptedPage = 0
                sessions[url] = s
                return token(from: s)

            case .loadMore(let url, let page):
                var s = sessions[url] ?? SessionState(exactSourceUrl: url)
                // 不递增 contentGeneration；分配 page
                s.page = page
                sessions[url] = s
                return token(from: s)
            }
        }
    }

    public func currentToken(exactSourceUrl: String) -> SourceSessionToken? {
        queue.sync {
            guard let s = sessions[exactSourceUrl] else { return nil }
            return token(from: s)
        }
    }

    /// cache hit 发布：不递增任何 generation。
    public func tokenForCacheHit(exactSourceUrl: String) -> SourceSessionToken? {
        currentToken(exactSourceUrl: exactSourceUrl)
    }

    public func requestPublishPermit(
        for request: SourceSessionToken,
        isFirstPage: Bool
    ) -> Result<PublishPermit, PublishRejectReason> {
        queue.sync {
            guard let s = sessions[request.exactSourceUrl] else {
                return .failure(.sessionMissing)
            }
            if request.exactSourceUrl != s.exactSourceUrl { return .failure(.sourceMismatch) }
            if let want = request.snapshotID, want != s.snapshotID { return .failure(.snapshotMismatch) }
            if request.uiGeneration != s.uiGeneration { return .failure(.uiGenerationMismatch) }
            if request.definitionGeneration != s.definitionGeneration {
                return .failure(.definitionGenerationMismatch)
            }
            if request.contentGeneration != s.contentGeneration {
                return .failure(.contentGenerationMismatch)
            }
            if let want = request.nodeID, want != s.nodeID { return .failure(.nodeMismatch) }

            if isFirstPage {
                if request.page != 1 { return .failure(.pageMismatch) }
                var next = s
                next.lastAcceptedPage = 1
                next.page = 1
                sessions[request.exactSourceUrl] = next
                return .success(PublishPermit(token: request, replaceFirstPage: true, appendPage: false))
            }

            // 分页：page == lastAccepted + 1
            if request.page != s.lastAcceptedPage + 1 {
                return .failure(.pageNotContiguous)
            }
            var next = s
            next.lastAcceptedPage = request.page
            next.page = request.page
            sessions[request.exactSourceUrl] = next
            return .success(PublishPermit(token: request, replaceFirstPage: false, appendPage: true))
        }
    }

    /// 测试复位。
    public func resetForTests() {
        queue.sync { sessions.removeAll() }
    }

    private func token(from s: SessionState) -> SourceSessionToken {
        SourceSessionToken(
            exactSourceUrl: s.exactSourceUrl,
            uiGeneration: s.uiGeneration,
            definitionGeneration: s.definitionGeneration,
            contentGeneration: s.contentGeneration,
            snapshotID: s.snapshotID,
            nodeID: s.nodeID,
            page: s.page
        )
    }
}
