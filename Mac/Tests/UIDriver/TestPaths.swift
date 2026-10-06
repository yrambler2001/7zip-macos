// TestPaths.swift -- where the UI tests find the repository, the fixture archives, the real home
// directory and the directory screenshots go to. Nothing here touches the app.
//
// Xcode's XCTRunner.app is app-sandboxed (read-only access to "/"), so inside a UI test
// `NSHomeDirectory()` is the runner's container and writing into the worktree is denied. Use
// `realHome` for the user's home directory, and `SevenZipApp.screenshot` (an XCTAttachment that
// Mac/scripts/test.sh exports into `screenshots`) instead of writing PNGs directly.
//
// Resolution order (first hit wins):
//   1. SEVENZIP_REPO_ROOT / SEVENZIP_SCREENSHOT_DIR / SEVENZIP_FIXTURES environment variables
//      (test.sh / verify.sh pass them as TEST_RUNNER_SEVENZIP_* so they reach the runner),
//   2. walking up from the test bundle until a directory containing `Mac/project.yml` is found,
//   3. the Fixtures folder copied into the test bundle / the container's temp directory.

import Foundation
import XCTest

public enum TestPaths {

    /// Repository (or worktree) root: the directory that contains `Mac/`.
    public static let repoRoot: String? = {
        if let env = ProcessInfo.processInfo.environment["SEVENZIP_REPO_ROOT"], isRoot(env) { return env }
        var url = Bundle(for: BundleToken.self).bundleURL
        for _ in 0..<12 {
            url = url.deletingLastPathComponent()
            if url.path == "/" { break }
            if isRoot(url.path) { return url.path }
        }
        return nil
    }()

    /// `Mac/Tests/Fixtures` in the worktree, else the copy inside the test bundle.
    public static let fixtures: String = {
        if let env = ProcessInfo.processInfo.environment["SEVENZIP_FIXTURES"],
           FileManager.default.fileExists(atPath: env) { return env }
        if let root = repoRoot {
            let p = root + "/Mac/Tests/Fixtures"
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        if let url = Bundle(for: BundleToken.self).resourceURL?.appendingPathComponent("Fixtures"),
           FileManager.default.fileExists(atPath: url.path) { return url.path }
        return NSTemporaryDirectory() + "Fixtures"
    }()

    /// `Mac/build/screenshots` -- where test.sh puts the exported attachments. A sandboxed
    /// test cannot write here itself.
    public static let screenshots: String = {
        if let env = ProcessInfo.processInfo.environment["SEVENZIP_SCREENSHOT_DIR"] { return env }
        if let root = repoRoot { return root + "/Mac/build/screenshots" }
        return NSTemporaryDirectory() + "7zip-screenshots"
    }()

    /// Scratch directory this process may always write to (the container's temp under the sandbox).
    public static let artifacts: String = {
        let path = NSTemporaryDirectory() + "7zip-uitests"
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }()

    /// The user's real home directory -- `NSHomeDirectory()` is the sandbox container in a UI test.
    public static let realHome: String = {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            let path = String(cString: dir)
            if !path.isEmpty, path != "/" { return path }
        }
        return NSHomeDirectory()
    }()

    /// True when this process runs inside an app sandbox (Xcode's XCTRunner does).
    public static let isSandboxed: Bool = NSHomeDirectory().contains("/Library/Containers/")

    /// One fixture archive, e.g. `TestPaths.fixture("test.7z")`.
    public static func fixture(_ name: String) -> String {
        (fixtures as NSString).appendingPathComponent(name)
    }

    private static func isRoot(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path + "/Mac/project.yml")
    }

    private final class BundleToken {}
}
