//
//  ChineseUtils.swift
//  Legado-iOS
//
//  简繁转换工具 — 使用 CFStringTransform（零依赖，iOS 内置）
//  t2s: 繁体→简体  s2t: 简体→繁体
//

import Foundation

struct ChineseUtils {

    /// 繁体 → 简体 (Traditional → Simplified)
    static func t2s(_ text: String) -> String {
        let mutable = NSMutableString(string: text)
        CFStringTransform(mutable, nil, "Hant-Hans" as CFString, false)
        return mutable as String
    }

    /// 简体 → 繁体 (Simplified → Traditional)
    static func s2t(_ text: String) -> String {
        let mutable = NSMutableString(string: text)
        CFStringTransform(mutable, nil, "Hans-Hant" as CFString, false)
        return mutable as String
    }
}
