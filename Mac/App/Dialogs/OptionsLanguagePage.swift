// OptionsLanguagePage.swift -- Options > Language (IDD_LANG 2101, "Language").
// 01b-fm-dialogs-settings.md section 4.9, 01-fm-feature-inventory.md section 7.1, section 9 #18.
//
// As on Windows (LangPage.cpp, dlgfeel finding 21): one drop-down list (IDC_LANG_LANG 100,
// CBS_DROPDOWNLIST, 240 px) of "<English name> : <native name>" with the "---" / "***" / "+++"
// marks, the built-in English first and the rest by name; and the static IDT_LANG_INFO 101 under
// it with ShowLangInfo's text. Picking an entry only shows its info and enables Apply
// (CBN_SELCHANGE); Apply / OK store the `Lang` value and switch the language (OnApply ->
// SaveRegLang + ReloadLang), and the sheet re-labels everything (OptionsDialog.cpp:31-50).

import Cocoa
import SevenZipKit

final class OptionsLanguagePage: OptionsPageBase {

    override var pageID: UInt32 { 2101 }                      // IDD_LANG
    override var fallbackTitle: String { "Language" }
    override var helpTopic: String { "fm/options.htm#language" }

    struct Entry {
        let code: String            // "" system default, "-" built-in English, else the file stem
        let englishName: String
        let nativeName: String
        let stringCount: Int
        let mark: String            // "***" exact locale match, "+++" same primary language
        var comments: [String] = []
        var missingLines: [String] = []
        var extraLines: [String] = []
    }

    private(set) var entries: [Entry] = []
    private let combo = NSPopUpButton(frame: .zero, pullsDown: false)   // IDC_LANG_LANG 100
    private let langLabel = OptionsUI.label(2102, "Language:")      // IDT_LANG_LANG 2102
    // IDT_LANG_INFO 101: a multi-line static (SS_NOPREFIX) the text simply overflows.
    private let infoField = RcPlace.makeWrappingLabel("")
    /// The files that did not load, reported once per page load (LangPage.cpp:262-263).
    private(set) var reportedLoadErrors: [String] = []

    /// The text IDT_LANG_INFO shows right now (for tests).
    var infoText: String { infoField.stringValue }
    /// The combo's entries as Windows writes them (for tests).
    var comboTitles: [String] { combo.itemTitles }
    private var originalCode = ""
    private var needSave = false

    override func loadView() {
        super.loadView()
        combo.target = self
        combo.action = #selector(comboChanged(_:))
        infoField.lineBreakMode = .byWordWrapping
        infoField.cell?.truncatesLastVisibleLine = false
        let rc = self.rc
        form.add(langLabel, rc, 2102)
        form.add(combo, rc, 100)
        form.add(infoField, rc, 101)
        infoField.frame.size.height = rc.rect(101).height
    }

    // MARK: OnInit (LangPage.cpp:57-265)

    override func pageDidLoad() {
        originalCode = Settings.language
        needSave = false
        buildEntries()
        relabelPage()
        reportLoadErrors(SZLang.shared.failedLanguageFiles)
    }

    /// `MessageBoxW(NULL, error, L"Error in Lang file", MB_ICONERROR)` at the end of OnInit
    /// (LangPage.cpp:262-263): the names of the *.txt files that did not open, space-separated.
    /// A sheet of the Options window once it is on screen, not an app-modal box.
    func reportLoadErrors(_ files: [String]) {
        reportedLoadErrors = files
        guard !files.isEmpty else { return }
        // MessageBoxW(NULL, error, "Error in Lang file", MB_ICONERROR).
        WinMessageBox.show(files.joined(separator: " "), caption: "Error in Lang file", icon: .error,
                           owner: view.window ?? NSApp.mainWindow)
    }

    private func buildEntries() {
        let candidates = SZLang.systemLanguageCandidates          // ["pt-br", "pt"] most specific first
        let exact = candidates.first?.lowercased()
        let primary = candidates.last?.lowercased()
        let englishCount = SZLang.shared.englishStringCount

        // LangPage.cpp:66-76: the built-in English record, Order 0, Mark "---".
        let english = Entry(code: "-", englishName: "English", nativeName: "English",
                            stringCount: englishCount, mark: "---")
        var others: [Entry] = []
        for info in SZLang.shared.availableLanguages {
            let code = info.code.lowercased()
            var mark = ""
            if code == exact {
                mark = "***"
            } else if let primary, code == primary || code.hasPrefix(primary + "-") {
                mark = "+++"
            }
            others.append(Entry(code: info.code,
                                englishName: info.englishName.isEmpty ? info.code : info.englishName,
                                nativeName: info.nativeName,
                                stringCount: info.stringCount,
                                mark: mark,
                                comments: info.comments,
                                missingLines: info.missingLines,
                                extraLines: info.extraLines))
        }
        // CLangListRecord::Compare: Order, then the displayed name, case-insensitively.
        others.sort { Self.comboTitle($0, withMark: false).caseInsensitiveCompare(Self.comboTitle($1, withMark: false))
            == .orderedAscending }
        entries = [english] + others
        combo.removeAllItems()
        for entry in entries { combo.addItem(withTitle: Self.comboTitle(entry, withMark: true)) }
        // The selected record: the language in use (g_LangID), else the English one.
        let current = originalCode.isEmpty ? SZLang.shared.currentLanguageCode : originalCode
        let index = entries.firstIndex { $0.code.caseInsensitiveCompare(current) == .orderedSame } ?? 0
        combo.selectItem(at: index)
    }

    /// "<English> : <native>" (NativeLangString) and "  <mark>" (LangPage.cpp:245-252).
    static func comboTitle(_ entry: Entry, withMark: Bool) -> String {
        var s = entry.englishName
        if !entry.nativeName.isEmpty { s += " : " + entry.nativeName }
        if withMark, !entry.mark.isEmpty { s += "  " + entry.mark }
        return s
    }

    override func relabelPage() {
        langLabel.stringValue = Lang.text(2102, "Language:")
        showLangInfo()
    }

    /// ShowLangInfo (LangPage.cpp:334-358): "<name> : <lines> / <en.ttt lines> = NN%", the file's
    /// comment lines, then "------ Missing lines: N :" and "------ Extra lines: N :" with up to 50
    /// "<id> : <text>" rows each (AddVectorToString / AddVectorToString2, LangPage.cpp:300-332).
    private func showLangInfo() {
        let row = combo.indexOfSelectedItem
        guard entries.indices.contains(row) else {
            infoField.stringValue = ""
            return
        }
        infoField.stringValue = Self.langInfoText(entries[row], englishCount: SZLang.shared.englishStringCount)
    }

    static func langInfoText(_ entry: Entry, englishCount: Int) -> String {
        var s = ""
        s = entry.code + " : \(entry.stringCount)"
        if englishCount != 0 {
            s += " / \(englishCount) = \(entry.stringCount * 100 / englishCount)%"
        }
        s += "\n"
        appendLines(&s, entry.comments)
        appendSection(&s, "Missing lines", entry.missingLines)
        appendSection(&s, "Extra lines", entry.extraLines)
        return s
    }

    /// AddVectorToString: at most 50 lines, a line longer than 1500 characters skipped, a leading
    /// ';' (the comment marker) dropped and the rest trimmed.
    private static func appendLines(_ s: inout String, _ lines: [String]) {
        for line in lines.prefix(50) {
            guard line.count <= 1500 else { continue }
            var a = line
            if a.hasPrefix(";") { a = String(a.dropFirst()).trimmingCharacters(in: .whitespaces) }
            s += a + "\n"
        }
    }

    /// AddVectorToString2: nothing when empty, else "\n------ <name>: <count> :\n" and the lines.
    private static func appendSection(_ s: inout String, _ name: String, _ lines: [String]) {
        guard !lines.isEmpty else { return }
        s += "\n------ \(name): \(lines.count) :\n"
        appendLines(&s, lines)
    }

    /// CBN_SELCHANGE (LangPage.cpp:282-292): the info, and Apply.
    @objc private func comboChanged(_ sender: Any?) {
        showLangInfo()
        guard !initMode else { return }
        needSave = true
        changed()
    }

    // MARK: OnApply (LangPage.cpp:267-280)

    override func applyPage() -> Bool {
        guard needSave else { return true }
        let row = combo.indexOfSelectedItem
        guard entries.indices.contains(row) else { return true }
        let code = entries[row].code
        Settings.language = code
        originalCode = code
        needSave = false
        // ReloadLang(); LangWasChanged = true -> the sheet and the main window re-label.
        do {
            try SZLang.shared.loadLanguage(code: code)
        } catch {
            WinMessageBox.run(error.localizedDescription, caption: "Error in Lang file", icon: .error,
                              owner: view.window)
            return true
        }
        owner?.languageDidChange()
        NotificationCenter.default.post(name: Settings.Group.language.notificationName, object: nil,
                                        userInfo: [Settings.keyUserInfoKey: Settings.Key.lang,
                                                   Settings.groupUserInfoKey: Settings.Group.language])
        return true
    }

    /// Cancel: nothing was switched before Apply.
    override func cancelPage() {
        needSave = false
    }
}
