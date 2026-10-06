// Formatting+WinCompare.swift -- the second size formatter of 7-Zip, added by the `wincompare`
// scope (00-orchestration.md: extend Formatting.swift through a new file).

import Foundation

extension Formatting {

    /// `AddSizeValue` of OverwriteDialog.cpp:68-88, which the Overwrite dialog and the checksum
    /// results (HashGUI.cpp AddSizeValuePair) use: IDS_FILE_SIZE 3504 "{0} bytes" around the
    /// *plain* number, then " : N KiB" (or MiB from 10 MiB, GiB from 10 GiB) once it reaches
    /// 1 KiB. 7zFM 25.01 shows "1234 bytes : 1 KiB" for the 1 234-byte fixture
    /// (ai/reports/wincompare.md). Not to be confused with App.cpp's file-local
    /// AddSizeValue (grouped digits, no unit), which the Copy dialog uses.
    static func sizeValue(_ value: UInt64) -> String {
        var s = Lang.format(Lang.get(3504, "{0} bytes"), String(value))
        if value >= 1 << 10 {
            let scaled: (UInt64, String)
            if value >= UInt64(10) << 30 { scaled = (value >> 30, "G") }
            else if value >= UInt64(10) << 20 { scaled = (value >> 20, "M") }
            else { scaled = (value >> 10, "K") }
            s += " : \(scaled.0) \(scaled.1)iB"
        }
        return s
    }
}
