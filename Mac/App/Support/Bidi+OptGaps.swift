// Bidi+OptGaps.swift -- right-to-left text in the composite one-line strings (the panel status
// line, the Copy / Move dialog's info block). requests.md, `packaging` -> `panel`; parity.md B 23.
//
// The app is not mirrored (it declares no RTL localization, parity.md C), so its labels are laid
// out left to right like the Windows controls, whose reading order is LTR unless WS_EX_RTLREADING
// is set. AppKit, though, gives a label the *natural* base direction -- the first strong character
// decides -- so an Arabic status line was laid out right to left as a whole and its segments came
// out in reverse ("15:05 20-09-2026 000 12 000 12 عنصر 10 / 1 تم تحديد"). Worse, digits that follow
// Arabic letters take the Arabic direction (UAX #9 rule W2), so even a left-to-right base pulled
// the next segment's numbers into the Arabic run. Each segment is therefore wrapped in a
// first-strong isolate (FSI ... PDI, UAX #9 section 2.4): inside, it reads in its own direction;
// outside, it is one neutral block placed in the label's left-to-right order.

import AppKit

enum Bidi {

    static let firstStrongIsolate = "\u{2068}"   // FSI
    static let popDirectionalIsolate = "\u{2069}" // PDI

    /// `text` as one isolated segment (unchanged when empty).
    static func isolate(_ text: String) -> String {
        text.isEmpty ? text : firstStrongIsolate + text + popDirectionalIsolate
    }

    /// Segments joined left to right, each isolated.
    static func join(_ parts: [String], separator: String) -> String {
        parts.map(isolate).joined(separator: separator)
    }

    /// "<label>: <value>" with label and value isolated, so the colon stays between them in a
    /// right-to-left translation ("الملفات: 1", not "1 :الملفات").
    static func labelValue(_ label: String, _ value: String) -> String {
        isolate(label) + ": " + isolate(value)
    }

    /// The visible text: the isolate controls removed (for tests and plain-text copies).
    static func stripped(_ text: String) -> String {
        text.replacingOccurrences(of: firstStrongIsolate, with: "")
            .replacingOccurrences(of: popDirectionalIsolate, with: "")
    }

    /// A label that keeps the app's left-to-right layout whatever its first letter is.
    static func makeLeftToRight(_ field: NSTextField) {
        field.baseWritingDirection = .leftToRight
    }
}
