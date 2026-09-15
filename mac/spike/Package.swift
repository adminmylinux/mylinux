// swift-tools-version:5.9
// Phase 0 spike for docs/MAC-REMOTE-PLAN.md: libvncclient (Homebrew libvncserver) from Swift, the framebuffer in an
// IOSurface shown by a CALayer, and numbers on screen. Throwaway: the real viewer goes into the launcher.
//   cd mac/spike && swift build -c release && .build/release/vncspike host[:port] [username] [ca.pem]
import PackageDescription

let package = Package(
    name: "vncspike",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "CVncClient", path: "CVncClient", pkgConfig: "libvncclient"),
        .executableTarget(
            name: "vncspike",
            dependencies: ["CVncClient"],
            path: "Sources",
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("IOSurface"), .linkedFramework("QuartzCore"), .linkedFramework("Carbon")]
        ),
    ]
)
