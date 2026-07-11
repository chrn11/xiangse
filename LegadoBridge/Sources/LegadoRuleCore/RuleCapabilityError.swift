import Foundation

/// 可分类的规则/能力错误 — 供夹具与在线报告归类
public enum RuleCapabilityError: Error, LocalizedError, Equatable {
    /// 登录流程（首版不支持）
    case loginRequired(detail: String = "")
    /// 验证码 / 人机验证
    case captchaRequired(detail: String = "")
    /// WebView 挑战页
    case webViewChallenge(detail: String = "")
    /// 漫画阅读
    case mangaUnsupported(detail: String = "")
    /// 音视频
    case audioVideoUnsupported(detail: String = "")
    /// 协议外原生能力（钥匙串、私有文件等）
    case nativeCapabilityForbidden(name: String)
    /// 规则缺口 / 解析能力不足
    case ruleGap(feature: String, detail: String = "")
    /// 网络失败
    case networkFailure(detail: String = "")
    /// 书源配置缺失
    case missingRule(name: String)
    /// 空响应
    case emptyResponse

    /// 稳定分类码，便于 CI / 兼容性报告聚合
    public var categoryCode: String {
        switch self {
        case .loginRequired: return "login"
        case .captchaRequired: return "captcha"
        case .webViewChallenge: return "webview_challenge"
        case .mangaUnsupported: return "manga"
        case .audioVideoUnsupported: return "audio_video"
        case .nativeCapabilityForbidden: return "native_forbidden"
        case .ruleGap: return "rule_gap"
        case .networkFailure: return "network"
        case .missingRule: return "missing_rule"
        case .emptyResponse: return "empty_response"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .loginRequired(let d):
            return "不支持登录流程" + (d.isEmpty ? "" : "：\(d)")
        case .captchaRequired(let d):
            return "不支持验证码/人机验证" + (d.isEmpty ? "" : "：\(d)")
        case .webViewChallenge(let d):
            return "不支持 WebView 挑战" + (d.isEmpty ? "" : "：\(d)")
        case .mangaUnsupported(let d):
            return "不支持漫画" + (d.isEmpty ? "" : "：\(d)")
        case .audioVideoUnsupported(let d):
            return "不支持音视频" + (d.isEmpty ? "" : "：\(d)")
        case .nativeCapabilityForbidden(let name):
            return "禁止协议外原生能力：\(name)"
        case .ruleGap(let feature, let d):
            return "规则能力缺口[\(feature)]" + (d.isEmpty ? "" : "：\(d)")
        case .networkFailure(let d):
            return "网络失败" + (d.isEmpty ? "" : "：\(d)")
        case .missingRule(let name):
            return "缺少\(name)"
        case .emptyResponse:
            return "网络响应为空"
        }
    }
}

/// 与历史 BridgeWebBook / WebBook 兼容的错误别名
public enum WebBookError: Error, LocalizedError {
    case noSearchUrl
    case noRule(String)
    case emptyResponse
    case parseFailed(String)
    case unsupported(RuleCapabilityError)

    public var errorDescription: String? {
        switch self {
        case .noSearchUrl: return "书源未配置 searchUrl"
        case .noRule(let n): return "缺少\(n)"
        case .emptyResponse: return "网络响应为空"
        case .parseFailed(let msg): return "解析失败：\(msg)"
        case .unsupported(let e): return e.errorDescription
        }
    }

    public var capability: RuleCapabilityError? {
        if case .unsupported(let e) = self { return e }
        return nil
    }
}
