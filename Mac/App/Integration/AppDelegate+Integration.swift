// AppDelegate+Integration.swift -- the `NSApplicationDelegate` methods the shell integration needs.
//
// They live in an extension on purpose: `Mac/App/AppDelegate.swift` belongs to no scope's ownership
// table (00-orchestration.md), and Swift lets an @objc extension satisfy the optional protocol
// requirements of `NSApplicationDelegate` just as well as the class body would.
//
// `application(_:open:)` receives both the `sevenzip://` / `x-7zip://` command URLs and plain file
// URLs (a double-click, "Open With", a drop on the Dock icon), which is the macOS replacement for
// the `7zFM.exe "%1"` association command (03-shell-integration-inventory.md section 3.3,
// section 6.2).

import AppKit

/// The `NSApplicationDelegate` methods this scope needs. They live in an extension so
/// `Mac/App/AppDelegate.swift`, which no scope owns, is not touched.
@objc extension AppDelegate {

    /// URL opens (`sevenzip://`, `x-7zip://`) and file opens both arrive here on macOS 10.13+.
    func application(_ application: NSApplication, open urls: [URL]) {
        var files: [URL] = []
        for url in urls {
            if url.isFileURL {
                files.append(url)
            } else {
                URLCommands.handle(url)
            }
        }
        if !files.isEmpty { URLCommands.openDocuments(files) }
    }

    /// The legacy `odoc` path, for callers that still send it (`open -a 7-Zip file`).
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        URLCommands.openDocuments(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }
}
