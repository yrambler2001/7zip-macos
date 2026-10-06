// PropertiesDialog.swift -- IDM_PROPERTIES 551 / toolbar "Info" (CPanel::Properties,
// PanelMenu.cpp:172-423). A two-column CListViewDialog (IDS_PROPERTIES 6600) listing the focused
// item's properties at the panel timestamp level, the sums of a multi-selection, the folder's own
// properties and, inside an archive, one block per archive level with kSpecProps followed by the
// handler's archive properties.
//
// Parity: 01-fm-feature-inventory.md §3.11 "Properties", 01b §4.11; §9 #10 (a file-system item
// shows the same dialog instead of the shell property sheet -- "Get Info" in the System submenu
// opens this dialog too).

import AppKit
import SevenZipKit

/// Name / value pairs, built on the panel queue (the folder may not be touched on the main thread).
struct PanelPropertyLines {
    var names: [String] = []
    var values: [String] = []

    /// kSeparator / kSeparatorSmall (PanelMenu.cpp:79-80): a row of hyphens in the name column.
    static let separator = "------------------------"
    static let separatorSmall = "----------------"

    mutating func add(_ name: String, _ value: String) {
        names.append(name)
        values.append(value)
    }

    /// AddSeparator: kSeparator with an empty value (AddListAscii).
    mutating func addSeparator() { add(Self.separator, "") }
    /// AddSeparatorSmall, between two archive levels.
    mutating func addSeparatorSmall() { add(Self.separatorSmall, "") }

    static func isSeparator(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0 == "-" }
    }
}

enum PanelProperties {

    /// kSpecProps (PanelMenu.cpp:157-169): the archive-level block header properties, in order.
    static let specProps: [SZPropID] = [.path, .type, .errorType, .error, .errorFlags,
                                        .warning, .warningFlags, .offset, .phySize, .tailSize]

    /// CPanel::Properties (PanelMenu.cpp:171-415) for an archive folder, row for row -- checked
    /// against 7zFM 26.03 for a file, a folder, two files, a file and a folder, nothing selected,
    /// a file in a sub-folder (7z) and a zip item (listfeel-data/win1/dlg-prop-*.txt):
    ///
    ///  1. one operated item: every folder property of the item (GetNumberOfProperties, kpidIsDir
    ///     included, as "Folder -" in a zip), then the raw properties, then kSeparator;
    ///     several: "" | "N object(s) selected", Folders and Files when not 0 (a folder counts
    ///     itself plus its kpidNumSubDirs, its files are its kpidNumSubFiles), Size, Packed Size,
    ///     kSeparator; none: nothing;
    ///  2. the folder's kpidPath under the name of kpidName ("Name sub/"; nothing at the archive
    ///     root, where it is empty), then IFolderProperties (Size, Packed Size, Folders, Files,
    ///     CRC for an archive folder);
    ///  3. per archive level, innermost first: kSeparator, kSpecProps, the handler's archive
    ///     properties; between two levels kSeparatorSmall and the outer handler's properties of
    ///     the item the inner level was opened from (GetArcProp2);
    ///  4. the level that failed to open (NonOpen_ErrorInfo): CAgent answers GetArcProp for it
    ///     with S_OK, so 7zFM always ends with two kSeparator rows, then any error there.
    ///
    /// Values are AddPropertyString's: sizes grouped ("1 234"), times at ns precision, booleans
    /// "+" / "-", error flags as their message. Called on the panel queue.
    static func build(folder: SZFolder, itemIndices: [Int], snapshot: PanelSnapshot,
                      level: SZTimestampLevel) -> PanelPropertyLines {
        var lines = PanelPropertyLines()
        if itemIndices.count == 1, let index = itemIndices.first {
            for info in folder.properties {
                // Raw properties (IArchiveGetRawProps) follow the folder's own, rendered as
                // PanelMenu.cpp:212-246 does: hex up to 256 bytes ("data:<n>" beyond), upper case
                // for a CRC / checksum of at most 8 bytes (01 §3.11).
                let text = info.isRawProperty
                    ? folder.rawPropertyString(at: index, propID: info.propID, forPropertiesDialog: true)
                    : sizeGrouped(info.propID, folder.displayStringOfItem(at: index, propID: info.propID,
                                                                          timestampLevel: .NS))
                guard !text.isEmpty else { continue }
                if info.propID == .errorType { lines.add("Open WARNING:", "Cannot open the file as expected archive type") }
                lines.add(info.localizedName, text)
            }
            lines.addSeparator()
        } else if itemIndices.count > 1 {
            var size: UInt64 = 0, packed: UInt64 = 0, dirs: UInt64 = 0, files: UInt64 = 0
            func number(_ index: Int, _ propID: SZPropID) -> UInt64 {
                (folder.propertyOfItem(at: index, propID: propID) as? NSNumber)?.uint64Value ?? 0
            }
            for index in itemIndices {
                size &+= number(index, .size)                      // GetItemSize
                packed &+= number(index, .packSize)
                if folder.isDirectory(at: index) {
                    dirs &+= 1 &+ number(index, .numSubDirs)
                    files &+= number(index, .numSubFiles)
                } else {
                    files &+= 1
                }
            }
            lines.add("", Lang.format(Lang.get(3002, "{0} object(s) selected"), "\(itemIndices.count)"))  // IDS_N_SELECTED_ITEMS
            if dirs != 0 { lines.add(propertyName(.numSubDirs), Formatting.size(dirs)) }
            if files != 0 { lines.add(propertyName(.numSubFiles), Formatting.size(files)) }
            lines.add(propertyName(.size), Formatting.size(size))
            lines.add(propertyName(.packSize), Formatting.size(packed))
            lines.addSeparator()
        }

        // GetFolderProperty(kpidPath), named as kpidName.
        let path = folder.propertiesDialogString(forFolderProperty: .path)
        if !path.isEmpty { lines.add(propertyName(.name), path) }
        for info in folder.folderPropertyInfos {
            let text = sizeGrouped(info.propID, folder.propertiesDialogString(forFolderProperty: info.propID))
            guard !text.isEmpty else { continue }
            lines.add(info.localizedName, text)
        }

        if let arcProps = folder.arcProps {
            let levels = arcProps.levelCount
            for level2 in 0..<levels {
                let level0 = levels - 1 - level2
                lines.addSeparator()
                for propID in specProps {
                    add(&lines, propID, propertyName(propID),
                        arcProps.propertiesDialogString(atLevel: level0, propID: propID, answered: nil))
                }
                for info in arcProps.properties(atLevel: level0) {
                    add(&lines, info.propID, info.localizedName,
                        arcProps.propertiesDialogString(atLevel: level0, propID: info.propID, answered: nil))
                }
                if level2 < levels - 1 {
                    // GetArcProp2 reads Arcs[level - 1], which exists for level0 >= 1 only.
                    lines.addSeparatorSmall()
                    for info in arcProps.properties2(atLevel: level0) {
                        add(&lines, info.propID, info.localizedName,
                            arcProps.propertiesDialogString2(atLevel: level0, propID: info.propID))
                    }
                }
            }
            // The level that failed to open: two kSeparator rows once GetArcProp answers at all.
            var needSeparator = true
            for propID in specProps {
                var answered: ObjCBool = false
                let text = withUnsafeMutablePointer(to: &answered) {
                    arcProps.propertiesDialogString(atLevel: levels, propID: propID, answered: $0)
                }
                guard answered.boolValue else { continue }
                if needSeparator { lines.addSeparator(); lines.addSeparator(); needSeparator = false }
                add(&lines, propID, propertyName(propID), text)
            }
        }
        return lines
    }

    /// AddPropertyString's tail: grouped sizes, the "Open WARNING:" row before kpidErrorType.
    private static func add(_ lines: inout PanelPropertyLines, _ propID: SZPropID, _ name: String, _ text: String) {
        let value = sizeGrouped(propID, text)
        guard !value.isEmpty else { return }
        if propID == .errorType { lines.add("Open WARNING:", "Cannot open the file as expected archive type") }
        lines.add(name, value)
    }

    /// IsSizeProp -> ConvertSizeToString (PanelMenu.cpp:129-134): a size reads "101 156" in the
    /// Properties list, as in 7zFM 25.01 (ai/reports/wincompare.md).
    static func sizeGrouped(_ propID: SZPropID, _ text: String) -> String {
        guard Formatting.sizePropIDs.contains(propID), let value = UInt64(text) else { return text }
        return Formatting.size(value)
    }

    /// GetNameOfProperty: the lang string 1000 + propID, else the numeric id (01b §4.18).
    static func propertyName(_ propID: SZPropID) -> String {
        Lang.get(1000 + propID.rawValue, "\(propID.rawValue)")
    }

}

enum PropertiesDialog {

    /// IDS_PROPERTIES 6600 in the generic two-column list dialog.
    static func show(lines: PanelPropertyLines, parent: NSWindow?) {
        var options = ListViewDialogOptions()
        options.title = Lang.text(6600, "Properties")
        options.strings = lines.names
        options.values = lines.values
        options.numColumns = 2
        options.selectFirst = true
        _ = ListViewDialog.run(options, parent: parent)
    }
}
