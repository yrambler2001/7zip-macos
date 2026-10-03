// ProgressDockTile.swift -- the Dock-tile progress bar: the macOS stand-in for 7zFM's taskbar button
// progress (`ITaskbarList3`, CProgressDialog::SetTaskbarProgressState / SetProgressValue,
// FileManager/ProgressDialog2.cpp:279-316, :592-593, :995; 01b-fm-dialogs-settings.md §4.17).
// Scope `opsgaps` (opsinfra-owned file, `Progress*.swift`).
//
// Windows draws one bar per progress window on the application's taskbar button. A Dock tile is one
// per application, so every operation that currently shows a Progress dialog registers here and the
// tile shows their combined progress: bytes done over bytes total across all of them. The colour
// follows the TBPFLAG Windows would use: TBPF_ERROR (red) as soon as any operation has displayed
// errors, else TBPF_PAUSED (yellow) while every running one is paused, else TBPF_NORMAL. When the
// last operation ends -- finished, cancelled or failed -- the tile goes back to the plain icon
// (TBPF_NOPROGRESS, :995).

import AppKit

final class ProgressDockTile {

    /// The TBPFLAG values 7zFM uses.
    enum State: Equatable {
        case normal     // TBPF_NORMAL
        case paused     // TBPF_PAUSED
        case error      // TBPF_ERROR (_errorsWereDisplayed)
    }

    /// One operation's contribution.
    struct Entry: Equatable {
        var completed: UInt64 = 0
        var total: UInt64?
        var paused = false
        var hasErrors = false
    }

    static let shared = ProgressDockTile()

    /// The tile drawn on. Tests may swap in a stand-in sink to observe what would be drawn.
    var dockTile: NSDockTile? = NSApp?.dockTile

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var order: [ObjectIdentifier] = []
    private var view: ProgressDockTileView?
    /// What the tile shows now, nil = the plain icon (TBPF_NOPROGRESS). Main thread only.
    private(set) var displayed: (fraction: Double?, state: State)?

    // MARK: registration (main thread only)

    /// The Progress dialog of `owner` appeared (CProgressDialog::OnInitDialog).
    func begin(_ owner: AnyObject) {
        precondition(Thread.isMainThread)
        let id = ObjectIdentifier(owner)
        if entries[id] == nil { order.append(id) }
        entries[id] = Entry()
        refresh()
    }

    /// The 200 ms tick of `owner` (UpdateStatInfo -> SetProgressValue / SetTaskbarProgressState).
    func update(_ owner: AnyObject, _ entry: Entry) {
        precondition(Thread.isMainThread)
        let id = ObjectIdentifier(owner)
        guard entries[id] != nil, entries[id] != entry else { return }
        entries[id] = entry
        refresh()
    }

    /// `owner` finished, failed or was cancelled (OnExternalCloseMessage: TBPF_NOPROGRESS).
    func end(_ owner: AnyObject) {
        precondition(Thread.isMainThread)
        let id = ObjectIdentifier(owner)
        guard entries.removeValue(forKey: id) != nil else { return }
        order.removeAll { $0 == id }
        refresh()
    }

    /// Number of operations currently drawn on the tile.
    var activeCount: Int { entries.count }

    // MARK: aggregation

    /// Bytes done over bytes total across every operation that knows its total; nil while none
    /// does yet (an empty bar, as the dialog's own bar before SetTotal).
    static func combinedFraction(_ entries: [Entry]) -> Double? {
        var done: Double = 0
        var total: Double = 0
        for entry in entries {
            guard let t = entry.total, t > 0 else { continue }
            total += Double(t)
            done += Double(min(entry.completed, t))
        }
        return total > 0 ? done / total : nil
    }

    static func combinedState(_ entries: [Entry]) -> State {
        if entries.contains(where: \.hasErrors) { return .error }
        if !entries.isEmpty, entries.allSatisfy(\.paused) { return .paused }
        return .normal
    }

    private func refresh() {
        let current = order.compactMap { entries[$0] }
        guard !current.isEmpty else {
            displayed = nil
            view = nil
            if let tile = dockTile {
                tile.contentView = nil
                tile.display()
            }
            return
        }
        let fraction = Self.combinedFraction(current)
        let state = Self.combinedState(current)
        // The dock redraws the whole tile on display(); skip it when nothing visible changed
        // (a whole-percent step, like the dialog's title).
        if let shown = displayed, shown.state == state,
           Self.percent(shown.fraction) == Self.percent(fraction) {
            return
        }
        displayed = (fraction, state)
        guard let tile = dockTile else { return }
        let tileView = view ?? ProgressDockTileView(frame: NSRect(origin: .zero, size: tile.size))
        view = tileView
        tileView.fraction = fraction
        tileView.state = state
        if tile.contentView !== tileView { tile.contentView = tileView }
        tile.display()
    }

    private static func percent(_ fraction: Double?) -> Int {
        fraction.map { Int(($0 * 100).rounded(.down)) } ?? -1
    }
}

/// The app icon with a progress bar along its bottom edge, the way Finder and Safari draw theirs.
final class ProgressDockTileView: NSView {

    var fraction: Double?
    var state: ProgressDockTile.State = .normal

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        NSApp.applicationIconImage?.draw(in: bounds)

        let inset = bounds.width * 0.08
        let height = max(bounds.height * 0.11, 6)
        let track = NSRect(x: bounds.minX + inset, y: bounds.minY + bounds.height * 0.08,
                           width: bounds.width - 2 * inset, height: height)
        let radius = height / 2

        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        let inner = track.insetBy(dx: 2, dy: 2)
        NSColor.white.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: inner, xRadius: inner.height / 2, yRadius: inner.height / 2).fill()

        guard let fraction, fraction > 0 else { return }
        var bar = inner
        bar.size.width = max(inner.height, inner.width * CGFloat(min(fraction, 1)))
        let fill: NSColor
        switch state {
        case .normal: fill = .systemBlue
        case .paused: fill = .systemYellow
        case .error: fill = .systemRed
        }
        fill.setFill()
        NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2).fill()
    }
}
