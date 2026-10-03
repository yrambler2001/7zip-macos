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

    mutating func add(_ name: String, _ value: String) {
        names.append(name)
        values.append(value)
    }

    mutating func addSeparator() {
        add("", "")
    }
}

enum PanelProperties {

    /// kSpecProps (PanelMenu.cpp:172): the archive-level block header properties, in order.
    static let specProps: [SZPropID] = [.path, .type, .errorType, .error, .errorFlags,
                                        .warning, .warningFlags, .offset, .phySize, .tailSize]

    /// Folder-level properties 7zFM shows after the item block (GetFolderProperty).
    static let folderProps: [SZPropID] = [.type, .path, .readOnly, .isHash, .totalSize, .freeSpace,
                                          .clusterSize, .volumeName, .fileSystem, .comment]

    /// Called on the panel queue.
    static func build(folder: SZFolder, itemIndices: [Int], snapshot: PanelSnapshot,
                      level: SZTimestampLevel) -> PanelPropertyLines {
        var lines = PanelPropertyLines()
        if let first = itemIndices.first {
            for info in folder.properties where info.propID != .isDir {
                // Raw properties (IArchiveGetRawProps) follow the folder's own, rendered the way
                // PanelMenu.cpp:212-246 does: hex up to 256 bytes ("data:<n>" beyond), upper case
                // for a CRC / checksum of at most 8 bytes (01 §3.11).
                let text = info.isRawProperty
                    ? folder.rawPropertyString(at: first, propID: info.propID, forPropertiesDialog: true)
                    : folder.displayStringOfItem(at: first, propID: info.propID, timestampLevel: level)
                guard !text.isEmpty else { continue }
                lines.add(info.localizedName, text)
            }
        }
        if itemIndices.count > 1 {
            lines.addSeparator()
            var size: UInt64 = 0, packed: UInt64 = 0, dirs = 0, files = 0
            for index in itemIndices {
                size &+= (folder.propertyOfItem(at: index, propID: .size) as? NSNumber)?.uint64Value ?? 0
                packed &+= (folder.propertyOfItem(at: index, propID: .packSize) as? NSNumber)?.uint64Value ?? 0
                if folder.isDirectory(at: index) { dirs += 1 } else { files += 1 }
            }
            lines.add(Lang.text(1007, "Size"), Formatting.size(size))
            lines.add(Lang.text(1008, "Packed Size"), Formatting.size(packed))
            lines.add(Lang.text(1031, "Folders"), "\(dirs)")
            lines.add(Lang.text(1032, "Files"), "\(files)")
        }
        lines.addSeparator()
        for propID in folderProps {
            guard let value = folder.folderProperty(forID: propID) else { continue }
            let text = displayString(value)
            guard !text.isEmpty else { continue }
            lines.add(propertyName(propID), text)
        }
        if let arcProps = folder.arcProps, arcProps.levelCount > 0 {
            // PanelMenu.cpp:345-410: innermost level first; each level's kSpecProps and handler
            // properties, then -- between two levels only -- the outer handler's properties of
            // the item the inner level was opened from (GetArcProp2, which reads Arcs[level - 1]
            // and so does not exist for level 0: asking for it read out of bounds and crashed).
            let levels = arcProps.levelCount
            for level2 in 0..<levels {
                let level0 = levels - 1 - level2
                lines.addSeparator()
                lines.add("----" + Lang.text(1003, "Path") + " \(level0 + 1)----", "")
                for propID in specProps {
                    let text = arcProps.displayString(atLevel: level0, propID: propID)
                    guard !text.isEmpty else { continue }
                    lines.add(propertyName(propID), text)
                }
                for info in arcProps.properties(atLevel: level0) {
                    let text = arcProps.displayString(atLevel: level0, propID: info.propID)
                    guard !text.isEmpty else { continue }
                    lines.add(info.localizedName, text)
                }
                if level2 < levels - 1 {
                    lines.addSeparator()                       // kSeparatorSmall
                    for info in arcProps.properties2(atLevel: level0) {
                        guard let value = arcProps.property2(atLevel: level0, propID: info.propID) else { continue }
                        let text = displayString(value)
                        guard !text.isEmpty else { continue }
                        lines.add(info.localizedName, text)
                    }
                }
            }
            // The level that failed to open (NonOpen_ErrorInfo), after a double separator.
            var needSeparator = true
            for propID in specProps {
                let text = arcProps.displayString(atLevel: levels, propID: propID)
                guard !text.isEmpty else { continue }
                if needSeparator { lines.addSeparator(); lines.addSeparator(); needSeparator = false }
                lines.add(propertyName(propID), text)
            }
        }
        if !snapshot.archivePath.isEmpty {
            lines.addSeparator()
            lines.add(Lang.text(1096, "ArcFileName"), snapshot.archivePath)
        }
        return lines
    }

    /// GetNameOfProperty: the lang string 1000 + propID, else the numeric id (01b §4.18).
    static func propertyName(_ propID: SZPropID) -> String {
        Lang.get(1000 + propID.rawValue, "\(propID.rawValue)")
    }

    private static func displayString(_ value: Any) -> String {
        switch value {
        case let text as String: return text
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "+" : "" }
            return Formatting.size(number.uint64Value)
        case let date as Date:
            return PanelPropertiesDateFormatter.string(from: date)
        default: return "\(value)"
        }
    }
}

enum PanelPropertiesDateFormatter {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func string(from date: Date) -> String { formatter.string(from: date) }
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
