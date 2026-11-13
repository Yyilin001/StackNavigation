// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StackNavigation",
    platforms: [.iOS(.v17)],
    products: [.library(name: "StackNavigation", targets: ["StackNavigation"])],
    targets: [
        .target(name: "StackNavigation"),
        .testTarget(name: "StackNavigationTests", dependencies: ["StackNavigation"])
    ]
)
