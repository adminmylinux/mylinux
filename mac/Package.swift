// swift-tools-version:6.0
// myLinux for the Mac: a launcher app around run.sh with saved machine profiles. Built into an app bundle by
// mac/build-app.sh (swift build alone produces only the executable).
import PackageDescription

let package = Package(
    name: "myLinuxMac",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "myLinux",
            path: "Sources/myLinux",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "myLinuxTests",
            dependencies: ["myLinux"],
            path: "Tests/myLinuxTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
