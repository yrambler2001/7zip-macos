// Settings.swift -- app-side settings (window, panels, view state) in the shared preferences
// domain, under keys named after the 7zFM registry values (01b-fm-dialogs-settings.md 5.2,
// SZSettings.h). Engine-side settings (extraction/compression/work dir) go through SZSettings.

import Foundation
import SevenZipKit

enum Settings {

    private static let defaults = UserDefaults.standard   // same domain as SZSettings (bundle id)

    // MARK: FM\Position, FM\Panels  (CWindowInfo)

    /// NSStringFromRect of the last window frame; nil = system default placement.
    static var windowFrame: String? {
        get { defaults.string(forKey: SZSettingsKeyFMPosition) }
        set { defaults.set(newValue, forKey: SZSettingsKeyFMPosition) }
    }

    static var maximized: Bool {
        get { defaults.bool(forKey: SZSettingsKeyFMMaximized) }
        set { defaults.set(newValue, forKey: SZSettingsKeyFMMaximized) }
    }

    /// 1 or 2 (kNumDefaultPanels = 1).
    static var numPanels: Int {
        get { min(max(defaults.object(forKey: SZSettingsKeyFMNumPanels) as? Int ?? 1, 1), 2) }
        set { defaults.set(newValue, forKey: SZSettingsKeyFMNumPanels) }
    }

    static var currentPanel: Int {
        get { min(max(defaults.integer(forKey: SZSettingsKeyFMCurrentPanel), 0), 1) }
        set { defaults.set(newValue, forKey: SZSettingsKeyFMCurrentPanel) }
    }

    /// Splitter position as a ratio of the window width (7zFM stores it over 1 << 16).
    static var splitterPos: Double {
        get {
            let v = defaults.double(forKey: SZSettingsKeyFMSplitterPos)
            return v > 0 && v < 1 ? v : 0.5
        }
        set { defaults.set(newValue, forKey: SZSettingsKeyFMSplitterPos) }
    }

    // MARK: per panel

    static func panelPath(_ index: Int) -> String? {
        defaults.string(forKey: index == 0 ? SZSettingsKeyFMPanelPath0 : SZSettingsKeyFMPanelPath1)
    }

    static func setPanelPath(_ path: String?, _ index: Int) {
        defaults.set(path, forKey: index == 0 ? SZSettingsKeyFMPanelPath0 : SZSettingsKeyFMPanelPath1)
    }

    /// 0 large icons, 1 small icons, 2 list, 3 details (default).
    static func listMode(_ index: Int) -> Int {
        let key = index == 0 ? SZSettingsKeyFMListMode0 : SZSettingsKeyFMListMode1
        return defaults.object(forKey: key) as? Int ?? 3
    }

    static func setListMode(_ mode: Int, _ index: Int) {
        defaults.set(mode, forKey: index == 0 ? SZSettingsKeyFMListMode0 : SZSettingsKeyFMListMode1)
    }

    static func flatView(_ index: Int) -> Bool {
        defaults.bool(forKey: index == 0 ? SZSettingsKeyFMFlatViewArc0 : SZSettingsKeyFMFlatViewArc1)
    }

    static func setFlatView(_ flat: Bool, _ index: Int) {
        defaults.set(flat, forKey: index == 0 ? SZSettingsKeyFMFlatViewArc0 : SZSettingsKeyFMFlatViewArc1)
    }

    // MARK: FM settings page (CFmSettings)

    static var showDots: Bool { defaults.bool(forKey: SZSettingsKeyFMShowDots) }
    static var fullRow: Bool { defaults.bool(forKey: SZSettingsKeyFMFullRow) }
    static var showGrid: Bool { defaults.bool(forKey: SZSettingsKeyFMShowGrid) }

    /// Toolbars mask: bit0 labels, bit1 large buttons, bit2 standard toolbar, bit3 archive toolbar;
    /// bit31 = "never saved" (kDefaultToolbarMask = bit31 | 8 | 4 | 1).
    static var toolbarsMask: UInt32 {
        get {
            if let v = defaults.object(forKey: SZSettingsKeyFMToolbars) as? Int { return UInt32(truncatingIfNeeded: v) }
            return 0x8000_0000 | 8 | 4 | 1
        }
        set { defaults.set(Int(newValue), forKey: SZSettingsKeyFMToolbars) }
    }

    /// Favorites: exactly 10 strings (FolderShortcuts).
    static var folderShortcuts: [String] {
        get {
            var list = defaults.stringArray(forKey: SZSettingsKeyFMFolderShortcuts) ?? []
            while list.count < 10 { list.append("") }
            return Array(list.prefix(10))
        }
        set { defaults.set(Array(newValue.prefix(10)), forKey: SZSettingsKeyFMFolderShortcuts) }
    }

    /// Folders History (max 100, most recent first).
    static var folderHistory: [String] {
        get { defaults.stringArray(forKey: SZSettingsKeyFMFolderHistory) ?? [] }
        set { defaults.set(Array(newValue.prefix(100)), forKey: SZSettingsKeyFMFolderHistory) }
    }

    static func addToFolderHistory(_ path: String) {
        guard !path.isEmpty else { return }
        var list = folderHistory.filter { $0 != path }
        list.insert(path, at: 0)
        folderHistory = list
    }

    static var autoRefresh: Bool {
        get { defaults.object(forKey: "FM.AutoRefresh") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "FM.AutoRefresh") }
    }

    static var timestampShowUTC: Bool {
        get { defaults.bool(forKey: "FM.TimestampShowUTC") }
        set { defaults.set(newValue, forKey: "FM.TimestampShowUTC") }
    }

    static var timestampLevel: Int {
        get { defaults.object(forKey: "FM.TimestampLevel") as? Int ?? Int(SZTimestampLevel.min.rawValue) }
        set { defaults.set(newValue, forKey: "FM.TimestampLevel") }
    }

    static func synchronize() { defaults.synchronize() }
}
