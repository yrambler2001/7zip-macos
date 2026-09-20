// AboutAndDragOutTests.swift -- two defects that were filed across scopes and had no owner
// (`polish`, Mac/docs/reports/polish.md):
//
//   * the two IDM_ABOUT 961 menu items changed their accessibility identifier at launch, because
//     `ToolsCommands.install()` retargeted them and an NSMenuItem reports its *current* action
//     (Mac/docs/requests.md, `harness` -> `tools`/`panel`) -- the identifier half of that is now
//     asserted in process (`SevenZipAppTests/MenuAndToolbarTests`), the click half here;
//   * dragging a member out of an archive the panel had already unlocked asked for the password a
//     second time, because `ArchiveDragOut.extract` had no `password:` parameter
//     (Mac/docs/requests.md, `cleanup` -> `extract`).

import XCTest

final class AboutAndDragOutTests: SevenZipUITestCase {

    override var screenshotPrefix: String { "polish" }

    // MARK: - IDM_ABOUT 961

    /// The About item opens the real IDD_ABOUT 2900 dialog. That it is *addressable by the selector
    /// it is declared with* -- the defect this test was written for -- is now asserted without a
    /// launch in `SevenZipAppTests/MenuAndToolbarTests.testMenuItemsAreAddressableBySelector`, over
    /// the same `NSMenuItem` objects; what is left here is the click and the dialog, which need the
    /// running app.
    func testAboutItemOpensTheAboutDialog() {
        launch()
        XCTAssertTrue(sevenZip.window.waitForExistence(timeout: 30))
        XCTAssertTrue(sevenZip.selectMenuItem("7-Zip", "About 7-Zip..."))
        guard let about = sevenZip.waitForDialog(title: "About 7-Zip") else {
            return XCTFail("the About item did not open IDD_ABOUT 2900")
        }
        let texts = sevenZip.texts(of: about).joined(separator: " ")
        XCTAssertTrue(texts.contains("7-Zip"), "About texts: \(texts)")
        XCTAssertTrue(sevenZip.dismissDialog(about, button: "OK"))
    }

    // MARK: - drag-out of an encrypted archive

    /// Unlock `secret.7z`, then run the real file-promise drag-out (`SZ_POLISH_DRAGOUT`, see
    /// `PanelDragOutVerification`): the member must be written without a second password prompt.
    func testDragOutOfAnUnlockedArchiveDoesNotAskForThePasswordAgain() {
        let output = (TestPaths.artifacts as NSString)
            .appendingPathComponent("dragout-\(UUID().uuidString.prefix(8))")
        launch(seed: .values([SettingsDomain.Key.panelPath0: TestPaths.fixtures]),
               environment: ["SZ_POLISH_DRAGOUT": output])

        let panel = sevenZip.panel(0)
        XCTAssertTrue(panel.waitForRow(named: "secret.7z", timeout: 30))
        panel.open("secret.7z")
        guard let prompt = sevenZip.waitForDialog(title: "Enter password") else {
            return XCTFail("opening secret.7z did not ask for the password")
        }
        let field = prompt.secureTextFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no password field")
        field.click()
        field.typeText("secret")
        XCTAssertTrue(sevenZip.dismissDialog(prompt, button: "OK"))
        XCTAssertTrue(panel.waitForRow(named: "readme.txt", timeout: 20),
                      "listing after the password: \(panel.names)")

        panel.select("readme.txt")
        XCTAssertTrue(sevenZip.selectMenuItem("Tools", "Drag Out (verify)"),
                      "the SZ_POLISH_DRAGOUT hook did not install its menu item")

        // The second prompt is the defect. Measured without the fix, it is worse than a prompt:
        // the promise path has already parked the panel queue and hopped to the main thread, so
        // the app stops answering and the next assertion times out instead. Either way the two
        // assertions below are what fail when the password is not forwarded.
        XCTAssertNil(sevenZip.waitForDialog(title: "Enter password", timeout: 6),
                     "the drag-out asked for the password a second time")

        let marker = (output as NSString).appendingPathComponent("drag-out-done.txt")
        XCTAssertTrue(waitForFile(marker, timeout: 30), "the promise never completed")
        XCTAssertEqual(try? String(contentsOfFile: marker, encoding: .utf8), "ok")

        let extracted = (output as NSString).appendingPathComponent("readme.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: extracted), "nothing was extracted")
        XCTAssertEqual(try? String(contentsOfFile: extracted, encoding: .utf8).count, 12,
                       "readme.txt is 12 bytes in every fixture archive")
        screenshot("15-drag-out-encrypted")
        try? FileManager.default.removeItem(atPath: output)
    }

    private func waitForFile(_ path: String, timeout: TimeInterval) -> Bool {
        waitFor("the file \(path)", timeout: timeout) {
            FileManager.default.fileExists(atPath: path)
        }
    }
}
