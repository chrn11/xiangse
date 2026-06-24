// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LegadoBridge",
    platforms: [
        .iOS(.v13),
        .macOS(.v13)
    ],
    products: [
        .library(name: "LegadoBridge", type: .dynamic, targets: ["LegadoBridge"])
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
        .target(
            name: "LegadoBridge",
            dependencies: [
                "LegadoBridgeHooks",
                "SwiftSoup",
                "Kanna"
            ],
            path: "Sources/LegadoBridge",
            exclude: [
                "Vendor/Core/Model/WebBook.swift",
                "Vendor/Core/Cache/ImageCacheManager.swift",
                "Vendor/Core/RuleEngine/RuleDebugger.swift",
                "Vendor/Core/RuleEngine/ReplaceEngine.swift",
                "Vendor/Core/RuleEngine/ReplaceEngineEnhanced.swift"
            ],
            sources: [
                "Bridge",
                "Vendor"
            ],
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("UIKit"),
                .linkedFramework("WebKit"),
                .linkedFramework("JavaScriptCore"),
                .linkedFramework("Security"),
                .linkedFramework("CoreGraphics")
            ]
        )
    ]
)
