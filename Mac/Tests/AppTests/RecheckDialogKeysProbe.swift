// RecheckDialogKeysProbe.swift -- the Mac half of recheck-data/win/keys.txt: for every dialog the
// first responder it opens with (and the selected text), the default button, the Tab order (the
// nextKeyView chain from the first responder, as Full Keyboard Access walks it) and whether Esc
// has a Cancel to go to. Written to Mac/build/recheck/out/dialog-keys.txt; runs only when
// Mac/build/recheck/PROBE exists.

import AppKit
import SevenZipKit
import XCTest
@testable import SevenZipAppHost

enum DialogKeys {
    static func desc(_ v: NSView?) -> String {
        guard let v else { return "none" }
        var view = v
        if let tv = v as? NSTextView, let field = tv.delegate as? NSView { view = field }
        let kind = String(describing: type(of: view))
        var text = ""
        switch view {
        case let b as NSButton: text = b.title
        case let p as NSPopUpButton: text = p.titleOfSelectedItem ?? ""
        case let f as NSTextField: text = f.stringValue
        default: break
        }
        if text.count > 30 { text = String(text.prefix(30)) + "..." }
        return "\(kind) '\(text)'"
    }

    /// The views a Tab can reach with Full Keyboard Access on: controls and lists.
    static func isTabStop(_ v: NSView) -> Bool {
        if v.isHiddenOrHasHiddenAncestor { return false }
        if let c = v as? NSControl { return c.isEnabled && !(c is NSTextField && !((c as! NSTextField).isEditable || (c as! NSTextField).isSelectable)) }
        return v is NSTableView || v is NSCollectionView
    }

    static func dump(_ name: String, _ window: NSWindow) -> String {
        var first = window.firstResponder as? NSView
        if let tv = first as? NSTextView, let field = tv.delegate as? NSView { first = field }
        var out = "DIALOG \(name) title='\(window.title)'"
        let def = window.defaultButtonCell?.controlView as? NSButton
            ?? allViews(window.contentView).compactMap { $0 as? NSButton }.first { $0.keyEquivalent == "\r" }
        out += " default=\(desc(def)) initial=\(desc(first))"
        if let tv = window.firstResponder as? NSTextView {
            let r = tv.selectedRange()
            out += " sel=\(r.location)-\(r.location + r.length)"
        }
        out += "\n"
        var v = first
        var seen = Set<ObjectIdentifier>()
        for k in 1...40 {
            guard let cur = v else { break }
            var next = cur.nextKeyView
            while let n = next, !isTabStop(n), !seen.contains(ObjectIdentifier(n)) { seen.insert(ObjectIdentifier(n)); next = n.nextKeyView }
            guard let n = next else { out += "  tab \(k) : (end of chain)\n"; break }
            out += "  tab \(k) : \(desc(n))\n"
            if n === first || seen.contains(ObjectIdentifier(n)) { break }
            seen.insert(ObjectIdentifier(n))
            v = n
        }
        let esc = allViews(window.contentView).compactMap { $0 as? NSButton }.first { $0.keyEquivalent == "\u{1b}" }
        out += "  esc button: \(desc(esc))\n"
        return out
    }

    static func allViews(_ v: NSView?) -> [NSView] {
        guard let v else { return [] }
        return [v] + v.subviews.flatMap { allViews($0) }
    }
}

final class RecheckDialogKeysProbe: AppHostTestCase {

    private var fixtures: String { TestPaths.fixtures }
    private var archive: String { TestPaths.fixture("test.7z") }
    private var out = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        let base = (TestPaths.repoRoot ?? "/tmp") + "/Mac/build/recheck"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: base + "/PROBE"), "recheck probe not requested")
    }

    private func probe(_ name: String, _ present: () -> Void) {
        _ = ModalProbe.present(timeout: 30, present) { window in
            RunLoop.current.run(mode: .modalPanel, before: Date().addingTimeInterval(0.3))
            self.out += DialogKeys.dump(name, window)
        }
    }

    func testDialogKeys() throws {
        probe("about") { AboutDialog.show(parent: nil) }
        probe("copy") { _ = CopyMoveDialog.run(move: false, value: "/Users/me/Documents/", history: [], info: "", parent: nil) }
        probe("createfolder") {
            _ = ComboDialog.run(title: Lang.text(6300, "Create Folder"), label: Lang.text(6302, "Folder name:"),
                                value: Lang.text(6304, "New Folder"), parent: nil)
        }
        probe("comment") { _ = CommentDialog.run(value: "", parent: nil) }
        probe("select") {
            _ = ComboDialog.run(title: Lang.text(6402, "Select"), label: Lang.text(6404, "Mask:"), value: "*", strings: ["*"], parent: nil)
        }
        probe("link") { _ = LinkDialog.run(currentDirPrefix: fixtures + "/", filePath: archive, anotherPath: TestPaths.realHome, parent: nil) }
        probe("split") { _ = SplitDialog.run(filePath: archive, path: fixtures, parent: nil) }
        probe("combine") {
            _ = CombineDialog.run(title: Lang.text(7400, "Combine Files"), prompt: Lang.text(7402, "Combine to:"),
                                  info: TestPaths.fixture("multi.7z.001"), path: fixtures, parent: nil)
        }
        var history = ListViewDialogOptions()
        history.title = Lang.text(6601, "Folders History")
        history.strings = [fixtures, "/tmp"]
        history.deleteIsAllowed = true
        probe("history") { _ = ListViewDialog.run(history, parent: nil) }
        try SZCodecs.loadCodecs()
        let results = try SZHasher.hash(paths: ["test.7z"], relativeTo: fixtures, methods: ["CRC32"], recursive: false, progress: nil)
        probe("hash") { HashResultsDialog.show(results: results, parent: nil) }
        probe("tempfiles") { ToolsTempFilesDialog.show(parent: nil) }
        probe("benchmark") { BenchmarkDialog.run(totalMode: false, parent: nil) }
        var extract = ExtractDialog.Options()
        extract.directoryPath = fixtures + "/"
        extract.archivePath = archive
        probe("extract") { _ = ExtractDialog.run(extract) }
        var input = CompressDialogInput()
        input.directoryPrefix = fixtures + "/"
        input.archiveBaseName = "a"
        input.itemPaths = [archive]
        probe("compress") { _ = CompressDialogController.run(input) }
        var pw = PasswordDialog.Options()
        pw.subject = archive
        probe("password") { _ = PasswordDialog.run(pw, parent: nil) }
        let old = OverwriteDialog.FileInfo(path: archive, size: 838, time: Date())
        let new = OverwriteDialog.FileInfo(path: TestPaths.fixture("test.zip"), size: 1024, time: Date())
        probe("overwrite") { _ = OverwriteDialog.run(oldFile: old, newFile: new, showExtraButtons: true, parent: nil) }
        let controller = OptionsWindowController.shared
        if let window = controller.window {
            _ = ModalProbe.present({ OptionsWindowController.showOptions() }) { w in
                RunLoop.current.run(mode: .modalPanel, before: Date().addingTimeInterval(0.3))
                self.out += DialogKeys.dump("options", w)
            }
            ModalProbe.close(window)
        }
        let path = (TestPaths.repoRoot ?? "/tmp") + "/Mac/build/recheck/out/dialog-keys.txt"
        try out.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
