import Foundation
import Carbon.HIToolbox

/// A Windows install that answers itself: `mylinux create windows --unattended --accept-microsoft-license`. Windows
/// Setup and Windows's first-run screens ask a person for the language and keyboard, the edition, Microsoft's licence
/// terms, the disk, and an account; an answer file can say all of it (windows/autounattend-unattended.xml), and with
/// it a new machine goes from Microsoft's ISO to a desktop without a hand on it.
///
/// The answers come from the command or from the launcher's dialog for a new machine (FirstStartSheet) and are kept
/// in the machine's folder until its first start (`unattended.answers`, for the Mac user alone): the ISO, which may be
/// given later, says which language Windows is in. At that start the launcher fills the file in for the machine
/// (`autounattend.xml`, for the Mac user alone); run-windows.sh puts that one on the machine's tools disc while Windows is not installed. The
/// licence terms are the person's to accept: the file is only made when the command says so in words
/// (`--accept-microsoft-license`), and a coding agent's skill tells it to pass that only when the user has said it.
/// When Windows reports "installed" (setup.ps1, as for any install), the launcher restarts the machine by itself
/// (`follow`): the start Windows was installed in has the installer's hardware. The file, which names the account's
/// password, is removed then, and the tools disc is made again without it at that start.
enum WindowsUnattended {
    /// The edition is chosen by its generic key, as Microsoft publishes them for installing (they do not activate).
    enum Edition: String, CaseIterable, Codable {
        case pro, home
        var key: String { self == .pro ? "VK7JG-NPHTM-C97JM-9MPGT-3V66T" : "YTMG3-N6DKC-DKB77-7M9GH-8HVX7" }
        var title: String { self == .pro ? "Windows 11 Pro" : "Windows 11 Home" }
    }

    struct Answers: Equatable, Codable {
        var user: String
        var password = ""
        var edition = Edition.pro
        /// Windows's language: the ISO's own (Setup has no other).
        var language = "en-US"
        /// The keyboard and the formats, as Windows names a language and region.
        var keyboard = "en-US"
        var computer = "*"
    }

    static let licenseTerms = "https://www.microsoft.com/useterms"
    static func file(_ machineFolder: URL) -> URL { machineFolder.appendingPathComponent("autounattend.xml") }
    /// This machine's install answers itself (and has not finished).
    static func inProgress(_ p: Profile) -> Bool {
        p.kind == .windows && FileManager.default.fileExists(atPath: file(p.machineFolder).path)
    }

    // ---- from the command or the dialog to the first start ----------------------------------------------------------------
    static func pending(_ machineFolder: URL) -> URL { machineFolder.appendingPathComponent("unattended.answers") }
    /// The answers a machine was made with, while it has not started with them.
    static func kept(_ machineFolder: URL) -> Answers? {
        (try? Data(contentsOf: pending(machineFolder))).flatMap { try? JSONDecoder().decode(Answers.self, from: $0) }
    }
    /// Asked to install by itself: waiting for its first start, or installing.
    static func asked(_ p: Profile) -> Bool { p.kind == .windows && !p.windowsInstalled && (inProgress(p) || kept(p.machineFolder) != nil) }
    /// Keeps the answers for the machine's first start, for the Mac user alone: nil, or what went wrong.
    static func keep(_ a: Answers, machineFolder: URL) -> String? {
        guard let data = try? JSONEncoder().encode(a) else { return "could not write the answers" }
        return put(data, at: pending(machineFolder)).map { "could not keep the answers: \($0)" }
    }
    /// The answers are not wanted after all (while the machine has not started with them): Windows Setup asks.
    static func forget(_ machineFolder: URL) {
        try? FileManager.default.removeItem(at: pending(machineFolder))
    }
    /// A start of a machine without Windows in it: answers that were kept become its answer file, in the ISO's
    /// language. nil, or what went wrong (the machine is not started then: it would ask what was answered).
    static func prepare(_ p: Profile, isoLabel: String?, template: String? = template()) -> String? {
        guard p.kind == .windows, var a = kept(p.machineFolder) else { return nil }
        if !p.windowsInstalled {
            a.language = language(isoLabel: isoLabel)
            if let problem = write(a, machineFolder: p.machineFolder, template: template) { return problem }
        }
        forget(p.machineFolder)
        return nil
    }
    /// A file for the Mac user alone, put in place whole: nil, or why not.
    private static func put(_ data: Data, at url: URL) -> String? {
        let fm = FileManager.default, tmp = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".tmp")
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: tmp)
            guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return "\(url.path) cannot be written" }
            try? fm.removeItem(at: url)
            try fm.moveItem(at: tmp, to: url)
            return nil
        } catch { return error.localizedDescription }
    }

    /// What is wrong with an account for Windows, in words; nil when it can be made.
    static func problem(user: String, password: String) -> String? {
        let u = user.trimmingCharacters(in: .whitespaces)
        if u.isEmpty || u.count > 20 { return "the account's name is 1 to 20 characters" }
        if u.contains(where: { "\"/\\[]:;|=,+*?<>@".contains($0) }) || u.hasSuffix(".") || u.unicodeScalars.contains(where: { $0.value < 32 }) {
            return "the account's name cannot have \" / \\ [ ] : ; | = , + * ? < > @ in it, nor end with a dot"
        }
        if ["administrator", "guest", "defaultaccount", "wdagutilityaccount", "system", "none", "defaultuser0"].contains(u.lowercased()) {
            return "\(u) is one of Windows's own account names: pick another"
        }
        if password.count > 127 || password.contains(where: \.isNewline) { return "the password is one line of up to 127 characters" }
        return nil
    }

    /// The language of Microsoft's ISO, from its label (CCCOMA_A64FRE_EN-US_DV9); English (United States) when it says none.
    static func language(isoLabel: String?) -> String {
        guard let label = isoLabel, let r = label.range(of: "_[A-Za-z]{2}-[A-Za-z]{2}_", options: .regularExpression) else { return "en-US" }
        let parts = label[r].dropFirst().dropLast().split(separator: "-")
        return parts[0].lowercased() + "-" + parts[1].uppercased()
    }

    /// The Mac's keyboard layouts that have a Windows one of the same name, as Windows names them.
    static let layouts: [String: String] = [
        "US": "en-US", "ABC": "en-US", "USExtended": "en-US", "USInternational-PC": "en-US", "British": "en-GB", "British-PC": "en-GB",
        "Norwegian": "nb-NO", "NorwegianExtended": "nb-NO", "Swedish": "sv-SE", "Swedish-Pro": "sv-SE", "Danish": "da-DK", "Finnish": "fi-FI",
        "Icelandic": "is-IS", "German": "de-DE", "Austrian": "de-AT", "SwissGerman": "de-CH", "SwissFrench": "fr-CH", "French": "fr-FR",
        "French-numerical": "fr-FR", "Spanish": "es-ES", "Spanish-ISO": "es-ES", "Italian": "it-IT", "Italian-Pro": "it-IT", "Dutch": "nl-NL",
        "Belgian": "nl-BE", "Portuguese": "pt-PT", "Brazilian": "pt-BR", "Brazilian-Pro": "pt-BR", "Polish": "pl-PL", "PolishPro": "pl-PL",
        "Czech": "cs-CZ", "Hungarian": "hu-HU", "Irish": "en-IE", "Canadian": "en-CA", "Canadian-CSA": "fr-CA", "Australian": "en-AU",
    ]
    /// The Mac's keyboard layout now ("com.apple.keylayout.Norwegian").
    static func macLayout() -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
    /// Windows's keyboard for a Mac layout, or nil when it has no namesake (the ISO's language's own is used then).
    static func keyboard(layout: String?) -> String? {
        guard let name = layout?.split(separator: ".").last.map(String.init) else { return nil }
        return layouts[name]
    }
    /// What --keyboard takes: a language and region as Windows writes them (nb-NO, en-US).
    static func isLocale(_ s: String) -> Bool { s.range(of: "^[a-z]{2,3}-[A-Z]{2}$", options: .regularExpression) != nil }

    /// A computer name from the machine's: letters, digits and hyphens, 15 at most; "*" (Windows picks one) otherwise.
    static func computerName(_ machine: String) -> String {
        var s = String(machine.uppercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        while s.contains("--") { s = s.replacingOccurrences(of: "--", with: "-") }
        s = String(s.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(15)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return s.isEmpty || s.allSatisfy(\.isNumber) ? "*" : s
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
    }

    static func render(_ template: String, _ a: Answers) -> String {
        var out = template
        for (word, value) in [("LANGUAGE", a.language), ("KEYBOARD", a.keyboard), ("LOCALE", a.keyboard), ("EDITION_KEY", a.edition.key),
                              ("COMPUTER", a.computer), ("USER", a.user), ("PASSWORD", a.password)] {
            out = out.replacingOccurrences(of: "{{\(word)}}", with: escape(value))
        }
        return out
    }

    /// The template built into the app (Contents/Resources/runtime/windows), or the checkout's when run from a build.
    static func template() -> String? {
        let dirs = [Paths.bundledRuntime?.appendingPathComponent("windows"),
                    Paths.buildRepo.map { URL(fileURLWithPath: $0).appendingPathComponent("windows") }]
        for case let dir? in dirs {
            if let s = try? String(contentsOf: dir.appendingPathComponent("autounattend-unattended.xml"), encoding: .utf8), s.contains("{{USER}}") { return s }
        }
        return nil
    }

    /// The machine's answer file, for the Mac user alone: nil, or what went wrong.
    static func write(_ a: Answers, machineFolder: URL, template: String? = template()) -> String? {
        guard let template else { return "this launcher has no answer file for an unattended Windows install" }
        let text = render(template, a)
        guard !text.contains("{{") else { return "the answer file has a place nothing was filled into" }
        return put(Data(text.utf8), at: file(machineFolder)).map { "could not write the answer file: \($0)" }
    }

    /// When each machine's Windows was first seen installed (the restart comes a little later: its first sign-in is settling).
    @MainActor private static var seenInstalled: [UUID: Date] = [:]
    static let settleSeconds: TimeInterval = 45

    /// RunManager's tick, for a running Windows machine: an install that answered itself ends by itself too. Windows
    /// said "installed" in the start it was installed in, which still has the installer's hardware: it is restarted
    /// once, into the machine it will be from then on.
    @MainActor static func follow(_ p: Profile, runner: Runner, now: Date = Date()) {
        // (also a machine this launcher took over while it installed: the launcher was updated or started again meanwhile)
        guard inProgress(p), runner.state == .running || runner.canStopElsewhere, p.windowsInstalled else { seenInstalled[p.id] = nil; return }
        guard let since = seenInstalled[p.id] else { seenInstalled[p.id] = now; return }
        guard now.timeIntervalSince(since) >= settleSeconds else { return }
        seenInstalled[p.id] = nil
        try? FileManager.default.removeItem(at: file(p.machineFolder))      // its work is done, and it names the account's password
        runner.restart(p)
    }
}
