import Foundation

/// Runs one of the checkout's or the bundle's download scripts (tools/get-image.sh, tools/get-qemu-runtime.sh) with
/// MYLINUX_OUT pointing at the right folder, and publishes its last line of output as the progress text.
class ScriptDownloader: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var progress = ""
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
        busy = true; progress = starting; lastError = nil
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = [script.path] + arguments
        proc.currentDirectoryURL = scripts
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Paths.toolPath
        env["MYLINUX_OUT"] = settings.outDir.path
        for (k, v) in extra { env[k] = v }
        proc.environment = env
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
        run("tools/get-image.sh", starting: "Looking up the latest release…", settings: settings)
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

/// The Omarchy guest (tools/get-omarchy.sh): downloaded once (1.4 GB) from the Try Omarchy project's signed release,
/// checked, and kept in <out>/omarchy; every Omarchy machine's disk is unpacked from it on its first start.
final class OmarchyManager: ScriptDownloader {
    static let shared = OmarchyManager()

    @Published private(set) var revision: String?
    @Published private(set) var present = false

    func refresh(_ settings: AppSettings = .shared) {
        present = settings.omarchyPresent
        revision = settings.omarchyRevision
    }

    func download(_ settings: AppSettings = .shared) {
        run("tools/get-omarchy.sh", starting: "Downloading Omarchy (1.4 GB)…", settings: settings)
    }

    override func finished() { refresh() }
}

/// The Debian cloud image and its UEFI firmware (tools/get-debian.sh): the latest stable image from cloud.debian.org
/// (about 300 MB) kept in <out>/debian; every Debian machine's disk is copied from it on its first start.
final class DebianManager: ScriptDownloader {
    static let shared = DebianManager()

    @Published private(set) var revision: String?
    @Published private(set) var present = false

    func refresh(_ settings: AppSettings = .shared) {
        present = settings.debianPresent
        revision = settings.debianRevision
    }

    func download(_ settings: AppSettings = .shared) {
        run("tools/get-debian.sh", starting: "Looking up the latest Debian image…", settings: settings)
    }

    override func finished() { refresh() }
}
