// BenchmarkTests.swift -- SZBenchmark (scope `tools`). A short in-process Bench() run must
// produce plausible non-zero ratings, and Cancel must end the worker thread.

import XCTest
import SevenZipKit

final class BenchmarkTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        try? SZCodecs.loadCodecs()
    }

    final class Recorder: NSObject, SZBenchmarkDelegate {
        let finished = XCTestExpectation(description: "benchmark finished")
        private let lock = NSLock()
        private var _updates = 0
        private var _error: Error?
        private var _frequencyLines: [String] = []
        var updates: Int { lock.lock(); defer { lock.unlock() }; return _updates }
        var error: Error? { lock.lock(); defer { lock.unlock() }; return _error }
        var frequencyLines: [String] { lock.lock(); defer { lock.unlock() }; return _frequencyLines }

        func benchmarkDidUpdate() { lock.lock(); _updates += 1; lock.unlock() }
        func benchmarkDidFinish(error: Error?) {
            lock.lock(); _error = error; lock.unlock()
            finished.fulfill()
        }
        func benchmarkDidAddFrequencyLine(_ line: String) {
            lock.lock(); _frequencyLines.append(line); lock.unlock()
        }
    }

    func testStaticInformation() {
        XCTAssertGreaterThan(SZBenchmark.processThreadCount, 0)
        XCTAssertGreaterThanOrEqual(SZBenchmark.systemThreadCount, SZBenchmark.processThreadCount)
        XCTAssertGreaterThan(SZBenchmark.ramSize, 0)
        XCTAssertEqual(SZBenchmark.ramSizeLimit, SZBenchmark.ramSize / 16 * 15)
        XCTAssertEqual(SZBenchmark.minimumDictionarySize, 1 << 18)          // kMinDicSize 256 KB
        XCTAssertEqual(SZBenchmark.maximumDictionarySize, 1 << 32)          // 4 GB on 64-bit
        XCTAssertEqual(SZBenchmark.minimumDictionaryLog, 18)                // kBenchMinDicLogSize
        XCTAssertFalse(SZBenchmark.cpuName.isEmpty)
        XCTAssertFalse(SZBenchmark.cpuFeaturesText.isEmpty)
        // GetSysInfo only fills s1/s2 under _WIN32 (Windows/SystemInfo.cpp:490-520), so both
        // are empty on macOS; the Darwin version and page size are in cpuFeaturesText instead.
        XCTAssertEqual(SZBenchmark.systemInfoLine2, "")
        XCTAssertTrue(SZBenchmark.cpuFeaturesText.contains("Darwin"))
        XCTAssertTrue(SZBenchmark.hardwareThreadsText.hasPrefix("/ "))
        XCTAssertTrue(SZBenchmark.versionWithCPUText.hasPrefix("7-Zip "))
        XCTAssertTrue(SZBenchmark.versionWithCPUText.contains("("))
        XCTAssertEqual(SZBenchmark.engineDateText.count, 10)                // MY_DATE "YYYY-MM-DD"

        // GetBenchMemoryUsage grows with the dictionary and with the thread count.
        let small = SZBenchmark.memoryUsage(forThreads: 1, level: -1, dictionary: 1 << 20, totalMode: false)
        let large = SZBenchmark.memoryUsage(forThreads: 1, level: -1, dictionary: 1 << 24, totalMode: false)
        XCTAssertGreaterThan(small, 0)
        XCTAssertGreaterThan(large, small)
        XCTAssertTrue(SZBenchmark.isMemoryUsageOK(small))
        XCTAssertFalse(SZBenchmark.isMemoryUsageOK(SZBenchmark.ramSize * 2))
    }

    func testShortRunProducesRatings() throws {
        let bench = SZBenchmark()
        let recorder = Recorder()
        bench.delegate = recorder
        bench.dictionarySize = 1 << 20     // small, so one pass is quick
        bench.numberOfThreads = 1
        bench.numberOfPasses = 1
        bench.level = -1

        try bench.start()
        XCTAssertTrue(bench.isRunning)
        wait(for: [recorder.finished], timeout: 180)
        bench.waitUntilFinished()
        XCTAssertFalse(bench.isRunning)
        XCTAssertNil(recorder.error)

        XCTAssertEqual(bench.passesFinished, 1)
        XCTAssertTrue(bench.didFinishAllPasses)
        XCTAssertGreaterThan(recorder.updates, 0)

        let encode = bench.resultingEncode
        let decode = bench.resultingDecode
        XCTAssertTrue(encode.isDefined)
        XCTAssertTrue(decode.isDefined)
        XCTAssertGreaterThan(encode.rating, 0)
        XCTAssertGreaterThan(decode.rating, 0)
        XCTAssertGreaterThan(encode.speed, 0)
        XCTAssertGreaterThan(decode.speed, 0)
        XCTAssertGreaterThan(encode.usagePercent, 0)
        XCTAssertGreaterThan(encode.unpackSize, 0)
        XCTAssertTrue(encode.ratingString.hasSuffix(" GIPS"))
        XCTAssertTrue(encode.speedString.hasSuffix(" KB/s"))
        XCTAssertTrue(encode.usageString.hasSuffix("%"))
        XCTAssertTrue(encode.sizeString.hasSuffix(" MB") || encode.sizeString.hasSuffix(" GB"))

        let total = bench.totalRating
        XCTAssertGreaterThanOrEqual(total.rating, min(encode.rating, decode.rating))

        XCTAssertEqual(bench.passes.count, 1)
        // IDT_BENCH_LOG: header + one line per pass + the averages after "-------------"
        let log = bench.logText
        XCTAssertTrue(log.contains("Compr Decompr Total   CPU"))
        XCTAssertTrue(log.contains("-------------"))
        XCTAssertEqual(bench.droppedPassIndex, -1)
        // the freq callback ran on the first pass
        XCTAssertFalse(bench.frequencyText.isEmpty)
    }

    func testStopEndsTheWorker() throws {
        let bench = SZBenchmark()
        let recorder = Recorder()
        bench.delegate = recorder
        bench.dictionarySize = 1 << 22
        bench.numberOfThreads = max(1, SZBenchmark.processThreadCount)
        bench.numberOfPasses = 1000            // would never finish on its own
        try bench.start()
        // let it get going, then ask it to leave (IDB_STOP / IDCANCEL semantics)
        Thread.sleep(forTimeInterval: 1.0)
        bench.requestStop()
        wait(for: [recorder.finished], timeout: 180)
        bench.waitUntilFinished()
        XCTAssertFalse(bench.isRunning)
        // E_ABORT is silent, exactly like the progress machinery
        XCTAssertNil(recorder.error)
        XCTAssertLessThan(bench.passesFinished, 1000)
    }
}
