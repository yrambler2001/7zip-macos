// OptionsTabControl.swift -- the property sheet's tab control (SysTabControl32 12320) as Windows 11
// draws it for 7zFM 26.03's Options sheet (dlgfeel, reports/dlgfeel.md "Options").
//
// Measured on the PC (dlgfeel-data/win/screen-options-*.png, options-tabs.txt):
//   * the control sits at 6,7 482x507 in the 494x550 client area; the page at 10,29 474x481;
//   * TCM_GETITEMRECT gives the tabs at y 2..20 of the control (client y 9..27), starting at x 2,
//     each one as wide as its caption plus the padding (System 46, 7-Zip 42, Folders 46 ...);
//   * an unselected tab is filled (245,245,245) with a (234,234,234) frame; the selected one is
//     2 px larger on each side and 2 px taller, filled like the page (250,250,250), and it opens
//     into the page, whose frame is (234,234,234) with a (245,245,245) shadow on the right and
//     at the bottom;
//   * the caption is centred; the selected tab's sits 3 px higher.
// The pages themselves stay in a tabless NSTabView (the property sheet's page area), which keeps
// the page switching, the view-controller life cycle and every test that walks NSTabView.

import AppKit

final class OptionsTabControl: NSView {

    /// Called with the index of the tab the user clicked.
    var onSelect: ((Int) -> Void)?

    private(set) var titles: [String] = []
    private(set) var selectedIndex = 0
    private var tabViews: [TabItemView] = []

    /// The tab row: y 2 in the control, 18 high (TCM_GETITEMRECT).
    static let tabTop: CGFloat = 2
    static let tabHeight: CGFloat = 18
    /// The page frame's top edge, under the tabs (client y 27).
    static let panelTop: CGFloat = 20

    override var isFlipped: Bool { true }

    // Colours of the light theme, and their counterparts in the dark one.
    private static func dynamic(_ light: CGFloat, _ dark: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            let v = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: v / 255, green: v / 255, blue: v / 255, alpha: 1)
        }
    }
    static let frameColor = dynamic(234, 70)
    static let shadowColor = dynamic(245, 40)
    static let tabFill = dynamic(245, 44)
    static let pageFill = dynamic(250, 36)

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setTitles(_ newTitles: [String]) {
        titles = newTitles
        while tabViews.count < titles.count {
            let view = TabItemView()
            view.owner = self
            addSubview(view)
            tabViews.append(view)
        }
        while tabViews.count > titles.count { tabViews.removeLast().removeFromSuperview() }
        for (i, view) in tabViews.enumerated() {
            view.index = i
            view.title = titles[i]
        }
        setAccessibilityChildren(tabViews)
        needsLayout = true
        needsDisplay = true
    }

    func select(_ index: Int) {
        guard index != selectedIndex || tabViews.indices.contains(index) else { return }
        selectedIndex = index
        needsLayout = true
        needsDisplay = true
        for view in tabViews { view.needsDisplay = true }
    }

    fileprivate func userSelected(_ index: Int) {
        guard tabViews.indices.contains(index) else { return }
        select(index)
        onSelect?(index)
    }

    /// The tab rects in this view's coordinates (unselected geometry), as TCM_GETITEMRECT.
    func tabRects() -> [NSRect] {
        var x: CGFloat = 2
        return titles.map { title in
            let w = Self.tabWidth(title)
            defer { x += w }
            return NSRect(x: x, y: Self.tabTop, width: w, height: Self.tabHeight)
        }
    }

    /// A tab is its caption plus 6 px padding on either side, at least 42 px (System 46, 7-Zip 42,
    /// Folders 46, Editor 42, Settings 50, Language 60 on the PC).
    static func tabWidth(_ title: String) -> CGFloat {
        let text = ceil((title as NSString).size(withAttributes: [.font: DialogMetrics.font]).width)
        return max(42, text + 13)
    }

    override func layout() {
        super.layout()
        for (i, rect) in tabRects().enumerated() where i < tabViews.count {
            tabViews[i].frame = i == selectedIndex
                ? NSRect(x: rect.minX - 2, y: rect.minY - 2, width: rect.width + 4, height: rect.height + 3)
                : rect
        }
        // The selected tab is drawn over its neighbours.
        if tabViews.indices.contains(selectedIndex) {
            let selected = tabViews[selectedIndex]
            selected.removeFromSuperview()
            addSubview(selected)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        // the page: (250,250,250) inside a 1 px frame, with a 2 px shadow right and 1 px below
        let panel = NSRect(x: 0, y: Self.panelTop, width: b.width - 2, height: b.height - Self.panelTop - 1)
        Self.pageFill.setFill()
        panel.fill()
        Self.frameColor.setFill()
        NSRect(x: panel.minX, y: panel.minY, width: panel.width, height: 1).fill()
        NSRect(x: panel.minX, y: panel.maxY - 1, width: panel.width, height: 1).fill()
        NSRect(x: panel.minX, y: panel.minY, width: 1, height: panel.height).fill()
        NSRect(x: panel.maxX - 1, y: panel.minY, width: 1, height: panel.height).fill()
        Self.shadowColor.setFill()
        NSRect(x: panel.maxX, y: panel.minY + 1, width: 2, height: panel.height).fill()
        NSRect(x: panel.minX + 1, y: panel.maxY, width: panel.width + 1, height: 1).fill()
    }

    // MARK: - one tab

    fileprivate final class TabItemView: NSView {
        weak var owner: OptionsTabControl?
        var index = 0
        var title = "" {
            didSet { needsDisplay = true; setAccessibilityLabel(title); setAccessibilityTitle(title) }
        }

        override var isFlipped: Bool { true }
        var isSelected: Bool { owner?.selectedIndex == index }

        override init(frame: NSRect) {
            super.init(frame: frame)
            setAccessibilityElement(true)
            setAccessibilityRole(.radioButton)
            setAccessibilitySubrole(.tabButtonSubrole)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func accessibilityValue() -> Any? { isSelected ? 1 : 0 }

        override func accessibilityPerformPress() -> Bool {
            owner?.userSelected(index)
            return true
        }

        override func mouseDown(with event: NSEvent) {
            owner?.userSelected(index)
        }

        override func draw(_ dirtyRect: NSRect) {
            let b = bounds
            let selected = isSelected
            (selected ? OptionsTabControl.pageFill : OptionsTabControl.tabFill).setFill()
            b.fill()
            OptionsTabControl.frameColor.setFill()
            NSRect(x: 0, y: 0, width: b.width, height: 1).fill()                    // top
            NSRect(x: 0, y: 0, width: 1, height: b.height - (selected ? 1 : 0)).fill()     // left
            NSRect(x: b.width - 1, y: 0, width: 1, height: b.height - (selected ? 1 : 0)).fill() // right
            if !selected {
                NSRect(x: 0, y: b.height - 1, width: b.width, height: 1).fill()   // the page's top edge
            }
            let attributes: [NSAttributedString.Key: Any] = [.font: DialogMetrics.font,
                                                             .foregroundColor: NSColor.labelColor]
            let size = (title as NSString).size(withAttributes: attributes)
            // The caption's baseline is 14 px below the tab's top edge, selected or not (client
            // y 23 for an unselected tab at y 9, y 21 for the selected one at y 7).
            let baseline: CGFloat = 14
            let origin = NSPoint(x: ((b.width - size.width) / 2).rounded(),
                                 y: (baseline - DialogMetrics.font.ascender).rounded())
            (title as NSString).draw(at: origin, withAttributes: attributes)
        }
    }
}
