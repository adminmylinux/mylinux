import SwiftUI
import AppKit

/// The Cloud Folders dialog (CloudFoldersWindow; inside Debian and Alpine also myLinux Apps' Cloud drives): a checkbox
/// for each cloud folder the Mac has. Ticked ones are shared into the machine as ~/<name>,
/// beside ~/Mac; a share is attached when the machine starts, so a change restarts a running machine.
struct CloudTab: View {
    let machineID: UUID
    let machine: String
    let dismiss: () -> Void
    var restarting: () -> Void = {}
    @ObservedObject private var store = ProfileStore.shared
    @State private var picked: Set<String> = []
    @State private var loaded = false
    /// A desktop's dialog stays open after Save: Omarchy's commands are pasted once it is back.
    @State private var savedNow = false
    @State private var copied = false

    private var saved: Profile? { store.profiles.first { $0.id == machineID } }
    private var running: Bool { RunManager.shared.runner(for: machineID).isActive }
    private var changed: Bool { Set(saved?.cloudFolders ?? []) != picked }
    private var kind: Profile.Kind? { saved?.kind }
    private var desktop: Bool { kind.map { !$0.isServer } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your Mac's cloud folders inside \(machine), \(desktop ? "in its home folder" : "beside ~/Mac"). The Mac's own apps keep them in sync, so there is nothing to sign in to inside; what the machine writes there syncs too.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(Array(CloudFolder.allCases.enumerated()), id: \.element) { i, f in
                    if i > 0 { Divider() }
                    row(f)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
            Text(running ? "Folders are attached when the machine starts: saving a change restarts \(machine)\(desktop ? "" : ", and its terminals reconnect")."
                         : "Folders are attached when the machine starts, so a change takes effect at the next Start.")
                .font(.caption).foregroundStyle(.secondary)
            if kind == .omarchy { omarchyCommands }
            if kind == .mylinux {
                Label("myLinux mounts them itself at every start: ~/Dropbox and the others are there, also for the apps.", systemImage: "checkmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !desktop { Spacer(minLength: 0) }
            HStack(spacing: 10) {
                if savedNow { Label("Saved\(running ? "; \(machine) is restarting" : "")", systemImage: "checkmark").font(.callout).foregroundStyle(.secondary) }
                Spacer()
                if desktop && savedNow && !changed {
                    Button("Done", action: dismiss).keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                    Button(running ? "Save and Restart" : "Save") { save() }
                        .keyboardShortcut(.defaultAction).disabled(!changed || saved == nil)
                }
            }
        }
        .frame(height: desktop ? nil : 458)
        .onAppear { if !loaded { picked = Set(saved?.cloudFolders ?? []); loaded = true } }
    }

    /// Omarchy: the launcher has no way in as root, so the mounting is a paste, once, in a terminal inside.
    @ViewBuilder private var omarchyCommands: some View {
        let script = CloudFolder.pasteScript(CloudFolder.allCases.map(\.rawValue).filter { picked.contains($0) })
        VStack(alignment: .leading, spacing: 8) {
            Text("Once, inside \(machine)").font(.headline)
            Text("After the restart, Apps… (⇧⌘A in its window) › Cloud drives mounts it with your password. Or by hand:")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("After saving (and the restart), copy these commands, paste them into a terminal in \(machine) (Super+Return opens one, ⌘Return when Command is Super; Ctrl+Shift+V pastes) and press Return. sudo asks for your \(machine) password. From then on the folders are there at every start; paste again after changing them here.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(script).font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .frame(height: 130)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
            HStack {
                Button { copy(script) } label: { Label(copied ? "Copied" : "Copy Commands", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    .disabled(changed && !picked.isEmpty && saved?.cloudFolders.isEmpty == true)
                Text("The Mac's clipboard is shared with \(machine) when clipboard sharing is on.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text + "\n", forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }

    private func row(_ f: CloudFolder) -> some View {
        let path = f.macPath()
        return HStack(spacing: 12) {
            Toggle(isOn: Binding(get: { picked.contains(f.rawValue) }, set: { on in if on { picked.insert(f.rawValue) } else { picked.remove(f.rawValue) } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(f.title).fontWeight(.semibold)
                    Text(path.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Not on this Mac")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(path == nil && !picked.contains(f.rawValue))
            Spacer()
            Text("~/\(f.guestName)").font(.callout.monospaced()).foregroundStyle(path == nil ? .tertiary : .secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func save() {
        guard var p = saved else { return }
        p.cloudFolders = CloudFolder.allCases.map(\.rawValue).filter { picked.contains($0) }
        store.update(p)
        let r = RunManager.shared.runner(for: machineID)
        if MachineApp.active {
            // in the machine's own app: the launcher saves and restarts; this window shows the seconds
            MachineLink.request(["action": "cloudFolders", "folders": p.cloudFolders, "restart": r.isActive])
            if r.isActive { r.mirrorRestartAsked(); restarting() } else { dismiss() }
            return
        }
        if desktop { if r.isActive { r.restart(p) }; savedNow = true; return }
        if r.isActive { r.restart(p); restarting() } else { dismiss() }
    }
}

/// The Cloud Folders dialog of a desktop machine (Omarchy, myLinux) as a window of its own: from ⇧⌘P or Machine ›
/// Cloud Folders… in the machine's window (the runtime's QEMU asks through MachineLink), or the machine's page. It
/// floats above the machine's window, also in full screen.
enum CloudFoldersWindow {
    private static var open: [UUID: NSWindow] = [:]

    static func show(_ id: UUID) {
        guard let p = ProfileStore.shared.profiles.first(where: { $0.id == id }) else { return }
        NSApp.activate()
        if let w = open[id] { w.makeKeyAndOrderFront(nil); return }
        var window: NSWindow?
        let view = CloudTab(machineID: id, machine: p.name, dismiss: { window?.close() }, restarting: { window?.close() })
            .padding(20).frame(width: 640)
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        window = w
        w.title = "\(p.name): Cloud Folders"
        w.styleMask = [.titled, .closable]
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in open[id] = nil }
        open[id] = w
        w.center()
        w.makeKeyAndOrderFront(nil)
    }
}
