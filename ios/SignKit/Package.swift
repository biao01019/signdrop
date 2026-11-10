// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SignKit",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(name: "SignKit", targets: ["SignKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19")
    ],
    targets: [
        .target(
            name: "SignKit",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ]
        ),
        .testTarget(
            name: "SignKitTests",
            dependencies: ["SignKit"]
        )
    ]
)
