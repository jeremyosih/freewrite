// swift-tools-version: 6.0
import PackageDescription

// Vendored finnvoor/PiDurableKit (CC0), pinned in VENDORED.md. Mirrors upstream's library target.
let package = Package(
    name: "PiDurableKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "PiDurableKit", targets: ["PiDurableKit"]),
    ],
    targets: [
        .target(
            name: "PiDurableKit",
            path: "Sources/PiDurableKit",
            resources: [
                .copy("Resources/pi-durable.js"), .copy("Resources/Documentation"), .copy("Resources/ThirdPartyNotices.txt"),
                .copy("Resources/quickjs.wasm"), .copy("Resources/codemode-worker.js"),
            ],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
    ]
)
