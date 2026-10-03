// Lang+WinMatch.swift -- dialog-scoped lang lookups (winmatch).
//
// With no language file 7zFM shows the text of its own .rc resources, which `SZLang` now prefers
// over Lang/en.ttt. A few lang IDs carry a different text in different dialogs -- 3803 is
// "&Show password" in IDD_PASSWORD but "Show Password" in IDD_EXTRACT / IDD_COMPRESS -- so a
// dialog asks for those with its own IDD (LangSetDlgItems keeps the control's .rc text).

import Foundation
import SevenZipKit

extension Lang {

    /// A control of dialog `dialog` (its IDD): the translation, else that dialog's .rc text, else
    /// the global lookup; mnemonics and accelerators stripped like `text(_:_:)`.
    static func dialogText(_ dialog: UInt32, _ id: UInt32, _ fallback: String) -> String {
        stripMnemonic(dropAccelerator(SZLang.shared.string(forID: id, inDialog: dialog, colon: false,
                                                           fallback: fallback)))
    }

    /// LangSetDlgItems_Colon (LangUtils.cpp:97-112): a translation gets ":" appended; the .rc text
    /// already ends in one ("Files:", "Compressed size:").
    static func dialogTextColon(_ dialog: UInt32, _ id: UInt32, _ fallback: String) -> String {
        stripMnemonic(dropAccelerator(SZLang.shared.string(forID: id, inDialog: dialog, colon: true,
                                                           fallback: fallback)))
    }
}
