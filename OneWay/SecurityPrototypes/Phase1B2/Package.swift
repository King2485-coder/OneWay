// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OneWayPhase1B2",
    platforms: [.macOS(.v13)],
    products: [.library(name: "OneWayPhase1B2", targets: ["OneWayPhase1B2"])],
    targets: [
        .target(
            name: "OneWayPhase1B2",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "OneWayPhase1B2Tests",
            dependencies: ["OneWayPhase1B2"]
        ),
    ]
)
