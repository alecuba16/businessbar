// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BusinessBar",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "BusinessBar",
            targets: ["BusinessBar"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/Defaults", from: "8.0.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
        .package(url: "https://github.com/sindresorhus/LaunchAtLogin-Modern", from: "1.0.0"),
        .package(url: "https://github.com/openid/AppAuth-iOS", from: "1.7.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.5.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.1")
    ],
    targets: [
        // Core library — pure business-logic code importable by both the app
        // and the unit-test target.
        .target(
            name: "BusinessBarCore",
            dependencies: [
                "Defaults",
                .product(name: "AppAuth", package: "AppAuth-iOS")
            ],
            path: "BusinessBarCore"
        ),
        // Main application executable
        .executableTarget(
            name: "BusinessBar",
            dependencies: [
                "BusinessBarCore",
                "Defaults",
                "KeyboardShortcuts",
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "LaunchAtLogin", package: "LaunchAtLogin-Modern"),
                .product(name: "AppAuth", package: "AppAuth-iOS"),
                "Sparkle"
            ],
            path: "BusinessBar",
            exclude: [
                "Resources/Info.plist",
                "Resources/BusinessBar.entitlements",
                "Resources/AppIcon.icns",
                "Resources/credentials.local.json.example",
                "Resources/credentials.local.json",
                // Excluded on purpose: SwiftPM runs an actool version probe for
                // any .xcassets in the build, regardless of .process or .copy,
                // and actool exists only in full Xcode. Nothing loads from this
                // catalog at runtime (icons render from SF Symbols; the app icon
                // ships as AppIcon.icns via bundle_app.sh), so excluding it
                // keeps the package buildable with Command Line Tools alone.
                "Resources/Assets.xcassets"
            ],
            resources: [
                .process("Resources/en.lproj"),
                .copy("Resources/credentials.json")
            ]
        ),
        // Unit-test target
        .testTarget(
            name: "BusinessBarTests",
            dependencies: [
                "BusinessBarCore",
                "Defaults",
                .product(name: "AppAuth", package: "AppAuth-iOS")
            ],
            path: "Tests/BusinessBarTests"
        ),
        .testTarget(
            name: "BusinessBarCoverageTests",
            dependencies: ["BusinessBar", "BusinessBarCore"],
            path: "Tests/CoverageTests"
        )
    ]
)
