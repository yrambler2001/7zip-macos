// OptionsLanguagePage.swift -- Options > Language (IDD_LANG 2101, "Language").
// 01b-fm-dialogs-settings.md section 4.9, 01-fm-feature-inventory.md section 7.1, section 9 #18.
//
// Windows shows a combo box; this page shows the same entries as a list with the English name,
// the native name and the translated-line count, because a list can carry all three columns at
// once. Entry order: the system default, then the built-in English entry ("-", LangPage.cpp:88-99),
// then every Lang/*.txt in the bundle. Entries that match the user's locale are marked ***
// (exact) or +++ (same primary language), as Lang_GetShortNames_for_DefaultLang does.
//
// Selecting a language switches it immediately (loadLanguage + relabel + notification), so open
// windows re-label without a restart; Apply/OK persist the `Lang` value and Cancel puts the
// original language back.

import Cocoa
import SevenZipKit

final class OptionsLanguagePage: OptionsPageBase, NSTableViewDataSource, NSTableViewDelegate {

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
    private let table = NSTableView()
    private let langLabel = OptionsUI.label(2102, "Language:")      // IDT_LANG_LANG 2102
    // IDT_LANG_INFO 101: a static on Windows that the text simply overflows; a read-only text view
    // here, because ShowLangInfo can list up to 50 missing and 50 extra ids.
    private let infoView = NSTextView()
    private var infoScroll: NSScrollView!
    /// The files that did not load, reported once per page load (LangPage.cpp:262-263).
    private(set) var reportedLoadErrors: [String] = []

    /// The text IDT_LANG_INFO shows right now (for tests).
    var infoText: String { infoView.string }
    private var originalCode = ""
    private var appliedCode = ""
    private var needSave = false

    override func loadView() {
        super.loadView()
        table.addTableColumn(OptionsUI.column("mark", "", width: 34))
        table.addTableColumn(OptionsUI.column("english", "English name", width: 170))
        table.addTableColumn(OptionsUI.column("native", "Native name", width: 170))
        table.addTableColumn(OptionsUI.column("code", "Code", width: 64))
        table.addTableColumn(OptionsUI.column("lines", "Strings", width: 120))
        table.usesAlternatingRowBackgroundColors = true
        table.style = .fullWidth
        table.rowHeight = 19
        table.allowsMultipleSelection = false
        table.dataSource = self
        table.delegate = self

        infoView.isEditable = false
        infoView.isSelectable = true
        infoView.drawsBackground = false
        infoView.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        infoView.textColor = .secondaryLabelColor
        infoView.textContainerInset = NSSize(width: 2, height: 2)
        infoView.isVerticallyResizable = true
        infoView.isHorizontallyResizable = false
        infoView.autoresizingMask = [.width]
        infoView.textContainer?.widthTracksTextView = true
        infoScroll = NSScrollView()
        infoScroll.documentView = infoView
        infoScroll.hasVerticalScroller = true
        infoScroll.autohidesScrollers = true
        infoScroll.drawsBackground = false
        infoScroll.borderType = .noBorder
        infoScroll.translatesAutoresizingMaskIntoConstraints = false
        infoScroll.heightAnchor.constraint(equalToConstant: 110).isActive = true

        let scroll = OptionsUI.scrollTable(table, minHeight: 200)
        let stack = OptionsUI.vstack([langLabel, scroll, infoScroll], spacing: 8)
        install(stack)
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            infoScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            langLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
        ])
    }

    // MARK: OnInit (LangPage.cpp:88-158)

    override func pageDidLoad() {
        originalCode = Settings.language
        appliedCode = originalCode
        needSave = false
        buildEntries()
        table.reloadData()
        selectRow(for: originalCode)
        relabelPage()
        reportLoadErrors(SZLang.shared.failedLanguageFiles)
    }

    /// `MessageBoxW(NULL, error, L"Error in Lang file", MB_ICONERROR)` at the end of OnInit
    /// (LangPage.cpp:262-263): the names of the *.txt files that did not open, space-separated.
    /// A sheet of the Options window once it is on screen, not an app-modal box.
    func reportLoadErrors(_ files: [String]) {
        reportedLoadErrors = files
        guard !files.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Error in Lang file"
        alert.informativeText = files.joined(separator: " ")
        alert.addButton(withTitle: Lang.text(401, "OK"))
        DispatchQueue.main.async { [weak self] in
            ErrorAlert.present(alert, on: self?.view.window ?? NSApp.mainWindow)
        }
    }

    private func buildEntries() {
        let candidates = SZLang.systemLanguageCandidates          // ["pt-br", "pt"] most specific first
        let exact = candidates.first?.lowercased()
        let primary = candidates.last?.lowercased()
        let englishCount = SZLang.shared.englishStringCount

        var list: [Entry] = [
            Entry(code: "", englishName: "System default", nativeName: candidates.first ?? "",
                  stringCount: 0, mark: ""),
            // LangPage.cpp:88-99: the first combo entry is the built-in English resource set.
            Entry(code: "-", englishName: "English", nativeName: "English",
                  stringCount: englishCount, mark: "---"),       // LangPage.cpp:69: Mark = "---"
        ]
        for info in SZLang.shared.availableLanguages {
            let code = info.code.lowercased()
            var mark = ""
            if code == exact {
                mark = "***"
            } else if let primary, code == primary || code.hasPrefix(primary + "-") {
                mark = "+++"
            }
            list.append(Entry(code: info.code,
                              englishName: info.englishName.isEmpty ? info.code : info.englishName,
                              nativeName: info.nativeName,
                              stringCount: info.stringCount,
                              mark: mark,
                              comments: info.comments,
                              missingLines: info.missingLines,
                              extraLines: info.extraLines))
        }
        entries = list
        sizeColumns()
    }

    private func countText(_ entry: Entry) -> String {
        let total = max(SZLang.shared.englishStringCount, 1)
        return entry.stringCount > 0 ? "\(entry.stringCount) / \(total) = \(entry.stringCount * 100 / total)%" : ""
    }

    private func sizeColumns() {
        OptionsUI.sizeColumnsToContent(table, texts: [
            "mark": entries.map(\.mark),
            "english": entries.map(\.englishName),
            "native": entries.map(\.nativeName),
            "code": entries.map { $0.code.isEmpty ? "auto" : $0.code },
            "lines": entries.map(countText),
        ])
    }

    override func relabelPage() {
        langLabel.stringValue = Lang.text(2102, "Language:")
        showLangInfo()
        table.reloadData()
    }

    private func selectRow(for code: String) {
        let index = entries.firstIndex { $0.code.caseInsensitiveCompare(code) == .orderedSame } ?? 0
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
    }

    /// ShowLangInfo (LangPage.cpp:334-358): "<name> : <lines> / <en.ttt lines> = NN%", the file's
    /// comment lines, then "------ Missing lines: N :" and "------ Extra lines: N :" with up to 50
    /// "<id> : <text>" rows each (AddVectorToString / AddVectorToString2, LangPage.cpp:300-332).
    private func showLangInfo() {
        let row = table.selectedRow
        guard entries.indices.contains(row) else {
            infoView.string = ""
            return
        }
        infoView.string = Self.langInfoText(entries[row], englishCount: SZLang.shared.englishStringCount)
        infoView.scrollToBeginningOfDocument(nil)
    }

    static func langInfoText(_ entry: Entry, englishCount: Int) -> String {
        var s = ""
        switch entry.code {
        case "":
            // macOS addition: the system-default entry has no file of its own.
            s = "System default \u{2014} the lang file that matches "
                + "\(SZLang.systemLanguageCandidates.joined(separator: ", ")), else built-in English.\n"
        default:
            s = entry.code + " : \(entry.stringCount)"
            if englishCount != 0 {
                s += " / \(englishCount) = \(entry.stringCount * 100 / englishCount)%"
            }
            s += "\n"
        }
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

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[row]
        let text: String
        switch tableColumn?.identifier.rawValue ?? "" {
        case "mark": text = entry.mark
        case "english": text = entry.englishName
        case "native": text = entry.nativeName
        case "code": text = entry.code.isEmpty ? "auto" : entry.code
        default: text = countText(entry)
        }
        let cell = NSTableCellView()
        let field = NSTextField(labelWithString: text)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingTail
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// CBN_SELCHANGE (LangPage.cpp:288-297) plus the immediate switch this port adds.
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !initMode, entries.indices.contains(table.selectedRow) else { return }
        let code = entries[table.selectedRow].code
        guard code != appliedCode else { return }
        switchLanguage(to: code)
        needSave = true
        changed()
    }

    private func switchLanguage(to code: String) {
        do {
            try SZLang.shared.loadLanguage(code: code)
        } catch {
            // LangPage.cpp:262-263 reports unreadable files in one "Error in Lang file" box.
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Error in Lang file"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return
        }
        appliedCode = code
        showLangInfo()
        // Re-label this window, the menu bar and the toolbars, then tell everyone else.
        owner?.languageDidChange()
        NotificationCenter.default.post(name: Settings.Group.language.notificationName, object: nil,
                                        userInfo: [Settings.keyUserInfoKey: Settings.Key.lang,
                                                   Settings.groupUserInfoKey: Settings.Group.language])
    }

    // MARK: OnApply (LangPage.cpp:267-280)

    override func applyPage() -> Bool {
        guard needSave else { return true }
        Settings.language = appliedCode
        originalCode = appliedCode
        needSave = false
        return true
    }

    /// Cancel: put the language that was active when the page opened back.
    override func cancelPage() {
        guard appliedCode != originalCode else { return }
        let code = originalCode
        try? SZLang.shared.loadLanguage(code: code)
        appliedCode = code
        needSave = false
        withoutChangeTracking {
            selectRow(for: code)
            owner?.languageDidChange()
        }
    }
}
