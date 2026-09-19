// OptionsEditorPage.swift -- Options > Editor (IDD_EDIT 2103, "Editor"): the viewer, editor and
// diff programs. 01b-fm-dialogs-settings.md section 4.7 / 5.2, 01-fm-feature-inventory.md
// section 9 #10.
//
// Windows browses for an .exe and drops any arguments the field held (SplitCmdLineSmart). On
// macOS a "program" is usually an application bundle, so the browse panel accepts both a bundle
// and a plain executable; the stored string may still carry arguments, exactly like Windows.

import Cocoa
import UniformTypeIdentifiers
import SevenZipKit

final class OptionsEditorPage: OptionsPageBase {

    override var pageID: UInt32 { 2103 }                      // IDD_EDIT
    override var fallbackTitle: String { "Editor" }
    override var helpTopic: String { "FM/options.htm#editor" }

    /// One row: label, path field, browse button, and the setting it maps to.
    private struct Row {
        let langID: UInt32
        let fallback: String
        let hint: String
        let get: () -> String
        let set: (String) -> Void
    }

    private var rows: [Row] = []
    private var labels: [NSTextField] = []
    private var fields: [NSTextField] = []
    private var changedRows: Set<Int> = []

    override func loadView() {
        super.loadView()
        rows = [
            // IDT_EDIT_VIEWER 543 / IDE_EDIT_VIEWER 100 / IDB_EDIT_VIEWER 101 -- FM.Viewer
            Row(langID: 543, fallback: "View", hint: "empty = Quick Look",
                get: { Settings.viewerPath }, set: { Settings.viewerPath = $0 }),
            // IDT_EDIT_EDITOR 2104 / IDE_EDIT_EDITOR 102 / IDB_EDIT_EDITOR 103 -- FM.Editor
            Row(langID: 2104, fallback: "Editor", hint: "empty = TextEdit (the notepad.exe fallback)",
                get: { Settings.editorPath }, set: { Settings.editorPath = $0 }),
            // IDT_EDIT_DIFF 2105 / IDE_EDIT_DIFF 104 / IDB_EDIT_DIFF 105 -- FM.Diff
            Row(langID: 2105, fallback: "Diff", hint: "empty hides the Diff command",
                get: { Settings.diffPath }, set: { Settings.diffPath = $0 }),
        ]

        var views: [NSView] = []
        for (index, row) in rows.enumerated() {
            let label = OptionsUI.colonLabel(row.langID, row.fallback)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
            let field = OptionsUI.textField(self, #selector(fieldEdited(_:)))
            field.tag = index
            field.delegate = self
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
            field.placeholderString = row.hint
            let button = OptionsUI.browseButton(self, #selector(browse(_:)))
            button.tag = index
            labels.append(label)
            fields.append(field)
            views.append(OptionsUI.vstack([label, OptionsUI.hstack([field, button])], spacing: 4))
        }
        views.append(OptionsUI.note("A value may be an application bundle (\u{201C}/Applications/BBEdit.app\u{201D}), "
                                    + "an executable, or a command line with arguments \u{2014} the file path is "
                                    + "appended as the last argument, as on Windows."))
        install(OptionsUI.vstack(views, spacing: 12))
    }

    // MARK: OnInit

    override func pageDidLoad() {
        for (index, row) in rows.enumerated() { fields[index].stringValue = row.get() }
        changedRows.removeAll()
        relabelPage()
    }

    override func relabelPage() {
        for (index, row) in rows.enumerated() {
            let base = Lang.text(row.langID, row.fallback)
            labels[index].stringValue = base.hasSuffix(":") ? base : base + ":"
        }
    }

    @objc private func fieldEdited(_ sender: Any?) {
        guard let field = sender as? NSTextField else { return }
        changedRows.insert(field.tag)
        changed()
    }

    /// Edit_BrowseForFile (EditPage.cpp:88-125): the chosen path replaces the whole text.
    @objc private func browse(_ sender: NSButton) {
        let index = sender.tag
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application, .unixExecutable]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.fields[index].stringValue = url.path
            self.changedRows.insert(index)
            self.changed()
        }
    }

    // MARK: OnApply (EditPage.cpp:61-79 -- only changed rows)

    override func applyPage() -> Bool {
        for index in changedRows.sorted() {
            rows[index].set(fields[index].stringValue.trimmingCharacters(in: .whitespaces))
        }
        changedRows.removeAll()
        return true
    }
}

extension OptionsEditorPage: NSTextFieldDelegate {
    /// EN_CHANGE outside _initMode marks the row changed (EditPage.cpp:142-158).
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        changedRows.insert(field.tag)
        changed()
    }
}
