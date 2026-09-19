import Foundation

// Where things live. Two modes:
//  - standalone: run.sh and its helpers ship inside the app (Contents/Resources/runtime), the kernel/rootfs pair is
//    downloaded into ~/Library/Application Support/myLinux/image, machines get their own folder under machines/.
//  - developer: a myLinux source checkout (Settings) provides run.sh, tools/ and out/, so builds and hot-swapped
//    binaries in that checkout are what starts.
enum Paths {
    // MYLINUX_SUPPORT_DIR points tests at a folder of their own instead of the user's data
    static let support: URL = ProcessInfo.processInfo.environment["MYLINUX_SUPPORT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("myLinux", isDirectory: true)
    static var profilesFile: URL { support.appendingPathComponent("profiles.json") }
    static var logs: URL { support.appendingPathComponent("logs", isDirectory: true) }
    static var machines: URL { support.appendingPathComponent("machines", isDirectory: true) }
    static var standaloneImage: URL { support.appendingPathComponent("image", isDirectory: true) }
    static var bundledRuntime: URL? { Bundle.main.resourceURL?.appendingPathComponent("runtime", isDirectory: true) }
    /// The checkout the app was built from (Info.plist), offered as the developer checkout when it exists.
    static var buildRepo: String? { Bundle.main.object(forInfoDictionaryKey: "MyLinuxRepo") as? String }

    /// GUI apps do not inherit the shell's PATH; Homebrew lives in one of these.
    static let toolPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// Homebrew's QEMU, if installed.
    static func qemu() -> String? {
        ["/opt/homebrew/bin/qemu-system-aarch64", "/usr/local/bin/qemu-system-aarch64"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The accelerated runtime's QEMU inside an out folder, if tools/get-qemu-runtime.sh installed one there
    /// (the same test as tools/qemu-flavour.sh: the binary and its lib folder).
    static func runtimeQemu(in out: URL) -> String? {
        let dir = out.appendingPathComponent("qemu-runtime", isDirectory: true)
        let bin = dir.appendingPathComponent("bin/qemu-system-aarch64").path
        var isDir: ObjCBool = false
        guard FileManager.default.isExecutableFile(atPath: bin),
              FileManager.default.fileExists(atPath: dir.appendingPathComponent("lib").path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return bin
    }

    static func isCheckout(_ path: String) -> Bool {
        !path.isEmpty && FileManager.default.isReadableFile(atPath: (path as NSString).appendingPathComponent("run.sh"))
            && FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent("tools/get-image.sh"))
    }

    /// A folder name from a profile name: letters, digits, dashes.
    static func slug(_ name: String) -> String {
        let s = name.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        return s.isEmpty ? "machine" : s
    }

    static let posixLocale = Locale(identifier: "en_US_POSIX")
}

/// App-wide settings (UserDefaults).
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var repoPath: String { didSet { UserDefaults.standard.set(repoPath, forKey: "repoPath") } }
    /// Move the machine's window onto the screen it was sized for. run.sh does that through System Events, so
    /// macOS asks this app for Automation permission the first time: off unless the user wants it.
    @Published var placeWindow: Bool { didSet { UserDefaults.standard.set(placeWindow, forKey: "placeWindow") } }

    private init() {
        placeWindow = UserDefaults.standard.bool(forKey: "placeWindow")
        if let saved = UserDefaults.standard.string(forKey: "repoPath") {
            repoPath = saved
        } else if let built = Paths.buildRepo, Paths.isCheckout(built) {
            repoPath = built                    // built from a checkout on this Mac: start in developer mode
        } else {
            repoPath = ""
        }
    }

    var developerMode: Bool { Paths.isCheckout(repoPath) }

    /// Directory holding run.sh and tools/.
    var scriptsDir: URL? {
        developerMode ? URL(fileURLWithPath: repoPath, isDirectory: true) : Paths.bundledRuntime
    }
    /// MYLINUX_OUT: Image, rootfs.cpio.gz and the myLinux.app QEMU wrapper.
    var outDir: URL {
        developerMode ? URL(fileURLWithPath: repoPath, isDirectory: true).appendingPathComponent("out", isDirectory: true)
                      : Paths.standaloneImage
    }
    var imagePresent: Bool {
        let fm = FileManager.default
        func nonEmpty(_ name: String) -> Bool {
            let p = outDir.appendingPathComponent(name).path
            return ((try? fm.attributesOfItem(atPath: p)[.size] as? NSNumber)?.int64Value ?? 0) > 0
        }
        return nonEmpty("Image") && nonEmpty("rootfs.cpio.gz")
    }
    /// The accelerated QEMU runtime next to the image (run.sh prefers it over Homebrew's QEMU).
    var runtimePresent: Bool { Paths.runtimeQemu(in: outDir) != nil }
    var runtimeRevision: String? {
        guard runtimePresent else { return nil }
        return (try? String(contentsOf: outDir.appendingPathComponent("qemu-runtime/RUNTIME-REVISION"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// Some QEMU can start a machine: the runtime, or Homebrew's.
    var qemuAvailable: Bool { runtimePresent || Paths.qemu() != nil }
    static let qemuMissingText = "QEMU is missing. Download the accelerated QEMU in Settings, or in Terminal: brew install qemu"

    var imageRevision: String? {
        (try? String(contentsOf: outDir.appendingPathComponent("IMAGE-REVISION"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
