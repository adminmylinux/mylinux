import XCTest
@testable import myLinux

final class ProfileTests: XCTestCase {
    private func profile() -> Profile {
        Profile(name: "Work", appsDisk: "/tmp/x/apps.img", shareDir: "/tmp/x/share")
    }

    func testEnvironmentMapsOntoRunSh() {
        var p = profile()
        p.grab = "full"; p.mouse = "relative"; p.clipboard = false; p.memoryGB = 12; p.appsSizeGB = 32
        let env = p.environment(outDir: URL(fileURLWithPath: "/data"), serialSocket: "/tmp/s.sock")
        XCTAssertEqual(env["MYLINUX_OUT"], "/data")
        XCTAssertEqual(env["APPS_IMG"], "/tmp/x/apps.img")
        XCTAssertEqual(env["SHARE_DIR"], "/tmp/x/share")
        XCTAssertEqual(env["GRAB"], "full")
        XCTAssertEqual(env["MOUSE"], "relative")
        XCTAssertEqual(env["CLIPBOARD"], "0")
        XCTAssertEqual(env["MEM"], "12G")
        XCTAssertEqual(env["APPS_SIZE_GB"], "32")
        XCTAssertEqual(env["NAME"], "myLinux (Work)")
        XCTAssertEqual(env["SERIAL"], "unix:/tmp/s.sock,server,nowait")
        XCTAssertNil(env["RES"], "an empty resolution must let run.sh fit the screen")
    }

    func testFixedResolutionIsPassedLowercase() {
        var p = profile(); p.resolution = "1920X1200"
        XCTAssertEqual(p.environment(outDir: URL(fileURLWithPath: "/d"), serialSocket: "/tmp/s")["RES"], "1920x1200")
    }

    func testTheFirstMachineKeepsThePlainWindowName() {
        var p = profile(); p.name = "myLinux"
        XCTAssertEqual(p.windowName, "myLinux")
    }

    func testProblemsCatchWhatRunShWouldRefuse() {
        var p = profile()
        XCTAssertTrue(p.problems.isEmpty)
        p.resolution = "wide"; XCTAssertFalse(p.problems.isEmpty)
        p.resolution = "400x300"; XCTAssertFalse(p.problems.isEmpty, "below run.sh's minimum")
        p.resolution = "1600x1000"; XCTAssertTrue(p.problems.isEmpty)
        p.appsSizeGB = 1; XCTAssertFalse(p.problems.isEmpty)
        p.appsSizeGB = 16; p.name = "  "; XCTAssertFalse(p.problems.isEmpty)
    }

    func testDecodingToleratesMissingFields() throws {
        let json = #"[{"id":"3E5B5E7E-0C3E-4E2E-9B7B-0F1E2D3C4B5A","name":"Old","appsDisk":"/d/a.img","shareDir":"/d/s"}]"#
        let list = try JSONDecoder().decode([Profile].self, from: Data(json.utf8))
        XCTAssertEqual(list.first?.grab, "opt")
        XCTAssertEqual(list.first?.memoryGB, 6)
        XCTAssertTrue(list.first?.clipboard == true)
    }
}

final class AutomaticMemoryTests: XCTestCase {
    func testSizesFollowTheMac() {
        XCTAssertEqual([8, 16, 24, 36].map { Profile.recommendedMemoryGB(.mylinux, macGB: $0) }, [3, 4, 6, 6])
        XCTAssertEqual([8, 16, 24, 36].map { Profile.recommendedMemoryGB(.omarchy, macGB: $0) }, [4, 6, 8, 8])
        XCTAssertEqual([8, 16, 24, 36].map { Profile.recommendedMemoryGB(.debian, macGB: $0) }, [2, 2, 4, 4])
    }
    func testNewMachinesAreAutomatic() {
        for kind in [Profile.Kind.mylinux, .omarchy, .debian] {
            let p = ProfileStore.newProfile(named: "M", kind: kind, folder: URL(fileURLWithPath: "/m/x"))
            XCTAssertTrue(p.memoryAuto); XCTAssertEqual(p.memoryGB, Profile.recommendedMemoryGB(kind))
        }
    }
    func testSavedMachinesAtTheOldDefaultBecomeAutomaticOthersKeepTheirs() throws {
        func decode(_ kind: String, _ gb: Int) throws -> Profile {
            try JSONDecoder().decode(Profile.self, from: Data(#"{"kind":"\#(kind)","name":"M","appsDisk":"/d/a","shareDir":"","memoryGB":\#(gb)}"#.utf8))
        }
        XCTAssertTrue(try decode("omarchy", 8).memoryAuto)
        XCTAssertTrue(try decode("debian", 2).memoryAuto)
        XCTAssertTrue(try decode("mylinux", 6).memoryAuto)
        XCTAssertFalse(try decode("omarchy", 12).memoryAuto, "a size someone chose stays")
        XCTAssertFalse(try decode("debian", 4).memoryAuto)
        var chosen = try decode("omarchy", 12)
        XCTAssertFalse(chosen.applyAutomaticMemory(macGB: 8)); XCTAssertEqual(chosen.memoryGB, 12)
        var auto = try decode("omarchy", 8)
        XCTAssertTrue(auto.applyAutomaticMemory(macGB: 8)); XCTAssertEqual(auto.memoryGB, 4)
    }
    func testTheStoreSizesAutomaticMachinesAtStart() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mylinux-memory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("profiles.json")
        let json = #"[{"kind":"omarchy","name":"O","appsDisk":"/d/o","shareDir":"","memoryGB":8},{"kind":"debian","name":"D","appsDisk":"/d/d","shareDir":"","memoryGB":16,"sshPort":2223}]"#
        try Data(json.utf8).write(to: file)
        let store = ProfileStore(file: file)
        XCTAssertEqual(store.profiles[0].memoryGB, Profile.recommendedMemoryGB(.omarchy))
        XCTAssertEqual(store.profiles[1].memoryGB, 16, "chosen by hand: kept")
        let saved = try JSONDecoder().decode([Profile].self, from: Data(contentsOf: file))
        XCTAssertEqual(saved.map(\.memoryAuto), [true, false], "the choice is saved, so it survives a change of Mac")
    }
}

final class OmarchyClipboardTests: XCTestCase {
    typealias C = OmarchyClipboard
    func testSyncIsEchoSafeBothWays() {
        var sent: [[String: String]] = [], copied: [(String, Data)] = []
        var now = 100.0
        let s = C.Sync(send: { sent.append(try! JSONSerialization.jsonObject(with: $0) as! [String: String]) },
                       copy: { copied.append(($0, $1)) }, clock: { now })
        XCTAssertTrue(s.macChanged(C.text, Data("hello".utf8)))
        XCTAssertEqual(sent.last, ["type": "clipboard", "format": C.text, "data": Data("hello".utf8).base64EncodedString()])
        XCTAssertFalse(s.guestChanged(C.text, Data("hello".utf8)), "the guest re-announcing what it was given is an echo")
        XCTAssertTrue(s.guestChanged(C.text, Data("from omarchy".utf8)))
        XCTAssertEqual(copied.last?.1, Data("from omarchy".utf8))
        XCTAssertFalse(s.macChanged(C.text, Data("from omarchy".utf8)), "the Mac re-announcing what it was given is an echo")
        now += 3
        XCTAssertTrue(s.macChanged(C.text, Data("from omarchy".utf8)), "the same text copied again later is a real change")
        XCTAssertTrue(s.guestChanged(C.png, Data([0x89, 0x50, 0x4e, 0x47])))
        XCTAssertEqual(copied.last?.0, C.png)
        XCTAssertTrue(s.syncRequested())
        XCTAssertEqual(sent.last?["format"], C.text, "sync answers with what the Mac holds")
    }
    func testDecode() {
        XCTAssertEqual(C.decode(Data(#"{"type":"sync"}"#.utf8)), .sync)
        let line = C.encode(C.png, Data([0x89, 0x50]))
        XCTAssertEqual(C.decode(line.dropLast()), .clipboard(C.png, Data([0x89, 0x50])))
        XCTAssertNil(C.decode(Data(#"{"type":"clipboard","format":"text/html","data":"aGk="}"#.utf8)), "unknown formats are ignored")
        XCTAssertNil(C.decode(Data(#"{"type":"clipboard","format":"text/plain;charset=utf-8","data":"/w=="}"#.utf8)), "invalid UTF-8 text is ignored")
        XCTAssertNil(C.decode(Data("not json".utf8)))
    }
    func testNewOmarchyMachinesGiveOmarchyEveryKey() {
        let p = ProfileStore.newProfile(named: "Omarchy", kind: .omarchy, folder: URL(fileURLWithPath: "/m/o"))
        XCTAssertEqual(p.grab, "full")
        XCTAssertEqual(p.environment(outDir: URL(fileURLWithPath: "/o"), serialSocket: "/tmp/s")["GRAB"], "full")
    }
}

final class WelcomeClockTests: XCTestCase {
    func testPercentComesFromCurlsProgressLine() {
        XCTAssertEqual(WelcomeSheet.percent(in: "######### 65.7%"), 0.657, accuracy: 0.0001)
        XCTAssertEqual(WelcomeSheet.percent(in: "#### 12.0%#### 13.5%"), 0.135, accuracy: 0.0001, "the last value wins")
        XCTAssertEqual(WelcomeSheet.percent(in: "checking the download ..."), 0)
    }
    func testClockAndEstimate() {
        XCTAssertEqual(WelcomeSheet.clockText(245), "4:05")
        XCTAssertEqual(WelcomeSheet.clockText(3723), "1:02:03")
        XCTAssertNil(WelcomeSheet.remaining(elapsed: 30, fraction: 0.01), "too early to judge")
        XCTAssertEqual(WelcomeSheet.remaining(elapsed: 60, fraction: 0.25), "about 3 min left")
        XCTAssertEqual(WelcomeSheet.remaining(elapsed: 50, fraction: 0.9), "under a minute left")
    }
}

final class TerminalURLTests: XCTestCase {
    func testLastURLWinsAndTrailingPunctuationGoes() {
        let text = "see https://a.example/one and then (https://b.example/two)."
        XCTAssertEqual(SshTerminal.lastURL(in: text, cols: 80)?.absoluteString, "https://b.example/two")
    }
    func testAURLWrappedAtTheTerminalWidthIsJoined() {
        let cols = 20
        let line1 = "https://claude.ai/oa"      // exactly cols wide: the terminal wrapped here
        let line2 = "uth?code=abc"
        XCTAssertEqual(line1.count, cols)
        XCTAssertEqual(SshTerminal.lastURL(in: "Open:\n\(line1)\n\(line2)\n", cols: cols)?.absoluteString, "https://claude.ai/oauth?code=abc")
    }
    func testAShortLineIsNotJoined() {
        XCTAssertEqual(SshTerminal.lastURL(in: "https://a.example/x\nnot part of it", cols: 80)?.absoluteString, "https://a.example/x")
        XCTAssertNil(SshTerminal.lastURL(in: "no links here", cols: 80))
    }
}

final class KnownHostsTests: XCTestCase {
    func testTheOptionQuotesThePath() {
        XCTAssertEqual(RemoteProfile.knownHostsOption("/Users/a/Library/Application Support/myLinux/m/known_hosts"),
                       "UserKnownHostsFile=\"/Users/a/Library/Application Support/myLinux/m/known_hosts\"")
        let p = ProfileStore.newProfile(named: "Debian", kind: .debian, folder: URL(fileURLWithPath: "/Users/a/Library/Application Support/myLinux/machines/d"))
        XCTAssertEqual(p.terminalProfile.sshOptions.first, "UserKnownHostsFile=\"/Users/a/Library/Application Support/myLinux/machines/d/known_hosts\"")
    }
    func testTheStrayFileGoesOnlyWhenItHoldsOurKeys() throws {
        let lib = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: lib) }
        let stray = lib.appendingPathComponent("Application")
        try "[127.0.0.1]:2223 ssh-ed25519 AAAAC3Nz\n[127.0.0.1]:2224 ecdsa-sha2-nistp256 AAAAE2V\n".write(to: stray, atomically: true, encoding: .utf8)
        XCTAssertTrue(RemoteProfile.removeStrayKnownHosts(library: lib))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
        try "[127.0.0.1]:2223 ssh-ed25519 AAAAC3Nz\nsomething else\n".write(to: stray, atomically: true, encoding: .utf8)
        XCTAssertFalse(RemoteProfile.removeStrayKnownHosts(library: lib), "anything else in it: left alone")
        try FileManager.default.removeItem(at: stray); try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: false)
        XCTAssertFalse(RemoteProfile.removeStrayKnownHosts(library: lib), "a folder: left alone")
    }
}

final class InstallScriptTests: XCTestCase {
    let sample = """
    #!/bin/bash
    CLAUDE=1      # option: Claude Code
    CODEX=0 # option:Codex
    BTOP=1        # option:
    CLAUDE=0      # option: a second line with the same name is not another box
    OTHER=1       # just a comment
    set -e
    """

    func testOptionsComeFromMarkedLines() {
        let o = InstallScript.options(in: sample)
        XCTAssertEqual(o.map(\.name), ["CLAUDE", "CODEX", "BTOP"])
        XCTAssertEqual(o.map(\.label), ["Claude Code", "Codex", "BTOP"], "an empty label falls back to the name")
        XCTAssertEqual(o.map(\.on), [true, false, true])
    }
    func testSettingRewritesOnlyThatLine() {
        let off = InstallScript.setting("CLAUDE", to: false, in: sample)
        XCTAssertTrue(off.contains("CLAUDE=0      # option: Claude Code\nCODEX=0"))
        XCTAssertEqual(off.replacingOccurrences(of: "CLAUDE=0      # option: Claude Code", with: "CLAUDE=1      # option: Claude Code"), sample)
        XCTAssertEqual(InstallScript.options(in: InstallScript.setting("CODEX", to: true, in: sample)).map(\.on), [true, true, true])
        XCTAssertEqual(InstallScript.setting("NOPE", to: true, in: sample), sample)
    }
    func testTheRepositoryScript() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../debian_install.sh").standardized
        let s = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(InstallScript.plausible(s))
        XCTAssertEqual(InstallScript.options(in: s).map(\.label), ["Claude Code", "Codex", "btop", "Bun", "Tailscale"])
        XCTAssertTrue(InstallScript.options(in: s).allSatisfy(\.on), "everything is on by default")
        XCTAssertFalse(InstallScript.plausible("<html>404</html>"))
        XCTAssertEqual(InstallScript.command(file: "debian_install.sh", script: s), " bash ~/.local/share/mylinux/debian_install.sh; command -v bash >/dev/null && exec bash -l\n")
    }
    func testAlpinesScriptRunsWithShAndLeavesBash() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../alpine_install.sh").standardized
        let s = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(s.hasPrefix("#!/bin/sh\n"), "Alpine has no bash until the script installs it")
        XCTAssertEqual(InstallScript.options(in: s).map(\.label), ["Claude Code", "Codex", "btop", "Bun", "Tailscale"])
        XCTAssertEqual(InstallScript.command(file: "alpine_install.sh", script: s), " sh ~/.local/share/mylinux/alpine_install.sh; command -v bash >/dev/null && exec bash -l\n")
        XCTAssertEqual(InstallScript.url("alpine_install.sh").absoluteString, "https://raw.githubusercontent.com/adminmylinux/mylinux/main/alpine_install.sh")
    }
}

final class DebianProfileTests: XCTestCase {
    func testEnvironmentMapsOntoRunDebianSh() {
        var p = ProfileStore.newProfile(named: "Build box", kind: .debian, folder: URL(fileURLWithPath: "/m/build-box"))
        p.memoryGB = 8; p.cpus = 4; p.appsSizeGB = 64; p.sshPort = 2300
        let env = p.environment(outDir: URL(fileURLWithPath: "/o"), serialSocket: "/tmp/s.sock", qmpSocket: "/tmp/q.sock")
        XCTAssertEqual(p.script, "run-debian.sh")
        XCTAssertEqual(env["DISK"], "/m/build-box/debian.raw")
        XCTAssertEqual(env["DISK_SIZE_GB"], "64"); XCTAssertEqual(env["MEM"], "8G"); XCTAssertEqual(env["CPUS"], "4")
        XCTAssertEqual(env["SSH_PORT"], "2300"); XCTAssertEqual(env["NAME"], "Build box")
        XCTAssertEqual(env["SHARE_DIR"], "/m/build-box/Mac"); XCTAssertEqual(env["QMP"], "/tmp/q.sock")
        XCTAssertNil(env["GRAB"], "a server has no window and no key grab"); XCTAssertNil(env["RES"])
        XCTAssertEqual(p.machineFolder.path, "/m/build-box")
    }
    func testProblemsMatchTheScriptsRefusals() {
        var p = ProfileStore.newProfile(named: "Debian", kind: .debian, folder: URL(fileURLWithPath: "/m/d"))
        XCTAssertTrue(p.problems.isEmpty, "\(p.problems)")
        p.sshPort = 80; XCTAssertFalse(p.problems.isEmpty)
        p.sshPort = 2223; p.appsSizeGB = 4; XCTAssertFalse(p.problems.isEmpty)
        p.appsSizeGB = 32; p.shareDir = "/a,b"; XCTAssertFalse(p.problems.isEmpty)
        p.shareDir = ""; XCTAssertTrue(p.problems.isEmpty, "the share folder is optional")
    }
    func testNewDebianMachinesGetTheirOwnSshPort() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mylinux-debian-test-\(UUID().uuidString)")
        let store = ProfileStore(file: dir.appendingPathComponent("profiles.json"))
        let a = store.add(kind: .debian), b = store.add(kind: .debian)
        XCTAssertEqual(a.sshPort, 2223); XCTAssertEqual(b.sshPort, 2224)
        XCTAssertEqual(a.name, "Debian"); XCTAssertEqual(b.name, "Debian 2")
        try? FileManager.default.removeItem(at: dir)
    }
}

final class AlpineServerTests: XCTestCase {
    func testAnAlpineMachineMapsOntoRunAlpineSh() {
        let p = ProfileStore.newProfile(named: "Alpine", kind: .alpine, folder: URL(fileURLWithPath: "/m/alpine"))
        XCTAssertTrue(p.isServer)
        XCTAssertEqual(p.script, "run-alpine.sh")
        XCTAssertEqual(p.appsDisk, "/m/alpine/alpine.raw")
        XCTAssertEqual(p.memoryGB, Profile.recommendedMemoryGB(.alpine))
        XCTAssertEqual([8, 16, 32].map { Profile.recommendedMemoryGB(.alpine, macGB: $0) }, [2, 2, 4])
        XCTAssertTrue(p.problems.isEmpty, "\(p.problems)")
        let env = p.environment(outDir: URL(fileURLWithPath: "/o"), serialSocket: "/s.sock", qmpSocket: "/q.sock")
        XCTAssertEqual(env["DISK"], "/m/alpine/alpine.raw"); XCTAssertEqual(env["SSH_PORT"], "2223"); XCTAssertEqual(env["QMP"], "/q.sock")
        let t = p.terminalProfile
        XCTAssertEqual(t.username, "alpine"); XCTAssertEqual(t.installScriptFile, "alpine_install.sh"); XCTAssertTrue(t.launcherMachine)
        XCTAssertEqual(ProfileStore.newProfile(named: "D", kind: .debian, folder: URL(fileURLWithPath: "/m/d")).terminalProfile.installScriptFile, "debian_install.sh")
    }
    func testServersShareThePortRange() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mylinux-alpine-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProfileStore(file: dir.appendingPathComponent("profiles.json"))
        let d = store.add(kind: .debian), a = store.add(kind: .alpine)
        XCTAssertEqual(d.sshPort, 2223); XCTAssertEqual(a.sshPort, 2224, "two servers cannot listen on one port")
        XCTAssertEqual(a.name, "Alpine")
    }
}

final class CloudFolderTests: XCTestCase {
    func testFoldersAreFoundWhereTheCloudAppsKeepThem() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("mylinux-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let storage = home.appendingPathComponent("Library/CloudStorage")
        for d in ["Dropbox", "OneDrive-SoftwareOne", "GoogleDrive-me@example.com"] {
            try FileManager.default.createDirectory(at: storage.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        XCTAssertEqual(CloudFolder.dropbox.macPath(home: home), storage.appendingPathComponent("Dropbox").path)
        XCTAssertEqual(CloudFolder.onedrive.macPath(home: home), storage.appendingPathComponent("OneDrive-SoftwareOne").path)
        XCTAssertEqual(CloudFolder.googledrive.macPath(home: home), storage.appendingPathComponent("GoogleDrive-me@example.com").path)
        XCTAssertNil(CloudFolder.icloud.macPath(home: home), "no iCloud Drive in this home")
        let docs = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        XCTAssertEqual(CloudFolder.icloud.macPath(home: home), docs.path)
    }
    func testTheMountScriptAddsTheTickedAndRemovesTheRest() {
        let s = CloudFolder.mountScript(["dropbox"])
        XCTAssertTrue(s.contains(#"want="dropbox:Dropbox""#))
        XCTAssertTrue(s.contains("for pair in dropbox:Dropbox onedrive:OneDrive icloud:iCloud googledrive:GoogleDrive; do"))
        XCTAssertTrue(s.contains(##"$R sed -i "\#^$tag $mp #d" /etc/fstab"##), "an unticked folder leaves fstab")
        XCTAssertTrue(s.contains("command -v doas") && s.contains("sudo -n"), "root through doas (Alpine) or sudo (Debian)")
        XCTAssertTrue(CloudFolder.mountScript([]).contains(#"want="""#))
    }
    func testAServerPassesItsCloudFoldersToRunServerSh() throws {
        var p = ProfileStore.newProfile(named: "A", kind: .alpine, folder: URL(fileURLWithPath: "/m/a"))
        XCTAssertNil(p.environment(outDir: URL(fileURLWithPath: "/o"), serialSocket: "/s")["EXTRA_SHARES"], "none by default")
        p.cloudFolders = ["dropbox", "nonsense"]
        let env = p.environment(outDir: URL(fileURLWithPath: "/o"), serialSocket: "/s")
        if let dropbox = CloudFolder.dropbox.macPath() { XCTAssertEqual(env["EXTRA_SHARES"], "dropbox=\(dropbox)") }
        else { XCTAssertNil(env["EXTRA_SHARES"], "a folder this Mac does not have is left out") }
        let saved = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(saved.cloudFolders, ["dropbox", "nonsense"])
        let old = try JSONDecoder().decode(Profile.self, from: Data(#"{"kind":"alpine","name":"A","appsDisk":"/a","shareDir":""}"#.utf8))
        XCTAssertEqual(old.cloudFolders, [], "saved before cloud folders existed")
    }
}

final class GhosttyTerminalTests: XCTestCase {
    func testTheCommandLineKeepsEveryArgumentWhole() {
        let line = GhosttySshTerminal.commandLine("/usr/bin/ssh", ["-p", "2223", "-o", #"UserKnownHostsFile="/Users/a/Library/Application Support/m/known_hosts""#, "it's@127.0.0.1"])
        XCTAssertTrue(line.hasPrefix("'/usr/bin/env' 'sh' '-c' "), "through env sh -c, which clears login's line and always exits 0")
        XCTAssertTrue(line.contains(#"; "$0" "$@"; exit 0'"#), "the program with its arguments exactly as given, then exit 0")
        XCTAssertTrue(line.contains(#"'UserKnownHostsFile="/Users/a/Library/Application Support/m/known_hosts"'"#), "a space stays inside its argument")
        XCTAssertTrue(line.hasSuffix(#"'it'\''s@127.0.0.1'"#), "a single quote is escaped")
    }
    func testTheEngineFollowsTheSetting() {
        let key = TerminalEngine.settingKey, saved = UserDefaults.standard.string(forKey: key)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        guard ProcessInfo.processInfo.environment["MYLINUX_TERMINAL"] == nil else { return }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(TerminalEngine.current, .ghostty, "Ghostty unless SwiftTerm is chosen")
        UserDefaults.standard.set("swiftterm", forKey: key)
        XCTAssertEqual(TerminalEngine.current, .swiftTerm)
    }
}

final class MachineCommandTests: XCTestCase {
    func testEachDistributionGetsItsOwnTools() {
        let alpine = MachineCommands.sections(alpine: true).flatMap(\.1), debian = MachineCommands.sections(alpine: false).flatMap(\.1)
        XCTAssertTrue(alpine.contains { $0.text == "doas apk update && doas apk upgrade" })
        XCTAssertTrue(debian.contains { $0.text == "sudo apt update && sudo apt upgrade -y" })
        XCTAssertFalse(alpine.contains { $0.text.contains("sudo") || $0.text.contains("apt ") }, "no sudo or apt on Alpine")
        XCTAssertFalse(debian.contains { $0.text.contains("doas") || $0.text.contains("apk ") }, "no doas or apk on Debian")
        XCTAssertEqual(alpine.first?.text, "cc", "the agents first")
    }
    func testAnUnfinishedCommandWaitsOnThePrompt() {
        let install = MachineCommands.sections(alpine: true).flatMap(\.1).first { $0.title.hasPrefix("Install a package") }
        XCTAssertEqual(install?.text, "doas apk add ")
        XCTAssertEqual(install?.run, false, "the name is typed by the user, then Return")
    }
}

final class SecondsTests: XCTestCase {
    func testDurationsReadInWholeSeconds() {
        XCTAssertEqual(Runner.seconds(0.2), "<1 s")
        XCTAssertEqual(Runner.seconds(0.6), "1 s")
        XCTAssertEqual(Runner.seconds(13.4), "13 s")
        XCTAssertEqual(Runner.seconds(16.5), "17 s")
    }
}

final class BundledRuntimeTests: XCTestCase {
    func testInstalledWhenMissingOrAnotherVersion() {
        XCTAssertTrue(RuntimeManager.bundledInstallNeeded(installed: nil, bundled: "qemu-runtime-11.1.1-2", hasTarball: true))
        XCTAssertTrue(RuntimeManager.bundledInstallNeeded(installed: "qemu-runtime-11.1.1-1", bundled: "qemu-runtime-11.1.1-2", hasTarball: true))
        XCTAssertFalse(RuntimeManager.bundledInstallNeeded(installed: "qemu-runtime-11.1.1-2", bundled: "qemu-runtime-11.1.1-2", hasTarball: true))
    }
    func testANewerDownloadedRuntimeIsKept() {
        XCTAssertFalse(RuntimeManager.bundledInstallNeeded(installed: "qemu-runtime-11.1.1-3", bundled: "qemu-runtime-11.1.1-2", hasTarball: true))
        XCTAssertFalse(RuntimeManager.bundledInstallNeeded(installed: "qemu-runtime-11.2.0-1", bundled: "qemu-runtime-11.1.1-9", hasTarball: true))
        XCTAssertTrue(RuntimeManager.bundledInstallNeeded(installed: "qemu-runtime-11.1.1-9", bundled: "qemu-runtime-11.2.0-1", hasTarball: true))
        XCTAssertTrue(RuntimeManager.bundledInstallNeeded(installed: "garbage", bundled: "qemu-runtime-11.1.1-2", hasTarball: true))
    }
    func testNothingWithoutABundledRuntime() {
        XCTAssertFalse(RuntimeManager.bundledInstallNeeded(installed: nil, bundled: "qemu-runtime-11.1.1-2", hasTarball: false))
        XCTAssertFalse(RuntimeManager.bundledInstallNeeded(installed: nil, bundled: nil, hasTarball: true))
        XCTAssertFalse(RuntimeManager.bundledInstallNeeded(installed: nil, bundled: "", hasTarball: true))
    }
}

final class RunnerDiskTests: XCTestCase {
    func matches(_ line: String, _ disk: String) -> Bool {
        let re = try! NSRegularExpression(pattern: Runner.diskPattern(disk))
        return re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }
    func testBothScriptsDriveOptionsAreRecognised() {
        let disk = "/Users/x/Library/Application Support/myLinux/machines/a.b/omarchy.ext4"
        // run.sh
        XCTAssertTrue(matches("qemu-system-aarch64 -drive file=\(disk),if=none,format=raw,id=apps -device virtio-blk-pci", disk))
        // run-omarchy.sh
        XCTAssertTrue(matches("qemu-system-aarch64 -drive if=none,id=root,file=\(disk),format=raw,media=disk -device virtio-blk-pci", disk))
    }
    func testAnotherMachinesDiskDoesNotMatch() {
        XCTAssertFalse(matches("-drive if=none,id=root,file=/m/omarchy.ext4.bak,format=raw", "/m/omarchy.ext4"))
        XCTAssertFalse(matches("-drive if=none,id=root,file=/m/old/omarchy.ext4,format=raw", "/m/omarchy.ext4"))
        XCTAssertFalse(matches("-drive file=/m/a.img,if=none", "/m/a.im"))
    }
}

final class RunnerTextTests: XCTestCase {
    func testColourCodesAndCarriageReturnsAreRemoved() {
        let raw = "\u{1B}[0;32mmyLinux\u{1B}[0m login:\r\nroot\r\n"
        XCTAssertEqual(Runner.cleanTerminalText(raw), "myLinux login:\nroot\n")
    }

    func testWindowTitleSequencesAreRemoved() {
        XCTAssertEqual(Runner.cleanTerminalText("\u{1B}]0;title\u{07}text"), "text")
    }

    func testNonPrintableBytesAreDropped() {
        XCTAssertEqual(Runner.cleanTerminalText("a\u{0}b\u{7}c"), "abc")
    }

    func testSocketPathFitsTheUnixLimit() {
        let runner = Runner(profileID: UUID())
        XCTAssertLessThan(runner.serialSocket.utf8.count, 104)
    }
}

final class PathTests: XCTestCase {
    func testSlugsAreFolderSafe() {
        XCTAssertEqual(Paths.slug("Work Machine"), "work-machine")
        XCTAssertEqual(Paths.slug("Viktor's µLinux!"), "viktor-s-linux")
        XCTAssertEqual(Paths.slug("***"), "machine")
    }

    func testCheckoutDetectionNeedsRunSh() {
        XCTAssertFalse(Paths.isCheckout(""))
        XCTAssertFalse(Paths.isCheckout("/tmp"))
    }
}

final class RemoteTests: XCTestCase {
    func testKeysymsForSpecialKeys() {
        XCTAssertEqual(KeyMap.keysym(keyCode: 36, characters: "\r", charactersIgnoringModifiers: "\r", shift: false), 0xff0d)   // Return
        XCTAssertEqual(KeyMap.keysym(keyCode: 53, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", shift: false), 0xff1b)
        XCTAssertEqual(KeyMap.keysym(keyCode: 122, characters: "", charactersIgnoringModifiers: "", shift: false), 0xffbe)   // F1
    }
    func testKeysymsFollowTheLayout() {
        XCTAssertEqual(KeyMap.keysym(keyCode: 0, characters: "a", charactersIgnoringModifiers: "a", shift: false), 0x61)
        XCTAssertEqual(KeyMap.keysym(keyCode: 0, characters: "A", charactersIgnoringModifiers: "a", shift: true), 0x41, "Shift sends the shifted glyph")
        XCTAssertEqual(KeyMap.keysym(keyCode: 0, characters: "\u{01}", charactersIgnoringModifiers: "a", shift: false), 0x61, "Ctrl+a arrives as a")
        XCTAssertEqual(KeyMap.keysym(keyCode: 39, characters: "ø", charactersIgnoringModifiers: "ø", shift: false), 0xf8, "Latin-1 keysym for ø")
        XCTAssertEqual(KeyMap.keysym(keyCode: 0, characters: "€", charactersIgnoringModifiers: "€", shift: false), 0x01000000 + 0x20ac, "Unicode keysym")
    }
    func testProfileDecodingToleratesOldFiles() throws {
        let json = #"[{"id":"3E5B5E7E-0C3E-4E2E-9B7B-0F1E2D3C4B5A","name":"imac","kind":"ssh","host":"192.168.0.61"}]"#
        let list = try JSONDecoder().decode([RemoteProfile].self, from: Data(json.utf8))
        XCTAssertEqual(list.first?.port, 22, "an SSH profile without a port gets 22")
        XCTAssertEqual(list.first?.keyboard, .mac)
        XCTAssertEqual(list.first?.problems, [])
    }
    func testProblems() {
        var p = RemoteProfile(kind: .vnc)
        XCTAssertFalse(p.problems.isEmpty, "a host is required")
        p.host = "omarchy"; p.port = 70000
        XCTAssertFalse(p.problems.isEmpty, "the port must be valid")
        p.port = 5900
        XCTAssertTrue(p.problems.isEmpty)
        XCTAssertEqual(p.keyboard, .optionSuper, "VNC desktops default to Option as Super")
    }
    /// A self-signed certificate for the tests (CN mylinux-test), made once with the system openssl.
    static func testCertificate() throws -> String {
        let path = NSTemporaryDirectory() + "mylinux-test-cert.pem"
        if !FileManager.default.fileExists(atPath: path) {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            p.arguments = ["req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes", "-keyout", "/dev/null",
                           "-subj", "/CN=mylinux-test", "-days", "1", "-out", path]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
        }
        return try String(contentsOfFile: path, encoding: .utf8)
    }
    func testPinRoundTrip() throws {
        let pem = try RemoteTests.testCertificate()
        let first = try XCTUnwrap(CertPin.describe(pem))
        let again = try XCTUnwrap(CertPin.describe(first.pem), "the PEM we write must read back")
        XCTAssertEqual(again.fingerprint, first.fingerprint)
        XCTAssertFalse(first.pem.contains("\r"))
    }
    func testCertificateDescription() throws {
        let pem = try RemoteTests.testCertificate()
        let info = try XCTUnwrap(CertPin.describe(pem))
        XCTAssertEqual(info.name, "mylinux-test")
        XCTAssertEqual(info.fingerprint.count, 32 * 3 - 1)
    }
}

/// Against a real VeNCrypt server: MYLINUX_TEST_VNC_HOST=192.168.0.61 swift test --filter CertProbe
final class OmarchyProfileTests: XCTestCase {
    func testAnOmarchyMachineMapsOntoRunOmarchySh() {
        var p = ProfileStore.newProfile(named: "Omarchy", kind: .omarchy, folder: URL(fileURLWithPath: "/tmp/m/omarchy"))
        XCTAssertEqual(p.script, "run-omarchy.sh")
        XCTAssertEqual(p.windowName, "Omarchy", "no myLinux prefix on the window")
        XCTAssertTrue(p.problems.isEmpty, "\(p.problems)")
        let env = p.environment(outDir: URL(fileURLWithPath: "/tmp/out"), serialSocket: "/tmp/s.sock", qmpSocket: "/tmp/q.sock")
        XCTAssertEqual(env["DISK"], "/tmp/m/omarchy/omarchy.ext4")
        XCTAssertEqual(env["DISK_SIZE_GB"], "32")
        XCTAssertEqual(env["MEM"], "\(Profile.recommendedMemoryGB(.omarchy))G", "sized from this Mac's memory")
        XCTAssertEqual(env["QMP"], "/tmp/q.sock", "Stop presses the power button there")
        XCTAssertEqual(env["SHARE_DIR"], "/tmp/m/omarchy/Mac")
        XCTAssertNil(env["APPS_IMG"]); XCTAssertNil(env["MOUSE"]); XCTAssertNil(env["CLIPBOARD"], "sharing is the default")
        p.clipboard = false
        XCTAssertEqual(p.environment(outDir: URL(fileURLWithPath: "/tmp/out"), serialSocket: "/tmp/s.sock")["CLIPBOARD"], "0")
        p.clipboard = true
        p.shareDir = ""
        XCTAssertTrue(p.problems.isEmpty, "the share is optional for Omarchy")
        XCTAssertNil(p.environment(outDir: URL(fileURLWithPath: "/tmp/out"), serialSocket: "/tmp/s.sock").keys.first { $0 == "SHARE_DIR" })
        p.appsSizeGB = 4
        XCTAssertFalse(p.problems.isEmpty, "the factory disk alone is 6 GB")
    }
    func testOmarchySettingsReachTheScript() {
        var p = ProfileStore.newProfile(named: "O", kind: .omarchy, folder: URL(fileURLWithPath: "/tmp/m/o"))
        var env = p.environment(outDir: URL(fileURLWithPath: "/tmp/out"), serialSocket: "/tmp/s")
        XCTAssertNil(env["CPUS"], "automatic: the script picks"); XCTAssertNil(env["AUDIO"]); XCTAssertNil(env["SSH"]); XCTAssertNil(env["FORWARD"])
        p.cpus = 4; p.sound = false; p.sshPort = 2222; p.resolution = "1920X1200"
        env = p.environment(outDir: URL(fileURLWithPath: "/tmp/out"), serialSocket: "/tmp/s")
        XCTAssertEqual(env["CPUS"], "4"); XCTAssertEqual(env["AUDIO"], "0")
        XCTAssertEqual(env["SSH"], "1"); XCTAssertEqual(env["FORWARD"], "2222:22"); XCTAssertEqual(env["RES"], "1920x1200")
        XCTAssertTrue(p.problems.isEmpty, "\(p.problems)")
        p.sshPort = 80
        XCTAssertFalse(p.problems.isEmpty, "privileged ports cannot be forwarded by a user process")
    }
    func testProfilesFromBeforeKindsAreMyLinux() throws {
        let old = #"{"name":"Work","appsDisk":"/x/apps.img","shareDir":"/x/share"}"#
        let p = try JSONDecoder().decode(Profile.self, from: Data(old.utf8))
        XCTAssertEqual(p.kind, .mylinux); XCTAssertEqual(p.script, "run.sh")
        let newer = #"{"name":"X","kind":"something-new","appsDisk":"/x/a","shareDir":"/x/s"}"#
        XCTAssertEqual(try JSONDecoder().decode(Profile.self, from: Data(newer.utf8)).kind, .mylinux, "an unknown kind must not drop the file")
        var o = ProfileStore.newProfile(named: "O", kind: .omarchy); o.name = "O"
        let round = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(o))
        XCTAssertEqual(round.kind, .omarchy)
    }
}

final class QemuRuntimeTests: XCTestCase {
    func testTheRuntimeNeedsItsBinaryAndItsLibraries() throws {
        let fm = FileManager.default
        let out = fm.temporaryDirectory.appendingPathComponent("mylinux-runtime-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: out) }
        XCTAssertNil(Paths.runtimeQemu(in: out), "nothing installed")
        let bin = out.appendingPathComponent("qemu-runtime/bin/qemu-system-aarch64")
        try fm.createDirectory(at: bin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: bin, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        XCTAssertNil(Paths.runtimeQemu(in: out), "a binary without lib/ is half an install (tools/qemu-flavour.sh says the same)")
        try fm.createDirectory(at: out.appendingPathComponent("qemu-runtime/lib"), withIntermediateDirectories: true)
        XCTAssertEqual(Paths.runtimeQemu(in: out), bin.path)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: bin.path)
        XCTAssertNil(Paths.runtimeQemu(in: out), "not executable")
    }
}

final class StatusMenuTests: XCTestCase {
    func testTheMenuBarOffersTheWayOutOfAGrab() {
        let menu = NSMenu()
        StatusMenu.shared.makeMenu(into: menu)
        let titles = menu.items.map(\.title)
        XCTAssertEqual(titles.first, StatusMenu.releaseTitle, "the release is the first thing under the mouse")
        XCTAssertTrue(titles.contains("Quit myLinux Launcher"))
        let release = menu.items[0]
        XCTAssertFalse(release.isEnabled, "nothing to release while no grab is on")
        XCTAssertFalse(menu.autoenablesItems, "enablement is ours, not AppKit's responder-chain guess")
    }
    func testKeysPassThroughWhileTheMenuIsOpen() {
        let menu = NSMenu()
        StatusMenu.shared.menuWillOpen(menu)
        XCTAssertTrue(KeyboardGrab.shared.passThrough)
        StatusMenu.shared.menuDidClose(menu)
        XCTAssertFalse(KeyboardGrab.shared.passThrough)
    }
}

/// Phase 4 of docs/MAC-REMOTE-PLAN.md: the session file, the URLs, the import, the ⌘K list.
final class RemoteSessionTests: XCTestCase {
    private func tempDir() throws -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mylinux-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }
    func testTheSessionFileRoundTripsAndGoesAwayWhenEmpty() throws {
        let file = try tempDir().appendingPathComponent("remote-session.json")
        let ids = [UUID(), UUID()]
        RemoteSession.save(ids, to: file)
        XCTAssertEqual(RemoteSession.load(from: file), ids, "in the order they were opened")
        RemoteSession.save([], to: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "no windows: nothing to bring back")
        XCTAssertEqual(RemoteSession.load(from: file), [])
    }
    func testLinksNameTheMachine() throws {
        XCTAssertEqual(RemoteLink.parse(URL(string: "mylinux://vnc/omarchy%20imac")!), .remote(kind: .vnc, name: "omarchy imac"))
        XCTAssertEqual(RemoteLink.parse(URL(string: "mylinux://ssh/build-box/")!), .remote(kind: .ssh, name: "build-box"))
        XCTAssertEqual(RemoteLink.parse(URL(string: "mylinux-launcher://start")!), .start)
        let id = UUID()
        XCTAssertEqual(RemoteLink.parse(URL(string: "mylinux-launcher://remote/\(id.uuidString)")!), .remote(kind: nil, name: id.uuidString), "the older form still works")
        XCTAssertNil(RemoteLink.parse(URL(string: "https://mylinux.app/vnc/x")!))
        XCTAssertNil(RemoteLink.parse(URL(string: "mylinux://settings")!))
    }
    func testFindingAProfileByNameHostOrId() throws {
        let store = RemoteStore(file: try tempDir().appendingPathComponent("remote.json"))
        var a = RemoteProfile(kind: .vnc); a.name = "Omarchy iMac"; a.host = "192.168.0.61"
        var b = RemoteProfile(kind: .ssh); b.name = "omarchy imac"; b.host = "192.168.0.61"
        store.profiles = [a, b]
        XCTAssertEqual(store.find("omarchy imac", kind: .vnc)?.id, a.id, "case does not matter")
        XCTAssertEqual(store.find("omarchy imac", kind: .ssh)?.id, b.id)
        XCTAssertEqual(store.find("OMARCHY IMAC")?.id, a.id, "without a kind the first match wins")
        XCTAssertEqual(store.find("192.168.0.61", kind: .ssh)?.id, b.id, "the host works too")
        XCTAssertEqual(store.find(b.id.uuidString)?.id, b.id)
        XCTAssertNil(store.find("nothing")); XCTAssertNil(store.find(""))
    }
    func testImportReadsTheViewersMachinesAndSecrets() throws {
        let json = #"[{"name":"imac","type":"vnc","host":"192.168.0.61","port":5900,"username":"viktor","quality":"best"},"# +
                   #"{"name":"build box","type":"ssh","host":"10.0.0.5","port":"2222","username":"root","keyFile":"~/.ssh/id","tmux":"main"},"# +
                   #"{"name":"old","host":"old.local","port":5901},{"name":"no host"}]"#
        let list = try RemoteImport.parse(Data(json.utf8))
        XCTAssertEqual(list.map(\.name), ["imac", "build box", "old"], "an entry without a host is skipped")
        XCTAssertEqual(list[0].kind, .vnc); XCTAssertEqual(list[0].quality, "best"); XCTAssertEqual(list[0].username, "viktor")
        XCTAssertEqual(list[1].kind, .ssh); XCTAssertEqual(list[1].port, 2222, "a port written as text"); XCTAssertEqual(list[1].tmux, "main"); XCTAssertEqual(list[1].keyboard, .mac)
        XCTAssertEqual(list[2].kind, .vnc, "older files have no type"); XCTAssertEqual(list[2].keyboard, .optionSuper)
        XCTAssertEqual(RemoteImport.secretKey(name: "build box", kind: .ssh), "SSH_BUILD_BOX_PASSWORD")
        XCTAssertEqual(RemoteImport.secretKey(name: "--Omarchy iMac!", kind: .vnc), "VNC_OMARCHY_IMAC_PASSWORD")
        XCTAssertEqual(RemoteImport.secretKey(name: "", kind: .vnc), "VNC_DEFAULT_PASSWORD")
        let env = RemoteImport.passwords("# comment\nVNC_IMAC_PASSWORD=secret\nSSH_BUILD_BOX_PASSWORD='it'\\''s'\nexport X=\"q\"\nbroken\n")
        XCTAssertEqual(env["VNC_IMAC_PASSWORD"], "secret"); XCTAssertEqual(env["SSH_BUILD_BOX_PASSWORD"], "it's"); XCTAssertEqual(env["X"], "q")
        // the files as the guest lays them out: vnc/machines.json with secrets.env one folder up
        let dir = try tempDir(); try FileManager.default.createDirectory(at: dir.appendingPathComponent("vnc"), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: dir.appendingPathComponent("vnc/machines.json"))
        try "VNC_IMAC_PASSWORD=secret\n".write(to: dir.appendingPathComponent("secrets.env"), atomically: true, encoding: .utf8)
        let entries = try RemoteImport.load(dir.appendingPathComponent("vnc/machines.json"))
        XCTAssertEqual(entries.map(\.password), ["secret", nil, nil])
    }
    func testMergingKeepsExistingProfilesAndTheirIds() throws {
        let store = RemoteStore(file: try tempDir().appendingPathComponent("remote.json"))
        var existing = RemoteProfile(kind: .vnc); existing.name = "iMac"; existing.host = "old"; existing.keyboard = .all
        store.profiles = [existing]
        var new = RemoteProfile(kind: .vnc); new.name = "imac"; new.host = "192.168.0.61"
        var other = RemoteProfile(kind: .ssh); other.name = "imac"; other.host = "192.168.0.61"
        var saved: [String] = []
        let r = store.merge([.init(profile: new, password: "pw"), .init(profile: other, password: nil)], savePassword: { pw, p in saved.append(pw + " for " + p.name); return true })
        XCTAssertEqual(r.added, 1); XCTAssertEqual(r.updated, 1)
        XCTAssertEqual(store.profiles.count, 2)
        XCTAssertEqual(store.profiles[0].id, existing.id, "the same name and kind updates in place")
        XCTAssertEqual(store.profiles[0].host, "192.168.0.61"); XCTAssertEqual(store.profiles[0].keyboard, .all, "the keyboard mode is the user's, not the file's")
        XCTAssertTrue(store.profiles[0].hasPassword); XCTAssertEqual(saved, ["pw for iMac"])
        XCTAssertEqual(store.profiles[1].kind, .ssh)
        XCTAssertEqual(store.merge([.init(profile: new, password: nil)], savePassword: { _, _ in false }).updated, 0, "nothing changed: not counted")
    }
    func testQuickConnectListsAndFilters() {
        var vm = Profile(name: "Work", appsDisk: "/x/apps.img", shareDir: "/x/share"); vm.name = "Work"
        var a = RemoteProfile(kind: .vnc); a.name = "Omarchy iMac"; a.host = "192.168.0.61"
        var b = RemoteProfile(kind: .ssh); b.host = "build.local"; b.username = "root"
        let items = QuickConnect.items(remote: [a, b], machines: [vm])
        XCTAssertEqual(items.map(\.title), ["Work", "Omarchy iMac", "build.local"], "machines first, then remote; a nameless profile shows its host")
        XCTAssertEqual(QuickConnect.filter(items, "").count, 3)
        XCTAssertEqual(QuickConnect.filter(items, "imac").map(\.title), ["Omarchy iMac"])
        XCTAssertEqual(QuickConnect.filter(items, "ssh root").map(\.title), ["build.local"], "every word must match, in the title or the subtitle")
        XCTAssertEqual(QuickConnect.filter(items, "192 vnc").map(\.title), ["Omarchy iMac"])
        XCTAssertEqual(QuickConnect.filter(items, "nothing").count, 0)
    }
}

final class CertProbeTests: XCTestCase {
    func testFetchesTheServerCertificate() throws {
        guard let host = ProcessInfo.processInfo.environment["MYLINUX_TEST_VNC_HOST"] else { throw XCTSkip("MYLINUX_TEST_VNC_HOST not set") }
        let done = expectation(description: "certificate")
        var result: Result<CertPin.Info, Error>?
        CertPin.fetch(host: host, port: 5900) { r in result = r; done.fulfill() }
        wait(for: [done], timeout: 15)
        let info = try XCTUnwrap(result).get()
        XCTAssertFalse(info.name.isEmpty, "the certificate names the machine")
        XCTAssertEqual(info.fingerprint.count, 95)
        XCTAssertTrue(info.pem.hasPrefix("-----BEGIN CERTIFICATE-----"))
    }
}
