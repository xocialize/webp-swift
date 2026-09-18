// swift-tools-version: 6.2
import PackageDescription

// webp-swift — WebP ENCODING for media-bridge consumers. Apple decodes WebP natively (ImageIO,
// macOS 11+) but ships no encoder: on macOS 27.2 `CGImageDestinationCopyTypeIdentifiers()` lists 22
// writable types and WebP is not one of them (Docs/WEBP-NATIVE.md in the Forge workspace). The only
// encoder is libwebp, which this package carries so that media-bridge itself stays pure-Swift.
//
// Unlike vpx-swift, there is no binary here: libwebp is plain C99 with intrinsics-only SIMD — zero
// assembly, no configure step — so it is vendored AS SOURCE (Sources/CWebP, v1.6.0 verbatim) and
// compiled by SwiftPM's own clang. What you can read, grep and rebuild is a lighter thing than an
// xcframework, and it satisfies the same quarantine: the codec lives in the REGISTERED package.
//
//     import WebPSwift
//     WebPStillEncoder.register()          // once at startup — WebP is now a lane the Kit can race
//
// or drive it directly: `try WebPStillEncoder().encode(cgImage, quality: 0.8)`.
//
//   CWebP      libwebp v1.6.0 from source: encoder + decoder + sharpyuv (~656 KB static, arm64).
//   WebPSwift  `WebPStillEncoder: ExternalStillEncoder` at Chrome's exact settings, straight alpha.
//
// License: BSD-3-Clause (matching libwebp + its PATENTS grant, reproduced in THIRD-PARTY-NOTICES.txt).
// media-bridge stays MIT; only a consumer that links webp-swift accepts BSD-3 + the patent grant.
let package = Package(
    name: "webp-swift",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WebPSwift", targets: ["WebPSwift"]),
    ],
    dependencies: [
        // 0.39.0 is the first tag carrying `ExternalStillEncoder` + `MediaBridge.register(externalStillEncoder:)`.
        .package(url: "https://github.com/xocialize/media-bridge.git", from: "0.39.0"),
    ],
    targets: [
        .target(
            name: "CWebP",
            path: "Sources/CWebP",
            sources: ["src", "sharpyuv"],
            publicHeadersPath: "include",
            // libwebp includes its own headers as "src/webp/…" and "sharpyuv/…", relative to its root.
            cSettings: [.headerSearchPath(".")]
        ),
        .target(
            name: "WebPSwift",
            dependencies: [
                "CWebP",
                .product(name: "MediaImport", package: "media-bridge"),   // the ExternalStillEncoder protocol
                .product(name: "MediaBridge", package: "media-bridge"),   // the one-line `register()`
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]   // CGImage isn't Sendable; C pointers are hand-checked
        ),
        .testTarget(
            name: "WebPSwiftTests",
            dependencies: [
                "WebPSwift",
                .product(name: "MediaBridge", package: "media-bridge"),
                .product(name: "MediaImport", package: "media-bridge"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
