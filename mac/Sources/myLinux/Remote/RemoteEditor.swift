import SwiftUI
import AppKit

/// A remote machine's settings and its Connect button.
struct RemoteEditor: View {
    @EnvironmentObject var store: RemoteStore
    @State private var draft: RemoteProfile
    @State private var password = ""
    @State private var passwordChanged = false
    @State private var keep = ""

    init(profile: RemoteProfile) {
        _draft = State(initialValue: profile)
        _keep = State(initialValue: profile.keepForMac.joined(separator: ", "))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("Name", text: $draft.name).textFieldStyle(.plain).font(.title2.bold()).frame(maxWidth: 320)
                Text(draft.kind == .ssh ? "SSH" : "VNC").font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(draft.kind == .ssh ? Color.green.opacity(0.25) : Color.blue.opacity(0.25)).clipShape(Capsule())
                Spacer()
                Button { connect() } label: { Label("Connect", systemImage: draft.kind == .ssh ? "terminal" : "display") }
                    .buttonStyle(.borderedProminent).disabled(!draft.problems.isEmpty)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            if let p = draft.problems.first { Banner(text: p, kind: .warning).padding(.horizontal, 20).padding(.bottom, 8) }
            Divider()
            Form {
                Section("Machine") {
                    TextField("Host or address", text: $draft.host)
                    TextField("Port", value: $draft.port, format: .number.grouping(.never))
                    TextField(draft.kind == .ssh ? "Username" : "Username (VeNCrypt servers such as wayvnc; empty for password-only)", text: $draft.username)
                    SecureField(draft.hasPassword ? "Password (saved in the Keychain; type to replace)" : "Password (optional; saved in the Keychain)", text: $password)
                        .onChange(of: password) { _, _ in passwordChanged = true }
                    if draft.kind == .vnc {
                        Picker("Picture quality", selection: $draft.quality) {
                            Text("Fast").tag("fast"); Text("Balanced").tag("balanced"); Text("Best").tag("best")
                        }
                    } else {
                        TextField("Key file (optional, e.g. ~/.ssh/id_ed25519; ~/.ssh and the agent are tried anyway)", text: $draft.keyFile)
                        TextField("tmux session (optional): the shell survives a closed window", text: $draft.tmux)
                    }
                }
                Section("Keyboard") {
                    Picker("Keys", selection: $draft.keyboard) {
                        ForEach(RemoteProfile.Keyboard.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Text(keyboardHelp).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if draft.kind == .vnc {
                        TextField("Shortcuts the Mac keeps in “Everything to the remote” (cmd+c, cmd+v, cmd+q)", text: $keep)
                            .onChange(of: keep) { _, v in draft.keepForMac = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty } }
                        if draft.keyboard == .all && !KeyboardGrab.permitted {
                            HStack {
                                Banner(text: "Grabbing every key needs Accessibility permission for myLinux Launcher.", kind: .warning)
                                Button("Ask now") { KeyboardGrab.askPermission() }.buttonStyle(.link).font(.caption)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onChange(of: draft) { _, new in store.update(new) }
        .onDisappear { savePassword() }
    }

    private var keyboardHelp: String {
        switch draft.keyboard {
        case .mac: return "⌘ combinations stay with macOS; the remote gets the other keys. Option is sent as Alt."
        case .optionSuper: return "The Option key acts as the remote's Super/⌘ key (Option+Space opens an Omarchy launcher); ⌘ stays with the Mac."
        case .all: return "Every key goes to the remote while its window is in front, ⌘Tab and ⌘Space included. Ctrl+Option+G gives the keyboard back; so does switching to another app."
        }
    }

    private func savePassword() {
        guard passwordChanged, !password.isEmpty else { return }
        if RemoteSecrets.setPassword(password, for: draft) { draft.hasPassword = true; store.update(draft) }
        passwordChanged = false
    }

    private func connect() {
        savePassword()
        RemoteWindowController.show(draft)
    }
}
