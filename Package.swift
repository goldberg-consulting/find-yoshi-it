// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FindYoshiIT",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FindAnythingCore", targets: ["FindAnythingCore"]),
        .executable(name: "FindYoshiIT", targets: ["FindAnythingApp"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "FindAnythingCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "FindAnythingApp", dependencies: ["FindAnythingCore"]),
        .testTarget(name: "FindAnythingCoreTests", dependencies: ["FindAnythingCore"]),
        .testTarget(name: "FindAnythingAppTests", dependencies: ["FindAnythingApp", "FindAnythingCore"])
    ],
    swiftLanguageModes: [.v5]
)
