// ArchivePreviewView.swift -- the Quick Look preview of an archive, drawn like 7zFM (quicklook
// scope, a macOS addition: 7zFM has no shell preview handler).
//
//   7z · LZMA2:12 · Solid · Folders: 2 · Files: 4 · 3 043 -> 296 bytes (10%)   the summary line
//   (!) ...and 12 345 more -- open in 7-Zip                                  a note, when needed
//   ---------------------------------------------------------------------- hairline
//   | Name                    |      Size | Packed Size | Modified |          SysHeader32, 24 px
//   | > [] sub                |     3 010 |             | 2024-... |          rows 19 px, 16 px icons
//
// Quick Look's own title bar already names the file and offers "Open with 7-Zip", so the preview
// has no title, icon or button of its own (qlfix): one summary line in the terms of 7zFM's
// Properties (01 §3.11) on the list's own background, a note line when there is something to say,
// a hairline, then the list.
//
// The list is the panel's Details view in miniature (01 §3.2 / §3.12, reports/listfeel.md): the
// same 19 pt rows and 24 pt header, the same font (SF Pro 12.2, `ListFontChoice`; tabular digits
// in the number and time columns), the same cell text (`Formatting.size`, `Formatting.displayName`,
// the engine's ConvertPropertyToString2 for times), the same icons (`PanelArchiveIcons`' pixel-
// sharp 16 px frames for the extensions 7-Zip registers, `Icons` by extension for the others), the
// same colours (`WinChrome`) and the Windows 11 selection fill (COLOR_HIGHLIGHT 0,120,212 with
// white text, reports/selcolors.md). The archive's folders open as an outline -- the one thing the
// panel does differently (it enters a folder instead), because a preview cannot navigate.
//
// Light and dark: the view follows the app's theme when the app has pushed it
// (`QuickLookPreferences`), else the system's appearance. Every colour is dynamic.
//
// Drawing rule (qlfix): every custom `draw(_:)` here fills its *bounds*, never `dirtyRect`. With the
// macOS 14 SDK a view does not clip to its bounds (`clipsToBounds` is false) and AppKit may hand it
// a dirty rect far larger than itself, backing the overflow with an extra layer: in the real Quick
// Look host the 1 pt hairline under the 1.2.0 summary band was asked to draw an 820 x 560 rect and
// painted its grey over the whole band (its overflow layer sat above the band's labels and below
// the list), which is the empty grey block users saw. App-hosted cacheDisplay renders never showed
// it.

import AppKit
import SevenZipKit

/// Geometry of the preview (the panel's, PanelMetrics: rows 19, header 24, icon 16 at x 4).
enum PreviewMetrics {
    static let rowHeight: CGFloat = 19
    static let headerHeight: CGFloat = 24
    static let iconSize: CGFloat = 16
    static let subitemPadding: CGFloat = 6
    static let bandPadding: CGFloat = 12
    static let summaryRowHeight: CGFloat = 17
    static let minimumColumnWidth: CGFloat = 100

    static var font: NSFont { ListFontChoice.current }
    static var digitsFont: NSFont { ListFontChoice.withTabularDigits(font) }
    static var boldFont: NSFont { NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }

    static func textWidth(_ text: String, _ font: NSFont) -> CGFloat {
        let field = NSTextField(labelWithString: text)
        field.font = font
        return ceil(field.intrinsicContentSize.width)
    }

    /// A Details column wide enough for `text` plus 6 pt each side, never below Windows' 100
    /// (PanelMetrics.columnWidth).
    static func columnWidth(fitting text: String) -> CGFloat {
        max(minimumColumnWidth, textWidth(text, digitsFont) + 2 * subitemPadding)
    }

    /// "9 999 999 999 999" (PanelMetrics.widestSize).
    static var sizeColumnWidth: CGFloat { columnWidth(fitting: "9 999 999 999 999") }

    /// The widest date at `level` (PanelMetrics.widestDate).
    static func timeColumnWidth(level: SZTimestampLevel, utc: Bool) -> CGFloat {
        var text = "2024-12-31"
        if level.rawValue > SZTimestampLevel.day.rawValue { text += " 23:59" }
        if level.rawValue >= SZTimestampLevel.sec.rawValue { text += ":59" }
        if level.rawValue > SZTimestampLevel.sec.rawValue {
            text += "." + String("123456789".prefix(level.rawValue >= 9 ? 9 : Int(level.rawValue)))
        }
        return columnWidth(fitting: utc ? text + "Z" : text)
    }
}

/// The texts (lang IDs: the panel's column names 1000 + kpid, 01 §7.2; macOS additions from 9970,
/// next to the theme's 9900s and Reset's 9960s, so a translator can add them to a Lang/*.txt).
/// 9971 ("Open in 7-Zip", 1.2.0) is retired with the button: Quick Look's title bar has its own.
enum PreviewText {
    enum LangID {
        static let checkbox: UInt32 = 9970        // Options > macOS: "Quick Look preview for archives"
        static let encrypted: UInt32 = 9972
        static let more: UInt32 = 9973
        static let stopped: UInt32 = 9974
        static let tooMany: UInt32 = 9975
        static let volumePart: UInt32 = 9976
        static let volumeFailed: UInt32 = 9977
    }

    static var encrypted: String {
        Lang.text(LangID.encrypted, "Encrypted archive \u{2014} open in 7-Zip to enter the password")
    }
    static func more(_ count: Int) -> String {
        Lang.format(Lang.text(LangID.more, "\u{2026}and {0} more \u{2014} open in 7-Zip"), Formatting.size(UInt64(count)))
    }
    static var stopped: String {
        Lang.text(LangID.stopped, "Listing stopped \u{2014} open in 7-Zip to see everything")
    }
    static var tooMany: String {
        Lang.text(LangID.tooMany, "Too many items to preview \u{2014} open in 7-Zip")
    }
    static var volumePart: String {
        Lang.text(LangID.volumePart, "Part of a multi-volume archive \u{2014} showing what this file holds")
    }
    static var volumeFailed: String {
        Lang.text(LangID.volumeFailed, "Part of a multi-volume archive \u{2014} open it in 7-Zip with all its volumes")
    }
    /// IDS_CANT_OPEN_ARCHIVE 3005.
    static func cannotOpen(_ name: String) -> String {
        Lang.format(Lang.text(3005, "Cannot open file '{0}' as archive"), name)
    }
    /// IDS_FILE_SIZE 3504, "{0} bytes".
    static func bytes(_ text: String) -> String { Lang.format(Lang.get(3504, "{0} bytes"), text) }

    /// A Properties label: the property's name (1000 + kpid).
    static func property(_ id: SZPropID, _ fallback: String) -> String { Lang.text(1000 + id.rawValue, fallback) }
}

/// The summary line and the note under it.
enum PreviewSummaryLine {

    static let separator = " \u{00B7} "

    /// "7z · LZMA2:12 · Solid · Folders: 2 · Files: 4 · 3 043 → 296 bytes (10%)": the archive
    /// level's Type, Method, Solid, Encrypted, Volumes, then the item sums Folders, Files, Size and
    /// Packed Size (01 §3.11's Properties terms, the app's number grouping).
    static func text(for summary: ArchivePreviewSummary, status: ArchivePreviewStatus) -> String {
        var parts: [String] = []
        if !summary.types.isEmpty { parts.append(summary.typeText) }
        if let method = summary.method { parts.append(method) }
        if summary.solid == true { parts.append(PreviewText.property(.solid, "Solid")) }
        if let blocks = summary.blocks, blocks > 1 {
            parts.append(PreviewText.property(.numBlocks, "Blocks") + ": " + Formatting.size(blocks))
        }
        if summary.encrypted || summary.headersEncrypted { parts.append(PreviewText.property(.encrypted, "Encrypted")) }
        if summary.multiVolume {
            if let n = summary.numVolumes {
                parts.append(PreviewText.property(.numVolumes, "Volumes") + ": " + Formatting.size(n))
            } else {
                parts.append(PreviewText.property(.isVolume, "Multivolume"))
            }
        }
        switch status {
        case .encrypted, .failed, .cancelled:
            if let phy = summary.physicalSize { parts.append(PreviewText.bytes(Formatting.size(phy))) }
        default:
            if summary.folders > 0 {
                parts.append(PreviewText.property(.numSubDirs, "Folders") + ": " + Formatting.size(UInt64(summary.folders)))
            }
            parts.append(PreviewText.property(.numSubFiles, "Files") + ": " + Formatting.size(UInt64(summary.files)))
            if let size = summary.size {
                var sizes = Formatting.size(size)
                if let packed = summary.packedSize ?? summary.physicalSize { sizes += " \u{2192} " + Formatting.size(packed) }
                var text = PreviewText.bytes(sizes)
                if let ratio = summary.ratioPercent { text += " (\(ratio)%)" }
                parts.append(text)
            } else if let phy = summary.physicalSize {
                parts.append(PreviewText.bytes(Formatting.size(phy)))
            }
        }
        if let comment = summary.comment { parts.append(ArchivePreviewBuilder.oneLine(comment)) }
        return parts.joined(separator: separator)
    }

    /// The note (nil: none); `listless` = there is no list to show under it.
    static func notice(for preview: ArchivePreview) -> (text: String, listless: Bool)? {
        switch preview.status {
        case .encrypted:
            return (PreviewText.encrypted, true)
        case .failed(let message):
            if preview.summary.multiVolume { return (PreviewText.volumeFailed, true) }
            var text = PreviewText.cannotOpen(preview.summary.fileName)
            if !message.isEmpty { text += " \u{2014} " + ArchivePreviewBuilder.oneLine(message) }
            return (text, true)
        case .cancelled:
            return nil
        case .truncated(let notShown):
            return (PreviewText.more(notShown), false)
        case .stopped(_, let tooMany):
            return (tooMany ? PreviewText.tooMany : PreviewText.stopped, preview.listedEntries == 0)
        case .complete:
            if preview.summary.multiVolume { return (PreviewText.volumePart, false) }
            if let warning = preview.summary.warning { return (ArchivePreviewBuilder.oneLine(warning), false) }
            return nil
        }
    }
}

// MARK: - the view

final class ArchivePreviewView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {

    private(set) var preview: ArchivePreview?
    private(set) var fileURL: URL?

    /// The summary line, on the list's background.
    let summaryField = NSTextField(labelWithString: "")
    let noticeIcon = NSImageView()
    let noticeField = NSTextField(wrappingLabelWithString: "")
    /// The hairline between the summary and the header (the header's own divider grey).
    let hairline = PreviewFillView(color: PreviewHeaderCell.divider)
    let outlineView = PreviewOutlineView()
    let scrollView = NSScrollView()

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        WinChrome.window.setFill()
        bounds.fill()
    }

    private func build() {
        addSubview(summaryField)
        addSubview(noticeIcon)
        addSubview(noticeField)
        addSubview(hairline)
        addSubview(scrollView)

        summaryField.font = PreviewMetrics.digitsFont
        summaryField.textColor = WinChrome.text
        summaryField.lineBreakMode = .byTruncatingTail
        summaryField.cell?.truncatesLastVisibleLine = true
        summaryField.setAccessibilityIdentifier("quickLookSummary")

        noticeIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        noticeIcon.contentTintColor = .systemOrange
        noticeIcon.imageScaling = .scaleProportionallyDown
        noticeField.font = PreviewMetrics.font
        noticeField.textColor = WinChrome.text
        noticeField.setAccessibilityIdentifier("quickLookNotice")

        configureOutline()
    }

    private func configureOutline() {
        outlineView.headerView = PreviewHeaderView(frame: NSRect(x: 0, y: 0, width: 100, height: PreviewMetrics.headerHeight))
        outlineView.rowHeight = PreviewMetrics.rowHeight
        outlineView.rowSizeStyle = .custom
        outlineView.intercellSpacing = NSSize(width: 0, height: 0)
        outlineView.backgroundColor = WinChrome.window
        outlineView.gridStyleMask = []
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.style = .plain
        outlineView.indentationPerLevel = 16
        outlineView.autoresizesOutlineColumn = false
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outlineView.allowsMultipleSelection = true
        outlineView.focusRingType = .none
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.setAccessibilityIdentifier("quickLookList")
        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            let header = PreviewHeaderCell(textCell: column.title)
            header.alignment = column.alignment
            tableColumn.headerCell = header
            tableColumn.title = column.title
            tableColumn.minWidth = 24
            tableColumn.maxWidth = 2000
            tableColumn.resizingMask = column == .name ? [.autoresizingMask, .userResizingMask] : [.userResizingMask]
            outlineView.addTableColumn(tableColumn)
            if column == .name { outlineView.outlineTableColumn = tableColumn }
        }
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = WinChrome.window
    }

    // MARK: columns (01 §3.2: an archive folder's kpidName, kpidSize, kpidPackSize, kpidMTime)

    enum Column: String, CaseIterable {
        case name, size, packedSize, modified

        var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }
        var propID: SZPropID {
            switch self {
            case .name: return .name
            case .size: return .size
            case .packedSize: return .packSize
            case .modified: return .mtime
            }
        }
        var title: String {
            switch self {
            case .name: return PreviewText.property(.name, "Name")
            case .size: return PreviewText.property(.size, "Size")
            case .packedSize: return PreviewText.property(.packSize, "Packed Size")
            case .modified: return PreviewText.property(.mtime, "Modified")
            }
        }
        /// GetColumnAlign (PanelFormat.alignment): names and times left, sizes right.
        var alignment: NSTextAlignment { self == .size || self == .packedSize ? .right : .left }
    }

    // MARK: showing

    /// Fills the view from a finished preview of `fileURL`. Main thread.
    func show(_ preview: ArchivePreview, fileURL: URL, timestampLevel: SZTimestampLevel = .min, utc: Bool = false) {
        self.preview = preview
        self.fileURL = fileURL
        summaryField.stringValue = PreviewSummaryLine.text(for: preview.summary, status: preview.status)
        summaryField.toolTip = summaryField.stringValue
        let notice = PreviewSummaryLine.notice(for: preview)
        noticeField.stringValue = notice?.text ?? ""
        noticeField.isHidden = notice == nil
        noticeIcon.isHidden = notice == nil
        noticeIcon.image = NSImage(systemSymbolName: preview.status == .encrypted ? "lock.fill" : "exclamationmark.triangle.fill",
                                   accessibilityDescription: nil)
        noticeIcon.contentTintColor = preview.status == .encrypted ? .secondaryLabelColor : .systemOrange
        // A file that could not be listed has no list, only its line and note.
        scrollView.isHidden = (notice?.listless ?? false) && preview.listedEntries == 0

        if let column = outlineView.tableColumn(withIdentifier: Column.size.identifier) {
            column.width = PreviewMetrics.sizeColumnWidth
        }
        if let column = outlineView.tableColumn(withIdentifier: Column.packedSize.identifier) {
            column.width = max(PreviewMetrics.sizeColumnWidth, PreviewMetrics.columnWidth(fitting: Column.packedSize.title))
        }
        if let column = outlineView.tableColumn(withIdentifier: Column.modified.identifier) {
            column.width = PreviewMetrics.timeColumnWidth(level: timestampLevel, utc: utc)
        }
        outlineView.reloadData()
        // A single top-level folder (the common "project/..." archive) starts open.
        let top = preview.root.children
        if top.count == 1, top[0].isDirectory { outlineView.expandItem(top[0]) }
        needsLayout = true
        needsDisplay = true
        layoutSubtreeIfNeeded()
    }

    // MARK: layout

    /// The line's text starts where the list's names do: 6 pt in, as the header's titles.
    static let inset: CGFloat = PreviewMetrics.subitemPadding
    static let lineTop: CGFloat = 6

    override func layout() {
        super.layout()
        let width = bounds.width
        let inset = Self.inset
        var y = Self.lineTop
        let lineHeight = ceil(summaryField.intrinsicContentSize.height)
        summaryField.frame = NSRect(x: inset, y: y, width: max(0, width - 2 * inset), height: lineHeight)
        y += lineHeight + 2
        if !noticeField.isHidden {
            let textX = inset + 16 + 4
            let textWidth = max(50, width - textX - inset)
            noticeField.preferredMaxLayoutWidth = textWidth
            let height = ceil(noticeField.fittingSize.height)
            noticeIcon.frame = NSRect(x: inset, y: y + floor((lineHeight - 14) / 2), width: 16, height: 14)
            noticeField.frame = NSRect(x: textX, y: y, width: textWidth, height: height)
            y += max(height, lineHeight) + 2
        }
        y += 3
        hairline.frame = NSRect(x: 0, y: y, width: width, height: 1)
        let listTop = y + 1
        scrollView.frame = NSRect(x: 0, y: listTop, width: width, height: max(0, bounds.height - listTop))
        if let name = outlineView.tableColumn(withIdentifier: Column.name.identifier) {
            let others = outlineView.tableColumns.filter { $0 !== name }.reduce(CGFloat(0)) { $0 + $1.width }
            name.width = max(160, scrollView.contentSize.width - others)
        }
    }

    // MARK: NSOutlineViewDataSource

    private func node(_ item: Any?) -> ArchivePreviewNode? {
        item as? ArchivePreviewNode ?? preview?.root
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        node(item)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        node(item)!.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? ArchivePreviewNode else { return false }
        return node.isDirectory && !node.children.isEmpty
    }

    // MARK: NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        PreviewRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue),
              let node = item as? ArchivePreviewNode else { return nil }
        let cell = (outlineView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? PreviewCellView)
            ?? PreviewCellView(column: column)
        cell.identifier = tableColumn.identifier
        switch column {
        case .name:
            cell.textField?.stringValue = Formatting.displayName(node.name)
            cell.imageView?.image = Self.icon(for: node)
        case .size:
            cell.textField?.stringValue = node.size.map(Formatting.size) ?? ""
        case .packedSize:
            cell.textField?.stringValue = node.packedSize.map(Formatting.size) ?? ""
        case .modified:
            cell.textField?.stringValue = node.modifiedText
        }
        return cell
    }

    /// PanelIcons' rule for an archive item (no real icons inside an archive): 7-Zip's own 16 px
    /// frame for the extensions it registers, the system's icon by extension otherwise, the folder
    /// icon for folders.
    static func icon(for node: ArchivePreviewNode) -> NSImage {
        if node.isDirectory { return Icons.folder }
        return PanelArchiveIcons.icon(forName: node.name, large: false)
            ?? Icons.icon(forName: node.name, isDirectory: false)
    }
}

// MARK: - pieces

/// A plain filled view (the band, the 1 px line under it).
final class PreviewFillView: NSView {
    let color: NSColor
    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        // Bounds, not dirtyRect: the view does not clip to its bounds (see the file comment).
        color.setFill()
        bounds.fill()
    }
}

final class PreviewOutlineView: NSOutlineView {
    /// No focus ring, no source-list look: the list is a SysListView32.
    override var acceptsFirstResponder: Bool { true }
}

/// The header (SysHeader32 with the list's font, 24 pt), as PanelHeaderCell draws it.
final class PreviewHeaderView: NSTableHeaderView {
    override func draw(_ dirtyRect: NSRect) {
        // Bounds, not dirtyRect: the view does not clip to its bounds (see the file comment).
        WinChrome.window.setFill()
        bounds.fill()
        super.draw(dirtyRect)
        PreviewHeaderCell.bottomLine.setFill()
        NSRect(x: bounds.minX, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }
}

/// A header item: the title in the list font, 6 pt from the edge it is aligned to, its baseline
/// 16 pt down the 24 pt header, a 1 px divider at the right edge (PanelHeaderCell, recheck §2).
/// No stored references (NSCell copies bitwise, see `CellCopy`): the font and colours are static.
final class PreviewHeaderCell: NSTableHeaderCell {
    static let divider = WinChrome.dynamic(WinChrome.gray(229), .separatorColor)
    static let bottomLine = WinChrome.dynamic(WinChrome.gray(229), .separatorColor)

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        WinChrome.window.setFill()
        cellFrame.fill()
        Self.divider.setFill()
        NSRect(x: cellFrame.maxX - 1, y: cellFrame.minY, width: 1, height: cellFrame.height).fill()
        drawInterior(withFrame: cellFrame, in: controlView)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let font = PreviewMetrics.font
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSAttributedString(string: stringValue, attributes: [
            .font: font, .foregroundColor: WinChrome.text, .paragraphStyle: paragraph,
        ])
        let inset = PreviewMetrics.subitemPadding
        let rect = NSRect(x: cellFrame.minX + inset, y: cellFrame.minY, width: max(0, cellFrame.width - 2 * inset - 1),
                          height: cellFrame.height)
        // Baseline 16 pt down the 24 pt header (flipped header view).
        let baseline: CGFloat = 16
        let origin = NSPoint(x: rect.minX, y: rect.minY + baseline - font.ascender)
        text.draw(with: NSRect(origin: origin, size: NSSize(width: rect.width, height: ceil(font.ascender - font.descender))),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// The selection as the Windows 11 list draws it: COLOR_HIGHLIGHT (0,120,212), white text
/// (PanelSelectionStyle.highlight / highlightText, reports/selcolors.md).
final class PreviewRowView: NSTableRowView {
    static let highlight = NSColor(srgbRed: 0, green: 120 / 255, blue: 212 / 255, alpha: 1)

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        Self.highlight.setFill()
        bounds.fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { isSelected ? .emphasized : .normal }
}

/// One cell: the name with its 16 px icon (LVIR_ICON at x 4 of the label area, the text 2 pt into
/// the label at x 20), or a size / time right- or left-aligned 6 pt from the column's edge.
final class PreviewCellView: NSTableCellView {
    let column: ArchivePreviewView.Column

    init(column: ArchivePreviewView.Column) {
        self.column = column
        super.init(frame: .zero)
        let field = NSTextField(labelWithString: "")
        field.font = column == .name ? PreviewMetrics.font : PreviewMetrics.digitsFont
        field.textColor = WinChrome.text
        field.lineBreakMode = .byTruncatingTail
        field.alignment = column.alignment
        field.cell?.truncatesLastVisibleLine = true
        addSubview(field)
        textField = field
        if column == .name {
            let image = NSImageView()
            image.imageScaling = .scaleNone
            addSubview(image)
            imageView = image
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { textField?.textColor = backgroundStyle == .emphasized ? .white : WinChrome.text }
    }

    override func layout() {
        super.layout()
        guard let field = textField else { return }
        let height = ceil(field.intrinsicContentSize.height)
        let y = ((bounds.height - height) / 2).rounded()
        if let imageView {
            imageView.frame = NSRect(x: 2, y: ((bounds.height - PreviewMetrics.iconSize) / 2).rounded(),
                                     width: PreviewMetrics.iconSize, height: PreviewMetrics.iconSize)
            field.frame = NSRect(x: 2 + PreviewMetrics.iconSize + 4, y: y,
                                 width: max(0, bounds.width - 22 - PreviewMetrics.subitemPadding), height: height)
        } else {
            // The text 6 pt from the edge it is aligned to; the field may use the other side's
            // padding too, so a date that needs the column's exact width is never cut.
            let pad = PreviewMetrics.subitemPadding
            let x = field.alignment == .right ? 0 : pad
            field.frame = NSRect(x: x, y: y, width: max(0, bounds.width - pad), height: height)
        }
    }
}
