// ArchivePreviewView.swift -- the Quick Look preview of an archive, drawn like 7zFM (quicklook
// scope, a macOS addition: 7zFM has no shell preview handler).
//
//   +--------------------------------------------------------------+
//   | [32px icon] test.7z                          [Open in 7-Zip] |  band, COLOR_BTNFACE
//   | Type: 7z          Method: LZMA2:12      Solid: +             |  the Properties block
//   | Folders: 2        Files: 4              Size: 3 045 ...      |  (01 §3.11)
//   | (!) ... and 12 345 more -- open in 7-Zip                     |  a notice, when there is one
//   +--------------------------------------------------------------+
//   | Name                    |      Size | Packed Size | Modified |  SysHeader32, 24 px
//   | > [] sub                |     3 010 |             | 2024-... |  rows 19 px, 16 px icons
//   |   [] readme.txt         |        12 |         150 | 2024-... |
//   +--------------------------------------------------------------+
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
// (`QuickLookPreferences`), else the system's appearance, which is also what Quick Look's own
// window follows. Every colour is dynamic, so either way works.

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
enum PreviewText {
    enum LangID {
        static let checkbox: UInt32 = 9970        // Options > macOS: "Quick Look preview for archives"
        static let openInApp: UInt32 = 9971       // the button
        static let encrypted: UInt32 = 9972
        static let more: UInt32 = 9973
        static let stopped: UInt32 = 9974
        static let tooMany: UInt32 = 9975
        static let volumePart: UInt32 = 9976
        static let volumeFailed: UInt32 = 9977
    }

    static var openInApp: String { Lang.text(LangID.openInApp, "Open in 7-Zip") }
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

    /// A Properties label: the property's name (1000 + kpid).
    static func property(_ id: SZPropID, _ fallback: String) -> String { Lang.text(1000 + id.rawValue, fallback) }
    /// "Compression ratio:" (IDT_PROGRESS_RATIO, 3905) without its colon.
    static var ratio: String {
        var text = Lang.text(3905, "Compression ratio:")
        while text.hasSuffix(":") || text.hasSuffix("\u{FF1A}") || text.hasSuffix(" ") { text.removeLast() }
        return text
    }
    /// VT_BOOL as ConvertPropertyToString shows it.
    static func flag(_ value: Bool) -> String { value ? "+" : "-" }
}

/// The summary's label / value pairs, in the Properties dialog's order (01 §3.11): the item sums
/// first, then the archive level's Type, Method, Solid, Blocks, Encrypted, Volumes, Physical Size.
enum PreviewSummaryRows {
    static func rows(for summary: ArchivePreviewSummary, status: ArchivePreviewStatus) -> [(String, String)] {
        var rows: [(String, String)] = []
        if !summary.types.isEmpty { rows.append((PreviewText.property(.type, "Type"), summary.typeText)) }
        if let method = summary.method { rows.append((PreviewText.property(.method, "Method"), method)) }
        if let solid = summary.solid { rows.append((PreviewText.property(.solid, "Solid"), PreviewText.flag(solid))) }
        if let blocks = summary.blocks, blocks > 1 {
            rows.append((PreviewText.property(.numBlocks, "Blocks"), Formatting.size(blocks)))
        }
        if summary.encrypted || summary.headersEncrypted {
            rows.append((PreviewText.property(.encrypted, "Encrypted"), PreviewText.flag(true)))
        }
        if summary.multiVolume {
            if let n = summary.numVolumes {
                rows.append((PreviewText.property(.numVolumes, "Volumes"), Formatting.size(n)))
            } else {
                rows.append((PreviewText.property(.isVolume, "Multivolume"), PreviewText.flag(true)))
            }
        }
        let listed: Bool
        switch status {
        case .encrypted, .failed, .cancelled: listed = false
        default: listed = true
        }
        if listed {
            rows.append((PreviewText.property(.numSubDirs, "Folders"), Formatting.size(UInt64(summary.folders))))
            rows.append((PreviewText.property(.numSubFiles, "Files"), Formatting.size(UInt64(summary.files))))
            if let size = summary.size { rows.append((PreviewText.property(.size, "Size"), Formatting.size(size))) }
            if let packed = summary.packedSize {
                rows.append((PreviewText.property(.packSize, "Packed Size"), Formatting.size(packed)))
            }
        }
        if let phy = summary.physicalSize {
            rows.append((PreviewText.property(.phySize, "Physical Size"), Formatting.size(phy)))
        }
        if listed, let ratio = summary.ratioPercent { rows.append((PreviewText.ratio, "\(ratio)%")) }
        if let comment = summary.comment {
            rows.append((PreviewText.property(.comment, "Comment"), ArchivePreviewBuilder.oneLine(comment)))
        }
        return rows
    }

    /// The notice under the summary (nil: none); `prominent` = there is no list to show.
    static func notice(for preview: ArchivePreview) -> (text: String, prominent: Bool)? {
        switch preview.status {
        case .encrypted:
            return (PreviewText.encrypted, true)
        case .failed(let message):
            var text = PreviewText.cannotOpen(preview.summary.fileName)
            if preview.summary.multiVolume { text = PreviewText.volumeFailed }
            else if !message.isEmpty { text += "\n" + message }
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

    /// Opens the archive in the containing app (the button). Replaced by the tests.
    static var openInApp: (URL) -> Void = ArchivePreviewView.openInContainingApp

    private(set) var preview: ArchivePreview?
    private(set) var fileURL: URL?

    let band = PreviewFillView(color: WinChrome.face)
    let iconView = NSImageView()
    let titleField = NSTextField(labelWithString: "")
    let openButton = NSButton(title: "", target: nil, action: nil)
    let summaryGrid = NSGridView()
    let noticeIcon = NSImageView()
    let noticeField = NSTextField(wrappingLabelWithString: "")
    let bandLine = PreviewFillView(color: WinChrome.listBorder)
    let outlineView = PreviewOutlineView()
    let scrollView = NSScrollView()
    let centerMessage = NSTextField(wrappingLabelWithString: "")
    let centerIcon = NSImageView()

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        addSubview(band)
        addSubview(bandLine)
        addSubview(scrollView)
        addSubview(centerIcon)
        addSubview(centerMessage)
        band.addSubview(iconView)
        band.addSubview(titleField)
        band.addSubview(openButton)
        band.addSubview(summaryGrid)
        band.addSubview(noticeIcon)
        band.addSubview(noticeField)

        iconView.imageScaling = .scaleNone
        titleField.font = PreviewMetrics.boldFont
        titleField.textColor = WinChrome.text
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.setAccessibilityIdentifier("quickLookTitle")

        openButton.bezelStyle = .rounded
        openButton.font = PreviewMetrics.font
        openButton.title = PreviewText.openInApp
        openButton.target = self
        openButton.action = #selector(openClicked(_:))
        openButton.setAccessibilityIdentifier("quickLookOpenInApp")

        summaryGrid.rowSpacing = 0
        summaryGrid.columnSpacing = 6
        summaryGrid.yPlacement = .center

        noticeIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        noticeIcon.contentTintColor = .systemOrange
        noticeField.font = PreviewMetrics.font
        noticeField.textColor = WinChrome.text
        noticeField.setAccessibilityIdentifier("quickLookNotice")
        centerMessage.font = PreviewMetrics.font
        centerMessage.textColor = WinChrome.text
        centerMessage.alignment = .center
        centerMessage.setAccessibilityIdentifier("quickLookMessage")
        centerIcon.imageScaling = .scaleProportionallyUpOrDown

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
        let name = preview.summary.fileName
        titleField.stringValue = Formatting.displayName(name)
        iconView.image = PanelArchiveIcons.icon(forName: name, large: true)
            ?? Self.resized(Icons.icon(forName: name, isDirectory: false), 32)

        summaryGrid.subviews.forEach { $0.removeFromSuperview() }
        while summaryGrid.numberOfRows > 0 { summaryGrid.removeRow(at: 0) }
        let rows = PreviewSummaryRows.rows(for: preview.summary, status: preview.status)
        let perRow = 3
        var index = 0
        while index < rows.count {
            var views: [NSView] = []
            for pair in rows[index..<min(index + perRow, rows.count)] {
                views.append(Self.label(pair.0 + ":", secondary: true))
                views.append(Self.label(pair.1, secondary: false))
            }
            while views.count < perRow * 2 { views.append(NSGridCell.emptyContentView) }
            summaryGrid.addRow(with: views)
            index += perRow
        }
        for row in 0..<summaryGrid.numberOfRows { summaryGrid.row(at: row).height = PreviewMetrics.summaryRowHeight }
        for column in 0..<summaryGrid.numberOfColumns where column % 2 == 1 {
            summaryGrid.column(at: column).trailingPadding = 18
        }

        let notice = PreviewSummaryRows.notice(for: preview)
        let hasList = preview.listedEntries > 0 || !(notice?.prominent ?? false)
        noticeField.stringValue = (notice != nil && !(notice!.prominent && !hasList)) ? notice!.text : ""
        noticeField.isHidden = noticeField.stringValue.isEmpty
        noticeIcon.isHidden = noticeField.isHidden
        centerMessage.stringValue = hasList ? "" : (notice?.text ?? "")
        centerMessage.isHidden = hasList
        centerIcon.isHidden = hasList
        centerIcon.image = preview.status == .encrypted
            ? NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)
            : NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        centerIcon.contentTintColor = .secondaryLabelColor
        scrollView.isHidden = !hasList

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
        layoutSubtreeIfNeeded()
    }

    private static func label(_ text: String, secondary: Bool) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = secondary ? PreviewMetrics.font : PreviewMetrics.digitsFont
        field.textColor = secondary ? .secondaryLabelColor : WinChrome.text
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    static func resized(_ image: NSImage, _ points: CGFloat) -> NSImage {
        let copy = image.copy() as? NSImage ?? image
        copy.size = NSSize(width: points, height: points)
        return copy
    }

    // MARK: layout

    override func layout() {
        super.layout()
        let width = bounds.width
        let pad = PreviewMetrics.bandPadding
        let buttonSize = openButton.intrinsicContentSize
        iconView.frame = NSRect(x: pad, y: pad, width: 32, height: 32)
        openButton.frame = NSRect(x: width - pad - buttonSize.width, y: pad + (32 - buttonSize.height) / 2,
                                  width: buttonSize.width, height: buttonSize.height)
        let titleHeight = ceil(titleField.intrinsicContentSize.height)
        titleField.frame = NSRect(x: pad + 32 + 8, y: pad + (32 - titleHeight) / 2,
                                  width: max(0, openButton.frame.minX - 8 - (pad + 40)), height: titleHeight)
        var y = pad + 32 + 8
        let gridSize = summaryGrid.fittingSize
        summaryGrid.frame = NSRect(x: pad, y: y, width: min(gridSize.width, width - 2 * pad), height: gridSize.height)
        if summaryGrid.numberOfRows > 0 { y += gridSize.height + 4 }
        if !noticeField.isHidden {
            let textWidth = max(50, width - 2 * pad - 22)
            noticeField.preferredMaxLayoutWidth = textWidth
            let height = ceil(noticeField.fittingSize.height)
            noticeIcon.frame = NSRect(x: pad, y: y + 1, width: 16, height: 16)
            noticeField.frame = NSRect(x: pad + 22, y: y, width: textWidth, height: height)
            y += max(height, 17) + 4
        }
        y += pad - 4
        band.frame = NSRect(x: 0, y: 0, width: width, height: y)
        bandLine.frame = NSRect(x: 0, y: y, width: width, height: 1)
        let listTop = y + 1
        scrollView.frame = NSRect(x: 0, y: listTop, width: width, height: max(0, bounds.height - listTop))
        let messageWidth = min(width - 4 * pad, 460)
        centerMessage.preferredMaxLayoutWidth = messageWidth
        let messageHeight = ceil(centerMessage.fittingSize.height)
        let middle = listTop + (bounds.height - listTop) / 2
        centerIcon.frame = NSRect(x: (width - 40) / 2, y: middle - 40 - 8, width: 40, height: 40)
        centerMessage.frame = NSRect(x: (width - messageWidth) / 2, y: middle, width: messageWidth, height: messageHeight)
        if let name = outlineView.tableColumn(withIdentifier: Column.name.identifier) {
            let others = outlineView.tableColumns.filter { $0 !== name }.reduce(CGFloat(0)) { $0 + $1.width }
            let scroller = scrollView.verticalScroller.map { $0.isHidden ? 0 : $0.frame.width } ?? 0
            name.width = max(160, scrollView.contentSize.width - others - (scrollView.hasVerticalScroller ? 0 : scroller))
        }
    }

    // MARK: the button

    @objc func openClicked(_ sender: Any?) {
        guard let fileURL else { return }
        Self.openInApp(fileURL)
    }

    /// `7-Zip.app`, seen from `7-Zip.app/Contents/PlugIns/QuickLook.appex`.
    static func containingAppURL(of bundleURL: URL = Bundle.main.bundleURL) -> URL {
        var url = bundleURL
        while url.pathExtension == "appex" || url.lastPathComponent == "PlugIns" || url.lastPathComponent == "Contents" {
            url = url.deletingLastPathComponent()
        }
        return url
    }

    /// Opens the archive with the app that carries this extension, through Launch Services --
    /// the plain "open this document with that application" route, never the sevenzip:// command
    /// channel (whose secret this extension neither has nor needs).
    static func openInContainingApp(_ fileURL: URL) {
        let app = containingAppURL()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([fileURL], withApplicationAt: app, configuration: configuration) { _, error in
            if let error { NSLog("7-Zip Quick Look: cannot open %@ in %@: %@", fileURL.path, app.path, error.localizedDescription) }
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
        color.setFill()
        dirtyRect.fill()
    }
}

final class PreviewOutlineView: NSOutlineView {
    /// No focus ring, no source-list look: the list is a SysListView32.
    override var acceptsFirstResponder: Bool { true }
}

/// The header (SysHeader32 with the list's font, 24 pt), as PanelHeaderCell draws it.
final class PreviewHeaderView: NSTableHeaderView {
    override func draw(_ dirtyRect: NSRect) {
        WinChrome.window.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
        PreviewHeaderCell.bottomLine.setFill()
        NSRect(x: dirtyRect.minX, y: bounds.maxY - 1, width: dirtyRect.width, height: 1).fill()
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
