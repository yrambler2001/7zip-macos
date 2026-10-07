// PreviewViewController.swift -- the principal class of QuickLook.appex
// (`com.apple.quicklook.preview`, a view-based QLPreviewingController; quicklook scope, a macOS
// addition with no 7zFM counterpart).
//
// Quick Look calls `preparePreviewOfFile(at:completionHandler:)` with the archive the user selected
// (Finder's preview pane, the space-bar panel, `qlmanage -p`). The archive is opened and listed on
// a background queue by `ArchivePreviewBuilder` -- read-only, within 2 s and 10 000 entries, never
// asking for a password -- and the result is drawn by `ArchivePreviewView` on the main thread.
// Every engine object lives and dies inside that one background call, so the bridge's
// one-thread-per-folder rule holds. When Quick Look drops the preview, the controller's flag makes
// the open's checkBreak answer E_ABORT.

import Cocoa
import os
import Quartz
import SevenZipKit

final class PreviewViewController: NSViewController, QLPreviewingController {

    /// Set when the preview is no longer wanted; polled by the open and the listing.
    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    private let cancelFlag = CancelFlag()
    static let log = Logger(subsystem: "com.yrambler2001.7zip", category: "quicklook")
    private var previewView: ArchivePreviewView { view as! ArchivePreviewView }

    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        let view = ArchivePreviewView(frame: NSRect(x: 0, y: 0, width: 820, height: 560))
        view.autoresizingMask = [.width, .height]
        self.view = view
        preferredContentSize = view.frame.size
    }

    deinit { cancelFlag.set() }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        let settings = PreviewSettings.current
        settings.apply(to: view)
        let flag = cancelFlag
        let path = url.path
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let start = Date()
            let preview = ArchivePreviewBuilder.build(path: path, limits: .standard,
                                                      timestampLevel: settings.timestampLevel,
                                                      isCancelled: { flag.isSet })
            // `log stream --predicate 'subsystem == "com.yrambler2001.7zip"'`: the outcome only; the
            // file's name stays private.
            Self.log.log("preview of \(path, privacy: .private): \(preview.status.kind, privacy: .public), \(preview.listedEntries, privacy: .public)/\(preview.totalEntries, privacy: .public) entries, types \(preview.summary.typeText, privacy: .public), \(Int(Date().timeIntervalSince(start) * 1000), privacy: .public) ms, lang '\(SZLang.shared.currentLanguageCode, privacy: .public)'")
            DispatchQueue.main.async {
                self?.previewView.show(preview, fileURL: url, timestampLevel: settings.timestampLevel,
                                       utc: settings.utc)
                handler(nil)
            }
        }
    }
}

/// The display settings of this process, from the snapshot the app pushed into the container
/// (`QuickLookPreferences`), else the defaults. Loaded once: the language and the UTC switch are
/// process-wide engine state.
struct PreviewSettings {
    var appearance: NSAppearance?
    var timestampLevel: SZTimestampLevel
    var utc: Bool

    static let current: PreviewSettings = {
        let prefs = QuickLookPreferences.load() ?? QuickLookPreferences()
        let settings = PreviewSettings(prefs)
        // ReloadLang ("" = the system's language, "-" = English, else a Lang/*.txt), from the
        // framework the app embeds.
        _ = try? SZLang.shared.loadLanguage(code: prefs.language ?? "")
        SZFolder.timestampShowUTC = settings.utc
        return settings
    }()

    init(_ prefs: QuickLookPreferences) {
        // AppTheme: "light" / "dark" force the appearance, "system" or nothing follows the system.
        switch prefs.theme {
        case "light": appearance = NSAppearance(named: .aqua)
        case "dark": appearance = NSAppearance(named: .darkAqua)
        default: appearance = nil
        }
        timestampLevel = prefs.timestampLevel.flatMap { SZTimestampLevel(rawValue: $0) } ?? .min
        utc = prefs.timestampShowUTC ?? false
    }

    func apply(to view: NSView) {
        view.appearance = appearance
    }
}
