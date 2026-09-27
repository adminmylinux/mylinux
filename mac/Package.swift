// swift-tools-version:6.0
// myLinux for the Mac: a launcher app around run.sh with saved machine profiles, and a native VNC viewer / SSH
// terminal for remote machines (docs/MAC-REMOTE-PLAN.md). Built into an app bundle by mac/build-app.sh.
// Needs Homebrew's libvncserver (libvncclient) at build and run time; GhosttyKit (Ghostty's terminal as a library, the
// terminals of the servers and SSH connections) comes as a Swift package, pinned to one release.
import PackageDescription

let package = Package(
    name: "myLinuxMac",
    platforms: [.macOS(.v15)],
    dependencies: [
        // tools/get-ghosttykit.sh unpacks the pinned release there (SwiftPM's own download of its binary stalls)
        .package(path: "../out/ghosttykit/libghostty-spm"),
    ],
    targets: [
        .systemLibrary(name: "CVncClient", path: "CVncClient", pkgConfig: "libvncclient",
                       providers: [.brew(["libvncserver"])]),
        .executableTarget(
            name: "myLinux",
            dependencies: ["CVncClient", .product(name: "GhosttyTerminal", package: "libghostty-spm")],
            path: "Sources/myLinux",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("IOSurface"), .linkedFramework("QuartzCore"), .linkedFramework("Carbon"),
                             .linkedFramework("Security"), .linkedFramework("Network"), .linkedFramework("WebKit")]
        ),
        .testTarget(
            name: "myLinuxTests",
            dependencies: ["myLinux"],
            path: "Tests/myLinuxTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
