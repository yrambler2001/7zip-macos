// SelColorsInputTests.swift -- the selection colours with real clicks in a real key window
// (Mac/docs/reports/selcolors.md). The app-hosted `SelColorsTests` render every state with the
// keyboard focus forced; this checks the part they cannot: that a click really gives the list the
// focus and the fill, that the other panel's selection disappears as in 7zFM (no
// LVS_SHOWSELALWAYS), and that the user's bug -- Light appearance, a selected row's Size column
// white on white -- is gone in the running app. Input shard: it clicks.

import AppKit
import XCTest

final class SelColorsInputTests: SevenZipUITestCase {

    override var screenshotPrefix: String { "selcolors" }

    private func makeScratch() throws -> String {
        let fm = FileManager.default
        let base = (TestPaths.artifacts as NSString).appendingPathComponent("selcolors-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(atPath: base + "/sub", withIntermediateDirectories: true)
        for (name, size) in [("a.txt", 1234), ("b.bin", 100_000), ("c.txt", 20)] {
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

    private struct Pixels {
        let px: [(r: Int, g: Int, b: Int)]
        init(_ element: XCUIElement) {
            var out: [(Int, Int, Int)] = []
            if let rep = NSBitmapImageRep(data: element.screenshot().pngRepresentation) {
                for y in 0..<rep.pixelsHigh {
                    for x in 0..<rep.pixelsWide {
                        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                        out.append((Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255)))
                    }
                }
            }
            px = out
        }
        /// Share of pixels in the selection blue (0,120,212), whatever the display profile does to it.
        var highlightShare: Double {
            guard !px.isEmpty else { return 0 }
            return Double(px.filter { $0.b > 150 && $0.r < 80 && $0.g > 70 && $0.g < 170 }.count) / Double(px.count)
        }
        static func lum(_ p: (r: Int, g: Int, b: Int)) -> Double {
            func l(_ v: Int) -> Double { let c = Double(v) / 255; return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * l(p.r) + 0.7152 * l(p.g) + 0.0722 * l(p.b)
        }
        /// WCAG contrast of the most distinct pixel against the dominant one.
        var contrast: Double {
            var counts: [Int: Int] = [:]
            for p in px { counts[p.r << 16 | p.g << 8 | p.b, default: 0] += 1 }
            guard let key = counts.max(by: { $0.value < $1.value })?.key else { return 0 }
            let bg = Self.lum((key >> 16, (key >> 8) & 255, key & 255))
            let fg = px.map { Self.lum($0) }.max { abs($0 - bg) < abs($1 - bg) } ?? bg
            return (max(bg, fg) + 0.05) / (min(bg, fg) + 0.05)
        }
    }

    private func cells(of row: XCUIElement) -> [XCUIElement] {
        row.cells.allElementsBoundByIndex.sorted { $0.frame.minX < $1.frame.minX }
    }

    /// Two panels, FullRow off (the default), the system's appearance (the app has no appearance
    /// override and `-AppleInterfaceStyle` in argv does not reach it; Light and Dark are both
    /// rendered by the app-hosted `SelColorsTests`): the clicked panel shows the name on the
    /// highlight and every other column readable; clicking the other panel hides it.
    func testClickedSelectionIsReadableAndFollowsTheFocus() throws {
        let scratch = try makeScratch()
        let isDark = UserDefaults(suiteName: UserDefaults.globalDomain)?.string(forKey: "AppleInterfaceStyle") == "Dark"
        for style in [isDark ? "Dark" : "Light"] {
            launch(seed: .typed([SettingsDomain.Key.numPanels: 2,
                                 SettingsDomain.Key.panelPath0: scratch,
                                 SettingsDomain.Key.panelPath1: scratch]))
            XCTAssertTrue(sevenZip.ensurePanelCount(2))
            let left = sevenZip.panel(0), right = sevenZip.panel(1)
            XCTAssertTrue(left.waitForRow(named: "a.txt") && right.waitForRow(named: "b.bin"))

            left.select("a.txt")
            let row = left.row(named: "a.txt")
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            let leftCells = cells(of: row)
            XCTAssertGreaterThan(leftCells.count, 2, "\(style): cells of a.txt")
            XCTAssertGreaterThan(Pixels(leftCells[0]).highlightShare, 0.05, "\(style): the clicked name has no fill")
            for (i, cell) in leftCells.enumerated().dropFirst() where !(cell.staticTexts.firstMatch.value as? String ?? "").isEmpty {
                let p = Pixels(cell)
                XCTAssertGreaterThanOrEqual(p.contrast, 4.5, "\(style): column \(i) of the selected row is unreadable")
                XCTAssertLessThan(p.highlightShare, 0.01, "\(style): column \(i) is filled with FullRow off")
            }
            screenshot("input-\(style.lowercased())-left-focused")

            right.select("b.bin")
            XCTAssertLessThan(Pixels(cells(of: left.row(named: "a.txt"))[0]).highlightShare, 0.01,
                              "\(style): the inactive panel still draws its selection (7zFM shows none)")
            XCTAssertGreaterThan(Pixels(cells(of: right.row(named: "b.bin"))[0]).highlightShare, 0.05,
                                 "\(style): the focused panel's selection has no fill")
            screenshot("input-\(style.lowercased())-right-focused")
        }
    }
}
