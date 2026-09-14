// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FindYoshiIT",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FindAnythingCore", targets: ["FindAnythingCore"]),
        .executable(name: "FindYoshiIT", targets: ["FindAnythingApp"]),
        .executable(name: "FindYoshiBenchmark", targets: ["SearchBenchmark"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "VectorMath", publicHeadersPath: "include"),
        .target(name: "FindAnythingCore", dependencies: ["CSQLite", "VectorMath"]),
        .executableTarget(name: "FindAnythingApp", dependencies: ["FindAnythingCore"]),
        .executableTarget(name: "SearchBenchmark", dependencies: ["FindAnythingCore"]),
        .testTarget(name: "FindAnythingCoreTests", dependencies: ["FindAnythingCore"]),
        .testTarget(name: "FindAnythingAppTests", dependencies: ["FindAnythingApp", "FindAnythingCore"])
    ],
    swiftLanguageModes: [.v5]
)
