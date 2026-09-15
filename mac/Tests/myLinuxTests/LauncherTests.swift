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
    func testCertificateDescription() throws {
        // a self-signed certificate made for the test
        let pem = try String(contentsOfFile: NSTemporaryDirectory() + "mylinux-test-cert.pem", encoding: .utf8)
        let info = try XCTUnwrap(CertPin.describe(pem))
        XCTAssertEqual(info.name, "mylinux-test")
        XCTAssertEqual(info.fingerprint.count, 32 * 3 - 1)
    }
}

/// Against a real VeNCrypt server: MYLINUX_TEST_VNC_HOST=192.168.0.61 swift test --filter CertProbe
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
