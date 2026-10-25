// swift-tools-version:5.9
// Plattformunabhaengiger Kern der UniFlow-Apps: Notizmodell, JSON, Zusammenfuehren, lokales Journal,
// Synchronisierung, lokale Datenbank. Laeuft auf iOS/macOS und Linux (CI ohne Mac: `swift test`).
//
// SQLite ohne Fremdpaket: iOS/macOS bringen das Modul SQLite3 mit; unter Linux bindet das Ziel CSQLite die
// System-Bibliothek ein (Kopfdateien aus libsqlite3-dev).
import PackageDescription

let package = Package(
    name: "UniFlowCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "UniFlowCore", targets: ["UniFlowCore"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite", providers: [.apt(["libsqlite3-dev"])]),
        .target(name: "UniFlowCore", dependencies: [.target(name: "CSQLite", condition: .when(platforms: [.linux]))]),
        .testTarget(name: "UniFlowCoreTests", dependencies: ["UniFlowCore"]),
    ]
)
