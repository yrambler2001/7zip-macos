// AboutDialog.swift -- Help > About 7-Zip (IDM_ABOUT 961), CAboutDialog / IDD_ABOUT 2900,
// plus the Help topic opener the whole app uses.
// Parity: 01b-fm-dialogs-settings.md 4.1, 01-fm-feature-inventory.md 2.6, 9 #17.

import AppKit
import SevenZipKit

final class AboutDialog: NSObject {

    private static let homePageURL = "https://www.7-zip.org/"     // kHomePageURL

    private let window: NSWindow

    /// The extra line the user asked for (dlgfeel finding 8), placed under the copyright line.
    static let macCredit = "macOS version by yrambler2001"

    private init(parent: NSWindow?) {
        window = DialogKit.window(title: Lang.text(2900, "About 7-Zip"), resizable: false)
        super.init()

        // IDD_ABOUT 2900 (AboutDialog.rc): 160 x 160 DLU = 240 x 260 px, every control on its .rc
        // rect (RcLayout, reports/dlgfeel.md section About).
        let rc = RcDialog(2900)
        let form = RcFormView()

        // IDI_LOGO 100, SS_REALSIZEIMAGE (AboutDialog.rc:21): 7zipLogo.ico at its real size, the
        // 110 x 63 wordmark, shipped as `AboutLogo` by make-icons (requests.md, icons -> tools). The
        // app icon stands in only if the asset is missing.
        let logo = NSImageView()
        let wordmark = NSImage(named: "AboutLogo")
        logo.image = wordmark ?? NSApp.applicationIconImage
        logo.imageScaling = wordmark == nil ? .scaleProportionallyUpOrDown : .scaleNone
        logo.imageAlignment = .alignTopLeft
        logo.setAccessibilityIdentifier("aboutLogo")
        form.add(logo, rc, -1, 0)
        // SS_REALSIZEIMAGE: the static takes the image's own size (110 x 63 in the capture).
        logo.frame.size = wordmark?.size ?? NSSize(width: 64, height: 64)

        // IDT_ABOUT_VERSION 101 = "7-Zip <MY_VERSION> (<cpu>)", with the port's version in it
        // (pub3): "7-Zip 26.03 for macOS 1.0.0 (arm64)". IDT_ABOUT_DATE 102 = MY_DATE
        let version = RcPlace.makeLabel(Self.versionText)
        version.setAccessibilityIdentifier("aboutVersion")
        form.add(version, rc, 101)
        form.add(RcPlace.makeLabel(SZBenchmark.engineDateText), rc, 102)
        // static LTEXT MY_COPYRIGHT (-1, the second static)
        form.add(RcPlace.makeLabel(SZBenchmark.engineCopyrightText), rc, -1, 1)
        // The macOS credit: one more 13 px line at the copyright line's pitch (21 px), so it sits
        // where IDT_ABOUT_INFO started; IDT_ABOUT_INFO moves down by that pitch.
        let copyrightRect = rc.rect(-1, 1)
        let pitch = rc.rect(-1, 1).minY - rc.rect(102).minY
        let credit = RcPlace.makeLabel(Self.macCredit)
        credit.setAccessibilityIdentifier("aboutMacCredit")
        form.addSubview(credit)
        RcPlace.label(credit, copyrightRect.offsetBy(dx: 0, dy: pitch))
        // IDT_ABOUT_INFO 2901 (the only localized item, kLangIDs): a multi-line LTEXT
        var infoRect = rc.rect(2901)
        infoRect.origin.y += pitch
        infoRect.size.height -= pitch
        let info = RcPlace.makeWrappingLabel(Lang.text(2901, "7-Zip is free software"))
        form.addSubview(info)
        RcPlace.label(info, infoRect)
        info.frame.size.height = infoRect.height

        // IDB_ABOUT_HOMEPAGE 110 "www.7-zip.org", IDOK (DEFPUSHBUTTON). IDD_ABOUT has only these
        // two (AboutDialog.rc, and 7zFM 26.03: dlgfeel-data/win/dlg-about.txt). Its help topic is
        // reached with F1 (CAboutDialog::OnHelp -> ShowHelpWindow("start.htm"), which opens HtmlHelp
        // in 7zFM's process): `helpKeyMonitor` gives the dialog the same F1 (and the Mac Help key).
        form.add(DialogKit.button("www.7-zip.org", target: self, action: #selector(homePageClicked)), rc, 110)
        form.add(DialogKit.button(Lang.text(401, "OK"), target: self, action: #selector(okClicked), key: "\r"), rc, 1)

        RcPlace.install(form, in: window, size: rc.size, parent: parent)
    }

    /// IDT_ABOUT_VERSION's text: MY_VERSION_CPU with "7-Zip <upstream>" replaced by the port's
    /// name, "7-Zip 26.03 for macOS 1.0.0 (arm64)" (pub3).
    static var versionText: String {
        let engine = SZBenchmark.versionWithCPUText
        let prefix = "7-Zip \(PortVersion.upstream)"
        guard engine.hasPrefix(prefix) else { return PortVersion.displayName }
        return PortVersion.displayName + engine.dropFirst(prefix.count)
    }

    @objc private func homePageClicked() {
        if let url = URL(string: Self.homePageURL) { NSWorkspace.shared.open(url) }
    }

    @objc private func okClicked() { NSApp.stopModal() }

    /// F1 / Help in the dialog = CAboutDialog::OnHelp (AboutDialog.cpp:55-58): the start page.
    static func isHelpKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else { return false }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        return mods.isEmpty && (Int(scalar.value) == NSF1FunctionKey || Int(scalar.value) == NSHelpFunctionKey)
    }

    private func installHelpKeyMonitor() -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, Self.isHelpKey(event) else { return event }
            Help.show(topic: Help.start)                                   // kHelpTopic "start.htm"
            return nil
        }
    }

    /// OnInit (:32-53): the codecs error message, when there is one, is shown first.
    static func show(parent: NSWindow? = nil) {
        do {
            try SZCodecs.loadCodecs()
        } catch {
            // AboutDialog.cpp:40: MessageBoxW(GetParent(), s, "7-Zip", MB_ICONERROR).
            WinMessageBox.run(error.localizedDescription, icon: .error, owner: parent)
        }
        let dialog = AboutDialog(parent: parent)
        let monitor = dialog.installHelpKeyMonitor()
        DialogKit.runModal(for: dialog.window)
        if let monitor { NSEvent.removeMonitor(monitor) }
        dialog.window.orderOut(nil)
    }
}

/// ShowHelpWindow(topic) (FileManager/HelpUtils.cpp): Windows opens `7-zip.chm::/<topic>` in
/// HtmlHelp. The port bundles the same pages, unpacked from that very `7-zip.chm` by
/// `Mac/scripts/fetch-assets.sh` (pinned hash), at `<bundle>/Contents/Resources/Help/`, and opens
/// the topic's page in the default web browser (01-fm-feature-inventory.md 9 #17, opsgaps).
///
/// Why a browser and not an Apple Help Book: a help book needs its own `.help` bundle, an
/// `hiutil` index rebuilt on every content change, and Help Viewer's registration cache, which is
/// keyed by bundle identifier and goes stale for ad-hoc signed and renamed copies (the test
/// apps); the CHM pages are plain HTML 3.2 that any browser renders, anchors included. Opening a
/// `file://` URL through the browser application (rather than `NSWorkspace.open(url)`, which
/// hands a `.htm` to whatever owns that type and drops the `#anchor`) keeps the `kHelpTopic`
/// fragment, e.g. `fm/options.htm#editor`.
enum Help {

    // Every kHelpTopic of the Windows sources, verbatim (CHM paths are case-insensitive, so the
    // `FM/` spellings resolve to the bundled lower-case `fm/` folder).
    static let start = "start.htm"                                // AboutDialog.cpp:25
    static let contents = "FM/index.htm"                          // kFMHelpTopic, MyLoadMenu.cpp:38 (IDM_HELP_CONTENTS 960)
    static let benchmark = "fm/benchmark.htm"                     // BenchmarkDialog.cpp:37
    static let tempFiles = "fm/temp.htm"                          // BrowseDialog2.cpp:979
    static let options = "fm/options.htm"
    static let add = "fm/plugins/7-zip/add.htm"                   // CompressDialog.cpp:1254
    static let addOptions = "fm/plugins/7-zip/add.htm#options"    // kHelpTopic_Options, CompressDialog.cpp:1255
    static let extract = "fm/plugins/7-zip/extract.htm"           // ExtractDialog.cpp:414
    static let optionsSystem = "FM/options.htm#system"            // kSystemTopic, SystemPage.cpp:39
    static let optionsMenu = "fm/options.htm#sevenZip"            // kMenuTopic, MenuPage.cpp:41
    static let optionsFolders = "fm/options.htm#folders"          // kFoldersTopic, FoldersPage.cpp
    static let optionsEditor = "FM/options.htm#editor"            // kEditTopic, EditPage.cpp:28
    static let optionsSettings = "FM/options.htm#settings"        // kSettingsTopic, SettingsPage.cpp:45
    static let optionsLanguage = "fm/options.htm#language"        // kLangTopic, LangPage.cpp:28
    static let plugins = "fm/plugins/index.htm"

    /// Where the 7zFM pages live on the web, used only when a build carries no bundled help.
    private static let onlineBase = "https://documentation.help/7-Zip/"

    /// Test hook: replaces the browser launch. Main thread only.
    static var opener: ((URL) -> Void)?

    /// The URL `show(topic:)` opens: the bundled page (with its anchor) or the online fallback.
    static func url(for topic: String) -> URL? {
        if let local = bundledURL(for: topic) { return local }
        // The site keeps the same file names but no directories.
        let name = (topic as NSString).lastPathComponent
        let anchorless = name.components(separatedBy: "#").first ?? name
        return URL(string: onlineBase + anchorless)
    }

    /// Opens the topic in the bundled help, else on the documentation site.
    static func show(topic: String) {
        guard let url = url(for: topic) else { NSSound.beep(); return }
        if let opener { opener(url); return }
        open(url)
    }

    /// `<bundle>/Contents/Resources/Help/<topic>` when the documentation was bundled.
    static func bundledURL(for topic: String, in bundle: Bundle = .main) -> URL? {
        guard let resources = bundle.resourceURL else { return nil }
        let parts = topic.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        // HtmlHelp is case-insensitive; the bundled tree is the CHM's own lower-case names.
        let page = String(parts.first ?? "").lowercased()
        guard !page.isEmpty, !page.contains("..") else { return nil }
        let candidate = resources.appendingPathComponent("Help").appendingPathComponent(page).absoluteURL
        guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        if parts.count > 1, !parts[1].isEmpty,
           var components = URLComponents(url: candidate.absoluteURL, resolvingAgainstBaseURL: true) {
            components.fragment = String(parts[1])
            return components.url ?? candidate
        }
        return candidate
    }

    /// The default browser keeps a file URL's fragment; Launch Services' per-type handler for
    /// `.htm` may not, so ask for the `https` handler and give the URL to it.
    private static func open(_ url: URL) {
        let workspace = NSWorkspace.shared
        guard url.isFileURL, let probe = URL(string: "https://www.7-zip.org/"),
              let browser = workspace.urlForApplication(toOpen: probe) else {
            workspace.open(url)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.open([url], withApplicationAt: browser, configuration: configuration) { _, error in
            if error != nil { DispatchQueue.main.async { NSWorkspace.shared.open(url) } }
        }
    }
}
