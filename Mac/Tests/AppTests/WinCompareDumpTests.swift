// WinCompareDumpTests.swift -- the macOS half of the side-by-side comparison with the real 7zFM
// (Mac/docs/reports/wincompare.md). It drives the app's own windows over the same fixture folder
// the Windows half used and writes text dumps to Mac/build/wincompare/out plus the paired
// screenshots `wincompare-<area>-mac.png`.
//
// It only runs when the fixture folder exists (`Mac/build/wincompare/cmp`, or WINCOMPARE_FIXTURES),
// so a normal `test.sh -H` skips it. The fixture is built by the commands in wincompare.md §1.

import AppKit
import SevenZipKit
import XCTest
@testable import SevenZipAppHost

final class WinCompareDumpTests: AppHostTestCase {

    override var screenshotPrefix: String { "wincompare" }

    private var controllers: [MainWindowController] = []
    private var savedNumPanels = 1
    private var savedPanelPaths: [String?] = []

    private var fixtures: String {
        ProcessInfo.processInfo.environment["WINCOMPARE_FIXTURES"]
            ?? ((TestPaths.repoRoot ?? "") + "/Mac/build/wincompare/cmp")
    }
    private var outDir: String { ((TestPaths.repoRoot ?? NSTemporaryDirectory()) + "/Mac/build/wincompare/out") }

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard FileManager.default.fileExists(atPath: fixtures + "/arc.7z") else {
            throw XCTSkip("no wincompare fixture folder at \(fixtures)")
        }
        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        savedNumPanels = Settings.numPanels
        savedPanelPaths = [Settings.panelPath(0), Settings.panelPath(1)]
    }

    override func tearDown() {
        while NSApp.modalWindow != nil { NSApp.abortModal() }
        for controller in controllers {
            controller.window?.toolbar = nil
            controller.window?.close()
        }
        controllers = []
        for (i, path) in savedPanelPaths.enumerated() { Settings.setPanelPath(path, i) }
        Settings.numPanels = savedNumPanels
        super.tearDown()
    }

    // MARK: - helpers

    private func save(_ name: String, _ text: String) {
        try? text.write(toFile: outDir + "/" + name, atomically: true, encoding: .utf8)
    }

    private func makeWindow(panels: Int = 1) -> MainWindowController {
        Settings.numPanels = panels
        let controller = MainWindowController()
        controllers.append(controller)
        // The Windows client area of the captured 7zFM window was 1424x694.
        controller.window?.setContentSize(NSSize(width: 1424, height: 694))
        controller.showWindow(nil)
        controller.window?.layoutIfNeeded()
        ActiveContext.register(controller)
        return controller
    }

    private func navigate(_ panel: PanelViewController, to path: String) {
        var done = false
        panel.navigate(to: path) { _ in done = true }
        XCTAssertTrue(wait(for: "panel bound to \(path)") { done })
        settle()
    }

    private func settle(_ seconds: TimeInterval = 0.3) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func select(_ panel: PanelViewController, _ names: [String]) {
        var set = IndexSet()
        for name in names {
            if let i = panel.rows.firstIndex(where: { $0.name == name }) { set.insert(i) }
        }
        if let first = set.first { panel.setFocus(first) }
        panel.setSelectedIndexes(set)
        settle(0.1)
    }

    private func handler(for action: Selector, from panel: PanelViewController) -> NSObject? {
        var responder: NSResponder? = panel.tableView
        while let current = responder {
            if current.responds(to: action) { return current }
            responder = current.nextResponder
        }
        if let window = panel.view.window {
            if window.responds(to: action) { return window }
            if let wc = window.windowController, wc.responds(to: action) { return wc }
            if let d = window.delegate as? NSObject, d.responds(to: action) { return d }
        }
        if let delegate = NSApp.delegate as? NSObject, delegate.responds(to: action) { return delegate }
        return nil
    }

    private func validate(_ item: NSMenuItem, _ panel: PanelViewController) -> Bool {
        guard let action = item.action else { return item.submenu != nil }
        if let target = item.target as? NSObject {
            if let v = target as? NSMenuItemValidation { return v.validateMenuItem(item) }
            return true
        }
        guard let target = handler(for: action, from: panel) else { return false }
        if let v = target as? NSMenuItemValidation { return v.validateMenuItem(item) }
        if let v = target as? NSUserInterfaceValidations { return v.validateUserInterfaceItem(item) }
        return true
    }

    private func menuBar(_ panel: PanelViewController) -> String {
        guard let bar = NSApp.mainMenu else { return "no main menu" }
        return WinCompareDump.menu(bar) { self.validate($0, panel) }
    }

    @discardableResult
    private func send(_ action: Selector, tag: Int = 0, from panel: PanelViewController) -> Bool {
        let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
        item.tag = tag
        guard let target = handler(for: action, from: panel) else { XCTFail("no handler for \(action)"); return false }
        _ = target.perform(action, with: item)
        return true
    }

    private func mainDump(_ controller: MainWindowController) -> String {
        guard let window = controller.window else { return "" }
        var out = WinCompareDump.window(window)
        if let toolbar = window.toolbar {
            out += "== toolbar\n"
            for item in toolbar.items {
                out += "  BTN '\(item.label)' id=\(item.itemIdentifier.rawValue)" + (item.isEnabled ? "" : " DISABLED") + "\n"
            }
        }
        out += "TITLE '\(window.title)'\n"
        return out
    }

    /// Present a dialog through `action`, dump and screenshot it, end its modal session.
    private func dialog(_ name: String, timeout: TimeInterval = 20, _ action: () -> Void,
                        then body: ((NSWindow) -> Void)? = nil) {
        let appeared = ModalProbe.present(timeout: timeout, action) { window in
            self.save("dlg-\(name).txt", WinCompareDump.window(window))
            self.attach(window, "dlg-\(name)-mac")
            body?(window)
        }
        if !appeared { save("dlg-\(name).txt", "NONE\n") }
        while NSApp.modalWindow != nil { NSApp.abortModal() }
        for window in NSApp.windows where window.isVisible && window.sheetParent != nil {
            window.sheetParent?.endSheet(window)
        }
        settle(0.2)
    }

    // MARK: - main window, menus, view modes, sorting, archives

    func testDumpMainWindowAndMenus() throws {
        let controller = makeWindow()
        let panel = controller.focusedPanel
        navigate(panel, to: fixtures)
        select(panel, [])
        save("main-folder.txt", mainDump(controller))
        attach(controller.window!, "main-folder-mac")
        save("menu-noselection.txt", menuBar(panel))
        for (tag, name) in [("arc7z", "arc.7z"), ("atxt", "a.txt"), ("sub", "sub")] {
            select(panel, [name])
            save("menu-sel-\(tag).txt", menuBar(panel))
        }
        select(panel, ["a.txt", "b.bin"])
        save("menu-sel-two.txt", menuBar(panel))
        save("main-sel-two.txt", mainDump(controller))

        // context menus (7zFM: WM_CONTEXTMENU on the list)
        for (tag, name) in [("arc7z", "arc.7z"), ("atxt", "a.txt"), ("sub", "sub")] {
            select(panel, [name])
            let menu = panel.makeItemContextMenu()
            save("ctx-\(tag).txt", WinCompareDump.menu(menu) { self.validate($0, panel) })
        }
        select(panel, [])
        if panel.responds(to: NSSelectorFromString("makeBackgroundContextMenu")) {
            // optional API
        }

        // view modes
        for (mode, name) in [(0, "large"), (1, "small"), (2, "list")] {
            panel.setListViewMode(mode)
            settle(0.5)
            attach(controller.window!, "main-view-\(name)-mac")
            save("main-view-\(name).txt", mainDump(controller))
        }
        panel.setListViewMode(3)
        settle()

        // sorting through the View menu actions
        let sorts: [(Selector, String)] = [
            (#selector(MenuActions.viewArrangeByType(_:)), "type"),
            (#selector(MenuActions.viewArrangeByDate(_:)), "date"),
            (#selector(MenuActions.viewArrangeBySize(_:)), "size"),
            (#selector(MenuActions.viewArrangeNoSort(_:)), "unsorted"),
            (#selector(MenuActions.viewArrangeByName(_:)), "name")]
        for (action, name) in sorts {
            send(action, from: panel); settle()
            save("main-sort-\(name).txt", mainDump(controller))
        }
        send(#selector(MenuActions.viewArrangeBySize(_:)), from: panel); settle()
        send(#selector(MenuActions.viewArrangeBySize(_:)), from: panel); settle()
        save("main-sort-size-again.txt", mainDump(controller))
        send(#selector(MenuActions.viewArrangeByName(_:)), from: panel); settle()

        send(#selector(MenuActions.viewFlatView(_:)), from: panel); settle(0.8)
        save("main-flat.txt", mainDump(controller))
        attach(controller.window!, "main-flat-mac")
        send(#selector(MenuActions.viewFlatView(_:)), from: panel); settle(0.5)

        // archives
        for (name, tag) in [("arc.7z", "arc7z"), ("arc.zip", "arczip"), ("arc.tar", "arctar"), ("vol.7z.001", "vol")] {
            navigate(panel, to: fixtures + "/" + name)
            select(panel, [])
            save("main-\(tag).txt", mainDump(controller))
            attach(controller.window!, "main-\(tag)-mac")
            if tag == "arc7z" {
                save("menu-arc7z-noselection.txt", menuBar(panel))
                select(panel, ["a.txt"])
                save("menu-arc7z-sel-atxt.txt", menuBar(panel))
                save("ctx-inarc-atxt.txt", WinCompareDump.menu(panel.makeItemContextMenu()) { self.validate($0, panel) })
                navigate(panel, to: fixtures + "/arc.7z/sub")
                save("main-arc7z-sub.txt", mainDump(controller))
            }
        }
        navigate(panel, to: fixtures)
    }

    func testDumpTwoPanels() throws {
        let controller = makeWindow(panels: 2)
        for panel in controller.visiblePanels { navigate(panel, to: fixtures) }
        save("main-twopanels.txt", mainDump(controller))
        attach(controller.window!, "main-twopanels-mac")
        save("menu-twopanels.txt", menuBar(controller.focusedPanel))
    }
}
