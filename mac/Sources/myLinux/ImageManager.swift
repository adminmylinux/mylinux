import Foundation

/// The kernel + root filesystem pair. Standalone, this downloads a myLinux release into Application Support with
/// tools/get-image.sh (one release resolved, checksummed, previous pair kept). In developer mode the checkout's
/// own out/ is used and building is the checkout's business.
final class ImageManager: ObservableObject {
    static let shared = ImageManager()

    @Published private(set) var busy = false
    @Published private(set) var progress = ""
    @Published private(set) var lastError: String?
    @Published private(set) var revision: String?
    @Published private(set) var present = false

    private var process: Process?

    func refresh(_ settings: AppSettings = .shared) {
        revision = settings.imageRevision
        present = settings.imagePresent
    }

    func download(_ settings: AppSettings = .shared) {
        guard !busy, let scripts = settings.scriptsDir else { return }
        let script = scripts.appendingPathComponent("tools/get-image.sh")
        guard FileManager.default.isReadableFile(atPath: script.path) else {
            lastError = "tools/get-image.sh is missing from the app."; return
        }
        busy = true; progress = "Looking up the latest release…"; lastError = nil
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = [script.path]
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
                self.refresh()
            }
        }
        do { try proc.run(); process = proc } catch {
            busy = false; lastError = "Could not start the download: \(error.localizedDescription)"
        }
    }

    func cancel() {
        process?.terminate()
    }
}
