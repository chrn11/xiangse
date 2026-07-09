import Foundation

/// 路线 A：将 Legado 书源转为香色闺阁完整 DOM 原生模型（基于 dicBaseModelTemplateDom）
enum XiangseNativeModelConverter {
    static let sourceType = "DOM"
    static let legadoProxyScheme = "locallinkSearchBook://"

    /// 从 BookSourceModelManager 读取官方 DOM 模板并深拷贝，再覆盖 Legado 字段
    static func nativeModel(for source: MemoryBridgeBookSource, manager: NSObject) -> NSMutableDictionary {
        let template = domTemplate(from: manager)
        let overlay = overlayFields(for: source)
        let merged = deepMerge(base: template, overlay: overlay)
        injectLegadoProxyActions(into: merged, source: source)
        return merged
    }

    /// 首次同步时把模板 top-level 键名写入调试文件，便于逆向校验
    static func dumpTemplateKeysIfNeeded(_ template: [String: Any]) {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent("Documents/legado_dom_template_keys.txt")
        guard !FileManager.default.fileExists(atPath: path) else { return }
        let keys = template.keys.sorted().joined(separator: "\n")
        try? keys.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Private

    private static func domTemplate(from manager: NSObject) -> [String: Any] {
        let sel = NSSelectorFromString("dicBaseModelTemplateDom")
        guard manager.responds(to: sel),
              let raw = manager.perform(sel)?.takeUnretainedValue() as? [String: Any],
              !raw.isEmpty else {
            return fallbackTemplate()
        }
        dumpTemplateKeysIfNeeded(raw)
        return raw
    }

    /// 模板不可读时的最小 DOM 骨架（须含原生启用键 enable="1"，否则 canSearch 判无可用站点）
    private static func fallbackTemplate() -> [String: Any] {
        [
            "sourceType": sourceType,
            "enable": "1",
            "enabled": true,
            "weight": 50,
            "searchBook": [
                "actionID": "searchBook",
                "parserID": sourceType
            ],
            "cf_title": "Legado",
            "cf_opentype": "0"
        ]
    }

    private static func overlayFields(for source: MemoryBridgeBookSource) -> [String: Any] {
        // 真机 Frida：dicBaseModelTemplateDom / 可用源均用字符串 enable="1"；
        // 仅写 Bool enabled 会被 canSearch / 启用筛选忽略 →「无可用站点」。
        [
            "sourceName": source.bookSourceName,
            "sourceType": sourceType,
            "sourceUrl": source.bookSourceUrl,
            "title": source.bookSourceName,
            "enable": "1",
            "enabled": true,
            "weight": 50,
            XiangseAdapter.legadoMarkerKey: XiangseAdapter.legadoMarkerValue,
            "bookSourceUrl": source.bookSourceUrl,
            "legadoBookSourceUrl": source.bookSourceUrl,
            "legadoBookSourceName": source.bookSourceName
        ]
    }

    /// 在模型中写入 Legado 代理深链，供原生搜索/目录链路识别（配合 Hook 转发引擎）
    private static func injectLegadoProxyActions(into model: NSMutableDictionary, source: MemoryBridgeBookSource) {
        let encodedUrl = source.bookSourceUrl.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? source.bookSourceUrl
        let proxy = "\(legadoProxyScheme)legado?url=\(encodedUrl)"
        model["cf_targeturl"] = proxy
        model["cf_opentype"] = "0"
        if model["cf_title"] == nil {
            model["cf_title"] = source.bookSourceName
        }
        // 模板本身无 sourceType/sourceName；强制补齐，避免筛选按 typeTitle 丢弃
        model["sourceType"] = sourceType
        model["enable"] = "1"
        model["enabled"] = true
    }

    private static func deepMerge(base: [String: Any], overlay: [String: Any]) -> NSMutableDictionary {
        let result = NSMutableDictionary(dictionary: base)
        for (key, value) in overlay {
            if let baseDict = result[key] as? [String: Any],
               let overlayDict = value as? [String: Any] {
                result[key] = deepMerge(base: baseDict, overlay: overlayDict)
            } else if let baseDict = result[key] as? NSDictionary,
                      let overlayDict = value as? [String: Any] {
                result[key] = deepMerge(base: baseDict as! [String: Any], overlay: overlayDict)
            } else {
                result[key] = value
            }
        }
        return result
    }
}
