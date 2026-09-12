// Lang.swift -- Swift facade over SZLang. String IDs are the 7zFM resource IDs
// (01-fm-feature-inventory.md section 7.2). Every UI string goes through here so the
// official Lang/*.txt files work unchanged.

import Foundation
import SevenZipKit

enum Lang {

    /// Lang text for `id` (current language, then built-in English), else `fallback`.
    static func get(_ id: UInt32, _ fallback: String) -> String {
        SZLang.shared.string(forID: id, fallback: fallback)
    }

    /// Only from the loaded translation (LangString_OnlyFromLangFile); nil when untranslated.
    static func translated(_ id: UInt32) -> String? {
        SZLang.shared.translatedString(forID: id)
    }

    /// Menu title as 7zFM builds it (MyChangeMenu): the translation if present, else the
    /// resource text; the "\t<accelerator>" part is dropped (macOS shows key equivalents itself)
    /// and "&" mnemonics are removed.
    static func menuTitle(_ id: UInt32, _ resourceText: String) -> String {
        let text = translated(id) ?? resourceText
        return stripMnemonic(dropAccelerator(text))
    }

    /// Plain UI text for dialogs/labels: strip mnemonics and accelerators.
    static func text(_ id: UInt32, _ fallback: String) -> String {
        stripMnemonic(dropAccelerator(get(id, fallback)))
    }

    static func dropAccelerator(_ s: String) -> String {
        if let tab = s.firstIndex(of: "\t") { return String(s[..<tab]) }
        return s
    }

    /// "&&" -> "&", "&x" -> "x".
    static func stripMnemonic(_ s: String) -> String {
        var out = ""
        var iterator = s.makeIterator()
        while let c = iterator.next() {
            if c == "&" {
                if let next = iterator.next() { out.append(next) }
            } else {
                out.append(c)
            }
        }
        return out
    }

    /// MyFormatNew: replaces "{0}".
    static func format(_ template: String, _ argument: String) -> String {
        template.replacingOccurrences(of: "{0}", with: argument)
    }

    /// ReloadLang: the "Lang" setting ("" = system language, "-" = English, else a code).
    static func loadFromSettings() {
        let code = SZSettings.string(forKey: SZSettingsKeyLang) ?? ""
        do {
            try SZLang.shared.loadLanguage(code: code)
        } catch {
            NSLog("7-Zip: language '%@' not loaded: %@", code, error.localizedDescription)
        }
    }
}
