// LayoutSweepTests.swift -- opens every window and dialog the app has, measures its geometry with
// `LayoutAudit` and captures a screenshot of each (`polish` scope, Mac/docs/reports/polish.md).
//
// Why measure instead of eyeballing: the Copy dialog's clipped buttons were in the accessibility
// tree and clickable, so every functional test passed while the window looked cut off. A window
// that opens is not a window that is laid out.
//
// The per-dialog screenshots are the second half of the check -- truncation and crowding do not
// show up in a frame -- and are exported to Mac/docs/reports/screenshots/polish-*.png.

import XCTest

final class LayoutSweepTests: SevenZipUITestCase {

    override var screenshotPrefix: String { "polish" }

    private var defects: [String] = []

    // MARK: - helpers

    /// Audit one window: print the row for the report table, screenshot it, collect hard defects.
    private func sweep(_ window: XCUIElement, _ name: String, shot: String?) {
        guard window.exists else {
            defects.append("MISSING \(name): the window is not in the tree")
            return
        }
        let report = LayoutAudit.report(window, name: name)
        print("SWEEP | \(name) | \(LayoutAudit.size(window)) | "
              + (report.isEmpty ? "clean" : "\(report.count) finding(s)")
              + " | frame=\(window.frame) main=\(sevenZip.window.frame)")
        for line in report { print("SWEEP   \(line)") }
        if let shot { capture(window, shot) }
        defects += report.filter(LayoutAudit.isHardDefect)
    }

    /// A screenshot of *this* window, not of the app's first window: a dialog is centred over the
    /// main window and `SevenZipApp.screenshot` would clip whatever falls outside it.
    private func capture(_ element: XCUIElement, _ name: String) {
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = "\(screenshotPrefix)-\(name).png"      // test.sh matches this name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func finish(_ what: String) {
        XCTAssertTrue(defects.isEmpty, "\(what):\n" + defects.joined(separator: "\n"))
        defects = []
    }

    private func fixturePanel(twoPanels: Bool = false) -> SevenZipPanel {
        launch(seed: .typed([SettingsDomain.Key.panelPath0: TestPaths.fixtures,
                             SettingsDomain.Key.panelPath1: TestPaths.fixtures,
                             SettingsDomain.Key.numPanels: twoPanels ? 2 : 1]))
        let panel = sevenZip.panel(0)
        XCTAssertTrue(panel.waitForRow(named: "test.7z", timeout: 30), "no fixtures listing")
        return panel
    }

    /// Open a dialog from a menu path, audit it, screenshot it and close it again.
    private func sweepMenuDialog(_ menu: [String], title: String, name: String, shot: String,
                                 close: String = "Cancel", settle: useconds_t = 500_000) {
        let opened: Bool
        switch menu.count {
        case 2: opened = sevenZip.selectMenuItem(menu[0], menu[1])
        case 3: opened = sevenZip.selectMenuItem(menu[0], menu[1], menu[2])
        default: opened = false
        }
        guard opened else {
            defects.append("MISSING \(name): the menu item \(menu.joined(separator: " > ")) did not open")
            return
        }
        usleep(settle)
        guard let dialog = sevenZip.waitForDialog(title: title) else {
            defects.append("MISSING \(name): no dialog titled \"\(title)\"; on screen: \(windowTitles())")
            return
        }
        sweep(dialog, name, shot: shot)
        if !sevenZip.dismissDialog(dialog, button: close) {
            dialog.typeKey(.escape, modifierFlags: [])
        }
        _ = sevenZip.waitForNoDialog(timeout: 5)
    }

    // MARK: - the main window (01 section 1.2)

    func testMainWindowLayout() {
        continueAfterFailure = true
        _ = fixturePanel()
        sweep(sevenZip.window, "Main window, 1 panel", shot: "20-main-one-panel")
        XCTAssertTrue(sevenZip.ensurePanelCount(2))
        sweep(sevenZip.window, "Main window, 2 panels", shot: "21-main-two-panels")
        finish("main window")
    }

    /// Everything on the File menu that opens a dialog for a file-system selection.
    func testFileMenuDialogs() {
        continueAfterFailure = true
        let panel = fixturePanel(twoPanels: true)
        panel.select("test.7z")

        sweepMenuDialog(["File", "Copy To..."], title: "Copy",
                        name: "Copy (IDD_COPY 3200)", shot: "22-copy")
        sweepMenuDialog(["File", "Move To..."], title: "Move",
                        name: "Move (IDD_COPY 3200, move)", shot: "23-move")
        sweepMenuDialog(["File", "Properties"], title: "Properties",
                        name: "Properties (IDD_LISTVIEW 99 / IDS_PROPERTIES 6600)", shot: "24-properties",
                        close: "OK", settle: 1_500_000)
        sweepMenuDialog(["File", "Create Folder"], title: "Create Folder",
                        name: "Create Folder (combo dialog, IDD_COMBO)", shot: "25-create-folder")
        sweepMenuDialog(["File", "Split file..."], title: "Split File",
                        name: "Split (IDD_SPLIT 7300)", shot: "26-split")
        sweepMenuDialog(["File", "Link..."], title: "Link",
                        name: "Link (IDD_LINK 7700)", shot: "27-link")
        sweepMenuDialog(["View", "Folders History..."], title: "Folders History",
                        name: "Folders History (generic list dialog)", shot: "28-folders-history")
        finish("File menu dialogs")
    }

    /// Combine needs a multi-volume set; the fixtures hold multi.7z.001..003.
    func testCombineDialog() {
        continueAfterFailure = true
        let panel = fixturePanel()
        guard panel.hasRow(named: "multi.7z.001") else {
            return skip("no multi-volume fixture")
        }
        panel.select("multi.7z.001")
        sweepMenuDialog(["File", "Combine files..."], title: "Combine Files multi.7z.001",
                        name: "Combine (IDD_COMBINE 7400)", shot: "29-combine")
        finish("Combine")
    }

    /// File > CRC > MD5 hashes the selection and shows the results list.
    func testHashResultsDialog() {
        continueAfterFailure = true
        let panel = fixturePanel()
        panel.select("test.7z")
        sweepMenuDialog(["File", "CRC", "MD5"], title: "Checksum information",
                        name: "Checksum information (IDD_LISTVIEW 99 / IDS_CHECKSUM 7501)",
                        shot: "30-hash-results", close: "OK", settle: 2_000_000)
        finish("hash results")
    }

    /// The Tools menu: Benchmark and the temporary-files browser, plus About.
    func testToolsAndAboutDialogs() {
        continueAfterFailure = true
        _ = fixturePanel()
        sweepMenuDialog(["7-Zip", "About 7-Zip..."], title: "About 7-Zip",
                        name: "About (IDD_ABOUT 2900)", shot: "31-about", close: "OK")
        sweepMenuDialog(["Tools", "Benchmark"], title: "Benchmark",
                        name: "Benchmark (IDD_BENCHMARK 7600)", shot: "32-benchmark",
                        close: "Cancel", settle: 2_000_000)
        sweepMenuDialog(["Tools", "Delete Temporary Files..."], title: "Delete Temporary Files",
                        name: "Temporary files browser", shot: "33-temp-files",
                        close: "Cancel", settle: 1_000_000)
        finish("Tools and About")
    }

    /// All seven Options pages (OptionsDialog.cpp:13-20 order, Plugins last and macOS only).
    func testOptionsPages() {
        continueAfterFailure = true
        _ = fixturePanel()
        XCTAssertTrue(sevenZip.selectMenuItem("Tools", "Options..."))
        guard let options = sevenZip.waitForDialog(title: "Options") else {
            defects.append("MISSING Options: no window")
            return finish("Options")
        }
        usleep(1_000_000)
        // NSTabView's tabs are the direct children of the AXTabGroup, and only those: the pages
        // themselves are full of radio buttons, so `options.radioButtons` is not the tab strip.
        var tabs = tabStrip(of: options)
        if tabs.count != 7 {
            print("SWEEP options tree:\n\(options.debugDescription)")
            tabs = []
        }
        XCTAssertEqual(tabs.count, 7, "expected seven Options pages")
        for (index, tab) in tabs.enumerated() {
            click(in: options, at: tab.1)
            usleep(800_000)
            sweep(options, "Options > \(tab.0)", shot: String(format: "34-options-%d-%@", index + 1,
                                                             slug(tab.0)))
        }
        options.typeKey(.escape, modifierFlags: [])
        _ = sevenZip.waitForNoDialog(timeout: 5)
        finish("Options pages")
    }

    /// Compress (IDD_COMPRESS 4000) and its Options sheet (IDD_COMPRESS_OPTIONS 2100).
    func testCompressDialogs() {
        continueAfterFailure = true
        let panel = fixturePanel()
        panel.select("test.7z")
        let addButton = sevenZip.toolbarButton("Add")
        XCTAssertTrue(addButton.exists, "no Add toolbar button")
        addButton.click()
        guard let compress = sevenZip.waitForDialog(title: "Add to archive", timeout: 40) else {
            defects.append("MISSING Compress: no dialog; on screen: \(windowTitles())")
            return finish("Compress")
        }
        usleep(1_500_000)
        sweep(compress, "Compress (IDD_COMPRESS 4000)", shot: "35-compress")

        let optionsButton = compress.buttons.matching(
            NSPredicate(format: "title == %@ OR label == %@", "Options", "Options")).firstMatch
        if optionsButton.exists {
            optionsButton.click()
            usleep(1_200_000)
            // The sheet is titled "Options" too, so take the newest sheet on the compress window.
            let sheet = compress.sheets.firstMatch.exists ? compress.sheets.firstMatch
                                                          : (sevenZip.waitForDialog(title: "Options") ?? compress)
            sweep(sheet, "Compress Options sheet (IDD_COMPRESS_OPTIONS)", shot: "36-compress-options")
            if !sevenZip.dismissDialog(sheet, button: "Cancel") {
                sheet.typeKey(.escape, modifierFlags: [])
            }
            usleep(600_000)
        } else {
            defects.append("MISSING Compress Options: no Options button on the Compress dialog")
        }
        if !sevenZip.dismissDialog(compress, button: "Cancel") {
            compress.typeKey(.escape, modifierFlags: [])
        }
        _ = sevenZip.waitForNoDialog(timeout: 5)
        finish("Compress")
    }

    /// Extract (IDD_EXTRACT 3400) from the toolbar, with an archive selected.
    func testExtractDialog() {
        continueAfterFailure = true
        let panel = fixturePanel()
        panel.select("test.7z")
        sevenZip.toolbarButton("Extract").click()
        guard let extract = sevenZip.waitForDialog(title: "Extract") else {
            defects.append("MISSING Extract: no dialog")
            return finish("Extract")
        }
        usleep(1_200_000)
        sweep(extract, "Extract (IDD_EXTRACT 3400)", shot: "37-extract")
        if !sevenZip.dismissDialog(extract, button: "Cancel") {
            extract.typeKey(.escape, modifierFlags: [])
        }
        _ = sevenZip.waitForNoDialog(timeout: 5)
        finish("Extract")
    }

    /// Comment (IDD_COMMENT 6400) and the Password prompt, both inside an archive.
    func testArchiveDialogs() {
        continueAfterFailure = true
        let panel = fixturePanel()
        panel.select("test.zip")
        sweepMenuDialog(["File", "Comment..."], title: "Comment",
                        name: "Comment (IDD_COMMENT 6400)", shot: "38-comment",
                        settle: 1_000_000)

        // Opening an encrypted archive asks for the password (IDD_PASSWORD 3800).
        panel.open("secret.7z")
        guard let password = sevenZip.waitForDialog(title: "Enter password") else {
            defects.append("MISSING Password: opening secret.7z did not ask")
            return finish("archive dialogs")
        }
        sweep(password, "Password (IDD_PASSWORD 3800)", shot: "39-password")
        if !sevenZip.dismissDialog(password, button: "Cancel") {
            password.typeKey(.escape, modifierFlags: [])
        }
        _ = sevenZip.waitForNoDialog(timeout: 5)
        finish("archive dialogs")
    }

    /// Progress (IDD_PROGRESS 100) during a real extraction, through the opsinfra demo hook.
    func testProgressDialog() {
        continueAfterFailure = true
        launch(seed: .values([SettingsDomain.Key.panelPath0: TestPaths.fixtures]),
               environment: ["SZ_OPSINFRA_DEMO": "extract", "SZ_OPSINFRA_HOLD": "20"])
        guard let progress = sevenZip.waitForDialog(title: "Extracting", timeout: 30) else {
            defects.append("MISSING Progress: the demo did not show it")
            return finish("Progress")
        }
        usleep(1_500_000)
        sweep(progress, "Progress (IDD_PROGRESS 100)", shot: "40-progress")
        if !sevenZip.dismissDialog(progress, button: "Cancel") {
            progress.typeKey(.escape, modifierFlags: [])
        }
        finish("Progress")
    }

    /// Overwrite, the two Password variants, Messages and Memory usage, in the order the
    /// opsinfra demo shows them.
    func testOperationDialogs() {
        continueAfterFailure = true
        launch(seed: .values([SettingsDomain.Key.panelPath0: TestPaths.fixtures]),
               environment: ["SZ_OPSINFRA_DEMO": "dialogs"])
        let expected: [(title: String, name: String, shot: String, close: String)] = [
            ("Confirm File Replace", "Overwrite (IDD_OVERWRITE 3500)", "41-overwrite", "Cancel"),
            ("Enter password", "Password, extract side (IDD_PASSWORD 3800)", "42-password-extract", "Cancel"),
            ("Enter password", "Password, compress side (IDD_PASSWORD 3800)", "43-password-compress", "Cancel"),
            ("7-Zip: Diagnostic messages", "Messages (IDD_MESSAGES 100)", "44-messages", "Close"),
            ("Memory usage request", "Memory usage (IDD_MEMORY_USE 7800)", "45-memory", "Cancel"),
        ]
        for step in expected {
            guard let dialog = sevenZip.waitForDialog(title: step.title, timeout: 30) else {
                defects.append("MISSING \(step.name): the demo did not show it")
                continue
            }
            usleep(500_000)
            sweep(dialog, step.name, shot: step.shot)
            if !sevenZip.dismissDialog(dialog, button: step.close) {
                dialog.typeKey(.escape, modifierFlags: [])
            }
            _ = sevenZip.waitForNoDialog(timeout: 8)
        }
        finish("operation dialogs")
    }

    // MARK: - small helpers

    /// The tab strip of an NSTabView: (label, frame) for each direct child of the AXTabGroup.
    private func tabStrip(of window: XCUIElement) -> [(String, CGRect)] {
        guard let snapshot = try? window.snapshot() else { return [] }
        func tabGroup(_ node: XCUIElementSnapshot) -> XCUIElementSnapshot? {
            if node.elementType == .tabGroup { return node }
            for child in node.children {
                if let found = tabGroup(child) { return found }
            }
            return nil
        }
        guard let group = tabGroup(snapshot) else { return [] }
        return group.children
            .filter { $0.elementType == .tab || $0.elementType == .radioButton }
            .map { ($0.title.isEmpty ? $0.label : $0.title, $0.frame) }
    }

    /// Click a point given in screen coordinates, through `window`'s coordinate space.
    private func click(in window: XCUIElement, at rect: CGRect) {
        let origin = window.frame.origin
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: rect.midX - origin.x, dy: rect.midY - origin.y))
            .click()
    }

    /// What the app has on screen, for a MISSING diagnosis.
    private func windowTitles() -> String {
        let windows = app.windows.allElementsBoundByAccessibilityElement.map {
            "\($0.title)\(LayoutAudit.size($0))"
        }
        let sheets = app.sheets.allElementsBoundByAccessibilityElement.map { "sheet:\($0.title)" }
        let dialogs = app.dialogs.allElementsBoundByAccessibilityElement.map {
            "dialog:\($0.title)[\(sevenZip.texts(of: $0).joined(separator: " / "))]"
        }
        return (windows + sheets + dialogs).joined(separator: ", ")
    }

    private func slug(_ text: String) -> String {
        let cleaned = text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(String(cleaned).prefix(20))
    }

    /// Not `XCTSkip`: the sweep keeps going and says so in the log.
    private func skip(_ message: String) {
        print("SWEEP skipped: \(message)")
    }
}
