// WindowAudit.swift -- the geometry audit of `LayoutAudit` (Mac/Tests/UITests/LayoutAudit.swift),
// moved off the GUI path: it walks the real `NSView` tree of a window that lives in *this* process
// instead of an `XCUIElementSnapshot` of another one.
//
// Why the move. The dialog sweep (`polish` scope, ai/reports/polish.md) found the clipped
// button rows of nineteen dialogs by opening each of them through the menu bar of a freshly
// launched app and looking at a screenshot. The defect itself, though, is a *number*: the button
// row's frame ran past the bottom edge of the window's content rectangle because
// `DialogKit.install` pinned the content with `+margin` instead of `-margin`. A frame comparison
// finds it, and a frame comparison needs neither a launch nor a screenshot.
//
// What this checks, and what it adds over the accessibility version:
//
//   CLIPPED   a view's frame leaves the window's content rectangle. This is the nineteen-dialog
//             defect. Hard failure.
//   FIT       the window's content size is smaller than what its content view needs
//             (`fittingSize`), i.e. Auto Layout was overruled by a fixed size. The cause of
//             CLIPPED, and it is caught even when the clipped control happens to be inside the
//             rectangle by luck. Hard failure.
//   OVERSIZE  the window is bigger than the screen it is on, so part of it cannot be reached.
//             Hard failure.
//   OVERLAP   two sibling controls cover each other, which no 7zFM dialog does. Hard failure.
//   TIGHT     a control's own text needs more width than its frame gives it, so AppKit truncates
//             it. In-process this is measured with the control's **real** font and cell metrics
//             (`NSCell.cellSize`), not with a guess at the system font, so it is far sharper than
//             the XCUITest heuristic -- but a label that is *meant* to truncate (the Copy dialog's
//             info lines set `.byTruncatingTail` on purpose) is legitimately tight, so it stays a
//             warning to look at, never a failure.
//
// An `NSScrollView` is a clipping boundary: its document view is meant to be larger and scrolled.
// Hidden views and zero-sized views are skipped, as is anything inside an `NSTabView`'s unselected
// pages (those views are not in the window at all, but a tab view keeps them around).

import AppKit

enum WindowAudit {

    /// Slack for backing-store rounding, in points.
    static let slack: CGFloat = 1

    // MARK: - entry points

    /// Every finding, warnings included, one per line.
    static func report(_ window: NSWindow, name: String) -> [String] {
        guard let content = window.contentView else { return ["ERROR \(name): the window has no content view"] }
        content.layoutSubtreeIfNeeded()
        var findings: [String] = []

        let bounds = content.bounds
        guard bounds.width > 1, bounds.height > 1 else {
            return ["ERROR \(name): content rectangle is \(rect(bounds))"]
        }

        // FIT: Auto Layout's answer for this content must fit in the size the window gave it.
        //
        // Only a hard defect when every label in the window is single-line and nothing scrolls. A
        // *wrapping* label's `fittingSize` is its width on one line -- it has no meaningful ideal
        // width -- and a scroll view's content is meant to be larger than its frame, so in those
        // windows the number says nothing: measured, the Options window reports "needs 941x452" in
        // English while looking exactly as `polish` signed it off. Those become warnings.
        let fitting = content.fittingSize
        if fitting.width > bounds.width + slack || fitting.height > bounds.height + slack {
            let kind = hasElasticContent(content) ? "FIT-SOFT" : "FIT"
            findings.append(String(format: "%@ %@: content needs %.0fx%.0f, the window gives %.0fx%.0f",
                                   kind, name, fitting.width, fitting.height, bounds.width, bounds.height))
        }

        // OVERSIZE: a window that does not fit its screen cannot be fully used.
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame.size
            let frame = window.frame.size
            if frame.width > visible.width + slack || frame.height > visible.height + slack {
                findings.append(String(format: "OVERSIZE %@: %.0fx%.0f does not fit the screen (%.0fx%.0f)",
                                       name, frame.width, frame.height, visible.width, visible.height))
            }
        }

        walk(content, path: name, content: content, findings: &findings)
        return findings
    }

    /// Hard defects only: what a test must fail on.
    static func defects(_ window: NSWindow, name: String) -> [String] {
        report(window, name: name).filter(isHardDefect)
    }

    static func isHardDefect(_ finding: String) -> Bool {
        finding.hasPrefix("CLIPPED") || finding.hasPrefix("OVERLAP")
            || finding.hasPrefix("OVERSIZE") || finding.hasPrefix("FIT ")
            || finding.hasPrefix("ERROR")
    }

    /// True when the window holds something whose fitting size is not its real minimum: a wrapping
    /// or truncating label, a text view, or anything that scrolls.
    private static func hasElasticContent(_ view: NSView) -> Bool {
        if view is NSScrollView || view is NSTextView { return true }
        if let field = view as? NSTextField {
            if field.maximumNumberOfLines != 1 { return true }
            if field.cell?.wraps == true { return true }
            if field.lineBreakMode != .byClipping, field.cell?.truncatesLastVisibleLine == true { return true }
        }
        return view.subviews.contains(where: hasElasticContent)
    }

    /// `480x200` -- for the report table.
    static func size(_ window: NSWindow) -> String {
        let f = window.frame
        return String(format: "%.0fx%.0f", f.width, f.height)
    }

    // MARK: - the walk

    private static func walk(_ node: NSView, path: String, content: NSView, findings: inout [String]) {
        var siblings: [(NSView, CGRect, String)] = []
        for child in node.subviews {
            guard !child.isHidden, child.alphaValue > 0.01 else { continue }
            let label = describe(child)
            let childPath = path + " > " + label
            let frame = content.convert(child.bounds, from: child)
            if frame.width > 1, frame.height > 1 {
                if frame.minX < content.bounds.minX - slack || frame.maxX > content.bounds.maxX + slack
                    || frame.minY < content.bounds.minY - slack || frame.maxY > content.bounds.maxY + slack {
                    findings.append("CLIPPED \(childPath): \(rect(frame)) leaves \(rect(content.bounds))")
                }
                // Overlap is judged on alignment rects: a label's frame reaches 2 pt past its text
                // on each side, so two statics that touch on Windows (dlgfeel lays them out on the
                // .rc rects) share those points without covering each other.
                if isControl(child) {
                    var aligned = frame
                    if let field = child as? NSTextField, !field.isEditable, !field.isBezeled {
                        aligned = frame.insetBy(dx: 2, dy: 0)
                    }
                    siblings.append((child, aligned, childPath))
                }
                if let tight = tightText(child, path: childPath) { findings.append(tight) }
            }
            if !isBoundary(child) {
                walk(child, path: childPath, content: content, findings: &findings)
            }
        }
        for i in siblings.indices {
            for j in siblings.indices where j > i {
                let a = siblings[i], b = siblings[j]
                let overlap = a.1.intersection(b.1)
                guard !overlap.isNull, overlap.width > 2, overlap.height > 2 else { continue }
                // A control fully inside another one is composition, not an overlap.
                if a.1.contains(b.1) || b.1.contains(a.1) { continue }
                findings.append("OVERLAP \(a.2) \(rect(a.1)) and \(b.2) \(rect(b.1))")
            }
        }
    }

    /// A scroll view's content is meant to run past the edge and be scrolled to; a tab view's
    /// unselected pages are laid out off-screen; a menu is not part of the window.
    private static func isBoundary(_ view: NSView) -> Bool {
        // A text field's subviews are its field editor's, laid out by AppKit while it edits.
        view is NSScrollView || view is NSTabView || view is NSClipView || view is NSTextField
    }

    /// Views that draw their own content and must not cover a sibling.
    ///
    /// A **separator** box is excluded: it is a line, its frame carries padding around that line,
    /// and two adjacent separators (the path bar's and the list header's, one point apart in the
    /// panel) legitimately share those points. Everything that shows text or takes a click is in.
    private static func isControl(_ view: NSView) -> Bool {
        if let box = view as? NSBox { return box.boxType != .separator }
        return view is NSControl || view is NSScrollView || view is NSProgressIndicator
    }

    // MARK: - truncation

    /// Does the control's own text fit its frame? Measured with the control's real cell, so the
    /// answer is the same one AppKit uses when it decides to draw an ellipsis.
    private static func tightText(_ view: NSView, path: String) -> String? {
        // A view that is deliberately allowed to shrink below its text (an info line pinned to the
        // window width, a status bar) sets a truncating line break mode; it is doing its job.
        if let field = view as? NSTextField {
            if field.maximumNumberOfLines != 1 && field.lineBreakMode == .byWordWrapping { return nil }
            if field.cell?.truncatesLastVisibleLine == true { return nil }
        }
        guard let control = view as? NSControl, let cell = control.cell else { return nil }
        let text = cell.title
        guard !text.isEmpty, !text.contains("\n") else { return nil }
        // Multi-line controls wrap rather than truncate.
        guard control.bounds.height < 26 else { return nil }
        let needed = cell.cellSize.width
        let available = control.bounds.width
        guard needed > available + 2 else { return nil }
        return String(format: "TIGHT %@: %@ needs %.0f pt, has %.0f pt", path,
                      quoted(text), needed, available)
    }

    // MARK: - formatting

    private static func describe(_ view: NSView) -> String {
        var parts = [typeName(view)]
        let identifier = view.identifier?.rawValue ?? ""
        if !identifier.isEmpty { parts.append("#" + identifier) }
        if let control = view as? NSControl, let title = control.cell?.title, !title.isEmpty {
            parts.append(quoted(title))
        }
        return parts.joined(separator: " ")
    }

    private static func typeName(_ view: NSView) -> String {
        // Order matters: NSPopUpButton is an NSButton, NSSecureTextField is an NSTextField.
        if view is NSPopUpButton { return "popUp" }
        // A checkbox and a radio button are unbordered NSButtons that carry a state; the exact
        // button type is not readable from AppKit, and this string is only report text.
        if let button = view as? NSButton {
            return button.isBordered ? "button" : "stateButton"
        }
        if view is NSSecureTextField { return "secureField" }
        if view is NSComboBox { return "combo" }
        if let field = view as? NSTextField { return field.isEditable ? "field" : "text" }
        if view is NSOutlineView { return "outline" }
        if view is NSTableView { return "table" }
        if view is NSScrollView { return "scroll" }
        if view is NSStackView { return "stack" }
        if view is NSGridView { return "grid" }
        if view is NSTabView { return "tabs" }
        if view is NSSplitView { return "splitView" }
        if view is NSProgressIndicator { return "progress" }
        if view is NSImageView { return "image" }
        if view is NSBox { return "box" }
        if view is NSTextView { return "textView" }
        return String(describing: type(of: view))
    }

    private static func quoted(_ s: String) -> String {
        let one = s.replacingOccurrences(of: "\n", with: "\\n")
        return "\"" + (one.count > 48 ? String(one.prefix(45)) + "..." : one) + "\""
    }

    private static func rect(_ r: CGRect) -> String {
        String(format: "[%.0f,%.0f %.0fx%.0f]", r.minX, r.minY, r.width, r.height)
    }
}
