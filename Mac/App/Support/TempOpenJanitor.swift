// TempOpenJanitor.swift -- the launch-time sweep of stale `7zO*` / `7zE*` temp folders.
//
// **Not Windows parity, an improvement documented as such** (01 §1.1 "Startup actions", §9 #11,
// PROGRESS 186 / 724): `DeleteOldTempFiles()` (PanelItemOpen.cpp:1815) exists in 7zFM but has no
// caller, so a 7zFM that crashed or was killed leaves its `7zO…` (open / edit) and `7zE…` (drag,
// e-mail) folders in %TEMP% for ever; only Tools > Delete Temporary Files removes them by hand.
//
// The sweep is deliberately conservative, because a folder another live process still uses must
// never go:
// - it does nothing while any other 7-Zip process of this bundle is running (`open -n` starts a
//   second one, and they share the temp folder);
// - it only takes folders whose own modification date is older than `minimumAge`, so a folder made
//   moments ago by a process that is starting up at the same time is left alone;
// - it removes only through `SZTempOpen.removeTemporaryDirectory(atPath:)`, which refuses anything
//   outside the temp folder or without one of the two prefixes;
// - it is off under the test-support contract (`SZ_TEST_SUPPORT`), whose instances each have their
//   own temp folder and are reset by `sevenzip://test/reset` instead.

import Foundation
import AppKit
import SevenZipKit

enum TempOpenJanitor {

    /// A folder younger than this is never swept.
    static let minimumAge: TimeInterval = 60 * 60
    /// The compress-and-email folders (`7zE-<uuid>`, `CompressCommands`) hold an attachment a mail
    /// draft may still reference, so they keep `purgeStaleEmailDirectories`' one-day rule.
    static let emailMinimumAge: TimeInterval = 24 * 60 * 60

    /// Starts the sweep on a utility queue; returns at once.
    static func sweepAtLaunch() {
        guard !TestSupport.isEnabled, !anotherInstanceIsRunning() else { return }
        DispatchQueue.global(qos: .utility).async {
            for path in staleDirectories(SZTempOpen.temporaryDirectories(), now: Date(),
                                         modificationDate: modificationDate(of:)) {
                SZTempOpen.removeTemporaryDirectory(atPath: path)
            }
        }
    }

    /// The candidates that are old enough. Split out, with the clock and the file system passed
    /// in, so a unit test can check the rule without touching the real temp folder.
    static func staleDirectories(_ candidates: [String], now: Date,
                                 modificationDate: (String) -> Date?) -> [String] {
        candidates.filter { path in
            let name = (path as NSString).lastPathComponent
            guard name.hasPrefix(SZTempOpen.openDirectoryPrefix)
                    || name.hasPrefix(SZTempOpen.extractDirectoryPrefix) else { return false }
            guard let date = modificationDate(path) else { return false }
            let age = name.hasPrefix(SZTempOpen.extractDirectoryPrefix + "-") ? emailMinimumAge : minimumAge
            return now.timeIntervalSince(date) >= age
        }
    }

    private static func modificationDate(of path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private static func anotherInstanceIsRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return true }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.processIdentifier != me }
    }
}
