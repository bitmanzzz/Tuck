// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tuck",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Tuck",
            path: "Sources/Tuck",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
