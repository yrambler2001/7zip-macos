// OkCancelTests.swift -- the okcancel scope (Mac/docs/reports/okcancel.md): "I right-clicked a row,
// chose 7-Zip > Add to archive... / Compress and email..., and SOMETIMES OK and Cancel don't work,
// while Help and the red close button work."
//
// Root cause (measured with real input in OkCancelUITests): `WinComboHover`, the tracking-area
// owner of every Windows-style combo / drop-down, was a plain NSObject whose Swift method
// `mouseEntered(with:)` has the selector `mouseEnteredWith:`. AppKit sends `mouseEntered:`, so the
// first time the mouse crossed a combo of a key dialog it raised "unrecognized selector"; inside
// `NSApp.runModal(for:)` that exception unwound the modal session and left the dialog on screen
// with no session -- OK / Cancel (`stopModal()`) did nothing, Help and the close box still worked.
//
// The app-hosted half, three checks over every dialog of the port:
//   * every tracking area's owner answers the selectors its options make AppKit send;
//   * an exception raised inside a dialog's modal session no longer ends the session
//     (`DialogKit.runModal`), so OK / Cancel keep working after any such bug;
//   * hypothesis (a) of the report, rejected: in six languages a click at the centre of every
//     visible, enabled control reaches that control (`NSView.hitTest`) -- nothing lies on top.

import AppKit
import SevenZipKit
import XCTest
@testable import SevenZipAppHost

final class OkCancelTests: AppHostTestCase {

    override var screenshotPrefix: String { "okcancel" }

    override func tearDown() {
        useLanguage("-")
        super.tearDown()
    }

    private var fixtures: String { TestPaths.fixtures }
    private var archive: String { TestPaths.fixture("test.7z") }

    struct Probe {
        let name: String
        var timeout: TimeInterval = 30
        let present: () -> Void
    }

    /// Every dialog of the port, built as the app builds it (SFFontTests' list).
    private func probes() -> [Probe] {
        let fixtures = self.fixtures, archive = self.archive
        var list: [Probe] = [
            Probe(name: "About (IDD_ABOUT)") { AboutDialog.show(parent: nil) },
            Probe(name: "Copy (IDD_COPY)") {
                _ = CopyMoveDialog.run(move: false, value: fixtures + "/", history: [fixtures], info: archive, parent: nil)
            },
            Probe(name: "Move (IDD_COPY)") {
                _ = CopyMoveDialog.run(move: true, value: fixtures + "/", history: [], info: "", parent: nil)
            },
            Probe(name: "Create Folder (IDD_COMBO)") {
                _ = ComboDialog.run(title: Lang.text(6300, "Create Folder"), label: Lang.text(6302, "Folder name:"),
                                    value: Lang.text(6304, "New Folder"), parent: nil)
            },
            Probe(name: "Select (IDD_COMBO)") {
                _ = ComboDialog.run(title: Lang.text(6402, "Select"), label: Lang.text(6404, "Mask:"), value: "*",
                                    strings: ["*"], parent: nil)
            },
            Probe(name: "Comment (IDD_COMMENT)") { _ = CommentDialog.run(value: "", parent: nil) },
            Probe(name: "Split (IDD_SPLIT)") { _ = SplitDialog.run(filePath: archive, path: fixtures, parent: nil) },
            Probe(name: "Combine (IDD_COMBO)") {
                _ = CombineDialog.run(title: Lang.text(7400, "Combine Files"), prompt: Lang.text(7402, "Combine to:"),
                                      info: TestPaths.fixture("multi.7z.001"), path: fixtures, parent: nil)
            },
            Probe(name: "Link (IDD_LINK)") {
                _ = LinkDialog.run(currentDirPrefix: fixtures + "/", filePath: archive,
                                   anotherPath: TestPaths.realHome, parent: nil)
            },
            Probe(name: "Folders History (IDD_LISTVIEW)") {
                var history = ListViewDialogOptions()
                history.title = Lang.text(6601, "Folders History")
                history.strings = [fixtures, "/tmp"]
                history.deleteIsAllowed = true
                _ = ListViewDialog.run(history, parent: nil)
            },
            Probe(name: "Delete Temporary Files (IDD_TEMP_FILES)") { ToolsTempFilesDialog.show(parent: nil) },
            Probe(name: "Benchmark (IDD_BENCH)", timeout: 60) { BenchmarkDialog.run(totalMode: false, parent: nil) },
            Probe(name: "Extract (IDD_EXTRACT)") {
                var extract = ExtractDialog.Options()
                extract.directoryPath = fixtures + "/"
                extract.archivePath = archive
                _ = ExtractDialog.run(extract)
            },
            Probe(name: "Add to Archive (IDD_COMPRESS)", timeout: 60) {
                var input = CompressDialogInput()
                input.directoryPrefix = fixtures + "/"
                input.archiveBaseName = fixtures + "/test"
                input.itemPaths = [archive]
                _ = CompressDialogController.run(input)
            },
            Probe(name: "Overwrite (IDD_OVERWRITE)") {
                let old = OverwriteDialog.FileInfo(path: archive, size: 838, time: Date())
                let new = OverwriteDialog.FileInfo(path: TestPaths.fixture("test.zip"), size: 1024, time: Date())
                _ = OverwriteDialog.run(oldFile: old, newFile: new, showExtraButtons: true, parent: nil)
            },
            Probe(name: "Password (IDD_PASSWORD)") {
                var pw = PasswordDialog.Options()
                pw.subject = archive
                pw.requiresVerification = true
                pw.showsEncryptFileNames = true
                _ = PasswordDialog.run(pw, parent: nil)
            },
            Probe(name: "Messages (IDD_MESSAGES)") { MessagesDialog.show(messages: ["a : CRC failed"], parent: nil) },
            Probe(name: "Memory (IDD_MEM)") {
                var memory = MemoryUseDialog.Options()
                memory.requiredGB = 4
                memory.limitGB = 2
                memory.ramGB = 16
                memory.filePath = "sub/big.txt"
                memory.archivePath = archive
                memory.showRemember = true
                _ = MemoryUseDialog.run(memory, parent: nil)
            },
            Probe(name: "Message box") {
                _ = WinMessageBox.run(Lang.text(6000, "Copy") + ": " + archive, caption: "7-Zip",
                                      buttons: .yesNoCancel, icon: .question, owner: nil)
            },
        ]
        if (try? SZCodecs.loadCodecs()) != nil {
            for name in ["7z", "zip"] {
                guard let f = SZCodecs.format(named: name) else { continue }
                list.append(Probe(name: "Compress Options \(name) (IDD_COMPRESS_OPTIONS)") {
                    var state = CompressOptionsSheet.State(
                        formatName: f.name, formatTimeFlags: f.timeFlags, formatFlags: f.flags,
                        supportsMTime: f.supportsMTime, supportsCTime: f.supportsCTime, supportsATime: f.supportsATime,
                        supportsSymLinks: f.supportsSymLinks, supportsHardLinks: f.supportsHardLinks,
                        supportsAltStreams: f.supportsAltStreams, supportsNtSecurity: f.supportsNtSecurity,
                        isTar: false, isZip: name == "zip", isGZip: false,
                        isKeepName: f.keepName, tarMethodName: "")
                    _ = CompressOptionsSheet.run(&state, parent: nil)
                })
            }
            if let results = try? SZHasher.hash(paths: ["test.7z"], relativeTo: fixtures, methods: ["CRC32", "SHA256"],
                                                recursive: false, progress: nil) {
                list.append(Probe(name: "Checksum (IDD_LISTVIEW)") { HashResultsDialog.show(results: results, parent: nil) })
            }
        }
        return list
    }

    // MARK: - hit testing

    private static func isShown(_ view: NSView) -> Bool {
        var v: NSView? = view
        while let current = v {
            if current.isHidden || current.alphaValue < 0.01 { return false }
            v = current.superview
        }
        return true
    }

    private static func controls(_ root: NSView) -> [NSControl] {
        var found: [NSControl] = []
        for child in root.subviews where !child.isHidden {
            if child is NSScrollView { continue }
            if let tabs = child as? NSTabView {
                if let page = tabs.selectedTabViewItem?.view { found += controls(page) }
                continue
            }
            if let control = child as? NSControl { found.append(control); continue }
            found += controls(child)
        }
        return found
    }

    private static func describe(_ view: NSView?) -> String {
        guard let view else { return "nothing" }
        let text = (view as? NSButton)?.title ?? (view as? NSTextField)?.stringValue ?? ""
        return "\(type(of: view)) '\(text.prefix(30))' \(NSStringFromRect(view.frame))"
    }

    /// The controls of `window` whose centre (and the centre of their inner half) a click does not
    /// reach: something else is on top of them.
    static func covered(in window: NSWindow, buttonsOnly: Bool = false) -> [String] {
        guard let content = window.contentView, let frameView = content.superview else { return [] }
        content.layoutSubtreeIfNeeded()
        var lines: [String] = []
        for control in controls(content) where isShown(control) && control.isEnabled {
            if buttonsOnly, !(control is NSButton) || control is NSPopUpButton { continue }
            let b = control.bounds
            guard b.width > 2, b.height > 2 else { continue }
            let points = [NSPoint(x: b.midX, y: b.midY),
                          NSPoint(x: b.minX + b.width * 0.25, y: b.midY),
                          NSPoint(x: b.minX + b.width * 0.75, y: b.midY)]
            for p in points {
                let inFrame = control.convert(p, to: frameView)
                let hit = frameView.hitTest(inFrame)
                if let hit, hit === control || hit.isDescendant(of: control) { continue }
                lines.append("\(describe(control)) at \(NSStringFromPoint(p)): click lands on \(describe(hit))")
                break
            }
        }
        return lines
    }

    /// Every enabled push button, check box, radio, field and drop-down of every dialog takes the
    /// click aimed at it, in English, German, Russian, French, Japanese and Arabic.
    func testEveryDialogControlReceivesTheClickAimedAtIt() {
        continueAfterFailure = true
        var failures: [String] = []
        var checked = 0
        for code in ["-", "de", "ru", "fr", "ja", "ar"] {
            autoreleasepool {
                useLanguage(code)
                for probe in probes() {
                    let appeared = ModalProbe.present(timeout: probe.timeout, probe.present) { window in
                        checked += 1
                        failures += Self.covered(in: window).map { "\(probe.name) [\(code)]: \($0)" }
                    }
                    if !appeared { failures.append("MISSING \(probe.name) [\(code)]") }
                }
            }
        }
        print("OKCANCEL-HIT | \(checked) dialogs, \(failures.count) covered controls")
        for line in failures { print("OKCANCEL-HIT \(line)") }
        XCTAssertGreaterThan(checked, 100)
        XCTAssertTrue(failures.isEmpty, "controls a click does not reach:\n" + failures.joined(separator: "\n"))
    }

    // MARK: - tracking-area owners

    /// Every tracking area under `view`, with the path of the view that holds it.
    private static func trackingAreas(_ view: NSView, path: String = "") -> [(String, NSTrackingArea)] {
        let here = path + "/" + String(describing: type(of: view))
        var found = view.trackingAreas.map { (here, $0) }
        for child in view.subviews { found += trackingAreas(child, path: here) }
        return found
    }

    /// The selectors AppKit sends a tracking area's owner, from its options
    /// (NSTrackingArea.h: mouseEntered: / mouseExited:, mouseMoved:, cursorUpdate:).
    static func missingSelectors(in window: NSWindow) -> [String] {
        guard let frameView = window.contentView?.superview ?? window.contentView else { return [] }
        var lines: [String] = []
        for (path, area) in trackingAreas(frameView) {
            guard let owner = area.owner as? NSObject else { continue }
            var needed: [Selector] = []
            if area.options.contains(.mouseEnteredAndExited) {
                needed += [#selector(NSResponder.mouseEntered(with:)), #selector(NSResponder.mouseExited(with:))]
            }
            if area.options.contains(.mouseMoved) { needed.append(#selector(NSResponder.mouseMoved(with:))) }
            if area.options.contains(.cursorUpdate) { needed.append(#selector(NSResponder.cursorUpdate(with:))) }
            for selector in needed where !owner.responds(to: selector) {
                lines.append("\(path): owner \(type(of: owner)) does not answer \(NSStringFromSelector(selector))")
            }
        }
        return lines
    }

    /// No tracking area of any dialog (or of the Options window, or the main window) has an owner
    /// that AppKit would send an unrecognized selector. Fails on the old `WinComboHover`.
    func testEveryTrackingAreaOwnerAnswersItsSelectors() {
        continueAfterFailure = true
        var failures: [String] = []
        var areas = 0
        for probe in probes() {
            let appeared = ModalProbe.present(timeout: probe.timeout, probe.present) { window in
                areas += Self.trackingAreas(window.contentView?.superview ?? window.contentView!).count
                failures += Self.missingSelectors(in: window).map { "\(probe.name): \($0)" }
            }
            if !appeared { failures.append("MISSING \(probe.name)") }
        }
        let options = OptionsWindowController.shared
        if let window = options.window {
            XCTAssertTrue(ModalProbe.present({ OptionsWindowController.showOptions() }) { _ in })
            for index in 0..<options.pageCount {
                options.selectPage(index)
                window.contentView?.layoutSubtreeIfNeeded()
                failures += Self.missingSelectors(in: window).map { "Options page \(index + 1): \($0)" }
            }
            ModalProbe.close(window)
        }
        for window in NSApp.windows where window.isVisible {
            failures += Self.missingSelectors(in: window).map { "window '\(window.title)': \($0)" }
        }
        print("OKCANCEL-TRACK | \(areas) tracking areas in the dialogs, \(failures.count) bad owners")
        XCTAssertGreaterThan(areas, 0)
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    /// The combo's hover state really follows the mouse now (it never did: the messages raised).
    func testComboHoverFollowsTheMouse() {
        let combo = WinComboBox(frame: NSRect(x: 0, y: 0, width: 100, height: 21))
        let event = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0,
                                           userData: nil)!
        guard let owner = combo.trackingAreas.first?.owner as? NSResponder else {
            return XCTFail("the combo's tracking area has no responder owner")
        }
        owner.mouseEntered(with: event)
        XCTAssertTrue(combo.hover.isInside)
        owner.mouseExited(with: event)
        XCTAssertFalse(combo.hover.isInside)
    }

    // MARK: - an exception inside a modal session

    /// An Objective-C exception raised while a dialog is modal (here from a timer inside the
    /// session, as the tracking-area message was) must not end the session: afterwards the dialog
    /// is still the modal window and its own Cancel still ends `run` with its Cancel answer.
    /// With `NSApp.runModal(for:)` the exception unwound `ComboDialog.run` and this test with it.
    func testAnExceptionInsideAModalDialogKeepsItsSession() {
        let before = DialogKit.caughtModalExceptions.count
        var raised = false
        var modalAfter: NSWindow?
        var cancelWorked = false
        var dialogWindow: NSWindow?
        // Two timers: a timer whose callback is unwound by an exception is left marked as firing
        // and never fires again (modalfix.md), so the one that raises is not the one that checks.
        let raiser = Timer(timeInterval: 0.05, repeats: true) { timer in
            guard !raised, let modal = NSApp.modalWindow else { return }
            raised = true
            dialogWindow = modal
            timer.invalidate()
            SZRaiseException(name: "OkCancelTestException", reason: "raised inside the modal session")
        }
        let checker = Timer(timeInterval: 0.05, repeats: true) { timer in
            guard raised else { return }
            timer.invalidate()
            modalAfter = NSApp.modalWindow
            guard let modal = NSApp.modalWindow else { return }
            // The dialog's own Cancel (Esc button), as a click would send it.
            if let cancel = DialogWindow.cancelButton(in: modal.contentView) {
                cancel.performClick(nil)
                cancelWorked = true
            } else {
                NSApp.stopModal()
            }
        }
        // A safety net so a regression fails instead of hanging: end any session after 10 s.
        let deadline = Timer(timeInterval: 10, repeats: false) { _ in
            if let modal = NSApp.modalWindow { modal.orderOut(nil); NSApp.stopModal() }
        }
        for t in [raiser, checker, deadline] {
            RunLoop.main.add(t, forMode: .modalPanel)
            RunLoop.main.add(t, forMode: .default)
        }
        defer { for t in [raiser, checker, deadline] { t.invalidate() } }
        let result = ComboDialog.run(title: "Create Folder", label: "Folder name:", value: "x", parent: nil)
        XCTAssertTrue(raised)
        XCTAssertNotNil(dialogWindow)
        XCTAssertTrue(modalAfter === dialogWindow, "the session did not survive the exception")
        XCTAssertTrue(cancelWorked, "no Cancel button to click")
        XCTAssertNil(result, "Cancel must answer nil")
        XCTAssertFalse(dialogWindow?.isVisible ?? true, "the dialog stayed on screen")
        XCTAssertNil(NSApp.modalWindow)
        XCTAssertEqual(DialogKit.caughtModalExceptions.count, before + 1)
        XCTAssertTrue(DialogKit.caughtModalExceptions.last?.contains("OkCancelTestException") ?? false)
    }

    // MARK: - cell copies (the crash the UI tests met once the hover worked)

    /// AppKit copies cells (a header's drawing and tracking, the accessibility snapshot, a
    /// pop-up's menu), and NSCell's `copy(with:)` duplicates the instance bitwise: a Swift stored
    /// reference arrives in the copy without its retain, so freeing the copy releases an object
    /// the original still uses. Each cell subclass with such a property must keep its objects
    /// alive through a copy and its release.
    func testCellCopiesKeepTheirObjectsAlive() {
        // AddressComboCell.icon
        let address = AddressComboCell()
        weak var weakIcon: NSImage?
        autoreleasepool {
            let icon = NSImage(size: NSSize(width: 16, height: 16))
            address.icon = icon
            weakIcon = icon
            for _ in 0..<3 { _ = address.copy() }
        }
        XCTAssertNotNil(weakIcon, "AddressComboCell: the icon was freed by a copy")
        XCTAssertTrue(address.icon === weakIcon)

        // WinPopUpButtonCell.hover
        let popup = WinPopUpButtonCell()
        weak var weakHover: WinComboHover?
        autoreleasepool {
            weakHover = popup.hover
            for _ in 0..<3 { _ = popup.copy() }
        }
        XCTAssertNotNil(weakHover, "WinPopUpButtonCell: the hover owner was freed by a copy")

        // WinHeaderCell.titleFont: a font is shared, so count its references instead.
        let header = WinHeaderCell(textCell: "Name")
        let font = NSFont(name: "Menlo", size: 13.7)!
        header.titleFont = font
        let before = CFGetRetainCount(font)
        autoreleasepool {
            for _ in 0..<3 { _ = header.copy() }
        }
        XCTAssertGreaterThanOrEqual(CFGetRetainCount(font), before, "WinHeaderCell: copies released titleFont")   // the font system may keep one more
        // and a copy carries the property
        let copy = header.copy() as? WinHeaderCell
        XCTAssertTrue(copy?.titleFont === font)
    }
}
