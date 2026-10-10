import XCTest
import SwiftUI
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

final class ServerAppsTests: XCTestCase {
    func testTheAppComesFromMain() {
        XCTAssertEqual(ServerApps.url("catalog.json").absoluteString, "https://raw.githubusercontent.com/adminmylinux/mylinux/main/server-apps/catalog.json")
        XCTAssertTrue(ServerApps.command.contains("sh /mnt/mac/.mylinux/apps/run.sh && exec"), "leaving the app starts a fresh login shell")
    }
    func testTheRepositoryFilesArePlausible() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../server-apps").standardized
        for f in ServerApps.files {
            XCTAssertTrue(ServerApps.plausible(f, try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)), f)
        }
        XCTAssertFalse(ServerApps.plausible("catalog.json", "<html>404</html>"))
    }
    func testOmarchysAgentIsAskedToOpenTheApp() async throws {
        let share = FileManager.default.temporaryDirectory.appendingPathComponent("apps-omarchy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: share) }
        var p = ProfileStore.newProfile(named: "O", kind: .omarchy, folder: share)
        p.shareDir = share.path
        let cmd = share.appendingPathComponent("mylinux-tools/control/apps.cmd")
        // a stand-in agent: takes the command as the real one does
        let agent = Task.detached {
            for _ in 0..<40 {
                if FileManager.default.fileExists(atPath: cmd.path) { try? FileManager.default.removeItem(at: cmd); return true }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return false
        }
        let problem = await ServerApps.openInOmarchy(p)
        XCTAssertNil(problem, "the agent took it")
        let took = await agent.value
        XCTAssertTrue(took)
        XCTAssertTrue(FileManager.default.fileExists(atPath: share.appendingPathComponent(".mylinux/apps/run.sh").path), "the app is in the share")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ServerApps.cloudStateFile(share.path).path), "with the cloud drives beside it")
        // no agent: said why, and the command does not linger for a later one to run unasked
        let unanswered = await ServerApps.openInOmarchy(p)
        XCTAssertTrue(unanswered?.contains("session helper did not answer") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cmd.path))
    }
    func testCloudDrivesGoBothWays() throws {
        let share = FileManager.default.temporaryDirectory.appendingPathComponent("apps-cloud-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: share) }
        var p = ProfileStore.newProfile(named: "A", kind: .alpine, folder: share)
        p.shareDir = share.path; p.cloudFolders = ["dropbox"]
        ServerApps.writeCloudState(p)
        let state = try JSONSerialization.jsonObject(with: Data(contentsOf: ServerApps.cloudStateFile(share.path))) as? [String: Any]
        XCTAssertEqual(state?["selected"] as? [String], ["dropbox"])
        XCTAssertEqual((state?["folders"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["dropbox", "onedrive", "icloud", "googledrive"])
        XCTAssertNil(ServerApps.takeCloudRequest(share.path), "no request")
        try Data(#"{"folders": ["icloud", "nonsense", "dropbox"]}"#.utf8).write(to: ServerApps.cloudRequestFile(share.path))
        XCTAssertEqual(ServerApps.takeCloudRequest(share.path), ["dropbox", "icloud"], "known folders, in their order")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ServerApps.cloudRequestFile(share.path).path), "taken once")
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

final class RemoveMachineTests: XCTestCase {
    /// A removed machine's folder is not handed to the next machine of its kind (its disk booted again as the "new" one).
    func testALeftOverFolderCountsOnlyWithFilesInIt() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("mylinux-leftover-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        XCTAssertFalse(ProfileStore.leftOver(dir.appendingPathComponent("omarchy")), "no folder")
        try fm.createDirectory(at: dir.appendingPathComponent("omarchy"), withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("omarchy/.DS_Store"))
        XCTAssertFalse(ProfileStore.leftOver(dir.appendingPathComponent("omarchy")), "empty but for hidden files")
        try Data([1]).write(to: dir.appendingPathComponent("omarchy/omarchy.ext4"))
        XCTAssertTrue(ProfileStore.leftOver(dir.appendingPathComponent("omarchy")), "a disk left behind")
    }

    /// What Move to Trash takes: the machine's own folder under machines/, else only its disk; never a folder or disk
    /// another machine uses.
    func testMachineFilesAreTheMachinesOwn() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("mylinux-machines-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let store = ProfileStore(file: root.appendingPathComponent("profiles.json"))
        let own = ProfileStore.newProfile(named: "Omarchy", kind: .omarchy, folder: root.appendingPathComponent("omarchy"))
        try fm.createDirectory(atPath: own.shareDir, withIntermediateDirectories: true)
        try Data([1]).write(to: URL(fileURLWithPath: own.appsDisk))
        store.profiles = [own]
        XCTAssertEqual(store.machineFiles(own, machinesRoot: root).map(\.lastPathComponent), ["omarchy"], "its whole folder")
        // a machine whose share is inside that folder keeps the folder; only the disk goes
        var other = ProfileStore.newProfile(named: "Debian", kind: .debian, folder: root.appendingPathComponent("debian"))
        other.shareDir = own.shareDir
        store.profiles = [own, other]
        XCTAssertEqual(store.machineFiles(own, machinesRoot: root).map(\.lastPathComponent), ["omarchy.ext4"])
        // a disk outside machines/ (a checkout's out/apps.img): the disk alone; nothing when another machine uses it
        let elsewhere = Profile(name: "Dev", appsDisk: own.appsDisk, shareDir: "/tmp/somewhere")
        store.profiles = [own, elsewhere]
        XCTAssertEqual(store.machineFiles(elsewhere, machinesRoot: root.appendingPathComponent("x")), [], "the disk is another machine's too")
        XCTAssertEqual(store.machineFiles(elsewhere, machinesRoot: root).count, 0)
        try? fm.removeItem(atPath: own.appsDisk)
        store.profiles = [own]
        XCTAssertEqual(store.machineFiles(own, machinesRoot: root.appendingPathComponent("x")), [], "no disk, nothing")
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
    func testNewerVersions() {
        XCTAssertTrue(LauncherUpdater.isNewer("0.7.17", than: "0.7.16"))
        XCTAssertTrue(LauncherUpdater.isNewer("0.8", than: "0.7.99"))
        XCTAssertTrue(LauncherUpdater.isNewer("0.7.10", than: "0.7.9"), "numbers, not text")
        XCTAssertFalse(LauncherUpdater.isNewer("0.7.16", than: "0.7.16"))
        XCTAssertFalse(LauncherUpdater.isNewer("0.7.16", than: "0.7.17"))
        XCTAssertFalse(LauncherUpdater.isNewer("0.7", than: "0.7.0"), "0.7 is 0.7.0")
        XCTAssertTrue(LauncherUpdater.isNewer("0.7.17", than: "0.7.16-3-gabc1234"), "a development build of 0.7.16 is older")
    }
    func testTheUpdateFeedReads() throws {
        let json = #"{"version": "0.7.17", "sha256": "ab", "size": 27455816, "notes": "**New**", "dmg": "https://github.com/adminmylinux/mylinux-releases/releases/download/launcher-0.7.17/myLinux-Launcher.dmg"}"#
        let r = try JSONDecoder().decode(LauncherUpdater.Release.self, from: Data(json.utf8))
        XCTAssertEqual(r.version, "0.7.17")
        XCTAssertEqual(r.dmg.lastPathComponent, "myLinux-Launcher.dmg")
        XCTAssertEqual(r.size, 27455816)
        XCTAssertEqual(r.notes, "**New**")
    }
    func testOmarchysPastedCommandsAskSudoForThePassword() {
        let s = CloudFolder.pasteScript(["dropbox"])
        XCTAssertTrue(s.hasPrefix("# myLinux:"), "a comment says what the paste is")
        XCTAssertTrue(s.contains(#"R=; [ "$(id -u)" = 0 ] || R="sudo""#))
        XCTAssertFalse(s.contains("sudo -n"), "a terminal can answer sudo's password question")
        XCTAssertTrue(s.contains(#"want="dropbox:Dropbox""#) && s.contains("/etc/fstab"), "mounted at every start from then on")
    }
    func testTheCloudFolderScriptsAreValidShell() throws {
        for (what, script) in [("server", CloudFolder.mountScript(["dropbox"])), ("paste", CloudFolder.pasteScript(["dropbox", "icloud"])),
                               ("console", CloudFolder.consoleScript(["dropbox"])), ("none", CloudFolder.mountScript([]))] {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-n"]
            let input = Pipe(); p.standardInput = input; p.standardError = Pipe()
            try p.run(); input.fileHandleForWriting.write(Data(script.utf8)); try input.fileHandleForWriting.close()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, "\(what): sh -n")
        }
        let s = CloudFolder.pasteScript(["dropbox"])
        XCTAssertTrue(s.contains("systemctl daemon-reload"), "systemd learns of the fstab change (no hint about it)")
        XCTAssertTrue(s.contains(#"echo "myLinux: ~/$name is ready""#), "the paste says when it worked")
    }
    func testMyLinuxMountsItsCloudFoldersThroughTheConsole() {
        let s = CloudFolder.consoleScript(["dropbox", "icloud"])
        XCTAssertFalse(s.contains("\n"), "one line typed into the console")
        XCTAssertTrue(s.hasSuffix("&"), "in the background: the console is free again at once")
        XCTAssertTrue(s.contains(#"want="dropbox:Dropbox icloud:iCloud""#))
        XCTAssertTrue(s.contains("while ! mountpoint -q /root"), "waits for the apps disk's home")
        XCTAssertTrue(s.contains("mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000 $tag $mp"))
        XCTAssertTrue(s.contains("mount --bind $mp /mnt/apps$mp"), "the apps see it too")
        XCTAssertTrue(s.contains("ln -sfn $mp /root/$name"))
        XCTAssertFalse(s.contains("fstab"), "the root filesystem is in RAM")
    }
    func testDesktopsPassTheirCloudFoldersToo() {
        for kind in [Profile.Kind.omarchy, .mylinux] {
            var p = ProfileStore.newProfile(named: "D", kind: kind, folder: URL(fileURLWithPath: "/m/d"))
            XCTAssertNil(p.environment(outDir: URL(fileURLWithPath: "/o"), serialSocket: "/s")["EXTRA_SHARES"], "\(kind): none by default")
            p.cloudFolders = ["dropbox"]
            let env = p.environment(outDir: URL(fileURLWithPath: "/o"), serialSocket: "/s")
            if let dropbox = CloudFolder.dropbox.macPath() { XCTAssertEqual(env["EXTRA_SHARES"], "dropbox=\(dropbox)", "\(kind)") }
        }
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
        XCTAssertEqual(p.keyboard, .all, "VNC desktops send every key to the remote by default")
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
    func testArchIsADesktopStartedLikeOmarchy() {
        let p = ProfileStore.newProfile(named: "A", kind: .arch, folder: URL(fileURLWithPath: "/tmp/m/a"))
        XCTAssertTrue(p.kind.runsDesktop); XCTAssertFalse(p.isServer)
        XCTAssertEqual(p.script, "run-omarchy.sh")
        XCTAssertEqual(p.appsDisk, "/tmp/m/a/arch.ext4"); XCTAssertEqual(p.shareDir, "/tmp/m/a/Mac")
        XCTAssertEqual(p.grab, "opt", "Plasma is a Ctrl desktop: ⌘ stays with the Mac")
        let env = p.environment(outDir: URL(fileURLWithPath: "/tmp/out"), serialSocket: "/tmp/s", qmpSocket: "/tmp/q")
        XCTAssertEqual(env["DESKTOP"], "arch"); XCTAssertEqual(env["QMP"], "/tmp/q"); XCTAssertEqual(env["DISK"], "/tmp/m/a/arch.ext4")
        XCTAssertEqual(env["APP_ICON"], "tools/icons/machine-arch.icns")
        XCTAssertNil(ProfileStore.newProfile(named: "O", kind: .omarchy).environment(outDir: URL(fileURLWithPath: "/tmp/out"), serialSocket: "/tmp/s")["DESKTOP"])
        XCTAssertTrue(p.problems.isEmpty, "\(p.problems)")
        XCTAssertEqual(MachineApp.bundleID(p), "dev.mylinux.vm.omarchy.\(p.id.uuidString.lowercased())", "the same QEMU wrapper as Omarchy's")
    }
    func testCodexLoginRequestIsTakenOnceAndTheLoginDeliveredPrivately() throws {
        let share = FileManager.default.temporaryDirectory.appendingPathComponent("codexlogin-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: share) }
        XCTAssertNil(CodexLogin.take(share), "no request, nothing taken")
        try FileManager.default.createDirectory(at: CodexLogin.folder(share), withIntermediateDirectories: true)
        try Data("1\n".utf8).write(to: CodexLogin.requestFile(share))
        let age = try XCTUnwrap(CodexLogin.take(share)); XCTAssertLessThan(age, CodexLogin.requestLifetime)
        XCTAssertNil(CodexLogin.take(share), "the launcher and a machine's app both watch: one of them gets it")
        // an old request (the script inside has given up) is taken and reported as old
        try Data("1\n".utf8).write(to: CodexLogin.requestFile(share))
        XCTAssertGreaterThan(try XCTUnwrap(CodexLogin.take(share, now: Date().addingTimeInterval(600))), CodexLogin.requestLifetime)

        let login = Data(#"{"auth_mode":"chatgpt","tokens":{"access_token":"x"}}"#.utf8)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("auth-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertNil(CodexLogin.login(at: file), "no file")
        try Data("not json".utf8).write(to: file); XCTAssertNil(CodexLogin.login(at: file))
        try login.write(to: file); XCTAssertEqual(CodexLogin.login(at: file), login)

        XCTAssertTrue(CodexLogin.deliver(login, to: share))
        XCTAssertEqual(try Data(contentsOf: CodexLogin.loginFile(share)), login)
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: CodexLogin.loginFile(share).path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o777, 0o600, "the login is the owner's only")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: CodexLogin.folder(share).path), ["codex-auth.json"], "no temporary file left")
        CodexLogin.sweep(share); XCTAssertTrue(FileManager.default.fileExists(atPath: CodexLogin.loginFile(share).path), "just delivered: it waits")
        CodexLogin.sweep(share, now: Date().addingTimeInterval(CodexLogin.loginLifetime + 5))
        XCTAssertFalse(FileManager.default.fileExists(atPath: CodexLogin.loginFile(share).path), "never collected: removed from the share")

        CodexLogin.decline(share, "you chose Don't Copy on the Mac.")
        XCTAssertEqual(try String(contentsOf: CodexLogin.declinedFile(share), encoding: .utf8), "you chose Don't Copy on the Mac.\n")
    }
    func testClaudeInstallReadsTheMachinesStatusAndSaysWhatIsMissing() throws {
        XCTAssertNil(ClaudeStatus.parse(Data("not json".utf8)))
        XCTAssertNil(ClaudeStatus.parse(Data(#"{"version": 1}"#.utf8)), "an answer without Claude Code's state is not one")
        // a machine without Claude Code: nothing to repair without a token, the form's alias is cc1
        let fresh = try XCTUnwrap(ClaudeStatus.parse(Data(#"{"claude": {"installed": false, "version": "", "path": ""}, "default": {"token": false, "account": "", "browser": false}, "accounts": [], "aliases": {"names": [], "loaded": false}, "statusLine": {"script": false, "showsAccount": false, "configured": false, "command": ""}, "apiKey": false}"#.utf8)))
        XCTAssertFalse(fresh.installed); XCTAssertFalse(fresh.hasToken); XCTAssertFalse(fresh.statusLineOK); XCTAssertEqual(fresh.nextAlias, "cc1")
        XCTAssertEqual(fresh.repairs.count, 1, "the status line alone; Claude Code comes with the token's page")
        // set up: a subscription with its alias, plain claude's token, myLinux's status line
        let json = #"{"claude": {"installed": true, "version": "2.1.34", "path": "~/.local/bin/claude"}, "default": {"token": true, "account": "viktor_gmail", "browser": false}, "accounts": [{"alias": "cc1", "account": "viktor_gmail", "token": true, "aliasLine": true}, {"alias": "cc3", "account": "work", "token": true, "aliasLine": true}], "aliases": {"names": ["cc", "cx", "cc1", "cc3", "cc2"], "loaded": true}, "statusLine": {"script": true, "showsAccount": true, "configured": true, "command": "~/.claude/statusline.sh"}, "apiKey": true}"#
        var s = try XCTUnwrap(ClaudeStatus.parse(Data(json.utf8)))
        XCTAssertTrue(s.installed); XCTAssertEqual(s.version, "2.1.34"); XCTAssertEqual(s.accounts.map(\.alias), ["cc1", "cc3"]); XCTAssertEqual(s.defaultAccount, "viktor_gmail")
        XCTAssertTrue(s.hasToken); XCTAssertTrue(s.statusLineOK); XCTAssertTrue(s.apiKey); XCTAssertEqual(s.repairs, [], "everything is in place")
        XCTAssertEqual(s.nextAlias, "cc4", "cc2 is an alias of the user's own there: not taken over")
        // the status line is someone else's script: an update, which says the old one is kept
        s.lineShowsAccount = false
        XCTAssertEqual(s.repairs.count, 1); XCTAssertTrue(s.repairs[0].hasPrefix("Update the status line")); XCTAssertTrue(s.repairs[0].contains("before-mylinux"))
        // another program is the status line: replaced, and named
        s.lineScript = false; s.lineConfigured = false; s.lineCommand = "npx ccusage statusline"
        XCTAssertTrue(s.repairs[0].contains("npx ccusage statusline"))
        // an alias a new terminal would not have; then only the line in ~/.bashrc
        s.accounts[1].aliasLine = false
        XCTAssertEqual(s.aliasesMissing, ["cc3"]); XCTAssertTrue(s.repairs.contains("Add the alias cc3 for new terminals"))
        s.accounts[1].aliasLine = true; s.aliasesLoaded = false
        XCTAssertTrue(s.repairs.contains("Have new terminals load the aliases (~/.bashrc)"))
        // signed in with the browser and no token: not sent to the token's page, and the status line can still be installed
        var browser = fresh; browser.installed = true; browser.browserLogin = true
        XCTAssertFalse(fresh.signedIn); XCTAssertTrue(browser.signedIn); XCTAssertFalse(browser.hasToken)
        XCTAssertEqual(browser.repairs.count, 1); XCTAssertTrue(browser.repairs[0].hasPrefix("Install the status line"))
        // Claude Code gone (the disk was started over) while a token is saved: installing it needs no token
        s.installed = false
        XCTAssertEqual(s.repairs.first, "Install Claude Code")
    }
    func testClaudeInstallChecksTheFormAndSendsOnlyWhatIsAsked() throws {
        let catalog: Set<String> = ["cc", "cx", "gm"]
        var r = ClaudeRequest(alias: "cc1", account: "viktor_gmail", token: "", apiKey: "", makeDefault: true)
        XCTAssertEqual(r.problem(catalogAliases: catalog), "Paste the token from claude setup-token.")
        r.token = " sk-ant-oat01-TESTtestTESTtestTESTtest0123456789\n"
        XCTAssertNil(r.problem(catalogAliases: catalog), "spaces and a line end around a pasted token do not matter")
        XCTAssertEqual(r.cleanToken, "sk-ant-oat01-TESTtestTESTtestTESTtest0123456789")
        for (alias, bad) in [("cc", true), ("cx", true), ("claude", true), ("c c", true), ("1cc", true), ("", true), ("work-1", false), ("_x", false)] {
            r.alias = alias; XCTAssertEqual(r.problem(catalogAliases: catalog) != nil, bad, alias)
        }
        r.alias = "cc1"
        for (account, bad) in [("", true), ("a b", true), ("a'b", true), ("me@work.example", false), ("viktor_gmail", false)] {
            r.account = account; XCTAssertEqual(r.problem(catalogAliases: catalog) != nil, bad, account)
        }
        r.account = "viktor_gmail"
        r.token = "sk-ant-oat01-abc'; touch pwned; 'def0123456789"; XCTAssertNotNil(r.problem(catalogAliases: catalog), "nothing but a token's characters")
        r.token = "sk-ant-oat01-TESTtestTESTtestTESTtest0123456789"
        r.apiKey = "sk-ant-api03-notamylinuxkey"; XCTAssertNotNil(r.problem(catalogAliases: catalog))
        r.apiKey = "mlx_TESTtestTESTtest"; XCTAssertNil(r.problem(catalogAliases: catalog))

        let defaults = ClaudeInstall.defaultAliases(catalog: #"{"aliases": [{"name": "cc", "command": "claude update && claude", "default": true}, {"name": "gm", "command": "gemini --yolo"}], "apps": []}"#)
        XCTAssertEqual(defaults, [["name": "cc", "command": "claude update && claude"]], "the aliases that are on from the start")
        let sent = r.json(defaultAliases: defaults)
        XCTAssertEqual(sent["alias"] as? String, "cc1"); XCTAssertEqual(sent["account"] as? String, "viktor_gmail"); XCTAssertEqual(sent["makeDefault"] as? Bool, true)
        XCTAssertEqual(sent["token"] as? String, r.cleanToken); XCTAssertEqual(sent["apiKey"] as? String, "mlx_TESTtestTESTtest")
        // a repair: no token, so no alias or account either
        let repair = ClaudeRequest().json(defaultAliases: defaults)
        XCTAssertEqual(Set(repair.keys), ["defaultAliases", "statusLine"])
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../server-apps").standardized
        XCTAssertEqual(ClaudeInstall.defaultAliases(catalog: try String(contentsOf: repo.appendingPathComponent("catalog.json"), encoding: .utf8)).map { $0["name"] }, ["cc", "cx"],
                       "the catalog's own: a new aliases file starts with them, as myLinux Apps starts it")
    }
    func testClaudeInstallLeavesItsRequestPrivateAndClearsWhatNobodyTook() throws {
        let share = FileManager.default.temporaryDirectory.appendingPathComponent("claudeinstall-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: share) }
        XCTAssertEqual(ClaudeInstall.prepare(""), "Claude Install needs the machine's share folder (its page › Files & sharing).")
        XCTAssertEqual(ClaudeInstall.prepare(share, script: nil), "The launcher has no copy of the Claude setup script.")
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../server-apps").standardized
        XCTAssertNil(ClaudeInstall.prepare(share, script: try String(contentsOf: repo.appendingPathComponent("claude_setup.py"), encoding: .utf8)))
        let script = try String(contentsOf: ClaudeInstall.folder(share).appendingPathComponent("claude_setup.py"), encoding: .utf8)
        XCTAssertTrue(script.contains("def status()") && script.contains("def apply("), "the script the wizard talks to, from the app itself")
        let id = ClaudeInstall.newID(), other = ClaudeInstall.newID()
        XCTAssertNotEqual(id, other); XCTAssertNotNil(id.range(of: "^[0-9a-f]{16}$", options: .regularExpression), "what the agent and the script take as an id")

        XCTAssertTrue(ClaudeInstall.ask(share, "status", id))
        XCTAssertEqual(try String(contentsOf: ClaudeInstall.commandFile(share, id), encoding: .utf8), "claude status \(id)\n")
        XCTAssertEqual(ClaudeInstall.commandFile(share, id).deletingLastPathComponent().path, share + "/mylinux-tools/control", "where Omarchy's agent looks")
        XCTAssertNil(ClaudeInstall.status(share, id), "no answer yet")
        try Data(#"{"claude": {"installed": true, "version": "2.1.34", "path": "~/.local/bin/claude"}}"#.utf8).write(to: ClaudeInstall.statusFile(share, id))
        XCTAssertEqual(ClaudeInstall.status(share, id)?.version, "2.1.34")

        let r = ClaudeRequest(alias: "cc1", account: "a", token: "sk-ant-oat01-TESTtestTESTtestTESTtest0123456789", apiKey: "", makeDefault: false)
        XCTAssertTrue(ClaudeInstall.writeRequest(r, id: id, share: share))
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: ClaudeInstall.requestFile(share, id).path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o777, 0o600, "the token is the owner's only")
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: ClaudeInstall.requestFile(share, id))) as? [String: Any])
        XCTAssertEqual(sent["token"] as? String, r.token); XCTAssertEqual(sent["alias"] as? String, "cc1")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: ClaudeInstall.folder(share).path).contains { $0.hasSuffix(".tmp") }, "no temporary file left")

        // the steps as the script appends them: the last word on each, in the order they began; a broken line is skipped
        try Data("""
        {"step": "claude", "title": "Installing Claude Code", "state": "running", "detail": ""}
        {"step": "claude", "title": "Installing Claude Code", "state": "done", "detail": "version 2.1.34"}
        {"step": "account", "title": "Saving a as cc1", "state": "running", "detail": ""}
        {"step": "half a li
        """.utf8).write(to: ClaudeInstall.progressFile(share, id))
        XCTAssertEqual(ClaudeInstall.steps(share, id).map { "\($0.step) \($0.state) \($0.detail)" }, ["claude done version 2.1.34", "account running "])
        XCTAssertNil(ClaudeInstall.outcome(share, id))
        try Data(#"{"ok": true, "steps": [{"step": "claude", "title": "Claude Code", "state": "done", "detail": "already installed"}], "alias": "cc1", "account": "a", "makeDefault": false, "status": {"claude": {"installed": true, "version": "2.1.34", "path": ""}}}"#.utf8).write(to: ClaudeInstall.resultFile(share, id))
        let outcome = try XCTUnwrap(ClaudeInstall.outcome(share, id))
        XCTAssertTrue(outcome.ok); XCTAssertEqual(outcome.alias, "cc1"); XCTAssertEqual(outcome.steps.count, 1); XCTAssertEqual(outcome.status?.installed, true)

        // a request nobody took leaves the share after its minute; answers after an hour; the script stays
        ClaudeInstall.sweep(share)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ClaudeInstall.requestFile(share, id).path), "just written: it waits for the machine")
        ClaudeInstall.sweep(share, now: Date().addingTimeInterval(ClaudeInstall.requestLifetime + 5))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ClaudeInstall.requestFile(share, id).path), "the token does not stay in the share")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ClaudeInstall.resultFile(share, id).path))
        ClaudeInstall.sweep(share, now: Date().addingTimeInterval(3700))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: ClaudeInstall.folder(share).path), ["claude_setup.py"])
        // the wizard forgets its own files, the command too when the agent never took it
        XCTAssertTrue(ClaudeInstall.writeRequest(r, id: other, share: share)); XCTAssertTrue(ClaudeInstall.ask(share, "apply", other))
        ClaudeInstall.forget(share, other); ClaudeInstall.forget(share, id)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: ClaudeInstall.folder(share).path), ["claude_setup.py"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: ClaudeInstall.control(share).path), [])
    }
    @MainActor func testClaudeInstallWindowKeepsOneSizeOnEveryPage() {
        // 0.7.61's window followed each page's height and was resized from inside its own layout: on a Retina display the
        // first Continue ended the launcher. The window has one size, and the view no say in it.
        let model = ClaudeInstallModel(machine: ProfileStore.newProfile(named: "O", kind: .omarchy, folder: URL(fileURLWithPath: "/tmp/m/o")))
        let w = ClaudeInstallWindow.window(model, close: {})
        defer { w.close() }
        XCTAssertEqual((w.contentViewController as? NSHostingController<ClaudeInstallView>)?.sizingOptions, [], "the view does not size the window")
        XCTAssertFalse(w.styleMask.contains(.resizable))
        func size() -> NSSize { w.contentRect(forFrameRect: w.frame).size }
        XCTAssertEqual(size(), ClaudeInstallView.size)
        w.orderFront(nil)
        var pages: [ClaudeInstallModel.Page] = [.status, .form, .working, .finished, .unreachable(ClaudeInstallModel.noAnswer), .checking]
        model.status.accounts = (1...12).map { ClaudeStatus.Account(alias: "cc\($0)", account: "a\($0)", token: true, aliasLine: false) }   // more than fits: it scrolls
        pages.append(.status)
        for page in pages {
            model.page = page
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            XCTAssertEqual(size(), ClaudeInstallView.size, "\(page)")
        }
    }
    func testTheLauncherSaysWhatTheMicrophoneIsForAndAsksOnlyAsAnApp() throws {
        // 0.7.62 and before: no usage text and no request, so macOS never granted the microphone and a machine recorded
        // silence. The text and the entitlement are in what build-app.sh writes; the question is put only by the app
        // itself (asking without the text in the running bundle's Info.plist ends the process: not in a test run).
        let mac = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../..").standardized
        let build = try String(contentsOf: mac.appendingPathComponent("build-app.sh"), encoding: .utf8)
        XCTAssertTrue(build.contains("<key>NSMicrophoneUsageDescription</key><string>"), "the launcher's Info.plist")
        let entitlements = try XCTUnwrap(NSDictionary(contentsOf: mac.appendingPathComponent("launcher.entitlements")))
        XCTAssertEqual(entitlements["com.apple.security.device.audio-input"] as? Bool, true, "a release's hardened runtime asks only with it")
        let bundles = try String(contentsOf: mac.appendingPathComponent("../tools/make-app-bundle.sh"), encoding: .utf8)
        XCTAssertEqual(bundles.components(separatedBy: "<key>NSMicrophoneUsageDescription</key><string>").count - 1, 2, "the machines' app and each machine's own")
        XCTAssertFalse(Microphone.canAsk, "the test runner is no app with the text")
        XCTAssertFalse(Microphone.shouldAsk)
    }
    func testKaliIsADesktopStartedLikeArch() {
        let p = ProfileStore.newProfile(named: "K", kind: .kali, folder: URL(fileURLWithPath: "/tmp/m/k"))
        XCTAssertTrue(p.kind.runsDesktop); XCTAssertFalse(p.isServer); XCTAssertEqual(p.kind.title, "Kali Linux")
        XCTAssertEqual(p.script, "run-omarchy.sh")
        XCTAssertEqual(p.appsDisk, "/tmp/m/k/kali.ext4"); XCTAssertEqual(p.shareDir, "/tmp/m/k/Mac")
        XCTAssertEqual(p.grab, "opt", "Xfce is a Ctrl desktop: ⌘ stays with the Mac"); XCTAssertTrue(p.clipboard)
        let env = p.environment(outDir: URL(fileURLWithPath: "/tmp/out"), serialSocket: "/tmp/s", qmpSocket: "/tmp/q")
        XCTAssertEqual(env["DESKTOP"], "kali"); XCTAssertEqual(env["QMP"], "/tmp/q"); XCTAssertEqual(env["DISK"], "/tmp/m/k/kali.ext4")
        XCTAssertEqual(env["APP_ICON"], "tools/icons/machine-kali.icns")
        XCTAssertEqual(ProfileStore.newProfile(named: "A", kind: .arch).environment(outDir: URL(fileURLWithPath: "/tmp/out"), serialSocket: "/tmp/s")["DESKTOP"], "arch")
        XCTAssertNil(ProfileStore.newProfile(named: "O", kind: .omarchy).environment(outDir: URL(fileURLWithPath: "/tmp/out"), serialSocket: "/tmp/s")["DESKTOP"])
        XCTAssertTrue(p.problems.isEmpty, "\(p.problems)")
        XCTAssertEqual(MachineApp.bundleID(p), "dev.mylinux.vm.omarchy.\(p.id.uuidString.lowercased())", "the same QEMU wrapper as Omarchy's and Arch's")
        XCTAssertEqual(p.kind.snippetOS, "kali"); XCTAssertEqual(Profile.recommendedMemoryGB(.kali, macGB: 36), 8)
    }
    func testWindowsIsADesktopWithItsOwnScript() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mylinux-win-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var p = ProfileStore.newProfile(named: "W", kind: .windows, folder: dir)
        XCTAssertTrue(p.kind.runsDesktop); XCTAssertFalse(p.isServer); XCTAssertEqual(p.kind.title, "Windows")
        XCTAssertEqual(p.script, "run-windows.sh")
        XCTAssertEqual(p.appsDisk, dir.appendingPathComponent("windows.raw").path); XCTAssertEqual(p.shareDir, "", "Windows reads no Mac folder")
        XCTAssertEqual(p.grab, "full", "⌘ is the Windows key"); XCTAssertEqual(p.appsSizeGB, 64); XCTAssertTrue(p.clipboard)
        let env = p.environment(outDir: URL(fileURLWithPath: "/tmp/out"), serialSocket: "/tmp/s", qmpSocket: "/tmp/q")
        XCTAssertEqual(env["DISK"], p.appsDisk); XCTAssertEqual(env["DISK_SIZE_GB"], "64"); XCTAssertEqual(env["GRAB"], "full"); XCTAssertEqual(env["QMP"], "/tmp/q")
        XCTAssertNil(env["DESKTOP"]); XCTAssertNil(env["SHARE_DIR"]); XCTAssertNil(env["EXTRA_SHARES"])
        XCTAssertEqual(env["APP_ICON"], "tools/icons/machine-windows.icns")
        XCTAssertTrue(p.problems.isEmpty, "\(p.problems)")
        p.appsSizeGB = 16; XCTAssertFalse(p.problems.isEmpty, "Windows 11 needs more than 16 GB"); p.appsSizeGB = 64
        XCTAssertEqual(MachineApp.bundleID(p), "dev.mylinux.vm.omarchy.\(p.id.uuidString.lowercased())", "the desktops' QEMU wrapper")
        XCTAssertEqual(p.kind.snippetOS, "windows"); XCTAssertEqual(Profile.recommendedMemoryGB(.windows, macGB: 36), 8)
        XCTAssertTrue(Snippets.pasteHint(.windows).contains("Ctrl+V"))
        // installed or not: the firmware's settings say the machine was started, Windows's own word that it is installed
        XCTAssertFalse(p.desktopCreated); XCTAssertFalse(p.windowsInstalled)
        try Data().write(to: dir.appendingPathComponent("vars.fd")); try Data().write(to: URL(fileURLWithPath: p.appsDisk))
        try "mylinux-setup: setup from D:\\mylinux as SYSTEM\r\n".write(to: dir.appendingPathComponent("setup.log"), atomically: true, encoding: .utf8)
        XCTAssertTrue(p.desktopCreated); XCTAssertFalse(p.windowsInstalled, "Setup is still at it")
        try "mylinux-setup: setup from D:\\mylinux as SYSTEM\r\nmylinux-setup: installed\r\n".write(to: dir.appendingPathComponent("setup.log"), atomically: true, encoding: .utf8)
        XCTAssertTrue(p.windowsInstalled, "said by setup.ps1, before run-windows.sh has kept it")
        try FileManager.default.removeItem(at: dir.appendingPathComponent("setup.log"))
        try Data().write(to: dir.appendingPathComponent("installed"))
        XCTAssertTrue(p.windowsInstalled)
        XCTAssertFalse(ProfileStore.newProfile(named: "K", kind: .kali, folder: dir).windowsInstalled)
        // the built-in snippets have a Windows set, each for Windows alone
        let data = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("server-apps/snippets.json"))
        let mine = try XCTUnwrap(Snippets.decode(data)).filter { $0.os.contains("windows") }
        XCTAssertGreaterThanOrEqual(mine.count, 5); XCTAssertTrue(mine.allSatisfy { $0.os == ["windows"] }, "a shell snippet is no PowerShell one")
        XCTAssertTrue(mine.contains { $0.id == "claude-install-windows" && $0.text.contains("claude.ai/install.ps1") })
    }
    func testWindowsInstallStagesComeFromTheMachinesFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mylinux-winstage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = ProfileStore.newProfile(named: "W", kind: .windows, folder: dir)
        let log = dir.appendingPathComponent("setup.log"), disk = URL(fileURLWithPath: p.appsDisk)
        func stage() -> WindowsSetupStage { let s = WindowsSetupStage.of(p); WindowsSetupStage.remember(s, for: p); return s }
        XCTAssertEqual(stage(), .setup, "no disk yet")
        try Data(count: 2048).write(to: disk)
        XCTAssertEqual(stage(), .setup, "an empty disk: Setup is at its questions")
        var gpt = Data(count: 2048); gpt.replaceSubrange(512..<520, with: Data("EFI PART".utf8)); try gpt.write(to: disk)
        XCTAssertEqual(stage(), .installing, "partitioned: Windows is being copied")
        try "mylinux-setup: setup from E:\\mylinux as SYSTEM\r\nmylinux-setup: first-run screens next\r\n".write(to: log, atomically: true, encoding: .utf8)
        XCTAssertEqual(stage(), .firstRun)
        // the machine stopped at those screens and started again: QEMU begins setup.log anew
        try "".write(to: log, atomically: true, encoding: .utf8)
        XCTAssertEqual(stage(), .firstRun, "remembered by the launcher's own mark")
        try "mylinux-setup: installed\r\n".write(to: log, atomically: true, encoding: .utf8)
        XCTAssertEqual(stage(), .done)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("first-run").path), "the mark goes when it has served")
        // a disk made again (the old one deleted): back at Setup's questions, whatever was remembered
        try FileManager.default.removeItem(at: log); try Data().write(to: dir.appendingPathComponent("first-run")); try Data(count: 2048).write(to: disk)
        XCTAssertEqual(stage(), .setup)
        XCTAssertEqual(WindowsSetupStage.allCases.map(\.title).count, 4)
    }
    @MainActor func testTheStepsOpenedByHandStayUntilTheUserClosesThem() {
        XCTAssertFalse(WindowsSetupHelp.closesWithMachine(wasRunning: false, openedByHand: true), "Show the Steps on a stopped machine's page")
        XCTAssertFalse(WindowsSetupHelp.closesWithMachine(wasRunning: false, openedByHand: false), "a tick for a machine that was not running closes nothing")
        XCTAssertFalse(WindowsSetupHelp.closesWithMachine(wasRunning: true, openedByHand: true), "opened by hand: the user's to close")
        XCTAssertTrue(WindowsSetupHelp.closesWithMachine(wasRunning: true, openedByHand: false), "came by themselves: gone with the machine")
    }
    func testWindowsIsToldTheKindOfDisplayItsWindowIsOn() {
        XCTAssertEqual(WindowsDisplay.scale(pixelWidth: 3456, width: 1728), 2, "a Retina display")
        XCTAssertEqual(WindowsDisplay.scale(pixelWidth: 2560, width: 2560), 1)
        XCTAssertEqual(WindowsDisplay.scale(pixelWidth: 3840, width: 2560), 1, "a 4K display at a size between: Windows keeps 100%")
        XCTAssertEqual(WindowsDisplay.scale(pixelWidth: 0, width: 0), 1)
        XCTAssertNil(WindowsDisplay.scale(ofWindowOf: 1), "a process without a window on screen")
    }
    func testWindowsSaysItsOwnMemoryFigure() throws {
        let m = try XCTUnwrap(WindowsDisplay.memory("memory=3350000000/8589934592"))
        XCTAssertEqual(m.used, 3_350_000_000); XCTAssertEqual(m.total, 8_589_934_592)
        for bad in ["memory=", "memory=1", "memory=9/8", "memory=-1/8", "memory=a/b", "scale=2", "memory=1/0"] { XCTAssertNil(WindowsDisplay.memory(bad), bad) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mylinux-winmem-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(WindowsDisplay.keptMemory(dir), "no helper has written anything")
        try "memory=2147483648/8589934592\n".write(to: WindowsDisplay.memoryFile(dir), atomically: true, encoding: .utf8)
        XCTAssertEqual(WindowsDisplay.keptMemory(dir)?.used, 2_147_483_648)
        XCTAssertNil(WindowsDisplay.keptMemory(dir, now: Date().addingTimeInterval(60)), "a figure a minute old is not the machine's now")
    }
    func testWindowsWizardsTalkThroughTheMachinesPort() throws {
        // a command file's words, and nothing else
        XCTAssertEqual(WindowsLink.question("claude status 0123abcd4567ef89\n"), WindowsLink.Question(tool: "claude", what: "status", id: "0123abcd4567ef89"))
        XCTAssertEqual(WindowsLink.question("codex apply 0123abcd")?.tool, "codex")
        for bad in ["claude status", "claude run 0123abcd", "apps status 0123abcd", "claude status 0123ABCD", "claude status ../../x", "claude status 0123abcd extra"] {
            XCTAssertNil(WindowsLink.question(bad), bad)
        }
        // the line for the port: the script, the arguments and the input, each one word
        let q = WindowsLink.Question(tool: "codex", what: "apply", id: "0123abcd4567ef89")
        let words = WindowsLink.askLine(q, script: "Write-Output 'a b'\n", input: Data(#"{"login":"x y"}"#.utf8)).split(separator: " ").map(String.init)
        XCTAssertEqual(words.count, 5); XCTAssertEqual(Array(words[0...1]), ["ask", "0123abcd4567ef89"])
        XCTAssertEqual(Data(base64Encoded: words[2]).map { String(decoding: $0, as: UTF8.self) }, "Write-Output 'a b'\n")
        XCTAssertEqual(Data(base64Encoded: words[3]).map { String(decoding: $0, as: UTF8.self) }, "codex\napply")
        XCTAssertEqual(Data(base64Encoded: words[4]).map { String(decoding: $0, as: UTF8.self) }, #"{"login":"x y"}"#)
        XCTAssertTrue(WindowsLink.askLine(WindowsLink.Question(tool: "claude", what: "status", id: "0123abcd"), script: "x", input: nil).hasSuffix(" -"), "no input is said, not left out")
        // Windows's lines
        func say(_ id: String, _ json: String) -> String { "say \(id) \(Data(json.utf8).base64EncodedString())" }
        if case .said(let id, let kind, let data)? = WindowsLink.answer(say("0123abcd", #"{"kind":"status","data":{"codex":{"installed":true,"version":"0.50.0"}}}"#)) {
            XCTAssertEqual(id, "0123abcd"); XCTAssertEqual(kind, "status"); XCTAssertEqual(CodexStatus.parse(data)?.version, "0.50.0")
        } else { XCTFail("a status line") }
        XCTAssertEqual(WindowsLink.answer("end 0123abcd 1"), .ended(id: "0123abcd", code: 1))
        for bad in ["memory=1/2", "say 0123abcd not-base64!", say("0123abcd", #"{"kind":"shell","data":{}}"#), say("../x", #"{"kind":"status","data":{}}"#), say("0123abcd", "[1]")] {
            XCTAssertNil(WindowsLink.answer(bad), bad)
        }

        // the helper's part, on a folder that stands in for a share
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("mylinux-link-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: link) }
        let files = WindowsLink.Files(base: link, tool: "claude")
        XCTAssertNil(files.prepare(script: "the script"))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: link)[.posixPermissions] as? NSNumber)?.intValue, 0o700, "for the Mac user alone")
        let bridge = WindowsLink.Bridge(link: link)
        let id = "0123abcd4567ef89"
        XCTAssertTrue(files.writeRequest(["token": "sk-ant-oat01-secretsecretsecret", "alias": "cc1"], id: id)); XCTAssertTrue(files.ask("apply", id))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: files.requestFile(id).path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        // nobody inside to take it: the command and the request stay, so the wizard sees that nobody took it
        XCTAssertEqual(bridge.outgoing(), []); XCTAssertTrue(FileManager.default.fileExists(atPath: files.commandFile(id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.requestFile(id).path))
        bridge.heard()
        let sent = bridge.outgoing()
        XCTAssertEqual(sent.count, 1); XCTAssertTrue(sent[0].hasPrefix("ask \(id) "))
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.commandFile(id).path), "taken")
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.requestFile(id).path), "the token is on its way, and nowhere else")
        XCTAssertEqual(bridge.outgoing(), [], "asked once")
        // the script's lines become the files the wizard reads
        bridge.incoming(say(id, #"{"kind":"step","data":{"step":"claude","title":"Installing Claude Code","state":"running","detail":""}}"#))
        bridge.incoming(say(id, #"{"kind":"step","data":{"step":"claude","title":"Installing Claude Code","state":"done","detail":"version 2.1.0"}}"#))
        XCTAssertEqual(ClaudeInstall.steps(link, id).map(\.state), ["done"]); XCTAssertEqual(ClaudeInstall.steps(link, id).first?.detail, "version 2.1.0")
        XCTAssertNil(ClaudeInstall.outcome(link, id))
        bridge.incoming(say(id, #"{"kind":"result","data":{"ok":true,"steps":[],"alias":"cc1","account":"me","makeDefault":false}}"#))
        XCTAssertEqual(ClaudeInstall.outcome(link, id)?.alias, "cc1")
        bridge.incoming("end \(id) 0")
        XCTAssertEqual(ClaudeInstall.outcome(link, id)?.ok, true, "the end does not undo an outcome")
        // lines for a question this helper never asked write nothing
        bridge.incoming(say("ffffffffffffffff", #"{"kind":"result","data":{"ok":true}}"#))
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.resultFile("ffffffffffffffff").path))
        // a setup that ends without an outcome is told as one that failed, after the steps it made
        let id2 = "89abcdef01234567"
        XCTAssertTrue(files.writeRequest([:], id: id2)); XCTAssertTrue(files.ask("apply", id2)); XCTAssertEqual(bridge.outgoing().count, 1)
        bridge.incoming(say(id2, #"{"kind":"step","data":{"step":"git","title":"Git","state":"done","detail":""}}"#))
        bridge.incoming("end \(id2) 1")
        let failed = try XCTUnwrap(ClaudeInstall.outcome(link, id2))
        XCTAssertFalse(failed.ok); XCTAssertEqual(failed.steps.map(\.step), ["git", "setup"]); XCTAssertEqual(failed.steps.last?.state, "failed")
        // a status question has no request, and its answer is the status file
        let id3 = "0011223344556677"
        XCTAssertTrue(files.ask("status", id3)); XCTAssertTrue(bridge.outgoing().first?.hasSuffix(" -") == true)
        bridge.incoming(say(id3, #"{"kind":"status","data":{"system":"windows","git":false,"claude":{"installed":false},"accounts":[{"alias":"cc1","account":"me","token":true,"aliasLine":true}],"aliases":{"names":["cc","cc1"],"loaded":false}}}"#))
        let status = try XCTUnwrap(ClaudeInstall.status(link, id3))
        XCTAssertTrue(status.windows); XCTAssertFalse(status.git); XCTAssertEqual(status.nextAlias, "cc2")
        XCTAssertTrue(status.repairs.contains { $0.contains("Git for Windows") }, "\(status.repairs)")
        XCTAssertTrue(status.repairs.contains { $0.contains("PATH") }, "\(status.repairs)")
        // Claude, the desktop app: installed and pinned with Claude Code, and the pin offered once
        XCTAssertTrue(status.repairs.contains { $0.contains("desktop app") && $0.contains("taskbar starts again") }, "\(status.repairs)")
        func desktop(_ json: String) -> ClaudeStatus? { ClaudeStatus.parse(Data(#"{"system":"windows","claude":{"installed":true},"statusLine":{"script":true,"showsAccount":true,"configured":true},"desktop":\#(json)}"#.utf8)) }
        XCTAssertEqual(desktop(#"{"installed":true,"version":"2.1","pinned":false,"pinnedOnce":false}"#)?.repairs.count, 1, "the pin alone")
        XCTAssertEqual(desktop(#"{"installed":true,"pinned":true,"pinnedOnce":true}"#)?.repairs, [])
        XCTAssertEqual(desktop(#"{"installed":true,"pinned":false,"pinnedOnce":true}"#)?.repairs, [], "taken off the taskbar by hand: not offered again")
        // an old agent's silence: a helper that has heard nothing for a while takes nothing
        XCTAssertFalse(bridge.alive(now: Date().addingTimeInterval(30)))
    }
    func testCodexInstallSaysWhatIsMissingAndSendsTheLoginOnlyWhenAsked() throws {
        let s = try XCTUnwrap(CodexStatus.parse(Data(#"{"system":"windows","codex":{"installed":false,"version":"","path":""},"login":{"file":false,"says":""},"alias":{"cx":false,"loaded":false},"winget":true}"#.utf8)))
        XCTAssertFalse(s.installed); XCTAssertFalse(s.signedIn); XCTAssertEqual(s.repairs.count, 2)
        let there = try XCTUnwrap(CodexStatus.parse(Data(#"{"codex":{"installed":true,"version":"0.50.0","path":"C:\\x\\codex.exe"},"login":{"file":true,"says":"Logged in using ChatGPT"},"alias":{"cx":true,"loaded":true}}"#.utf8)))
        XCTAssertTrue(there.repairs.isEmpty); XCTAssertEqual(there.says, "Logged in using ChatGPT"); XCTAssertTrue(there.winget, "not said: assumed")
        XCTAssertNil(CodexStatus.parse(Data(#"{"claude":{"installed":true}}"#.utf8)), "another tool's answer")
        // a cx from before 0.7.73 starts Codex with its background server, which stops on Windows: it is renewed
        let old = try XCTUnwrap(CodexStatus.parse(Data(#"{"codex":{"installed":true},"login":{"file":true},"alias":{"cx":true,"current":false,"loaded":true}}"#.utf8)))
        XCTAssertTrue(old.cxOld); XCTAssertFalse(old.cx); XCTAssertEqual(old.repairs.count, 1); XCTAssertTrue(old.repairs[0].contains("Renew"), "\(old.repairs)")
        XCTAssertEqual(CodexInstall.request(login: nil)["login"] as? String, "")
        XCTAssertEqual(CodexInstall.request(login: Data(#"{"tokens":{}}"#.utf8))["login"] as? String, #"{"tokens":{}}"#)
        let o = try XCTUnwrap(CodexOutcome.parse(Data(#"{"ok":true,"steps":[{"step":"codex","title":"Codex","state":"done","detail":"x"}],"status":{"codex":{"installed":true}}}"#.utf8)))
        XCTAssertTrue(o.ok); XCTAssertEqual(o.steps.count, 1); XCTAssertEqual(o.status?.installed, true)
        // the script both wizards send is the launcher's own
        let script = try XCTUnwrap(WindowsLink.bundledScript() ?? (try? String(contentsOfFile: #filePath.replacingOccurrences(of: "/mac/Tests/myLinuxTests/LauncherTests.swift", with: "/windows/\(WindowsLink.scriptName)"), encoding: .utf8)))
        for word in ["function Claude-Apply", "function Codex-Apply", "MYLINUX_CLAUDE_ACCOUNT", "'claude status'", "'codex apply'", "--no-daemon", "function Pin-Desktop"] { XCTAssertTrue(script.contains(word), word) }
        // nothing is agreed to on the user's behalf: terms are accepted in one place, the Microsoft Store's for OpenAI's
        // desktop app, and only when the request says the user has accepted them
        let accepting = script.split(separator: "\n").filter { $0.contains("accept-source-agreements") || $0.contains("accept-package-agreements") }
        XCTAssertEqual(accepting.count, 1); XCTAssertTrue(accepting.first?.contains("--source msstore") ?? false)
        XCTAssertTrue(script.contains("(Key $request 'storeTerms') -ne $true"), "without the user's word the app is not installed")
    }
    func testTheCommandLinesWordsAreRead() {
        // sizes are whole gigabytes, however they are written
        XCTAssertEqual(["1", "1g", "1GB", "20gb", "2048m", "4096MB", "8 GiB".replacingOccurrences(of: " ", with: "")].map(CLI.gigabytes), [1, 1, 1, 20, 2, 4, 8])
        for bad in ["0", "0.5", "512m", "1.5g", "-2", "lots", ""] { XCTAssertNil(CLI.gigabytes(bad), bad) }
        // a kind, as people say it
        XCTAssertEqual(["tiny", "Tiny-Alpine", "tinyalpine", "alpine", "DEBIAN", "omarchy", "arch", "kali", "windows", "win11", "mylinux"].map(CLI.kind),
                       [.tiny, .tiny, .tiny, .alpine, .debian, .omarchy, .arch, .kali, .windows, .windows, .mylinux])
        XCTAssertNil(CLI.kind("ubuntu"))
        // what stands alone, what follows a --name, the --flags, and what is after --
        let w = CLI.words(["tiny", "--name", "tester 1", "--memory=1", "--disk", "20gb", "--wait", "--", "uname", "-a", "--name"])
        XCTAssertEqual(w, CLI.Words(plain: ["tiny"], values: ["name": "tester 1", "memory": "1", "disk": "20gb"], flags: ["wait"], rest: ["uname", "-a", "--name"]))
        XCTAssertNil(CLI.words(["tiny", "--name"]), "a --name without its value")
        XCTAssertNil(CLI.words(["--wait=yes"]), "a flag takes no value")
        // a download's progress as an agent can pass it on: the percentage, or the words; never curl's bar
        XCTAssertEqual(CLI.progress("#################                                  24.3%"), "24.3%")
        XCTAssertEqual(CLI.progress("\r######## 51%"), "51%"); XCTAssertEqual(CLI.progress("Unpacking Omarchy…"), "Unpacking Omarchy…")
        XCTAssertEqual(CLI.progress("  Looking for a saved   Debian… "), "Looking for a saved Debian…")
        XCTAssertNil(CLI.progress("#=#=#   -=O=-  ")); XCTAssertNil(CLI.progress(""))
        XCTAssertTrue(CLI.usage.contains("mylinux delete <name> --yes [--stop]"))
        XCTAssertTrue(CLI.usage.contains("mylinux create <kind>"))
    }
    @MainActor func testTheCommandLineMakesAMachineAsAsked() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mylinux-cli-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ProfileStore(file: dir.appendingPathComponent("profiles.json"))
        func ask(_ words: String...) -> CLI.Reply { CLIService.handle(words, store: store) }
        // (names nobody's real machine has: a machine's folder comes from its name, in the launcher's own data folder)
        let one = "clitest-\(UUID().uuidString.prefix(8).lowercased())", two = one + "-build"
        // "install tiny alpine 1gb/20gb called tester1", as the skill turns it into words (not started: no QEMU in a test)
        let made = ask("create", "tiny", "--name", one, "--memory", "1", "--disk", "20gb", "--no-start")
        XCTAssertEqual(made.code, 0, "\(made.json)")
        let p = try XCTUnwrap(store.profiles.first { $0.name == one })
        XCTAssertEqual(p.kind, .tiny); XCTAssertEqual(p.memoryGB, 1); XCTAssertFalse(p.memoryAuto, "a size that was asked for stays"); XCTAssertEqual(p.appsSizeGB, 20)
        XCTAssertTrue((1024...65535).contains(p.sshPort), "a server listens")
        let m = try XCTUnwrap(made.json["machine"] as? [String: Any])
        XCTAssertEqual(m["state"] as? String, "stopped"); XCTAssertEqual(m["ready"] as? Bool, false); XCTAssertEqual((m["ssh"] as? [String: Any])?["user"] as? String, "alpine")
        // sizes left out are the kind's own, and its memory goes on following the Mac's
        XCTAssertEqual(ask("create", "debian", "--name", two, "--no-start").code, 0)
        let d = try XCTUnwrap(store.profiles.first { $0.name == two })
        XCTAssertTrue(d.memoryAuto); XCTAssertEqual(d.appsSizeGB, 32); XCTAssertNotEqual(d.sshPort, p.sshPort, "two servers, two ports")
        // what is refused, in words, and nothing made
        let before = store.profiles.count
        for (words, part) in [(["create", "tiny", "--name", one.uppercased(), "--no-start"], "there already"), (["create", "ubuntu"], "which kind"),
                              (["create", "tiny", "--disk", "2", "--no-start"], "Disk size"), (["create", "tiny", "--memory", "half", "--no-start"], "gigabytes"),
                              (["create", "tiny", "--ssh-port", "\(p.sshPort)", "--no-start"], "\(one)'s"), (["status", "nobody"], "no machine named"),
                              (["delete", one], "--yes"), (["frobnicate"], "no command")] {
            let r = CLIService.handle(words, store: store)
            XCTAssertNotEqual(r.code, 0, "\(words)"); XCTAssertEqual(r.json["ok"] as? Bool, false)
            XCTAssertTrue((r.json["error"] as? String ?? "").contains(part), "\(words): \(r.json)")
        }
        XCTAssertEqual(store.profiles.count, before)
        // a machine is found by its name whatever the capitals, and listed
        XCTAssertEqual(CLIService.find(one.uppercased(), store: store)?.id, p.id)
        XCTAssertEqual((ask("list").json["machines"] as? [[String: Any]])?.compactMap { $0["name"] as? String }.sorted(), [one, two])
        XCTAssertEqual((ask("kinds").json["kinds"] as? [[String: Any]])?.count, 8)
        // erasing is said in full and done only on --yes
        for what in ["machines", "everything"] {
            let r = ask("erase", what)
            XCTAssertEqual(r.code, 2); XCTAssertTrue((r.json["error"] as? String ?? "").contains(one), "what would go is named: \(r.json)")
            XCTAssertTrue((r.json["error"] as? String ?? "").contains("--yes"))
        }
        XCTAssertEqual(ask("erase").code, 2); XCTAssertEqual(ask("erase", "tester1", "--yes").code, 2, "one machine is delete's")
        XCTAssertEqual(store.profiles.count, before, "nothing went")
        // a server's own command is given with the command's path, to be run as it stands
        XCTAssertTrue(((m["ssh"] as? [String: Any])?["command"] as? String ?? "").hasSuffix("mylinux\" ssh \"\(one)\" -- <command>"), "\(m["ssh"] ?? "")")
        // the skill, written where the agents that are on a Mac keep theirs, and nowhere else
        if let text = CLI.Skill.text() {
            let mac = dir.appendingPathComponent("mac-with-claude")
            XCTAssertEqual(CLI.Skill.install(text: text, home: mac).written, [], "no agent there: nothing is made")
            try FileManager.default.createDirectory(at: mac.appendingPathComponent(".claude"), withIntermediateDirectories: true)
            let done = CLI.Skill.install(text: text, home: mac)
            XCTAssertEqual(done.written, [mac.appendingPathComponent(".claude/skills/mylinux/SKILL.md").path]); XCTAssertTrue(done.problems.isEmpty)
            XCTAssertEqual(CLI.Skill.install("codex", text: text, home: mac).written.count, 1, "an agent that is named gets it")
            XCTAssertTrue(text.contains("delete NAME --yes") && text.contains("--stop") && text.contains("`failed`"))
        }
        // deleted on --yes, into the Trash (nothing of it was on disk yet)
        XCTAssertEqual(ask("delete", one, "--yes").code, 0); XCTAssertNil(CLIService.find(one, store: store))
        // and every machine at once
        let erased = ask("erase", "machines", "--yes")
        XCTAssertEqual(erased.code, 0, "\(erased.json)"); XCTAssertEqual(erased.json["erased"] as? [String], [two]); XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertEqual(ask("erase", "machines", "--yes").json["erased"] as? [String], [], "nothing left to erase is not a failure")
        // the skill names this app's own command, and the launcher keeps an installed copy like its own
        if let text = CLI.Skill.text() {
            XCTAssertFalse(text.contains("{{MYLINUX}}")); XCTAssertTrue(text.contains("name: mylinux")); XCTAssertTrue(text.contains("create tiny --name tester1 --memory 1 --disk 20 --wait"))
            let home = dir.appendingPathComponent("home"), file = home.appendingPathComponent(".claude/skills/mylinux/SKILL.md")
            CLI.Skill.refreshInstalled(home: home)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "never put where there is none")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "an older launcher's".write(to: file, atomically: true, encoding: .utf8)
            CLI.Skill.refreshInstalled(home: home)
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), text)
        }
    }
    func testAWindowsInstallThatAnswersItself() throws {
        // the ISO's own language, the Mac's keyboard where Windows has its namesake, a computer name Windows takes
        XCTAssertEqual(["CCCOMA_A64FRE_EN-US_DV9", "CCCOMA_A64FRE_NB-NO_DV9", "ccsa_a64fre_de-de_dv5", "Windows 11", nil].map(WindowsUnattended.language),
                       ["en-US", "nb-NO", "de-DE", "en-US", "en-US"])
        XCTAssertEqual(WindowsUnattended.keyboard(layout: "com.apple.keylayout.Norwegian"), "nb-NO")
        XCTAssertEqual(WindowsUnattended.keyboard(layout: "com.apple.keylayout.Icelandic"), "is-IS")
        XCTAssertEqual(WindowsUnattended.keyboard(layout: "com.apple.keylayout.ABC"), "en-US")
        XCTAssertNil(WindowsUnattended.keyboard(layout: "com.apple.keylayout.Dvorak"), "no namesake: the language's own")
        XCTAssertNil(WindowsUnattended.keyboard(layout: nil))
        XCTAssertTrue(WindowsUnattended.isLocale("nb-NO")); XCTAssertFalse(WindowsUnattended.isLocale("norwegian")); XCTAssertFalse(WindowsUnattended.isLocale("nb_NO"))
        XCTAssertEqual(["wintest", "My Windows 11!", "a-very-long-machine-name-indeed", "42", "", "Ünïcode"].map(WindowsUnattended.computerName),
                       ["WINTEST", "MY-WINDOWS-11", "A-VERY-LONG-MAC", "*", "*", "N-CODE"])
        // an account Windows would refuse is refused here, in words
        XCTAssertNil(WindowsUnattended.problem(user: "viktor", password: ""))
        XCTAssertNil(WindowsUnattended.problem(user: "Viktor K", password: "p<&>\"'w"))
        for bad in ["", "Administrator", "guest", "a/b", "name@host", "ends.", String(repeating: "x", count: 21)] { XCTAssertNotNil(WindowsUnattended.problem(user: bad, password: ""), bad) }
        XCTAssertNotNil(WindowsUnattended.problem(user: "viktor", password: "two\nlines"))
        // the file: every place filled, what was typed escaped, and still XML
        let template = try String(contentsOfFile: #filePath.replacingOccurrences(of: "/mac/Tests/myLinuxTests/LauncherTests.swift", with: "/windows/autounattend-unattended.xml"), encoding: .utf8)
        var a = WindowsUnattended.Answers(user: "Viktor & Co", password: "p<&>\"'w")
        a.edition = .home; a.language = "nb-NO"; a.keyboard = "is-IS"; a.computer = "WINTEST"
        let text = WindowsUnattended.render(template, a)
        XCTAssertFalse(text.contains("{{"))
        XCTAssertTrue(text.contains("<Name>Viktor &amp; Co</Name>")); XCTAssertTrue(text.contains("<Value>p&lt;&amp;&gt;&quot;&apos;w</Value>"))
        XCTAssertTrue(text.contains("<Key>\(WindowsUnattended.Edition.home.key)</Key>")); XCTAssertTrue(text.contains("<AcceptEula>true</AcceptEula>"))
        XCTAssertTrue(text.contains("<UILanguage>nb-NO</UILanguage>")); XCTAssertTrue(text.contains("<InputLocale>is-IS</InputLocale>")); XCTAssertTrue(text.contains("<ComputerName>WINTEST</ComputerName>"))
        XCTAssertNoThrow(try XMLDocument(xmlString: text), "what was typed cannot break the file")
        XCTAssertTrue(text.contains("mylinux\\setup.cmd"), "the drivers and helpers are installed as in any install")
        // written for the Mac user alone, in the machine's folder
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mylinux-unattended-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(WindowsUnattended.write(a, machineFolder: dir, template: template))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: WindowsUnattended.file(dir).path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertNotNil(WindowsUnattended.write(a, machineFolder: dir, template: nil), "a launcher without the template says so")
    }
    @MainActor func testAnUnattendedWindowsIsOnlyMadeOnTheUsersWord() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mylinux-cli-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ProfileStore(file: dir.appendingPathComponent("profiles.json"))
        let name = "clitest-\(UUID().uuidString.prefix(8).lowercased())"
        // Microsoft's licence terms are the user's to accept: without the word for it, nothing is made
        let refused = CLIService.handle(["create", "windows", "--name", name, "--unattended", "--no-start"], store: store)
        XCTAssertEqual(refused.code, 2); XCTAssertTrue((refused.json["error"] as? String ?? "").contains("--accept-microsoft-license"), "\(refused.json)")
        XCTAssertTrue((refused.json["error"] as? String ?? "").contains(WindowsUnattended.licenseTerms))
        XCTAssertTrue(store.profiles.isEmpty)
        // the account's options belong to it, and the other kinds ask nothing
        XCTAssertEqual(CLIService.handle(["create", "windows", "--user", "x", "--no-start"], store: store).code, 2)
        XCTAssertEqual(CLIService.handle(["create", "tiny", "--unattended", "--accept-microsoft-license", "--no-start"], store: store).code, 2)
        XCTAssertEqual(CLIService.handle(["create", "windows", "--unattended", "--accept-microsoft-license", "--user", "Administrator", "--no-start"], store: store).code, 2)
        XCTAssertEqual(CLIService.handle(["create", "windows", "--unattended", "--accept-microsoft-license", "--edition", "enterprise", "--no-start"], store: store).code, 2)
        XCTAssertTrue(store.profiles.isEmpty)
    }
    func testAnOmarchyThatAnswersItsFirstStart() throws {
        // the Mac's keyboard by Omarchy's name for it; --keyboard by that name, or as the unattended Windows takes it
        XCTAssertEqual(OmarchyUnattended.keyboard(layout: "com.apple.keylayout.Norwegian"), "Norwegian")
        XCTAssertEqual(OmarchyUnattended.keyboard(layout: "com.apple.keylayout.ABC"), "English (US)")
        XCTAssertEqual(OmarchyUnattended.keyboard(layout: "com.apple.keylayout.Dvorak"), "English (US, Dvorak)")
        XCTAssertNil(OmarchyUnattended.keyboard(layout: "com.apple.keylayout.Thai"), "no namesake: Omarchy's own, English (US)")
        XCTAssertNil(OmarchyUnattended.keyboard(layout: nil))
        XCTAssertEqual(["icelandic", "is-IS", "English (UK)", "nb-no", " German "].map { OmarchyUnattended.keyboard($0) }, ["Icelandic", "Icelandic", "English (UK)", "Norwegian", "German"])
        XCTAssertNil(OmarchyUnattended.keyboard("klingon"))
        XCTAssertEqual(Set(OmarchyUnattended.layouts.map(\.name)).count, OmarchyUnattended.layouts.count)
        XCTAssertEqual(OmarchyUnattended.layouts.count, 48, "Omarchy's setup form offers 48")
        XCTAssertEqual(["Omarchy", "My Omarchy 2!", "", "ünï"].map(OmarchyUnattended.hostname), ["omarchy", "my-omarchy-2", "omarchy", "n"])
        // what Omarchy's own form would refuse is refused here, in words
        var good = OmarchyUnattended.Answers(user: "viktor", password: "p w=1$x")
        good.keyboard = "Icelandic"; good.hostname = "omtest"; good.timezone = "Atlantic/Reykjavik"; good.fullName = "Viktor K"; good.email = "v@example.com"
        XCTAssertNil(OmarchyUnattended.problem(good))
        func with(_ change: (inout OmarchyUnattended.Answers) -> Void) -> String? { var a = good; change(&a); return OmarchyUnattended.problem(a) }
        for bad in ["", "Viktor", "1abc", "a b", "root", "sddm", String(repeating: "x", count: 33)] { XCTAssertNotNil(with { $0.user = bad }, bad) }
        XCTAssertTrue(with { $0.password = "" }?.contains("--password") ?? false, "Omarchy takes no blank password, and none is made up")
        XCTAssertNotNil(with { $0.password = "two\nlines" }); XCTAssertNotNil(with { $0.keyboard = "Klingon" }); XCTAssertNotNil(with { $0.fullName = "a:b" })
        XCTAssertNotNil(with { $0.email = "nobody" }); XCTAssertNil(with { $0.email = "" }); XCTAssertNil(with { $0.fullName = "" })
        for bad in ["-x", "a b", "", String(repeating: "h", count: 64)] { XCTAssertNotNil(with { $0.hostname = bad }, bad) }
        for bad in ["Mars/Olympus", "../etc/passwd", ""] { XCTAssertNotNil(with { $0.timezone = bad }, bad) }
        // the answers as the gum in the disk reads them: a line each, what was typed kept as typed, and the last "yes"
        let text = OmarchyUnattended.text(good)
        XCTAssertEqual(text.split(separator: "\n").map(String.init),
                       ["keyboard=Icelandic", "username=viktor", "password=p w=1$x", "fullname=Viktor K", "email=v@example.com", "hostname=omtest", "timezone=Atlantic/Reykjavik", "confirm=yes"])
        XCTAssertTrue(OmarchyUnattended.text(with2(good) { $0.fullName = "" }).contains("fullname=\n"), "skipped is an answer too")
        // kept for the Mac user alone until the machine's first start, with the word that it sets itself up
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mylinux-omarchy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = ProfileStore.newProfile(named: "O", kind: .omarchy, folder: dir)
        XCTAssertEqual(p.machineFolder.path, dir.path); XCTAssertEqual(OmarchyUnattended.stage(p), .none)
        XCTAssertNil(OmarchyUnattended.write(good, machineFolder: dir))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: OmarchyUnattended.file(dir).path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try String(contentsOf: OmarchyUnattended.file(dir), encoding: .utf8), text)
        XCTAssertEqual(OmarchyUnattended.stage(p), .settingUp)
        XCTAssertFalse((try String(contentsOf: OmarchyUnattended.marker(dir), encoding: .utf8)).contains("p w"), "the word names nothing secret")
        try "asked\n".write(to: OmarchyUnattended.marker(dir), atomically: true, encoding: .utf8)       // run-omarchy.sh, when the answers did not go in
        XCTAssertEqual(OmarchyUnattended.stage(p), .asking)
        XCTAssertEqual(OmarchyUnattended.stage(ProfileStore.newProfile(named: "A", kind: .arch, folder: dir)), .none, "Omarchy's alone")
        // a machine deleted before its first start: its answers do not go to the Trash with it
        try "x".write(to: dir.appendingPathComponent("autounattend.xml"), atomically: true, encoding: .utf8)
        try "x".write(to: dir.appendingPathComponent("omarchy.ext4"), atomically: true, encoding: .utf8)
        ProfileStore.forgetAnswers(in: dir)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), ["first-start.unattended", "omarchy.ext4"])
    }
    private func with2(_ a: OmarchyUnattended.Answers, _ change: (inout OmarchyUnattended.Answers) -> Void) -> OmarchyUnattended.Answers { var b = a; change(&b); return b }
    @MainActor func testAnOmarchyWithAnswersIsRefusedInWords() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mylinux-cli-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ProfileStore(file: dir.appendingPathComponent("profiles.json"))
        let name = "clitest-\(UUID().uuidString.prefix(8).lowercased())", start = ["create", "omarchy", "--name", name, "--no-start"]
        // the password is the user's: without one nothing is made, and none is made up
        for (words, part) in [(["--unattended"], "--password"), (["--unattended", "--password", "x", "--keyboard", "klingon"], "--keyboard"),
                              (["--unattended", "--password", "x", "--user", "root"], "own account names"),
                              (["--unattended", "--password", "x", "--timezone", "Mars/Olympus"], "time zone"),
                              (["--unattended", "--password", "x", "--hostname", "-x"], "host name"),
                              (["--unattended", "--password", "x", "--edition", "pro"], "Windows's"),
                              (["--password", "x"], "--unattended"), (["--timezone", "UTC"], "--unattended")] {
            let r = CLIService.handle(start + words, store: store)
            XCTAssertEqual(r.code, 2, "\(words)"); XCTAssertTrue((r.json["error"] as? String ?? "").contains(part), "\(words): \(r.json)")
        }
        let r = CLIService.handle(["create", "windows", "--unattended", "--accept-microsoft-license", "--hostname", "x", "--no-start"], store: store)
        XCTAssertEqual(r.code, 2); XCTAssertTrue((r.json["error"] as? String ?? "").contains("Omarchy's"), "\(r.json)")
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertTrue(CLI.usage.contains("omarchy: --unattended --password PW"))
    }
    func testTheDialogOfANewMachineTakesItsFirstStartAnswers() throws {
        // as on this Mac: its user name when the kind takes it, its keyboard by the kind's name for it, no password
        var o = FirstStartForm.suggested(.omarchy, name: "Omarchy", macUser: "Viktor", macLayout: "com.apple.keylayout.Norwegian")
        XCTAssertEqual(o.user, "viktor"); XCTAssertEqual(o.keyboard, "Norwegian"); XCTAssertTrue(o.answered); XCTAssertEqual(o.password, "")
        XCTAssertEqual(FirstStartForm.suggested(.omarchy, name: "O", macUser: "root", macLayout: nil).user, "", "a name Omarchy refuses is not suggested")
        var w = FirstStartForm.suggested(.windows, name: "Windows", macUser: "Viktor", macLayout: "com.apple.keylayout.Norwegian")
        XCTAssertEqual(w.user, "Viktor"); XCTAssertEqual(w.keyboard, "nb-NO"); XCTAssertFalse(w.acceptsLicense, "the licence is the user's to tick")
        XCTAssertEqual(FirstStartForm.suggested(.windows, name: "W", macUser: "guest", macLayout: nil).keyboard, "en-US")
        // Omarchy: a password, typed twice, of the user's own; then it can be made
        XCTAssertEqual(o.verdict(taken: []), .waiting("Choose a password: Omarchy takes no account without one."))
        o.password = "p w=1$x"
        XCTAssertEqual(o.verdict(taken: []), .waiting("Type the password once more."))
        o.again = "p w=1"; XCTAssertEqual(o.verdict(taken: []), .wrong("The two passwords are not the same."))
        o.again = o.password; XCTAssertEqual(o.verdict(taken: []), .ready)
        // the name of a new machine: there, in bounds, nobody's; a machine that is there already is not named again
        XCTAssertEqual(o.verdict(taken: ["omarchy"]), .wrong("A machine named Omarchy is there already.")); XCTAssertEqual(o.verdict(taken: nil), .ready)
        var unnamed = o; unnamed.name = "  "; XCTAssertEqual(unnamed.verdict(taken: []), .waiting("Give the machine a name.")); XCTAssertEqual(unnamed.verdict(taken: nil), .ready)
        var slash = o; slash.name = "a/b"; if case .wrong = slash.verdict(taken: []) {} else { XCTFail("a name with a slash") }
        // what Omarchy's form would refuse is said as a sentence
        var bad = o; bad.user = "Root User"
        if case .wrong(let why) = bad.verdict(taken: []) { XCTAssertTrue(why.hasPrefix("The account's name") && why.hasSuffix(".")) } else { XCTFail("a user name Omarchy refuses") }
        bad = o; bad.hostname = "-x"; if case .wrong = bad.verdict(taken: []) {} else { XCTFail("a host name Omarchy refuses") }
        // the answers: the host name from the machine's name unless one is typed, what was typed trimmed
        o.name = "My Omarchy 2"; o.fullName = " Viktor K "; o.timezone = "Atlantic/Reykjavik"
        var a = o.omarchy()
        XCTAssertEqual(a.hostname, "my-omarchy-2"); XCTAssertEqual(a.fullName, "Viktor K"); XCTAssertEqual(a.password, "p w=1$x"); XCTAssertEqual(a.keyboard, "Norwegian")
        o.hostname = "box"; a = o.omarchy(); XCTAssertEqual(a.hostname, "box"); XCTAssertNil(OmarchyUnattended.problem(a))
        // asked in the machine's window instead: nothing of the answers is checked
        var asked = FirstStartForm.suggested(.omarchy, name: "Omarchy", macUser: "viktor", macLayout: nil); asked.answered = false
        XCTAssertEqual(asked.verdict(taken: []), .ready)
        // Windows: no password is an answer, and Microsoft's licence terms are accepted by the user's own tick
        if case .waiting(let what) = w.verdict(taken: []) { XCTAssertTrue(what.contains("licence terms")) } else { XCTFail("the licence is not accepted yet") }
        w.acceptsLicense = true; XCTAssertEqual(w.verdict(taken: []), .ready)
        w.password = "secret"; XCTAssertEqual(w.verdict(taken: []), .waiting("Type the password once more.")); w.again = "secret"; XCTAssertEqual(w.verdict(taken: []), .ready)
        w.user = "Administrator"; if case .wrong = w.verdict(taken: []) {} else { XCTFail("one of Windows's own account names") }
        w.user = "Viktor"; w.edition = .home; w.name = "My Windows 11!"
        let wa = w.windows()
        XCTAssertEqual(wa.user, "Viktor"); XCTAssertEqual(wa.edition, .home); XCTAssertEqual(wa.keyboard, "nb-NO"); XCTAssertEqual(wa.computer, "MY-WINDOWS-11")
        XCTAssertTrue(FirstStartSheet.asks(.omarchy) && FirstStartSheet.asks(.windows)); XCTAssertFalse(FirstStartSheet.asks(.arch) || FirstStartSheet.asks(.tiny))

        // kept in the machine's folder until its first start, for the Mac user alone; forgotten when the form says to ask
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mylinux-firststart-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let om = ProfileStore.newProfile(named: "O", kind: .omarchy, folder: dir.appendingPathComponent("o"))
        XCTAssertNil(o.apply(to: om)); XCTAssertEqual(OmarchyUnattended.read(om.machineFolder), a); XCTAssertEqual(OmarchyUnattended.stage(om), .settingUp)
        // the dialog opened again for it: what was answered, never the password
        let again = FirstStartSheet.start(.existing(om))
        XCTAssertEqual(again.hostname, "box"); XCTAssertEqual(again.timezone, "Atlantic/Reykjavik"); XCTAssertEqual(again.password, ""); XCTAssertEqual(again.again, "")
        XCTAssertNil(asked.apply(to: om)); XCTAssertNil(OmarchyUnattended.read(om.machineFolder)); XCTAssertEqual(OmarchyUnattended.stage(om), .none)

        // Windows: the answers wait for the first start, when the ISO says its language
        let template = try String(contentsOfFile: #filePath.replacingOccurrences(of: "/mac/Tests/myLinuxTests/LauncherTests.swift", with: "/windows/autounattend-unattended.xml"), encoding: .utf8)
        let win = ProfileStore.newProfile(named: "W", kind: .windows, folder: dir.appendingPathComponent("w"))
        XCTAssertFalse(WindowsUnattended.asked(win)); XCTAssertNil(WindowsUnattended.prepare(win, isoLabel: "CCCOMA_A64FRE_NB-NO_DV9", template: template), "nothing kept, nothing done")
        XCTAssertNil(w.apply(to: win)); XCTAssertEqual(WindowsUnattended.kept(win.machineFolder), wa); XCTAssertTrue(WindowsUnattended.asked(win)); XCTAssertFalse(WindowsUnattended.inProgress(win))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: WindowsUnattended.pending(win.machineFolder).path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(FirstStartSheet.start(.existing(win)).edition, .home); XCTAssertEqual(FirstStartSheet.start(.existing(win)).password, "")
        XCTAssertNotNil(WindowsUnattended.prepare(win, isoLabel: nil, template: nil), "a launcher without the answer file's template does not start the install")
        XCTAssertNotNil(WindowsUnattended.kept(win.machineFolder), "and keeps the answers")
        XCTAssertNil(WindowsUnattended.prepare(win, isoLabel: "CCCOMA_A64FRE_NB-NO_DV9", template: template))
        XCTAssertNil(WindowsUnattended.kept(win.machineFolder)); XCTAssertTrue(WindowsUnattended.inProgress(win)); XCTAssertTrue(WindowsUnattended.asked(win))
        let xml = try String(contentsOf: WindowsUnattended.file(win.machineFolder), encoding: .utf8)
        XCTAssertTrue(xml.contains("<UILanguage>nb-NO</UILanguage>")); XCTAssertTrue(xml.contains("<Name>Viktor</Name>")); XCTAssertTrue(xml.contains("<Value>secret</Value>"))
        XCTAssertTrue(xml.contains("<Key>\(WindowsUnattended.Edition.home.key)</Key>"))
        // asked in Windows Setup after all, before the start: the kept answers go
        XCTAssertNil(w.apply(to: win)); var no = w; no.answered = false
        XCTAssertNil(no.apply(to: win)); XCTAssertNil(WindowsUnattended.kept(win.machineFolder))
        // and none of them goes to the Trash with a machine
        XCTAssertNil(w.apply(to: win)); ProfileStore.forgetAnswers(in: win.machineFolder)
        XCTAssertNil(WindowsUnattended.kept(win.machineFolder)); XCTAssertFalse(WindowsUnattended.inProgress(win))
    }
    func testATokenIsNamedNeverGiven() throws {
        // mylinux claude NAME --install --token-file FILE --token-name NAME: the launcher reads the entry itself
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mylinux-secret-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("tokens").path, made = "sk-ant-oat01-MADEupMADEupMADEupMADEup0123456789"
        try """
            # my tokens
            OTHER=one
            export CLAUDE_CODE_TOKEN_GMAIL = "\(made)"
            QUOTED='two words'
            EMPTY=
            TWICE=a
            TWICE=b
            """.write(toFile: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(AgentCommands.secret(named: "CLAUDE_CODE_TOKEN_GMAIL", inFile: file).value, made)
        XCTAssertEqual(AgentCommands.secret(named: "OTHER", inFile: file).value, "one"); XCTAssertEqual(AgentCommands.secret(named: "QUOTED", inFile: file).value, "two words")
        for (name, part) in [("MISSING", "no entry named MISSING"), ("EMPTY", "is empty"), ("TWICE", "2 times"), ("bad name", "letters, digits and _")] {
            let r = AgentCommands.secret(named: name, inFile: file)
            XCTAssertNil(r.value, name); XCTAssertTrue(r.problem?.contains(part) ?? false, "\(name): \(r.problem ?? "")")
            XCTAssertFalse(r.problem?.contains(made) ?? true, "never a value in what is said")
        }
        XCTAssertTrue(AgentCommands.secret(named: "X", inFile: dir.appendingPathComponent("nowhere").path).problem?.contains("cannot be read") ?? false)
        // Codex in a Linux machine rides in the request of Claude Code's script, with or without its steps
        var r = ClaudeRequest(); r.claude = false; r.codexInstall = true; r.codexLogin = "{\"tokens\": {}}"
        let j = r.json(defaultAliases: [])
        XCTAssertEqual(j["claude"] as? Bool, false); XCTAssertEqual(j["statusLine"] as? Bool, false); XCTAssertNil(j["token"])
        XCTAssertEqual((j["codex"] as? [String: Any])?["install"] as? Bool, true); XCTAssertEqual((j["codex"] as? [String: Any])?["login"] as? String, "{\"tokens\": {}}")
        XCTAssertNil(ClaudeRequest().json(defaultAliases: [])["codex"], "a request of the wizard's is as it was"); XCTAssertNil(ClaudeRequest().json(defaultAliases: [])["claude"])
        let linux = try XCTUnwrap(ClaudeStatus.parse(Data(#"{"claude": {"installed": true, "version": "2.1.0", "path": "~/.local/bin/claude"}, "codex": {"installed": true, "version": "0.200.1", "login": true, "cx": true}}"#.utf8)))
        XCTAssertTrue(linux.codexInstalled && linux.codexLogin && linux.codexCx); XCTAssertEqual(linux.codexVersion, "0.200.1")
        // Windows: OpenAI's desktop app is asked for in words, and the Store's terms are the user's
        XCTAssertNil(CodexInstall.request(login: nil)["desktop"])
        let asked = CodexInstall.request(login: nil, desktop: true, storeTerms: false)
        XCTAssertEqual(asked["desktop"] as? Bool, true); XCTAssertEqual(asked["storeTerms"] as? Bool, false)
        let win = try XCTUnwrap(CodexStatus.parse(Data(#"{"codex": {"installed": true, "version": "0.161.0"}, "desktop": {"installed": true, "version": "1.2.3.0"}}"#.utf8)))
        XCTAssertTrue(win.desktopInstalled); XCTAssertEqual(win.desktopVersion, "1.2.3.0")
    }
    @MainActor func testClaudeAndCodexFromTheCommandLineAreRefusedInWords() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mylinux-cli-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ProfileStore(file: dir.appendingPathComponent("profiles.json"))
        let name = "clitest-\(UUID().uuidString.prefix(8).lowercased())"
        XCTAssertEqual(CLIService.handle(["create", "omarchy", "--name", name, "--no-start"], store: store).code, 0)
        XCTAssertEqual(CLIService.handle(["create", "tiny", "--name", name + "-s", "--no-start"], store: store).code, 0)
        for (words, part) in [(["claude"], "which machine"), (["claude", "nobody"], "no machine named"), (["codex", name + "-s"], "Omarchy or a Windows machine"),
                              (["claude", name], "is not running"), (["codex", name, "--install", "--login-from-mac"], "is not running")] {
            let r = CLIService.handle(words, store: store)
            XCTAssertNotEqual(r.code, 0, "\(words)"); XCTAssertTrue((r.json["error"] as? String ?? "").contains(part), "\(words): \(r.json)")
        }
        XCTAssertEqual(CLI.words(["om", "--install", "--token-file", "~/t", "--token-name", "N", "--account", "gmail"])?.values["token-name"], "N")
        XCTAssertTrue(CLI.usage.contains("mylinux claude <name> --install") && CLI.usage.contains("--login-from-mac"))
        for n in [name, name + "-s"] { XCTAssertEqual(CLIService.handle(["delete", n, "--yes"], store: store).code, 0) }
    }
    func testTinyAlpineIsAServerThatIsAlpineInside() {
        let p = ProfileStore.newProfile(named: "T", kind: .tiny, folder: URL(fileURLWithPath: "/tmp/m/t"))
        XCTAssertTrue(p.isServer); XCTAssertFalse(p.kind.runsDesktop)
        XCTAssertEqual(p.script, "run-tiny.sh"); XCTAssertEqual(p.kind.title, "Tiny Alpine")
        XCTAssertEqual(p.appsDisk, "/tmp/m/t/tiny.raw"); XCTAssertEqual(p.shareDir, "/tmp/m/t/Mac")
        // Alpine's account, install script and snippets; its own first-start file (no cloud-init seed)
        XCTAssertEqual(p.kind.serverUser, "alpine"); XCTAssertEqual(p.terminalProfile.username, "alpine")
        XCTAssertEqual(p.kind.installScriptName, "alpine_install.sh"); XCTAssertEqual(p.kind.snippetOS, "alpine")
        XCTAssertEqual(p.kind.firstStartFile, "boot/Image"); XCTAssertEqual(Profile.Kind.alpine.firstStartFile, "seed.iso")
        XCTAssertEqual(Profile.Kind.alpine.installScriptName, "alpine_install.sh"); XCTAssertEqual(Profile.Kind.debian.installScriptName, "debian_install.sh")
        XCTAssertEqual(Profile.Kind.debian.serverUser, "debian"); XCTAssertEqual(Profile.Kind.debian.snippetOS, "debian")
        XCTAssertEqual(MachineApp.bundleID(p), "dev.mylinux.machine.\(p.id.uuidString.lowercased())")
        XCTAssertEqual([8, 16, 36].map { Profile.recommendedMemoryGB(.tiny, macGB: $0) }, [2, 2, 4])
        XCTAssertTrue(p.problems.isEmpty, "\(p.problems)")
    }
    func testMachinesOfARetiredKindAreLeftOutNotOpenedAsMyLinux() throws {
        let json = #"[{"kind":"puppy","name":"P","appsDisk":"/d/p/puppy.ext4","shareDir":""},{"kind":"debian","name":"D","appsDisk":"/d/d","shareDir":"","sshPort":2223}]"#
        let list = try XCTUnwrap(ProfileStore.decodeList(Data(json.utf8)))
        XCTAssertEqual(list.map(\.name), ["D"]); XCTAssertEqual(list[0].kind, .debian); XCTAssertEqual(list[0].sshPort, 2223)
        XCTAssertEqual(ProfileStore.decodeList(Data(#"[{"kind":"puppy","name":"P","appsDisk":"/d/p","shareDir":""}]"#.utf8))?.count, 0)
        XCTAssertEqual(ProfileStore.decodeList(Data(#"[{"kind":"omarchy","name":"O","appsDisk":"/d/o","shareDir":""}]"#.utf8))?.first?.kind, .omarchy)
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
    func testMachineAppsAreNamedAfterTheMachine() {
        var p = ProfileStore.newProfile(named: "Build/box: 2", kind: .debian)
        XCTAssertEqual(MachineApp.appName(p), "Build-box- 2", "no slash or colon in a bundle name")
        XCTAssertEqual(MachineApp.bundleID(p), "dev.mylinux.machine.\(p.id.uuidString.lowercased())")
        p.name = "..."
        XCTAssertEqual(MachineApp.appName(p), "Debian", "an empty name falls back to the kind")
        let desk = ProfileStore.newProfile(named: "Work", kind: .omarchy)
        XCTAssertEqual(MachineApp.bundleID(desk), "dev.mylinux.vm.omarchy.\(desk.id.uuidString.lowercased())")
        XCTAssertEqual(desk.appBundleEnvironment["APP_NAME"], "Work")
        XCTAssertEqual(desk.appBundleEnvironment["APP_ICON"], "tools/icons/machine-omarchy.icns")
        XCTAssertEqual(desk.environment(outDir: URL(fileURLWithPath: "/tmp"), serialSocket: "/tmp/s")["APP_ID"], desk.id.uuidString.lowercased())
        XCTAssertFalse(MachineApp.active, "the tests are the launcher")
    }

    func testTheMachineAppMirrorsTheLaunchersRunner() {
        let id = UUID()
        let app = Runner(profileID: id)
        let t = Date().timeIntervalSince1970
        app.mirror(["id": id.uuidString, "state": "running", "startedAt": t - 14, "readyAt": t, "sshReady": true, "mountingCloud": false])
        XCTAssertEqual(app.state, .running)
        XCTAssertEqual(app.readyIn ?? 0, 14, accuracy: 0.01)
        XCTAssertTrue(app.sshReady)
        app.mirrorRestartAsked()
        XCTAssertNil(app.readyAt, "a restart asked in the app counts from the ask")
        app.mirror(["id": id.uuidString, "state": "stopping", "startedAt": t - 14, "readyAt": t])
        XCTAssertGreaterThan(app.restartBeganAt ?? .distantPast, Date(timeIntervalSince1970: t), "the ask is kept until the launcher's own restart begins")
        app.mirror(["id": id.uuidString, "state": "failed", "why": "no disk"])
        XCTAssertEqual(app.state, .failed("no disk"))
        XCTAssertEqual(Runner(profileID: id).report["state"] as? String, "stopped")
    }

    func testPaletteFindsInstalledProgramsByName() {
        let all = CommandPalette.entries(programs: ["claude", "btop", "bash", "clang", "claude-helper"], alpine: false)
        XCTAssertEqual(CommandPalette.search("cla", in: all).first?.title, "Claude Code", "a named app before plain programs")
        XCTAssertEqual(CommandPalette.search("cla", in: all).first?.command, "claude")
        XCTAssertTrue(CommandPalette.search("cla", in: all).contains { $0.command == "clang" }, "other programs are found too")
        XCTAssertFalse(CommandPalette.search("", in: all).contains { $0.source == .program }, "plain programs only once something is typed")
        XCTAssertTrue(CommandPalette.search("", in: all).contains { $0.title == "btop" })
        XCTAssertFalse(all.contains { $0.title == "Codex" }, "only what is installed gets a name")
        XCTAssertTrue(all.contains { $0.command == "cc" }, "the cc alias when Claude Code is installed")
        XCTAssertFalse(all.contains { $0.command == "cx" }, "no cx without Codex")
        XCTAssertFalse(all.contains { $0.command.contains("tailscale") }, "no Tailscale commands without it")
        XCTAssertTrue(CommandPalette.entries(programs: nil, alpine: false).contains { $0.command == "cx" }, "all of them while the list is loading")
        XCTAssertEqual(CommandPalette.search("update", in: all).first?.command, "sudo apt update && sudo apt upgrade -y")
        XCTAssertTrue(CommandPalette.subsequence("cc", of: "claude code"))
        XCTAssertFalse(CommandPalette.subsequence("cx", of: "claude"))
        let alpine = CommandPalette.entries(programs: nil, alpine: true)
        XCTAssertEqual(CommandPalette.search("install", in: alpine).first?.command, "doas apk add ")
        XCTAssertEqual(CommandPalette.search("install", in: alpine).first?.run, false, "left on the prompt for the name")
    }

    func testCmdSpaceIsOnlyTakenForServerWindows() {
        XCTAssertNil(SpaceHotkey.target(front: nil))
        XCTAssertNil(SpaceHotkey.target(front: NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first), "Spotlight's elsewhere")
        XCTAssertTrue(SpaceHotkey.enabled || UserDefaults.standard.object(forKey: SpaceHotkey.settingKey) != nil, "on unless turned off")
    }

    func testMachineStatusAndNumbersRead() {
        var p = ProfileStore.newProfile(named: "Work box", kind: .alpine)
        p.memoryGB = 2; p.sshPort = 2293
        let r = Runner(profileID: p.id)
        XCTAssertEqual(MachineStatus.text(p, r), "Stopped · 2 GB · port 2293")
        r.mirror(["state": "running", "startedAt": Date().timeIntervalSince1970 - 14, "readyAt": Date().timeIntervalSince1970])
        XCTAssertEqual(MachineStatus.text(p, r), "Running · ready in 14 s")
        XCTAssertTrue(MachineStatus.running(r))
        XCTAssertEqual(Fmt.percent(0.244), "24%")
        XCTAssertEqual(Fmt.gb(1.5 * 1_073_741_824), "1.5")
        XCTAssertEqual(Fmt.gb(312 * 1_073_741_824), "312")
        XCTAssertEqual(Fmt.size(995e9), "995 GB")
        XCTAssertEqual(Fmt.size(312e6), "312 MB", "under a gigabyte in MB")
        XCTAssertEqual(Fmt.size(0), "0 MB")
        XCTAssertEqual(Fmt.size(2e12), "2 TB")
    }

    func testStatsReadTheQemuCommandLine() {
        XCTAssertEqual(MachineStats.smp("qemu-system-aarch64 -name x -smp 4 -m 2G"), 4)
        XCTAssertEqual(MachineStats.smp("qemu -smp cpus=6,cores=6 -m 8G"), 6)
        XCTAssertNil(MachineStats.smp("qemu -m 2G"))
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("stats-\(UUID().uuidString).img")
        FileManager.default.createFile(atPath: f.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: f) }
        let h = try! FileHandle(forWritingTo: f); try! h.truncate(atOffset: 1 << 30); try! h.close()
        let d = MachineStats.fileDisk(f.path)
        XCTAssertEqual(d?.total, Double(1 << 30))
        XCTAssertLessThan(d?.used ?? 1e9, 1e6, "a sparse disk file takes almost nothing until written")
    }

    func testLinksNameTheMachine() throws {
        XCTAssertEqual(RemoteLink.parse(URL(string: "mylinux://vnc/omarchy%20imac")!), .remote(kind: .vnc, name: "omarchy imac"))
        XCTAssertEqual(RemoteLink.parse(URL(string: "mylinux://ssh/build-box/")!), .remote(kind: .ssh, name: "build-box"))
        XCTAssertEqual(RemoteLink.parse(URL(string: "mylinux-launcher://start")!), .start)
        let id = UUID()
        XCTAssertEqual(RemoteLink.parse(URL(string: "mylinux-launcher://start/\(id.uuidString.lowercased())")!), .startMachine(id), "a machine's own app in the Dock")
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
        XCTAssertEqual(list[2].kind, .vnc, "older files have no type"); XCTAssertEqual(list[2].keyboard, .all)
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
    func testAVncServerThatNeverAnswersEndsInAMessage() throws {
        // a server that takes the connection and says nothing (a stuck wayvnc): not "Connecting…" for ever
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vnclog-\(UUID().uuidString)")
        VncLog.directory = dir
        defer { try? FileManager.default.removeItem(at: dir) }
        let fd = socket(AF_INET, SOCK_STREAM, 0); XCTAssertGreaterThanOrEqual(fd, 0); defer { close(fd) }
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_addr.s_addr = inet_addr("127.0.0.1"); addr.sin_port = 0
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        Darwin.listen(fd, 4)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        var p = RemoteProfile(kind: .vnc); p.name = "silent"; p.host = "127.0.0.1"; p.port = Int(UInt16(bigEndian: addr.sin_port))
        let c = VncConnection(profile: p)
        let failed = expectation(description: "failed")
        var message = ""
        c.onState = { st in if case .failed(let m) = st { message = m; failed.fulfill() } }
        c.start()
        wait(for: [failed], timeout: 20)
        XCTAssertTrue(message.contains("did not answer within 10 seconds"), message)
    }
    func testVncDesktopsSendEveryKeyByDefaultOnceMoved() throws {
        XCTAssertEqual(RemoteProfile(kind: .vnc).keyboard, .all)
        XCTAssertEqual(RemoteProfile(kind: .ssh).keyboard, .mac)
        let file = try tempDir().appendingPathComponent("remote.json")
        var old = RemoteProfile(kind: .vnc); old.name = "msi"; old.keyboard = .optionSuper
        var mac = RemoteProfile(kind: .vnc); mac.name = "imac"; mac.keyboard = .mac
        let ssh = RemoteProfile(kind: .ssh)
        try JSONEncoder().encode([old, mac, ssh]).write(to: file)
        let store = RemoteStore(file: file)
        XCTAssertEqual(store.profiles.map(\.keyboard), [.all, .mac, .mac], "the old default moves; a choice of its own stays")
        var again = store.profiles[0]; again.keyboard = .optionSuper; store.update(again)
        XCTAssertEqual(RemoteStore(file: file).profiles[0].keyboard, .optionSuper, "only once: a later choice stays")
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

final class VncLogTests: XCTestCase {
    /// A server that refuses with a reason: the failure says it, and logs/vnc.log has it.
    func testRefusalReasonReachesTheMessage() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vnclog-\(UUID().uuidString)")
        VncLog.directory = dir
        defer { try? FileManager.default.removeItem(at: dir) }
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_addr.s_addr = inet_addr("127.0.0.1"); addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = Darwin.bind(listener, $0, len); _ = getsockname(listener, $0, &len) } }
        listen(listener, 1)
        let port = Int(UInt16(bigEndian: addr.sin_port))
        let reason = "Too many authentication failures"
        Thread.detachNewThread {
            let c = accept(listener, nil, nil)
            _ = "RFB 003.008\n".withCString { Darwin.write(c, $0, 12) }
            var buf = [UInt8](repeating: 0, count: 12); _ = read(c, &buf, 12)
            var reply: [UInt8] = [0] + withUnsafeBytes(of: UInt32(reason.utf8.count).bigEndian, Array.init) + Array(reason.utf8)
            _ = Darwin.write(c, &reply, reply.count)
            close(c); close(listener)
        }
        var p = RemoteProfile(kind: .vnc); p.host = "127.0.0.1"; p.port = port; p.name = "refusing test server"
        let conn = VncConnection(profile: p)
        let failed = expectation(description: "failed")
        var message = ""
        conn.onState = { if case .failed(let m) = $0 { message = m; failed.fulfill() } }
        conn.start()
        wait(for: [failed], timeout: 15)
        XCTAssertTrue(message.contains(reason), message)
        let log = try String(contentsOf: VncLog.file, encoding: .utf8)
        XCTAssertTrue(log.contains("[refusing test server]") && log.contains(reason), log)
    }
}

final class TailscaleTests: XCTestCase {
    func testStatusIsRead() throws {
        let json = """
        {"BackendState":"Running","TUN":false,"AuthURL":"","CurrentTailnet":{"Name":"me@example.com"},"Self":{"HostName":"mac"},
         "Peer":{"k1":{"ID":"n1","HostName":"omarchy-msi","DNSName":"omarchy-msi.tail1.ts.net.","TailscaleIPs":["100.109.140.29","fd7a::1"],"OS":"linux","Online":true,"LastSeen":"0001-01-01T00:00:00Z"},
                 "k2":{"ID":"n2","HostName":"alpine","DNSName":"alpine.tail1.ts.net.","TailscaleIPs":["100.125.0.127"],"OS":"linux","Online":false,"LastSeen":"2026-09-28T10:00:00Z"}}}
        """
        let s = try XCTUnwrap(Tailscale.parse(Data(json.utf8)))
        XCTAssertEqual(s.state, "Running"); XCTAssertTrue(s.userspace); XCTAssertEqual(s.tailnet, "me@example.com")
        XCTAssertEqual(s.peers.map(\.name), ["omarchy-msi", "alpine"], "online first")
        XCTAssertEqual(s.peers[0].ip, "100.109.140.29"); XCTAssertEqual(s.peers[0].dnsName, "omarchy-msi.tail1.ts.net")
        XCTAssertNil(s.peers[0].lastSeen, "never is no date"); XCTAssertNotNil(s.peers[1].lastSeen)
        XCTAssertNil(Tailscale.parse(Data("not json".utf8)))
    }

    func testTailnetAddresses() {
        XCTAssertTrue(Tailscale.isTailnet("100.109.140.29")); XCTAssertTrue(Tailscale.isTailnet("100.64.0.1")); XCTAssertTrue(Tailscale.isTailnet("100.127.255.254"))
        XCTAssertFalse(Tailscale.isTailnet("100.63.0.1")); XCTAssertFalse(Tailscale.isTailnet("100.128.0.1")); XCTAssertFalse(Tailscale.isTailnet("192.168.0.157"))
        XCTAssertTrue(Tailscale.isTailnet("omarchy-msi.tail32cedf.ts.net")); XCTAssertTrue(Tailscale.isTailnet("OMARCHY-MSI.tail32cedf.ts.net."))
        XCTAssertFalse(Tailscale.isTailnet("example.com"))
    }

    func testAPeerKeepsItsProfileID() {
        XCTAssertEqual(Tailscale.stableID("tailscale:vnc:n1"), Tailscale.stableID("tailscale:vnc:n1"))
        XCTAssertNotEqual(Tailscale.stableID("tailscale:vnc:n1"), Tailscale.stableID("tailscale:ssh:n1"))
    }

    func testAToolThatHangsIsStopped() {
        let start = Date()
        XCTAssertNil(Tailscale.run("/bin/sleep", ["30"], timeout: 1))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertEqual(Tailscale.run("/bin/echo", ["hi"], timeout: 5)?.0, 0)
    }

    /// The forwarder hands each connection to the helper as its stdin and stdout: a stand-in that answers like a
    /// server (it echoes its arguments, then what it reads).
    func testTheForwarderRunsTheHelperPerConnection() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let saved = Tailscale.script
        Tailscale.script = dir.appendingPathComponent("nc.sh")
        defer { Tailscale.script = saved }
        try "#!/bin/sh\necho \"to $1 $2\"\nhead -c 5\n".write(to: Tailscale.script, atomically: true, encoding: .utf8)
        let f = try XCTUnwrap(Tailscale.Forwarder.to("100.100.1.1", 5901))
        XCTAssertTrue(Tailscale.Forwarder.to("100.100.1.1", 5901) === f, "one per destination")
        for _ in 0..<2 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_addr.s_addr = inet_addr("127.0.0.1"); addr.sin_port = UInt16(f.localPort).bigEndian
            let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            XCTAssertEqual(rc, 0)
            _ = "hello".withCString { Darwin.write(fd, $0, 5) }
            var got = Data(); var buf = [UInt8](repeating: 0, count: 256)
            while true { let n = Darwin.read(fd, &buf, 256); if n <= 0 { break }; got.append(contentsOf: buf[0..<n]) }
            close(fd)
            XCTAssertEqual(String(data: got, encoding: .utf8), "to 100.100.1.1 5901\nhello")
        }
    }

    /// tailscale nc's own failure (a refused port) is kept, and said in words; a connection that works clears it.
    func testARefusedPortIsSaidInWords() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let saved = Tailscale.script
        Tailscale.script = dir.appendingPathComponent("nc.sh")
        defer { Tailscale.script = saved }
        try "#!/bin/sh\n[ \"$2\" = 5902 ] && exit 0\necho 'Dial(\"'$1'\", '$2'): unexpected HTTP response: 502 Bad Gateway, dial failure: connect tcp '$1':'$2': connection was refused' >&2\nexit 1\n"
            .write(to: Tailscale.script, atomically: true, encoding: .utf8)
        func touch(_ port: Int) throws {
            let f = try XCTUnwrap(Tailscale.Forwarder.to("100.100.1.2", port))
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_addr.s_addr = inet_addr("127.0.0.1"); addr.sin_port = UInt16(f.localPort).bigEndian
            _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            var b = [UInt8](repeating: 0, count: 16); _ = Darwin.read(fd, &b, 16); close(fd)
            for _ in 0..<20 where Tailscale.routeProblem("100.100.1.2", port) == nil && port != 5902 { Thread.sleep(forTimeInterval: 0.05) }
        }
        try touch(5900)
        XCTAssertEqual(Tailscale.routeProblem("100.100.1.2", 5900), "nothing answers on port 5900 of 100.100.1.2 (is its server running, on that port?)")
        try touch(5902)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertNil(Tailscale.routeProblem("100.100.1.2", 5902))
        XCTAssertNil(Tailscale.routeProblem("100.100.9.9", 5900), "never tried")
    }

    /// With MYLINUX_TEST_TAILSCALE_CLOSED=<a tailnet host without a VNC server>: the window's words for it.
    func testATailnetMachineWithoutVNC() throws {
        guard let host = ProcessInfo.processInfo.environment["MYLINUX_TEST_TAILSCALE_CLOSED"] else { throw XCTSkip("MYLINUX_TEST_TAILSCALE_CLOSED not set") }
        guard case .status = Tailscale.detect() else { return XCTFail("no Tailscale found") }
        VncLog.directory = FileManager.default.temporaryDirectory
        var p = RemoteProfile(kind: .vnc); p.host = host; p.name = "closed"
        let conn = VncConnection(profile: p)
        let failed = expectation(description: "failed"); var message = ""
        conn.onState = { if case .failed(let m) = $0 { message = m; failed.fulfill() } }
        conn.start()
        wait(for: [failed], timeout: 30)
        print("message: \(message)")
        XCTAssertTrue(message.contains("nothing answers on port 5900 of closed"), message)
    }

    /// With MYLINUX_TEST_TAILSCALE=<a tailnet host running VNC>: this Mac's real Tailscale, and a VNC server's
    /// greeting and an ssh server's banner through it (nothing is logged in to).
    func testThisMacsTailnet() throws {
        guard let host = ProcessInfo.processInfo.environment["MYLINUX_TEST_TAILSCALE"] else { throw XCTSkip("MYLINUX_TEST_TAILSCALE not set") }
        guard case .status(let c, let s) = Tailscale.detect() else { return XCTFail("no Tailscale found") }
        print("tailscale: \(c.tool) \(c.socket ?? "-") state=\(s.state) userspace=\(s.userspace) peers=\(s.peers.count)")
        XCTAssertEqual(s.state, "Running")
        let to = Tailscale.endpoint(host, 5900)
        XCTAssertEqual(to.routed, s.userspace)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_addr.s_addr = inet_addr(to.routed ? "127.0.0.1" : host); addr.sin_port = UInt16(to.port).bigEndian
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        XCTAssertEqual(rc, 0)
        var buf = [UInt8](repeating: 0, count: 12); var got = 0
        while got < 12 { let n = Darwin.read(fd, &buf[got], 12 - got); if n <= 0 { break }; got += n }
        close(fd)
        XCTAssertEqual(String(bytes: buf, encoding: .ascii), "RFB 003.008\n")
        if s.userspace {
            // stdin stays open a moment, as ssh's does (tailscale nc ends at the end of its input)
            let banner = Tailscale.run("/bin/sh", ["-c", "sleep 4 | sh \"\(Tailscale.script.path)\" \(host) 22 | head -c 8"], timeout: 15)
            XCTAssertEqual(banner.flatMap { String(data: $0.1, encoding: .utf8) }, "SSH-2.0-")
        }
    }
}

final class FreshInstallTests: XCTestCase {
    /// A new install has no machines (the welcome offers them); removing the last one leaves none, not a new myLinux.
    func testANewInstallStartsWithoutMachines() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("profiles.json")
        guard !AppSettings.shared.developerMode else { throw XCTSkip("developer mode keeps the checkout's machine") }
        XCTAssertTrue(ProfileStore(file: file).profiles.isEmpty, "nothing made unasked")
        try "[]".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(ProfileStore(file: file).profiles.isEmpty, "an emptied list stays empty")
    }
}

final class MountShareTests: XCTestCase {
    func testThisMacsSharesAreRead() {
        let text = """
        \t\t\tList of Share Points
        name:\t\tViktor Kjartansson’s Public Folder
        path:\t\t/Users/vikkjart/Public
        \tsmb:\t{
        \t\tname:\tViktor Kjartansson’s Public Folder
        \t\tshared:\t1
        \t\tguest access:\t1
        \t}

        name:\t\tNot over SMB
        path:\t\t/Users/x/Other
        \tsmb:\t{
        \t\tname:\tNot over SMB
        \t\tshared:\t0
        \t}
        """
        XCTAssertEqual(MountShare.parseShares(text), ["Viktor Kjartansson’s Public Folder"])
    }

    func testANameInsideIsSuggested() {
        XCTAssertEqual(MountShare.suggestedName("Viktor Kjartansson’s Public Folder"), "Public")
        XCTAssertEqual(MountShare.suggestedName("media library"), "MediaLibrary")
        XCTAssertEqual(MountShare.suggestedName("Bilder 2026"), "Bilder2026")
    }

    func testWhatTheScriptWouldRefuseIsSaidFirst() {
        var r = MountShare.Request(server: "10.0.2.2", share: "Viktor Kjartansson’s Public Folder", name: "Public", user: "vikkjart")
        XCTAssertNil(r.problem)
        r.server = "100.109.140.29"; XCTAssertNil(r.problem)
        r.server = "nas; rm -rf /"; XCTAssertNotNil(r.problem)
        r.server = "nas"; r.share = "a/b"; XCTAssertNotNil(r.problem)
        r.share = "media"; r.name = "../x"; XCTAssertNotNil(r.problem)
        r.name = ".hidden"; XCTAssertNotNil(r.problem)
        r.name = "Media"; r.user = ""; XCTAssertNil(r.problem, "a guest share has no user")
    }

    func testTheScriptIsAmongTheFilesCopiedIn() {
        XCTAssertTrue(ServerApps.files.contains("mount-share.sh"))
        XCTAssertTrue(MountShare.guestLine.hasPrefix(" "), "the leading space keeps it out of the shell history")
    }
}

final class MacFolderTests: XCTestCase {
    let home = "/Users/me"

    func testWhatCanBeShared() {
        XCTAssertNil(MacFolder.problem(name: "Projects", path: "/Users/me/prjs", others: [], home: home))
        XCTAssertNil(MacFolder.problem(name: "Disk", path: "/Volumes/Backup", others: [], home: home))
        for path in ["/", "/Users", "/Users/me", "/Users/me/Library", "/Users/me/Library/Mail", "/System", "/Volumes", "/Applications"] {
            XCTAssertNotNil(MacFolder.problem(name: "X", path: path, others: [], home: home), path)
        }
        XCTAssertNil(MacFolder.problem(name: "Box", path: "/Users/me/Library/CloudStorage/Box-Box", others: [], home: home))
        XCTAssertNotNil(MacFolder.problem(name: "a b", path: "/Users/me/x", others: [], home: home), "one word")
        XCTAssertNotNil(MacFolder.problem(name: "Dropbox", path: "/Users/me/x", others: [], home: home), "a cloud folder's name")
        let p = MacFolder(name: "Projects", path: "/Users/me/prjs")
        XCTAssertNotNil(MacFolder.problem(name: "projects", path: "/Users/me/other", others: [p], home: home), "the same tag")
        XCTAssertNotNil(MacFolder.problem(name: "Work", path: "/Users/me/prjs", others: [p], home: home), "the same folder")
        XCTAssertEqual(p.tag, "mac-projects")
    }

    func testNamesAreSuggested() {
        XCTAssertEqual(MacFolder.suggestedName("/Users/me/prjs"), "prjs")
        XCTAssertEqual(MacFolder.suggestedName("/Users/me/My Projects"), "MyProjects")
        XCTAssertEqual(MacFolder.suggestedName("/Volumes/Backup Disk 2"), "BackupDisk2")
    }

    func testTheyAreSharedMountedAndListed() {
        let m = MacFolder(name: "Projects", path: "/Users/me/prjs")
        XCTAssertEqual(CloudFolder.extraShares([], mac: [m]), "mac-projects=/Users/me/prjs")
        let script = CloudFolder.mountScript([], mac: [m])
        XCTAssertTrue(script.contains(#"want="mac-projects:Projects""#))
        XCTAssertTrue(script.contains("$1 ~ /^mac-/"), "taken-away Mac folders are cleaned up")
        XCTAssertTrue(CloudFolder.consoleScript([], mac: [m]).contains("mac-projects:Projects"))
        var p = ProfileStore.newProfile(named: "O", kind: .omarchy); p.macFolders = [m]
        let state = ServerApps.cloudState(p)
        XCTAssertEqual((state["selected"] as? [String])?.last, "mac-projects")
        let last = (state["folders"] as? [[String: Any]])?.last
        XCTAssertEqual(last?["guest"] as? String, "Projects"); XCTAssertEqual(last?["mac"] as? Bool, true)
        if let out = ProcessInfo.processInfo.environment["MYLINUX_TEST_WRITE_MOUNT_SCRIPT"] {
            try? CloudFolder.mountScript(["dropbox"], mac: [m]).write(toFile: out, atomically: true, encoding: .utf8)
        }
    }
}

final class SnippetTests: XCTestCase {
    func testTheBuiltInSnippetsReadAndFitTheirSystems() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../server-apps/snippets.json").standardized
        let list = try XCTUnwrap(Snippets.decode(try Data(contentsOf: file)))
        XCTAssertFalse(list.isEmpty)
        let omarchy = list.filter { $0.os.contains(Profile.Kind.omarchy.rawValue) }.map(\.id)
        for id in ["cc-alias", "claude-subscription", "cx-alias", "codex-subscription", "statusline"] { XCTAssertTrue(omarchy.contains(id), id) }
        XCTAssertTrue(list.allSatisfy { s in s.os.allSatisfy { Profile.Kind(rawValue: $0) != nil } })
        XCTAssertTrue(list.allSatisfy { !$0.isOwn }, "built in, not the user's")
        XCTAssertTrue(Snippets.pasteHint(.omarchy).contains("Ctrl+Shift+V"))
    }
    func testVncDesktopsHaveSnippetsOfTheirOwn() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../server-apps").standardized
        let vnc = try XCTUnwrap(Snippets.decode(try Data(contentsOf: dir.appendingPathComponent("snippets-vnc.json"))))
        XCTAssertTrue(vnc.allSatisfy { $0.os == ["vnc"] }, "a file of their own, for VNC desktops only")
        let omarchy = try XCTUnwrap(Snippets.decode(try Data(contentsOf: dir.appendingPathComponent("snippets.json")))).filter { $0.os.contains("omarchy") }
        // codex-login asks the launcher through a machine's share folder, which a VNC desktop does not have
        XCTAssertEqual(Set(vnc.map(\.id)), Set(omarchy.map(\.id)).subtracting(["codex-login"]), "begun as a copy of Omarchy's")
        XCTAssertEqual(SnippetSet.vnc.file, "snippets-vnc.json"); XCTAssertEqual(SnippetSet.machine(.omarchy).file, "snippets.json")
    }
}
