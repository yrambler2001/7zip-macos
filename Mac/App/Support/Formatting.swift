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
        return folder.displayStringOfItem(at: index, propID: propID, timestampLevel: level)
    }

    /// Item name as the list shows it (PanelListNotify.cpp SetItemText): RLO replaced by "_",
    /// 4+ consecutive spaces collapsed to "... ", a trailing space made visible as U+2423.
    static func displayName(_ name: String) -> String {
        var s = name.replacingOccurrences(of: "\u{202E}", with: "_")
        while let r = s.range(of: "    ") {
            var end = r.upperBound
            while end < s.endIndex, s[end] == " " { end = s.index(after: end) }
            s.replaceSubrange(r.lowerBound..<end, with: "... ")
        }
        if s.hasSuffix(" ") { s.removeLast(); s.append("\u{2423}") }
        return s
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
