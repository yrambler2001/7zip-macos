// LayoutAudit.swift -- geometry checks the layout sweep (`polish` scope, Mac/docs/reports/polish.md)
// runs on every window and dialog of the app, so "the window opened" is never mistaken for "the
// window looks right".
//
// Three classes of defect are measured from one accessibility snapshot:
//
//   CLIPPED  an element's frame leaves its window's frame -- the Copy dialog's cut-off buttons
//            (Mac/docs/requests.md) are exactly this.
//   OVERLAP  two sibling controls cover each other, which no dialog of 7zFM does.
//   OVERSIZE a window is bigger than the screen it is on, so part of it cannot be reached. One
//            label that resists compression is enough to do this to a whole window.
//   TIGHT    a label or button title needs more width than its frame gives it, so AppKit
//            truncates it with an ellipsis. This one is a heuristic (the text is measured with
//            the system font, which is not always the control's font), so it is reported as a
//            warning to look at on the screenshot, never as a hard failure. A label tall enough
//            to hold two lines is skipped -- it wraps, it does not truncate -- and so is anything
//            inside a toolbar, whose items report the icon's frame rather than the icon's plus
//            the label's.
//
// Frames come from `XCUIElementSnapshot`, i.e. one query for the whole tree: resolving elements
// one at a time is slow and has crashed the runner (harness api section 7).

import AppKit
import XCTest

public enum LayoutAudit {

    /// Controls that draw their own text and must not overlap a sibling.
    private static let controlTypes: Set<XCUIElement.ElementType> = [
        .button, .checkBox, .radioButton, .staticText, .textField, .secureTextField,
        .comboBox, .popUpButton, .slider, .stepper, .progressIndicator, .segmentedControl,
        .scrollView, .table, .outline, .tabGroup, .collectionView,
    ]

    /// Types whose title is drawn inside a frame that also holds chrome (border, box, arrow).
    private static func chromeWidth(_ type: XCUIElement.ElementType) -> CGFloat {
        switch type {
        case .button: return 26
        case .checkBox, .radioButton: return 22
        case .popUpButton, .comboBox: return 34
        default: return 2
        }
    }

    // MARK: - entry points

    /// Hard defects only: what a test should fail on.
    public static func defects(_ window: XCUIElement, name: String) -> [String] {
        report(window, name: name).filter(isHardDefect)
    }

    /// A finding a test must fail on, as opposed to a TIGHT warning to look at on a screenshot.
    public static func isHardDefect(_ finding: String) -> Bool {
        finding.hasPrefix("CLIPPED") || finding.hasPrefix("OVERLAP")
            || finding.hasPrefix("OVERSIZE") || finding.hasPrefix("ERROR")
    }

    /// Every finding, warnings included, one per line.
    public static func report(_ window: XCUIElement, name: String) -> [String] {
        guard let snapshot = try? window.snapshot() else { return ["ERROR \(name): no snapshot"] }
        let bounds = snapshot.frame
        guard bounds.width > 1, bounds.height > 1 else { return ["ERROR \(name): empty window frame"] }
        var findings: [String] = []
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame.size
            if bounds.width > visible.width + 1 || bounds.height > visible.height + 1 {
                findings.append(String(format: "OVERSIZE %@: %@ does not fit the screen (%.0fx%.0f)",
                                       name, rect(bounds), visible.width, visible.height))
            }
        }
        walk(snapshot, path: name, bounds: bounds, findings: &findings)
        return findings
    }

    /// `name  120x230 at (10, 20)` -- for the report table.
    public static func size(_ window: XCUIElement) -> String {
        let f = window.frame
        return String(format: "%.0fx%.0f", f.width, f.height)
    }

    // MARK: - the walk

    /// A scroll view is a clipping boundary: its content is *meant* to run past the edge and be
    /// scrolled to (a panel's list is wider than the panel whenever the columns add up to more).
    /// Menus are torn off the window entirely.
    private static func isBoundary(_ type: XCUIElement.ElementType) -> Bool {
        type == .scrollView || type == .menu || type == .menuItem || type == .menuBar
    }

    private static func walk(_ node: XCUIElementSnapshot, path: String, bounds: CGRect,
                             findings: inout [String], insideToolbar: Bool = false) {
        var siblings: [(XCUIElementSnapshot, String)] = []
        for child in node.children {
            let childInToolbar = insideToolbar || child.elementType == .toolbar
            let label = describe(child)
            let childPath = path + " > " + label
            let frame = child.frame
            if frame.width > 1, frame.height > 1 {
                // A window's own title bar sits above its content, so the window frame is the
                // only reference; 1 pt of slack absorbs backing-store rounding.
                if frame.minX < bounds.minX - 1 || frame.maxX > bounds.maxX + 1
                    || frame.minY < bounds.minY - 1 || frame.maxY > bounds.maxY + 1 {
                    findings.append("CLIPPED \(childPath): \(rect(frame)) leaves \(rect(bounds))")
                }
                if controlTypes.contains(child.elementType) {
                    siblings.append((child, childPath))
                }
                if !childInToolbar, let tight = tightText(child, path: childPath) {
                    findings.append(tight)
                }
            }
            if !isBoundary(child.elementType) {
                walk(child, path: childPath, bounds: bounds, findings: &findings,
                     insideToolbar: childInToolbar)
            }
        }
        for i in siblings.indices {
            for j in siblings.indices where j > i {
                let a = siblings[i], b = siblings[j]
                let overlap = a.0.frame.intersection(b.0.frame)
                guard !overlap.isNull, overlap.width > 2, overlap.height > 2 else { continue }
                // A control fully inside another one is composition, not an overlap.
                if a.0.frame.contains(b.0.frame) || b.0.frame.contains(a.0.frame) { continue }
                findings.append("OVERLAP \(a.1) \(rect(a.0.frame)) and \(b.1) \(rect(b.0.frame))")
            }
        }
    }

    /// Does the control's own text fit in its frame?
    private static func tightText(_ node: XCUIElementSnapshot, path: String) -> String? {
        let type = node.elementType
        guard [XCUIElement.ElementType.staticText, .button, .checkBox, .radioButton,
               .popUpButton].contains(type) else { return nil }
        let text = node.elementType == .staticText
            ? ((node.value as? String) ?? node.label)
            : (node.title.isEmpty ? node.label : node.title)
        guard !text.isEmpty, !text.contains("\n") else { return nil }
        // Tall enough for a second line: it is a wrapping label, so it does not truncate.
        guard node.frame.height < 24 else { return nil }
        let needed = (text as NSString)
            .size(withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]).width
        let available = node.frame.width - chromeWidth(type)
        guard needed > available + 2 else { return nil }
        return String(format: "TIGHT %@: %@ needs %.0f pt, has %.0f pt", path,
                      quoted(text), needed, available)
    }

    // MARK: - formatting

    private static func describe(_ node: XCUIElementSnapshot) -> String {
        var parts = [typeName(node.elementType)]
        if !node.identifier.isEmpty { parts.append("#" + node.identifier) }
        let text = node.title.isEmpty ? node.label : node.title
        if !text.isEmpty { parts.append(quoted(text)) }
        return parts.joined(separator: " ")
    }

    private static func quoted(_ s: String) -> String {
        let one = s.replacingOccurrences(of: "\n", with: "\\n")
        return "\"" + (one.count > 48 ? String(one.prefix(45)) + "..." : one) + "\""
    }

    private static func rect(_ r: CGRect) -> String {
        String(format: "[%.0f,%.0f %.0fx%.0f]", r.minX, r.minY, r.width, r.height)
    }

    private static func typeName(_ type: XCUIElement.ElementType) -> String {
        switch type {
        case .window: return "window"
        case .sheet: return "sheet"
        case .dialog: return "dialog"
        case .group: return "group"
        case .button: return "button"
        case .checkBox: return "checkBox"
        case .radioButton: return "radio"
        case .staticText: return "text"
        case .textField: return "field"
        case .secureTextField: return "secureField"
        case .comboBox: return "combo"
        case .popUpButton: return "popUp"
        case .scrollView: return "scroll"
        case .table: return "table"
        case .outline: return "outline"
        case .tabGroup: return "tabs"
        case .tab: return "tab"
        case .splitGroup: return "splitGroup"
        case .splitter: return "splitter"
        case .progressIndicator: return "progress"
        case .image: return "image"
        case .toolbar: return "toolbar"
        case .textView: return "textView"
        case .radioGroup: return "radioGroup"
        case .collectionView: return "collection"
        case .stepper: return "stepper"
        case .slider: return "slider"
        case .segmentedControl: return "segmented"
        default: return "type\(type.rawValue)"
        }
    }
}
