// AboutDialog.swift -- Help > About 7-Zip (IDM_ABOUT 961), CAboutDialog / IDD_ABOUT 2900,
// plus the Help topic opener the whole app uses.
// Parity: 01b-fm-dialogs-settings.md 4.1, 01-fm-feature-inventory.md 2.6, 9 #17.

import AppKit
import SevenZipKit

final class AboutDialog: NSObject {

    private static let homePageURL = "https://www.7-zip.org/"     // kHomePageURL

    private let window: NSWindow

    private init(parent: NSWindow?) {
        window = DialogKit.window(title: Lang.text(2900, "About 7-Zip"), resizable: false)
        super.init()

        // IDI_LOGO 100, 32 x 32, SS_REALSIZEIMAGE
        let logo = NSImageView()
        logo.image = NSApp.applicationIconImage
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.translatesAutoresizingMaskIntoConstraints = false
        logo.addConstraint(NSLayoutConstraint(item: logo, attribute: .width, relatedBy: .equal,
                                              toItem: nil, attribute: .notAnAttribute, multiplier: 1, constant: 64))
        logo.addConstraint(NSLayoutConstraint(item: logo, attribute: .height, relatedBy: .equal,
                                              toItem: nil, attribute: .notAnAttribute, multiplier: 1, constant: 64))

        // IDT_ABOUT_VERSION 101 = "7-Zip <MY_VERSION> (<cpu>)"; IDT_ABOUT_DATE 102 = MY_DATE
        let version = DialogKit.label(SZBenchmark.versionWithCPUText, bold: true)
        let date = DialogKit.label(SZBenchmark.engineDateText)
        // static LTEXT MY_COPYRIGHT
        let copyright = DialogKit.label(Self.copyrightLine)
        // IDT_ABOUT_INFO 2901 (the only localized item, kLangIDs)
        let info = DialogKit.label(Lang.text(2901, "7-Zip is free software"))
        info.maximumNumberOfLines = 4
        info.preferredMaxLayoutWidth = 320

        // IDB_ABOUT_HOMEPAGE 110 "www.7-zip.org"
        let homePage = DialogKit.button("www.7-zip.org", target: self, action: #selector(homePageClicked))
        let help = DialogKit.button(Lang.text(409, "Help"), target: self, action: #selector(helpClicked))
        let ok = DialogKit.button(Lang.text(401, "OK"), target: self, action: #selector(okClicked), key: "\r")
        let buttons = NSStackView(views: [help, NSView(), homePage, ok])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let text = NSStackView(views: [version, date, copyright, info])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 6

        let top = NSStackView(views: [logo, text])
        top.orientation = .horizontal
        top.alignment = .top
        top.spacing = 14

        let stack = NSStackView(views: [top, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.addConstraint(NSLayoutConstraint(item: buttons, attribute: .width, relatedBy: .equal,
                                               toItem: stack, attribute: .width, multiplier: 1, constant: 0))
        DialogKit.install(stack, in: window, parent: parent, minimumWidth: 420)
    }

    /// SZEngineCopyrightString() is `MY_COPYRIGHT " : " MY_DATE`; the .rc shows only the
    /// copyright on its own line (the date is IDT_ABOUT_DATE).
    private static var copyrightLine: String {
        let full = SZEngineCopyrightString()
        if let range = full.range(of: " : ") { return String(full[full.startIndex..<range.lowerBound]) }
        return full
    }

    @objc private func homePageClicked() {
        if let url = URL(string: Self.homePageURL) { NSWorkspace.shared.open(url) }
    }

    @objc private func helpClicked() { Help.show(topic: Help.start) }
    @objc private func okClicked() { NSApp.stopModal() }

    /// OnInit (:32-53): the codecs error message, when there is one, is shown first.
    static func show(parent: NSWindow? = nil) {
        do {
            try SZCodecs.loadCodecs()
        } catch {
            let alert = NSAlert()
            alert.messageText = "7-Zip"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.addButton(withTitle: Lang.text(401, "OK"))
            alert.runModal()
        }
        let dialog = AboutDialog(parent: parent)
        NSApp.runModal(for: dialog.window)
        dialog.window.orderOut(nil)
    }
}

/// ShowHelpWindow(topic) (FileManager/HelpUtils.cpp): Windows opens `7-zip.chm::/<topic>`.
/// On macOS the same topic paths are looked up in the bundled HTML help
/// (`<bundle>/Contents/Resources/Help/<topic>`) and, when that is missing, on the 7-Zip
/// documentation site (01-fm-feature-inventory.md 9 #17).
enum Help {

    static let start = "start.htm"                       // kHelpTopic of About
    static let contents = "FM/index.htm"                 // kFMHelpTopic (F1)
    static let benchmark = "fm/benchmark.htm"
    static let tempFiles = "fm/temp.htm"
    static let options = "fm/options.htm"
    static let add = "fm/plugins/7-zip/add.htm"
    static let extract = "fm/plugins/7-zip/extract.htm"

    private static let onlineBase = "https://documentation.help/7-Zip/"

    /// Opens the topic in the bundled help, else in the default browser.
    static func show(topic: String) {
        if let local = bundledURL(for: topic) {
            NSWorkspace.shared.open(local)
            return
        }
        // The site keeps the same file names but no directories; fall back to the index for
        // a topic that is not a plain page.
        let name = (topic as NSString).lastPathComponent
        let anchorless = name.components(separatedBy: "#").first ?? name
        if let url = URL(string: onlineBase + anchorless) {
            NSWorkspace.shared.open(url)
        }
    }

    /// `<bundle>/Contents/Resources/Help/<topic>` when the documentation was bundled.
    static func bundledURL(for topic: String) -> URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let page = topic.components(separatedBy: "#").first ?? topic
        let candidate = resources.appendingPathComponent("Help").appendingPathComponent(page)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        if let anchor = topic.components(separatedBy: "#").dropFirst().first,
           let url = URL(string: candidate.absoluteString + "#" + anchor) {
            return url
        }
        return candidate
    }
}
