// DlgFeelSnapshots.swift -- the Mac halves of the dlgfeel paired captures: every dialog rendered
// at 1x in the light appearance, the content view only (the client area of the Windows capture),
// written to Mac/build/dlgfeel/<name>.png and, for the paired set, to
// Mac/build/screenshots/wincompare-dlgfeel-<name>-mac.png (reports/dlgfeel.md).

import AppKit
import SevenZipKit
import XCTest
@testable import SevenZipAppHost

enum DlgSnap {

    /// The content view of `window` at one pixel per point over the window background.
    static func png(_ window: NSWindow) -> Data? {
        guard let content = window.contentView else { return nil }
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        let bounds = content.bounds
        let w = Int(bounds.width.rounded()), h = Int(bounds.height.rounded())
        guard w > 1, h > 1,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = bounds.size
        // Tag the pixels sRGB, as the Windows captures are, so colours compare as numbers.
        let srgb = rep.retagging(with: .sRGB) ?? rep
        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: srgb) {
            NSGraphicsContext.current = context
            (window.appearance ?? NSApp.effectiveAppearance).performAsCurrentDrawingAppearance {
                (window.backgroundColor ?? .windowBackgroundColor).setFill()
                NSRect(origin: .zero, size: bounds.size).fill()
            }
            context.flushGraphics()
        }
        NSGraphicsContext.restoreGraphicsState()
        // cacheDisplay draws over what is already in the bitmap only where the views draw, so the
        // background filled above shows through the transparent parts.
        content.cacheDisplay(in: bounds, to: srgb)
        return srgb.representation(using: .png, properties: [:])
    }

    static var buildDirectory: String {
        let root = TestPaths.repoRoot ?? NSTemporaryDirectory()
        let dir = root + "/Mac/build/dlgfeel"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    static func write(_ window: NSWindow, _ name: String, paired: Bool = false) -> String? {
        guard let data = png(window) else { return nil }
        let path = buildDirectory + "/\(name).png"
        try? data.write(to: URL(fileURLWithPath: path))
        if paired {
            let shot = TestPaths.screenshots + "/wincompare-dlgfeel-\(name)-mac.png"
            try? data.write(to: URL(fileURLWithPath: shot))
        }
        return path
    }
}

final class DlgFeelSnapshots: AppHostTestCase {

    private var fixtures: String { TestPaths.fixtures }
    private var archive: String { TestPaths.fixture("test.7z") }
    /// The paired captures go to Mac/build/screenshots only when Mac/build/dlgfeel/PAIRED
    /// exists (a flag file, because xcodebuild does not pass the shell's environment on).
    private var paired: Bool { FileManager.default.fileExists(atPath: DlgSnap.buildDirectory + "/PAIRED") }

    override func setUpWithError() throws {
        try super.setUpWithError()
        NSApp.appearance = NSAppearance(named: .aqua)
    }

    override func tearDown() {
        NSApp.appearance = nil
        super.tearDown()
    }

    private func snap(_ name: String, timeout: TimeInterval = 30, settle: TimeInterval = 0,
                      _ present: () -> Void) {
        let appeared = ModalProbe.present(timeout: timeout, present) { window in
            if settle > 0 {
                let until = Date().addingTimeInterval(settle)
                while Date() < until { RunLoop.current.run(mode: .modalPanel, before: Date().addingTimeInterval(0.05)) }
            }
            let size = window.contentView?.bounds.size ?? .zero
            print("DLGFEEL \(name) content=\(Int(size.width))x\(Int(size.height)) resizable=\(window.styleMask.contains(.resizable))")
            DlgSnap.write(window, name, paired: self.paired)
        }
        XCTAssertTrue(appeared, "\(name) never came up")
    }

    func testAbout() { snap("about") { AboutDialog.show(parent: nil) } }

    func testCopyMove() {
        snap("copy") {
            _ = CopyMoveDialog.run(move: false, value: "/Users/me/Documents/", history: [], info: "", parent: nil)
        }
        snap("move") {
            _ = CopyMoveDialog.run(move: true, value: "/Users/me/Documents/", history: [], info: "", parent: nil)
        }
    }

    func testCombo() {
        snap("createfolder") {
            _ = ComboDialog.run(title: Lang.text(6300, "Create Folder"), label: Lang.text(6302, "Folder name:"),
                                value: Lang.text(6304, "New Folder"), parent: nil)
        }
        snap("createfile") {
            _ = ComboDialog.run(title: Lang.text(6301, "Create File"), label: Lang.text(6303, "File Name:"),
                                value: Lang.text(6305, "New File"), parent: nil)
        }
        snap("select") {
            _ = ComboDialog.run(title: Lang.text(6402, "Select"), label: Lang.text(6404, "Mask:"), value: "*",
                                strings: ["*"], parent: nil)
        }
    }

    func testComment() { snap("comment-file") { _ = CommentDialog.run(value: "", parent: nil) } }

    func testTools() {
        snap("split") { _ = SplitDialog.run(filePath: archive, path: fixtures, parent: nil) }
        snap("combine") {
            _ = CombineDialog.run(title: Lang.text(7400, "Combine Files"), prompt: Lang.text(7402, "Combine to:"),
                                  info: TestPaths.fixture("multi.7z.001"), path: fixtures, parent: nil)
        }
        snap("link") {
            _ = LinkDialog.run(currentDirPrefix: fixtures + "/", filePath: archive,
                               anotherPath: TestPaths.realHome, parent: nil)
        }
    }

    func testLists() throws {
        var history = ListViewDialogOptions()
        history.title = Lang.text(6601, "Folders History")
        history.strings = [fixtures, "/tmp"]
        history.deleteIsAllowed = true
        snap("history") { _ = ListViewDialog.run(history, parent: nil) }
        try SZCodecs.loadCodecs()
        let results = try SZHasher.hash(paths: ["test.7z"], relativeTo: fixtures, methods: ["CRC32"],
                                        recursive: false, progress: nil)
        snap("hash-crc32") { HashResultsDialog.show(results: results, parent: nil) }
        snap("tempfiles") { ToolsTempFilesDialog.show(parent: nil) }
    }

    func testBenchmark() {
        snap("bench-start", timeout: 60, settle: 3) { BenchmarkDialog.run(totalMode: false, parent: nil) }
    }

    func testExtract() {
        var extract = ExtractDialog.Options()
        extract.directoryPath = fixtures + "/"
        extract.archivePath = archive
        snap("extract") { _ = ExtractDialog.run(extract) }
    }

    func testCompress() throws {
        try SZCodecs.loadCodecs()
        var input = CompressDialogInput()
        input.directoryPrefix = fixtures + "/"
        input.archiveBaseName = "a"
        input.itemPaths = [archive]
        snap("compress", timeout: 60) { _ = CompressDialogController.run(input) }
        for name in ["7z", "zip"] {
            guard let f = SZCodecs.format(named: name) else { return XCTFail("no \(name) format") }
            var state = CompressOptionsSheet.State(
                formatName: f.name, formatTimeFlags: f.timeFlags, formatFlags: f.flags,
                supportsMTime: f.supportsMTime, supportsCTime: f.supportsCTime, supportsATime: f.supportsATime,
                supportsSymLinks: f.supportsSymLinks, supportsHardLinks: f.supportsHardLinks,
                supportsAltStreams: f.supportsAltStreams, supportsNtSecurity: f.supportsNtSecurity,
                isTar: false, isZip: name == "zip", isGZip: false,
                isKeepName: f.keepName, tarMethodName: "")
            snap(name == "7z" ? "compress-options" : "compress-options-zip") {
                _ = CompressOptionsSheet.run(&state, parent: nil)
            }
        }
    }

    func testOperations() {
        let old = OverwriteDialog.FileInfo(path: archive, size: 838, time: Date())
        let new = OverwriteDialog.FileInfo(path: TestPaths.fixture("test.zip"), size: 1024, time: Date())
        snap("overwrite") { _ = OverwriteDialog.run(oldFile: old, newFile: new, showExtraButtons: true, parent: nil) }
        var pw = PasswordDialog.Options()
        pw.subject = archive
        snap("password") { _ = PasswordDialog.run(pw, parent: nil) }
        snap("messages") { MessagesDialog.show(messages: ["a : CRC failed"], parent: nil) }
        var memory = MemoryUseDialog.Options()
        memory.requiredGB = 4
        memory.limitGB = 2
        memory.ramGB = 16
        memory.filePath = "sub/big.txt"
        memory.archivePath = archive
        memory.showRemember = true
        snap("memory") { _ = MemoryUseDialog.run(memory, parent: nil) }
        let progress = ProgressDialog(title: Lang.text(3300, "Extracting"), showCompressionInfo: false)
        progress.window.setContentSize(progress.window.contentMinSize)
        DlgSnap.write(progress.window, "progress", paired: paired)
    }

    func testOptions() {
        let controller = OptionsWindowController.shared
        guard let window = controller.window else { return XCTFail("no Options window") }
        _ = ModalProbe.present({ OptionsWindowController.showOptions() }) { _ in }
        for index in 0..<controller.pageCount {
            controller.selectPage(index)
            window.contentView?.layoutSubtreeIfNeeded()
            DlgSnap.write(window, "options-\(index)", paired: paired)
        }
        ModalProbe.close(window)
    }
}

final class DlgFeelCalibration: AppHostTestCase {
    /// IDD_COMPRESS's controls on a bare form at their Windows rects, for measuring ink offsets.
    func testCalibrationRender() {
        NSApp.appearance = NSAppearance(named: .aqua)
        defer { NSApp.appearance = nil }
        let dialog = RcDialog(4000)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: dialog.size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let form = RcFormView(frame: NSRect(origin: .zero, size: dialog.size))
        window.contentView = form
        form.add(RcPlace.makeLabel("Archive format:"), dialog, 4003)
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: ["7z", "zip"])
        form.add(popup, dialog, 104)
        let check = NSButton(checkboxWithTitle: "Create SFX archive", target: nil, action: nil)
        form.add(check, dialog, 4012)
        let checked = NSButton(checkboxWithTitle: "Compress shared files", target: nil, action: nil)
        checked.state = .on
        form.add(checked, dialog, 4013)
        form.add(WinGroupBox(title: "Options"), dialog, 4011)
        let edit = NSTextField(string: "")
        form.add(edit, dialog, 111)
        form.add(NSButton(title: "Options", target: nil, action: nil), dialog, 2100)
        let combo = NSComboBox(frame: .zero)
        combo.stringValue = "a.7z"
        form.add(combo, dialog, 100)
        form.add(NSButton(title: "OK", target: nil, action: nil), dialog, 1)
        window.orderFront(nil)
        DlgSnap.write(window, "calib")
        window.orderOut(nil)
    }
}
