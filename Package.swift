// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Cablehop",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Cablehop", path: "Sources/Cablehop"),
        .testTarget(name: "CablehopTests", dependencies: ["Cablehop"], path: "Tests/CablehopTests"),
    ]
)
