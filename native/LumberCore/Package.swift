// swift-tools-version: 6.0
// LumberCore: everything in Lumber that doesn't need Apple-only frameworks
// (DSP, mixing, WAV, the Demucs pipeline, timing math, song sources, prompt
// interpretation). Builds and tests on Linux as well as iOS, so it can be
// verified without a Mac.

import PackageDescription

let package = Package(
    name: "LumberCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LumberCore", targets: ["LumberCore"]),
    ],
    targets: [
        .target(name: "LumberCore"),
        .testTarget(
            name: "LumberCoreTests",
            dependencies: ["LumberCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
