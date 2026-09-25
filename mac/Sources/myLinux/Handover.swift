import AppKit

/// One launcher at a time. Opening a new launcher while an older one still runs (an update opened from the DMG, or
/// the app replaced under a running copy) used to leave both, each with some machine windows, all named "myLinux
/// Launcher" in ⌘Tab. The new launcher asks the older ones to hand over: they report which machine and remote
/// windows they had open and quit, leaving the machines running; the new one picks the machines up ("started by an
/// earlier launcher") and reopens those windows. Launchers before 0.5.3 do not answer, and are force-quit after a
/// few seconds (their machines are processes of their own and keep running).
enum Handover {
    static let request = Notification.Name("dev.mylinux.launcher.handover")
    static let reply = Notification.Name("dev.mylinux.launcher.handedOver")
    /// Set in the launcher that is handing over: it quits without asking about running machines.
    static var handingOver = false

    /// Launchers are matched by their data folder: a test run with its own MYLINUX_SUPPORT_DIR never touches the
    /// real one. Runs with a command-line mode (the tests' --flags) take no part unless MYLINUX_HANDOVER_TEST=1.
    private static var me: String { "\(ProcessInfo.processInfo.processIdentifier)|\(Paths.support.path)" }
    private static var enabled: Bool {
        ProcessInfo.processInfo.environment["MYLINUX_HANDOVER_TEST"] == "1" || !CommandLine.arguments.dropFirst().contains { $0.hasPrefix("--") }
    }

    /// At launch: listen for later launchers, and ask the earlier ones to hand over.
    static func start() {
        guard enabled else { return }
        let center = DistributedNotificationCenter.default()
        let support = Paths.support.path
        center.addObserver(forName: request, object: nil, queue: .main) { n in
            guard let from = n.object as? String, from != me, from.hasSuffix("|" + support) else { return }
            handOver(to: from)
        }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "dev.mylinux.launcher")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard !others.isEmpty else { return }
        center.addObserver(forName: reply, object: nil, queue: .main) { n in
            guard let to = n.object as? String, to == me else { return }
            reopen((n.userInfo?["windows"] as? [String] ?? []).compactMap(UUID.init(uuidString:)))
        }
        NSLog("handover: asking %d earlier launcher(s) to hand over", others.count)
        center.postNotificationName(request, object: me, userInfo: nil, deliverImmediately: true)
        // an earlier launcher that does not answer (before 0.5.3): force-quit it, but only from a real launch with
        // the real data folder, never from a test run beside the user's launcher
        guard ProcessInfo.processInfo.environment["MYLINUX_SUPPORT_DIR"] == nil, !CommandLine.arguments.dropFirst().contains(where: { $0.hasPrefix("--") }) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            for o in others where !o.isTerminated {
                NSLog("handover: an earlier launcher (pid %d) did not answer; force-quitting it, its machines keep running", o.processIdentifier)
                o.forceTerminate()
            }
        }
    }

    /// In the earlier launcher: tell the new one which windows were open, and quit, machines left running.
    private static func handOver(to newer: String) {
        var ids: [String] = []
        for c in RemoteWindowController.open {
            let id = (c.profile.machineID ?? c.profile.id).uuidString
            if !ids.contains(id) { ids.append(id) }
        }
        NSLog("handover: handing over to %@ with %d window(s)", newer, ids.count)
        handingOver = true
        DistributedNotificationCenter.default().postNotificationName(reply, object: newer, userInfo: ["windows": ids], deliverImmediately: true)
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    /// In the new launcher: the handed-over windows again. A server's terminal waits for the machine to be seen as
    /// running (the 4-second check), then opens as the Terminal button would; a remote connection opens directly.
    private static func reopen(_ ids: [UUID]) {
        NSLog("handover: reopening %d window(s)", ids.count)
        for id in ids {
            if let p = ProfileStore.shared.profiles.first(where: { $0.id == id }), p.isServer {
                let runner = RunManager.shared.runner(for: id)
                var tries = 0
                Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { t in
                    tries += 1
                    if runner.state == .inUseElsewhere || runner.isActive { t.invalidate(); runner.openTerminal(p) }
                    else if tries > 40 { t.invalidate() }
                }
            } else if let r = RemoteStore.shared.profiles.first(where: { $0.id == id }) {
                RemoteWindowController.show(r)
            }
        }
    }
}
