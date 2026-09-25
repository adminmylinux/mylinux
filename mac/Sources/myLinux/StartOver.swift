import AppKit
import Foundation
import Security

/// Settings › Start over: everything the launcher keeps on this Mac, gone, and a fresh launcher. The same list as the
/// manual reset: the Application Support folder (machines and their disks, downloads, the runtime, profiles),
/// the browser pane's website data, the saved remote passwords, the launcher's defaults and macOS permissions.
enum StartOver {
    /// Returns an error to show, or nil after it has quit to restart.
    static func clearAll() -> String? {
        if !RunManager.shared.active.isEmpty { return "Shut down the running machines first." }
        RemoteWindowController.open.forEach { $0.close() }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let bundleID = Bundle.main.bundleIdentifier ?? "dev.mylinux.launcher"
        var failed: [String] = []
        for url in [Paths.support, home.appendingPathComponent("Library/WebKit/\(bundleID)"),
                    home.appendingPathComponent("Library/Caches/\(bundleID)"),
                    home.appendingPathComponent("Library/HTTPStorages/\(bundleID)"),
                    home.appendingPathComponent("Library/Saved Application State/\(bundleID).savedState")]
        where fm.fileExists(atPath: url.path) {
            do { try fm.removeItem(at: url) } catch { failed.append(url.path) }
        }
        // saved remote passwords
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: RemoteSecrets.service]
        SecItemDelete(q as CFDictionary)
        // permissions macOS granted (Accessibility for the keyboard grab, System Events for window placement)
        let tcc = Process(); tcc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil"); tcc.arguments = ["reset", "All", bundleID]
        tcc.standardOutput = FileHandle.nullDevice; tcc.standardError = FileHandle.nullDevice
        try? tcc.run(); tcc.waitUntilExit()
        if !failed.isEmpty { return "Could not delete: " + failed.joined(separator: ", ") }
        // settings last, then a new launcher once this one has quit
        UserDefaults.standard.removePersistentDomain(forName: bundleID)
        UserDefaults.standard.synchronize()
        let relaunch = Process(); relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", Bundle.main.bundlePath]
        try? relaunch.run()
        NSApp.terminate(nil)
        return nil
    }
}
