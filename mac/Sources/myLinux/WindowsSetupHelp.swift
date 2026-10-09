import AppKit
import SwiftUI

/// Where a Windows machine's install is, told from the machine's own files: the disk's partition table (Windows Setup
/// has its answers and is copying), what windows/setup.ps1 reports into setup.log ("first-run screens next",
/// "installed"), and a mark the launcher leaves when the first-run screens were reached (setup.log starts empty at
/// every start of the machine, and a machine stopped at those screens comes back at them).
enum WindowsSetupStage: Int, CaseIterable {
    case setup, installing, firstRun, done

    private static func mark(_ p: Profile) -> URL { p.machineFolder.appendingPathComponent("first-run") }

    static func of(_ p: Profile) -> WindowsSetupStage {
        if p.windowsInstalled { return .done }
        // no partition table: Setup has not been told which disk yet (a new disk, or one made again)
        guard let disk = try? FileHandle(forReadingFrom: URL(fileURLWithPath: p.appsDisk)) else { return .setup }
        defer { try? disk.close() }
        guard (try? disk.seek(toOffset: 512)) != nil, (try? disk.read(upToCount: 8)) == Data("EFI PART".utf8) else { return .setup }
        if FileManager.default.fileExists(atPath: mark(p).path) { return .firstRun }
        if let log = try? String(contentsOf: p.machineFolder.appendingPathComponent("setup.log"), encoding: .utf8),
           log.split(whereSeparator: \.isNewline).contains(where: { $0.hasPrefix("mylinux-setup: first-run screens next") }) { return .firstRun }
        return .installing
    }

    /// Keeps what `of` cannot read again after the machine's next start; takes a stale mark away.
    static func remember(_ stage: WindowsSetupStage, for p: Profile) {
        let fm = FileManager.default
        switch stage {
        case .firstRun: if !fm.fileExists(atPath: mark(p).path) { fm.createFile(atPath: mark(p).path, contents: nil) }
        case .setup, .done: try? fm.removeItem(at: mark(p))
        case .installing: break
        }
    }

    var title: String {
        switch self {
        case .setup: return "Answer Windows Setup"
        case .installing: return "Windows installs"
        case .firstRun: return "Windows's first-run screens"
        case .done: return "Start Windows again"
        }
    }
}

@MainActor
final class WindowsSetupModel: ObservableObject {
    let machine: Profile
    @Published private(set) var stage: WindowsSetupStage
    private var timer: Timer?

    init(machine: Profile) {
        self.machine = machine
        stage = WindowsSetupStage.of(machine)
        WindowsSetupStage.remember(stage, for: machine)
    }

    func follow() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
    }

    func refresh() {
        let now = WindowsSetupStage.of(machine)
        WindowsSetupStage.remember(now, for: machine)
        if now != stage { stage = now }
    }

    func stop() { timer?.invalidate(); timer = nil }
}

/// The steps of a Windows install, the one it is at marked. Every step's text is there from the start: the answer
/// nobody guesses ("I don't have internet", where Windows offers "Install driver") can be read before its page comes.
struct WindowsSetupHelpView: View {
    @ObservedObject var model: WindowsSetupModel
    /// One size, set by the window (a window that follows its content's height ended the launcher once: 0.7.61).
    static let size = CGSize(width: 380, height: 620)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                step(.setup) {
                    Text("Language and keyboard, then “I don't have a product key” (or enter yours), an edition, Microsoft's licence terms, and the one empty disk (Disk 0).")
                }
                step(.installing) {
                    Text("Nothing to do for 10 to 40 minutes. It restarts by itself a few times; leave the window open.")
                }
                step(.firstRun) {
                    Text("Region and keyboard, then the page that asks for a network:")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("At “Let's connect you to a network”").font(.callout)
                        Text("choose “I don't have internet”.").font(.callout.weight(.semibold))
                    }
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.16)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.45)))
                    Text("No driver is needed, and “Install driver” is not the way. myLinux installs the network driver by itself when these screens are done, so the network is there on the desktop. With a network here, Windows insists on an account online.")
                    Text("Then your name, a password (or none) and the privacy choices. A Microsoft account can be added later, in Windows's Settings › Accounts.")
                    Text("If “Why did my PC restart?” comes up instead of these screens (a very busy Mac can do that), stop the machine and start it again.")
                }
                step(.done) {
                    Text("Windows is installed. Shut it down (Start › Power › Shut down, or Stop in myLinux Launcher) and start it again: its display then fills the window and follows its size.")
                }
                Divider()
                Label("Too small to read? + and Fill Screen at the top right of Windows's window make it larger while it installs.", systemImage: "plus.magnifyingglass")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    @ViewBuilder private func step<Content: View>(_ s: WindowsSetupStage, @ViewBuilder _ content: () -> Content) -> some View {
        let now = model.stage == s, past = s.rawValue < model.stage.rawValue
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(now ? Color.accentColor : Color.primary.opacity(past ? 0.10 : 0.07))
                if past { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.secondary) }
                else { Text("\(s.rawValue + 1)").font(.callout.weight(.semibold)).foregroundStyle(now ? Color.white : Color.secondary) }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(s.title).font(.headline)
                    if now { Text("now").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor) }
                }
                Group { content() }.font(.callout).foregroundStyle(now ? Color.primary : Color.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .opacity(past ? 0.7 : 1)
    }
}

/// The steps window, beside the machine's window while Windows is being installed in it: opened by the launcher when
/// such a machine runs (without taking the keyboard from it), closed when it stops, and there again from the machine's
/// page (Show the Steps). A panel that does not activate the launcher: the keyboard stays with Windows.
@MainActor
enum WindowsSetupHelp {
    private static var open: [UUID: (NSPanel, WindowsSetupModel)] = [:]
    private static var dismissed: Set<UUID> = []          // closed by the user while its machine runs: not opened again by itself
    private static var waited: [UUID: Int] = [:]          // ticks spent waiting for the machine's window to appear
    private static var running: Set<UUID> = []            // as the last tick saw it

    static func model(for id: UUID) -> WindowsSetupModel? { open[id]?.1 }

    /// RunManager's tick, for every Windows machine: `running` is whether a QEMU has its disk open.
    static func follow(_ p: Profile, running: Bool) {
        guard running else {
            self.running.remove(p.id)
            open[p.id]?.0.close(); dismissed.remove(p.id); waited[p.id] = nil
            return
        }
        self.running.insert(p.id)
        guard open[p.id] == nil, !dismissed.contains(p.id), !p.windowsInstalled else { return }
        // beside the machine's window: wait a few ticks for it to be there (the tools disc and the app come first)
        if MachineWindowPlacement.frame(of: p) == nil, waited[p.id, default: 0] < 4 { waited[p.id, default: 0] += 1; return }
        show(p, byUser: false)
    }

    static func show(_ p: Profile, byUser: Bool) {
        if byUser { dismissed.remove(p.id) }
        if let (w, model) = open[p.id] { model.refresh(); if byUser { w.makeKeyAndOrderFront(nil) } else { w.orderFrontRegardless() }; return }
        let model = WindowsSetupModel(machine: p)
        let hosting = NSHostingController(rootView: WindowsSetupHelpView(model: model))
        hosting.sizingOptions = []
        // (the non-activating style has to be there when the panel is made)
        let w = NSPanel(contentRect: NSRect(origin: .zero, size: WindowsSetupHelpView.size), styleMask: [.titled, .closable, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        w.contentViewController = hosting
        w.setContentSize(WindowsSetupHelpView.size)
        w.title = "\(p.name): Installing Windows"
        w.isFloatingPanel = true; w.level = .floating
        w.hidesOnDeactivate = false; w.becomesKeyOnlyIfNeeded = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated {
                guard let (_, model) = open[p.id] else { return }
                model.stop(); open[p.id] = nil
                // closed while its machine runs: the user's wish for this run (follow() forgets it when the machine stops)
                if running.contains(p.id) { dismissed.insert(p.id) }
            }
        }
        open[p.id] = (w, model)
        place(w, beside: p)
        model.follow()
        if byUser { w.makeKeyAndOrderFront(nil) } else { w.orderFrontRegardless() }
    }

    /// To the right of the machine's window, its top at the window's top; to its left when there is no room; over its
    /// right edge when there is none either. Without the machine's window, where the launcher's other windows go.
    static func place(_ w: NSWindow, beside p: Profile) {
        guard let m = MachineWindowPlacement.frame(of: p),
              let vis = (NSScreen.screens.first { $0.frame.contains(NSPoint(x: m.midX, y: m.midY)) })?.visibleFrame else {
            MachineWindowPlacement.place(w, for: nil); return
        }
        var f = w.frame
        let gap: CGFloat = 12
        if m.maxX + gap + f.width <= vis.maxX { f.origin.x = m.maxX + gap }
        else if m.minX - gap - f.width >= vis.minX { f.origin.x = m.minX - gap - f.width }
        else { f.origin.x = vis.maxX - f.width - gap }
        f.origin.y = min(max(m.maxY - f.height, vis.minY), vis.maxY - f.height)
        w.setFrame(f, display: false)
    }
}
