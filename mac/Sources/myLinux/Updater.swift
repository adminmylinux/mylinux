import Foundation
import AppKit
import CryptoKit
import Security

/// Settings › Updates: the launcher updates itself from the public releases. mac/publish-release.sh puts latest.json
/// (version, DMG link, SHA-256, notes) beside the DMG of the release launcher-latest; the update downloads that
/// version's DMG, checks its SHA-256 and that the app inside is signed by the same team as this one, puts it in this
/// app's place and opens it: the new launcher takes over from this one (Handover) and the machines keep running.
/// A launcher built from a checkout (CFBundleVersion 0) is updated with the checkout's own scripts instead.
@MainActor
final class LauncherUpdater: ObservableObject {
    static let shared = LauncherUpdater()

    struct Release: Decodable, Equatable, Sendable {
        let version: String
        let dmg: URL
        let sha256: String
        var notes: String?
        var size: Int?
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(done: Int64, total: Int64)
        case installing
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var checkedAt: Date?
    /// Why the last update did not install (the toolbar says so; Settings › Updates has the words).
    @Published private(set) var failedUpdate: String?
    private var timer: Timer?

    /// In the background: a look shortly after launch and every six hours, for the toolbar's Update button. Not in a
    /// machine's own app, and not for a build from a checkout (it cannot update itself).
    func startChecking() {
        guard timer == nil, !MachineApp.active, !Self.isDevelopmentBuild else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.check() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }

    /// The feed; MYLINUX_UPDATE_FEED (a scratch MYLINUX_SUPPORT_DIR only) points a test at its own.
    static var feed: URL {
        let env = ProcessInfo.processInfo.environment
        if let f = env["MYLINUX_UPDATE_FEED"], env["MYLINUX_SUPPORT_DIR"] != nil { return URL(string: f) ?? URL(fileURLWithPath: f) }
        return URL(string: "https://github.com/adminmylinux/mylinux-releases/releases/download/launcher-latest/latest.json")!
    }

    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
    /// A build from a checkout (mac/build-app.sh without MYLINUX_RELEASE) has CFBundleVersion 0.
    static var isDevelopmentBuild: Bool { (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") == "0" }

    /// "0.7.16" < "0.7.17" < "0.8"; what is not a number sorts lowest, so a development version never looks newer.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            let core = v.split(separator: "-").first.map(String.init) ?? v
            return core.split(separator: ".").map { Int($0) ?? -1 }
        }
        var x = parts(a), y = parts(b)
        while x.count < y.count { x.append(0) }
        while y.count < x.count { y.append(0) }
        return x.lexicographicallyPrecedes(y) == false && x != y
    }

    // ---- check ------------------------------------------------------------------------------------------------------
    func check() {
        if case .downloading = state { return }
        if state == .installing || state == .checking { return }
        state = .checking
        Task {
            do {
                let (data, response) = try await Self.session.data(from: Self.feed)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw Problem("the update feed answered \(http.statusCode)") }
                let release = try JSONDecoder().decode(Release.self, from: data)
                checkedAt = Date()
                state = Self.isNewer(release.version, than: Self.currentVersion) ? .available(release) : .upToDate
            } catch {
                state = .failed("Could not check for updates: \(Self.describe(error))")
            }
        }
    }

    // ---- update -----------------------------------------------------------------------------------------------------
    func update(to release: Release) {
        guard case .available = state else { return }
        if let why = Self.cannotReplace() { state = .failed(why); return }
        failedUpdate = nil
        state = .downloading(done: 0, total: Int64(release.size ?? 0))
        Task {
            do {
                let dmg = try await download(release)
                state = .installing
                let target = Bundle.main.bundleURL
                try await Task.detached(priority: .userInitiated) { try Self.install(dmg: dmg, over: target) }.value
                Self.relaunch(target)
            } catch {
                let why = "The update did not install: \(Self.describe(error)) This launcher stays as it was."
                failedUpdate = why
                state = .failed(why)
            }
        }
    }

    /// Why this copy cannot be replaced, or nil.
    static func cannotReplace() -> String? {
        if isDevelopmentBuild { return "This launcher was built from a checkout: update it there (git pull, mac/build-app.sh)." }
        let path = Bundle.main.bundlePath
        if path.hasPrefix("/Volumes/") { return "Move myLinux Launcher to the Applications folder first, then update." }
        if path.contains("/AppTranslocation/") {
            // macOS runs a downloaded app from a temporary copy until Finder has moved it: an app copied into
            // Applications by a tool (cp, ditto) stays that way, and a temporary copy cannot be replaced
            return "macOS is running myLinux Launcher from a temporary copy, because it was not put into the Applications folder with Finder. Quit it, drag it out of Applications and back in with Finder (or drag it there again from the DMG), start it, then update."
        }
        if !FileManager.default.isWritableFile(atPath: (path as NSString).deletingLastPathComponent) {
            return "This Mac's user cannot write to \((path as NSString).deletingLastPathComponent); update with the DMG from mylinux.app instead."
        }
        return nil
    }

    private func download(_ release: Release) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mylinux-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("myLinux-Launcher.dmg")
        if release.dmg.isFileURL {
            try FileManager.default.copyItem(at: release.dmg, to: dest)
        } else {
            let progress = DownloadProgress { [weak self] done, total in
                Task { @MainActor in if case .downloading = self?.state { self?.state = .downloading(done: done, total: total) } }
            }
            let (file, response) = try await Self.session.download(from: release.dmg, delegate: progress)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw Problem("the download answered \(http.statusCode)") }
            try FileManager.default.moveItem(at: file, to: dest)
        }
        let digest = try await Task.detached { try Self.sha256(of: dest) }.value
        guard digest == release.sha256.lowercased() else { throw Problem("the download does not match its SHA-256.") }
        return dest
    }

    /// Bytes written so far, for the progress line.
    private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let report: (Int64, Int64) -> Void
        private var last = Date.distantPast
        init(_ report: @escaping (Int64, Int64) -> Void) { self.report = report }
        func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard Date().timeIntervalSince(last) > 0.2 else { return }
            last = Date(); report(totalBytesWritten, totalBytesExpectedToWrite)
        }
        func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Mounts the DMG, checks the app in it, and puts it in `target`'s place (the old one goes to the Trash).
    nonisolated static func install(dmg: URL, over target: URL) throws {
        let mount = dmg.deletingLastPathComponent().appendingPathComponent("mnt", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        guard run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path]) == 0 else {
            throw Problem("the DMG would not open.")
        }
        defer { _ = run("/usr/bin/hdiutil", ["detach", "-quiet", mount.path]) }
        let app = mount.appendingPathComponent("myLinux Launcher.app")
        guard FileManager.default.fileExists(atPath: app.path) else { throw Problem("the DMG has no myLinux Launcher.app.") }
        try checkSignature(app)
        // copied beside the old one first (same volume), then swapped in: a failed copy leaves the old one whole
        let staged = target.deletingLastPathComponent().appendingPathComponent(".myLinux Launcher.update.app")
        try? FileManager.default.removeItem(at: staged)
        guard run("/usr/bin/ditto", [app.path, staged.path]) == 0 else { throw Problem("the new app could not be copied next to this one.") }
        do {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: staged, backupItemName: nil, options: [])
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        try? FileManager.default.removeItem(at: dmg.deletingLastPathComponent())
    }

    /// The new app must be validly signed, deeply, by the team that signed this one.
    nonisolated static func checkSignature(_ app: URL) throws {
        guard let team = ownTeam() else { throw Problem("this launcher has no team signature to compare with.") }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { throw Problem("the new app's signature could not be read.") }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { throw Problem("the signature check could not be set up.") }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(code, flags, requirement)
        guard status == errSecSuccess else { throw Problem("the new app is not signed by myLinux's developer (\(status)).") }
    }

    nonisolated static func ownTeam() -> String? {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// The new launcher, as a second instance: it asks this one to hand over (Handover), which quits it.
    static func relaunch(_ app: URL) {
        var args = ["-n", app.path]
        if let support = ProcessInfo.processInfo.environment["MYLINUX_SUPPORT_DIR"] { args = ["-n", "--env", "MYLINUX_SUPPORT_DIR=\(support)", app.path] }
        _ = run("/usr/bin/open", args)
    }

    // ---- helpers ------------------------------------------------------------------------------------------------------
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    struct Problem: LocalizedError { let text: String; init(_ t: String) { text = t }; var errorDescription: String? { text } }

    static func describe(_ error: Error) -> String {
        if let p = error as? Problem { return p.text }
        return error.localizedDescription.hasSuffix(".") ? error.localizedDescription : error.localizedDescription + "."
    }

    @discardableResult nonisolated static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
