// QuickActionController.swift -- the two Finder Quick Actions
// (03-shell-integration-inventory.md section 6.1 "Action extension shown as Finder Quick Action",
// section 6.3 recommendation 2, section 7).
//
// A `com.apple.ui-services` Action extension with `NSExtensionServiceAllowsFinderPreviewItem` shows
// up in Finder's **Quick Actions** submenu, in the Preview pane and on the Touch Bar. One appex is
// one flat entry -- there are no submenus -- so there are two: "Extract with 7-Zip" for the archive
// UTIs and "Compress with 7-Zip" for any file. They work whether or not the Finder Sync extension
// is enabled, and they are toggled in a different place (System Settings > General > Login Items &
// Extensions > **Finder**, not > File Providers).
//
// The commands are the same ones the context menu offers, taken from the same `FinderMenuModel`, so
// the labels, the naming rules and the generated switches cannot drift:
//   "Extract with 7-Zip"  -> `SevenZipExtractTo`, i.e. `x -o"<dir><spec>/" [-spe] [-snzN] -an -ai…`
//   "Compress with 7-Zip" -> `SevenZipCompress`,  i.e. `a -i… -ad -saa -- "<dir><name>"`
//
// Sandboxed like the Finder Sync extension: no file access, no process spawning, the command goes
// to the app through `sevenzip://`.

import Cocoa
import os
import UniformTypeIdentifiers

private let log = Logger(subsystem: ExtensionHandoff.subsystem, category: "QuickAction")

/// Shared body. The view is never meant to be seen: the request completes as soon as the command
/// has been handed to the app, which is the closest an Action extension gets to "headless".
class QuickActionController: NSViewController {

    /// The `FinderMenuModel` verb this action runs.
    var commandVerb: String { "" }

    override func loadView() {
        view = NSView(frame: .zero)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        log.log("\(self.commandVerb, privacy: .public): \(providers.count, privacy: .public) attachments, types \(providers.map(\.registeredTypeIdentifiers), privacy: .public)")
        QuickActionInput.fileURLs(from: providers) { [weak self] urls in
            guard let self else { return }
            self.run(with: urls) { self.finish() }
        }
    }

    private func run(with urls: [URL], completion: @escaping () -> Void) {
        guard !urls.isEmpty else {
            ExtensionHandoff.report(.noItems, log: log) { _ in completion() }
            return
        }
        let selection = FinderSelection(urls: urls)
        let bundleID = Bundle.main.bundleIdentifier ?? SevenZipBundle.quickActionExtract
        let settings = IntegrationSettings.current(extensionBundleID: bundleID)
        guard let command = FinderMenuModel.command(verb: commandVerb, selection: selection,
                                                   settings: settings) else {
            ExtensionHandoff.report(.notAvailable, log: log) { _ in completion() }
            return
        }
        let built = command.argv(for: selection.paths, listFileDirectory: NSTemporaryDirectory())
        guard let url = CommandURL.url(argv: built.argv,
                                       temporaryFiles: built.temporaryFiles) else {
            ExtensionHandoff.report(.unknownCommand, log: log) { _ in completion() }
            return
        }
        log.log("\(self.commandVerb, privacy: .public): \(urls.count, privacy: .public) items")
        // The request is completed only after the system has answered the hand-off: completing
        // first lets the extension process be torn down while the open is still in flight.
        ExtensionHandoff.send(url, log: log) { _ in completion() }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}

/// "Extract with 7-Zip": `Extract to "<name>/"`, the one-click command, `-spe` from
/// `Options.ElimDupExtract` exactly as the context-menu item.
final class ExtractQuickActionController: QuickActionController {
    override var commandVerb: String { "SevenZipExtractTo" }
}

/// "Compress with 7-Zip": the `Add to archive…` dialog over the selection.
final class CompressQuickActionController: QuickActionController {
    override var commandVerb: String { "SevenZipCompress" }
}
