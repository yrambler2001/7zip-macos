// PanelFinderInfo.swift -- Properties (IDM_PROPERTIES 551, Alt+Enter, toolbar Info) outside an
// archive: 7zFM opens the operating system's property sheet, the port opens Finder's Get Info
// windows (01 §3.11, 01b §4.11; listfeel.md §4).
//
// CPanel::Properties (PanelMenu.cpp:171-180): a folder without IGetFolderArcProps -- the file
// system, the drives, the root -- goes to InvokeSystemCommand("properties"), which
// (PanelMenu.cpp:58-76) does nothing unless the folder is the file system or the pure drives list
// and something is operated (Get_ItemIndices_Operated), and otherwise invokes the shell's
// "properties" verb on those items. An archive folder gets the 7-Zip list dialog.
//
// On macOS the shell verb is Finder's "open information window of <item>", sent as an Apple
// Event. It needs the user's Automation consent (NSAppleEventsUsageDescription in Info.plist):
//
//   * the event is sent from a background queue, never the main thread, so a consent prompt or a
//     busy Finder cannot freeze the app, and it carries a timeout;
//   * when the user has denied Automation (errAEEventNotPermitted, -1743, checked first with
//     AEDeterminePermissionToAutomateTarget and again from the send), Finder is not running, or the
//     send fails or times out, the 7-Zip list dialog is shown instead, as before;
//   * under XCTest or the test-support contract no event is ever sent: the stub sender answers
//     "denied" (the CI machine cannot grant Automation, and a consent prompt would sit over the
//     UI suite). The routing decision and the fallback are what the tests cover; the real
//     Finder path is a manual check (listfeel.md §4).

import Cocoa
import SevenZipKit

enum FinderInfo {

    /// What Properties does for the current folder and operated items.
    enum Route: Equatable {
        case listDialog                 // an archive folder: CListViewDialog
        case finder([URL])              // the file system or the volumes list, items operated
        case nothing                    // InvokeSystemCommand returns early
    }

    enum Outcome: Equatable {
        case shown
        case denied                     // the user refused Automation for Finder
        case failed(Int)                // OSStatus of the send (Finder not running, timeout, ...)
    }

    /// At most this many Get Info windows for one command (Finder opens one per item; the
    /// Windows sheet is one window for any number). kMaxOpenItems, PanelItems.cpp:1096.
    static let maxWindows = 20

    /// The routing rule of CPanel::Properties / InvokeSystemCommand.
    static func route(isArchive: Bool, isFileSystem: Bool, isVolumesFolder: Bool, itemPaths: [String]) -> Route {
        if isArchive { return .listDialog }
        guard isFileSystem || isVolumesFolder, !itemPaths.isEmpty else { return .nothing }
        return .finder(itemPaths.prefix(maxWindows).map { URL(fileURLWithPath: $0) })
    }

    /// The sender: the real Apple Event, or the stub under tests. Tests may replace it.
    static var sender: ([URL], @escaping (Outcome) -> Void) -> Void = defaultSender

    static var sendsRealEvents: Bool {
        let env = ProcessInfo.processInfo.environment
        return !TestSupport.isEnabled && env["XCTestConfigurationFilePath"] == nil && env["SEVENZIP_UITEST"] == nil
    }

    private static let defaultSender: ([URL], @escaping (Outcome) -> Void) -> Void = { urls, done in
        guard sendsRealEvents else { done(.denied); return }
        queue.async {
            let outcome = sendNow(urls)
            DispatchQueue.main.async { done(outcome) }
        }
    }

    private static let queue = DispatchQueue(label: "com.yrambler2001.7zip.finder-info", qos: .userInitiated)

    /// errAEEventNotPermitted / errAEEventWouldRequireUserConsent.
    static let notPermitted = -1743
    static let wouldRequireConsent = -1744
    /// Seconds a send may take, consent prompt included, before it counts as failed.
    static let timeout: TimeInterval = 120

    /// Background queue only.
    private static func sendNow(_ urls: [URL]) -> Outcome {
        let finder = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        if let desc = finder.aeDesc {
            // Without asking: a recorded refusal falls back at once instead of sending.
            let status = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, false)
            if Int(status) == notPermitted { return .denied }
        }
        let open = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenDocuments),
                                          targetDescriptor: finder, returnID: AEReturnID(kAutoGenerateReturnID),
                                          transactionID: AETransactionID(kAnyTransactionID))
        let list = NSAppleEventDescriptor.list()
        for url in urls { list.insert(informationWindow(of: url), at: list.numberOfItems + 1) }
        open.setParam(list, forKeyword: keyDirectObject)
        do {
            _ = try open.sendEvent(options: [.waitForReply], timeout: timeout)
            let activate = NSAppleEventDescriptor(eventClass: AEEventClass(kAEMiscStandards), eventID: AEEventID(kAEActivate),
                                                  targetDescriptor: finder, returnID: AEReturnID(kAutoGenerateReturnID),
                                                  transactionID: AETransactionID(kAnyTransactionID))
            _ = try? activate.sendEvent(options: [.noReply], timeout: 5)
            return .shown
        } catch {
            let code = (error as NSError).code
            return code == notPermitted ? .denied : .failed(code)
        }
    }

    /// `information window of <file URL>`: Finder's item property 'iwnd' as an object specifier.
    static func informationWindow(of url: URL) -> NSAppleEventDescriptor {
        let spec = NSAppleEventDescriptor.record().coerce(toDescriptorType: DescType(typeObjectSpecifier))
            ?? NSAppleEventDescriptor.record()
        spec.setDescriptor(NSAppleEventDescriptor(typeCode: OSType(cProperty)), forKeyword: AEKeyword(keyAEDesiredClass))
        spec.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
        spec.setDescriptor(NSAppleEventDescriptor(typeCode: fourCharCode("iwnd")), forKeyword: AEKeyword(keyAEKeyData))
        spec.setDescriptor(NSAppleEventDescriptor(fileURL: url), forKeyword: AEKeyword(keyAEContainer))
        return spec
    }

    static func fourCharCode(_ text: String) -> OSType {
        text.utf8.reduce(0) { ($0 << 8) | OSType($1) }
    }
}

extension PanelViewController {

    /// CPanel::Properties: the routing above, then the list dialog for an archive folder or when
    /// Finder cannot be asked.
    func showProperties() {
        guard let snap = snapshot else { return }
        let indices = operatedRowIndices()
        let paths = indices.map { rows[$0].fullPath }.filter { !$0.isEmpty }
        let route = FinderInfo.route(isArchive: snap.isArchive, isFileSystem: snap.isFileSystem,
                                     isVolumesFolder: snap.isVolumesFolder, itemPaths: paths)
        lastPropertiesRoute = route
        switch route {
        case .nothing:
            return
        case .listDialog:
            showPropertiesList(engineIndices: indices.map { rows[$0].engineIndex }, snapshot: snap)
        case .finder(let urls):
            let engineIndices = indices.map { rows[$0].engineIndex }
            FinderInfo.sender(urls) { [weak self] outcome in
                guard let self, outcome != .shown else { return }
                self.showPropertiesList(engineIndices: engineIndices, snapshot: snap)
            }
        }
    }

    /// The 7-Zip list (CListViewDialog, IDS_PROPERTIES 6600), built on the panel queue.
    func showPropertiesList(engineIndices: [Int], snapshot snap: PanelSnapshot) {
        let level = timestampLevel
        runOnQueue { [self] in
            guard let folder = self.folder else { return }
            let lines = PanelProperties.build(folder: folder, itemIndices: engineIndices,
                                              snapshot: snap, level: level)
            DispatchQueue.main.async {
                PropertiesDialog.show(lines: lines, parent: self.view.window)
            }
        }
    }
}
