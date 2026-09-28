// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DisplayManager",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DisplayManager", targets: ["DisplayManager"])
    ],
    targets: [
        .target(name: "DisplayManagerCore"),
        .executableTarget(
            name: "DisplayManager",
            dependencies: ["DisplayManagerCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "DisplayManagerCoreTests",
            dependencies: ["DisplayManagerCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
