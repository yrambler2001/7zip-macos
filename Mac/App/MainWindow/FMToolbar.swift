// FMToolbar.swift -- the 7zFM toolbar as Windows draws it (App.cpp CreateToolbar / AddButton /
// ReloadToolbars, 01 §1.3), instead of an NSToolbar: macOS 26 puts every NSToolbarItem in a
// rounded glass capsule, and 7zFM's toolbar is a flat TBSTYLE_FLAT strip under the menu.
//
// What the real thing looks like (ai/reports/winmatch.md §3, measured on 7zFM 25.01 at
// 96 dpi, `winmatch-data/win/tb-*.txt`):
//   * one strip across the window, a 2 px etched line on top (no CCS_NODIVIDER), 4 px below;
//   * no separators: AddButton appends the archive buttons and the standard buttons back to back;
//   * every button the same size (TB_AUTOSIZE without BTNS_AUTOSIZE): the widest label or the
//     bitmap, plus 7 x 6 px of padding; the label (when "Show Buttons Text" is on) under the
//     bitmap in a 16 px line -- 42 x 46 with text and 24 x 24 bitmaps, 31 x 30 without text,
//     55 x 58 / 55 x 42 with the 48 x 36 bitmaps;
//   * flat buttons: nothing drawn at rest; hover is a (229,243,255) rectangle with a (204,232,255)
//     1 px border, pressed (204,232,255) with a (153,209,255) border, 2 px corners (Windows 11);
//   * the buttons are never disabled (TBSTATE_ENABLED and nothing ever changes it) and never take
//     the keyboard focus; a tooltip names each one (TBSTYLE_TOOLTIPS);
//   * TBSTYLE_WRAPABLE: a window too narrow for the row wraps the buttons onto more rows.
//
// In dark mode the same shapes use translucent white, since the Windows colours are light-only.

import Cocoa

/// One toolbar button: its bitmap, label and the selector it sends down the responder chain.
struct FMToolbarItemSpec {
    let identifier: String
    let label: String
    let image: NSImage?
    let action: Selector
}

/// The strip. `MainWindowController` owns one per window and feeds it with `configure`.
final class FMToolbarView: NSView {

    /// TB padding (comctl32 default with TBSTYLE_FLAT at 96 dpi): button = content + 7 x 6.
    static let paddingX: CGFloat = 7
    static let paddingY: CGFloat = 6
    /// The label line under the bitmap.
    static let textHeight: CGFloat = 16
    /// The etched divider on top and the margin under the buttons.
    static let topInset: CGFloat = 2
    static let bottomInset: CGFloat = 4
    /// The label font: the window's GUI font, Segoe UI 9 on Windows, which Helvetica Neue 11 matches
    /// in advance widths (listfeel.md §2). With it the text buttons are 42 x 46, as measured (recheck §2).
    static let labelFont = PanelMetrics.listFont
    /// How far the bitmap and the label move while a button is pressed (listfeel.md §7).
    static let pressedOffset = NSSize(width: 1, height: 0)

    private(set) var buttons: [FMToolbarButton] = []
    private(set) var showsText = true
    private(set) var buttonSize = NSSize.zero
    private var heightConstraint: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Toolbar")
        setAccessibilityIdentifier("7zFMToolbar")
        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        heightConstraint?.isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// ReloadToolbars: drop every button and add the new set.
    func configure(_ specs: [FMToolbarItemSpec], showText: Bool, large: Bool) {
        buttons.forEach { $0.removeFromSuperview() }
        showsText = showText
        let imageSize = large ? NSSize(width: 48, height: 36) : NSSize(width: 24, height: 24)
        var width = imageSize.width
        if showText {
            for spec in specs {
                let w = (spec.label as NSString).size(withAttributes: [.font: Self.labelFont]).width
                width = max(width, ceil(w))
            }
        }
        buttonSize = NSSize(width: width + Self.paddingX,
                            height: imageSize.height + Self.paddingY + (showText ? Self.textHeight : 0))
        buttons = specs.map { spec in
            let button = FMToolbarButton(spec: spec, imageSize: imageSize, showText: showText)
            addSubview(button)
            return button
        }
        isHidden = specs.isEmpty                     // MoveSubWindows: no toolbar, no room taken
        needsLayout = true
        updateHeight()
        needsDisplay = true
    }

    /// The button for an item identifier ("sz.add" ...), for tests and accessibility.
    func button(_ identifier: String) -> FMToolbarButton? {
        buttons.first { $0.identifier?.rawValue == identifier }
    }

    /// Buttons per row at the current width (TBSTYLE_WRAPABLE), at least one.
    private var perRow: Int {
        guard buttonSize.width > 0, bounds.width > 0 else { return max(buttons.count, 1) }
        return max(1, Int(floor(bounds.width / buttonSize.width)))
    }

    private var rows: Int {
        buttons.isEmpty ? 0 : (buttons.count + perRow - 1) / perRow
    }

    private func updateHeight() {
        let h = buttons.isEmpty ? 0 : Self.topInset + CGFloat(rows) * buttonSize.height + Self.bottomInset
        if heightConstraint?.constant != h { heightConstraint?.constant = h }
    }

    override func layout() {
        super.layout()
        let n = perRow
        for (i, button) in buttons.enumerated() {
            button.frame = NSRect(x: CGFloat(i % n) * buttonSize.width,
                                  y: Self.topInset + CGFloat(i / n) * buttonSize.height,
                                  width: buttonSize.width, height: buttonSize.height)
        }
        updateHeight()
    }

    override func draw(_ dirtyRect: NSRect) {
        WinChrome.face.setFill()                      // COLOR_BTNFACE (240,240,240), recheck §2
        bounds.fill()
        // The etched divider at the top of a toolbar without CCS_NODIVIDER: shadow, then highlight.
        FMToolbarColors.dividerShadow.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        FMToolbarColors.dividerHighlight.setFill()
        NSRect(x: 0, y: 1, width: bounds.width, height: 1).fill()
    }
}

/// A flat toolbar button: bitmap with the label under it, a light rectangle on hover and a
/// darker one while pressed, nothing at rest. An `NSButton` for its target / action and its
/// accessibility (role button, title = the label), drawn entirely here so AppKit adds no bezel.
final class FMToolbarButton: NSButton {

    private let bitmap: NSImage?
    private let imageSize: NSSize
    private let showsText: Bool
    var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }
    private var trackingArea: NSTrackingArea?

    init(spec: FMToolbarItemSpec, imageSize: NSSize, showText: Bool) {
        bitmap = spec.image
        self.imageSize = imageSize
        showsText = showText
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier(spec.identifier)
        title = spec.label                    // the accessibility title, also with text off
        toolTip = spec.label                  // TBSTYLE_TOOLTIPS: TTN_GETDISPINFO -> SetButtonText
        isBordered = false
        setButtonType(.momentaryChange)
        refusesFirstResponder = true          // toolbar buttons never take the keyboard focus
        target = nil                          // the responder chain, as the menu items do
        action = spec.action
        setAccessibilityLabel(spec.label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { frame.size }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isHovered = false
    }

    override func draw(_ dirtyRect: NSRect) {
        let pressed = isHighlighted
        if pressed || isHovered {
            let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            (pressed ? FMToolbarColors.pressedFill : FMToolbarColors.hoverFill).setFill()
            path.fill()
            (pressed ? FMToolbarColors.pressedBorder : FMToolbarColors.hoverBorder).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        // The bitmap, 3 px from the top, centred; nearest-neighbour so the 96 dpi art stays crisp
        // on a Retina screen (each bitmap pixel becomes a 2 x 2 block, as at 200 % on Windows).
        // While pressed the bitmap and the label move 1 px to the right (comctl32 v6's pressed
        // offset on Windows 11, measured with a real mouse-down on 7zFM 26.03's Info button:
        // every pixel column moves by +1 and no row moves, listfeel.md §7).
        let shift = pressed ? FMToolbarView.pressedOffset : .zero
        let imageRect = NSRect(x: floor((bounds.width - imageSize.width) / 2) + shift.width,
                               y: FMToolbarView.paddingY / 2 + shift.height,
                               width: imageSize.width, height: imageSize.height)
        if let bitmap {
            NSGraphicsContext.current?.imageInterpolation = .none
            bitmap.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1,
                        respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none.rawValue])
        }
        guard showsText else { return }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byClipping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: FMToolbarView.labelFont, .foregroundColor: WinChrome.text, .paragraphStyle: style,
        ]
        // The label's baseline 12 px under the bitmap, as Segoe UI 9 sits in its 16 px line (ink of
        // "Add" rows 31..39 of a 46 px button; recheck §2).
        let textRect = NSRect(x: shift.width, y: imageRect.maxY + 3, width: bounds.width, height: FMToolbarView.textHeight)
        (title as NSString).draw(in: textRect, withAttributes: attributes)
    }
}

/// The comctl32 v6 (Windows 10 / 11 "Explorer" toolbar theme) colours, with dark equivalents.
enum FMToolbarColors {
    private static func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
    }

    static let hoverFill = dynamic(rgb(229, 243, 255), NSColor(white: 1, alpha: 0.10))
    static let hoverBorder = dynamic(rgb(204, 232, 255), NSColor(white: 1, alpha: 0.18))
    static let pressedFill = dynamic(rgb(204, 232, 255), NSColor(white: 1, alpha: 0.18))
    static let pressedBorder = dynamic(rgb(153, 209, 255), NSColor(white: 1, alpha: 0.30))
    static let dividerShadow = dynamic(rgb(160, 160, 160), NSColor(white: 0, alpha: 0.5))
    static let dividerHighlight = dynamic(rgb(255, 255, 255), NSColor(white: 1, alpha: 0.08))
}
