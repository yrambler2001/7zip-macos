// ExtensionHandoff.swift -- how the sandboxed Finder Sync extension and the two Quick Actions hand
// a `sevenzip://` command to the app (03-shell-integration-inventory.md section 6.4 variant (b)).
//
// finderfix: the URL is **aimed** at the app that contains the extension
// (`NSWorkspace.open(_:withApplicationAt:)`), so it cannot be answered by another registered copy of
// 7-Zip -- a Debug build in DerivedData, a mounted DMG, a test copy -- which is what a plain
// `NSWorkspace.open(URL)` leaves to Launch Services' choice of scheme handler. Only when the aimed
// open fails does it fall back to the scheme.
//
// Every step is logged under the subsystem `com.yrambler2001.7zip` with public outcomes, so a
// "nothing happened" report can be diagnosed with
// `log stream --predicate 'subsystem == "com.yrambler2001.7zip"'`. Paths stay private.
//
// Compiled into the app and the three appexes (AppKit only, no bridge). The app itself never
// calls it.

import AppKit
import os

enum ExtensionHandoff {

    static let subsystem = "com.yrambler2001.7zip"

    /// The opener, replaceable by a test. Arguments: the URL, the app to aim at, the completion
    /// (`nil` error = delivered).
    typealias AimedOpener = (URL, URL, @escaping (Error?) -> Void) -> Void
    /// The unaimed fallback, replaceable by a test. Returns `NSWorkspace.open`'s Bool.
    typealias SchemeOpener = (URL) -> Bool

    static var aimedOpener: AimedOpener = { url, app, completion in
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration) { _, error in
            completion(error)
        }
    }

    static var schemeOpener: SchemeOpener = { NSWorkspace.shared.open($0) }

    /// How a hand-off went, for the log and the tests.
    enum Outcome: Equatable {
        case aimed
        case scheme
        case failed
    }

    /// Hands `url` to the app at `appURL` (the containing app by default). `completion` runs on
    /// the main queue once the system has answered, so a Quick Action can complete its request
    /// only after the hand-off, not before.
    static func send(_ url: URL, to appURL: URL = SevenZipBundle.containingAppURL,
                     log: Logger, completion: ((Outcome) -> Void)? = nil) {
        log.log("handing \(url.path, privacy: .public) to \(appURL.lastPathComponent, privacy: .public)")
        aimedOpener(url, appURL) { error in
            DispatchQueue.main.async {
                let outcome: Outcome
                if let error {
                    log.error("aimed open failed: \(error.localizedDescription, privacy: .public); trying the URL scheme")
                    outcome = schemeOpener(url) ? .scheme : .failed
                } else {
                    outcome = .aimed
                }
                if outcome == .failed {
                    log.fault("hand-off failed: no application took the sevenzip URL")
                } else {
                    log.log("hand-off delivered (\(outcome == .aimed ? "aimed" : "scheme", privacy: .public))")
                }
                completion?(outcome)
            }
        }
    }

    /// Asks the app to show the error box for `failure` -- an extension has no window to show one
    /// on, and doing nothing is exactly the bug this file exists for.
    static func report(_ failure: CommandURL.ExtensionFailure, log: Logger,
                       completion: ((Outcome) -> Void)? = nil) {
        log.error("reporting failure \(failure.rawValue, privacy: .public) to the app")
        guard let url = CommandURL.errorURL(failure) else {
            completion?(.failed)
            return
        }
        send(url, log: log, completion: completion)
    }
}
