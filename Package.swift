// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NavTree",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(name: "NavTree", targets: ["NavTree"])
    ],
    targets: [
        .target(name: "NavTree"),
        .testTarget(name: "NavTreeTests", dependencies: ["NavTree"])
    ]
)
