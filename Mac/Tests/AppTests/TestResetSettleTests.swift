// TestResetSettleTests.swift -- the reset half of `Mac/docs/reports/fastui.md` section 6.10.
//
// Two defects, one symptom. When an app-modal `NSAlert` was up, step 1 of `sevenzip://test/reset`
// called `NSApp.abortModal()`, which is documented to **raise** `NSAbortModalException`. Both callers
// run inside a `CFRunLoopTimer` callback (the settle ticker, and `TestResetWatcher.poll` by way of
// `begin`), and an exception unwinding out of a timer callback leaves that timer marked as firing, so
// the run loop never fires it again: the settle ticker and the request watcher both died, `current`
// stayed set, and no reset was ever delivered or acknowledged again. The reported failure was exactly
// that -- "no reset acknowledgement within 30 s (generation was 0, is now 0; the request file was
// taken)".
//
// So this file asserts the two properties the contract needs:
//
//   1. a reset **settles past** an app-modal alert instead of waiting for it (the whole point of a
//      reset is to recover an app that is wedged, which is when a test needs it most);
//   2. a reset **always acknowledges** once its settle timeout expires, with a note that names the
//      step that stalled -- so a test fails with a message instead of timing out with nothing.
//
// Both cases raise `settleTimeout` from 15 s to about a second so they cost a second, not fifteen.

import AppKit
import XCTest
@testable import SevenZipAppHost

final class TestResetSettleTests: AppHostTestCase {

    /// A window that will not stay away, so `TestResetCoordinator.transientWindows()` never empties
    /// and step 2 must time out. It stands in for whatever a future scope leaves on screen -- the
    /// point is that the reset acknowledges anyway.
    ///
    /// It keeps coming *back* rather than overriding `orderOut`/`close` to swallow AppKit's calls:
    /// swallowing them leaves AppKit's own window-animation bookkeeping half done, and the eventual
    /// real close then over-releases `_NSWindowTransformAnimation` -- a segfault in `objc_release`
    /// under `CA::Transaction::commit`, which is how this fixture killed the host app once.
    /// `animationBehavior = .none` for the same reason: nothing to animate, nothing to over-release.
    private final class StubbornWindow: NSWindow {
        private var stubborn = false

        /// `super` is always called and the window comes straight back, synchronously, so
        /// `transientWindows()` is never empty when the settle ticker looks -- a timer that put it
        /// back a moment later raced the ticker and the reset settled by luck.
        override func orderOut(_ sender: Any?) {
            super.orderOut(sender)
            if stubborn { super.orderFront(nil) }
        }

        func beStubborn() {
            // `NSWindow` created directly defaults to `isReleasedWhenClosed = true`, and this test
            // also holds it in a property: `close()` then released it twice and the host app died in
            // `objc_release` under `objc_autoreleasePoolPop`. `NSWindowController` clears this flag for
            // the windows the app itself makes, which is why nothing else here has to.
            isReleasedWhenClosed = false
            animationBehavior = .none
            orderFront(nil)
            stubborn = true
        }

        func relent() {
            stubborn = false
            close()
        }
    }

    private var savedTimeout: TimeInterval = 15
    private var savedTestSupport: String?
    private var stubborn: StubbornWindow?
    private var scratchFiles: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedTimeout = TestResetCoordinator.settleTimeout
        savedTestSupport = ProcessInfo.processInfo.environment["SZ_TEST_SUPPORT"]
        // Read with getenv on every access, so this reaches the coordinator's own guard
        // (`Mac/docs/api/resetcmd.md` section 1). The host app is not launched with it.
        setenv("SZ_TEST_SUPPORT", "1", 1)
        // Step 3 calls `OptionsPostApply.reloadLangItems()`, which rebuilds the toolbar of **every**
        // window in `NSApp.windows` and throws `NSInternalInconsistencyException` ("index>=0 &&
        // index<[_currentItems count]") on the toolbar of a window that has been closed. The shipped
        // app has exactly one toolbar, so this never bites a user; a test bundle that has built extra
        // `MainWindowController`s may still be holding theirs. Filed for `options` in
        // `Mac/docs/requests.md`. Until it is fixed, make the precondition true rather than depend on
        // the order the test classes happened to run in.
        let live = (NSApp.delegate as? AppDelegate)?.mainWindowController?.window
        for window in NSApp.windows where window !== live && window.toolbar != nil {
            window.toolbar = nil
        }
        // A reset left in flight by an earlier case would make this one's request queue behind it and
        // its generation land two higher, which is a confusing way to learn that something else broke.
        XCTAssertFalse(TestResetCoordinator.isResetting,
                       "a previous case left a reset in flight at \(TestResetCoordinator.stage.rawValue)")
    }

    override func tearDown() {
        TestResetCoordinator.settleTimeout = savedTimeout
        if let saved = savedTestSupport { setenv("SZ_TEST_SUPPORT", saved, 1) } else { unsetenv("SZ_TEST_SUPPORT") }
        stubborn?.relent()
        stubborn = nil
        for path in scratchFiles { try? FileManager.default.removeItem(atPath: path) }
        scratchFiles = []
        super.tearDown()
    }

    // MARK: - helpers

    private func request(named name: String) -> TestResetRequest {
        var request = TestResetRequest()
        let ack = (TestPaths.artifacts as NSString)
            .appendingPathComponent("modalfix-\(name)-\(UUID().uuidString).ack")
        request.ackPath = ack
        scratchFiles.append(ack)
        if let note = TestResetCoordinator.stallNotePath(for: request) { scratchFiles.append(note) }
        // Panel 0 goes to the fixtures, which exist: this is a test about settling, not about paths.
        request.panelPaths = [0: TestPaths.fixtures, 1: TestPaths.fixtures]
        return request
    }

    private func acknowledgement(_ request: TestResetRequest) -> String? {
        guard let path = request.ackPath,
              let data = FileManager.default.contents(atPath: path) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - 1. settling past an app-modal alert

    /// An ownerless app-modal `NSAlert` -- exactly what the old `PanelViewController.showError` put up
    /// -- and a reset sent while it is on screen. The reset must end the session and acknowledge, and
    /// it must acknowledge *because it settled*, not because it timed out.
    func testTheResetSettlesPastAnOwnerlessAppModalAlert() {
        TestResetCoordinator.settleTimeout = 6
        let request = self.request(named: "modal-settle")
        let before = TestResetCoordinator.generation

        // The reset is sent from a timer that fires *inside* the nested modal session: a timer in
        // `.common` / `.modalPanel` runs there (fastui section 6.5), which is exactly how the real
        // request watcher delivers a reset to a wedged app.
        var sent = false
        let sender = Timer(timeInterval: 0.2, repeats: true) { _ in
            guard !sent, NSApp.modalWindow != nil else { return }
            sent = true
            XCTAssertEqual(TestResetCoordinator.handle(request), .success)
        }
        for mode in [RunLoop.Mode.common, .modalPanel] { RunLoop.main.add(sender, forMode: mode) }

        let alert = ErrorAlert.make(message: "modalfix: an app-modal alert owned by no window")
        _ = alert.runModal()                 // returns only because the reset ended the session
        sender.invalidate()

        XCTAssertTrue(sent, "the reset was never delivered into the modal session")
        XCTAssertNil(NSApp.modalWindow, "the reset must leave no modal session behind")
        XCTAssertTrue(wait(for: "the acknowledgement", timeout: 30) { self.acknowledgement(request) != nil },
                      "the reset never acknowledged: \(TestResetCoordinator.stage.rawValue)")
        XCTAssertEqual(TestResetCoordinator.generation, before + 1)
        XCTAssertEqual(acknowledgement(request), String(TestResetCoordinator.generation))
        XCTAssertNil(TestResetCoordinator.lastStall,
                     "the reset should have *settled* past the alert, not timed out waiting for it")
        if let note = TestResetCoordinator.stallNotePath(for: request) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: note),
                           "a reset that settled must leave no stall note")
        }
    }

    // MARK: - 2. acknowledging a settle that cannot finish

    /// A window that will not go away, so step 2 cannot succeed. The acknowledgement must still arrive
    /// -- with the generation bumped and a note that names step 2 and the window -- because a test that
    /// is told what stalled can fail with a message, and a test that is told nothing can only time out.
    func testAStalledSettleStillAcknowledgesAndSaysWhatStalled() {
        TestResetCoordinator.settleTimeout = 1
        let window = StubbornWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
                                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "modalfix stubborn window"
        window.beStubborn()
        stubborn = window
        XCTAssertTrue(window.isVisible, "the stall fixture must be on screen")

        let request = self.request(named: "stalled-settle")
        let before = TestResetCoordinator.generation
        XCTAssertEqual(TestResetCoordinator.handle(request), .success)

        XCTAssertTrue(wait(for: "the acknowledgement of a stalled reset", timeout: 30) {
            self.acknowledgement(request) != nil
        }, "a reset whose settle timed out must still write the ack (it wrote nothing at all before)")
        XCTAssertEqual(TestResetCoordinator.generation, before + 1,
                       "the generation must be bumped even when the reset gave up")
        XCTAssertEqual(acknowledgement(request), String(TestResetCoordinator.generation))

        let stall = TestResetCoordinator.lastStall
        XCTAssertNotNil(stall, "a reset that did not settle must say so")
        XCTAssertTrue(stall?.contains("step 2") ?? false,
                      "the stall message must name the step: \(stall ?? "nil")")
        XCTAssertTrue(stall?.contains("StubbornWindow") ?? false,
                      "the stall message must name what would not go: \(stall ?? "nil")")

        guard let notePath = TestResetCoordinator.stallNotePath(for: request) else {
            return XCTFail("a request with an ack path has a stall-note path")
        }
        let note = try? String(contentsOfFile: notePath, encoding: .utf8)
        XCTAssertNotNil(note, "the stall note should sit next to the ack file at \(notePath)")
        XCTAssertTrue(note?.contains(String(TestResetCoordinator.generation)) ?? false,
                      "the note names the generation it belongs to: \(note ?? "nil")")
        print("MODALFIX | stalled reset acknowledged | \(stall ?? "")")
    }

    /// The shape the fastui run actually hit, and the one the old code could never recover from.
    /// Step 4 hands each panel a completion block; a panel whose serial queue cannot run -- parked
    /// behind a long engine call, or starved because an app-modal session owns the main thread -- never
    /// delivers it, so `finish` was never reached. Measured on the unfixed code with this exact
    /// fixture: "no reset acknowledgement within 25 s (generation was 0, is now 0)", which is the
    /// failure `Mac/docs/reports/fastui.md` section 6.10 reports verbatim. The ack must arrive anyway,
    /// and it must say that step 4 is what stalled.
    func testAStalledPanelRebuildStillAcknowledges() {
        TestResetCoordinator.settleTimeout = 2
        guard let controller = (NSApp.delegate as? AppDelegate)?.mainWindowController else {
            return XCTFail("the app-hosted tests run inside the app, so there is a live main window")
        }
        let release = DispatchSemaphore(value: 0)
        controller.panels[0].runOnQueue { release.wait() }        // park the panel's serial queue
        defer {
            release.signal()
            _ = wait(for: "the parked reset to drain", timeout: 20) { !TestResetCoordinator.isResetting }
            // The watchdog acknowledged while step 4 was still in flight, so the panels of the *live*
            // window are still binding. Let them finish here rather than under the next case: the
            // panel queue serializes them, so nothing is unsafe, but a half-bound window is a poor
            // fixture for whatever runs next.
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
        }

        let request = self.request(named: "stalled-rebuild")
        let before = TestResetCoordinator.generation
        XCTAssertEqual(TestResetCoordinator.handle(request), .success)

        XCTAssertTrue(wait(for: "the acknowledgement of a stalled rebuild", timeout: 30) {
            self.acknowledgement(request) != nil
        }, "a reset whose panel rebuild never returned wrote no acknowledgement at all before")
        XCTAssertEqual(TestResetCoordinator.generation, before + 1)
        let stall = TestResetCoordinator.lastStall
        XCTAssertTrue(stall?.contains("step 4") ?? false,
                      "the stall message must name step 4: \(stall ?? "nil")")
        print("MODALFIX | stalled rebuild acknowledged | \(stall ?? "")")
    }

    /// A clean reset after a stalled one must remove the note, so a test can never read an old
    /// diagnosis as this reset's.
    func testACleanResetRemovesAnEarlierStallNote() {
        TestResetCoordinator.settleTimeout = 4
        let request = self.request(named: "note-cleared")
        guard let notePath = TestResetCoordinator.stallNotePath(for: request) else {
            return XCTFail("a request with an ack path has a stall-note path")
        }
        try? Data("99: a note from an earlier run\n".utf8)
            .write(to: URL(fileURLWithPath: notePath), options: .atomic)

        XCTAssertEqual(TestResetCoordinator.handle(request), .success)
        XCTAssertTrue(wait(for: "the acknowledgement", timeout: 30) { self.acknowledgement(request) != nil })
        XCTAssertNil(TestResetCoordinator.lastStall, "this reset settles")
        XCTAssertFalse(FileManager.default.fileExists(atPath: notePath),
                       "a reset that settled must remove the stall note it found")
    }
}
