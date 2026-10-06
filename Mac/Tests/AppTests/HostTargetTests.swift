// HostTargetTests.swift -- the properties of the app-hosted target itself, asserted rather than
// assumed: an app-hosted test that quietly writes the developer's preferences, or that runs off the
// main thread, would be worse than no test at all.

import AppKit
import SevenZipKit
import XCTest
@testable import SevenZipAppHost

final class HostTargetTests: AppHostTestCase {

    /// The host app is a real 7-Zip process: it saves `FM.Position`, `FM.Columns.<type>`,
    /// `FM.Panels.splitterPos` and the rest when it quits, and these tests change those values on
    /// purpose. So its settings domain must be a throwaway plist, never
    /// `com.yrambler2001.7zip` (`AppHostTestCase.isolatedFromRealSettings`).
    func testSettingsAreIsolatedFromTheRealDomain() {
        XCTAssertTrue(SZSettings.usesOverrideSuite, "the app is using its real preferences domain")
        let domain = SZSettings.applicationID
        XCTAssertNotEqual(domain, "com.yrambler2001.7zip")
        XCTAssertTrue(domain.hasPrefix("/"), "the domain should be a plist path, not a name: \(domain)")
        // A write really does land in that file and not in the real domain.
        let key = "FM.FastUiIsolationProbe"
        SZSettings.setString("1", forKey: key)
        SZSettings.synchronize()
        defer { SZSettings.setString(nil, forKey: key) }   // nil removes
        let plist = (try? Data(contentsOf: URL(fileURLWithPath: domain)))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) }
        XCTAssertEqual((plist as? [String: Any])?[key] as? String, "1",
                       "the write did not reach \(domain)")
    }

    /// XCTest runs these cases on the main thread, which is the only thread any of the app's
    /// windows, panels and dialogs may be touched from.
    func testCasesRunOnTheMainThread() {
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertNotNil(NSApp.mainMenu, "the host app finished launching before the tests ran")
    }

    /// The three test-only app copies must claim **nothing** on this machine. macOS registers an app
    /// bundle with Launch Services the moment it is launched, and `NSWorkspace.open(URL)` hands a
    /// `sevenzip://` URL to whichever registered bundle owns the scheme -- with the probes registered
    /// that turned out to be a probe, and eleven UI tests of another scope that used an unaimed
    /// `NSWorkspace.open` were answered by it and failed (`ai/api/resetcmd.md` section 5). So the
    /// copies use `Mac/Tests/AppVariants/Info.plist`, which is `Mac/App/Info.plist` with the URL
    /// schemes, the 40 document types, their 23 type declarations and the five Services removed --
    /// and nothing else. This fails if either half drifts.
    func testTheVariantInfoPlistMatchesTheApps() throws {
        let root = try XCTUnwrap(TestPaths.repoRoot, "the worktree root was not found")
        let app = try plist(root + "/Mac/App/Info.plist")
        let variant = try plist(root + "/Mac/Tests/AppVariants/Info.plist")
        let claims = ["CFBundleURLTypes", "CFBundleDocumentTypes", "NSServices",
                      "UTImportedTypeDeclarations", "UTExportedTypeDeclarations"]
        for key in claims {
            XCTAssertNil(variant[key], "a test-only copy of the app must not declare \(key)")
        }
        // The running host app is one of those copies, so the claims are gone from *this* process too.
        for key in claims {
            XCTAssertNil(Bundle.main.infoDictionary?[key],
                         "the host app declares \(key); it is not built from the variant plist")
        }
        let expected = Set(app.keys).subtracting(claims)
        XCTAssertEqual(Set(variant.keys), expected,
                       "regenerate with: python3 - <<'PY'  (see the comment in "
                       + "Mac/Tests/AppVariants/Info.plist; strip \(claims) from Mac/App/Info.plist)")
        for key in expected where !(variant[key] as? String ?? "").hasPrefix("$(") {
            XCTAssertEqual(String(describing: variant[key] ?? ""), String(describing: app[key] ?? ""),
                           "\(key) drifted between Mac/App/Info.plist and the variant plist")
        }
    }

    private func plist(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let any = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try XCTUnwrap(any as? [String: Any], "not a plist dictionary: \(path)")
    }

    /// The fixtures and the screenshot directory resolve, so the sweeps have something to work with
    /// and their PNGs land in the report directory rather than in a temporary folder.
    func testPathsResolve() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: TestPaths.fixture("test.7z")),
                      "fixtures at \(TestPaths.fixtures)")
        XCTAssertNotNil(TestPaths.repoRoot, "the worktree root was not found")
        XCTAssertTrue(TestPaths.screenshots.hasSuffix("Mac/build/screenshots"),
                      "screenshots go to \(TestPaths.screenshots)")
    }
}
