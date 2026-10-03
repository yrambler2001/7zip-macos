// OptGapsTests.swift -- the Options / Compress / dialog backlog closed by `mac/optgaps`, asserted in
// the app's own process (`SevenZipAppTests`, see AppHostTestCase).

import AppKit
import SevenZipKit
import XCTest
@testable import SevenZipAppHost

final class OptGapsTests: AppHostTestCase {

    override var screenshotPrefix: String { "optgaps" }

    // MARK: - Options pages fit the window (requests.md, `fastui` -> `options`)

    /// Languages with the longest Options labels (measured by `fastui`: de, ru, ja, ar, he) plus
    /// built-in English.
    private let layoutLanguages = ["-", "de", "ru", "ja", "ar", "he", "fr", "uk"]

    func testOptionsPagesFitTheirWindow() {
        continueAfterFailure = true
        let controller = OptionsWindowController.shared
        guard let window = controller.window else { return XCTFail("the Options window has no window") }
        var problems: [String] = []
        for code in layoutLanguages {
            useLanguage(code)
            let appeared = ModalProbe.present({ OptionsWindowController.showOptions() }) { _ in }
            XCTAssertTrue(appeared, "the Options window did not come up in '\(code)'")
            guard let content = window.contentView, let tabs = Self.firstTabView(in: content) else {
                return XCTFail("no NSTabView in the Options window")
            }
            for index in 0..<tabs.numberOfTabViewItems {
                tabs.selectTabViewItem(at: index)
                content.layoutSubtreeIfNeeded()
                let fitting = content.fittingSize
                let bounds = content.bounds.size
                let name = "\(code) page \(index + 1) \(tabs.tabViewItems[index].label)"
                print(String(format: "OPTFIT | %@ | needs %.0fx%.0f | has %.0fx%.0f", name,
                             fitting.width, fitting.height, bounds.width, bounds.height))
                if fitting.width > bounds.width + 1 || fitting.height > bounds.height + 1 {
                    var culprits: [String] = []
                    if let page = tabs.tabViewItems[index].view {
                        Self.collectWide(page, limit: page.bounds.width, path: "", into: &culprits)
                    }
                    problems.append(String(format: "%@ needs %.0fx%.0f in %.0fx%.0f", name,
                                           fitting.width, fitting.height, bounds.width, bounds.height)
                                    + culprits.map { "\n    " + $0 }.joined())
                }
            }
            ModalProbe.close(window)
        }
        XCTAssertTrue(problems.isEmpty, "Options pages that want more than the window:\n"
                      + problems.joined(separator: "\n"))
    }

    // MARK: - helpers

    static func firstTabView(in view: NSView) -> NSTabView? {
        if let tabs = view as? NSTabView { return tabs }
        for child in view.subviews {
            if let found = firstTabView(in: child) { return found }
        }
        return nil
    }

    /// The deepest views whose own fitting width exceeds `limit`.
    static func collectWide(_ view: NSView, limit: CGFloat, path: String, into out: inout [String]) {
        let name = path + "/" + String(describing: type(of: view))
        let wideChildren = view.subviews.filter { $0.fittingSize.width > limit + 1 }
        if wideChildren.isEmpty {
            if view.fittingSize.width > limit + 1 {
                var text = ""
                if let field = view as? NSTextField { text = " '" + field.stringValue.prefix(60) + "'" }
                if let button = view as? NSButton { text = " '" + button.title.prefix(60) + "'" }
                out.append(String(format: "%@ %.0f%@", name, view.fittingSize.width, text))
            }
            return
        }
        for child in wideChildren { collectWide(child, limit: limit, path: name, into: &out) }
    }
}
