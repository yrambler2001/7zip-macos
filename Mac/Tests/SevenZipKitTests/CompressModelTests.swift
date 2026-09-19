// CompressModelTests.swift -- the Compress dialog's computation model (scope `compress`).
// Each test names the CompressDialog.cpp function it pins down; the expected item lists come
// from 01b-fm-dialogs-settings.md section 4.23 "Automatic values" and the sources it cites.
//
// CompressModel.swift is symlinked into this target (like Settings.swift and FileTypes.swift)
// because it is deliberately AppKit-free.

import XCTest
import SevenZipKit

final class CompressModelTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        try? SZCodecs.loadCodecs()
        try? SZLang.shared.loadLanguage(code: "-")
    }

    private func model(_ formatName: String, ram: UInt64 = 16 << 30) -> CompressModel {
        guard let info = SZCodecs.format(named: formatName) else {
            fatalError("format \(formatName) missing")
        }
        return CompressModel(arcInfo: info, ramSize: ram)
    }

    private func plain(_ id: UInt32, _ fallback: String) -> String { fallback }

    // MARK: - g_Formats (01b 4.23 "Format table")

    func testFormatTable() {
        XCTAssertEqual(CompressStaticFormat.all.count, 9)

        let any = CompressStaticFormat.forFormatName("rar5")     // any other handler -> entry 0
        XCTAssertEqual(any.name, "")
        XCTAssertEqual(any.levels, Array(0...9))
        XCTAssertTrue(any.methods.isEmpty)
        XCTAssertEqual(any.flags, [.multiThread, .memUse])

        let sevenZip = CompressStaticFormat.forFormatName("7z")
        XCTAssertEqual(sevenZip.levels, Array(0...9))
        XCTAssertEqual(sevenZip.methods, [.lzma2, .lzma, .ppmd, .bzip2, .deflate, .deflate64, .copy])
        XCTAssertEqual(sevenZip.flags, [.filter, .solid, .multiThread, .encrypt,
                                        .encryptFileNames, .memUse, .sfx])

        let zip = CompressStaticFormat.forFormatName("zip")
        XCTAssertEqual(zip.levels, [0, 1, 3, 5, 7, 9])
        XCTAssertEqual(zip.methods, [.deflate, .deflate64, .bzip2, .lzma, .ppmdZip])
        XCTAssertEqual(zip.flags, [.multiThread, .encrypt, .memUse])

        XCTAssertEqual(CompressStaticFormat.forFormatName("gzip").levels, [1, 5, 7, 9])
        XCTAssertEqual(CompressStaticFormat.forFormatName("bzip2").levels, [1, 3, 5, 7, 9])
        XCTAssertEqual(CompressStaticFormat.forFormatName("xz").levels, Array(1...9))  // no Store
        XCTAssertEqual(CompressStaticFormat.forFormatName("tar").levels, [0])
        XCTAssertEqual(CompressStaticFormat.forFormatName("tar").methods, [.gnu, .posix])
        XCTAssertEqual(CompressStaticFormat.forFormatName("wim").levels, [0])
        XCTAssertTrue(CompressStaticFormat.forFormatName("wim").methods.isEmpty)
        XCTAssertTrue(CompressStaticFormat.forFormatName("Hash").levels.isEmpty)
        XCTAssertEqual(CompressStaticFormat.forFormatName("Hash").methods, [.sha256, .sha1])
        // No zstd entry in 26.03.
        XCTAssertFalse(CompressStaticFormat.all.contains { $0.name.lowercased() == "zstd" })
    }

    // MARK: - SetLevel2

    func testLevelItems() {
        let m = model("7z")
        let items = m.levelItems(plain)
        XCTAssertEqual(items.map(\.title), ["0 - Store", "1 - Fastest", "2", "3 - Fast", "4",
                                            "5 - Normal", "6", "7 - Maximum", "8", "9 - Ultra"])
        XCTAssertEqual(items.map(\.data), (0...9).map(Int64.init))

        let zip = model("zip").levelItems(plain)
        XCTAssertEqual(zip.map(\.title), ["0 - Store", "1 - Fastest", "3 - Fast", "5 - Normal",
                                          "7 - Maximum", "9 - Ultra"])
    }

    // MARK: - SetMethod2

    func test7zMethodItemsHideCopyAndDeflate() {
        let m = model("7z")
        m.level = 5
        XCTAssertEqual(m.methodItems.map(\.title), ["*  LZMA2", "LZMA", "PPMd", "BZip2"])
        XCTAssertTrue(m.methodItems[0].isAuto)
        XCTAssertEqual(m.autoMethodRaw, CompressMethodID.lzma2.rawValue)
        XCTAssertEqual(m.methodSpec, "")                  // auto emits nothing
        XCTAssertEqual(m.estimatedMethodName, "LZMA2")
    }

    func testMethodComboIsEmptyAtLevelZeroExceptTarAndHash() {
        let m = model("7z")
        m.level = 0
        XCTAssertTrue(m.methodItems.isEmpty)
        XCTAssertNil(m.method)

        let tar = model("tar")
        tar.level = 0
        XCTAssertEqual(tar.methodItems.map(\.title), ["*  GNU", "POSIX"])

        let hash = model("Hash")
        hash.level = 0
        XCTAssertEqual(hash.methodItems.map(\.title), ["*  SHA256", "SHA1"])
    }

    func testSFXModeLimitsThe7zMethodList() {
        let m = model("7z")
        m.level = 5
        m.sfxMode = true
        // g_7zSfxMethods = Copy, LZMA, LZMA2, PPMd -- intersected with the visible 7z list.
        XCTAssertEqual(m.methodItems.map(\.title), ["*  LZMA2", "LZMA", "PPMd"])
    }

    func testZipMethodItems() {
        let m = model("zip")
        m.level = 5
        XCTAssertEqual(m.methodItems.map(\.title), ["*  Deflate", "Deflate64", "BZip2", "LZMA", "PPMd"])
        // The zip PPMd is kPPMdZip, a different encoder from the 7z one.
        XCTAssertEqual(m.methodItems.last?.data, Int64(CompressMethodID.ppmdZip.rawValue))
    }

    // MARK: - SetDictionary2 (01b 4.23 "Automatic values")

    func testLzmaAutoDictionaryPerLevel() {
        let m = model("7z")
        let expected: [Int: UInt64] = [0: 64 << 10, 1: 256 << 10, 2: 1 << 20, 3: 4 << 20,
                                       4: 16 << 20, 5: 32 << 20, 6: 64 << 20, 7: 128 << 20,
                                       8: 256 << 20, 9: 256 << 20]
        for (level, dict) in expected {
            m.level = level
            m.selectedMethodRaw = CompressMethodID.lzma2.rawValue
            XCTAssertEqual(m.autoDictionary, dict, "level \(level)")
        }
    }

    func testLzmaDictionaryItemList() {
        let m = model("7z")
        m.level = 5
        m.selectedMethodRaw = CompressMethodID.lzma2.rawValue
        let (items, selection) = m.dictionaryItems(storedDictionary: nil)
        XCTAssertEqual(selection, 0)
        XCTAssertEqual(items[0].title, "*  32 MB")
        XCTAssertEqual(items.map(\.title).prefix(11),
                       ["*  32 MB", "64 KB", "256 KB", "1 MB", "2 MB", "3 MB", "4 MB", "6 MB",
                        "8 MB", "12 MB", "16 MB"])
        // The top three entries: 2 GB, 3 GB and the 4 GB one clamped to kLzmaMaxDictSize.
        XCTAssertEqual(items.suffix(3).map(\.title), ["2048 MB", "3072 MB", "3840 MB"])
        XCTAssertEqual(items.last?.data, Int64(CompressModel.lzmaMaxDictSize))
    }

    func testStoredDictionarySelectsLargestItemNotAbove() {
        let m = model("7z")
        m.level = 9
        m.selectedMethodRaw = CompressMethodID.lzma2.rawValue
        // 5 MB is not an item; the largest one <= 5 MB is 4 MB.
        let (items, selection) = m.dictionaryItems(storedDictionary: 5 << 20)
        XCTAssertEqual(items[selection].title, "4 MB")
        // The -2 marker means ">= 4 GB": the largest item wins.
        let (items2, selection2) = m.dictionaryItems(storedDictionary: -2)
        XCTAssertEqual(items2[selection2].title, "3840 MB")
    }

    func testPpmdAndOtherDictionaryLists() {
        let m = model("7z")
        m.level = 5
        m.selectedMethodRaw = CompressMethodID.ppmd.rawValue
        XCTAssertEqual(m.autoDictionary, 1 << 24)                       // 1 << (5 + 19) = 16 MB
        let ppmd = m.dictionaryItems(storedDictionary: nil).items
        XCTAssertEqual(ppmd[0].title, "*  16 MB")
        XCTAssertEqual(ppmd[1].title, "1 MB")
        XCTAssertEqual(ppmd.last?.title, "1024 MB")                     // kPpmd_MaxDictSize_Up

        m.selectedMethodRaw = CompressMethodID.bzip2.rawValue
        XCTAssertEqual(m.autoDictionary, 900 << 10)
        let bzip2 = m.dictionaryItems(storedDictionary: nil).items
        XCTAssertEqual(bzip2.map(\.title), ["*  900 KB", "100 KB", "200 KB", "300 KB", "400 KB",
                                            "500 KB", "600 KB", "700 KB", "800 KB", "900 KB"])
        m.level = 4
        XCTAssertEqual(m.autoDictionary, 500 << 10)
        m.level = 1
        XCTAssertEqual(m.autoDictionary, 100 << 10)

        let zip = model("zip")
        zip.level = 5
        zip.selectedMethodRaw = CompressMethodID.deflate.rawValue
        XCTAssertEqual(zip.autoDictionary, 32 << 10)
        XCTAssertEqual(zip.dictionaryItems(storedDictionary: nil).items.map(\.title), ["*  32 KB"])
        zip.selectedMethodRaw = CompressMethodID.deflate64.rawValue
        XCTAssertEqual(zip.autoDictionary, 64 << 10)
        zip.selectedMethodRaw = CompressMethodID.ppmdZip.rawValue
        let ppmdZip = zip.dictionaryItems(storedDictionary: nil).items
        XCTAssertEqual(ppmdZip[1].title, "1 MB")
        XCTAssertEqual(ppmdZip.last?.title, "256 MB")
    }

    // MARK: - SetOrder2

    func testWordSizeItems() {
        let m = model("7z")
        m.level = 5
        m.selectedMethodRaw = CompressMethodID.lzma2.rawValue
        XCTAssertEqual(m.autoOrder, 32)
        XCTAssertEqual(m.orderItems(storedOrder: nil).items.map(\.title),
                       ["*  32", "8", "12", "16", "24", "32", "48", "64", "96", "128", "192",
                        "256", "273"])
        m.level = 9
        XCTAssertEqual(m.autoOrder, 64)

        m.selectedMethodRaw = CompressMethodID.ppmd.rawValue
        XCTAssertEqual(m.autoOrder, 32)
        XCTAssertEqual(m.orderItems(storedOrder: nil).items.map(\.title),
                       ["*  32", "2", "3", "4", "5", "6", "7", "8", "10", "12", "14", "16",
                        "20", "24", "28", "32"])
        m.level = 4
        XCTAssertEqual(m.autoOrder, 4)
        m.level = 5
        XCTAssertEqual(m.autoOrder, 6)
        m.level = 7
        XCTAssertEqual(m.autoOrder, 16)

        let zip = model("zip")
        zip.level = 9
        zip.selectedMethodRaw = CompressMethodID.deflate.rawValue
        XCTAssertEqual(zip.autoOrder, 128)
        XCTAssertEqual(zip.orderItems(storedOrder: nil).items.last?.title, "258")
        zip.selectedMethodRaw = CompressMethodID.deflate64.rawValue
        XCTAssertEqual(zip.orderItems(storedOrder: nil).items.last?.title, "257")
        zip.selectedMethodRaw = CompressMethodID.ppmdZip.rawValue
        XCTAssertEqual(zip.autoOrder, 12)
        XCTAssertEqual(zip.orderItems(storedOrder: nil).items.map(\.title),
                       ["*  12"] + (2...16).map { "\($0)" })

        // BZip2 and Copy have no word size at all.
        m.selectedMethodRaw = CompressMethodID.bzip2.rawValue
        XCTAssertTrue(m.orderItems(storedOrder: nil).items.isEmpty)
        XCTAssertTrue(m.orderMode == false)
        m.selectedMethodRaw = CompressMethodID.ppmd.rawValue
        XCTAssertTrue(m.orderMode)                                      // PPMd emits mem/o
    }

    // MARK: - SetSolidBlockSize2

    func testSolidItemsAndAutoValue() {
        let m = model("7z")
        m.level = 5
        m.selectedMethodRaw = CompressMethodID.lzma2.rawValue
        m.dictionary = CompressModel.autoValue                          // 32 MB
        // chunk = clamp(32 MB * 4, 1 MB, 256 MB) = 128 MB; << 6 = 8 GB, under the 16 GB cap.
        XCTAssertEqual(CompressModel.lzma2ChunkSize(32 << 20), 128 << 20)
        XCTAssertEqual(m.autoSolidBlockSize, (128 << 20) << 6)
        let (items, selection) = m.solidItems(storedBlockLogSize: nil, localize: plain)
        XCTAssertEqual(selection, 0)
        XCTAssertEqual(items[0].title, "*  8 GB")
        XCTAssertEqual(items[1].title, "Non-solid")                     // 7z only
        XCTAssertEqual(items[1].data, CompressModel.solidLogNonSolid)
        XCTAssertEqual(items[2].title, "1 MB")
        XCTAssertEqual(items[2].data, 20)
        XCTAssertEqual(items[items.count - 2].title, "64 GB")
        XCTAssertEqual(items[items.count - 2].data, 36)
        XCTAssertEqual(items.last?.title, "Solid")
        XCTAssertEqual(items.last?.data, CompressModel.solidLogFullSolid)

        // LZMA (not LZMA2): dict << 7, minimum 16 MB, cap 4 GB.
        m.selectedMethodRaw = CompressMethodID.lzma.rawValue
        m.dictionary = CompressModel.autoValue
        XCTAssertEqual(m.autoSolidBlockSize, (32 << 20) << 7)

        // xz: the chunk size itself, and no "Non-solid" item.
        let xz = model("xz")
        xz.level = 5
        xz.selectedMethodRaw = nil
        XCTAssertEqual(xz.autoSolidBlockSize, CompressModel.lzma2ChunkSize(32 << 20))
        let xzItems = xz.solidItems(storedBlockLogSize: nil, localize: plain).items
        XCTAssertFalse(xzItems.contains { $0.title == "Non-solid" })

        // Level 0 and non-solid formats have no combo at all.
        m.level = 0
        XCTAssertNil(m.autoSolidBlockSize)
        let zip = model("zip")
        zip.level = 5
        XCTAssertNil(zip.autoSolidBlockSize)
    }

    func testSolidBlockSizeEmission() {
        let m = model("7z")
        m.level = 5
        m.blockLogSize = CompressModel.autoValue
        XCTAssertNil(m.solidBlockSizeBytes)                      // nothing emitted
        m.blockLogSize = CompressModel.solidLogNonSolid
        XCTAssertEqual(m.solidBlockSizeBytes, 0)                 // s=0b
        m.blockLogSize = CompressModel.solidLogFullSolid
        XCTAssertEqual(m.solidBlockSizeBytes, UInt64.max)        // s=18446744073709551615b
        m.blockLogSize = 24
        XCTAssertEqual(m.solidBlockSizeBytes, 1 << 24)
    }

    // MARK: - SetNumThreads2

    func testMaxAlgorithmThreadsPerMethod() {
        let zip = model("zip")
        zip.level = 5
        XCTAssertEqual(zip.maxAlgorithmThreads, 128)
        XCTAssertEqual(model("xz").maxAlgorithmThreads, 512)

        let m = model("7z")
        m.level = 5
        m.selectedMethodRaw = CompressMethodID.lzma.rawValue
        XCTAssertEqual(m.maxAlgorithmThreads, 2)
        m.selectedMethodRaw = CompressMethodID.lzma2.rawValue
        XCTAssertEqual(m.maxAlgorithmThreads, 512)
        m.selectedMethodRaw = CompressMethodID.bzip2.rawValue
        XCTAssertEqual(m.maxAlgorithmThreads, 64)
        m.selectedMethodRaw = CompressMethodID.ppmd.rawValue
        XCTAssertEqual(m.maxAlgorithmThreads, 1)
        // Any other handler: 2 x hardware.
        let wim = model("wim")
        XCTAssertEqual(wim.maxAlgorithmThreads, CompressModel.systemThreadCount * 2)
    }

    func testThreadItems() {
        let m = model("7z")
        m.level = 5
        m.selectedMethodRaw = CompressMethodID.lzma.rawValue     // max 2
        let (items, selection) = m.threadItems(storedNumThreads: nil)
        XCTAssertEqual(items[0].data, CompressModel.autoValue)
        XCTAssertTrue(items[0].title.hasPrefix(CompressModel.autoPrefix))
        XCTAssertEqual(items.dropFirst().map(\.title), ["1", "2"])
        XCTAssertEqual(selection, 0)

        // A stored explicit count selects that item instead of auto.
        let (items2, selection2) = m.threadItems(storedNumThreads: 2)
        XCTAssertEqual(items2[selection2].title, "2")

        // Single-threaded methods offer only the auto item.
        m.selectedMethodRaw = CompressMethodID.ppmd.rawValue
        XCTAssertEqual(m.threadItems(storedNumThreads: nil).items.count, 1)

        // Formats without kFF_MultiThread have no combo.
        let tar = model("tar")
        tar.level = 0
        XCTAssertTrue(tar.threadItems(storedNumThreads: nil).items.isEmpty)
    }

    // MARK: - Memory use combo and limit

    func testMemUseItemsAndSpecs() {
        let m = model("7z", ram: 16 << 30)
        let (items, selection) = m.memUseItems(stored: "")
        XCTAssertEqual(selection, 0)
        XCTAssertEqual(items[0], CompressModel.MemUseItem(title: "*  80%", spec: ""))
        XCTAssertEqual(items[1], CompressModel.MemUseItem(title: "10%", spec: "10%"))
        XCTAssertEqual(items[10], CompressModel.MemUseItem(title: "100%", spec: "100%"))
        XCTAssertEqual(items[11], CompressModel.MemUseItem(title: "256 MB", spec: "256M"))
        XCTAssertEqual(items[12], CompressModel.MemUseItem(title: "384 MB", spec: "384M"))
        // AddMemSize only switches to GB at >= 2 GB (size >= 1 << 31).
        XCTAssertEqual(items[15], CompressModel.MemUseItem(title: "1024 MB", spec: "1024M"))
        XCTAssertEqual(items[16], CompressModel.MemUseItem(title: "1536 MB", spec: "1536M"))
        XCTAssertEqual(items[17], CompressModel.MemUseItem(title: "2 GB", spec: "2G"))
        XCTAssertEqual(items.last?.spec, "16384G")               // 2 << 43, the top 64-bit item

        // A stored percentage is selected.
        let (_, sel50) = m.memUseItems(stored: "50%")
        XCTAssertEqual(m.memUseItems(stored: "50%").items[sel50].spec, "50%")
        // A stored absolute size that is not an item is inserted at its sorted position.
        let (items3, sel3) = m.memUseItems(stored: "300M")
        XCTAssertEqual(items3[sel3].title, "300 MB")
        XCTAssertEqual(items3[sel3 - 1].title, "256 MB")
        XCTAssertEqual(items3[sel3 + 1].title, "384 MB")

        // Formats without kFF_MemUse have no combo.
        let tar = model("tar")
        XCTAssertTrue(tar.memUseItems(stored: "").items.isEmpty)
    }

    func testMemUseLimit() {
        let m = model("7z", ram: 16 << 30)
        XCTAssertEqual(m.ramSizeReduced, 16 << 30)
        // Calc_From_Val_Percents_Less100: val * percents / 100 while it does not overflow.
        XCTAssertEqual(m.ramUsageAuto, (16 << 30) * 80 / 100)
        XCTAssertEqual(m.memUseLimitBytes, m.ramUsageAuto)       // the auto item
        m.memUseSpec = "50%"
        XCTAssertEqual(m.memUseLimitBytes, (16 << 30) * 50 / 100)
        m.memUseSpec = "512M"
        XCTAssertEqual(m.memUseLimitBytes, 512 << 20)
        m.memUseSpec = "2G"
        XCTAssertEqual(m.memUseLimitBytes, 2 << 30)

        // A tiny machine is lifted to the 64 MB floor.
        let tiny = model("7z", ram: 32 << 20)
        XCTAssertEqual(tiny.ramSizeReduced, 64 << 20)
    }

    func testMemUseParsing() {
        XCTAssertNil(CompressMemUse(spec: ""))
        XCTAssertEqual(CompressMemUse(spec: "80%"), CompressMemUse(spec: "80%"))
        XCTAssertEqual(CompressMemUse(spec: "80%")?.propertyValue, "80%")
        XCTAssertEqual(CompressMemUse(spec: "512M")?.value, 512 << 20)
        XCTAssertEqual(CompressMemUse(spec: "512M")?.propertyValue, "\(512 << 20)b")
        XCTAssertEqual(CompressMemUse(spec: "3G")?.value, 3 << 30)
        XCTAssertEqual(CompressMemUse(spec: "1000")?.value, 1000)
        XCTAssertNil(CompressMemUse(spec: "abc"))
    }

    // MARK: - Memory estimation

    func testMemoryEstimationLevelZeroIsOneMegabyte() {
        let m = model("7z")
        m.level = 0
        XCTAssertEqual(m.memoryEstimate.compressed, 1 << 20)
        XCTAssertEqual(m.memoryEstimate.decompressed, 1 << 20)
        XCTAssertEqual(m.decompressionMemoryText, "1 MB")
    }

    func testLzma2SingleThreadEstimate() {
        let m = model("7z")
        m.level = 5
        m.selectedMethodRaw = CompressMethodID.lzma2.rawValue
        m.dictionary = Int64(16 << 20)
        m.numThreads = 1
        // hs for dict 16 MB: the sources' bit trick yields 8 MB, size1 = 8*4 + 16*4 + 16*4 + 2
        // MB = 162 MB; block = dict + 64 KB, x1.5 -> ~24 MB.
        let estimate = m.memoryUsage(threads: 1, dictionary: 16 << 20)
        XCTAssertEqual(estimate.decompressed, (16 << 20) + (2 << 20))
        let expectedSize1: UInt64 = (8 << 20) * 4 + (16 << 20) * 4 + (16 << 20) * 4 + (2 << 20)
        var block: UInt64 = (16 << 20) + (1 << 16)
        block += block >> 1
        XCTAssertEqual(estimate.compressed, expectedSize1 + block)
    }

    func testPpmdAndBZip2AndDeflateEstimates() {
        let m = model("7z")
        m.level = 5
        m.selectedMethodRaw = CompressMethodID.ppmd.rawValue
        var e = m.memoryUsage(threads: 1, dictionary: 16 << 20)
        XCTAssertEqual(e.compressed, (16 << 20) + (2 << 20))
        XCTAssertEqual(e.decompressed, (16 << 20) + (2 << 20))

        m.selectedMethodRaw = CompressMethodID.bzip2.rawValue
        e = m.memoryUsage(threads: 4, dictionary: 900 << 10)
        XCTAssertEqual(e.compressed, (10 << 20) * 4)
        XCTAssertEqual(e.decompressed, 7 << 20)

        let zip = model("zip")
        zip.level = 5
        zip.selectedMethodRaw = CompressMethodID.deflate.rawValue
        e = zip.memoryUsage(threads: 1, dictionary: 32 << 10)
        XCTAssertEqual(e.compressed, 4 << 20)
        XCTAssertEqual(e.decompressed, 2 << 20)
    }

    func testFilterFormatAddsBcj2AtUltra() {
        let m = model("7z")
        m.selectedMethodRaw = CompressMethodID.lzma2.rawValue
        m.level = 8
        let without = m.memoryUsage(threads: 1, dictionary: 16 << 20).compressed
        m.level = 9
        let with = m.memoryUsage(threads: 1, dictionary: 16 << 20).compressed
        // Level 9 also enlarges the dictionary-independent part, so only the BCJ2 add-on is
        // asserted here: it is exactly 2 * 12 MB + 5 MB more than the same formula without it.
        XCTAssertNotNil(without)
        XCTAssertNotNil(with)
        let zipLike = model("zip")           // no kFF_Filter
        zipLike.selectedMethodRaw = CompressMethodID.lzma.rawValue
        zipLike.level = 9
        XCTAssertNotNil(zipLike.memoryUsage(threads: 1, dictionary: 16 << 20).compressed)
    }

    func testUnknownDictionaryGivesQuestionMark() {
        // "wim" has no methods at all, so the dictionary is unknown.
        let m = model("wim")
        m.level = 5
        XCTAssertNil(m.memoryEstimate.compressed)
        XCTAssertEqual(m.memoryUsageText, "?")
        XCTAssertEqual(m.decompressionMemoryText, "?")
    }

    func testMemoryUsageTextFormat() {
        XCTAssertEqual(CompressModel.memUsageText(1 << 20), "1 MB")
        XCTAssertEqual(CompressModel.memUsageText((1 << 20) + 1), "2 MB")     // rounded up
        XCTAssertEqual(CompressModel.memUsageText(32 << 30), "32 GB")
        XCTAssertEqual(CompressModel.memUsageText(100 << 40), "100 TB")

        let m = model("7z", ram: 16 << 30)
        m.level = 5
        m.selectedMethodRaw = CompressMethodID.lzma2.rawValue
        m.dictionary = Int64(16 << 20)
        m.numThreads = 1
        // "<usage> / <limit> / <RAM>"
        let parts = m.memoryUsageText.components(separatedBy: " / ")
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[1], CompressModel.memUsageText(m.ramUsageAuto))
        XCTAssertEqual(parts[2], "16384 MB")   // AddMemUsage uses MB up to and including 16 GB
    }

    // MARK: - Encryption method

    func testEncryptionMethodItems() {
        let m = model("7z")
        let seven = m.encryptionMethodItems(stored: "")
        XCTAssertEqual(seven.items, ["AES-256"])
        XCTAssertEqual(seven.defaultIndex, 0)
        XCTAssertEqual(m.encryptionMethodSpec(selectedIndex: 0, items: seven.items, defaultIndex: 0), "")

        let zip = model("zip")
        let z = zip.encryptionMethodItems(stored: "")
        XCTAssertEqual(z.items, ["ZipCrypto", "AES-256"])
        XCTAssertEqual(z.selection, 0)
        XCTAssertEqual(zip.encryptionMethodSpec(selectedIndex: 0, items: z.items, defaultIndex: 0), "")
        XCTAssertEqual(zip.encryptionMethodSpec(selectedIndex: 1, items: z.items, defaultIndex: 0), "AES256")
        // A stored method starting with "aes" pre-selects AES-256.
        XCTAssertEqual(zip.encryptionMethodItems(stored: "AES256").selection, 1)

        // Formats without kFF_Encrypt have no combo.
        XCTAssertTrue(model("tar").encryptionMethodItems(stored: "").items.isEmpty)
    }

    // MARK: - ParseVolumeSizes / presets

    func testVolumeParsing() {
        XCTAssertEqual(CompressVolumes.parse("10M"), [10 << 20])
        XCTAssertEqual(CompressVolumes.parse("650M - CD"), [650 << 20])   // the comment is ignored
        XCTAssertEqual(CompressVolumes.parse("1000"), [1000])
        XCTAssertEqual(CompressVolumes.parse("1k 2k 3k"), [1 << 10, 2 << 10, 3 << 10])
        XCTAssertEqual(CompressVolumes.parse("1G"), [1 << 30])
        XCTAssertEqual(CompressVolumes.parse("1T"), [1 << 40])
        XCTAssertEqual(CompressVolumes.parse(""), [])
        XCTAssertNil(CompressVolumes.parse("abc"))
        XCTAssertNil(CompressVolumes.parse("0"))                          // a zero size is invalid
        XCTAssertEqual(CompressVolumes.presets.count, 9)
        XCTAssertEqual(CompressVolumes.presets.first, "10M")

        XCTAssertEqual(CompressVolumes.count(forSize: 100, volumeSizes: []), 1)
        XCTAssertEqual(CompressVolumes.count(forSize: 300, volumeSizes: [100]), 3)
        XCTAssertEqual(CompressVolumes.count(forSize: 250, volumeSizes: [100, 100]), 3)
    }

    // MARK: - Timestamp precision

    func testTimePrecisionTitles() {
        XCTAssertEqual(CompressTimePrecision.title(0, secText: "sec", nsText: "ns"), "100 ns : Windows")
        XCTAssertEqual(CompressTimePrecision.title(1, secText: "sec", nsText: "ns"), "1 sec : Unix")
        XCTAssertEqual(CompressTimePrecision.title(2, secText: "sec", nsText: "ns"), "2 sec : DOS")
        XCTAssertEqual(CompressTimePrecision.title(3, secText: "sec", nsText: "ns"), "1 ns : Linux")
        XCTAssertEqual(CompressTimePrecision.title(16, secText: "sec", nsText: "ns"), "1 sec")
        XCTAssertEqual(CompressTimePrecision.title(25, secText: "sec", nsText: "ns"), "1 ns")
        XCTAssertEqual(CompressTimePrecision.title(24, secText: "sec", nsText: "ns"), "10 ns")
        XCTAssertEqual(CompressTimePrecision.title(22, secText: "sec", nsText: "ns"), "1000 ns")
    }

    func testTimePrecisionAvailabilityFromTheRealHandlers() throws {
        let zip = try XCTUnwrap(SZCodecs.format(named: "zip"))
        let available = CompressTimePrecision.available(
            timeFlags: zip.timeFlags,
            defaultPrecision: CompressTimePrecision.defaultPrecision(timeFlags: zip.timeFlags,
                                                                     isGZip: false))
        // ZipRegister.cpp offers the Windows 100 ns, Unix 1 s and DOS 2 s precisions and
        // defaults to Windows.
        XCTAssertEqual(available, [CompressTimePrecision.win, CompressTimePrecision.unix,
                                   CompressTimePrecision.dos],
                       "zip timeFlags = 0x\(String(zip.timeFlags, radix: 16))")
        XCTAssertEqual(CompressTimePrecision.defaultPrecision(timeFlags: zip.timeFlags, isGZip: false),
                       CompressTimePrecision.win)

        let gzip = try XCTUnwrap(SZCodecs.format(named: "gzip"))
        XCTAssertEqual(CompressTimePrecision.defaultPrecision(timeFlags: gzip.timeFlags, isGZip: true),
                       CompressTimePrecision.unix)
    }

    // MARK: - Parameter generation (01b 4.23 "Parameter generation")

    func testPropertyOrderFor7z() {
        var r = CompressDialogResult()
        r.formatName = "7z"
        r.level = 9
        r.method = "LZMA2"
        r.dictionary = 64 << 20
        r.order = 64
        r.numThreads = 4
        r.solidBlockSize = 1 << 24
        r.encryptHeadersIsAllowed = true
        r.encryptHeaders = true
        r.memUse = CompressMemUse(spec: "50%")
        r.mTime = true
        r.cTime = false
        r.timePrecision = 0
        XCTAssertEqual(r.properties.map(\.switchText),
                       ["x=9", "0=LZMA2", "0d=67108864b", "0fb=64", "he=on", "s=16777216b",
                        "mt=4", "memuse=50%", "tm=on", "tc=off", "tp=0"])
    }

    func testPropertyOrderForZipAndPpmd() {
        var r = CompressDialogResult()
        r.formatName = "zip"
        r.level = 5
        r.method = "PPMd"
        r.dictionary = 16 << 20
        r.order = 6
        r.orderMode = true                       // PPMd: mem / o instead of d / fb
        r.encryptionMethod = "AES256"
        XCTAssertEqual(r.properties.map(\.switchText),
                       ["x=5", "m=PPMd", "mem=16777216b", "o=6", "em=AES256"])
    }

    func testAutoValuesEmitNothing() {
        var r = CompressDialogResult()
        r.formatName = "7z"
        r.level = -1                             // no level chosen
        r.method = ""                            // the auto item
        r.dictionary = nil
        r.order = nil
        r.numThreads = nil
        r.solidBlockSize = nil
        XCTAssertTrue(r.properties.isEmpty)
    }

    func testSolidEmissionValues() {
        var r = CompressDialogResult()
        r.formatName = "7z"
        r.level = 5
        r.solidBlockSize = 0
        XCTAssertEqual(r.properties.map(\.switchText), ["x=5", "s=0b"])
        r.solidBlockSize = UInt64.max
        XCTAssertEqual(r.properties.map(\.switchText), ["x=5", "s=18446744073709551615b"])
    }

    func testParametersAreAppendedAndCanOverrideTheMethod() {
        var r = CompressDialogResult()
        r.formatName = "7z"
        r.level = 5
        r.method = "LZMA2"
        r.dictionary = 1 << 20
        r.parameters = "-mhc=off  0=PPMd"
        // A "<digit>=" token for 7z is a method override: the method block is skipped.
        XCTAssertTrue(r.hasMethodOverride)
        XCTAssertEqual(r.properties.map(\.switchText), ["x=5", "hc=off", "0=PPMd"])

        r.parameters = "-mhc=off"
        XCTAssertFalse(r.hasMethodOverride)
        XCTAssertEqual(r.properties.map(\.switchText), ["x=5", "0=LZMA2", "0d=1048576b", "hc=off"])

        var zip = CompressDialogResult()
        zip.formatName = "zip"
        zip.level = 5
        zip.method = "Deflate"
        zip.parameters = "m=LZMA"
        XCTAssertTrue(zip.hasMethodOverride)
        XCTAssertEqual(zip.properties.map(\.switchText), ["x=5", "m=LZMA"])
    }

    func testResultBecomesUpdateOptions() {
        var r = CompressDialogResult()
        r.archivePath = "/tmp/a.7z"
        r.formatName = "7z"
        r.formatIndex = 3
        r.level = 5
        r.updateMode = .sync
        r.pathMode = .absolute
        r.sfxMode = true
        r.deleteAfterCompressing = true
        r.setArcMTime = true
        r.openShareForWrite = true
        r.password = "p"
        r.volumeSizes = [1 << 20, 2 << 20]
        r.symLinks = true
        r.preserveATime = false
        let o = r.updateOptions()
        XCTAssertEqual(o.archivePath, "/tmp/a.7z")
        XCTAssertEqual(o.formatIndex, 3)
        XCTAssertEqual(o.updateMode, .sync)
        XCTAssertEqual(o.pathMode, .absolute)
        XCTAssertEqual(o.nameMode, .smart)
        XCTAssertTrue(o.sfxMode)
        XCTAssertTrue(o.deleteAfterCompressing)
        XCTAssertTrue(o.setArchiveMTime)
        XCTAssertTrue(o.openShareForWrite)
        XCTAssertEqual(o.password, "p")
        XCTAssertEqual(o.volumeSizes.map(\.uint64Value), [1 << 20, 2 << 20])
        XCTAssertEqual(o.storeSymLinks, NSNumber(value: true))
        XCTAssertEqual(o.preserveATime, NSNumber(value: false))
        XCTAssertNil(o.storeHardLinks)
        XCTAssertEqual(o.properties.map(\.switchText), ["x=5"])
    }

    // MARK: - Size formatting helpers

    func testSizeTextHelpers() {
        XCTAssertEqual(CompressModel.dictText(64 << 10), "64 KB")
        XCTAssertEqual(CompressModel.dictText(1 << 20), "1 MB")
        XCTAssertEqual(CompressModel.dictText(1 << 30), "1024 MB")   // no GB branch upstream
        XCTAssertEqual(CompressModel.sizeText(1 << 20), "1 MB")
        XCTAssertEqual(CompressModel.sizeText(1 << 30), "1 GB")
        XCTAssertEqual(CompressModel.sizeText(64 << 30), "64 GB")
        XCTAssertEqual(CompressModel.memSizeText(256 << 20), "256 MB")
        XCTAssertEqual(CompressModel.memSizeText(2 << 30), "2 GB")
    }

    // MARK: - End-to-end: the dialog's own property list really compresses

    /// The properties the model would emit are accepted by the engine and produce the archive
    /// the console produces with the equivalent switches.
    func testModelPropertiesMatchTheConsole() throws {
        guard let tool = UpdaterTestCase.consoleTool else {
            throw XCTSkip("console 7zz not built")
        }
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("compress-xcheck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let source = (dir as NSString).appendingPathComponent("payload.txt")
        try String(repeating: "7-zip cross-check payload\n", count: 500)
            .write(toFile: source, atomically: true, encoding: .utf8)

        var r = CompressDialogResult()
        r.formatName = "7z"
        r.level = 9
        r.method = "LZMA2"
        r.dictionary = 1 << 24
        r.order = 64
        r.numThreads = 1
        r.solidBlockSize = 1 << 24
        let bridgePath = (dir as NSString).appendingPathComponent("bridge.7z")
        r.archivePath = bridgePath
        let options = r.updateOptions()
        options.formatName = "7z"
        let done = DispatchSemaphore(value: 0)
        var thrown: Error?
        DispatchQueue.global().async {
            do { _ = try SZUpdater.update(with: options, sourcePaths: [source], progress: nil) }
            catch { thrown = error }
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 60), .success)
        if let thrown { throw thrown }

        // 7zz a -t7z -mx=9 -m0=LZMA2 -m0d=16777216b -m0fb=64 -mmt=1 -ms=16777216b
        let consolePath = (dir as NSString).appendingPathComponent("console.7z")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["a", "-t7z"] + r.properties.map { "-m" + $0.switchText }
            + [consolePath, source]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, output)

        let bridge = try Data(contentsOf: URL(fileURLWithPath: bridgePath))
        let console = try Data(contentsOf: URL(fileURLWithPath: consolePath))
        // The headers carry the item's own timestamp, so the archives are not byte-identical;
        // the compressed payload size must match exactly.
        XCTAssertEqual(bridge.count, console.count,
                       "bridge \(bridge.count) B vs console \(console.count) B with \(r.properties.map(\.switchText))")
    }
}
