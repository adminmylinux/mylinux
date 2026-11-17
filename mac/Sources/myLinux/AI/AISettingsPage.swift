import SwiftUI

/// Settings › AI: which of the person's own AIs Ask AI… uses (Claude Code or Codex, signed in on this Mac), its model,
/// and the defaults a new machine gets when the request does not say.
struct AISettingsPage: View {
    @AppStorage("ai.provider") private var provider = AI.Provider.claude.rawValue
    @AppStorage("ai.claudeModel") private var claudeModel = "sonnet"
    @AppStorage("ai.codexModel") private var codexModel = ""
    @State private var states: [String: (ok: Bool, text: String)] = [:]

    var body: some View {
        PageHeader(title: "AI", subtitle: "Ask AI… (⌘J) does what you tell it with the launcher, through your own Claude Code or Codex.")
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("", selection: $provider) {
                    ForEach(AI.Provider.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                ForEach(AI.Provider.allCases) { p in
                    HStack(spacing: 6) {
                        if let s = states[p.rawValue] {
                            Image(systemName: s.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(s.ok ? .green : .orange)
                            Text("\(p.label): \(s.text)").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        } else {
                            ProgressView().controlSize(.small); Text(p.label).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                if provider == AI.Provider.claude.rawValue {
                    Picker("Model", selection: $claudeModel) {
                        Text("Sonnet").tag("sonnet"); Text("Opus").tag("opus"); Text("Haiku").tag("haiku")
                    }.frame(width: 260)
                } else {
                    HStack {
                        Text("Model")
                        TextField("Codex's own default", text: $codexModel).textFieldStyle(.roundedBorder).frame(width: 200)
                    }
                }
            }
        }
        .task {
            for p in AI.Provider.allCases { let s = await AI.check(p); states[p.rawValue] = s }
        }
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Defaults for a new machine").fontWeight(.semibold)
                Text("What a new Omarchy (or an unattended Windows) gets when your request does not say: “create omarchy 8/32 with username viktor and the rest as default”. Empty fields are as on this Mac. The password is kept in the Keychain and never goes to the AI.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                DefaultsForm()
            }
        }
        DisclosureGroup("Details") {
            Text("The AI turns what you ask into the launcher's own commands, those the mylinux command takes (create, start, stop, restart, delete, and Claude Code or Codex inside a machine), and Ask AI shows them before anything runs. It runs from an empty folder with its tools, settings and saved sessions off, so it only reads the request, the machines' names and states, and which defaults are stored. Erasing, a machine's shell and the agents' skill are left to you.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
        }
    }
}
