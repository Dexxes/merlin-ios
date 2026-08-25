// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Merlin",
    // Erforderlich, sobald lokalisierte Resources (en.lproj/de.lproj) im
    // Spiel sind - sonst bricht `swift build` (xtool) mit
    // "manifest property 'defaultLocalization' not set" ab.
    defaultLocalization: "en",
    platforms: [
        .iOS(.v18),
    ],
    products: [
        // Main app
        .library(
            name: "Merlin",
            targets: ["Merlin"]
        ),
        // Share Extension
        .library(
            name: "MerlinShare",
            targets: ["MerlinShare"]
        ),
    ],
    targets: [
        .target(
            name: "Merlin",
            exclude: ["Info.plist", "Merlin.entitlements"],
            resources: [
                .process("Assets.xcassets"),
                .process("Resources"),
                .copy("no-img.png"),
                .copy("merlin-logo.png"),
            ]
        ),
        .target(
            name: "MerlinShare",
            exclude: ["Info.plist", "MerlinShare.entitlements"],
            resources: [
                .process("Assets.xcassets"),
                .process("Resources"),
            ]
        ),
    ]
)
