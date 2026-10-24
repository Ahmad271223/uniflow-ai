// swift-tools-version:5.9
// Plattformunabhaengiger Kern der UniFlow-Apps: Notizmodell, JSON, Zusammenfuehren, lokales Journal,
// Synchronisierung. Laeuft auf iOS/macOS und Linux (CI ohne Mac: `swift test`).
import PackageDescription

let package = Package(
    name: "UniFlowCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "UniFlowCore", targets: ["UniFlowCore"]),
    ],
    targets: [
        .target(name: "UniFlowCore"),
        .testTarget(name: "UniFlowCoreTests", dependencies: ["UniFlowCore"]),
    ]
)
