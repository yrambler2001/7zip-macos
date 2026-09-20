// SplitViewTests.swift -- View > 2 Panels and the stored divider position (01 section 1.2,
// 01b section 5.7; `polish` scope, Mac/docs/reports/polish.md).
//
// The defect these cover: `showSecondPanel` used to place the divider from a
// `DispatchQueue.main.async` block, and whether that block or the split view's own layout pass ran
// first was a coin toss. When the block won, `setPosition(_:ofDividerAt:)` ran against a subview
// that had just been inserted and was still zero points wide, and NSSplitView collapsed *both*
// panels to zero -- one launch in four, measured. When the layout pass won, it derived the ratio
// from those same live frames and flashed a 1080/119 split for up to ~280 ms before the async
// block corrected it. So a test must assert the *even* split, not just that two panels exist.

import XCTest

final class SplitViewTests: SevenZipUITestCase {

    override var screenshotPrefix: String { "polish" }

    // MARK: - helpers

    private var splitGroup: XCUIElement { sevenZip.window.splitGroups.element(boundBy: 0) }

    /// The divider's position inside the split view, as the accessibility tree reports it.
    private var dividerPosition: CGFloat? {
        let divider = splitGroup.descendants(matching: .splitter).firstMatch
        guard divider.exists else { return nil }
        if let number = divider.value as? NSNumber { return CGFloat(number.doubleValue) }
        if let text = divider.value as? String, let value = Double(text) { return CGFloat(value) }
        return nil
    }

    /// The width of each panel's address combo -- the panel's own width minus fixed chrome, so
    /// two panels of the same width have combos of the same width. A collapsed panel's combo is
    /// about 59 pt wide, which is what the failure looked like in the accessibility tree.
    private func addressBarWidths() -> (CGFloat, CGFloat) {
        (sevenZip.panel(0).addressBar.frame.width, sevenZip.panel(1).addressBar.frame.width)
    }

    /// A panel that has just been inserted is in the tree before its own subviews have their
    /// final frames -- the address combo grows over a few hundred milliseconds while the folder
    /// is read. Wait for that to settle before measuring, so the test asserts the *result* of the
    /// split and not a frame caught mid-layout.
    private func waitForPanelsToSettle(timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        var previous: (CGFloat, CGFloat) = (-1, -1)
        repeat {
            let current = addressBarWidths()
            if current == previous, current.0 > 1, current.1 > 1 { return }   // two samples agree
            previous = current
            usleep(250_000)
        } while Date() < deadline
    }

    /// Both panels the same width, to within `tolerance`, and the divider in the middle.
    private func assertEvenSplit(_ what: String, tolerance: CGFloat = 12) {
        XCTAssertEqual(sevenZip.panelCount, 2, "\(what): the second panel is not in the tree")
        XCTAssertTrue(sevenZip.panelsAreOrderedLeftToRight, "\(what): panels out of order")
        waitForPanelsToSettle()
        let (left, right) = addressBarWidths()
        XCTAssertEqual(left, right, accuracy: tolerance,
                       "\(what): panel widths differ (address combos \(left) and \(right))")
        guard let position = dividerPosition else { return XCTFail("\(what): no divider") }
        XCTAssertEqual(position, splitGroup.frame.width / 2, accuracy: tolerance,
                       "\(what): divider at \(position) of \(splitGroup.frame.width)")
    }

    /// `FM.Panels.splitterPos` is a **string** in the domain: SZSettings stores doubles as "%.6f".
    private func twoPanelSeed(ratio: String, position: String? = nil) -> SettingsSeed {
        var values: [String: Any] = [SettingsDomain.Key.numPanels: 2,
                                     SettingsDomain.Key.splitterPos: ratio,
                                     SettingsDomain.Key.panelPath0: TestPaths.fixtures,
                                     SettingsDomain.Key.panelPath1: TestPaths.fixtures]
        if let position { values[SettingsDomain.Key.position] = position }
        return .typed(values)
    }

    // MARK: - tests

    /// Toggling View > 2 Panels splits the window evenly -- three separate launches, because the
    /// defect was a race that only showed up in some of them.
    func testTwoPanelsSplitEvenlyOnFirstUse() {
        for trial in 1...3 {
            launch(seed: .typed([SettingsDomain.Key.numPanels: 1,
                                 SettingsDomain.Key.splitterPos: "0.500000",
                                 SettingsDomain.Key.panelPath0: TestPaths.fixtures,
                                 SettingsDomain.Key.panelPath1: TestPaths.fixtures]))
            XCTAssertTrue(sevenZip.panel(0).table.waitForExistence(timeout: 30))
            XCTAssertEqual(sevenZip.panelCount, 1, "trial \(trial): started with two panels")
            XCTAssertTrue(sevenZip.ensurePanelCount(2), "trial \(trial): View > 2 Panels did nothing")
            XCTAssertTrue(sevenZip.panel(1).waitForRow(named: "test.7z", timeout: 20),
                          "trial \(trial): the second panel never listed its folder")
            assertEvenSplit("toggle trial \(trial)")
            if trial == 1 { screenshot("11-two-panels-even") }
            sevenZip.terminate()
        }
    }

    /// Launching straight into two panels (`FM.Panels.numPanels` = 2) puts the divider where
    /// `FM.Panels.splitterPos` says, not at the 120 pt minimum and not at the middle.
    func testStoredSplitterPositionIsRestoredOnLaunch() {
        launch(seed: twoPanelSeed(ratio: "0.350000"))
        XCTAssertTrue(sevenZip.panel(0).table.waitForExistence(timeout: 30))
        XCTAssertTrue(sevenZip.panel(1).waitForRow(named: "test.7z", timeout: 20))
        XCTAssertEqual(sevenZip.panelCount, 2)
        waitForPanelsToSettle()
        guard let position = dividerPosition else { return XCTFail("no divider") }
        let width = splitGroup.frame.width
        XCTAssertEqual(position, width * 0.35, accuracy: 12,
                       "divider at \(position) of \(width), expected 35%")
        let (left, right) = addressBarWidths()
        XCTAssertLessThan(left, right, "panel 0 should be the narrow one at 35%")
        screenshot("12-two-panels-stored-ratio")
    }

    /// The window at its smallest (360x240, `MainWindowController.init`): 0.5 of 360 is still
    /// wider than kPanelSizeMin, so the split stays even instead of snapping to a minimum.
    func testTwoPanelsAtMinimumWindowSize() {
        launch(seed: twoPanelSeed(ratio: "0.500000", position: "200 200 360 240"))
        XCTAssertTrue(sevenZip.panel(0).table.waitForExistence(timeout: 30))
        XCTAssertTrue(sevenZip.panel(1).waitForRow(named: "test.7z", timeout: 20))
        XCTAssertEqual(sevenZip.window.frame.width, 360, accuracy: 2)
        assertEvenSplit("minimum window size", tolerance: 8)
        screenshot("13-two-panels-minimum-size")
    }

    /// Drag the divider, quit, launch again from the same settings domain: the position is saved
    /// as a ratio and restored (CApp::Save / FM.Panels.splitterPos).
    func testSplitterPositionSurvivesRelaunch() {
        launch(seed: twoPanelSeed(ratio: "0.500000"))
        XCTAssertTrue(sevenZip.panel(0).table.waitForExistence(timeout: 30))
        XCTAssertTrue(sevenZip.panel(1).waitForRow(named: "test.7z", timeout: 20))
        assertEvenSplit("before the drag")
        let divider = splitGroup.descendants(matching: .splitter).firstMatch
        XCTAssertTrue(divider.exists, "no divider to drag")
        divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.3,
                   thenDragTo: sevenZip.window.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)))
        guard let dragged = dividerPosition else { return XCTFail("no divider after the drag") }
        let width = splitGroup.frame.width
        XCTAssertLessThan(dragged, width * 0.45, "the drag did not move the divider left")

        XCTAssertTrue(sevenZip.quit(), "the app did not quit cleanly, so nothing was saved")
        let saved = sevenZip.seedFile?.values[SettingsDomain.Key.splitterPos] as? String
        XCTAssertNotNil(saved, "FM.Panels.splitterPos was not written on quit")
        XCTAssertEqual(Double(saved ?? "") ?? 0, Double(dragged / width), accuracy: 0.02,
                       "the saved ratio is not where the divider was")

        sevenZip.launch(seed: .keep)
        XCTAssertTrue(sevenZip.panel(0).table.waitForExistence(timeout: 30))
        XCTAssertTrue(sevenZip.panel(1).waitForRow(named: "test.7z", timeout: 20))
        XCTAssertEqual(sevenZip.panelCount, 2, "the second panel did not come back")
        guard let restored = dividerPosition else { return XCTFail("no divider after the relaunch") }
        XCTAssertEqual(restored, dragged, accuracy: 12,
                       "divider restored at \(restored), was \(dragged)")
        screenshot("14-two-panels-restored-ratio")
    }
}
