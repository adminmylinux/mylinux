import AppKit
import Foundation
import Security

/// Settings › Start over: everything the launcher keeps on this Mac, gone, and a fresh launcher. The same list as the
/// manual reset: the Application Support folder (machines and their disks, downloads, the runtime, profiles),
/// the browser pane's website data, the saved remote passwords, the launcher's defaults and macOS permissions.
enum StartOver {
    /// Returns an error to show, or nil after it has quit to restart. `toTrash` (the command line's `mylinux erase
    /// everything`): the data folder, with the machines and their disks in it, is moved to the Trash and not deleted,
    /// so a word typed to an agent can be taken back; Settings' button, which asks in a dialog, deletes it.
    static func clearAll(toTrash: Bool = false) -> String? {
        if !RunManager.shared.active.isEmpty { return "Shut down the running machines first." }
        RemoteWindowController.open.forEach { $0.close() }
        let bundleID = Bundle.main.bundleIdentifier ?? "dev.mylinux.launcher"
        // a test (a scratch MYLINUX_SUPPORT_DIR) clears its own folder only: never this Mac's saved passwords or permissions
        let test = ProcessInfo.processInfo.environment["MYLINUX_SUPPORT_DIR"] != nil
        if !test {
            // saved remote passwords
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: RemoteSecrets.service]
            SecItemDelete(q as CFDictionary)
            // permissions macOS granted (Accessibility for the keyboard grab, System Events for window placement)
            let tcc = Process(); tcc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil"); tcc.arguments = ["reset", "All", bundleID]
            tcc.standardOutput = FileHandle.nullDevice; tcc.standardError = FileHandle.nullDevice
            try? tcc.run(); tcc.waitUntilExit()
        }
        // the files and the settings go once this launcher has quit: while it quits it still writes (the machine list,
        // the open windows, its window frames), which brought a deleted machine back. The helper is this binary.
        guard let me = Bundle.main.executablePath else { return "The launcher cannot find itself to start over." }
        let helper = Process(); helper.executableURL = URL(fileURLWithPath: me)
        // (a test's launcher is not started again: one opened from here would not have the test's folder, and would be this Mac's own)
        helper.arguments = ["--finish-start-over", String(getpid()), test ? "-" : Bundle.main.bundlePath] + (toTrash ? ["trash"] : [])
        helper.standardOutput = FileHandle.nullDevice; helper.standardError = FileHandle.nullDevice
        do { try helper.run() } catch { return "Could not start over: \(error.localizedDescription)" }
        NSApp.terminate(nil)
        return nil
    }

    /// What is deleted: the data, and what macOS keeps for the app (web views, caches, window state).
    static func paths(home: URL = FileManager.default.homeDirectoryForCurrentUser, bundleID: String) -> [URL] {
        [Paths.support, home.appendingPathComponent("Library/WebKit/\(bundleID)"),
         home.appendingPathComponent("Library/Caches/\(bundleID)"),
         home.appendingPathComponent("Library/HTTPStorages/\(bundleID)"),
         home.appendingPathComponent("Library/Saved Application State/\(bundleID).savedState")]
    }

    /// In the helper: waits (up to a minute) for the launcher `pid` to be gone, deletes, and opens `relaunch`. With
    /// `trash` the data folder goes to the Trash (as "myLinux", its own name there); a folder that cannot be moved
    /// there is left where it is, not deleted.
    static func finish(after pid: pid_t, relaunch: String, trash: Bool = false) -> Int32 {
        let deadline = Date().addingTimeInterval(60)
        while kill(pid, 0) == 0 && Date() < deadline { usleep(200_000) }
        let bundleID = Bundle.main.bundleIdentifier ?? "dev.mylinux.launcher"
        let fm = FileManager.default
        // a test (a scratch MYLINUX_SUPPORT_DIR) clears its own folder only, never this Mac's settings
        let test = ProcessInfo.processInfo.environment["MYLINUX_SUPPORT_DIR"] != nil
        for url in test ? [Paths.support] : paths(bundleID: bundleID) where fm.fileExists(atPath: url.path) {
            do {
                if trash && url == Paths.support { try fm.trashItem(at: url, resultingItemURL: nil) } else { try fm.removeItem(at: url) }
            } catch { NSLog("start over: could not %@ %@: %@", trash ? "move to the Trash" : "delete", url.path, error.localizedDescription) }
        }
        if !test {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
            UserDefaults.standard.synchronize()
        }
        guard relaunch != "-" else { return 0 }
        let open = Process(); open.executableURL = URL(fileURLWithPath: "/usr/bin/open"); open.arguments = ["-n", relaunch]
        try? open.run(); open.waitUntilExit()
        return 0
    }
}
