// PanelDragOutVerification.swift -- a verification hook for the drag-out path, in the shape the
// other scopes already use (SZ_OPSINFRA_DEMO, SZ_EXTRACT_CONTEXT, SZ_COMPRESS_DEMO): it does
// nothing unless its environment variable is set, and it is the only way a UI test can exercise
// dragging an archive member to Finder, which XCUITest cannot do across applications.
//
//   SZ_POLISH_DRAGOUT=<directory>   adds "Drag Out (verify)" to the Tools menu. Choosing it runs
//                                   the *real* drag-out: the panel's own
//                                   `tableView(_:pasteboardWriterForRow:)` builds the
//                                   NSFilePromiseProvider for the focused row and the promise
//                                   delegate writes it into <directory>, on the promise queue,
//                                   exactly as a drop into Finder does.
//
// What it is for: `ArchiveDragOut.extract` had no `password:` parameter, so a drag out of an
// archive the panel had already unlocked asked for the password a second time
// (Mac/docs/requests.md, `cleanup` -> `extract`).

import AppKit

enum PanelDragOutVerification {

    static let environmentVariable = "SZ_POLISH_DRAGOUT"
    /// Written next to the extracted file once the promise has been fulfilled, so a test can wait
    /// for the operation instead of polling for a file that is still being written.
    static let doneFileName = "drag-out-done.txt"

    static var destination: String? {
        let value = ProcessInfo.processInfo.environment[environmentVariable]
        return (value?.isEmpty ?? true) ? nil : value
    }

    static func installIfRequested() {
        guard destination != nil else { return }
        NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification,
                                               object: nil, queue: .main) { _ in
            addMenuItem(to: NSApp.mainMenu)
        }
    }

    /// The Tools menu is the one holding IDM_BENCHMARK 901, whatever language its title is in.
    private static func addMenuItem(to menuBar: NSMenu?) {
        guard let menuBar else { return }
        guard let tools = menuBar.items.compactMap({ $0.submenu })
            .first(where: { $0.items.contains { $0.tag == 901 } }) else {
            NSLog("polish-dragout: no Tools menu")
            return
        }
        let item = NSMenuItem(title: "Drag Out (verify)",
                              action: #selector(MainWindowController.polishVerifyDragOut(_:)),
                              keyEquivalent: "")
        item.setAccessibilityIdentifier("polishVerifyDragOut:")
        tools.addItem(.separator())
        tools.addItem(item)
    }

    /// Drives the promise the way a drop into Finder does: the provider comes from the panel's
    /// own pasteboard-writer method and the delegate runs on `PanelViewController.promiseQueue`.
    static func run(panel: PanelViewController) {
        guard let destination else { return }
        try? FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
        guard let row = panel.operatedRowIndices().first,
              let provider = panel.tableView(NSTableView(), pasteboardWriterForRow: row)
                  as? NSFilePromiseProvider else {
            NSLog("polish-dragout: no file promise for the focused row")
            write(done: "no-promise", in: destination)
            return
        }
        let name = panel.filePromiseProvider(provider, fileNameForType: "public.data")
        let url = URL(fileURLWithPath: destination).appendingPathComponent(name)
        NSLog("polish-dragout: promising %@", url.path)
        PanelViewController.promiseQueue.addOperation {
            panel.filePromiseProvider(provider, writePromiseTo: url) { error in
                let outcome = error.map { "error: \($0.localizedDescription)" } ?? "ok"
                NSLog("polish-dragout: %@ -> %@", url.path, outcome)
                write(done: outcome, in: destination)
            }
        }
    }

    private static func write(done outcome: String, in directory: String) {
        let marker = URL(fileURLWithPath: directory).appendingPathComponent(doneFileName)
        try? outcome.write(to: marker, atomically: true, encoding: .utf8)
    }
}

extension MainWindowController {

    /// Tools > "Drag Out (verify)" -- only present while SZ_POLISH_DRAGOUT is set.
    @objc func polishVerifyDragOut(_ sender: Any?) {
        PanelDragOutVerification.run(panel: focusedPanel)
    }
}
