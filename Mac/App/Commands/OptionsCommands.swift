// OptionsCommands.swift -- Tools > Options (IDM_OPTIONS 900) and what 7zFM does after the
// property sheet closes (OptionsDialog.cpp:31-50, 01b-fm-dialogs-settings.md section 4.22):
//
//   if (langPage.LangWasChanged) { MyLoadMenu(true); ReloadToolbars(); MoveSubWindows(); ReloadLangItems(); }
//   g_App.SetListSettings();
//   g_App.RefreshAllPanels();
//
// The selector is already declared in MenuActions and wired to both Tools > Options and the
// application menu's Options item, so nothing outside this scope needs to change.

import Cocoa
import SevenZipKit

extension MainWindowController {

    @objc func toolsOptions(_ sender: Any?) {                       // IDM_OPTIONS 900
        OptionsWindowController.showOptions()
    }
}

/// The post-apply steps, factored out so every page can trigger them.
enum OptionsPostApply {

    /// g_App.SetListSettings() + g_App.RefreshAllPanels(): the list settings (ShowDots, FullRow,
    /// ShowGrid, SingleClick, AlternativeSelection, ShowRealFileIcons) plus a reload of every
    /// panel. The panel scope owns how a panel renders them; a reload is what 7zFM does too.
    static func settingsApplied(languageChanged: Bool) {
        if languageChanged { reloadLangItems() }
        NotificationCenter.default.post(name: Settings.Group.fm.notificationName, object: nil,
                                        userInfo: [Settings.groupUserInfoKey: Settings.Group.fm])
        for panel in allPanels() { panel.reload() }
    }

    /// MyLoadMenu(true) + ReloadToolbars() + ReloadLangItems(): rebuild the menu bar and re-create
    /// the toolbar items so every title comes from the new lang file.
    static func reloadLangItems() {
        NSApp.mainMenu = MainMenu.build()
        // ReloadToolbars: every open window's strip (FMToolbar.swift) takes the new labels. A
        // closed window is skipped -- File > New Window builds a fresh one (winmatch; the NSToolbar
        // this replaced raised on a closed window, requests.md `modalfix` -> `options`).
        for controller in MainWindows.controllers where !controller.isClosed {
            controller.reloadToolbars()
        }
    }

    /// Every panel of every window. The panels are view controllers inside the window's split
    /// view, so they are found through the view hierarchy rather than a private property.
    static func allPanels() -> [PanelViewController] {
        NSApp.windows.compactMap(\.contentView).flatMap(panels(in:))
    }

    private static func panels(in view: NSView) -> [PanelViewController] {
        if let panel = view.nextResponder as? PanelViewController { return [panel] }
        return view.subviews.flatMap(panels(in:))
    }
}
