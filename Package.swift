// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BocchiSmartPet",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "BocchiSmartPet", targets: ["BocchiSmartPet"])],
    targets: [
        .target(name: "BocchiCore"),
        .executableTarget(name: "BocchiSmartPet", dependencies: ["BocchiCore"]),
        .testTarget(name: "BocchiCoreTests", dependencies: ["BocchiCore"])
    ]
)
