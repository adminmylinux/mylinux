import AppKit
import ObjectiveC

/// A quit with a sheet open. The application does not quit while a window has a sheet on it, and does not ask the app
/// delegate either: ⌘Q, the Dock's Quit and an update's handover did nothing while the Welcome sheet was up. So its
/// terminate: closes the sheets first (SwiftUI's through their own state, as if dismissed) and quits once they are
/// gone. The application is SwiftUI's own NSApplication subclass, which takes no NSPrincipalClass, so its terminate:
/// is replaced at launch.
enum QuitClosesSheets {
    /// Posted when a quit waits for the sheets: whoever shows one closes it (ContentView: the Welcome sheet and the
    /// new-machine dialog).
    static let closeSheets = Notification.Name("mylinux.closeSheets")
    private typealias Terminate = @convention(c) (NSApplication, Selector, AnyObject?) -> Void

    static func install() {
        guard let app = NSApp, let cls = object_getClass(app) else { return }
        let sel = #selector(NSApplication.terminate(_:))
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: Terminate.self)
        let replacement: @convention(block) (NSApplication, AnyObject?) -> Void = { app, sender in
            guard app.windows.contains(where: { $0.attachedSheet != nil }) else { original(app, sel, sender); return }
            NotificationCenter.default.post(name: closeSheets, object: nil)
            afterSheets(app, tries: 0) { original(app, sel, sender) }
        }
        let imp = imp_implementationWithBlock(replacement)
        // an override on that class alone (or its own replaced): NSApplication itself stays as it is
        if !class_addMethod(cls, sel, imp, method_getTypeEncoding(method)) { method_setImplementation(method, imp) }
    }

    /// Every tenth of a second until no window has a sheet; after half a second the ones nobody closed are ended
    /// here (an AppKit sheet, a SwiftUI one of another window), after two the quit goes on regardless.
    private static func afterSheets(_ app: NSApplication, tries: Int, _ then: @escaping () -> Void) {
        let open = app.windows.compactMap { w in w.attachedSheet.map { (w, $0) } }
        if open.isEmpty || tries >= 20 { then(); return }
        if tries == 5 { for (w, s) in open { w.endSheet(s) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { afterSheets(app, tries: tries + 1, then) }
    }
}
