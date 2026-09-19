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

    func run(_ tool: String, arguments: [String] = [], starting: String, settings: AppSettings) {
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

    func remove(_ settings: AppSettings = .shared) {
        run("tools/get-qemu-runtime.sh", arguments: ["--remove"], starting: "Removing…", settings: settings)
    }

    override func finished() { refresh() }
}
