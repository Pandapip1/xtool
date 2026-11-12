// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DemoAssets",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "DemoAssets",
            targets: ["DemoAssets"]
        ),
    ],
    dependencies: [
        .package(path: "../ExampleSupport"),
    ],
    targets: [
        .target(
            name: "DemoAssets",
            dependencies: [
                "ExampleSupport",
            ],
            resources: [
                .process("Assets.xcassets"),
            ]
        ),
    ]
)
