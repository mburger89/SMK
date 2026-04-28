// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "smk",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "SMK", targets: ["smk"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-mmio", branch: "main")
    ],
    targets: [
        .executableTarget(
            name: "smk",
            dependencies: [
                .product(name: "MMIO", package: "swift-mmio")
            ],
            swiftSettings: [
                .enableExperimentalFeature("Embedded"),
                .enableExperimentalFeature("Extern"),
                .unsafeFlags([
                    "-wmo",                             // Required for Embedded Swift
                    "-Xfrontend", "-gnone",            // Disable debug info that requires SwiftOnoneSupport
                ])
            ]
        ),
    ]
)
