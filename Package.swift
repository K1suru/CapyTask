// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CapyTask",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CapyTask", targets: ["CapyTask"])
    ],
    targets: [
        .executableTarget(
            name: "CapyTask",
            exclude: ["Resources/Info.plist"],
            resources: [.copy("Resources/Images")],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(
            name: "CapyTaskTests",
            dependencies: ["CapyTask"]
        )
    ]
)
