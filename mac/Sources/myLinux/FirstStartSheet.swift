import SwiftUI
import AppKit

/// What the dialog for a new Omarchy or Windows machine holds: the machine's name, its memory, its disk's size and
/// the Mac folder it shares, and the answers to what it would ask a person in its window at its first start
/// (Omarchy's first-start questions, Windows Setup and Windows's first-run screens). The same answers as `mylinux
/// create <kind> --unattended` takes, checked by the same rules.
struct FirstStartForm: Equatable {
    var kind: Profile.Kind
    var name: String
    /// The machine's memory in GB; 0: automatic (it follows this Mac's memory).
    var memoryGB = 0
    var diskGB = 32
    /// The Mac folder shown inside the machine (an Omarchy: Windows reads none); empty: "Mac" in the machine's own folder.
    var share = ""
    /// Answered here, so the machine sets itself up; or asked in the machine's window, as it was before.
    var answered = true
    var user: String
    var password = ""
    var again = ""
    /// Omarchy's name for a keyboard; for Windows a language and region (nb-NO).
    var keyboard: String
    var timezone = TimeZone.current.identifier
    /// Omarchy's host name; empty: made from the machine's name.
    var hostname = ""
    var fullName = ""
    var email = ""
    var edition = WindowsUnattended.Edition.pro
    /// Microsoft's licence terms, which an install that answers itself accepts for the user: theirs to tick.
    var acceptsLicense = false

    /// A form as on this Mac: its user name (when the kind takes it), its keyboard, its time zone. No password.
    static func suggested(_ kind: Profile.Kind, name: String, macUser: String = NSUserName(), macLayout: String? = WindowsUnattended.macLayout()) -> FirstStartForm {
        let disk = ProfileStore.newProfile(named: "x", kind: kind).appsSizeGB          // the kind's own
        if kind == .windows {
            return FirstStartForm(kind: kind, name: name, diskGB: disk, user: WindowsUnattended.problem(user: macUser, password: "") == nil ? macUser : "",
                                  keyboard: WindowsUnattended.keyboard(layout: macLayout) ?? "en-US")
        }
        let a = OmarchyUnattended.suggested(machine: name, macUser: macUser.lowercased(), macLayout: macLayout)
        var probe = a; probe.password = "x"
        return FirstStartForm(kind: kind, name: name, diskGB: disk, user: OmarchyUnattended.problem(probe) == nil ? a.user : "", keyboard: a.keyboard)
    }

    /// The memory sizes on offer (as on a machine's page), and the disk sizes of the kind.
    static var memoryChoices: [Int] { [2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64].filter { $0 <= max(4, Profile.macMemoryGB - 2) } }
    var diskChoices: [Int] {
        let all = kind == .windows ? [32, 64, 128, 256, 512] : [16, 32, 64, 128, 256, 512]
        return all.contains(diskGB) ? all : (all + [diskGB]).sorted()
    }
    var sharesFolder: Bool { kind != .windows }
    /// Why a folder is not one to show inside a machine (run-omarchy.sh refuses the same), or nil.
    static func shareProblem(_ path: String, home: String = NSHomeDirectory(), machines: String = Paths.machines.path) -> String? {
        if path.isEmpty { return nil }
        if path.contains(",") { return "The shared folder's path must not contain a comma." }
        let folder = URL(fileURLWithPath: path).standardizedFileURL.path
        if folder.hasPrefix(machines + "/") { return nil }
        let whole = ["/", "/Users", "/private", "/tmp", "/private/tmp", "/System", "/Library", "/Applications", "/Volumes", home, home + "/Library"]
        if whole.contains(folder) || folder.hasPrefix(home + "/Library/") {
            return "That folder is not one to share: a system folder, the whole home folder or the Library. Pick a folder of your own inside."
        }
        return nil
    }
    /// The machine's own settings into its profile: its name, memory, disk size and shared folder.
    func settings(into p: inout Profile) {
        p.name = machineName
        p.memoryAuto = memoryGB == 0
        p.memoryGB = memoryGB == 0 ? Profile.recommendedMemoryGB(kind) : memoryGB
        p.appsSizeGB = diskGB
        if sharesFolder, !share.isEmpty { p.shareDir = share }
    }

    /// Windows's keyboards on offer: those a Mac layout has a namesake for.
    static let windowsKeyboards = Array(Set(WindowsUnattended.layouts.values)).sorted()
    static let timezones = TimeZone.knownTimeZoneIdentifiers.sorted()

    var machineName: String { name.trimmingCharacters(in: .whitespaces) }
    func omarchy() -> OmarchyUnattended.Answers {
        var a = OmarchyUnattended.Answers(user: user.trimmingCharacters(in: .whitespaces), password: password)
        a.keyboard = keyboard; a.timezone = timezone
        let host = hostname.trimmingCharacters(in: .whitespaces)
        a.hostname = host.isEmpty ? OmarchyUnattended.hostname(machineName) : host
        a.fullName = fullName.trimmingCharacters(in: .whitespaces); a.email = email.trimmingCharacters(in: .whitespaces)
        return a
    }
    func windows() -> WindowsUnattended.Answers {
        var a = WindowsUnattended.Answers(user: user.trimmingCharacters(in: .whitespaces), password: password)
        a.edition = edition; a.keyboard = keyboard; a.computer = WindowsUnattended.computerName(machineName)
        return a
    }

    /// Whether the machine can be made as the form stands: yes, not yet (something is still to fill in), or no.
    enum Verdict: Equatable { case ready, waiting(String), wrong(String) }
    /// `taken`: the other machines' names.
    func verdict(taken: [String]) -> Verdict {
        if machineName.isEmpty { return .waiting("Give the machine a name.") }
        if machineName.count > 60 || machineName.contains("/") || machineName.contains(",") { return .wrong("A name is up to 60 characters, without / or a comma.") }
        if taken.contains(where: { $0.caseInsensitiveCompare(machineName) == .orderedSame }) { return .wrong("A machine named \(machineName) is there already.") }
        var draft = ProfileStore.newProfile(named: machineName, kind: kind)
        settings(into: &draft)
        if let problem = draft.problems.first { return .wrong(problem) }
        if sharesFolder, let problem = Self.shareProblem(share) { return .wrong(problem) }
        guard answered else { return .ready }
        func sentence(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() + (s.hasSuffix(".") ? "" : ".") }
        if user.trimmingCharacters(in: .whitespaces).isEmpty { return .waiting("Name the account.") }
        if kind == .windows {
            if let problem = WindowsUnattended.problem(user: user, password: password) { return .wrong(sentence(problem)) }
        } else {
            if password.isEmpty { return .waiting("Choose a password: Omarchy takes no account without one.") }
            if let problem = OmarchyUnattended.problem(omarchy()) { return .wrong(sentence(problem)) }
        }
        if password != again { return again.isEmpty ? .waiting("Type the password once more.") : .wrong("The two passwords are not the same.") }
        if kind == .windows, !acceptsLicense { return .waiting("Accepting Microsoft's licence terms is yours to do: tick the box, or let Windows Setup ask.") }
        return .ready
    }

    /// Keeps the answers for the machine's first start (or forgets them, when the form says to ask in the window):
    /// nil, or what went wrong.
    func apply(to p: Profile) -> String? {
        guard answered else {
            if kind == .windows { WindowsUnattended.forget(p.machineFolder) } else { OmarchyUnattended.forget(p.machineFolder) }
            return nil
        }
        return kind == .windows ? WindowsUnattended.keep(windows(), machineFolder: p.machineFolder)
                                : OmarchyUnattended.write(omarchy(), machineFolder: p.machineFolder)
    }
}

/// The dialog a new Omarchy or Windows machine is made with in the launcher's window (+, and File › New … Machine…):
/// its name and its first-start answers, so nothing is asked in the machine's window. Also for a machine that is
/// there and has not started yet (made by the Welcome sheet or as a duplicate; "Answer Here…" on its page).
struct FirstStartSheet: View {
    enum Subject: Identifiable {
        /// A machine to make, its settings copied from another of its kind when given.
        case new(Profile.Kind, copying: Profile?)
        /// A machine that has not started yet.
        case existing(Profile)
        var id: String { switch self { case .new(let k, _): return "new-\(k.rawValue)"; case .existing(let p): return p.id.uuidString } }
        var kind: Profile.Kind { switch self { case .new(let k, _): return k; case .existing(let p): return p.kind } }
        var isNew: Bool { if case .new = self { return true }; return false }
    }
    /// The kinds that ask a person something at their first start.
    static func asks(_ kind: Profile.Kind) -> Bool { kind == .omarchy || kind == .windows }

    /// Shows the dialog in the Machines window: the object is a machine's id (a machine that is there), or nothing
    /// (what `waiting` holds).
    static let showNotification = Notification.Name("mylinux.firstStart")
    /// A machine's first-start answers were kept or forgotten (its page says who answers).
    static let changedNotification = Notification.Name("mylinux.firstStartChanged")
    /// The kind a menu command asked a new machine of, until the Machines window shows the dialog.
    @MainActor static var waiting: Profile.Kind?
    /// File › New Omarchy Machine…: the dialog, in the Machines window (brought forward, or opened).
    @MainActor static func ask(_ kind: Profile.Kind) {
        waiting = kind
        StatusMenu.showMachines()
        NotificationCenter.default.post(name: showNotification, object: nil)
    }

    let subject: Subject
    /// Called when the dialog closes: with the machine's id when it was made or its answers changed, nil when cancelled.
    let done: (UUID?) -> Void
    @EnvironmentObject var store: ProfileStore
    @State private var form: FirstStartForm
    @State private var failure: String?

    init(subject: Subject, done: @escaping (UUID?) -> Void) {
        self.subject = subject; self.done = done
        _form = State(initialValue: Self.start(subject))
    }

    /// For --render-first-start: the form the picture is taken of.
    static var renderForm: FirstStartForm?

    /// The form the dialog opens with: as on this Mac; for a machine that is there, its own settings, and the answers
    /// it has already (never the password).
    static func start(_ subject: Subject, store: ProfileStore = .shared) -> FirstStartForm {
        if let renderForm { return renderForm }
        switch subject {
        case .new(let kind, let template):
            var f = FirstStartForm.suggested(kind, name: store.uniqueName(kind.title))
            if let t = template, t.kind == kind { f.memoryGB = t.memoryAuto ? 0 : t.memoryGB; f.diskGB = t.appsSizeGB }      // (store.add copies the same)
            return f
        case .existing(let p):
            var f = FirstStartForm.suggested(p.kind, name: p.name)
            f.memoryGB = p.memoryAuto ? 0 : p.memoryGB; f.diskGB = p.appsSizeGB
            // (the folder a new machine gets, "Mac" beside its disk, is "its own": shown so, and left as it is)
            if p.shareDir != p.machineFolder.appendingPathComponent("Mac").path { f.share = p.shareDir }
            if p.kind == .windows, let a = WindowsUnattended.kept(p.machineFolder) {
                f.user = a.user; f.edition = a.edition; f.keyboard = a.keyboard
            } else if p.kind == .omarchy, let a = OmarchyUnattended.read(p.machineFolder) {
                f.user = a.user; f.keyboard = a.keyboard; f.timezone = a.timezone; f.hostname = a.hostname; f.fullName = a.fullName; f.email = a.email
            }
            return f
        }
    }

    private var isWindows: Bool { subject.kind == .windows }
    /// The machine the dialog is about, when it is there already.
    private var existing: Profile? { if case .existing(let p) = subject { return p }; return nil }
    private var verdict: FirstStartForm.Verdict {
        form.verdict(taken: store.profiles.filter { $0.id != existing?.id }.map(\.name))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center) {
                  VStack(alignment: .leading, spacing: 2) {
                    Text(isWindows ? "Install Windows by itself" : "Set Omarchy up by itself")
                    Text(isWindows ? "Windows Setup and Windows's first-run screens are answered from here. Turned off, they ask in the machine's window."
                                   : "Omarchy's first-start questions are answered from here. Turned off, it asks them in the machine's window.")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                  }
                  Spacer(minLength: 8)
                  Toggle(isWindows ? "Install Windows by itself" : "Set Omarchy up by itself", isOn: $form.answered).labelsHidden().toggleStyle(.switch)
                }
                Divider()
                // two columns: what belongs together shares a row. An answer that is not given (the switch is off) is greyed.
                Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 12) {
                    GridRow {
                        cell("Name") { TextField("", text: $form.name).accessibilityLabel("Name") }
                        cell(isWindows ? "Account name" : "User name") {
                            TextField("", text: $form.user, prompt: Text(isWindows ? "a local administrator" : "small letters, like dhh")).accessibilityLabel(isWindows ? "Account name" : "User name")
                        }
                        .disabled(!form.answered)
                    }
                    GridRow {
                        cell("Password") {
                            SecureField("", text: $form.password, prompt: Text(isWindows ? "none: Windows signs in by itself" : "for signing in and for sudo")).accessibilityLabel("Password")
                        }
                        cell("Password again") { SecureField("", text: $form.again).accessibilityLabel("Password again") }
                    }
                    .disabled(!form.answered)
                    GridRow {
                        cell("Keyboard") { keyboardPicker }
                        if isWindows {
                            cell("Edition") {
                                Picker("Edition", selection: $form.edition) { ForEach(WindowsUnattended.Edition.allCases, id: \.self) { Text($0.title).tag($0) } }.labelsHidden()
                            }
                        } else {
                            cell("Time zone") {
                                Picker("Time zone", selection: $form.timezone) {
                                    ForEach(FirstStartForm.timezones.contains(form.timezone) ? FirstStartForm.timezones : [form.timezone] + FirstStartForm.timezones, id: \.self) { Text($0).tag($0) }
                                }
                                .labelsHidden()
                            }
                        }
                    }
                    .disabled(!form.answered)
                    GridRow {
                        cell("Memory") {
                            Picker("Memory", selection: $form.memoryGB) {
                                Text("Automatic (\(Profile.recommendedMemoryGB(subject.kind)) GB on this Mac)").tag(0)
                                Divider()
                                ForEach(FirstStartForm.memoryChoices.contains(form.memoryGB) || form.memoryGB == 0 ? FirstStartForm.memoryChoices : (FirstStartForm.memoryChoices + [form.memoryGB]).sorted(), id: \.self) { Text("\($0) GB").tag($0) }
                            }
                            .labelsHidden()
                        }
                        cell("Disk size") {
                            Picker("Disk size", selection: $form.diskGB) { ForEach(form.diskChoices, id: \.self) { Text("\($0) GB").tag($0) } }.labelsHidden()
                        }
                    }
                    if isWindows {
                        GridRow {
                            // (the words take the row's width, so this switch stands under the one at the top)
                            HStack(alignment: .center) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("I accept the Microsoft Software License Terms")
                                    if let terms = URL(string: WindowsUnattended.licenseTerms) { Link("Read the terms", destination: terms).font(.caption) }
                                }
                                Spacer(minLength: 8)
                                Toggle("I accept the Microsoft Software License Terms", isOn: $form.acceptsLicense).labelsHidden().toggleStyle(.switch)
                            }
                            .gridCellColumns(2).disabled(!form.answered)
                        }
                    } else {
                        GridRow {
                            cell("Host name") { TextField("", text: $form.hostname, prompt: Text(OmarchyUnattended.hostname(form.machineName))).accessibilityLabel("Host name") }
                                .disabled(!form.answered)
                            cell("Mac folder to share") { sharePicker }
                        }
                        GridRow {
                            cell("Full name") { TextField("", text: $form.fullName, prompt: Text("for git; can be left out")).accessibilityLabel("Full name") }
                            cell("E-mail address") { TextField("", text: $form.email, prompt: Text("for git; can be left out")).accessibilityLabel("E-mail address") }
                        }
                        .disabled(!form.answered)
                    }
                }
                .textFieldStyle(.roundedBorder)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
            .padding(.horizontal, 20)
            Spacer(minLength: 0)
            footer
        }
        // a fixed size: nothing in it comes or goes, a field that does not apply is greyed
        .frame(width: 640, height: isWindows ? 510 : 580)
    }

    /// One field of the grid: its name above it, and the field as wide as its column.
    private func cell<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var keyboardPicker: some View {
        if isWindows {
            // by the language's name ("Norwegian Bokmål (Norway)"), in the order of those names
            let all = FirstStartForm.windowsKeyboards.contains(form.keyboard) ? FirstStartForm.windowsKeyboards : [form.keyboard] + FirstStartForm.windowsKeyboards
            Picker("Keyboard", selection: $form.keyboard) {
                ForEach(all.map { (code: $0, name: Locale.current.localizedString(forIdentifier: $0) ?? $0) }.sorted { $0.name < $1.name }, id: \.code) { Text($0.name).tag($0.code) }
            }
            .labelsHidden()
        } else {
            Picker("Keyboard", selection: $form.keyboard) { ForEach(OmarchyUnattended.layouts.map(\.name), id: \.self) { Text($0).tag($0) } }.labelsHidden()
        }
    }

    /// The Mac folder the machine shows inside (as ~/<its name>): its own "Mac" unless another is chosen.
    private var sharePicker: some View {
        let own = form.share.isEmpty
        let shown = own ? "Mac" : URL(fileURLWithPath: form.share).lastPathComponent
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(own ? "Its own folder, Mac" : (form.share as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1).truncationMode(.middle).help(own ? "A folder named Mac beside the machine's disk" : form.share)
                Spacer(minLength: 4)
                if !own { Button("Its Own") { form.share = "" }.controlSize(.small).help("Back to the folder named Mac beside the machine's disk") }
                Button("Choose…") { chooseShare() }.controlSize(.small)
            }
            Text("shown in Omarchy as ~/\(shown)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
    private func chooseShare() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "The Mac folder that \(form.machineName.isEmpty ? "the machine" : form.machineName) shows inside"
        panel.prompt = "Share"
        if !form.share.isEmpty { panel.directoryURL = URL(fileURLWithPath: form.share) }
        if panel.runModal() == .OK, let url = panel.url { form.share = url.path }
    }

    private var header: some View {
        HStack(spacing: 14) {
            if let icon = WelcomeSheet.icon(isWindows ? "machine-windows" : "omarchy") { Image(nsImage: icon).resizable().frame(width: 48, height: 48) }
            VStack(alignment: .leading, spacing: 3) {
                Text(subject.isNew ? "New \(subject.kind.title) Machine" : "\(existing?.name ?? form.name): its first start").font(.title2.weight(.semibold))
                Text(isWindows ? "Answer here what Windows Setup would ask, and Windows installs itself."
                               : "Answer here what Omarchy would ask, and it starts straight at its desktop.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 14)
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            Group {
                if let failure { Text(failure).foregroundStyle(.red) }
                else {
                    switch verdict {
                    case .ready:
                        Text(!form.answered ? (isWindows ? "Windows Setup asks in the machine's window." : "Omarchy asks in the machine's window.")
                             : isWindows ? "Its first start installs Windows, in 15 to 40 minutes." : "Its first start goes straight to the desktop.")
                            .foregroundStyle(.secondary)
                    case .waiting(let what): Text(what).foregroundStyle(.secondary)
                    case .wrong(let what): Text(what).foregroundStyle(.orange)
                    }
                }
            }
            .font(.callout).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
            Button(subject.isNew ? "Create" : "Save") { confirm() }
                .keyboardShortcut(.defaultAction).disabled(verdict != .ready)
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
    }

    private func confirm() {
        guard verdict == .ready else { return }
        switch subject {
        case .new(let kind, let template):
            var p = store.add(copying: template, kind: kind, named: form.machineName)
            form.settings(into: &p); store.update(p)
            if let problem = form.apply(to: p) { store.remove(p.id, trashFiles: true); failure = problem; return }
            finish(p.id)
        case .existing(let old):
            var p = store.profiles.first { $0.id == old.id } ?? old
            form.settings(into: &p); store.update(p)
            if let problem = form.apply(to: p) { failure = problem; return }
            finish(p.id)
        }
    }
    private func finish(_ id: UUID) {
        NotificationCenter.default.post(name: Self.changedNotification, object: id)
        done(id)
    }
}
