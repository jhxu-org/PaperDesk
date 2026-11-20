// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PaperDesk",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PaperDesk", targets: ["PaperDesk"]),
               .executable(name: "PaperDeskBridge", targets: ["PaperDeskBridge"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "PaperDeskCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "PaperDesk", dependencies: ["PaperDeskCore"], resources: [.copy("Resources/Chat")]),
        .executableTarget(name: "PaperDeskBridge", dependencies: ["PaperDeskCore"]),
        .executableTarget(name: "PaperDeskChecks", dependencies: ["PaperDeskCore"], path: "Tests/PaperDeskCoreTests")
    ]
)
