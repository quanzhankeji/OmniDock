// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "OmniDock",
    defaultLocalization: "en",
    platforms: [
        .macOS("12.3")
    ],
    products: [
        .executable(name: "OmniDock", targets: ["OmniDock"])
    ],
    targets: [
        .target(
            name: "OmniDockCore",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("IOKit"),
                .linkedFramework("ScreenCaptureKit")
            ]
        ),
        .executableTarget(
            name: "OmniDock",
            dependencies: ["OmniDockCore"]
        ),
        .testTarget(
            name: "OmniDockCoreTests",
            dependencies: ["OmniDockCore"]
        )
    ]
)
