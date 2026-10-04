// AppHostTestCase.swift -- base class of the `SevenZipAppTests` target: XCTest cases that run
// **inside 7-Zip.app's own process** (`TEST_HOST`), so they get real AppKit objects, real Auto
// Layout, the real lang files and the app's real menu bar at unit-test speed.
//
// Why this target exists (Mac/docs/reports/fastui.md): the XCUITest suite cost 28.7 s per test,
// almost all of it launching and quitting the app. An assertion about a *frame*, a menu title or a
// localized string does not need another process to be launched and driven through the
// accessibility bus -- it needs the object. Here the object is right there:
//
//   * `NSApp.mainMenu` is the menu the app built with `MainMenu.build()`;
//   * a dialog is `CopyMoveDialog.run(...)`, probed with `ModalProbe` while it is on screen;
//   * a language is `SZLang.shared.loadLanguage(code:)`, 93 of them in one test instead of 93
//     app launches.
//
// House rules for this target:
//
//   * Main thread only. Every window, panel and dialog of the app is main-thread-only, and XCTest
//     runs these cases on the main thread; `setUp` asserts it rather than letting a stray thread
//     corrupt AppKit.
//   * Leave the app as you found it. The host app keeps running for the whole test bundle, so a
//     test that loads a language, opens a window or registers an `ActiveContext` provider must put
//     it back in `tearDown` -- otherwise it has silently written the next test's fixture.
//   * No synthesized input, ever. These tests are not allowed to depend on being frontmost, which
//     is what lets them run while an XCUITest shard drives another instance.

import AppKit
import SevenZipKit
import XCTest
@testable import SevenZipAppHost

class AppHostTestCase: XCTestCase {

    /// File-name prefix of the PNGs this class writes into `Mac/docs/reports/screenshots/`.
    var screenshotPrefix: String { "fastui" }

    /// Hard defects collected by `audit(...)`; `finishAudit()` fails the test with all of them.
    private(set) var defects: [String] = []
    /// TIGHT warnings collected by `audit(...)` -- printed, never failed on.
    private(set) var warnings: [String] = []

    private var savedLanguageCode: String?
    private var savedContextProvider: OperationContextProviding?

    /// The host app must not read or write the developer's preferences: it is a real 7-Zip process
    /// and it saves its window state, its column layout and its splitter ratio on the way out.
    ///
    /// Two belts. The scheme's test action launches it with `SEVENZIP_DEFAULTS_SUITE` pointing at a
    /// throwaway plist, which covers the app's own launch; and this runs before the first case and
    /// calls `setenv` as well, because `NMacPrefs::ApplicationID()` re-reads the variable on every
    /// access (MacPrefs.cpp:23-28) -- so even if the scheme's variable does not arrive, nothing a
    /// test does afterwards can reach `com.yrambler2001.7zip`. Asserted, not assumed:
    /// `HostTargetTests.testSettingsAreIsolatedFromTheRealDomain`.
    static let isolatedFromRealSettings: String = {
        if SZSettings.usesOverrideSuite { return SZSettings.applicationID }
        let directory = (TestPaths.repoRoot.map { $0 + "/Mac/build" }) ?? TestPaths.artifacts
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = (directory as NSString).appendingPathComponent("hostapp-defaults.plist")
        if !FileManager.default.fileExists(atPath: path) {
            let seed: [String: Any] = ["Lang": "-", "FM.Panels.numPanels": 1]
            try? PropertyListSerialization.data(fromPropertyList: seed, format: .xml, options: 0)
                .write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        setenv("SEVENZIP_DEFAULTS_SUITE", path, 1)
        return SZSettings.applicationID
    }()

    override func setUpWithError() throws {
        try super.setUpWithError()
        XCTAssertTrue(Thread.isMainThread, "the app-hosted tests must run on the main thread")
        XCTAssertNotNil(NSApp, "no NSApplication: the target is not hosted by 7-Zip.app")
        XCTAssertTrue(SZSettings.usesOverrideSuite,
                      "the host app writes \(Self.isolatedFromRealSettings); it must not be the "
                      + "developer's own preferences domain")
        continueAfterFailure = false
        defects = []
        warnings = []
        savedLanguageCode = SZLang.shared.currentLanguageCode
        savedContextProvider = ActiveContext.provider
        // Titles are asserted against the English resource text, exactly as the XCUITest suite
        // asserted them with `Lang = "-"` in the settings domain.
        useLanguage("-")
        // Every message box is recorded (`recordedBoxes`), and an error report nobody waits for
        // (`WinMessageBox.show`, what used to be a sheet that stayed up unnoticed, modal since
        // recheck2) is answered at once with its Esc answer, so a stray report never wedges the
        // suite. A question (`WinMessageBox.run`) is left to the test's own answerer. A test that
        // drives boxes itself sets its own observers and puts `recordAndDismissReports` back.
        recordedBoxes = []
        WinMessageBox.observers = [recordAndDismissReports]
    }

    struct RecordedBox {
        let caption: String
        let text: String
        weak var owner: NSWindow?
        let asynchronous: Bool
    }

    /// Every box shown since setUp (or `recordedBoxes = []`), oldest first.
    var recordedBoxes: [RecordedBox] = []

    /// The text of the last box owned by `window` -- what used to be "the sheet on the window".
    func boxText(ownedBy window: NSWindow?) -> String? {
        recordedBoxes.last { $0.owner != nil && $0.owner === window }?.text
    }

    lazy var recordAndDismissReports: (WinMessageBoxWindow) -> Void = { [weak self] box in
        self?.recordedBoxes.append(RecordedBox(caption: box.caption, text: box.message, owner: box.ownerWindow,
                                               asynchronous: box.isAsynchronous))
        Self.dismissStrayReports(box)
    }

    static let dismissStrayReports: (WinMessageBoxWindow) -> Void = { box in
        guard box.isAsynchronous else {
            // a question a test did not script: say who asked, the test's own watcher answers it
            print("APPHOST | message box [\(box.caption)]: \(box.message)\n"
                  + Thread.callStackSymbols.prefix(14).joined(separator: "\n"))
            return
        }
        print("APPHOST | report [\(box.caption)] over '\(box.ownerWindow?.title ?? "-")': \(box.message)\n"
              + Thread.callStackSymbols.prefix(16).joined(separator: "\n"))
        RunLoop.main.perform(inModes: [.modalPanel, .default, .common]) { [weak box] in
            guard let box, box.isVisible else { return }
            box.answer(box.boxButtons.escapeResult ?? .no)
        }
    }

    // MARK: - language

    /// Load one language file ("-" = built-in English, "" = system). Fails the test if the file
    /// does not load, because every assertion after it would be about the wrong strings.
    func useLanguage(_ code: String, file: StaticString = #filePath, line: UInt = #line) {
        do {
            try SZLang.shared.loadLanguage(code: code)
        } catch {
            XCTFail("language '\(code)' did not load: \(error)", file: file, line: line)
        }
    }

    // MARK: - audit

    /// Audit one window: record the report line, screenshot it, collect the hard defects. The same
    /// contract as `LayoutSweepTests.sweep` had, minus the app launch.
    func audit(_ window: NSWindow, _ name: String, shot: String? = nil) {
        let report = WindowAudit.report(window, name: name)
        let hard = report.filter(WindowAudit.isHardDefect)
        print("SWEEP | \(name) | \(WindowAudit.size(window)) | "
              + (report.isEmpty ? "clean" : "\(report.count) finding(s)"))
        for line in report { print("SWEEP   \(line)") }
        if let shot { attach(window, shot) }
        defects += hard
        warnings += report.filter { !WindowAudit.isHardDefect($0) }
    }

    /// Fail once with every hard defect the audits found.
    func finishAudit(_ what: String, file: StaticString = #filePath, line: UInt = #line) {
        if !warnings.isEmpty {
            print("SWEEP \(warnings.count) warning(s) in \(what) (truncation heuristics, not failures)")
        }
        XCTAssertTrue(defects.isEmpty, "\(what):\n" + defects.joined(separator: "\n"),
                      file: file, line: line)
        defects = []
        warnings = []
    }

    // MARK: - screenshots

    /// A PNG of the window's content view, attached to the result **and** written straight into
    /// `Mac/docs/reports/screenshots/` -- unlike the XCUITest runner this process is not
    /// sandboxed, so `test.sh` does not have to export it from the result bundle.
    @discardableResult
    func attach(_ window: NSWindow, _ name: String) -> URL? {
        guard let content = window.contentView else { return nil }
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        let bounds = content.bounds
        guard bounds.width > 1, bounds.height > 1,
              let rep = content.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        content.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else { return nil }
        let base = name.hasPrefix(screenshotPrefix + "-") ? name : "\(screenshotPrefix)-\(name)"
        let file = base.hasSuffix(".png") ? base : base + ".png"
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = file
        attachment.lifetime = XCTAttachment.Lifetime.keepAlways
        add(attachment)
        let directory = TestPaths.screenshots
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: directory).appendingPathComponent(file)
        do {
            try png.write(to: url, options: Data.WritingOptions.atomic)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - run loop

    /// Let the main run loop turn until `condition` holds (the panels read folders on their own
    /// queue and call back to the main thread). Never a fixed sleep.
    @discardableResult
    func wait(for what: String, timeout: TimeInterval = 20, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return condition()
    }
}
