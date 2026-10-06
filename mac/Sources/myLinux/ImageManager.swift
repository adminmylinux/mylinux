import Foundation
import AppKit

/// Runs one of the checkout's or the bundle's download scripts (tools/get-image.sh, tools/get-qemu-runtime.sh) with
/// MYLINUX_OUT pointing at the right folder, and publishes its last line of output as the progress text.
class ScriptDownloader: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var progress = ""
    /// When the running download began (the header counts its seconds).
    @Published private(set) var startedAt: Date?
    @Published fileprivate(set) var lastError: String?
    private var process: Process?

    /// Called on the main thread when the script has ended, whatever the outcome.
    func finished() {}

    func run(_ tool: String, arguments: [String] = [], environment extra: [String: String] = [:], starting: String, settings: AppSettings) {
        guard !busy, let scripts = settings.scriptsDir else { return }
        let script = scripts.appendingPathComponent(tool)
        guard FileManager.default.isReadableFile(atPath: script.path) else {
            lastError = "\(tool) is missing from the app."; return
        }
        busy = true; progress = starting; lastError = nil; startedAt = Date()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = [script.path] + arguments
        proc.currentDirectoryURL = scripts
        proc.environment = Self.environment(settings).merging(extra) { $1 }
        let pipe = Pipe()
        proc.standardOutput = pipe; proc.standardError = pipe
        var tail = ""
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { h.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            tail = String((tail + text).suffix(2000))
            let line = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).last.map(String.init)?
                .trimmingCharacters(in: .whitespaces)
            DispatchQueue.main.async { if let line, !line.isEmpty { self?.progress = line } }
        }
        proc.terminationHandler = { [weak self] pr in
            let out = tail
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false; self.progress = ""; self.process = nil
                if pr.terminationStatus != 0 {
                    let lines = out.split(whereSeparator: \.isNewline).map(String.init).suffix(3)
                    self.lastError = lines.isEmpty ? "Download failed (status \(pr.terminationStatus))." : lines.joined(separator: "\n")
                }
                self.finished()
            }
        }
        do { try proc.run(); process = proc } catch {
            busy = false; lastError = "Could not start the download: \(error.localizedDescription)"
        }
    }

    func cancel() { process?.terminate() }

    /// The scripts' environment: MYLINUX_OUT, and standalone the saved downloads (tools/download-cache.sh); a
    /// checkout's out/ is the developer's business.
    static func environment(_ settings: AppSettings) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Paths.toolPath
        env["MYLINUX_OUT"] = settings.outDir.path
        if !settings.developerMode { env["MYLINUX_CACHE"] = Paths.downloadCache.path }
        return env
    }

    /// A Linux that may be saved on this Mac already (tools/download-cache.sh). With nothing installed, the script's
    /// --check says what is saved and what is out: the saved copy installs when it is the latest (or the lookup
    /// fails: the script falls back to it), and when a newer one is out, the user chooses. An update of an installed
    /// one goes straight to the script, which still copies the saved one when that is the latest.
    func install(_ tool: String, name: String, size: String, installed: Bool, starting: String, settings: AppSettings) {
        guard !busy else { return }
        guard !installed, !settings.developerMode, let scripts = settings.scriptsDir else {
            run(tool, starting: starting, settings: settings); return
        }
        busy = true; progress = "Looking for a saved \(name)…"; lastError = nil; startedAt = Date()
        let env = Self.environment(settings)
        DispatchQueue.global(qos: .userInitiated).async {
            let answer = Self.capture(scripts.appendingPathComponent(tool), ["--check"], env: env, cwd: scripts, timeout: 45) ?? ""
            func value(_ key: String) -> String? {
                answer.split(separator: "\n").first { $0.hasPrefix(key) }.map { $0.dropFirst(key.count).trimmingCharacters(in: .whitespaces) }
            }
            let saved = value("cached:").flatMap { $0 == "none" || $0.isEmpty ? nil : $0 }
            let latest = value("latest:").flatMap { $0 == "unknown" || $0.isEmpty ? nil : $0 }
            DispatchQueue.main.async {
                self.busy = false; self.progress = ""
                guard let saved else { self.run(tool, starting: starting, settings: settings); return }
                guard let latest, latest != saved else {
                    self.run(tool, starting: "Installing the saved \(name)…", settings: settings); return
                }
                switch Self.askNewer(name: name, saved: saved, latest: latest, size: size) {
                case .alertFirstButtonReturn: self.run(tool, starting: starting, settings: settings)
                case .alertSecondButtonReturn:
                    self.run(tool, environment: ["MYLINUX_FROM_CACHE": "1"], starting: "Installing the saved \(name)…", settings: settings)
                default: break
                }
            }
        }
    }

    /// A newer one than the saved one is out: download it, or install the saved one (Cancel: neither).
    static func askNewer(name: String, saved: String, latest: String, size: String) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = "A newer \(name) is available"
        alert.informativeText = "\(name) \(saved) is saved on this Mac and installs in seconds, without a download.\n\nThe newer \(latest) is \(size) to download."
        alert.addButton(withTitle: "Download Newer")
        alert.addButton(withTitle: "Use Saved \(name)")
        alert.addButton(withTitle: "Cancel")
        // MYLINUX_TEST_NEWER=newer|saved (a scratch MYLINUX_SUPPORT_DIR only): the answer, and the question printed
        let env = ProcessInfo.processInfo.environment
        if let answer = env["MYLINUX_TEST_NEWER"], env["MYLINUX_SUPPORT_DIR"] != nil {
            print("asked: \(alert.messageText) | \(alert.informativeText.replacingOccurrences(of: "\n", with: " ")) | answered \(answer)")
            return answer == "saved" ? .alertSecondButtonReturn : .alertFirstButtonReturn
        }
        NSApp.activate()
        return alert.runModal()
    }

    /// A script's output (stdout), or nil when it could not start; ended after `timeout` seconds.
    static func capture(_ script: URL, _ args: [String], env: [String: String], cwd: URL, timeout: TimeInterval) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path] + args
        p.currentDirectoryURL = cwd
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let stop = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stop)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit(); stop.cancel()
        return String(decoding: data, as: UTF8.self)
    }
}

/// Saved downloads (tools/download-cache.sh, Paths.downloadCache): each Linux as last downloaded, kept through Clear
/// All Data, so a machine of that kind installs again without a download.
enum SavedDownloads {
    struct Item { let name: String; let revision: String; let bytes: Double }
    static let kinds: [(folder: String, name: String, revisionFile: String)] = [
        ("mylinux", "myLinux image", "IMAGE-REVISION"), ("omarchy", "Omarchy", "OMARCHY-REVISION"),
        ("debian", "Debian", "DEBIAN-REVISION"), ("alpine", "Alpine", "ALPINE-REVISION"),
        ("arch", "Arch Linux", "ARCH-REVISION"),
    ]

    /// At launch: Linuxes installed before saving existed are saved too (APFS clones: no time, no extra space).
    static func saveInstalled(_ settings: AppSettings = .shared) {
        guard !settings.developerMode, let scripts = settings.scriptsDir else { return }
        let env = ScriptDownloader.environment(settings)
        DispatchQueue.global(qos: .utility).async {
            _ = ScriptDownloader.capture(scripts.appendingPathComponent("tools/save-downloads.sh"), [], env: env, cwd: scripts, timeout: 300)
        }
    }

    /// What is saved, with its revision and size (measured: call off the main thread).
    static func list() -> [Item] {
        kinds.compactMap { k in
            let dir = Paths.downloadCache.appendingPathComponent(k.folder, isDirectory: true)
            guard let rev = try? String(contentsOf: dir.appendingPathComponent(k.revisionFile), encoding: .utf8) else { return nil }
            return Item(name: k.name, revision: rev.trimmingCharacters(in: .whitespacesAndNewlines), bytes: StorageUsage.allocated(dir))
        }
    }

    static func removeAll() -> String? {
        guard FileManager.default.fileExists(atPath: Paths.downloadCache.path) else { return nil }
        do { try FileManager.default.removeItem(at: Paths.downloadCache); return nil }
        catch { return "Could not remove the saved downloads: \(error.localizedDescription)" }
    }
}

/// The kernel + root filesystem pair. Standalone, this downloads a myLinux release into Application Support with
/// tools/get-image.sh (one release resolved, checksummed, previous pair kept). In developer mode the checkout's
/// own out/ is used and building is the checkout's business.
final class ImageManager: ScriptDownloader {
    static let shared = ImageManager()

    @Published private(set) var revision: String?
    @Published private(set) var present = false

    func refresh(_ settings: AppSettings = .shared) {
        revision = settings.imageRevision
        present = settings.imagePresent
    }

    func download(_ settings: AppSettings = .shared) {
        install("tools/get-image.sh", name: "myLinux", size: "about 120 MB", installed: present, starting: "Looking up the latest release…", settings: settings)
    }

    override func finished() { refresh() }
}

/// The accelerated QEMU (tools/get-qemu-runtime.sh): QEMU with VirGL in <out>/qemu-runtime, self-contained, so a Mac
/// without Homebrew's QEMU can start machines, and a guest with the virgl Mesa driver renders on the Mac's GPU.
/// run.sh uses it whenever it is installed; removing it goes back to Homebrew's.
final class RuntimeManager: ScriptDownloader {
    static let shared = RuntimeManager()

    @Published private(set) var revision: String?
    @Published private(set) var present = false

    func refresh(_ settings: AppSettings = .shared) {
        present = settings.runtimePresent
        revision = settings.runtimeRevision
    }

    func download(_ settings: AppSettings = .shared) {
        run("tools/get-qemu-runtime.sh", starting: "Downloading the accelerated QEMU…", settings: settings)
    }

    /// The runtime tarball a release build carries (mac/build-app.sh with MYLINUX_RELEASE=1), and its version.
    static var bundledTarball: URL? {
        guard let url = Paths.bundledRuntime?.appendingPathComponent("qemu-runtime-macos-arm64.tar.gz"),
              FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        return url
    }
    static var bundledVersion: String? {
        guard let url = Paths.bundledRuntime?.appendingPathComponent("tools/qemu-runtime.version") else { return nil }
        return (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// Whether the bundled runtime should be installed: there is one, and nothing at least as new is installed.
    /// Versions read "qemu-runtime-11.1.1-2"; a downloaded runtime newer than the app's stays.
    static func bundledInstallNeeded(installed: String?, bundled: String?, hasTarball: Bool) -> Bool {
        guard hasTarball, let bundled, !bundled.isEmpty else { return false }
        guard let installed, !installed.isEmpty else { return true }
        return runtimeOrder(installed).lexicographicallyPrecedes(runtimeOrder(bundled))
    }
    /// "qemu-runtime-11.1.1-2" -> [11, 1, 1, 2]; anything unparsable sorts lowest.
    static func runtimeOrder(_ v: String) -> [Int] {
        let tail = v.hasPrefix("qemu-runtime-") ? String(v.dropFirst("qemu-runtime-".count)) : v
        return tail.split(whereSeparator: { $0 == "." || $0 == "-" }).map { Int($0) ?? -1 }
    }

    /// Installs the bundled runtime without a download when it is missing or older than the app's. Not in developer
    /// mode: the checkout's out/ is the developer's business (tools/get-qemu-runtime.sh, tools/build-qemu-runtime.sh).
    func installBundledIfNeeded(_ settings: AppSettings = .shared) {
        guard !settings.developerMode, let tarball = Self.bundledTarball,
              Self.bundledInstallNeeded(installed: settings.runtimeRevision, bundled: Self.bundledVersion, hasTarball: true) else { return }
        run("tools/get-qemu-runtime.sh", environment: ["MYLINUX_RUNTIME_FILE": tarball.path], starting: "Installing the app's QEMU…", settings: settings)
    }

    func remove(_ settings: AppSettings = .shared) {
        run("tools/get-qemu-runtime.sh", arguments: ["--remove"], starting: "Removing…", settings: settings)
    }

    override func finished() { refresh() }
}

/// A desktop guest, kept in <out>/<kind>; every machine of that kind has its disk unpacked from it on its first start.
/// Omarchy (tools/get-omarchy.sh): downloaded once (1.4 GB) from the Try Omarchy project's signed release. Arch Linux
/// with Plasma (tools/get-arch.sh): about 2 GB, our build (tools/build-arch-image.sh) from mylinux-releases.
final class DesktopImageManager: ScriptDownloader {
    static let omarchy = DesktopImageManager(.omarchy)
    static let arch = DesktopImageManager(.arch)
    static func shared(_ kind: Profile.Kind) -> DesktopImageManager { kind == .arch ? arch : omarchy }

    let kind: Profile.Kind
    @Published private(set) var revision: String?
    @Published private(set) var present = false

    init(_ kind: Profile.Kind) { self.kind = kind; super.init() }

    /// For the download rows: the size and where it comes from.
    var size: String { kind == .arch ? "about 2 GB" : "1.4 GB" }
    var detail: String {
        kind == .arch ? "about 2 GB, Arch Linux ARM with KDE Plasma, built by myLinux"
                      : "1.4 GB, from the Try Omarchy project's signed release"
    }

    func refresh(_ settings: AppSettings = .shared) {
        present = settings.desktopPresent(kind)
        revision = settings.desktopRevision(kind)
    }

    func download(_ settings: AppSettings = .shared) {
        install("tools/get-\(kind.rawValue).sh", name: kind.title, size: size, installed: present,
                starting: "Downloading \(kind.title) (\(size))…", settings: settings)
    }

    override func finished() { refresh() }
}

/// A server's cloud image and its UEFI firmware: Debian's latest stable image (tools/get-debian.sh, about 300 MB) or
/// Alpine's (tools/get-alpine.sh, about 100 MB), kept in <out>/<distro>; every machine of that kind has its disk
/// copied from it on its first start.
final class ServerImageManager: ScriptDownloader {
    static let debian = ServerImageManager(.debian)
    static let alpine = ServerImageManager(.alpine)
    static func shared(_ kind: Profile.Kind) -> ServerImageManager { kind == .alpine ? alpine : debian }

    let kind: Profile.Kind
    @Published private(set) var revision: String?
    @Published private(set) var present = false

    init(_ kind: Profile.Kind) { self.kind = kind; super.init() }

    /// For the download rows: the size and where it comes from.
    var detail: String {
        kind == .alpine ? "about 100 MB, the latest stable cloud image from alpinelinux.org"
                        : "about 300 MB, the latest stable cloud image from debian.org"
    }

    func refresh(_ settings: AppSettings = .shared) {
        present = settings.serverImagePresent(kind)
        revision = settings.serverRevision(kind)
    }

    func download(_ settings: AppSettings = .shared) {
        install("tools/get-\(kind.rawValue).sh", name: kind.title, size: kind == .alpine ? "about 100 MB" : "about 300 MB", installed: present,
                starting: "Looking up the latest \(kind.title) image…", settings: settings)
    }

    override func finished() { refresh() }
}
