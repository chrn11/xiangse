import Foundation

/// 书源协议 — 供 AnalyzeUrl / RuleWebBook 使用，避免 CoreData 依赖
public protocol BridgeSourceProtocol: AnyObject {
    var bookSourceUrl: String { get }
    var bookSourceName: String { get }
    var header: String? { get }
    var enabledCookieJar: Bool { get }
    var loginCheckJs: String? { get }
    var loginUrl: String? { get }
    var bookUrlPattern: String? { get }
    var searchUrl: String? { get }
    /// 发现页入口 URL（可含 {{page}} 等模板）
    var exploreUrl: String? { get }
    var concurrentRate: String? { get }
    var jsLib: String? { get }
    var variable: String? { get }

    func getSearchRule() -> BridgeSearchRule?
    func getExploreRule() -> BridgeExploreRule?
    func getBookInfoRule() -> BridgeBookInfoRule?
    func getTocRule() -> TocRule?
    func getContentRule() -> BridgeContentRule?
}
