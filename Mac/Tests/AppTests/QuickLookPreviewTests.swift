// QuickLookPreviewTests.swift -- the Quick Look preview (quicklook scope) rendered in the host app,
// which compiles Mac/QuickLook into the test copies of the app (project.yml, SevenZipTestApp), and
// the app's side of it: Options > macOS > "Quick Look preview for archives", Reset All Settings,
// the launch-time election.
//
// The renders are written to Mac/build/screenshots/quicklook-*.png (light and dark) and attached to
// the result. They use the app's own icons (the host bundle carries the fm-*.ico frames), so they
// show exactly what the extension draws. PlugInKit is never touched: every pluginkit call goes
// through `FinderExtensionControl.runner`, replaced here.

import AppKit
import SevenZipKit
import XCTest
@testable import SevenZipAppHost

final class QuickLookPreviewTests: AppHostTestCase {

    override var screenshotPrefix: String { "quicklook" }

    private var windows: [NSWindow] = []
    private var savedRunner = FinderExtensionControl.runner
    private var work = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedRunner = FinderExtensionControl.runner
        work = (NSTemporaryDirectory() as NSString).appendingPathComponent("ql-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
    }

    override func tearDown() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        FinderExtensionControl.runner = savedRunner
        ArchivePreviewView.openInApp = ArchivePreviewView.openInContainingApp
        try? FileManager.default.removeItem(atPath: work)
        super.tearDown()
    }

    // MARK: - rendering

    /// The preview of `path` in a window of Quick Look's default size, in `appearance`.
    @discardableResult
    private func render(_ path: String, dark: Bool, limits: ArchivePreviewLimits = .standard,
                        shot: String? = nil) -> ArchivePreviewView {
        let preview = ArchivePreviewBuilder.build(path: path, limits: limits)
        let view = ArchivePreviewView(frame: NSRect(x: 0, y: 0, width: 820, height: 560))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = view
        windows.append(window)
        view.show(preview, fileURL: URL(fileURLWithPath: path))
        window.orderFrontRegardless()
        view.layoutSubtreeIfNeeded()
        let rows = min(view.outlineView.numberOfRows, 8)
        wait(for: "rows of \(path)") {
            view.outlineView.layoutSubtreeIfNeeded()
            return (0..<rows).allSatisfy { view.outlineView.view(atColumn: 0, row: $0, makeIfNecessary: false) != nil }
        }
        view.displayIfNeeded()
        if let shot { save(capture(view), shot + (dark ? "-dark" : "-light")) }
        return view
    }

    /// The view drawn part by part at 2x: the band, its line, the list's header and rows, the
    /// centred message. Drawing the whole window in one `cacheDisplay` is not reliable on macOS 26
    /// (the scroll view skips its rows' clip view, Feel3FontTests.drawList), and here it skipped
    /// the band as well; each part drawn on its own is complete.
    private func capture(_ view: ArchivePreviewView, scale: CGFloat = 2) -> Data? {
        let size = view.bounds.size
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let appearance = view.window?.appearance ?? NSApp.effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            ctx.setFillColor(WinChrome.window.cgColor)
        }
        ctx.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
        var parts: [NSView] = [view.band, view.bandLine]
        if !view.scrollView.isHidden {
            parts.append(view.scrollView.contentView)
            if let header = view.outlineView.headerView { parts.append(header) }
        } else {
            parts += [view.centerIcon, view.centerMessage]
        }
        for part in parts where !part.isHidden && part.bounds.width > 0 && part.bounds.height > 0 {
            let inRoot = view.convert(part.bounds, from: part).intersection(view.bounds)
            guard !inRoot.isEmpty else { continue }
            let partRect = part.convert(inRoot, from: view)
            let w = Int(inRoot.width * scale), h = Int(inRoot.height * scale)
            guard let sub = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            sub.scaleBy(x: scale, y: scale)
            // As the window's backing store draws text: no font smoothing (Feel3FontTests.drawUnsmoothed).
            sub.setAllowsFontSmoothing(false)
            sub.setShouldSmoothFonts(false)
            if part.isFlipped {
                sub.translateBy(x: 0, y: inRoot.height)
                sub.scaleBy(x: 1, y: -1)
            }
            sub.translateBy(x: -partRect.minX, y: -partRect.minY)
            appearance.performAsCurrentDrawingAppearance {
                part.displayIgnoringOpacity(partRect, in: NSGraphicsContext(cgContext: sub, flipped: part.isFlipped))
            }
            guard let image = sub.makeImage() else { continue }
            // The root is flipped: its y runs down, the bitmap's up.
            ctx.draw(image, in: CGRect(x: inRoot.minX * scale, y: (size.height - inRoot.maxY) * scale,
                                       width: inRoot.width * scale, height: inRoot.height * scale))
        }
        guard let image = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }

    /// Writes `png` to Mac/build/screenshots/quicklook-<name>.png and attaches it.
    private func save(_ png: Data?, _ name: String) {
        guard let png else { return XCTFail("no image for \(name)") }
        let file = "quicklook-\(name).png"
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = file
        attachment.lifetime = .keepAlways
        add(attachment)
        try? FileManager.default.createDirectory(atPath: TestPaths.screenshots, withIntermediateDirectories: true)
        try? png.write(to: URL(fileURLWithPath: TestPaths.screenshots).appendingPathComponent(file), options: .atomic)
    }

    private func cellText(_ view: ArchivePreviewView, row: Int, column: ArchivePreviewView.Column) -> String? {
        guard let index = view.outlineView.tableColumns.firstIndex(where: { $0.identifier == column.identifier }),
              let cell = view.outlineView.view(atColumn: index, row: row, makeIfNecessary: true) as? NSTableCellView
        else { return nil }
        return cell.textField?.stringValue
    }

    private func summaryTexts(_ view: ArchivePreviewView) -> [String] {
        view.summaryGrid.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
    }

    func testRendersTheFourCasesLightAndDark() throws {
        for dark in [false, true] {
            render(TestPaths.fixture("test.7z"), dark: dark, shot: "7z")
            render(TestPaths.fixture("test.zip"), dark: dark, shot: "zip")
            render(TestPaths.fixture("test.tar.gz"), dark: dark, shot: "tar-gz")
            render(TestPaths.fixture("secret.7z"), dark: dark, shot: "encrypted-headers")
        }
    }

    func testRendersTheLimitsAndFailures() throws {
        var limits = ArchivePreviewLimits()
        limits.maxListedEntries = 3
        let truncated = render(TestPaths.fixture("test.7z"), dark: false, limits: limits, shot: "truncated")
        XCTAssertEqual(truncated.noticeField.stringValue, "\u{2026}and 3 more \u{2014} open in 7-Zip")
        XCTAssertFalse(truncated.noticeField.isHidden)

        let corrupt = render(TestPaths.fixture("corrupt.7z"), dark: false, shot: "corrupt")
        XCTAssertTrue(corrupt.scrollView.isHidden, "no list for a file that does not open")
        XCTAssertTrue(corrupt.centerMessage.stringValue.hasPrefix("Cannot open file 'corrupt.7z' as archive"),
                      corrupt.centerMessage.stringValue)

        let lone = (work as NSString).appendingPathComponent("multi.7z.001")
        try FileManager.default.copyItem(atPath: TestPaths.fixture("multi.7z.001"), toPath: lone)
        let volume = render(lone, dark: true, shot: "first-volume-alone")
        let text = volume.centerMessage.isHidden ? volume.noticeField.stringValue : volume.centerMessage.stringValue
        XCTAssertTrue(text.contains("multi-volume"), text)
    }

    /// The list is the panel's Details list: 19 pt rows, the 24 pt header, SF Pro 12.2 (tabular
    /// digits in the number columns), sizes grouped by spaces, the panel's icons.
    func testLooksLikeThePanel() throws {
        let view = render(TestPaths.fixture("test.7z"), dark: false)
        let outline = view.outlineView
        XCTAssertEqual(outline.rowHeight, PanelMetrics.rowHeight)
        XCTAssertEqual(outline.headerView?.frame.height, PanelMetrics.headerHeight)
        XCTAssertEqual(PreviewMetrics.font, PanelMetrics.listFont)
        XCTAssertEqual(PreviewMetrics.font.pointSize, 12.2, accuracy: 0.001)
        XCTAssertEqual(PreviewMetrics.digitsFont, PanelMetrics.listDigitsFont)
        XCTAssertEqual(outline.tableColumns.map(\.title), ["Name", "Size", "Packed Size", "Modified"])
        XCTAssertEqual(PreviewMetrics.sizeColumnWidth, CGFloat(PanelMetrics.sizeColumnWidth))
        XCTAssertEqual(PreviewMetrics.timeColumnWidth(level: .min, utc: false),
                       CGFloat(PanelMetrics.timeColumnWidth(level: .min, utc: false)))
        // Folders first, then names; the folder's size is the sum of what it holds.
        XCTAssertEqual(cellText(view, row: 0, column: .name), "sub")
        XCTAssertEqual(cellText(view, row: 0, column: .size), "3 010")
        XCTAssertEqual(cellText(view, row: 1, column: .name), "notes.md")
        XCTAssertEqual(cellText(view, row: 2, column: .name), "readme.txt")
        XCTAssertEqual(cellText(view, row: 2, column: .size), "12")
        XCTAssertTrue(cellText(view, row: 2, column: .modified)?.hasPrefix("2024-01-0") ?? false)
        // A date fits its column whole, as in the panel (PanelMetrics.timeColumnWidth).
        let timeCell = try XCTUnwrap(outline.view(atColumn: 3, row: 2, makeIfNecessary: true) as? NSTableCellView)
        timeCell.layoutSubtreeIfNeeded()
        let field = try XCTUnwrap(timeCell.textField)
        XCTAssertGreaterThanOrEqual(field.frame.width, ceil(field.intrinsicContentSize.width), "the date is not cut")
        // Three items at the top: nothing starts expanded (only a single top folder does).
        XCTAssertFalse(outline.isItemExpanded(outline.item(atRow: 0)))
        outline.expandItem(outline.item(atRow: 0))
        XCTAssertEqual(cellText(view, row: 1, column: .name), "deep")
        XCTAssertEqual(cellText(view, row: 2, column: .name), "big.txt")
        XCTAssertEqual(cellText(view, row: 2, column: .size), "3 000")

        // The summary in the Properties terms (01 §3.11).
        let summary = summaryTexts(view)
        for label in ["Type:", "Method:", "Solid:", "Folders:", "Files:", "Size:", "Physical Size:", "Compression ratio:"] {
            XCTAssertTrue(summary.contains(label), "\(label) in \(summary)")
        }
        XCTAssertTrue(summary.contains("3 043"), "\(summary)")
        XCTAssertEqual(view.titleField.stringValue, "test.7z")
        XCTAssertEqual(view.openButton.title, "Open in 7-Zip")
    }

    /// An archive inside an archive gets 7-Zip's own pixel-sharp 16 px frame, as in the panel.
    func testArchiveItemsUseThePanelsArchiveIcons() throws {
        let view = render(TestPaths.fixture("nested.zip"), dark: false)
        let node = try XCTUnwrap(view.preview?.root.children.first { $0.name == "test.7z" })
        let icon = ArchivePreviewView.icon(for: node)
        XCTAssertTrue(icon === PanelArchiveIcons.icon(forName: "test.7z", large: false), "the panel's cached frame")
        XCTAssertEqual(icon.size, NSSize(width: 16, height: 16))
        let folder = ArchivePreviewNode(name: "x", isDirectory: true)
        XCTAssertTrue(ArchivePreviewView.icon(for: folder) === Icons.folder)
    }

    func testEncryptedHeadersSayWhatToDo() {
        let view = render(TestPaths.fixture("secret.7z"), dark: false)
        XCTAssertTrue(view.scrollView.isHidden)
        XCTAssertEqual(view.centerMessage.stringValue,
                       "Encrypted archive \u{2014} open in 7-Zip to enter the password")
        XCTAssertTrue(summaryTexts(view).contains("Encrypted:"))
    }

    /// The button opens the archive in the containing app through Launch Services, never through
    /// the sevenzip:// command URL.
    func testOpenInAppUsesTheContainingApp() {
        var opened: [URL] = []
        ArchivePreviewView.openInApp = { opened.append($0) }
        let view = render(TestPaths.fixture("test.zip"), dark: false)
        view.openClicked(nil)
        XCTAssertEqual(opened, [URL(fileURLWithPath: TestPaths.fixture("test.zip"))])
        XCTAssertEqual(ArchivePreviewView.containingAppURL(
            of: URL(fileURLWithPath: "/Applications/7-Zip.app/Contents/PlugIns/QuickLook.appex")).path,
            "/Applications/7-Zip.app")
    }

    func testPreviewSettingsFollowTheAppTheme() {
        XCTAssertEqual(PreviewSettings(QuickLookPreferences(theme: "dark")).appearance?.name, .darkAqua)
        XCTAssertEqual(PreviewSettings(QuickLookPreferences(theme: "light")).appearance?.name, .aqua)
        XCTAssertNil(PreviewSettings(QuickLookPreferences(theme: "system")).appearance)
        XCTAssertNil(PreviewSettings(QuickLookPreferences()).appearance, "no snapshot: the system's appearance")
        XCTAssertEqual(PreviewSettings(QuickLookPreferences(timestampLevel: 0)).timestampLevel, .sec)
        XCTAssertEqual(PreviewSettings(QuickLookPreferences()).timestampLevel, .min)
    }

    // MARK: - Options > macOS > "Quick Look preview for archives"

    /// Records pluginkit calls; answers `-m` with `line` (nil: not registered).
    private func stubPluginKit(_ line: @escaping () -> String?) -> () -> [[String]] {
        var calls: [[String]] = []
        FinderExtensionControl.runner = { args in
            calls.append(args)
            if args.first == "-m", let l = line() { return (0, l + "\n") }
            return (0, "")
        }
        return { calls }
    }

    private let appex = "/Applications/7-Zip.app/Contents/PlugIns/QuickLook.appex"

    private func registration(_ election: Character, path: String? = nil) -> String {
        "\(election)    com.yrambler2001.7zip.QuickLook(1.2.0)\tA0FC853A-E8B3-4C0B-AA62-55563A0BD9F4\t2026-10-08 00:00:00 +0000\t\(path ?? appex)"
    }

    func testCheckboxIsOnTheMacPageAndDisabledWithoutTheExtension() {
        let page = OptionsMacPage()
        _ = page.view
        page.pageDidLoad()
        XCTAssertEqual(page.quickLookBox.title, "Quick Look preview for archives")
        XCTAssertNotNil(page.quickLookBox.superview)
        XCTAssertFalse(page.quickLookBox.isEnabled, "the host app carries no QuickLook.appex")
        XCTAssertEqual(page.quickLookBox.state, .off)
        XCTAssertNotEqual(page.quickLookBox.frame.minY, page.resetButton.frame.minY, "no overlap with Reset")
    }

    /// No election (a fresh registration) and `+` are on; `-` is off; Apply elects.
    func testCheckboxFollowsPlugInKitAndApplyElects() {
        var election: Character = " "
        let calls = stubPluginKit { self.registration(election) }
        let page = OptionsMacPage()
        page.quickLookAppexPath = appex
        _ = page.view
        page.pageDidLoad()
        XCTAssertTrue(wait(for: "state") { page.quickLookState != nil })
        XCTAssertEqual(page.quickLookState, .enabled, "no election is on for a Quick Look extension")
        XCTAssertEqual(page.quickLookBox.state, .on)
        XCTAssertTrue(page.quickLookBox.isEnabled)

        page.quickLookBox.state = .off
        page.quickLookClicked(nil)
        election = "-"
        var done = false
        page.applyQuickLook { done = true }
        XCTAssertTrue(wait(for: "apply") { done })
        XCTAssertTrue(calls().contains(["-e", "ignore", "-i", "com.yrambler2001.7zip.QuickLook"]), "\(calls())")
        XCTAssertEqual(page.quickLookState, .disabled)
        XCTAssertEqual(page.quickLookBox.state, .off)

        page.quickLookBox.state = .on
        page.quickLookClicked(nil)
        election = "+"
        done = false
        page.applyQuickLook { done = true }
        XCTAssertTrue(wait(for: "apply") { done })
        XCTAssertTrue(calls().contains(["-a", appex]), "claims the registration before electing")
        XCTAssertTrue(calls().contains(["-e", "use", "-i", "com.yrambler2001.7zip.QuickLook"]))
        XCTAssertEqual(page.quickLookState, .enabled)
    }

    func testStateRules() {
        typealias C = QuickLookExtensionControl
        let mine = FinderExtensionControl.Registration(election: " ", version: "1", path: appex)
        XCTAssertEqual(C.state(active: mine, embeddedPath: appex), .enabled)
        XCTAssertEqual(C.state(active: .init(election: "+", version: "1", path: appex), embeddedPath: appex), .enabled)
        XCTAssertEqual(C.state(active: .init(election: "-", version: "1", path: appex), embeddedPath: appex), .disabled)
        XCTAssertEqual(C.state(active: nil, embeddedPath: appex), .notRegistered)
        XCTAssertEqual(C.state(active: mine, embeddedPath: nil), .notEmbedded)
        XCTAssertEqual(C.state(active: .init(election: "+", version: "1", path: "/Volumes/x/7-Zip.app/Contents/PlugIns/QuickLook.appex"),
                               embeddedPath: appex),
                       .otherCopy(path: "/Volumes/x/7-Zip.app/Contents/PlugIns/QuickLook.appex", enabled: true))
    }

    /// Reset All Settings turns the preview back on -- in a real copy. The host (a test instance
    /// without the extension) never touches PlugInKit.
    func testResetRestoresTheDefault() {
        let calls = stubPluginKit { self.registration("-") }
        QuickLookExtensionControl.restoreDefault(embeddedPath: appex, testSupport: false)
        XCTAssertTrue(calls().contains(["-a", appex]))
        XCTAssertEqual(calls().last, ["-e", "use", "-i", "com.yrambler2001.7zip.QuickLook"])

        let before = calls().count
        QuickLookExtensionControl.restoreDefault(embeddedPath: appex, testSupport: true)
        QuickLookExtensionControl.restoreDefault(embeddedPath: nil, testSupport: false)
        QuickLookExtensionControl.restoreDefault()
        XCTAssertEqual(calls().count, before, "test instances and copies without the appex: no pluginkit call")
        XCTAssertTrue(SettingsReset.isPreserved(QuickLookExtensionControl.firstLaunchMarkerKey))
    }

    func testLaunchAction() {
        typealias C = QuickLookExtensionControl
        let home = "/Users/me"
        func action(test: Bool = false, xctest: Bool = false, id: String? = "com.yrambler2001.7zip",
                    path: String = "/Applications/7-Zip.app", embedded: Bool = true, marker: Bool = false) -> C.LaunchAction {
            C.launchAction(testSupport: test, xctestLoaded: xctest, bundleIdentifier: id, bundlePath: path,
                           home: home, embedded: embedded, markerSet: marker)
        }
        XCTAssertEqual(action(), .enable, "first launch from /Applications elects use")
        XCTAssertEqual(action(marker: true), .claim, "later launches only claim the registration")
        XCTAssertEqual(action(path: "/Volumes/7-Zip/7-Zip.app"), .claim, "a disk-image copy does not elect")
        XCTAssertEqual(action(test: true), .none)
        XCTAssertEqual(action(xctest: true), .none)
        XCTAssertEqual(action(id: "com.yrambler2001.7zip-host"), .none)
        XCTAssertEqual(action(embedded: false), .none)
    }

    // MARK: - re-registration at launch (Finder Sync, both Quick Actions, Quick Look)

    func testLaunchRegistrationDecision() {
        typealias F = FinderExtensionControl
        let mine = "/Applications/7-Zip.app/Contents/PlugIns/FinderSync.appex"
        XCTAssertEqual(F.launchRegistration(active: nil, embeddedPath: mine), .register, "missing: register")
        for election: Character in ["+", " ", "-", "!"] {
            XCTAssertEqual(F.launchRegistration(active: .init(election: election, version: "1", path: mine), embeddedPath: mine),
                           .leave, "present (\(election)): nothing")
        }
        XCTAssertEqual(F.launchRegistration(active: .init(election: "+", version: "1", path: "/Volumes/7-Zip/7-Zip.app/Contents/PlugIns/FinderSync.appex"),
                                            embeddedPath: mine), .takeOver)
    }

    /// Missing: `-a` only, never an election. Present -- elected use, or ignored by the user: no
    /// call besides the query, so an "ignore" is never flipped.
    func testRegisterAtLaunchNeverElects() {
        let ids = FinderExtensionControl.finderExtensions.map(\.identifier) + [QuickLookExtensionControl.identifier]
        XCTAssertEqual(ids, ["com.yrambler2001.7zip.FinderSync", "com.yrambler2001.7zip.QuickActionExtract",
                             "com.yrambler2001.7zip.QuickActionCompress", "com.yrambler2001.7zip.QuickLook"])
        for id in ids {
            let name = id.components(separatedBy: ".").last! + ".appex"
            let path = "/Applications/7-Zip.app/Contents/PlugIns/" + name
            var line: String? = nil
            let calls = stubPluginKit { line }
            XCTAssertEqual(FinderExtensionControl.registerAtLaunch(identifier: id, embeddedPath: path), .register)
            XCTAssertTrue(calls().contains(["-a", path]), "\(id): \(calls())")
            XCTAssertFalse(calls().contains { $0.first == "-e" }, "\(id): no election")

            for election: Character in ["-", "+"] {
                line = "\(election)    \(id)(1.2.0)\tX\t2026\t\(path)"
                let before = calls().count
                XCTAssertEqual(FinderExtensionControl.registerAtLaunch(identifier: id, embeddedPath: path), .leave)
                XCTAssertEqual(Array(calls()[before...]), [["-m", "-v", "-i", id]], "\(id) \(election): only the query")
            }
        }
    }

    /// The snapshot the app pushes carries the four display settings, from the app's own values.
    func testSnapshotCarriesTheDisplaySettings() {
        let saved = Settings.theme
        defer { Settings.theme = saved }
        Settings.theme = .dark
        let snapshot = QuickLookSettingsBridge.snapshot()
        XCTAssertEqual(snapshot.theme, "dark")
        XCTAssertEqual(snapshot.timestampLevel, Settings.timestampLevel)
        XCTAssertEqual(snapshot.timestampShowUTC, Settings.timestampShowUTC)
        XCTAssertFalse(QuickLookSettingsBridge.push(), "a test instance never writes into the extension's container")
    }
}
