// ShowcaseScreenshotTests.swift -- the images in docs/images/ (README, docs/parity.md): the main
// window in Light and Dark, Add to Archive, Extract and Options, rendered in process at 2x in a
// neutral demo folder, `/Users/Shared/7-Zip Demo/`, so no user name or machine detail shows up in
// a path field.
//
// Opt-in, because it writes outside the build directory (the demo folder, which it leaves in place
// for `ShowcaseUITests`, the context-menu shot): it runs only when `Mac/build/showcase/RUN` exists
// (or SEVENZIP_SHOWCASE=1 is in the host app's environment).
// `Mac/scripts/showcase.sh` does both runs and copies the results into docs/images/.
//
// Writes Mac/build/screenshots/showcase-<name>.png (git-ignored).

import AppKit
import SevenZipKit
import XCTest
@testable import SevenZipAppHost

/// The demo folder the showcase images are taken in, shared with `ShowcaseUITests`.
enum ShowcaseDemo {
    static let folder = "/Users/Shared/7-Zip Demo"

    static var isEnabled: Bool {
        if ProcessInfo.processInfo.environment["SEVENZIP_SHOWCASE"] == "1" { return true }
        guard let root = TestPaths.repoRoot else { return false }
        return FileManager.default.fileExists(atPath: root + "/Mac/build/showcase/RUN")
    }

    /// Build the folder from the fixtures: a few real archives (so icons and dialogs are genuine),
    /// two folders and some plain files, every date the same fixed moment.
    static func make() throws {
        let fm = FileManager.default
        try? fm.removeItem(atPath: folder)
        for dir in ["Documents", "Photos", "Projects"] {
            try fm.createDirectory(atPath: folder + "/" + dir, withIntermediateDirectories: true)
        }
        let archives = [("test.7z", "Project backup.7z"), ("test.zip", "Photos 2025.zip"),
                        ("test.tar.gz", "source-1.4.2.tar.gz"), ("test.tar.xz", "logs.tar.xz"),
                        ("secret.7z", "Private.7z"), ("test.wim", "install.wim")]
        for (from, to) in archives {
            try fm.copyItem(atPath: TestPaths.fixture(from), toPath: folder + "/" + to)
        }
        let files: [(String, Int)] = [("Budget 2025.xlsx", 48_213), ("notes.txt", 1_234),
                                      ("presentation.key", 2_731_904), ("readme.md", 2_048)]
        for (name, size) in files {
            fm.createFile(atPath: folder + "/" + name, contents: Data(repeating: 0x20, count: size))
        }
        fm.createFile(atPath: folder + "/Documents/letter.txt", contents: Data("Hello".utf8))
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute) = (2026, 3, 14, 10, 30)
        guard let date = Calendar.current.date(from: c) else { return }
        let items = ((try? fm.subpathsOfDirectory(atPath: folder)) ?? []) + [""]
        for item in items {
            try? fm.setAttributes([.modificationDate: date, .creationDate: date],
                                  ofItemAtPath: item.isEmpty ? folder : folder + "/" + item)
        }
    }
}

final class ShowcaseScreenshotTests: AppHostTestCase {

    override var screenshotPrefix: String { "showcase" }

    private var controllers: [MainWindowController] = []
    private var savedTheme: String?
    private var savedNumPanels = 1
    private var savedPanelPath: String?
    private var savedListMode = 3
    private var savedLastPage = 0
    private var savedAppearance: NSAppearance?

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ShowcaseDemo.isEnabled else {
            throw XCTSkip("showcase images are opt-in: Mac/scripts/showcase.sh")
        }
        savedTheme = Settings.string(Settings.Key.theme)
        savedNumPanels = Settings.numPanels
        savedPanelPath = Settings.panelPath(0)
        savedListMode = Settings.listMode(0)
        savedLastPage = Settings.optionsLastPage
        savedAppearance = NSApp.appearance
    }

    override func tearDown() {
        while NSApp.modalWindow != nil { NSApp.abortModal() }
        if let window = OptionsWindowController.shared.window, window.isVisible { ModalProbe.close(window) }
        for controller in controllers { controller.window?.close() }
        controllers = []
        if ShowcaseDemo.isEnabled {
            Settings.setString(savedTheme, Settings.Key.theme)
            Settings.numPanels = savedNumPanels
            Settings.setPanelPath(savedPanelPath, 0)
            Settings.setListMode(savedListMode, 0)
            Settings.optionsLastPage = savedLastPage
            NSApp.appearance = savedAppearance
        }
        super.tearDown()
    }

    func testShowcaseImages() throws {
        try ShowcaseDemo.make()
        try SZCodecs.loadCodecs()
        let demo = ShowcaseDemo.folder

        // The main window, Details view, one archive selected.
        Settings.numPanels = 1
        Settings.setListMode(3, 0)
        Settings.removeKey("FM.Columns.FSFolder")
        let controller = MainWindowController()
        controllers.append(controller)
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 900, height: 440))
        controller.showWindow(nil)
        let panel = controller.focusedPanel
        var done = false
        panel.navigate(to: demo) { _ in done = true }
        XCTAssertTrue(wait(for: "demo folder listed") { done && panel.rows.count >= 10 })
        for theme in [AppTheme.light, .dark] {
            Settings.theme = theme
            panel.listFocusOverride = true
            if let row = panel.rows.firstIndex(where: { $0.name == "Project backup.7z" }) {
                panel.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                panel.focusedIndex = row
            }
            panel.refreshSelectionAppearance()
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try write(window, "main-\(theme.rawValue)")
            panel.listFocusOverride = nil
        }

        for theme in [AppTheme.light, .dark] {
            Settings.theme = theme
            // Add to Archive
            var input = CompressDialogInput()
            input.directoryPrefix = demo + "/"
            input.archiveBaseName = "Documents"
            input.itemPaths = [demo + "/Documents"]
            XCTAssertTrue(ModalProbe.present(timeout: 60, { _ = CompressDialogController.run(input) }) { w in
                try? self.write(w, "add-to-archive-\(theme.rawValue)")
            })
            // Extract
            var extract = ExtractDialog.Options()
            extract.directoryPath = demo + "/Photos 2025/"
            extract.archivePath = demo + "/Photos 2025.zip"
            XCTAssertTrue(ModalProbe.present({ _ = ExtractDialog.run(extract) }) { w in
                try? self.write(w, "extract-\(theme.rawValue)")
            })
            // Options: the macOS tab, and a Windows page
            let options = OptionsWindowController.shared
            let optionsWindow = try XCTUnwrap(options.window)
            XCTAssertTrue(ModalProbe.present({ OptionsWindowController.showOptions() }) { _ in })
            options.selectPage(options.pageCount - 1)
            try write(optionsWindow, "options-macos-\(theme.rawValue)")
            options.selectPage(4)                                   // Settings
            try write(optionsWindow, "options-\(theme.rawValue)")
            ModalProbe.close(optionsWindow)
        }
    }

    /// The window's content view at 2x over the window background, attached and written to
    /// `Mac/build/screenshots/showcase-<name>.png`.
    private func write(_ window: NSWindow, _ name: String) throws {
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        let bounds = content.bounds
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                                                 pixelsWide: Int(bounds.width.rounded()) * 2,
                                                 pixelsHigh: Int(bounds.height.rounded()) * 2,
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = bounds.size
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
        content.cacheDisplay(in: bounds, to: srgb)
        let png = try XCTUnwrap(srgb.representation(using: .png, properties: [:]), name)
        let file = "showcase-\(name).png"
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = file
        attachment.lifetime = .keepAlways
        add(attachment)
        try FileManager.default.createDirectory(atPath: TestPaths.screenshots, withIntermediateDirectories: true)
        try png.write(to: URL(fileURLWithPath: TestPaths.screenshots).appendingPathComponent(file), options: .atomic)
    }
}
