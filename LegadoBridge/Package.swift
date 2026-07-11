// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LegadoBridge",
    platforms: [
        .iOS(.v13)
    ],
    products: [
        .library(name: "LegadoBridge", type: .dynamic, targets: ["LegadoBridge"]),
        .library(name: "LegadoRuleCore", targets: ["LegadoRuleCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.6.0"),
        .package(url: "https://github.com/tid-kijyun/Kanna.git", from: "5.2.0")
    ],
    targets: [
        .target(
            name: "LegadoBridgeHooks",
            path: "Sources/LegadoBridgeHooks",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("UIKit")
            ]
        ),
        // 独立规则引擎：规则 / 网络 / Cookie / 变量 / JS API
        .target(
            name: "LegadoRuleCore",
            dependencies: [
                "SwiftSoup",
                "Kanna"
            ],
            path: "Sources",
            exclude: [
                // Vendor 内旧版依赖 CoreData 的替换/调试实现；无 CoreData 版见 LegadoRuleCore/Replace*.swift
                "LegadoBridge/Vendor/Core/RuleEngine/RuleDebugger.swift",
                "LegadoBridge/Vendor/Core/RuleEngine/ReplaceAnalyzer.swift",
                "LegadoBridge/Vendor/Core/RuleEngine/ReplaceEngine.swift",
                "LegadoBridge/Vendor/Core/RuleEngine/ReplaceEngineEnhanced.swift"
            ],
            sources: [
                "LegadoRuleCore",
                "LegadoBridge/Vendor/Core/RuleEngine",
                "LegadoBridge/Vendor/Core/Network/AnalyzeUrl.swift",
                "LegadoBridge/Vendor/Core/Network/DecompressInterceptor.swift",
                "LegadoBridge/Vendor/Core/Network/BackstageWebView.swift",
                "LegadoBridge/Vendor/Core/Network/ConcurrentRateLimiter.swift",
                "LegadoBridge/Vendor/Core/Network/StrResponse.swift",
                "LegadoBridge/Vendor/Core/Model/BookSourcePart.swift",
                "LegadoBridge/Vendor/Core/Utils",
                "LegadoBridge/Bridge/BridgeSourceProtocol.swift",
                "LegadoBridge/Bridge/BridgeRuleTypes.swift",
                "LegadoBridge/Bridge/BridgeBook.swift",
                "LegadoBridge/Bridge/BridgeStubs.swift"
            ],
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("WebKit"),
                .linkedFramework("JavaScriptCore"),
                .linkedFramework("Security")
            ]
        ),
        .target(
            name: "LegadoBridge",
            dependencies: [
                "LegadoBridgeHooks",
                "LegadoRuleCore",
                "SwiftSoup",
                "Kanna"
            ],
            path: "Sources/LegadoBridge",
            exclude: [
                "Vendor",
                "Bridge/BridgeSourceProtocol.swift",
                "Bridge/BridgeRuleTypes.swift",
                "Bridge/BridgeBook.swift",
                "Bridge/BridgeStubs.swift"
            ],
            sources: [
                "Bridge"
            ],
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("WebKit"),
                .linkedFramework("JavaScriptCore"),
                .linkedFramework("Security")
            ]
        ),
        .testTarget(
            name: "LegadoRuleCoreTests",
            dependencies: ["LegadoRuleCore"],
            path: "Tests/LegadoRuleCoreTests",
            resources: [
                .copy("Fixtures")
            ]
        ),
        .testTarget(
            name: "LegadoBridgeTests",
            dependencies: ["LegadoBridge"],
            path: "Tests/LegadoBridgeTests"
        )
    ]
)
