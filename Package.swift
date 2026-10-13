// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "gpt-mem",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "gpt-mem", targets: ["GPTMemoryCLI"]),
        .executable(name: "gpt-manager", targets: ["GPTMemoryDesktop"]),
        .library(name: "GPTAnalysisKit", targets: ["GPTAnalysisKit"]),
        .library(name: "GPTSessionKit", targets: ["GPTSessionKit"]),
        .library(name: "GPTMemoryCore", targets: ["GPTMemoryCore"])
    ],
    targets: [
        .target(name: "CNative", linkerSettings: [.linkedLibrary("proc"), .linkedLibrary("sqlite3")]),
        .target(name: "GPTAnalysisKit"),
        .target(name: "GPTSessionKit", dependencies: ["GPTAnalysisKit"]),
        .target(name: "GPTMemoryCore", dependencies: ["CNative", "GPTAnalysisKit"]),
        .executableTarget(name: "GPTMemoryCLI", dependencies: ["GPTMemoryCore"]),
        .executableTarget(name: "GPTMemoryDesktop", dependencies: ["GPTMemoryCore", "GPTAnalysisKit", "GPTSessionKit"]),
        .testTarget(name: "GPTMemoryCoreTests", dependencies: ["GPTMemoryCore", "GPTAnalysisKit"]),
        .testTarget(name: "GPTAnalysisKitTests", dependencies: ["GPTAnalysisKit"]),
        .testTarget(name: "GPTSessionKitTests", dependencies: ["GPTSessionKit"])
    ],
    swiftLanguageModes: [.v5]
)
