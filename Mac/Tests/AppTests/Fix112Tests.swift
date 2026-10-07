// Fix112Tests.swift -- the 1.1.2 fixes in the real app (ai/reports/fix112.md):
//
//   1. a header click sorts whatever settings were saved: with Show ".." on, every folder that
//      implements IFolderCompare (the file system, every archive) dropped the click;
//   2. Options > macOS > Reset All Settings (the decision, the wipe, nothing saved afterwards);
//   3. the theme defaults to Light.

import AppKit
import SevenZipKit
import XCTest
@testable import SevenZipAppHost

final class Fix112Tests: AppHostTestCase {

    override var screenshotPrefix: String { "fix112" }

    private var controllers: [MainWindowController] = []
    private var scratchDirectories: [String] = []
    private var saved: [String: Any] = [:]
    private var savedRelauncher = SettingsReset.startRelauncher
    private var savedTerminate = SettingsReset.terminate
    private var savedObservers = WinMessageBox.observers

    override func setUpWithError() throws {
        try super.setUpWithError()
        saved = Settings.domainContents()
        savedRelauncher = SettingsReset.startRelauncher
        savedTerminate = SettingsReset.terminate
        savedObservers = WinMessageBox.observers
        // Never launch or quit anything from a test.
        SettingsReset.startRelauncher = { XCTFail("relaunch helper started unexpectedly: \($0)") }
        SettingsReset.terminate = { XCTFail("terminate called unexpectedly") }
    }

    override func tearDown() {
        SZSettings.writesSuspended = false
        SettingsReset.startRelauncher = savedRelauncher
        SettingsReset.terminate = savedTerminate
        WinMessageBox.observers = savedObservers
        while NSApp.modalWindow != nil { NSApp.abortModal() }
        for controller in controllers { controller.window?.close() }
        controllers = []
        for path in scratchDirectories { try? FileManager.default.removeItem(atPath: path) }
        scratchDirectories = []
        Settings.replaceDomainContents(with: saved)
        AppTheme.applyStored()
        super.tearDown()
    }

    // MARK: helpers

    private func makeScratch(_ name: String) -> String {
        let path = (TestPaths.artifacts as NSString).appendingPathComponent("fix112-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        scratchDirectories.append(path)
        return path
    }

    private func touch(_ path: String, size: Int) {
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data(repeating: 0x41, count: size)), path)
    }

    private func makeWindow() -> MainWindowController {
        Settings.numPanels = 1
        Settings.setListMode(3, 0)
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

    private func clickHeader(_ panel: PanelViewController, _ propID: SZPropID) throws {
        let column = try XCTUnwrap(panel.tableView.tableColumns.first { PanelViewController.propID(of: $0) == propID },
                                   "no \(propID) column")
        panel.tableView(panel.tableView, didClick: column)          // LVN_COLUMNCLICK -> OnColumnClick
    }

    private func names(_ panel: PanelViewController) -> [String] {
        panel.rows.filter { !$0.isParentRow }.map(\.name)
    }

    private func waitOrder(_ panel: PanelViewController, _ expected: [String], _ what: String, line: UInt = #line) {
        XCTAssertTrue(wait(for: what) { self.names(panel) == expected }, "\(what): \(names(panel))", line: line)
    }

    // MARK: - 1. sorting with a user's saved settings

    /// The user's FM.Columns.7-Zip.zip (sorted by Packed Size, descending).
    static let userZipLayout = """
    {"sortID":8,"columns":[{"width":450,"visible":true,"propID":4},{"width":126,"visible":true,"propID":7},\
    {"width":126,"visible":true,"propID":8},{"width":145,"visible":true,"propID":12},\
    {"width":123,"visible":true,"propID":10},{"width":100,"visible":true,"propID":9}],"ascending":false}
    """

    /// The values that were on the machine where header clicks did nothing: Show ".." on, details
    /// view, the stored layouts. The file system and a zip archive, each sorted from its layout,
    /// then by header clicks. Before fix112 every click below left the order unchanged.
    func testHeaderClicksSortWithTheUserSettings() throws {
        SZSettings.setPropertyListValue(Fix112LayoutTests_userFSFolderJSON, forKey: "FM.Columns.FSFolder")
        SZSettings.setPropertyListValue(Self.userZipLayout, forKey: "FM.Columns.7-Zip.zip")
        SZSettings.setPropertyListValue(#"{"sortID":4,"ascending":false,"columns":[{"visible":true,"propID":4,"width":160}]}"#,
                                        forKey: "FM.Columns.RootFolder")
        Settings.showDots = true

        let dir = makeScratch("sort")
        try FileManager.default.createDirectory(atPath: dir + "/sub", withIntermediateDirectories: true)
        touch(dir + "/a.txt", size: 1234)
        touch(dir + "/b.bin", size: 100_000)
        touch(dir + "/notes.md", size: 20)
        let options = SZUpdateOptions.options(archivePath: dir + "/c.zip")
        options.formatName = "zip"
        _ = try SZUpdater.update(with: options, sourcePaths: [dir + "/a.txt", dir + "/b.bin", dir + "/notes.md"], progress: nil)
        let base = Date(timeIntervalSince1970: 1_705_314_600)
        for (i, name) in ["sub", "c.zip", "a.txt", "notes.md", "b.bin"].enumerated() {
            try FileManager.default.setAttributes([.creationDate: base.addingTimeInterval(Double(i) * 60)],
                                                  ofItemAtPath: dir + "/" + name)
        }

        let controller = makeWindow()
        let panel = controller.focusedPanel
        navigate(panel, to: dir)
        XCTAssertEqual(panel.rows.first?.isParentRow, true, "Show .. is on")
        XCTAssertEqual(panel.sortPropID, .ctime)
        waitOrder(panel, ["sub", "c.zip", "a.txt", "notes.md", "b.bin"], "the stored sort: Created ascending")

        try clickHeader(panel, .name)
        waitOrder(panel, ["sub", "a.txt", "b.bin", "c.zip", "notes.md"], "Name ascending")
        try clickHeader(panel, .name)
        waitOrder(panel, ["sub", "notes.md", "c.zip", "b.bin", "a.txt"], "Name reversed")
        try clickHeader(panel, .size)
        XCTAssertTrue(wait(for: "size descending") {
            let n = self.names(panel); return n.first == "sub" && n[1] == "b.bin" && n.last == "notes.md"
        }, "Size descending: \(names(panel))")
        try clickHeader(panel, .ctime)
        waitOrder(panel, ["sub", "b.bin", "notes.md", "a.txt", "c.zip"], "Created starts descending")
        XCTAssertEqual(panel.rows.first?.isParentRow, true, ".. stays first")
        panel.viewArrangeByName(nil)
        waitOrder(panel, ["sub", "a.txt", "b.bin", "c.zip", "notes.md"], "View > Arrange By > Name")

        // Inside the zip (IFolderCompare in the archive folder), with its stored Packed Size sort.
        let zip = try XCTUnwrap(panel.rows.first { $0.name == "c.zip" })
        panel.openRow(zip, insideOnly: false, formatHint: nil)
        XCTAssertTrue(wait(for: "inside c.zip") { panel.currentPath.hasSuffix("c.zip/") })
        XCTAssertEqual(panel.sortPropID, .packSize)
        XCTAssertEqual(panel.rows.first?.isParentRow, true)
        try clickHeader(panel, .name)
        waitOrder(panel, ["a.txt", "b.bin", "notes.md"], "zip: Name ascending")
        try clickHeader(panel, .name)
        waitOrder(panel, ["notes.md", "b.bin", "a.txt"], "zip: Name reversed")
        try clickHeader(panel, .size)
        waitOrder(panel, ["b.bin", "a.txt", "notes.md"], "zip: Size descending")
    }

    /// Corrupt and legacy values: none of them may keep a header click from sorting.
    func testHeaderClicksSortWithCorruptStoredLayouts() throws {
        let dir = makeScratch("corrupt")
        touch(dir + "/a.txt", size: 30)
        touch(dir + "/b.txt", size: 10)
        touch(dir + "/c.txt", size: 20)
        let corrupt: [Any] = [
            #"{"sortID":4242,"ascending":false,"columns":[{"propID":7,"visible":true,"width":100},{"propID":7,"visible":false,"width":1}]}"#,
            #"{"sortID":11,"ascending":true,"columns":[{"propID":11,"visible":false,"width":100},{"propID":99999,"visible":true,"width":100}]}"#,
            #"{"sortID":"7","ascending":"no","columns":[{"propID":"7","visible":1,"width":-50},"junk",{"width":3}]}"#,
            #"{"sortID":0,"columns":[]}"#,
            "not json",
            Data(#"{"sortID":12,"ascending":true,"columns":[]}"#.utf8),
            42,
        ]
        for value in corrupt {
            SZSettings.setPropertyListValue(value, forKey: "FM.Columns.FSFolder")
            // legacy NSTableView autosave keys from an autosaveName never apply to the panel
            SZSettings.setPropertyListValue(["junk"], forKey: "NSTableView Columns v2 FSFolder")
            SZSettings.setPropertyListValue(["junk"], forKey: "NSTableView Sort Ordering v2 FSFolder")
            Settings.showDots = (value as? Int) != 42
            let controller = makeWindow()
            let panel = controller.focusedPanel
            navigate(panel, to: dir)
            try clickHeader(panel, .name)
            if panel.sortPropID == .name && !panel.ascending { try clickHeader(panel, .name) }
            waitOrder(panel, ["a.txt", "b.txt", "c.txt"], "\(value): Name ascending")
            try clickHeader(panel, .name)
            waitOrder(panel, ["c.txt", "b.txt", "a.txt"], "\(value): Name reversed")
            try clickHeader(panel, .size)
            waitOrder(panel, ["a.txt", "c.txt", "b.txt"], "\(value): Size descending")
            XCTAssertNotNil(Settings.columnLayout(forFolderType: "FSFolder"), "\(value): a clean layout was saved")
            controller.window?.close()
        }
    }

    // MARK: - 2. Reset All Settings

    func testResetDecision() {
        let contents: [String: Any] = ["FM.FirstLaunchIntegration": true,
                                       "FM.LaunchServicesStamp": "/Applications/7-Zip.app|346",
                                       "FM.LaunchServicesStamp.com.example": "x",
                                       "FM.Theme": "dark", "FM.ShowDots": true, "Lang": "-",
                                       "FM.Columns.FSFolder": "{}", "FM.FolderHistory": ["/a"],
                                       "Options.ContextMenu": 3, "Options.CascadedMenu": true,
                                       "NSTableView Columns v2 x": ["y"], "NSWindow Frame Main": "0 0 1 1",
                                       "Compression.ArcHistory": ["/b.7z"]]
        XCTAssertEqual(Set(SettingsReset.contentsAfterReset(contents).keys),
                       ["FM.FirstLaunchIntegration", "FM.LaunchServicesStamp", "FM.LaunchServicesStamp.com.example"],
                       "only the first-launch marker and the Launch Services stamps survive")

        let args = SettingsReset.relaunchArguments(bundlePath: "/Applications/7-Zip.app", pid: 4242,
                                                   environment: ["SEVENZIP_DEFAULTS_SUITE": "/tmp/it's.plist",
                                                                 "HOME": "/Users/x"])
        XCTAssertEqual(Array(args.prefix(2)), ["/bin/sh", "-c"])
        let script = args[2]
        XCTAssertTrue(script.contains("kill -0 4242"), script)
        XCTAssertTrue(script.contains("exec '/usr/bin/open' '-n' '-a' '/Applications/7-Zip.app' '--env' 'SEVENZIP_DEFAULTS_SUITE=/tmp/it'\\''s.plist'"), script)
        XCTAssertFalse(script.contains("HOME"), "only the domain and test-support variables are passed on")
        let plain = SettingsReset.relaunchArguments(bundlePath: "/Applications/7-Zip.app", pid: 1, environment: [:])[2]
        XCTAssertFalse(plain.contains("--env"), plain)

        XCTAssertNil(SettingsReset.savedApplicationStatePath(bundleIdentifier: "com.yrambler2001.7zip", usesOverrideSuite: true, home: "/Users/x"))
        XCTAssertEqual(SettingsReset.savedApplicationStatePath(bundleIdentifier: "com.yrambler2001.7zip", usesOverrideSuite: false, home: "/Users/x"),
                       "/Users/x/Library/Saved Application State/com.yrambler2001.7zip.savedState")
    }

    private func onDiskDomain() -> [String: Any] {
        Settings.synchronize()
        guard let path = Settings.domainPlistPath(), let dict = NSDictionary(contentsOfFile: path) as? [String: Any] else { return [:] }
        return dict
    }

    /// No answers No: nothing changes. Yes: the domain is emptied (the marker kept), a relaunch is
    /// scheduled for this bundle, the app quits, and nothing the quitting instance does -- every
    /// window's save-on-quit, a setting written afterwards, the engine's own accessors -- reaches
    /// the domain again.
    func testResetAllSettingsFromTheMacPage() throws {
        Settings.replaceDomainContents(with: saved.merging([
            "FM.FirstLaunchIntegration": true, "FM.ShowDots": true, "FM.Theme": "dark",
            "FM.Columns.FSFolder": Fix112LayoutTests_userFSFolderJSON,
            "NSTableView Columns v2 FSFolder": ["junk"], "FM.FolderHistory": ["/tmp"],
            "Options.WorkDirType": 2, "Options.WorkDirPath": "/tmp/7z-work"]) { _, new in new })
        XCTAssertNotNil(Settings.domainPlistPath(), "the host runs on its own plist domain")
        let controller = makeWindow()
        let mac = OptionsMacPage()
        _ = mac.view
        mac.pageDidLoad()
        XCTAssertEqual(mac.resetButton.title, "Reset All Settings...")
        XCTAssertNotNil(mac.resetButton.superview, "the button is on the page")

        var asked: [String] = []
        var answer = WinMessageBox.Result.no
        WinMessageBox.observers.append { box in
            asked.append(box.message)
            if case .yesNo = box.boxButtons {} else { XCTFail("Yes / No buttons") }
            box.answer(answer)
        }
        mac.resetAllClicked(nil)
        XCTAssertEqual(asked, ["Reset all 7-Zip settings to their defaults? 7-Zip will restart."])
        XCTAssertEqual(Settings.string(Settings.Key.theme), "dark", "No changes nothing")
        XCTAssertFalse(SZSettings.writesSuspended)

        var relaunch: [String] = []
        var terminated = false
        SettingsReset.startRelauncher = { relaunch = $0 }
        SettingsReset.terminate = { terminated = true }
        answer = .yes
        mac.resetAllClicked(nil)
        XCTAssertEqual(asked.count, 2)
        XCTAssertTrue(terminated, "the app quits")
        XCTAssertTrue(relaunch.last?.contains("'-n' '-a' '\(Bundle.main.bundleURL.path)'") ?? false, "\(relaunch)")
        XCTAssertTrue(relaunch.last?.contains("SEVENZIP_DEFAULTS_SUITE=") ?? false, "a suite run stays one: \(relaunch)")
        // The domain's file is the truth: it is what the relaunched instance reads. (In this
        // process, a plist-path domain -- what the host runs on -- still answers a removed key from
        // the file as it was first loaded, measured: Lang and FM.Panels.numPanels of the host's seed;
        // the app's own named domain has no such layer.)
        let kept: Set<String> = Set(saved.keys.filter(SettingsReset.isPreserved)).union(["FM.FirstLaunchIntegration"])
        XCTAssertEqual(Set(onDiskDomain().keys), kept, "only the preserved keys are left")
        XCTAssertNil(onDiskDomain()["FM.Theme"], "the theme is back at its default (Light)")
        XCTAssertTrue(SZSettings.writesSuspended)

        // What the quitting instance does next must not reach the domain.
        controller.focusedPanel.saveColumnLayout()
        MainWindows.saveAllForTermination()
        Settings.numPanels = 2
        Settings.showDots = true
        SZSettings.setPropertyListValue("x", forKey: "Anything")
        Settings.saveWorkDir(Settings.loadWorkDir())
        Settings.synchronize()
        XCTAssertEqual(Set(onDiskDomain().keys), kept, "nothing saved after the reset")
        SZSettings.writesSuspended = false
    }

    // MARK: - 3. Light by default

    func testLightIsTheDefaultTheme() {
        Settings.removeKey(Settings.Key.theme)
        XCTAssertEqual(Settings.theme, .light)
        AppTheme.applyStored()
        XCTAssertEqual(NSApp.appearance?.name, .aqua)
        Settings.theme = .system
        XCTAssertEqual(Settings.string(Settings.Key.theme), "system", "an explicit System is kept")
        XCTAssertNil(NSApp.appearance)
        let mac = OptionsMacPage()
        _ = mac.view
        Settings.removeKey(Settings.Key.theme)
        mac.pageDidLoad()
        XCTAssertEqual(mac.selectedTheme, .light, "the page shows Light for a fresh domain")
    }
}

/// The same JSON as `Fix112LayoutTests.userFSFolderJSON` (that file is in the unit-test target).
let Fix112LayoutTests_userFSFolderJSON = """
{"sortID":10,"ascending":true,"columns":[{"visible":true,"width":464,"propID":4},\
{"visible":true,"width":126,"propID":7},{"visible":true,"width":124,"propID":12},\
{"visible":true,"width":123,"propID":10},{"visible":true,"width":100,"propID":28},\
{"visible":true,"width":100,"propID":31},{"visible":true,"width":100,"propID":32},\
{"visible":false,"width":123,"propID":11},{"visible":false,"width":123,"propID":98},\
{"visible":false,"width":100,"propID":9},{"visible":false,"width":126,"propID":8},\
{"visible":false,"width":100,"propID":53},{"visible":false,"width":100,"propID":25},\
{"visible":false,"width":100,"propID":26},{"visible":false,"width":100,"propID":89},\
{"visible":false,"width":100,"propID":91},{"visible":false,"width":100,"propID":37}]}
"""
