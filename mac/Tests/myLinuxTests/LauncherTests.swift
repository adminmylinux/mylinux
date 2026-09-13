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
