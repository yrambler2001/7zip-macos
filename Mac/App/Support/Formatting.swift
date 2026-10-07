// Formatting.swift -- cell/status text exactly as 7zFM renders it (PanelListNotify.cpp).

import AppKit
import SevenZipKit

enum Formatting {

    /// PROPIDs that 7zFM renders with ConvertSizeToString (IsSizeProp, PanelListNotify.cpp:96).
    static let sizePropIDs: Set<SZPropID> = [
        .size, .packSize, .totalSize, .freeSpace, .clusterSize, .phySize, .headersSize, .tailSize,
        .embeddedStubSize, .unpackSize, .virtualSize, .altStreamsSize, .totalPhySize, .offset,
    ]

    /// Thousands separated by spaces: 1234567 -> "1 234 567" (ConvertSizeToString).
    static func size(_ value: UInt64) -> String {
        let digits = String(value)
        var out = ""
        for (i, ch) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(" ") }
            out.append(ch)
        }
        return out
    }

    /// Text for a property value already read from a folder (typed) — numbers grouped for size
    /// columns, booleans as "+" (VT_BOOL true) or "", everything else through the engine string.
    static func cellText(folder: SZFolder, index: Int, propID: SZPropID, level: SZTimestampLevel) -> String {
        if sizePropIDs.contains(propID) {
            if let n = folder.propertyOfItem(at: index, propID: propID) as? NSNumber {
                return size(n.uint64Value)
            }
            return ""
        }
        // A VT_BSTR cell shows LF and CR as spaces (PanelListNotify.cpp:470-479), so a comment or a
        // link target with a line break stays on its row.
        return oneLine(folder.displayStringOfItem(at: index, propID: propID, timestampLevel: level))
    }

    /// Text with LF and CR as spaces (the VT_BSTR branch of SetItemText).
    static func oneLine(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.map { $0 == "\n" || $0 == "\r" ? " " : $0 }))
    }

    /// Characters that would start a new line in an AppKit text field, or that draw nothing in the
    /// Windows list: the C0 controls, DEL, NEL and the Unicode line and paragraph separators.
    static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return v < 0x20 || v == 0x7F || v == 0x85 || v == 0x2028 || v == 0x2029
    }

    /// What the name column draws for a control character (fix111; see displayName).
    static let controlCharacterReplacement = ""

    /// Item name as the list shows it (PanelListNotify.cpp SetItemText): RLO replaced by "_",
    /// 4+ consecutive spaces collapsed to "... ", a trailing space made visible as U+2423.
    /// fix111: a control character (the CR of a Finder "Icon\r" file, an LF, ...) is passed to the
    /// list as it is on Windows, where the single-line label draws it as nothing; in an AppKit field
    /// it started a second line, which pushed the name up out of the row's centre. It is replaced
    /// by `controlCharacterReplacement` here; the name itself (rename, copy, sort) is unchanged.
    static func displayName(_ name: String) -> String {
        var s = name.replacingOccurrences(of: "\u{202E}", with: "_")
        if s.unicodeScalars.contains(where: isControl) {
            var out = String.UnicodeScalarView()
            for scalar in s.unicodeScalars {
                if isControl(scalar) { out.append(contentsOf: controlCharacterReplacement.unicodeScalars) } else { out.append(scalar) }
            }
            s = String(out)
        }
        while let r = s.range(of: "    ") {
            var end = r.upperBound
            while end < s.endIndex, s[end] == " " { end = s.index(after: end) }
            s.replaceSubrange(r.lowerBound..<end, with: "... ")
        }
        if s.hasSuffix(" ") { s.removeLast(); s.append("\u{2423}") }
        return s.isEmpty && !name.isEmpty ? "_" : s       // `if (dest == 0) text[dest++] = '_'`
    }

    /// Column alignment (GetColumnAlign): strings/times left, numbers/sizes right, booleans center.
    static func alignment(for info: SZPropertyInfo) -> NSTextAlignment {
        switch info.varType {
        case .UI1, .UI2, .UI4, .UI8, .I2, .I4, .I8: return .right
        case .bool: return .center
        default: return .left
        }
    }
}
