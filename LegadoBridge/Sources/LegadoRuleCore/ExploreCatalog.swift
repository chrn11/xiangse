import Foundation
import CryptoKit
import CoreFoundation

// MARK: - ExploreJSONValue

/// 持久模型用的无损 JSON 值；禁止用 Vendor AnyCodable 承担持久模型。
public enum ExploreJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ExploreJSONValue])
    case object([String: ExploreJSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int64.self) {
            self = .number(Double(i))
        } else if let d = try? c.decode(Double.self) {
            self = .number(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([ExploreJSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: ExploreJSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v):
            if v.rounded() == v, v >= Double(Int64.min), v <= Double(Int64.max) {
                try c.encode(Int64(v))
            } else {
                try c.encode(v)
            }
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    public static func fromAny(_ any: Any?) -> ExploreJSONValue {
        guard let any else { return .null }
        switch any {
        case is NSNull: return .null
        case let b as Bool: return .bool(b)
        case let n as NSNumber:
            // Bool 桥接为 NSNumber
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return .bool(n.boolValue)
            }
            return .number(n.doubleValue)
        case let s as String: return .string(s)
        case let a as [Any]: return .array(a.map { fromAny($0) })
        case let o as [String: Any]:
            var out: [String: ExploreJSONValue] = [:]
            for (k, v) in o { out[k] = fromAny(v) }
            return .object(out)
        default:
            return .string(String(describing: any))
        }
    }
}

// MARK: - Domain types

public enum ExploreNodeKind: String, Codable, Equatable, Sendable {
    case group
    case url
    case action
    case unsupported
}

public struct ExploreNode: Codable, Equatable, Sendable {
    public var nodeID: String
    public var kind: ExploreNodeKind
    public var rawTitle: String
    public var displayTitle: String
    public var rawTarget: String
    public var rawStyle: ExploreJSONValue?
    public var originalOrder: Int
    public var selectable: Bool
    public var diagnosticCode: String?
    public var children: [ExploreNode]

    public init(
        nodeID: String,
        kind: ExploreNodeKind,
        rawTitle: String,
        displayTitle: String,
        rawTarget: String,
        rawStyle: ExploreJSONValue? = nil,
        originalOrder: Int,
        selectable: Bool,
        diagnosticCode: String? = nil,
        children: [ExploreNode] = []
    ) {
        self.nodeID = nodeID
        self.kind = kind
        self.rawTitle = rawTitle
        self.displayTitle = displayTitle
        self.rawTarget = rawTarget
        self.rawStyle = rawStyle
        self.originalOrder = originalOrder
        self.selectable = selectable
        self.diagnosticCode = diagnosticCode
        self.children = children
    }
}

public struct ExploreChannel: Codable, Equatable, Sendable {
    public var channelID: String
    public var rawTitle: String
    public var displayTitle: String
    public var rawStyle: ExploreJSONValue?
    public var originalOrder: Int
    public var nodes: [ExploreNode]

    public init(
        channelID: String,
        rawTitle: String,
        displayTitle: String,
        rawStyle: ExploreJSONValue? = nil,
        originalOrder: Int,
        nodes: [ExploreNode]
    ) {
        self.channelID = channelID
        self.rawTitle = rawTitle
        self.displayTitle = displayTitle
        self.rawStyle = rawStyle
        self.originalOrder = originalOrder
        self.nodes = nodes
    }
}

public struct ExploreCatalogDiagnostics: Codable, Equatable, Sendable {
    public var codes: [String]
    public var notes: [String]

    public init(codes: [String] = [], notes: [String] = []) {
        self.codes = codes
        self.notes = notes
    }
}

public struct ExploreCatalogSnapshot: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var exactSourceUrl: String
    public var sourceNameSnapshot: String?
    public var definitionFingerprint: String
    public var runtimeContextEpoch: Int
    public var snapshotID: String
    public var channels: [ExploreChannel]
    public var defaultChannelID: String?
    public var defaultNodeID: String?
    public var diagnostics: ExploreCatalogDiagnostics

    public init(
        schemaVersion: Int = 1,
        exactSourceUrl: String,
        sourceNameSnapshot: String? = nil,
        definitionFingerprint: String,
        runtimeContextEpoch: Int = 0,
        snapshotID: String,
        channels: [ExploreChannel],
        defaultChannelID: String? = nil,
        defaultNodeID: String? = nil,
        diagnostics: ExploreCatalogDiagnostics = ExploreCatalogDiagnostics()
    ) {
        self.schemaVersion = schemaVersion
        self.exactSourceUrl = exactSourceUrl
        self.sourceNameSnapshot = sourceNameSnapshot
        self.definitionFingerprint = definitionFingerprint
        self.runtimeContextEpoch = runtimeContextEpoch
        self.snapshotID = snapshotID
        self.channels = channels
        self.defaultChannelID = defaultChannelID
        self.defaultNodeID = defaultNodeID
        self.diagnostics = diagnostics
    }
}

// MARK: - ID / fingerprint helpers

public enum ExploreCatalogID {
    public static func definitionFingerprint(exactSourceUrl: String, exploreRaw: String) -> String {
        hexSHA256(frame(["EXDF", exactSourceUrl, exploreRaw]))
    }

    public static func channelID(
        sourceUrl: String,
        definitionFingerprint: String,
        indexPath: [Int],
        rawTitle: String
    ) -> String {
        "lbc1_" + hexSHA256(frame([
            "LBC1",
            sourceUrl,
            definitionFingerprint,
            indexPath.map(String.init).joined(separator: "."),
            rawTitle
        ]))
    }

    public static func nodeID(
        sourceUrl: String,
        definitionFingerprint: String,
        channelID: String,
        indexPath: [Int],
        kind: ExploreNodeKind,
        rawTitle: String,
        rawTarget: String
    ) -> String {
        "lbn1_" + hexSHA256(frame([
            "LBN1",
            sourceUrl,
            definitionFingerprint,
            channelID,
            indexPath.map(String.init).joined(separator: "."),
            kind.rawValue,
            rawTitle,
            rawTarget
        ]))
    }

    public static func snapshotID(for catalogWithoutDiagnostics: ExploreCatalogSnapshot) throws -> String {
        var copy = catalogWithoutDiagnostics
        copy.diagnostics = ExploreCatalogDiagnostics()
        copy.snapshotID = ""
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(copy)
        return "lbs1_" + hexSHA256(data)
    }

    private static func frame(_ parts: [String]) -> Data {
        var data = Data()
        for part in parts {
            let utf8 = Data(part.utf8)
            var be = UInt32(utf8.count).bigEndian
            data.append(Data(bytes: &be, count: 4))
            data.append(utf8)
        }
        return data
    }

    private static func hexSHA256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Builder / normalizer

public enum ExploreCatalogBuilder {
    /// 从 exploreUrl 原文构建快照（不执行顶层 JS；JS 求值后的字符串请先传入）。
    public static func build(
        exactSourceUrl: String,
        sourceNameSnapshot: String? = nil,
        exploreRaw: String,
        runtimeContextEpoch: Int = 0
    ) -> ExploreCatalogSnapshot {
        let fingerprint = ExploreCatalogID.definitionFingerprint(
            exactSourceUrl: exactSourceUrl,
            exploreRaw: exploreRaw
        )
        var diagnostics = ExploreCatalogDiagnostics()
        let trimmed = exploreRaw.trimmingCharacters(in: .whitespacesAndNewlines)

        let channels: [ExploreChannel]
        if trimmed.isEmpty {
            channels = []
            diagnostics.codes.append("emptyExplore")
        } else if trimmed.hasPrefix("[") || trimmed.hasPrefix("{") {
            channels = normalizeJSON(
                text: trimmed,
                sourceUrl: exactSourceUrl,
                fingerprint: fingerprint,
                diagnostics: &diagnostics
            )
        } else if RuleWebBook.isTopLevelExploreJS(trimmed) {
            channels = []
            diagnostics.codes.append("topLevelJSUnevaluated")
            diagnostics.notes.append("caller must evaluate @js/<js> before build")
        } else {
            channels = normalizeTextItems(
                ExploreCatalogLexer.splitItems(trimmed),
                sourceUrl: exactSourceUrl,
                fingerprint: fingerprint,
                diagnostics: &diagnostics
            )
        }

        var snap = ExploreCatalogSnapshot(
            exactSourceUrl: exactSourceUrl,
            sourceNameSnapshot: sourceNameSnapshot,
            definitionFingerprint: fingerprint,
            runtimeContextEpoch: runtimeContextEpoch,
            snapshotID: "",
            channels: channels,
            defaultChannelID: channels.first?.channelID,
            defaultNodeID: channels.first?.nodes.first(where: { $0.selectable })?.nodeID
                ?? channels.first?.nodes.first?.nodeID,
            diagnostics: diagnostics
        )
        if let sid = try? ExploreCatalogID.snapshotID(for: snap) {
            snap.snapshotID = sid
        }
        return snap
    }

    /// JSON / JS 求值结果统一 normalizer。
    public static func normalizeJSON(
        text: String,
        sourceUrl: String,
        fingerprint: String,
        diagnostics: inout ExploreCatalogDiagnostics
    ) -> [ExploreChannel] {
        guard let data = text.data(using: .utf8) else {
            diagnostics.codes.append("jsonDecodeFailed")
            return []
        }
        let obj: Any
        do {
            obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            diagnostics.codes.append("jsonDecodeFailed")
            return []
        }

        if let arr = obj as? [Any] {
            return channelsFromJSONArray(
                arr,
                sourceUrl: sourceUrl,
                fingerprint: fingerprint,
                diagnostics: &diagnostics
            )
        }
        if let dict = obj as? [String: Any] {
            // 单对象：当作一个 channel/node 容器
            return channelsFromJSONArray(
                [dict],
                sourceUrl: sourceUrl,
                fingerprint: fingerprint,
                diagnostics: &diagnostics
            )
        }
        if let s = obj as? String {
            return normalizeTextItems(
                ExploreCatalogLexer.splitItems(s),
                sourceUrl: sourceUrl,
                fingerprint: fingerprint,
                diagnostics: &diagnostics
            )
        }
        diagnostics.codes.append("jsonUnsupportedRoot")
        return []
    }

    private static func channelsFromJSONArray(
        _ arr: [Any],
        sourceUrl: String,
        fingerprint: String,
        diagnostics: inout ExploreCatalogDiagnostics
    ) -> [ExploreChannel] {
        // 合同：多个顶层项 → 每个可映射为 channel（空 URL group）或其 nodes。
        // 简化：若项含 children/items 则该项为 channel；否则全部落入单一默认 channel。
        var hasNested = false
        for item in arr {
            if let d = item as? [String: Any],
               (d["children"] as? [Any]) != nil || (d["items"] as? [Any]) != nil {
                hasNested = true
                break
            }
        }

        if hasNested {
            var channels: [ExploreChannel] = []
            for (idx, item) in arr.enumerated() {
                guard let d = item as? [String: Any] else {
                    diagnostics.codes.append("jsonItemUnsupported")
                    continue
                }
                let rawTitle = (d["title"] as? String) ?? (d["name"] as? String) ?? ""
                let display = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                let style = styleValue(from: d["style"])
                let channelID = ExploreCatalogID.channelID(
                    sourceUrl: sourceUrl,
                    definitionFingerprint: fingerprint,
                    indexPath: [idx],
                    rawTitle: rawTitle
                )
                let childArr = (d["children"] as? [Any]) ?? (d["items"] as? [Any]) ?? []
                let nodes = nodesFromJSONItems(
                    childArr,
                    sourceUrl: sourceUrl,
                    fingerprint: fingerprint,
                    channelID: channelID,
                    parentPath: [idx],
                    diagnostics: &diagnostics
                )
                // 空 URL 分组：保留 channel，即使无子项
                channels.append(
                    ExploreChannel(
                        channelID: channelID,
                        rawTitle: rawTitle,
                        displayTitle: display.isEmpty ? "分组\(idx + 1)" : display,
                        rawStyle: style,
                        originalOrder: idx,
                        nodes: nodes
                    )
                )
            }
            return channels
        }

        let channelID = ExploreCatalogID.channelID(
            sourceUrl: sourceUrl,
            definitionFingerprint: fingerprint,
            indexPath: [0],
            rawTitle: ""
        )
        let nodes = nodesFromJSONItems(
            arr,
            sourceUrl: sourceUrl,
            fingerprint: fingerprint,
            channelID: channelID,
            parentPath: [0],
            diagnostics: &diagnostics
        )
        return [
            ExploreChannel(
                channelID: channelID,
                rawTitle: "",
                displayTitle: "发现",
                rawStyle: nil,
                originalOrder: 0,
                nodes: nodes
            )
        ]
    }

    private static func nodesFromJSONItems(
        _ arr: [Any],
        sourceUrl: String,
        fingerprint: String,
        channelID: String,
        parentPath: [Int],
        diagnostics: inout ExploreCatalogDiagnostics
    ) -> [ExploreNode] {
        var nodes: [ExploreNode] = []
        for (idx, item) in arr.enumerated() {
            let path = parentPath + [idx]
            if let s = item as? String {
                let parsed = ExploreCatalogLexer.parseItem(s)
                nodes.append(
                    makeNode(
                        parsed: parsed,
                        sourceUrl: sourceUrl,
                        fingerprint: fingerprint,
                        channelID: channelID,
                        indexPath: path,
                        order: idx,
                        diagnostics: &diagnostics
                    )
                )
                continue
            }
            guard let d = item as? [String: Any] else {
                diagnostics.codes.append("jsonNodeUnsupported")
                let rawTitle = String(describing: item)
                let nid = ExploreCatalogID.nodeID(
                    sourceUrl: sourceUrl,
                    definitionFingerprint: fingerprint,
                    channelID: channelID,
                    indexPath: path,
                    kind: .unsupported,
                    rawTitle: rawTitle,
                    rawTarget: ""
                )
                nodes.append(
                    ExploreNode(
                        nodeID: nid,
                        kind: .unsupported,
                        rawTitle: rawTitle,
                        displayTitle: "不支持",
                        rawTarget: "",
                        originalOrder: idx,
                        selectable: false,
                        diagnosticCode: "unsupportedNode"
                    )
                )
                continue
            }
            let rawTitle = (d["title"] as? String) ?? (d["name"] as? String) ?? ""
            let display = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = (d["url"] as? String) ?? (d["target"] as? String)
            let action = d["action"] as? String
            let style = styleValue(from: d["style"])
            let childArr = (d["children"] as? [Any]) ?? (d["items"] as? [Any])
            let kind: ExploreNodeKind
            let rawTarget: String
            let selectable: Bool
            var code: String?
            if let childArr, !childArr.isEmpty {
                kind = .group
                rawTarget = url ?? ""
                selectable = false
                let nid = ExploreCatalogID.nodeID(
                    sourceUrl: sourceUrl,
                    definitionFingerprint: fingerprint,
                    channelID: channelID,
                    indexPath: path,
                    kind: kind,
                    rawTitle: rawTitle,
                    rawTarget: rawTarget
                )
                let children = nodesFromJSONItems(
                    childArr,
                    sourceUrl: sourceUrl,
                    fingerprint: fingerprint,
                    channelID: channelID,
                    parentPath: path,
                    diagnostics: &diagnostics
                )
                nodes.append(
                    ExploreNode(
                        nodeID: nid,
                        kind: kind,
                        rawTitle: rawTitle,
                        displayTitle: display.isEmpty ? "分组\(idx + 1)" : display,
                        rawTarget: rawTarget,
                        rawStyle: style,
                        originalOrder: idx,
                        selectable: selectable,
                        diagnosticCode: code,
                        children: children
                    )
                )
                continue
            } else if let action, !(action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                kind = .action
                rawTarget = action
                selectable = true
            } else if let url {
                // 空 URL 保留为 group
                if url.isEmpty {
                    kind = .group
                    rawTarget = ""
                    selectable = false
                    code = "emptyURLGroup"
                } else {
                    kind = .url
                    rawTarget = url
                    selectable = true
                }
            } else if !rawTitle.isEmpty {
                kind = .group
                rawTarget = ""
                selectable = false
                code = "titleOnlyGroup"
            } else {
                kind = .unsupported
                rawTarget = ""
                selectable = false
                code = "unsupportedNode"
                diagnostics.codes.append("unsupportedNode")
            }
            let nid = ExploreCatalogID.nodeID(
                sourceUrl: sourceUrl,
                definitionFingerprint: fingerprint,
                channelID: channelID,
                indexPath: path,
                kind: kind,
                rawTitle: rawTitle,
                rawTarget: rawTarget
            )
            nodes.append(
                ExploreNode(
                    nodeID: nid,
                    kind: kind,
                    rawTitle: rawTitle,
                    displayTitle: display.isEmpty ? (kind == .group ? "分组\(idx + 1)" : "分类\(idx + 1)") : display,
                    rawTarget: rawTarget,
                    rawStyle: style,
                    originalOrder: idx,
                    selectable: selectable,
                    diagnosticCode: code
                )
            )
        }
        return nodes
    }

    private static func normalizeTextItems(
        _ items: [String],
        sourceUrl: String,
        fingerprint: String,
        diagnostics: inout ExploreCatalogDiagnostics
    ) -> [ExploreChannel] {
        let channelID = ExploreCatalogID.channelID(
            sourceUrl: sourceUrl,
            definitionFingerprint: fingerprint,
            indexPath: [0],
            rawTitle: ""
        )
        var nodes: [ExploreNode] = []
        for (idx, item) in items.enumerated() {
            // 保留空 segment 供诊断，但不强制生成空 node
            if item.isEmpty {
                diagnostics.codes.append("emptySegment")
                continue
            }
            // 跳过注释装饰行（与旧行为兼容，但空 URL group 不跳过）
            let leading = item.trimmingCharacters(in: .whitespacesAndNewlines)
            if leading.hasPrefix("//") || leading.hasPrefix("°") || leading.hasPrefix("☆") {
                diagnostics.codes.append("skippedCommentLine")
                continue
            }
            var parsed = ExploreCatalogLexer.parseItem(item)
            // 单段且无 `::`：整段视为 rawTarget（默认「发现」），不得当成空 target group
            if parsed.rawTarget.isEmpty,
               !item.contains("::"),
               looksLikeExploreTarget(item)
            {
                parsed = ExploreCatalogLexer.ParsedItem(rawTitle: "发现", rawTarget: item, rawStyle: nil)
            }
            nodes.append(
                makeNode(
                    parsed: parsed,
                    sourceUrl: sourceUrl,
                    fingerprint: fingerprint,
                    channelID: channelID,
                    indexPath: [0, idx],
                    order: idx,
                    diagnostics: &diagnostics
                )
            )
        }
        return [
            ExploreChannel(
                channelID: channelID,
                rawTitle: "",
                displayTitle: "发现",
                rawStyle: nil,
                originalOrder: 0,
                nodes: nodes
            )
        ]
    }

    private static func looksLikeExploreTarget(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return false }
        let lower = t.lowercased()
        return lower.hasPrefix("http")
            || t.hasPrefix("/")
            || t.contains("{{")
            || t.contains("://")
    }

    private static func makeNode(
        parsed: ExploreCatalogLexer.ParsedItem,
        sourceUrl: String,
        fingerprint: String,
        channelID: String,
        indexPath: [Int],
        order: Int,
        diagnostics: inout ExploreCatalogDiagnostics
    ) -> ExploreNode {
        let kind: ExploreNodeKind
        let selectable: Bool
        var code: String?
        if parsed.rawTarget.isEmpty {
            kind = .group
            selectable = false
            code = parsed.rawStyle == nil ? "titleOnlyGroup" : "emptyURLGroup"
        } else {
            // 非空 target：保留为可选择叶子（相对路径 / 规则串 / URL）
            kind = .url
            selectable = true
        }
        let display = parsed.rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let nid = ExploreCatalogID.nodeID(
            sourceUrl: sourceUrl,
            definitionFingerprint: fingerprint,
            channelID: channelID,
            indexPath: indexPath,
            kind: kind,
            rawTitle: parsed.rawTitle,
            rawTarget: parsed.rawTarget
        )
        if let code { diagnostics.codes.append(code) }
        return ExploreNode(
            nodeID: nid,
            kind: kind,
            rawTitle: parsed.rawTitle,
            displayTitle: display.isEmpty ? "分类\(order + 1)" : display,
            rawTarget: parsed.rawTarget,
            rawStyle: parsed.rawStyle,
            originalOrder: order,
            selectable: selectable,
            diagnosticCode: code
        )
    }

    private static func styleValue(from any: Any?) -> ExploreJSONValue? {
        guard let any else { return nil }
        return ExploreJSONValue.fromAny(any)
    }
}
