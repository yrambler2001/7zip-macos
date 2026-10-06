// MainWindowLayoutTests.swift -- the main window's geometry (01 section 1.2, 01b section 5.7),
// measured on a `MainWindowController` built in this process.
//
// It replaces `LayoutSweepTests.testMainWindowLayout` and the three launch-only cases of
// `SplitViewTests`: "the split is even on first use", "the stored splitter ratio is restored" and
// "the split survives the minimum window size". All four asked about frames, and a frame does not
// need a second process -- `showSecondPanel()` runs the same code whether the toggle came from the
// View menu or from a method call.
//
// The one `SplitViewTests` case that stays an XCUITest is the divider **drag**: a press-and-drag
// is synthesized input and the defect it covers is the round trip through
// `splitViewDidResizeSubviews` -> `captureSplitterRatio` -> the settings domain.
//
// The defect all of this guards (ai/reports/polish.md): `showSecondPanel` used to place the
// divider from a `DispatchQueue.main.async` block, and whether that block or the split view's own
// layout pass ran first was a coin toss. When the block won, `setPosition(_:ofDividerAt:)` ran
// against a subview that had just been inserted and was still zero points wide, and NSSplitView
// collapsed *both* panels. So a test must assert the even split, not just that two panels exist --
// and it must do it more than once, because the defect was a race.

import AppKit
import XCTest
@testable import SevenZipAppHost

final class MainWindowLayoutTests: AppHostTestCase {

    override var screenshotPrefix: String { "fastui" }

    private var controllers: [MainWindowController] = []

    override func tearDown() {
        for controller in controllers { controller.window?.close() }
        controllers = []
        super.tearDown()
    }

    /// A window of its own, so nothing here touches the app's live one. `showWindow` is needed
    /// because NSSplitView only lays its subviews out once the window has a frame on screen.
    ///
    /// `MainWindowController.init` calls `restoreState()`, which reads `FM.Panels.numPanels` from
    /// the settings domain -- so `panels` is written there first rather than assumed: a domain left
    /// with two panels by an earlier case would otherwise make "started with one panel" fail for a
    /// reason that has nothing to do with the split.
    private func makeWindow(size: NSSize = NSSize(width: 1200, height: 800),
                            panels: Int = 1) -> MainWindowController {
        Settings.numPanels = panels
        let controller = MainWindowController()
        controllers.append(controller)
        controller.window?.setContentSize(size)
        controller.showWindow(nil)
        controller.window?.layoutIfNeeded()
        return controller
    }

    /// The panel widths, which is what a collapsed split shows up in: `SplitViewTests` measured the
    /// address combos over accessibility for exactly this, because a collapsed panel's combo is
    /// about 59 pt wide.
    private func panelWidths(_ controller: MainWindowController) -> [CGFloat] {
        controller.panels.map { $0.view.frame.width }
    }

    private func dividerPosition(_ controller: MainWindowController) -> CGFloat? {
        guard let split = firstSplitView(in: controller), split.subviews.count > 1 else { return nil }
        return split.subviews[0].frame.maxX
    }

    private func firstSplitView(in controller: MainWindowController) -> NSSplitView? {
        func search(_ view: NSView) -> NSSplitView? {
            if let split = view as? NSSplitView { return split }
            for child in view.subviews {
                if let found = search(child) { return found }
            }
            return nil
        }
        guard let content = controller.window?.contentView else { return nil }
        return search(content)
    }

    /// Let the window finish laying the split out and then measure. A panel that has just been
    /// inserted is in the tree before its own subviews have their final frames -- the XCUITest
    /// version of this test had the same helper, for the same reason -- so the run loop is pumped
    /// until two consecutive samples of the panel widths agree. Never a fixed delay.
    @discardableResult
    private func waitForSplitToSettle(_ controller: MainWindowController,
                                      timeout: TimeInterval = 10) -> [CGFloat] {
        let deadline = Date().addingTimeInterval(timeout)
        var previous: [CGFloat] = []
        repeat {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            controller.window?.layoutIfNeeded()
            controller.window?.displayIfNeeded()
            let current = panelWidths(controller)
            if current == previous, current.allSatisfy({ $0 > 1 }) { return current }
            previous = current
        } while Date() < deadline
        return previous
    }

    /// Both panels the same width and the divider in the middle, to within `tolerance`.
    private func assertEvenSplit(_ controller: MainWindowController, _ what: String,
                                 tolerance: CGFloat = 12,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let widths = waitForSplitToSettle(controller)
        XCTAssertEqual(widths.count, 2, "\(what): \(widths.count) panel(s)", file: file, line: line)
        guard widths.count == 2 else { return }
        XCTAssertEqual(widths[0], widths[1], accuracy: tolerance,
                       "\(what): panel widths \(widths)", file: file, line: line)
        guard let split = firstSplitView(in: controller), let position = dividerPosition(controller) else {
            return XCTFail("\(what): no divider", file: file, line: line)
        }
        XCTAssertEqual(position, split.frame.width / 2, accuracy: tolerance,
                       "\(what): divider at \(position) of \(split.frame.width)", file: file, line: line)
    }

    // MARK: - 01 section 1.2: the window itself

    /// One panel and two panels: nothing clipped, nothing overlapping, the window fits the screen.
    func testMainWindowLayout() {
        continueAfterFailure = true
        let controller = makeWindow()
        guard let window = controller.window else { return XCTFail("no window") }
        audit(window, "Main window, 1 panel", shot: "20-main-one-panel")
        controller.switchOnOffOnePanel()
        waitForSplitToSettle(controller)
        XCTAssertEqual(controller.numPanels, 2, "View > 2 Panels did nothing")
        audit(window, "Main window, 2 panels", shot: "21-main-two-panels")
        finishAudit("main window")
    }

    // MARK: - 01b section 5.7: the splitter

    /// Toggling to two panels splits the window evenly -- three separate windows, because the
    /// defect was a race that showed up in roughly one launch in four.
    func testTwoPanelsSplitEvenlyOnFirstUse() {
        continueAfterFailure = true
        for trial in 1...3 {
            let controller = makeWindow()
            XCTAssertEqual(controller.numPanels, 1, "trial \(trial): started with two panels")
            controller.switchOnOffOnePanel()
            assertEvenSplit(controller, "toggle trial \(trial)")
            if trial == 1, let window = controller.window {
                audit(window, "Main window, even split", shot: "11-two-panels-even")
            }
        }
        finishAudit("even split")
    }

    /// A stored `FM.Panels.splitterPos` is honoured: the divider lands at that share of the width,
    /// not at the 120 pt minimum and not in the middle.
    func testStoredSplitterPositionIsRestored() {
        continueAfterFailure = true
        let savedRatio = Settings.splitterPos
        defer { Settings.splitterPos = savedRatio }
        Settings.splitterPos = 0.35
        let controller = makeWindow()
        controller.switchOnOffOnePanel()
        waitForSplitToSettle(controller)
        guard let split = firstSplitView(in: controller), let position = dividerPosition(controller) else {
            return XCTFail("no divider")
        }
        XCTAssertEqual(position, split.frame.width * 0.35, accuracy: 12,
                       "divider at \(position) of \(split.frame.width), expected 35%")
        let widths = panelWidths(controller)
        XCTAssertLessThan(widths[0], widths[1], "panel 0 should be the narrow one at 35%")
    }

    /// The window at its smallest (360x240, `MainWindowController.init`): 0.5 of 360 is still wider
    /// than kPanelSizeMin 120, so the split stays even instead of snapping to the minimum.
    func testTwoPanelsAtMinimumWindowSize() {
        continueAfterFailure = true
        let savedRatio = Settings.splitterPos
        defer { Settings.splitterPos = savedRatio }
        Settings.splitterPos = 0.5
        let controller = makeWindow(size: NSSize(width: 360, height: 240))
        controller.switchOnOffOnePanel()
        waitForSplitToSettle(controller)
        XCTAssertEqual(controller.window?.frame.width ?? 0, 360, accuracy: 24,
                       "the window kept its minimum width")
        assertEvenSplit(controller, "minimum window size", tolerance: 8)
        if let window = controller.window {
            audit(window, "Main window, minimum size, 2 panels", shot: "13-two-panels-minimum-size")
        }
        finishAudit("minimum window size")
    }
}
