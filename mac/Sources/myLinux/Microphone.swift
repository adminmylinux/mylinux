import AppKit
import AVFoundation

/// A desktop machine's sound device (run-omarchy.sh: intel-hda with hda-micro) has a microphone, the Mac's. macOS gives
/// the microphone to the app responsible for the process that opens it, and for a machine that is this launcher, whose
/// child QEMU is. Until 0.7.62 the launcher had no NSMicrophoneUsageDescription and never asked, so macOS never did
/// either and a machine recorded silence (voice input in Claude Code inside Omarchy heard nothing). The launcher now
/// asks once, before the first machine with sound starts; the answer is macOS's to keep (System Settings › Privacy &
/// Security › Microphone). A machine that was running when the answer was given hears the microphone after its next start.
enum Microphone {
    enum Access { case allowed, denied, undecided }

    static var access: Access {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .allowed
        case .notDetermined: return .undecided
        default: return .denied
        }
    }

    /// The app can put macOS's question: it is the launcher's bundle (not a test runner, whose own bundle has such a
    /// text too) and its Info.plist has the text macOS shows (asking without it ends the app), and this is not a test
    /// run beside the user's launcher (a scratch MYLINUX_SUPPORT_DIR; MYLINUX_TEST_MIC=1 asks anyway).
    static var canAsk: Bool { canAsk(Bundle.main) }

    static func canAsk(_ bundle: Bundle) -> Bool {
        guard bundle.bundleIdentifier == MachineApp.launcherBundleID,
              bundle.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else { return false }
        let env = ProcessInfo.processInfo.environment
        return env["MYLINUX_SUPPORT_DIR"] == nil || env["MYLINUX_TEST_MIC"] == "1"
    }

    /// Nobody has answered yet, and the question can be put.
    static var shouldAsk: Bool { canAsk && access == .undecided }

    /// macOS's question (it shows it once ever; afterwards this answers at once), then `done` on the main thread.
    static func ask(_ done: @escaping () -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async(execute: done) }
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) }
    }
}
