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

final class BundledRuntimeTests: XCTestCase {
    func testInstalledWhenMissingOrAnotherVersion() {
        XCTAssertTrue(RuntimeManager.bundledInstallNeeded(installed: nil, bundled: "qemu-runtime-11.1.1-2", hasTarball: true))
        XCTAssertTrue(RuntimeManager.bundledInstallNeeded(installed: "qemu-runtime-11.1.1-1", bundled: "qemu-runtime-11.1.1-2", hasTarball: true))
        XCTAssertFalse(RuntimeManager.bundledInstallNeeded(installed: "qemu-runtime-11.1.1-2", bundled: "qemu-runtime-11.1.1-2", hasTarball: true))
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
        XCTAssertEqual(env["MEM"], "8G")
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
