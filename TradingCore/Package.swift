// swift-tools-version: 5.9
import PackageDescription

// The trading domain: strategy rules, signals, risk checks, paper execution, ledgers,
// backtests and the audit chain. Pure Swift with no UI and no network, so every rule
// here runs under `swift test` on a Mac in seconds.
let package = Package(
    name: "TradingCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TradingCore", targets: ["TradingCore"])
    ],
    targets: [
        .target(name: "TradingCore"),
        .testTarget(name: "TradingCoreTests", dependencies: ["TradingCore"])
    ],
    swiftLanguageVersions: [.v5]
)
