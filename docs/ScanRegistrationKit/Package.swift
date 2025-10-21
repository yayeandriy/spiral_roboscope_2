
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ScanRegistrationKit",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "ScanRegistrationKit",
            targets: ["ScanRegistrationKit"]
        ),
    ],
    targets: [
        .target(
            name: "ScanRegistrationKit",
            path: "Sources/ScanRegistrationKit"
        ),
        .testTarget(
            name: "ScanRegistrationKitTests",
            dependencies: ["ScanRegistrationKit"],
            path: "Tests/ScanRegistrationKitTests"
        )
    ]
)
