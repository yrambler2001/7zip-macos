// ExtractHashTests.swift -- `-scrc<M>` on extract and test: the checksums of the *extracted* data,
// shown in the same list dialog the File > CRC command uses
// (03-shell-integration-inventory.md §2.6, GUI/ExtractGUI.cpp:81-98 and :129-136).
//
// The option is off by default, so the first test pins that. The digests are cross-checked against
// the console `7zz x -scrcSHA256` / `7zz t -scrcSHA256` output, which is the reference.

import XCTest
import SevenZipKit

final class ExtractHashTests: UpdaterTestCase {

    private var fixtures: String {
        guard let url = Bundle(for: ExtractHashTests.self).resourceURL else { fatalError("no resources") }
        return url.appendingPathComponent("Fixtures").path
    }

    private func fixture(_ name: String) -> String { (fixtures as NSString).appendingPathComponent(name) }

    private func extract(_ options: SZExtractOptions, _ archives: [String],
                         test: Bool = false) throws -> SZExtractResult {
        let outcome: Result<SZExtractResult, Error> = offMain {
            do {
                let r = test
                    ? try SZArchiveExtractor.testArchives(at: archives, options: options, progress: nil)
                    : try SZArchiveExtractor.extractArchives(at: archives, options: options, progress: nil)
                return .success(r)
            } catch { return .failure(error) }
        }
        return try outcome.get()
    }

    /// `"SHA256 for data:              <hex>"` out of the console tool's tail.
    private func consoleDigest(_ arguments: [String], label: String) throws -> String {
        let run = try XCTUnwrap(runConsole(arguments))
        XCTAssertEqual(run.status, 0, run.output)
        for line in run.output.components(separatedBy: "\n") where line.hasPrefix(label) {
            return line.dropFirst(label.count).trimmingCharacters(in: .whitespaces)
        }
        XCTFail("no \"\(label)\" line in:\n\(run.output)")
        return ""
    }

    // MARK: - off by default

    func testNoHashMethodsMeansNoHashResults() throws {
        let out = try tempDir("scrc-off")
        let options = SZExtractOptions()
        options.outputDirectory = out + "/"
        options.outDirMode = .direct
        options.overwriteMode = .overwrite
        XCTAssertEqual(options.hashMethods, [], "-scrc must be off unless the caller asks")

        let result = try extract(options, [fixture("test.7z")])
        XCTAssertTrue(result.isOK)
        XCTAssertNil(result.hashResults)

        // A test run still shows its own statistics box when no hashing was asked for.
        let testOptions = SZExtractOptions()
        let tested = try extract(testOptions, [fixture("test.7z")], test: true)
        XCTAssertNil(tested.hashResults)
        XCTAssertNotNil(tested.testSummary)
    }

    // MARK: - extracting with -scrc

    func testExtractWithHashMethodMatchesTheConsole() throws {
        guard Self.consoleTool != nil else { throw XCTSkip("console 7zz is not built") }
        let out = try tempDir("scrc-x")
        let options = SZExtractOptions()
        options.outputDirectory = out + "/"
        options.outDirMode = .direct
        options.overwriteMode = .overwrite
        options.hashMethods = ["SHA256"]

        let result = try extract(options, [fixture("test.7z")])
        XCTAssertTrue(result.isOK)
        let hashes = try XCTUnwrap(result.hashResults)

        // The files really were written; -scrc hashes the extracted data, it does not replace it.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: (out as NSString).appendingPathComponent("readme.txt")))

        // CHashBundle's counters, i.e. what the archive holds (4 files, 2 folders, 3043 bytes).
        XCTAssertEqual(hashes.numFiles, 4)
        XCTAssertEqual(hashes.filesSize, 3043)
        XCTAssertEqual(hashes.numErrors, 0)
        XCTAssertEqual(hashes.methodNames, ["SHA256"])

        let consoleOut = try tempDir("scrc-x-console")
        let expected = try consoleDigest(["x", "-scrcSHA256", "-y", "-o" + consoleOut,
                                          fixture("test.7z")],
                                         label: "SHA256 for data:")
        XCTAssertEqual(hashes.dataDigests["SHA256"], expected)
        XCTAssertFalse(expected.isEmpty)
    }

    /// The exact rows ExtractGUI builds: "Archives:" and "Packed Size" in front of
    /// AddHashBundleRes (GUI/ExtractGUI.cpp:129-136).
    func testHashResultRowsAreTheWindowsOnes() throws {
        let out = try tempDir("scrc-rows")
        let options = SZExtractOptions()
        options.outputDirectory = out + "/"
        options.outDirMode = .direct
        options.overwriteMode = .overwrite
        options.hashMethods = ["CRC32"]
        let result = try extract(options, [fixture("test.7z")])
        let rows = try XCTUnwrap(result.hashResults).rows
        XCTAssertGreaterThanOrEqual(rows.count, 5)

        XCTAssertTrue(rows[0].name.contains("Archives"), rows[0].name)
        XCTAssertEqual(rows[0].value, "1")
        XCTAssertTrue(rows[1].name.contains("Packed"), rows[1].name)
        XCTAssertTrue(rows[1].value.hasPrefix("296"), rows[1].value)      // test.7z is 296 bytes

        let names = rows.map { $0.name }
        XCTAssertTrue(names.contains { $0.contains("Files") }, "\(names)")
        XCTAssertTrue(names.contains { $0.contains("Size") }, "\(names)")
        // Several files, so the two sum rows, never a bare "CRC32" row.
        XCTAssertTrue(names.contains { $0.contains("CRC32") && $0.contains("data") }, "\(names)")
        XCTAssertFalse(names.contains("CRC32"), "\(names)")
        // The text form is the same rows as "<name>: <value>" lines.
        let text = try XCTUnwrap(result.hashResults).text
        XCTAssertTrue(text.contains(rows[0].name + ": 1"), text)
    }

    // MARK: - testing with -scrc

    /// With a hash bundle the results dialog *replaces* the test statistics box, which is the
    /// `if (HashBundle) ... else if (Options->TestMode)` of ExtractGUI.cpp:131-152.
    func testTestModeWithHashMethodReplacesTheSummary() throws {
        guard Self.consoleTool != nil else { throw XCTSkip("console 7zz is not built") }
        let options = SZExtractOptions()
        options.hashMethods = ["SHA256"]
        let result = try extract(options, [fixture("test.7z")], test: true)
        XCTAssertTrue(result.isOK)
        XCTAssertNil(result.testSummary, "the hash list takes the place of the statistics box")
        let hashes = try XCTUnwrap(result.hashResults)
        XCTAssertEqual(hashes.numFiles, 4)

        let expected = try consoleDigest(["t", "-scrcSHA256", fixture("test.7z")],
                                         label: "SHA256 for data:")
        XCTAssertEqual(hashes.dataDigests["SHA256"], expected)
    }

    /// `@"*"` is every hasher the codecs expose, as for the CRC submenu's "*" item.
    func testAllMethods() throws {
        let options = SZExtractOptions()
        options.hashMethods = ["*"]
        let result = try extract(options, [fixture("test.7z")], test: true)
        let hashes = try XCTUnwrap(result.hashResults)
        XCTAssertEqual(hashes.methodNames.count, SZHasher.availableMethods.count)
        XCTAssertTrue(hashes.methodNames.contains("CRC32"))
        for method in hashes.methodNames {
            XCTAssertFalse((hashes.dataDigests[method] ?? "").isEmpty, method)
        }
    }

    /// A bad method name must fail the call, not silently extract without hashing.
    func testUnknownMethodFails() throws {
        let options = SZExtractOptions()
        options.hashMethods = ["NOT-A-HASHER"]
        XCTAssertThrowsError(try extract(options, [fixture("test.7z")], test: true))
    }
}
