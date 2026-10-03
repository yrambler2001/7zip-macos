// CompressBrowseFilter.swift -- the file-type filters of the Compress dialog's "..." button
// (IDB_COMPRESS_SET_ARCHIVE, `CCompressDialog::OnButtonSetArchive`, CompressDialog.cpp:879-1016;
// 01b-fm-dialogs-settings.md section 4.23, parity.md D item 11).
//
// Windows hands `CBrowseInfo::BrowseForFile` one filter per entry of the format combo,
// "<Name> (<ext> <ext> ...)", then an "Archive: (<main ext> ...)" filter with every mask, then
// "All Files (*)"; in SFX mode only "exe" and "All Files". The initial filter is the format that is
// selected (0 in SFX mode). After the dialog: in SFX mode the extension becomes ".exe"; when a
// format filter was chosen its main extension is appended unless the name already has one of the
// format's extensions, and the format combo follows the chosen filter. NSSavePanel has no filter
// combo, so the same list is an accessory pop-up that drives `allowedContentTypes`.

import Cocoa
import SevenZipKit
import UniformTypeIdentifiers

struct CompressBrowseFilter: Equatable {
    /// What the pop-up shows: "7z (7z)", "Archive: (7z zip ...)", "All Files (*)".
    let title: String
    /// The extensions the filter admits, lowercase without dot; empty = every file.
    let extensions: [String]
    /// The format-combo row this filter stands for, nil for the aggregate / "exe" / all filters.
    let formatListIndex: Int?

    /// `k_DontSave_Exts` (CompressDialog.cpp:876): extensions a format can read but is never
    /// saved under, so they are kept out of the masks.
    static let dontSaveExtensions: Set<String> = ["xpi", "odt", "ods", "docx", "xlsx"]

    /// The filter list and the index to start on (`filterIndex`).
    static func filters(formats: [(name: String, extensions: [String], mainExtension: String)],
                        selectedFormat: Int, sfx: Bool,
                        archiveLabel: String, allFilesLabel: String) -> (filters: [CompressBrowseFilter], initial: Int) {
        var filters: [CompressBrowseFilter] = []
        var initial = 0
        if sfx {
            filters.append(CompressBrowseFilter(title: "exe (exe)", extensions: ["exe"], formatListIndex: nil))
        } else {
            initial = selectedFormat
            var allMasks: [String] = []
            var mainExtensions: [String] = []
            for (i, format) in formats.enumerated() {
                let exts = format.extensions.filter { !dontSaveExtensions.contains($0.lowercased()) }
                filters.append(CompressBrowseFilter(title: "\(format.name) (\(exts.joined(separator: " ")))",
                                                    extensions: exts, formatListIndex: i))
                allMasks += exts
                mainExtensions.append(format.mainExtension)
            }
            // IDT_COMPRESS_ARCHIVE 4001 without its '&', then the main extensions only.
            let label = archiveLabel.replacingOccurrences(of: "&", with: "")
            filters.append(CompressBrowseFilter(title: "\(label) (\(mainExtensions.joined(separator: " ")))",
                                                extensions: allMasks, formatListIndex: nil))
        }
        filters.append(CompressBrowseFilter(title: "\(allFilesLabel) (*)", extensions: [], formatListIndex: nil))
        if initial < 0 || initial >= filters.count { initial = filters.count - 1 }
        return (filters, initial)
    }

    /// The path after the save panel (CompressDialog.cpp:978-1006): SFX forces ".exe"; a format
    /// filter appends the format's main extension unless the name already carries one of its
    /// extensions (`ai.FindExtension(ext)`, case-blind).
    static func resolvedPath(_ path: String, filter: CompressBrowseFilter, sfx: Bool,
                             mainExtension: (Int) -> String) -> String {
        if sfx {
            return deletingExtension(path) + ".exe"
        }
        guard let index = filter.formatListIndex else { return path }
        let name = (path as NSString).lastPathComponent
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            let ext = String(name[name.index(after: dot)...]).lowercased()
            if filter.extensions.contains(where: { $0.lowercased() == ext }) { return path }
        }
        return (path.hasSuffix(".") ? path : path + ".") + mainExtension(index)
    }

    /// `GetExtDotPos` + `DeleteFrom`: the last dot of the file name, not of a folder name.
    private static func deletingExtension(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return path }
        let dropped = name.distance(from: dot, to: name.endIndex)
        return String(path.dropLast(dropped))
    }

    /// The content types `NSSavePanel` gets for this filter; empty = anything.
    var contentTypes: [UTType] {
        extensions.compactMap { UTType(filenameExtension: $0, conformingTo: .data) }
    }
}

/// The accessory pop-up (the "Save as type" combo of the Windows file dialog).
final class CompressBrowseFilterChooser: NSObject {
    let filters: [CompressBrowseFilter]
    let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private weak var panel: NSSavePanel?

    init(filters: [CompressBrowseFilter], initial: Int, panel: NSSavePanel) {
        self.filters = filters
        self.panel = panel
        super.init()
        popup.addItems(withTitles: filters.map(\.title))
        popup.selectItem(at: initial)
        popup.target = self
        popup.action = #selector(filterChanged(_:))
        let label = NSTextField(labelWithString: "Save as type:")
        let row = NSStackView(views: [label, popup])
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        row.frame = NSRect(origin: .zero, size: row.fittingSize)
        panel.accessoryView = row
        apply()
    }

    var selected: CompressBrowseFilter { filters[max(popup.indexOfSelectedItem, 0)] }

    @objc private func filterChanged(_ sender: Any?) { apply() }

    private func apply() {
        guard let panel else { return }
        // Typing another extension stays possible, as in the Windows dialog; the rules of
        // `resolvedPath` then decide, not the panel.
        panel.allowsOtherFileTypes = true
        panel.allowedContentTypes = selected.contentTypes
    }
}
