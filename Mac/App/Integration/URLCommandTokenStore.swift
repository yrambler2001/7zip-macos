// URLCommandTokenStore.swift -- the app's side of the URL secret (sec113, `URLCommandPolicy.swift`).
//
// The secret is 256 random bits (`SecRandomCopyBytes`), stored as 64 hex digits under
// `Integration.URLToken` in the app's settings domain. That is where the sandboxed extensions can
// read it (the read-only shared-preference exception on `com.yrambler2001.7zip`), and the app also
// pushes it with the settings snapshot into each extension's container (`FinderSettingsBridge`).
// Web pages and sandboxed apps can read neither.
//
// Lifetime:
//  * created at launch (`FinderIntegration.install`, before any URL is handled) when missing, so
//    the first launch of an installed copy -- including one started by an extension's URL --
//    already has it;
//  * never rotated otherwise;
//  * Options > macOS > Reset All Settings empties the domain, so the relaunched instance creates a
//    new one and pushes it to the extensions; a URL with the old one is refused.
//
// An extension that finds no secret (the app has never run) does not send its command: it sends
// `sevenzip:///error?code=notready`, which launches the app (creating the secret) and tells the
// user to choose the command again.

import Foundation
import Security
import SevenZipKit

enum URLCommandTokenStore {

    /// `SZ_URL_TOKEN`: with `SZ_TEST_SUPPORT=1` only, a fixed secret the XCUITest harness sets
    /// at launch, because the sandboxed test runner cannot read the app's domain. Whoever sets a
    /// launch environment already runs code locally, so this opens nothing to a URL sender.
    static let testEnvironmentVariable = "SZ_URL_TOKEN"

    /// The secret, nil when there is none or it is malformed.
    static var current: String? {
        if CommandURL.testSupportEnabled,
           let fixed = CommandURL.environmentValue(testEnvironmentVariable),
           URLCommandToken.isWellFormed(fixed) {
            return fixed
        }
        let value = Settings.string(URLCommandToken.settingsKey)
        return URLCommandToken.isWellFormed(value) ? value : nil
    }

    /// The secret, created now when there is none. Nil only when the random source failed or
    /// settings writes are suspended (the instance that is quitting after a reset).
    @discardableResult
    static func ensure() -> String? {
        if let token = current { return token }
        guard let token = generate() else { return nil }
        Settings.setString(token, URLCommandToken.settingsKey)
        // Written through to disk at once, so an extension reading the domain sees it.
        SZSettings.synchronize()
        return current
    }

    /// 256 bits from the system's CSPRNG, as lowercase hex.
    static func generate() -> String? {
        var bytes = [UInt8](repeating: 0, count: URLCommandToken.byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return URLCommandToken.hex(bytes)
    }

    /// Whether `presented` is the secret (constant time).
    static func accepts(_ presented: String?) -> Bool {
        URLCommandToken.matches(presented, expected: current)
    }
}
