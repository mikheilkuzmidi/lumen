// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Lumen",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "LumenCore", targets: ["LumenCore"]),
        .library(name: "LumenMeta", targets: ["LumenMeta"]),
        .library(name: "LumenSAMMask", targets: ["LumenSAMMask"]),
        .library(name: "LumenRender", targets: ["LumenRender"]),
        .library(name: "LumenOpen", targets: ["LumenOpen"]),
        .executable(name: "lumen", targets: ["lumen"]),
        .executable(name: "LumenStudio", targets: ["LumenStudio"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        // The edit plan, layers, the agent loop and the model protocols. No networking and no pixels.
        .target(name: "LumenCore"),
        // Muse Spark, SAM 3.1 and Muse Image through the Meta Model API.
        .target(name: "LumenMeta", dependencies: ["LumenCore", "LumenSAMMask"]),
        // SAM 3.1's mask decoder, ported from Meta's reference parser; under the SAM License (its own LICENSE).
        .target(name: "LumenSAMMask", exclude: ["LICENSE"]),
        // Layers applied to a photo with Core Image.
        .target(name: "LumenRender", dependencies: ["LumenCore"]),
        // Open-weight planners: Muse Spark Open on a hosting provider, Muse Glimmer on this Mac.
        .target(name: "LumenOpen", dependencies: ["LumenCore"]),
        .executableTarget(name: "lumen", dependencies: [
            "LumenCore", "LumenMeta", "LumenRender", "LumenOpen",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        .executableTarget(name: "LumenStudio", dependencies: ["LumenCore", "LumenMeta", "LumenRender", "LumenOpen"]),
        .testTarget(name: "LumenCoreTests", dependencies: ["LumenCore"]),
        .testTarget(name: "LumenMetaTests", dependencies: ["LumenMeta"], resources: [.copy("Recorded")]),
        .testTarget(name: "LumenSAMMaskTests", dependencies: ["LumenSAMMask"]),
        .testTarget(name: "LumenRenderTests", dependencies: ["LumenRender"]),
        .testTarget(name: "LumenOpenTests", dependencies: ["LumenOpen"]),
        .testTarget(name: "LumenCLITests", dependencies: ["lumen"]),
        // A paid end-to-end edit with the Meta models; skipped unless LUMEN_LIVE=1.
        .testTarget(name: "LumenLiveTests", dependencies: ["LumenCore", "LumenMeta", "LumenRender"]),
    ]
)
