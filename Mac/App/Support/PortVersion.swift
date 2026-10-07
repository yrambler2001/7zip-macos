// PortVersion.swift -- the port's version as the user sees it (pub3, ai/reports/pub3.md).
//
// Two numbers: the 7-Zip engine the app is built on (upstream, "26.03", C/7zVersion.h) and the
// macOS port's own semantic version ("1.0.0", Mac/VERSION -> MARKETING_VERSION ->
// CFBundleShortVersionString). Together: "7-Zip 26.03 for macOS 1.0.0", the name in the About box,
// the update check, the disk image and the release notes.

import Foundation
import SevenZipKit

enum PortVersion {

    /// The port's version, CFBundleShortVersionString ("1.0.0").
    static var port: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// The build number, CFBundleVersion (the commit count the release was built from).
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    /// The engine's version, MY_VERSION of C/7zVersion.h ("26.03").
    static var upstream: String { SZEngineVersionString() }

    /// "7-Zip 26.03 for macOS 1.0.0".
    static func displayName(upstream: String = upstream, port: String = port) -> String {
        "7-Zip \(upstream) for macOS \(port)"
    }

    static var displayName: String { displayName() }
}
