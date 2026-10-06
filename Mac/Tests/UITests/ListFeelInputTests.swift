// ListFeelInputTests.swift -- the list's mouse behaviour with real input (ai/reports/
// listfeel.md §6, §8): the rubber band as 7zFM 26.03 draws it with "Full row select" off, and the
// address bar's drop-down navigating on a pick. The geometry is in the app-hosted ListFeelTests.
// Input shard: it clicks and drags.

import AppKit
import XCTest

final class ListFeelInputTests: SevenZipUITestCase {

    override var screenshotPrefix: String { "listfeel" }

    private func makeScratch() throws -> String {
        let fm = FileManager.default
        let base = (TestPaths.artifacts as NSString).appendingPathComponent("listfeel-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(atPath: base + "/sub", withIntermediateDirectories: true)
        for (name, size) in [("a.txt", 1234), ("b.bin", 100_000), ("c.txt", 20), ("d.txt", 300), ("notes.md", 20)] {
            try Data(repeating: 0x78, count: size).write(to: URL(fileURLWithPath: base + "/" + name))
        }
        addTeardownBlock { [weak sevenZip] in
            if let app = sevenZip, app.isRunning, app.testSupportIsImplemented {
                var options = SevenZipApp.ResetOptions()
                options.panels = 1
                options.path0 = TestPaths.fixtures
                app.reset(options)
            }
            try? fm.removeItem(atPath: base)
        }
        return base
    }

    /// The status bar's first part without its bidi isolation marks ("4 / 6 object(s) selected").
    private func selected(_ panel: SevenZipPanel) -> String {
        panel.status.filter { $0.isASCII }
    }

    private func cells(of row: XCUIElement) -> [XCUIElement] {
        row.cells.allElementsBoundByIndex.sorted { $0.frame.minX < $1.frame.minX }
    }

    /// FullRow off (the default), measured on 7zFM: a drag that starts on a Size cell is the
    /// background's -- a dotted rubber band, not an item drag -- and selects the rows whose icon or
    /// name it crosses, nothing when it stays over the other columns; a click on a Size cell
    /// clears the selection; a click on a name selects it.
    func testRubberBandFromTheOtherColumns() throws {
        let scratch = try makeScratch()
        launch(seed: .values([SettingsDomain.Key.panelPath0: scratch]))
        let panel = sevenZip.panel(0)
        XCTAssertTrue(panel.waitForRow(named: "d.txt"))
        let a = cells(of: panel.row(named: "a.txt")), d = cells(of: panel.row(named: "d.txt"))
        XCTAssertGreaterThan(a.count, 2)
        XCTAssertGreaterThan(d.count, 2)
        let mid = CGVector(dx: 0.5, dy: 0.5)

        // Over the Size and Modified cells only: the band meets no item.
        a[1].coordinate(withNormalizedOffset: mid).press(forDuration: 0.2, thenDragTo: d[2].coordinate(withNormalizedOffset: mid))
        XCTAssertTrue(waitFor("nothing selected") { selected(panel).hasPrefix("0 / ") }, "status \(panel.status)")
        XCTAssertTrue(panel.waitForRow(named: "a.txt"), "the drag moved an item")

        // From the Size cell of a.txt back to d.txt's icon: a.txt, b.bin, c.txt and d.txt.
        let icon = d[0].coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 10, dy: 0))
        a[1].coordinate(withNormalizedOffset: mid).press(forDuration: 0.2, thenDragTo: icon)
        XCTAssertTrue(waitFor("four selected") { selected(panel).hasPrefix("4 / ") }, "status \(panel.status)")
        screenshot("input-rubber-band")

        // A click on a Size cell is a click on the background: the selection goes.
        a[1].click()
        XCTAssertTrue(waitFor("cleared") { selected(panel).hasPrefix("0 / ") }, "status \(panel.status)")
        // A click on the name selects.
        panel.select("b.bin")
        XCTAssertTrue(waitFor("b.bin selected") { selected(panel).hasPrefix("1 / ") }, "status \(panel.status)")
    }

    /// CBN_SELENDOK: picking an entry in the address bar's drop-down with the mouse goes there at
    /// once, with no Return, and the entries are the path's components by name.
    func testAddressDropdownPickNavigates() throws {
        let scratch = try makeScratch()
        launch(seed: .values([SettingsDomain.Key.panelPath0: scratch + "/sub"]))
        let panel = sevenZip.panel(0)
        XCTAssertTrue(panel.waitForPath(scratch + "/sub"))
        let bar = panel.addressBar
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "no address bar")
        // The arrow, 9 pt in from the combo's right edge, opens the Windows-style list
        // (AddressPopup, feel3): one row per entry, named after the entry, no indent spaces.
        bar.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5)).withOffset(CGVector(dx: -9, dy: 0)).click()
        let name = (scratch as NSString).lastPathComponent
        let entry = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'address-dropdown-' AND label == %@", name))
            .firstMatch
        if !entry.waitForExistence(timeout: 10) { _ = sevenZip.dumpTree("listfeel-dropdown") }
        XCTAssertTrue(entry.exists, "no drop-down entry for \(name)")
        screenshot("input-address-dropdown")
        entry.click()
        XCTAssertTrue(panel.waitForPath(scratch), "the pick did not navigate: \(panel.path)")
        XCTAssertTrue(panel.waitForRow(named: "a.txt"))
    }
}
