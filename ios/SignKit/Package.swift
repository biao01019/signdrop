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
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
        // SRP 需要 2048 位模幂，标准库没有大数类型。
        .package(url: "https://github.com/attaswift/BigInt.git", from: "5.3.0")
    ],
    targets: [
        .target(
            name: "SignKit",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "BigInt", package: "BigInt")
            ]
        ),
        .testTarget(
            name: "SignKitTests",
            dependencies: [
                "SignKit",
                .product(name: "BigInt", package: "BigInt")
            ]
        )
    ]
)
