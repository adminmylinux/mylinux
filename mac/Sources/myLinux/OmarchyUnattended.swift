import Foundation

/// Omarchy's first start without its questions: `mylinux create omarchy --unattended --password PW`. A new Omarchy
/// asks a person, in the machine's window, for the keyboard, an account's name and password, a name and an e-mail
/// address for git, the host name and the time zone, and then whether it all looks right. Omarchy cannot be told the
/// answers beforehand, so they are put into the new disk with a gum that gives them (omarchy/answers,
/// tools/omarchy-bake-answers.sh), and the first start goes to the desktop by itself, in under a minute.
///
/// The launcher keeps the answers in the machine's folder (`first-start.answers`, for the Mac user alone) from the
/// command to the machine's first start; run-omarchy.sh puts them into the disk it makes then and removes the file,
/// and inside Omarchy they are removed when the setup ends. `first-start.unattended`, which names nothing secret,
/// stays until the desktop is seen: `mylinux status` says "ready" then.
enum OmarchyUnattended {
    struct Answers: Equatable {
        var user: String
        var password: String
        /// The keyboard, by the name Omarchy's own list has for it.
        var keyboard = "English (US)"
        var fullName = ""
        var email = ""
        var hostname = "omarchy"
        var timezone = "UTC"
    }

    static func file(_ machineFolder: URL) -> URL { machineFolder.appendingPathComponent("first-start.answers") }
    static func marker(_ machineFolder: URL) -> URL { machineFolder.appendingPathComponent("first-start.unattended") }

    /// Where a machine made with answers is: nothing of it (never, or done), setting itself up, or asking after all
    /// (run-omarchy.sh could not put the answers into the disk, and wrote that into the marker).
    enum Stage { case none, settingUp, asking }
    static func stage(_ p: Profile) -> Stage {
        guard p.kind == .omarchy, let word = try? String(contentsOf: marker(p.machineFolder), encoding: .utf8) else { return .none }
        return word.trimmingCharacters(in: .whitespacesAndNewlines) == "asked" ? .asking : .settingUp
    }

    /// Omarchy's keyboards, as its setup form names them (install/provisioning/setup-form.sh), each with the Mac's
    /// layouts of the same keys and the languages and regions it is the usual keyboard of.
    static let layouts: [(name: String, mac: [String], locales: [String])] = [
        ("English (US)", ["US", "ABC", "USExtended", "USInternational-PC", "Australian", "Canadian"], ["en-US", "en-AU", "en-CA"]),
        ("English (UK)", ["British", "British-PC"], ["en-GB"]),
        ("English (US, Dvorak)", ["Dvorak"], []), ("English (US, Colemak)", ["Colemak"], []),
        ("Azerbaijani", [], ["az-AZ"]), ("Belarusian", ["Byelorussian"], ["be-BY"]), ("Belgian", ["Belgian"], ["nl-BE", "fr-BE"]),
        ("Bulgarian", ["Bulgarian"], ["bg-BG"]), ("Croatian", ["Croatian", "Croatian-PC"], ["hr-HR"]), ("Czech", ["Czech"], ["cs-CZ"]),
        ("Danish", ["Danish"], ["da-DK"]), ("Dutch", ["Dutch"], ["nl-NL"]), ("Estonian", ["Estonian"], ["et-EE"]),
        ("Finnish", ["Finnish", "FinnishExtended"], ["fi-FI"]), ("French", ["French", "French-numerical", "French-PC"], ["fr-FR"]),
        ("French (Canada)", ["Canadian-CSA", "CanadianFrench-PC"], ["fr-CA"]), ("French (Switzerland)", ["SwissFrench"], ["fr-CH"]),
        ("Georgian", ["Georgian-QWERTY"], ["ka-GE"]), ("German", ["German", "Austrian"], ["de-DE", "de-AT"]),
        ("German (Switzerland)", ["SwissGerman"], ["de-CH"]), ("Greek", ["Greek"], ["el-GR"]), ("Hebrew", ["Hebrew", "Hebrew-PC"], ["he-IL"]),
        ("Hungarian", ["Hungarian"], ["hu-HU"]), ("Icelandic", ["Icelandic"], ["is-IS"]), ("Irish", ["Irish"], ["en-IE"]),
        ("Italian", ["Italian", "Italian-Pro"], ["it-IT"]), ("Japanese", [], ["ja-JP"]), ("Kazakh", ["Kazakh"], ["kk-KZ"]),
        ("Kyrgyz", ["Kyrgyz-Cyrillic"], ["ky-KG"]), ("Lao", [], ["lo-LA"]), ("Latvian", ["Latvian"], ["lv-LV"]),
        ("Lithuanian", ["Lithuanian"], ["lt-LT"]), ("Macedonian", ["Macedonian"], ["mk-MK"]),
        ("Norwegian", ["Norwegian", "NorwegianExtended"], ["nb-NO", "nn-NO", "no-NO"]), ("Polish", ["Polish", "PolishPro"], ["pl-PL"]),
        ("Portuguese", ["Portuguese"], ["pt-PT"]), ("Portuguese (Brazil)", ["Brazilian", "Brazilian-Pro", "Brazilian-ABNT2"], ["pt-BR"]),
        ("Romanian", ["Romanian", "Romanian-Standard"], ["ro-RO"]), ("Russian", ["Russian", "RussianWin", "Russian-Phonetic"], ["ru-RU"]),
        ("Serbian", ["Serbian-Latin"], ["sr-RS"]), ("Slovak", ["Slovak", "Slovak-QWERTY"], ["sk-SK"]), ("Slovenian", ["Slovenian"], ["sl-SI"]),
        ("Spanish", ["Spanish", "Spanish-ISO"], ["es-ES"]), ("Spanish (Latin American)", ["LatinAmerican"], ["es-MX", "es-419"]),
        ("Swedish", ["Swedish", "Swedish-Pro"], ["sv-SE"]), ("Tajik", ["Tajik-Cyrillic"], ["tg-TJ"]),
        ("Turkish", ["Turkish-QWERTY", "Turkish-QWERTY-PC"], ["tr-TR"]), ("Ukrainian", ["Ukrainian", "Ukrainian-PC"], ["uk-UA"]),
    ]
    /// What --keyboard takes: Omarchy's name for a keyboard ("Icelandic", "english (uk)"), or a language and region
    /// as the unattended Windows takes them (is-IS, nb-NO). Omarchy's name for it, or nil.
    static func keyboard(_ word: String) -> String? {
        let w = word.trimmingCharacters(in: .whitespaces).lowercased()
        return layouts.first { $0.name.lowercased() == w }?.name ?? layouts.first { $0.locales.contains { $0.lowercased() == w } }?.name
    }
    /// Omarchy's keyboard for a Mac layout ("com.apple.keylayout.Norwegian"), or nil when it has no namesake.
    static func keyboard(layout: String?) -> String? {
        guard let name = layout?.split(separator: ".").last.map(String.init) else { return nil }
        return layouts.first { $0.mac.contains(name) }?.name
    }

    /// Omarchy's own account names (its setup form refuses them).
    static let reserved: Set<String> = ["root", "bin", "daemon", "mail", "ftp", "http", "nobody", "dbus", "systemd-coredump", "systemd-network",
        "systemd-oom", "systemd-journal-remote", "systemd-resolve", "systemd-timesync", "tss", "uuidd", "alpm", "git", "avahi", "cups",
        "cups-browsed", "lp", "_talkd", "polkitd", "rtkit", "qemu", "brltty", "gluster", "rpc", "libvirt-qemu", "pcscd", "nvidia-persistenced", "sddm"]

    private static func matches(_ s: String, _ pattern: String) -> Bool { s.range(of: pattern, options: .regularExpression) != nil }
    private static func oneLine(_ s: String) -> Bool { !s.unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }

    /// What Omarchy would not take of these answers, in words (its form's own rules); nil when it takes them all.
    static func problem(_ a: Answers) -> String? {
        if !matches(a.user, "^[a-z_][a-z0-9_-]*[$]?$") || a.user.count > 32 {
            return "the account's name is small letters, digits, _ and -, starting with a letter (like dhh), 32 at most"
        }
        if reserved.contains(a.user) { return "\(a.user) is one of Omarchy's own account names: pick another" }
        if a.password.isEmpty { return "Omarchy's account needs a password (for signing in and for sudo): --password PW, of the user's choosing" }
        if !oneLine(a.password) || a.password.count > 200 { return "the password is one line of up to 200 characters" }
        if !layouts.contains(where: { $0.name == a.keyboard }) { return "Omarchy has no keyboard called \(a.keyboard)" }
        if !oneLine(a.fullName) || a.fullName.contains(":") || a.fullName.count > 100 { return "the full name is one line of up to 100 characters, without a colon" }
        if !a.email.isEmpty, !matches(a.email, "^[^@\\s]+@[^@\\s]+$") || a.email.count > 254 { return "the e-mail address is name@host" }
        if !matches(a.hostname, "^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$") {
            return "the host name is 1 to 63 letters, digits and hyphens, and does not start or end with a hyphen"
        }
        if TimeZone(identifier: a.timezone) == nil || !matches(a.timezone, "^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$") {
            return "the time zone is a name like Europe/Oslo or UTC"
        }
        return nil
    }

    /// A host name from the machine's name: small letters, digits and hyphens; "omarchy" (Omarchy's own) when nothing is left.
    static func hostname(_ machine: String) -> String {
        var s = String(machine.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        while s.contains("--") { s = s.replacingOccurrences(of: "--", with: "-") }
        s = String(s.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(63)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return s.isEmpty ? "omarchy" : s
    }

    /// The answers as omarchy/answers/gum reads them: a line for each question, the last one the "Does this look right?".
    static func text(_ a: Answers) -> String {
        [("keyboard", a.keyboard), ("username", a.user), ("password", a.password), ("fullname", a.fullName), ("email", a.email),
         ("hostname", a.hostname), ("timezone", a.timezone), ("confirm", "yes")].map { "\($0.0)=\($0.1)\n" }.joined()
    }

    /// The machine's answers, for the Mac user alone, and the word that it sets itself up: nil, or what went wrong.
    static func write(_ a: Answers, machineFolder: URL) -> String? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: machineFolder, withIntermediateDirectories: true)
            let url = file(machineFolder), tmp = machineFolder.appendingPathComponent(".first-start.tmp")
            try? fm.removeItem(at: tmp)
            guard fm.createFile(atPath: tmp.path, contents: Data(text(a).utf8), attributes: [.posixPermissions: 0o600]) else { return "could not write \(url.path)" }
            try? fm.removeItem(at: url)
            try fm.moveItem(at: tmp, to: url)
            try Data().write(to: marker(machineFolder))
            return nil
        } catch { return "could not write the first-start answers: \(error.localizedDescription)" }
    }

    /// The answers kept for the machine's first start, read back (for the machine's page and the dialog), or nil.
    static func read(_ machineFolder: URL) -> Answers? {
        guard let text = try? String(contentsOf: file(machineFolder), encoding: .utf8) else { return nil }
        var said: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            said[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        guard let user = said["username"], let password = said["password"] else { return nil }
        var a = Answers(user: user, password: password)
        a.keyboard = said["keyboard"] ?? a.keyboard; a.fullName = said["fullname"] ?? ""; a.email = said["email"] ?? ""
        a.hostname = said["hostname"] ?? a.hostname; a.timezone = said["timezone"] ?? a.timezone
        return a
    }
    /// The answers are not wanted after all (while the machine has not started with them): Omarchy asks.
    static func forget(_ machineFolder: URL) {
        for url in [file(machineFolder), marker(machineFolder)] { try? FileManager.default.removeItem(at: url) }
    }
    /// What a new machine of that name is given unless something else is said: as on this Mac (its user name when
    /// Omarchy takes it, its keyboard where Omarchy has its namesake, its time zone), and no password.
    static func suggested(machine: String, macUser: String = NSUserName(), macLayout: String? = WindowsUnattended.macLayout(),
                          zone: String = TimeZone.current.identifier) -> Answers {
        var a = Answers(user: macUser, password: "")
        if let layout = keyboard(layout: macLayout) { a.keyboard = layout }
        a.timezone = zone; a.hostname = hostname(machine)
        return a
    }

    /// How long a machine may run without its desktop being seen before the wait for it is given up.
    static let patience: TimeInterval = 600

    /// RunManager's tick, for a running Omarchy: the setup is over when the desktop is there, and the desktop is there
    /// when Omarchy's session tool, which starts with it, has written its status into the share since this start.
    @MainActor static func follow(_ p: Profile, runner: Runner, now: Date = Date()) {
        guard stage(p) != .none, runner.state == .running, let started = runner.startedAt else { return }
        let status = URL(fileURLWithPath: p.shareDir).appendingPathComponent("mylinux-tools/control/status.json")
        let written = p.shareDir.isEmpty ? nil : (try? status.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if written.map({ $0 >= started }) ?? false || now.timeIntervalSince(started) > patience {
            try? FileManager.default.removeItem(at: marker(p.machineFolder))
        }
    }
}
