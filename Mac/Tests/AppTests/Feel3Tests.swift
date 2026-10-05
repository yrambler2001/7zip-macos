// Feel3Tests.swift -- the feel3 findings (Mac/docs/reports/feel3.md): Finder Get Info's event,
// combo boxes drawn as Windows 11's, no phantom scroll bars, the address text that must not move
// when the combo is clicked, the address drop-down's rows, 7-Zip's archive icons, Open archive in a
// new window, Option+Space, the list font setting.

import AppKit
import SevenZipKit
import XCTest
@testable import SevenZipAppHost

final class Feel3Tests: AppHostTestCase {

    override var screenshotPrefix: String { "feel3" }

    private var controllers: [MainWindowController] = []
    private var scratchDirectories: [String] = []
    private var savedNumPanels = 1
    private var savedPanelPaths: [String?] = []
    private var savedListModes: [Int] = []
    private var savedAppearance: NSAppearance?

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedNumPanels = Settings.numPanels
        savedPanelPaths = [Settings.panelPath(0), Settings.panelPath(1)]
        savedListModes = [Settings.listMode(0), Settings.listMode(1)]
        savedAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .aqua)
    }

    override func tearDown() {
        AddressPopup.current?.close()
        while NSApp.modalWindow != nil { NSApp.abortModal() }
        for controller in controllers { controller.window?.close() }
        for controller in MainWindows.controllers where !controllers.contains(where: { $0 === controller }) {
            if controller !== MainWindows.primary { controller.window?.close() }
        }
        controllers = []
        for path in scratchDirectories { try? FileManager.default.removeItem(atPath: path) }
        scratchDirectories = []
        for (i, path) in savedPanelPaths.enumerated() { Settings.setPanelPath(path, i) }
        for (i, mode) in savedListModes.enumerated() { Settings.setListMode(mode, i) }
        Settings.numPanels = savedNumPanels
        NSApp.appearance = savedAppearance
        super.tearDown()
    }

    // MARK: helpers

    private func makeScratch(_ names: [String] = ["a.txt", "b.bin", "arc.7z", "arc.zip", "x.rar", "y.tar.gz"]) -> String {
        let path = (TestPaths.artifacts as NSString).appendingPathComponent("feel3-\(UUID().uuidString)")
        let fm = FileManager.default
        try? fm.createDirectory(atPath: path + "/cmp/sub", withIntermediateDirectories: true)
        for name in names { fm.createFile(atPath: path + "/cmp/" + name, contents: Data("x".utf8)) }
        scratchDirectories.append(path)
        return path + "/cmp"
    }

    private func makeWindow(panels: Int = 1, mode: Int = 3) -> MainWindowController {
        Settings.numPanels = panels
        Settings.setListMode(mode, 0)
        Settings.setListMode(mode, 1)
        let controller = MainWindowController()
        controllers.append(controller)
        controller.window?.setContentSize(NSSize(width: 1000, height: 600))
        controller.showWindow(nil)
        return controller
    }

    private func navigate(_ panel: PanelViewController, to path: String) {
        var done = false
        panel.navigate(to: path) { _ in done = true }
        XCTAssertTrue(wait(for: "panel bound to \(path)") { done })
        panel.view.window?.contentView?.layoutSubtreeIfNeeded()
    }

    /// `view`'s `rect` at 2x, sRGB over white; returns the bitmap.
    private func render(_ view: NSView, _ rect: NSRect? = nil) -> NSBitmapImageRep? {
        let area = (rect ?? view.bounds).integral
        guard let raw = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(area.width) * 2,
                                         pixelsHigh: Int(area.height) * 2, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 32),
              let rep = raw.retagging(with: .sRGB) else { return nil }
        rep.size = area.size
        view.cacheDisplay(in: area, to: rep)
        return rep
    }

    /// The leftmost dark column (points) of `rep` at or right of `fromX` points.
    private func inkMinX(_ rep: NSBitmapImageRep, fromX: CGFloat = 0, threshold: Int = 140) -> CGFloat? {
        guard let data = rep.bitmapData else { return nil }
        for x in Int(fromX * 2)..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                let p = data + y * rep.bytesPerRow + x * 4
                let a = Int(p[3])
                let v = (Int(p[0]) + Int(p[1]) + Int(p[2])) / 3 + 255 - a
                if v < threshold { return CGFloat(x) / 2 }
            }
        }
        return nil
    }

    private func inkRows(_ rep: NSBitmapImageRep, fromX: CGFloat, toX: CGFloat, threshold: Int = 140) -> (CGFloat, CGFloat)? {
        guard let data = rep.bitmapData else { return nil }
        var minY = Int.max, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in Int(fromX * 2)..<min(rep.pixelsWide, Int(toX * 2)) {
                let p = data + y * rep.bytesPerRow + x * 4
                let v = (Int(p[0]) + Int(p[1]) + Int(p[2])) / 3 + 255 - Int(p[3])
                if v < threshold { minY = min(minY, y); maxY = max(maxY, y) }
            }
        }
        return maxY < 0 ? nil : (CGFloat(minY) / 2, CGFloat(maxY + 1) / 2)
    }

    // MARK: 1. Finder Get Info

    /// One `open` per item, its direct object the specifier AppleScript compiles for
    /// `open information window of item (POSIX file p)` -- never a list.
    func testGetInfoEventIsOneSpecifierPerItem() throws {
        let url = URL(fileURLWithPath: "/tmp/feel3 a.txt")
        let finder = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        let event = FinderInfo.openEvent(for: url, target: finder)
        XCTAssertEqual(event.eventClass, AEEventClass(kCoreEventClass))
        XCTAssertEqual(event.eventID, AEEventID(kAEOpenDocuments))
        let direct = try XCTUnwrap(event.paramDescriptor(forKeyword: keyDirectObject))
        XCTAssertEqual(direct.descriptorType, DescType(typeObjectSpecifier), "a single specifier, not a list")
        XCTAssertEqual(direct.forKeyword(AEKeyword(keyAEKeyData))?.typeCodeValue, FinderInfo.fourCharCode("iwnd"))
        XCTAssertEqual(direct.forKeyword(AEKeyword(keyAEDesiredClass))?.typeCodeValue, OSType(cProperty))
        let item = try XCTUnwrap(direct.forKeyword(AEKeyword(keyAEContainer)))
        XCTAssertEqual(item.descriptorType, DescType(typeObjectSpecifier))
        XCTAssertEqual(item.forKeyword(AEKeyword(keyAEDesiredClass))?.typeCodeValue, OSType(cObject))
        XCTAssertEqual(item.forKeyword(AEKeyword(keyAEKeyForm))?.enumCodeValue, OSType(formAbsolutePosition))
        XCTAssertEqual(item.forKeyword(AEKeyword(keyAEKeyData))?.fileURLValue?.path, url.path)
    }

    // MARK: 2. combo boxes

    /// A drop-down list draws its text left-aligned 4 pt in, baseline 15 pt down, in a box with
    /// Windows 11's (210) border and (253) fill -- not AppKit's centred capsule.
    func testDropDownListDrawsLeftAlignedText() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let form = RcFormView(frame: window.contentLayoutRect)
        window.contentView = form
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: ["English : English  ---", "Deutsch"])
        form.addSubview(popup)
        RcPlace.popup(popup, NSRect(x: 20, y: 10, width: 240, height: 21))
        XCTAssertTrue(popup.cell is WinPopUpButtonCell)
        XCTAssertEqual(popup.frame.height, 21)
        let rep = try XCTUnwrap(render(popup))
        let x = try XCTUnwrap(inkMinX(rep, fromX: 1.5, threshold: 100))
        XCTAssertEqual(x, 4.5, accuracy: 1.5, "the text 4 px in (Windows' 'E' ink at +4/+5)")
        let rows = try XCTUnwrap(inkRows(rep, fromX: 3, toX: 60, threshold: 100))
        // Windows: 'E' from y+6, the 'g' of "English" down to y+16 (its last ink row), baseline 15.
        XCTAssertEqual(rows.1, 17, accuracy: 1, "the descender's last row 16 px below the top (bottom edge 17)")
        // the fill
        let data = try XCTUnwrap(rep.bitmapData)
        let p = data + 4 * rep.bytesPerRow + 200 * 4
        XCTAssertEqual(Int(p[0]), 253, accuracy: 2, "CBS_DROPDOWNLIST fill (253)")
        save(rep, "combo-dropdownlist")
    }

    /// An edit combo (CBS_DROPDOWN): the WinComboBox, 21 pt, white with a (141) border.
    func testEditComboIsWindowsStyle() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 60), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let form = RcFormView(frame: window.contentLayoutRect)
        window.contentView = form
        let combo = WinComboBox()
        combo.stringValue = "/Users/me/Documents/"
        form.addSubview(combo)
        RcPlace.combo(combo, NSRect(x: 12, y: 10, width: 438, height: 21))
        XCTAssertEqual(combo.frame.height, 21)
        let rep = try XCTUnwrap(render(combo))
        let x = try XCTUnwrap(inkMinX(rep, fromX: 1.5, threshold: 100))
        XCTAssertEqual(x, 4.5, accuracy: 1.5, "the text 4 px in")
        let data = try XCTUnwrap(rep.bitmapData)
        let border = data + 20 * rep.bytesPerRow + 0
        XCTAssertEqual(Int(border[0]), 141, accuracy: 3, "CBS_DROPDOWN border (141)")
        save(rep, "combo-edit")
    }

    // MARK: 3. scroll bars

    /// No scroll bar while nothing overflows, in every view mode and both panels; legacy style
    /// (Win32's), which the system's overlay preference cannot switch.
    func testNoScrollBarsWithoutOverflow() throws {
        let scratch = makeScratch()
        for mode in 0...3 {
            let controller = makeWindow(panels: 2, mode: mode)
            for panel in controller.panels {
                navigate(panel, to: scratch)
                panel.view.layoutSubtreeIfNeeded()
                let scroll: NSScrollView = mode == 3 ? try XCTUnwrap(panel.tableView.enclosingScrollView)
                                                     : panel.iconView.scrollView
                scroll.tile()
                XCTAssertEqual(scroll.scrollerStyle, .legacy, "mode \(mode)")
                scroll.scrollerStyle = .overlay
                XCTAssertEqual(scroll.scrollerStyle, .legacy, "the preference cannot switch it")
                XCTAssertTrue(scroll.verticalScroller?.isHidden ?? true, "mode \(mode): a vertical scroll bar with 7 rows")
                // Details: a horizontal bar exactly when the columns are wider than the list (as
                // Windows: two 500 pt panels do not hold 7zFM's 760 px of default columns).
                let overflows = mode == 3 && panel.tableView.tableColumns.reduce(0) { $0 + $1.width } > scroll.contentView.bounds.width
                XCTAssertEqual(!(scroll.horizontalScroller?.isHidden ?? true), overflows, "mode \(mode): horizontal bar")
            }
            controller.window?.close()
        }
    }

    // MARK: 6 / 7. the address bar

    /// Clicking into the address text (the field editor taking over) leaves the text where it was.
    func testAddressTextDoesNotMoveWhenEdited() throws {
        let scratch = makeScratch()
        let controller = makeWindow()
        let panel = controller.focusedPanel
        navigate(panel, to: scratch)
        let combo = panel.pathCombo
        let bar = try XCTUnwrap(combo.superview)
        let rect = combo.frame
        let beforeRep = try XCTUnwrap(render(bar, rect))
        let before = try XCTUnwrap(inkMinX(beforeRep, fromX: 22))
        let beforeRows = try XCTUnwrap(inkRows(beforeRep, fromX: 22, toX: 200))
        controller.window?.makeFirstResponder(combo)
        bar.layoutSubtreeIfNeeded()
        XCTAssertNotNil(combo.currentEditor())
        (combo.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: 0, length: 0))
        let afterRep = try XCTUnwrap(render(bar, rect))
        let after = try XCTUnwrap(inkMinX(afterRep, fromX: 22))
        let afterRows = try XCTUnwrap(inkRows(afterRep, fromX: 22, toX: 200))
        XCTAssertEqual(after, before, accuracy: 0.5, "the path moved from x \(before) to \(after) when edited")
        XCTAssertEqual(afterRows.0, beforeRows.0, accuracy: 0.5, "the path moved vertically: \(beforeRows) -> \(afterRows)")
        controller.window?.makeFirstResponder(panel.tableView)
    }

    /// The arrow opens the Windows-style list: 18 pt rows with an icon each, indented 10 pt per
    /// level, nothing highlighted, the row under the mouse highlighted; a pick navigates.
    func testAddressDropdownRowsIconsAndPick() throws {
        let scratch = makeScratch()
        let controller = makeWindow()
        let panel = controller.focusedPanel
        navigate(panel, to: scratch + "/sub")
        panel.showAddressPopup()
        let popup = try XCTUnwrap(AddressPopup.current)
        XCTAssertTrue(popup.isOpen)
        let list = popup.list
        XCTAssertEqual(list.hot, -1, "CB_GETCURSEL -1 when the list opens")
        XCTAssertTrue(list.items.allSatisfy { $0.icon != nil }, "every entry has an icon")
        XCTAssertEqual(list.rowRect(1).minY - list.rowRect(0).minY, 18, "LB_GETITEMHEIGHT 18")
        XCTAssertEqual(list.items[1].level, 1)
        let comboRect = try XCTUnwrap(panel.pathCombo.window).convertToScreen(panel.pathCombo.convert(panel.pathCombo.bounds, to: nil))
        XCTAssertEqual(popup.panel.frame.width, comboRect.width, "the combo's width")
        XCTAssertEqual(popup.panel.frame.maxY, comboRect.minY, "right under the combo")
        list.hot = 2
        if let rep = render(list) { save(rep, "address-dropdown") }
        let parent = try XCTUnwrap(panel.addressDropdownPaths.firstIndex(of: scratch + "/"))
        list.onPick?(parent)
        XCTAssertFalse(popup.isOpen)
        XCTAssertTrue(wait(for: "bound to the picked entry") { panel.currentPath == scratch + "/" })
    }

    // MARK: 8. archive icons

    /// 7-Zip's per-format icons for the extensions it registers: 16 pt with the .ico's 16 and 32 px
    /// frames, 32 pt with its 32 px frame; none for other extensions.
    func testArchiveIconsPerExtension() throws {
        for (name, ico) in [("a.7z", "7z"), ("a.zip", "zip"), ("b.rar", "rar"), ("x.tgz", "gz"), ("v.001", "split"),
                            ("d.iso", "iso"), ("e.zst", "zst")] {
            let small = try XCTUnwrap(PanelArchiveIcons.icon(forName: name, large: false), name)
            XCTAssertEqual(small.size, NSSize(width: 16, height: 16))
            XCTAssertEqual(Set(small.representations.map(\.pixelsWide)), [16, 32], "\(name) -> \(ico).ico frames")
            let large = try XCTUnwrap(PanelArchiveIcons.icon(forName: name, large: true))
            XCTAssertEqual(large.size, NSSize(width: 32, height: 32))
            XCTAssertTrue(large.representations.contains { $0.pixelsWide == 32 })
        }
        XCTAssertNil(PanelArchiveIcons.icon(forName: "a.txt", large: false))
        XCTAssertNil(PanelArchiveIcons.icon(forName: "noext", large: false))
        // The panel uses them for file-system and archive items alike.
        let scratch = makeScratch()
        let controller = makeWindow()
        let panel = controller.focusedPanel
        navigate(panel, to: scratch)
        let row = try XCTUnwrap(panel.rows.first { $0.name == "arc.7z" })
        XCTAssertTrue(panel.icon(for: row) === PanelArchiveIcons.icon(forName: "arc.7z", large: false))
        XCTAssertTrue(panel.largeIcon(for: row) === PanelArchiveIcons.icon(forName: "arc.7z", large: true))
    }

    // MARK: 5. Open archive

    /// 7-Zip > Open archive starts a new 7zFM on Windows (ContextMenu.cpp:1264): a new window here,
    /// and the panel it was invoked from stays where it was.
    func testContextOpenArchiveOpensANewWindow() throws {
        let scratch = makeScratch(["a.txt"])
        try? FileManager.default.removeItem(atPath: scratch + "/test.7z")
        try FileManager.default.copyItem(atPath: TestPaths.fixture("test.7z"), toPath: scratch + "/test.7z")
        let controller = makeWindow()
        let panel = controller.focusedPanel
        navigate(panel, to: scratch)
        let index = try XCTUnwrap(panel.rows.firstIndex { $0.name == "test.7z" })
        panel.setSelectedIndexes(IndexSet(integer: index))
        panel.focusedIndex = index
        let before = MainWindows.controllers.count
        controller.sevenZipOpenArchive(nil)
        XCTAssertTrue(wait(for: "a new window") { MainWindows.controllers.count == before + 1 })
        let opened = try XCTUnwrap(MainWindows.controllers.last)
        controllers.append(opened)
        XCTAssertTrue(opened !== controller)
        XCTAssertTrue(wait(for: "the new window shows the archive") {
            opened.focusedPanel.snapshot?.isArchive == true
        })
        XCTAssertEqual(panel.currentPath, scratch + "/", "the invoking panel did not move")
    }

    // MARK: Option+Space

    /// Ctrl+Space toggles the focused item's selection; on the Mac Option+Space (and Ctrl+Space
    /// when the system lets it through). The focus stays.
    func testOptionSpaceTogglesTheFocusedItem() throws {
        let scratch = makeScratch()
        let controller = makeWindow()
        let panel = controller.focusedPanel
        navigate(panel, to: scratch)
        controller.window?.makeFirstResponder(panel.tableView)
        let index = try XCTUnwrap(panel.rows.firstIndex { $0.name == "b.bin" })
        panel.setSelectedIndexes(IndexSet(integer: index))
        panel.focusedIndex = index
        func key(_ mods: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0,
                             windowNumber: controller.window?.windowNumber ?? 0, context: nil,
                             characters: mods.contains(.option) ? "\u{a0}" : " ", charactersIgnoringModifiers: " ",
                             isARepeat: false, keyCode: 49)!
        }
        XCTAssertTrue(panel.handleListKeyDown(key(.option)))
        XCTAssertFalse(panel.selectedIndexes.contains(index), "Option+Space deselects the focused item")
        XCTAssertEqual(panel.focusedIndex, index, "the focus stays")
        XCTAssertTrue(panel.handleListKeyDown(key(.option)))
        XCTAssertTrue(panel.selectedIndexes.contains(index), "and selects it again")
        XCTAssertTrue(panel.handleListKeyDown(key(.control)))
        XCTAssertFalse(panel.selectedIndexes.contains(index), "Ctrl+Space as well")
    }

    // MARK: list font setting

    /// FM.ListFont picks one of the candidates; the default stays Helvetica Neue 11.
    func testListFontSetting() {
        XCTAssertEqual(ListFontChoice.resolve(nil).fontName, "HelveticaNeue")
        XCTAssertEqual(ListFontChoice.resolve(nil).pointSize, 11)
        for candidate in ListFontChoice.candidates {
            let font = ListFontChoice.resolve(candidate.key)
            XCTAssertEqual(font.pointSize, candidate.size, accuracy: 0.01, candidate.key)
        }
        XCTAssertEqual(ListFontChoice.resolve("Arial:12.5").pointSize, 12.5, "a free family:size value")
        XCTAssertEqual(ListFontChoice.resolve("nonsense").fontName, "HelveticaNeue", "unknown values fall back")
    }

    // MARK: -

    private func save(_ rep: NSBitmapImageRep, _ name: String) {
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: TestPaths.artifacts).appendingPathComponent("feel3-\(name).png"))
    }
}
