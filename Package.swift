// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "GPMCCore", platforms: [.macOS(.v13), .iOS(.v17)], products: [.library(name: "GPMCCore", targets: ["GPMCCore"])], targets: [.target(name: "GPMCCore", path: "GPMC/Core"), .testTarget(name: "GPMCCoreTests", dependencies: ["GPMCCore"])])
