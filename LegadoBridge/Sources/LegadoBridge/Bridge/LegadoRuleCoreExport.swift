import Foundation

/// 向适配层调用方再导出规则核心公开类型，避免仅 import LegadoBridge 时找不到 SearchBookResult 等符号
@_exported import LegadoRuleCore
