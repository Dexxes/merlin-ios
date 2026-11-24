// swift-tools-version: 6.0

import PackageDescription

// xtool auf Linux (WSL) hat keinen funktionierenden actool-Ersatz (siehe
// https://github.com/xtool-org/xtool/issues/310, Stand 2026-11-24 offen, kein
// Fix). Schon das blosse Durchlaufen eines .xcassets-Ordners - auch mit
// .copy() statt .process() - loest den actool-Aufruf aus und bricht den
// Build ab. Einziger bestaetigter Workaround: den Ordner komplett
// ausschliessen. Icons/benannte Image-Sets fehlen dann in lokalen WSL-Dev-
// Builds; fuer echte Release-Builds weiterhin macOS/Xcode nutzen, dort bleibt
// der Asset-Catalog echt kompiliert.
#if os(Linux)
let assetsExclude = ["Assets.xcassets"]
let assetsResources: [Resource] = []
#else
let assetsExclude: [String] = []
let assetsResources: [Resource] = [.process("Assets.xcassets")]
#endif

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
            exclude: ["Info.plist", "Merlin.entitlements", "PrivacyInfo.xcprivacy"] + assetsExclude,
            resources: assetsResources + [
                .process("Resources"),
                .copy("no-img.png"),
                .copy("merlin-logo.png"),
                .copy("paper-texture.png"),
            ]
        ),
        .target(
            name: "MerlinShare",
            exclude: ["Info.plist", "MerlinShare.entitlements", "PrivacyInfo.xcprivacy"] + assetsExclude,
            resources: assetsResources + [
                .process("Resources"),
                // Logo as a plain file: SwiftPM builds (xtool) don't compile
                // the asset catalog, so UIImage(named:) can't find it there.
                .copy("merlin-logo.png"),
            ]
        ),
    ]
)
