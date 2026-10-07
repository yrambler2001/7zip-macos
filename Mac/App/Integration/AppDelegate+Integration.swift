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
//
// A **Dock drop** is the one case that is not an open: on Windows 7-Zip is registered as an
// Explorer drop handler, so dragging a selection onto it offers "Add to archive…" (`03 section
// 1.7`). macOS delivers a Dock drop through the same `kAEOpenDocuments` event as a double-click, so
// the two are told apart by the event's sender (`DockDropDetector`) and routed by
// `DockDropRouter.action`.

import AppKit
import SevenZipKit

/// Who sent the `kAEOpenDocuments` event that is being handled right now.
///
/// There is no `NSApplicationDelegate` callback for "dropped on the Dock icon": Finder, the Dock,
/// `open(1)` and `NSWorkspace` all cause the same `'aevt'/'odoc'`. The event's address attribute
/// does say who sent it, though, so the Dock's own drops can be recognised by resolving that
/// address to a running application and comparing its bundle identifier.
///
/// If the attribute is missing, or resolves to anything else, the request is treated as an ordinary
/// document open — the conservative answer, because opening what the user asked to open is never
/// destructive while compressing it unasked would be surprising.
enum DockDropDetector {

    /// `com.apple.dock`. LaunchServices forwards a Dock drop with the Dock as the sender.
    static let dockBundleIdentifier = "com.apple.dock"

    private static let keyAddressAttribute = AEKeyword(0x6164_6472)          // 'addr'
    private static let keyOriginalAddressAttribute = AEKeyword(0x6672_6F6D)  // 'from'
    private static let kernelProcessIDType = DescType(0x6B70_6964)           // 'kpid'

    /// The source of the event currently being dispatched.
    static var currentSource: DocumentOpenSource {
        source(of: NSAppleEventManager.shared().currentAppleEvent)
    }

    /// Split out so a test can hand over a descriptor it built itself.
    static func source(of event: NSAppleEventDescriptor?) -> DocumentOpenSource {
        guard let event else { return .document }
        guard let bundleID = senderBundleIdentifier(of: event) else { return .document }
        return bundleID == dockBundleIdentifier ? .dockDrop : .document
    }

    /// The bundle identifier of the process that sent `event`, or nil when it cannot be resolved.
    static func senderBundleIdentifier(of event: NSAppleEventDescriptor) -> String? {
        for keyword in [keyOriginalAddressAttribute, keyAddressAttribute] {
            guard let address = event.attributeDescriptor(forKeyword: keyword) else { continue }
            let pidDescriptor = address.descriptorType == kernelProcessIDType
                ? address
                : address.coerce(toDescriptorType: kernelProcessIDType)
            guard let data = pidDescriptor?.data, data.count >= 4 else { continue }
            var pid: pid_t = 0
            _ = withUnsafeMutableBytes(of: &pid) { data.copyBytes(to: $0, count: 4) }
            guard pid > 0,
                  let application = NSRunningApplication(processIdentifier: pid),
                  let bundleID = application.bundleIdentifier else { continue }
            return bundleID
        }
        return nil
    }
}

/// The `NSApplicationDelegate` methods this scope needs. They live in an extension so
/// `Mac/App/AppDelegate.swift`, which no scope owns, is not touched.
@objc extension AppDelegate {

    /// URL opens (`sevenzip://`, `x-7zip://`) and file opens both arrive here on macOS 10.13+.
    ///
    /// A shell command (a command URL, a Dock drop) goes through `GMode.submit`: on a cold launch
    /// this event arrives *before* `applicationDidFinishLaunching` (measured, reports/gmode.md), and
    /// running the command's modal dialog from here used to hold the launch until OK / Cancel, after
    /// which the default file-manager window appeared. Now the launch is marked as one for a command
    /// (no file-manager window) and the command runs once the app is up.
    func application(_ application: NSApplication, open urls: [URL]) {
        var files: [URL] = []
        // sec113: who sent the URL, read now while the Apple event is current. Logged only: the
        // URL's token is the check, and a sender has often exited by the time it is resolved.
        let sender = NSAppleEventManager.shared().currentAppleEvent
            .flatMap(DockDropDetector.senderBundleIdentifier(of:))
        for url in urls {
            if url.isFileURL {
                files.append(url)
            } else if URLCommands.isShellCommand(url) {
                GMode.submit { URLCommands.handle(url, sender: sender) }
            } else {
                URLCommands.handle(url, sender: sender)
            }
        }
        if !files.isEmpty {
            openDocuments(files, source: DockDropDetector.currentSource)
        }
    }

    /// The legacy `odoc` path, for callers that still send it (`open -a 7-Zip file`).
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        openDocuments(filenames.map { URL(fileURLWithPath: $0) }, source: DockDropDetector.currentSource)
        sender.reply(toOpenOrPrint: .success)
    }

    /// A plain open runs now (its windows are the launch's windows, reports/newwindow.md); a Dock
    /// drop is 7zG's drop handler, a shell command (`GMode`).
    @nonobjc private func openDocuments(_ files: [URL], source: DocumentOpenSource) {
        if source == .dockDrop {
            GMode.submit { URLCommands.openDocuments(files, source: source) }
        } else {
            URLCommands.openDocuments(files, source: source)
        }
    }
}
