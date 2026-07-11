import Foundation

/// LegadoRuleCore 模块入口说明
///
/// 本模块承载阅读协议基线 `legado-E 3.26.030717` 的规则引擎：
/// - `RuleWebBook`：search / getBookInfo / getChapterList / getContent（含分页）
/// - Vendor RuleEngine / AnalyzeUrl / JSBridge（java / source / cookie / network）
/// - Cookie / 变量 / 可分类不支持错误 / hook103 语义夹具接口
///
/// 香色适配与 Hook 留在 `LegadoBridge`。
public enum LegadoRuleCoreInfo {
    public static let protocolBaseline = "legado-E 3.26.030717"
    public static let moduleName = "LegadoRuleCore"
}
