// VersionTests.swift -- the version plumbing (pub3, ai/reports/pub3.md): Mac/VERSION is the one
// source, the framework's Info.plist carries PORT_VERSION, UPSTREAM_VERSION is the engine's
// MY_VERSION, and the running slice is the one the test was built for (the suite also runs under
// Rosetta: `Mac/scripts/test.sh -A x86_64`).

import XCTest
import SevenZipKit

final class VersionTests: XCTestCase {

    /// Mac/VERSION, parsed the way Mac/scripts/version.sh reads it.
    static func versionFile() throws -> [String: String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VERSION")
        let text = try String(contentsOf: url, encoding: .utf8)
        var values: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) where !line.hasPrefix("//") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { values[parts[0]] = parts[1] }
        }
        return values
    }

    func testVersionFileMatchesTheEngineAndTheBundles() throws {
        let values = try Self.versionFile()
        let port = try XCTUnwrap(values["PORT_VERSION"])
        let upstream = try XCTUnwrap(values["UPSTREAM_VERSION"])
        XCTAssertNotNil(port.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression), "PORT_VERSION '\(port)'")
        XCTAssertEqual(upstream, SZEngineVersionString(), "UPSTREAM_VERSION is C/7zVersion.h's MY_VERSION")

        let framework = Bundle(for: SZCodecs.self)
        XCTAssertEqual(framework.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, port,
                       "MARKETING_VERSION (Mac/Version.xcconfig) reaches the bundles")
        let build = try XCTUnwrap(framework.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        XCTAssertNotNil(Int(build), "CFBundleVersion is a build number, not '\(build)'")
    }

    /// The slice the process runs is the one it was compiled for: under Rosetta the x86_64 slice,
    /// i.e. the C fallbacks instead of Asm/arm64/LzmaDecOpt.S.
    func testRunningSlice() {
        #if arch(arm64)
        XCTAssertTrue(SZBenchmark.versionWithCPUText.contains("arm64"), SZBenchmark.versionWithCPUText)
        #elseif arch(x86_64)
        XCTAssertTrue(SZBenchmark.versionWithCPUText.contains("x64"), SZBenchmark.versionWithCPUText)
        #endif
    }
}
