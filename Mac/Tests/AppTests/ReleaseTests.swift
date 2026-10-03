// ReleaseTests.swift -- the backlog `mac/release` closed, asserted in the app's own process
// (`SevenZipAppTests`, see AppHostTestCase):
//
//   * IDS_SET_FOLDER 6007 has no built-in English string on Windows; the port's one fallback and
//     a language file's override (01b §4.5, PROGRESS 9.3);
//   * the launch-time temp sweep's selection rule (01 §1.1, §9 #11 -- an improvement, not parity);
//   * the codecs are loaded off the main thread after the window exists (FM.cpp:738-743);
//   * ShowRealFileIcons governs file-system icons (PanelItems.cpp:587).

import AppKit
import SevenZipKit
import XCTest
@testable import SevenZipAppHost

final class ReleaseTests: AppHostTestCase {

    override var screenshotPrefix: String { "release" }

    func testSetFolderFallbackAndLanguageOverride() {
        defer { useLanguage("-") }
        // The built-in English is the reference template's line (Lang/en.ttt: "Select destination
        // folder."), which the port also uses as the fallback at all four call sites.
        useLanguage("-")
        XCTAssertEqual(Lang.text(6007, "Select destination folder."), "Select destination folder.")
        useLanguage("de")
        XCTAssertEqual(Lang.text(6007, "Select destination folder."), "Zielordner auswählen")
        useLanguage("fr")
        XCTAssertEqual(Lang.text(6007, "Select destination folder."), "Sélectionner le dossier de destination.")
    }

    func testTempSweepTakesOnlyOldOwnFolders() {
        let now = Date()
        let old = now.addingTimeInterval(-2 * 60 * 60)
        let veryOld = now.addingTimeInterval(-2 * 24 * 60 * 60)
        let ages: [String: Date] = [
            "/t/7zO1A2B3C4D": old,          // stale open/edit folder: swept
            "/t/7zE00000001": old,          // stale drag folder: swept
            "/t/7zO99999999": now,          // fresh: kept
            "/t/7zE-1234-uuid": old,        // e-mail folder younger than a day: kept
            "/t/7zE-5678-uuid": veryOld,    // e-mail folder older than a day: swept
            "/t/other": veryOld,            // not ours: kept
        ]
        let swept = TempOpenJanitor.staleDirectories(Array(ages.keys), now: now) { ages[$0] }
        XCTAssertEqual(Set(swept), ["/t/7zO1A2B3C4D", "/t/7zE00000001", "/t/7zE-5678-uuid"])
        // A folder whose date cannot be read is never taken.
        XCTAssertTrue(TempOpenJanitor.staleDirectories(["/t/7zOFFFFFFFF"], now: now) { _ in nil }.isEmpty)
    }

    func testCodecsAreLoadedAfterLaunch() {
        // The window is created first and the table is built on a worker; by the time a test runs
        // it is there, and every reader sees the same full table.
        let deadline = Date().addingTimeInterval(10)
        while !SZCodecs.isLoaded, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(SZCodecs.isLoaded)
        XCTAssertGreaterThan(SZCodecs.formats.count, 50)
    }

    func testShowRealFileIconsGovernsFileSystemIcons() {
        let saved = Settings.showRealFileIcons
        defer { Settings.showRealFileIcons = saved }
        Settings.showRealFileIcons = false                  // the Windows default
        XCTAssertFalse(PanelIcons.showsRealIcons(isFileSystem: true, isVolumesFolder: false, isRoot: false))
        XCTAssertTrue(PanelIcons.showsRealIcons(isFileSystem: true, isVolumesFolder: true, isRoot: false))
        XCTAssertTrue(PanelIcons.showsRealIcons(isFileSystem: false, isVolumesFolder: false, isRoot: true))
        XCTAssertTrue(PanelIcons.showsRealIcons(isFileSystem: false, isVolumesFolder: false, isRoot: false))
        Settings.showRealFileIcons = true
        XCTAssertTrue(PanelIcons.showsRealIcons(isFileSystem: true, isVolumesFolder: false, isRoot: false))

        // Outside a file-system folder (no snapshot here) the real icon is used even with it off.
        Settings.showRealFileIcons = false
        let row = PanelRow(engineIndex: 0, name: "Calculator.app", displayName: "Calculator.app",
                           isDirectory: true, size: 0, isPackage: true,
                           fullPath: "/System/Applications/Calculator.app")
        var cache: [String: NSImage] = [:]
        _ = PanelIcons.icon(for: row, snapshot: nil, cache: &cache, large: false)
        XCTAssertFalse(cache.isEmpty, "no snapshot = not a file-system folder: the real icon is cached")
    }

    /// IDI_LOGO: the About box shows 7zipLogo.ico's 110 x 63 wordmark at its real size
    /// (AboutDialog.rc:21, requests.md icons -> tools).
    func testAboutShowsTheWordmark() {
        let appeared = ModalProbe.present({ AboutDialog.show() }) { window in
            func imageViews(_ view: NSView?) -> [NSImageView] {
                guard let view else { return [] }
                return [view as? NSImageView].compactMap { $0 } + view.subviews.flatMap { imageViews($0) }
            }
            let logo = imageViews(window.contentView).first { $0.accessibilityIdentifier() == "aboutLogo" }
            XCTAssertNotNil(logo, "no logo view")
            XCTAssertEqual(logo?.image?.size, NSSize(width: 110, height: 63))
            XCTAssertEqual(logo?.frame.size, NSSize(width: 110, height: 63))
            _ = self.attach(window, "01-about-logo")
        }
        XCTAssertTrue(appeared)
    }
}
