// FirstLaunchIntegration.swift -- macOS addition (theme scope, reports/theme.md §3): on the first
// launch of an *installed* copy, switch the Finder integration on, once.
//
// Windows' installer registers 7-zip.dll as the Explorer context-menu handler, so a fresh 7zFM
// shows Options > 7-Zip > "Integrate 7-Zip to shell context menu" (IDX_SYSTEM_INTEGRATE_TO_MENU
// 2301) and "Cascaded context menu" (IDX_SYSTEM_CASCADED_MENU 2302) ticked (01b §4.13, 03 §1.3).
// A Mac app has no installer: its Finder Sync extension starts out not elected, so the first
// launch does what the installer would have done:
//
//   * elects this copy's Finder Sync extension and its two Quick Actions "use" through PlugInKit
//     (`FinderExtensionControl.setEnabled(true)`, which first removes every other copy's
//     registration, then `-a` / `-e use` for each Quick Action identifier);
//   * stores `Options.CascadedMenu` = true (its default already, written so the extension's
//     snapshot carries it).
//
// Once only. The marker `FM.FirstLaunchIntegration` is written whether or not PlugInKit agreed,
// so a user who later unticks either box is never overridden. No message box at launch: when the
// election fails the Options checkbox simply shows the real PlugInKit state, which is the truth.
//
// When it runs -- decided by `decide(_:)`, a pure function the app-hosted tests drive:
//   * never in a test instance: SZ_TEST_SUPPORT set, an XCTest bundle loaded, or a bundle id that is
//     not the real app's (`com.yrambler2001.7zip-host`, `-p1`, `-p2`, ...);
//   * never when the copy has no FinderSync.appex;
//   * only from an installed location: the app bundle inside `/Applications` or `~/Applications`
//     (subfolders included). A copy run from a mounted disk image (`/Volumes/...`), from App
//     Translocation (`/private/var/folders/.../AppTranslocation/...`), from a build folder
//     (`Mac/build`, DerivedData) or from Downloads *defers*: nothing is written, and the first
//     launch of the copy the user installs does it;
//   * the marker is already there, or `Options.CascadedMenu` was already written (the user has
//     been through Options > 7-Zip before): the marker is set and nothing else is touched.

import Foundation

enum FirstLaunchIntegration {

    /// The marker: present once the first-launch decision was carried out (or found unnecessary).
    static let markerKey = "FM.FirstLaunchIntegration"
    static let realBundleIdentifier = "com.yrambler2001.7zip"
    static let quickActionIdentifiers = ["com.yrambler2001.7zip.QuickActionExtract",
                                         "com.yrambler2001.7zip.QuickActionCompress"]

    struct Environment {
        var testSupport: Bool
        var xctestLoaded: Bool
        var bundleIdentifier: String?
        var bundlePath: String
        var homeDirectory: String
        var hasEmbeddedAppex: Bool
        var markerSet: Bool
        var cascadedDefined: Bool
    }

    enum Decision: Equatable {
        /// Never for this copy (a test instance, no extension).
        case skip(String)
        /// Not an installed location yet: try again on a later launch.
        case deferred(String)
        /// Someone already decided (the marker, or the user's own Options choice): set the marker only.
        case alreadyDone
        /// Turn the integration and the cascaded menu on, then set the marker.
        case enable
    }

    /// The bundle path is inside /Applications or ~/Applications (after resolving symlinks).
    static func isInstalledLocation(_ bundlePath: String, home: String) -> Bool {
        let path = FinderExtensionControl.canonical(bundlePath)
        let roots = ["/Applications", FinderExtensionControl.canonical((home as NSString).appendingPathComponent("Applications"))]
        return roots.contains { root in path.hasPrefix(root + "/") }
            && !path.contains("/AppTranslocation/")
    }

    static func decide(_ env: Environment) -> Decision {
        if env.testSupport { return .skip("test support (SZ_TEST_SUPPORT)") }
        if env.xctestLoaded { return .skip("running under XCTest") }
        guard env.bundleIdentifier == realBundleIdentifier else {
            return .skip("bundle id \(env.bundleIdentifier ?? "-") is not the app's")
        }
        guard env.hasEmbeddedAppex else { return .skip("no Finder extension in this copy") }
        if env.markerSet { return .alreadyDone }
        guard isInstalledLocation(env.bundlePath, home: env.homeDirectory) else {
            return .deferred("not in /Applications or ~/Applications: \(env.bundlePath)")
        }
        if env.cascadedDefined { return .alreadyDone }
        return .enable
    }

    static func currentEnvironment() -> Environment {
        Environment(testSupport: TestSupport.isEnabled,
                    xctestLoaded: NSClassFromString("XCTestCase") != nil,
                    bundleIdentifier: Bundle.main.bundleIdentifier,
                    bundlePath: Bundle.main.bundlePath,
                    homeDirectory: NSHomeDirectory(),
                    hasEmbeddedAppex: FinderExtensionControl.embeddedAppexPath != nil,
                    markerSet: Settings.hasKey(markerKey),
                    cascadedDefined: Settings.cascadedMenu != nil)
    }

    /// The settings half, synchronous (so `FinderSettingsBridge.push()` right after it carries the
    /// cascaded value); the PlugInKit half runs through `elect`, off the main thread in the app.
    @discardableResult
    static func run(_ env: Environment, elect: @escaping () -> Void) -> Decision {
        let decision = decide(env)
        switch decision {
        case .skip, .deferred:
            break
        case .alreadyDone:
            Settings.setBool(true, markerKey)
        case .enable:
            Settings.cascadedMenu = true
            Settings.setBool(true, markerKey)
            Settings.synchronize()
            elect()
        }
        return decision
    }

    /// The PlugInKit half: this copy's Finder Sync extension on (claimed), then each Quick Action
    /// registered from this copy and elected use. Blocking; never reports an error.
    static func electAll(embeddedPath: String?) {
        guard let embeddedPath else { return }
        FinderExtensionControl.setEnabled(true, embeddedPath: embeddedPath)
        let plugIns = (embeddedPath as NSString).deletingLastPathComponent
        for identifier in quickActionIdentifiers {
            let name = identifier.components(separatedBy: ".").last ?? identifier
            let appex = (plugIns as NSString).appendingPathComponent(name + ".appex")
            guard FileManager.default.fileExists(atPath: appex) else { continue }
            let mine = FinderExtensionControl.canonical(appex)
            let others = FinderExtensionControl.parse(
                FinderExtensionControl.runner(["-m", "-D", "-A", "-v", "-i", identifier]).output, identifier: identifier)
            for registration in others where FinderExtensionControl.canonical(registration.path) != mine {
                _ = FinderExtensionControl.runner(["-r", registration.path])
            }
            _ = FinderExtensionControl.runner(["-a", appex])
            _ = FinderExtensionControl.runner(["-e", "use", "-i", identifier])
        }
    }

    /// At launch (FinderIntegration.install's didFinishLaunching block).
    static func runIfNeeded() {
        let env = currentEnvironment()
        let decision = run(env) {
            let embedded = FinderExtensionControl.embeddedAppexPath
            FinderExtensionControl.launchQueue.async { electAll(embeddedPath: embedded) }
        }
        if case .deferred(let why) = decision { NSLog("7-Zip: first-launch Finder integration deferred: %@", why) }
    }
}
