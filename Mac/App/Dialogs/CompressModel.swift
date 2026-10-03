// CompressModel.swift -- everything the Compress dialog computes, without any AppKit:
// the static format table (`g_Formats`), the level / method / dictionary / word-size /
// solid / thread / memory-use item lists with their auto rules, the memory estimation, the
// `-m` property emission order and the per-format settings round-trip.
//
// This is a line-by-line port of the computation half of `CPP/7zip/UI/GUI/CompressDialog.cpp`
// (01b-fm-dialogs-settings.md section 4.23, "Format table", "Automatic values",
// "OnOK validation", "Parameter generation"). Keeping it AppKit-free makes every rule
// unit-testable (Mac/Tests/SevenZipKitTests/CompressModelTests.swift).

import Foundation
import SevenZipKit

// ---------------------------------------------------------------------------
// MARK: - Methods (kMethodsNames, EMethodID)

/// `EMethodID` (CompressDialog.cpp:122-141). The raw value **is** the enum index, which is
/// what the per-format `Method` setting is compared against.
enum CompressMethodID: Int, CaseIterable {
    case copy = 0, lzma, lzma2, ppmd, bzip2, deflate, deflate64, ppmdZip
    case sha256, sha1, crc32, crc64, gnu, posix

    /// `kMethodsNames[]` (CompressDialog.cpp:143-160). Note that `ppmd` and `ppmdZip` share
    /// the name "PPMd" — the zip variant is a different encoder with different item lists.
    var name: String {
        switch self {
        case .copy: return "Copy"
        case .lzma: return "LZMA"
        case .lzma2: return "LZMA2"
        case .ppmd: return "PPMd"
        case .bzip2: return "BZip2"
        case .deflate: return "Deflate"
        case .deflate64: return "Deflate64"
        case .ppmdZip: return "PPMd"
        case .sha256: return "SHA256"
        case .sha1: return "SHA1"
        case .crc32: return "CRC32"
        case .crc64: return "CRC64"
        case .gnu: return "GNU"
        case .posix: return "POSIX"
        }
    }

    /// `g_7zSfxMethods` (CompressDialog.cpp:162-168) / `IsMethodSupportedBySfx`.
    var isSupportedBySFX: Bool {
        switch self {
        case .copy, .lzma, .lzma2, .ppmd: return true
        default: return false
        }
    }

    /// `GetOrderMode` (CompressDialog.cpp:2363-2372): PPMd emits `mem`/`o` instead of `d`/`fb`.
    var usesOrderMode: Bool { self == .ppmd || self == .ppmdZip }
}

// ---------------------------------------------------------------------------
// MARK: - The static format table (g_Formats)

/// `CFormatInfo::Flags` (CompressDialog.cpp:236-248).
struct CompressFormatFlags: OptionSet {
    let rawValue: UInt32
    static let filter = CompressFormatFlags(rawValue: 1 << 0)            // kFF_Filter
    static let solid = CompressFormatFlags(rawValue: 1 << 1)             // kFF_Solid
    static let multiThread = CompressFormatFlags(rawValue: 1 << 2)       // kFF_MultiThread
    static let encrypt = CompressFormatFlags(rawValue: 1 << 3)           // kFF_Encrypt
    static let encryptFileNames = CompressFormatFlags(rawValue: 1 << 4)  // kFF_EncryptFileNames
    static let memUse = CompressFormatFlags(rawValue: 1 << 5)            // kFF_MemUse
    static let sfx = CompressFormatFlags(rawValue: 1 << 6)               // kFF_SFX
}

/// One `g_Formats[]` entry (CompressDialog.cpp:270-355).
struct CompressStaticFormat {
    let name: String
    let levelsMask: UInt32
    let methods: [CompressMethodID]
    let flags: CompressFormatFlags

    var hasMethods: Bool { !methods.isEmpty }

    /// Levels the combo offers, in order (one item per set bit of `LevelsMask`).
    var levels: [Int] { (0..<32).filter { (levelsMask >> UInt32($0)) & 1 == 1 } }

    /// `g_Formats[]` verbatim. Entry 0 ("") is the fallback for any other update-capable
    /// handler (`GetStaticFormatIndex` returns 0 when the name does not match).
    static let all: [CompressStaticFormat] = [
        CompressStaticFormat(name: "", levelsMask: (1 << 10) - 1, methods: [],
                             flags: [.multiThread, .memUse]),
        CompressStaticFormat(name: "7z", levelsMask: (1 << 10) - 1,
                             methods: [.lzma2, .lzma, .ppmd, .bzip2, .deflate, .deflate64, .copy],
                             flags: [.filter, .solid, .multiThread, .encrypt,
                                     .encryptFileNames, .memUse, .sfx]),
        CompressStaticFormat(name: "Zip",
                             levelsMask: (1 << 0) | (1 << 1) | (1 << 3) | (1 << 5) | (1 << 7) | (1 << 9),
                             methods: [.deflate, .deflate64, .bzip2, .lzma, .ppmdZip],
                             flags: [.multiThread, .encrypt, .memUse]),
        CompressStaticFormat(name: "GZip", levelsMask: (1 << 1) | (1 << 5) | (1 << 7) | (1 << 9),
                             methods: [.deflate], flags: [.memUse]),
        CompressStaticFormat(name: "BZip2",
                             levelsMask: (1 << 1) | (1 << 3) | (1 << 5) | (1 << 7) | (1 << 9),
                             methods: [.bzip2], flags: [.multiThread, .memUse]),
        CompressStaticFormat(name: "xz", levelsMask: (1 << 10) - 1 - (1 << 0),
                             methods: [.lzma2], flags: [.solid, .multiThread, .memUse]),
        CompressStaticFormat(name: "Tar", levelsMask: 1 << 0, methods: [.gnu, .posix], flags: []),
        CompressStaticFormat(name: "wim", levelsMask: 1 << 0, methods: [], flags: []),
        CompressStaticFormat(name: "Hash", levelsMask: 0, methods: [.sha256, .sha1], flags: []),
    ]

    /// `GetStaticFormatIndex` (CompressDialog.cpp:1551-1558): match by name, fall back to 0.
    static func forFormatName(_ name: String) -> CompressStaticFormat {
        all.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } ?? all[0]
    }
}

// ---------------------------------------------------------------------------
// MARK: - Combo items

/// One combo entry: the text the user sees and the item data the dialog reads back.
/// `data == CompressModel.autoValue` is the `*  <value>` auto item, whose property is not
/// emitted at all (`GetDictSpec` and friends return -1).
struct CompressComboItem: Equatable {
    let title: String
    let data: Int64
    var isAuto: Bool { data == CompressModel.autoValue }
}

// ---------------------------------------------------------------------------
// MARK: - The model

/// The Compress dialog's state plus every derived value. Mutating a property and reading a
/// list back reproduces the Windows cascade (`FormatChanged` -> `SetLevel` -> `SetMethod` ->
/// `SetDictionary` / `SetOrder` / `SetSolidBlockSize` / `SetNumThreads` -> `SetMemoryUsage`).
final class CompressModel {

    /// `(UInt32)(Int32)-1` / `k_Auto_Dict`: "auto, emit nothing".
    static let autoValue: Int64 = -1
    /// `kSolidLog_NoSolid` (IDS_COMPRESS_NON_SOLID 4072).
    static let solidLogNonSolid: Int64 = 0
    /// `kSolidLog_FullSolid` (IDS_COMPRESS_SOLID 4073) -> `s=18446744073709551615b`.
    static let solidLogFullSolid: Int64 = 64
    /// `kLzmaMaxDictSize = 15 << 28` = 3840 MB (CompressDialog.cpp:91).
    static let lzmaMaxDictSize: UInt64 = 15 << 28
    /// `k_Auto_Prefix` (CompressDialog.cpp:1620).
    static let autoPrefix = "*  "

    // MARK: state

    /// The engine format (`CArcInfoEx`) currently selected.
    private(set) var arcInfo: SZFormatInfo
    /// The matching `g_Formats[]` entry.
    private(set) var staticFormat: CompressStaticFormat

    /// The level combo's selection. `-1` = nothing selectable (Hash).
    var level: Int = 5
    /// The method combo's item data: nil = the auto item, else a `CompressMethodID` raw value
    /// (or an index past `CompressMethodID.allCases.count` for an external codec).
    var selectedMethodRaw: Int?
    /// Dictionary combo item data (`autoValue` = auto).
    var dictionary: Int64 = CompressModel.autoValue
    /// Word-size combo item data.
    var order: Int64 = CompressModel.autoValue
    /// Solid combo item data (a log2, or `solidLogNonSolid` / `solidLogFullSolid`).
    var blockLogSize: Int64 = CompressModel.autoValue
    /// Threads combo item data.
    var numThreads: Int64 = CompressModel.autoValue
    /// The `MemUse` spec string the combo selected ("" = the auto 80 % item).
    var memUseSpec: String = ""
    /// "Create SFX archive" (IDX_COMPRESS_SFX 4012).
    var sfxMode = false
    /// External single-stream codecs offered as extra 7z methods (`SetMethods(userCodecs)`).
    /// Empty on macOS: there are no `Codecs\` DLLs (01 section 9).
    var externalMethods: [String] = []

    // MARK: RAM (OnInit, CompressDialog.cpp:437-459)

    /// `GetRamSize()`.
    let ramSize: UInt64
    let ramSizeDefined: Bool
    /// `_ramSize_Reduced = max(_ramSize, 64 MB)`.
    var ramSizeReduced: UInt64 { max(ramSize, 64 << 20) }
    /// `_ramUsage_Auto` = 80 % of the reduced size (the handlers' own auto limit).
    var ramUsageAuto: UInt64 { CompressModel.percent(of: ramSizeReduced, 80) }

    init(arcInfo: SZFormatInfo, ramSize: UInt64 = CompressModel.physicalMemory()) {
        self.arcInfo = arcInfo
        self.staticFormat = CompressStaticFormat.forFormatName(arcInfo.name)
        self.ramSize = ramSize
        self.ramSizeDefined = ramSize != 0
    }

    static func physicalMemory() -> UInt64 { hardwareOverride?.ram ?? ProcessInfo.processInfo.physicalMemory }

    /// `Calc_From_Val_Percents`: percent of a 64-bit size without overflowing.
    static func percent(of size: UInt64, _ percent: UInt64) -> UInt64 {
        if percent == 0 { return 0 }
        if size <= UInt64.max / percent { return size * percent / 100 }
        return size / 100 * percent
    }

    /// Switching the format keeps the dialog's own idea of the level etc.; the caller then
    /// re-applies the per-format settings (`FormatChanged`).
    func setFormat(_ info: SZFormatInfo) {
        arcInfo = info
        staticFormat = CompressStaticFormat.forFormatName(info.name)
    }

    // MARK: derived format predicates

    var is7z: Bool { arcInfo.name.caseInsensitiveCompare("7z") == .orderedSame }
    var isZip: Bool { arcInfo.name.caseInsensitiveCompare("zip") == .orderedSame }
    var isXz: Bool { arcInfo.name.caseInsensitiveCompare("xz") == .orderedSame }
    var isTar: Bool { arcInfo.name.caseInsensitiveCompare("tar") == .orderedSame }
    var isGZip: Bool { arcInfo.name.caseInsensitiveCompare("gzip") == .orderedSame }
    var isHashHandler: Bool { arcInfo.isHashHandler }

    /// `GetLevel2`: the level with `-1` mapped to 5.
    var level2: Int { level < 0 ? 5 : level }

    // MARK: levels (SetLevel2, CompressDialog.cpp:1572-1618)

    /// `g_Levels[]` lang IDs; 0 = the number only.
    static let levelLangIDs: [UInt32] = [4050, 4051, 0, 4052, 0, 4053, 0, 4054, 0, 4055]
    static let levelFallbacks = ["Store", "Fastest", "", "Fast", "", "Normal", "", "Maximum", "", "Ultra"]

    /// The level combo: `"<n>"` or `"<n> - <name>"`.
    func levelItems(_ localize: (UInt32, String) -> String) -> [CompressComboItem] {
        staticFormat.levels.map { i in
            var title = "\(i)"
            if i < CompressModel.levelLangIDs.count {
                let langID = CompressModel.levelLangIDs[i]
                if langID != 0 {
                    title += " - " + localize(langID, CompressModel.levelFallbacks[i])
                }
            }
            return CompressComboItem(title: title, data: Int64(i))
        }
    }

    // MARK: methods (SetMethod2, CompressDialog.cpp:1627-1709)

    /// The method combo, in order. Empty when level 0 is selected for a non-tar, non-hash
    /// format, or when the format declares no methods at all.
    /// The first item is the auto item (`*  <name>`, data `autoValue`).
    var methodItems: [CompressComboItem] {
        guard staticFormat.hasMethods else { return [] }
        if level == 0 && !isHashHandler && !isTar { return [] }
        var items: [CompressComboItem] = []
        var candidates: [(raw: Int, name: String)] = []
        for m in staticFormat.methods {
            // 7z hides Copy / Deflate / Deflate64 from the combo (CompressDialog.cpp:1664-1668).
            if is7z && (m == .copy || m == .deflate || m == .deflate64) { continue }
            candidates.append((m.rawValue, m.name))
        }
        if is7z {
            for (i, name) in externalMethods.enumerated() {
                candidates.append((CompressMethodID.allCases.count + i, name))
            }
        }
        if sfxMode {
            candidates = candidates.filter { CompressMethodID(rawValue: $0.raw)?.isSupportedBySFX ?? false }
        }
        for (i, c) in candidates.enumerated() {
            if i == 0 {
                items.append(CompressComboItem(title: CompressModel.autoPrefix + c.name,
                                               data: CompressModel.autoValue))
            } else {
                items.append(CompressComboItem(title: c.name, data: Int64(c.raw)))
            }
        }
        return items
    }

    /// `_auto_MethodId`: the method the auto item stands for (the first offered one).
    var autoMethodRaw: Int? {
        guard staticFormat.hasMethods else { return nil }
        if level == 0 && !isHashHandler && !isTar { return nil }
        var candidates = staticFormat.methods.filter { !(is7z && ($0 == .copy || $0 == .deflate || $0 == .deflate64)) }
        if sfxMode { candidates = candidates.filter { $0.isSupportedBySFX } }
        return candidates.first?.rawValue
    }

    /// `GetMethodID`: the explicit selection, else the auto method.
    var methodRaw: Int? { selectedMethodRaw ?? autoMethodRaw }
    var method: CompressMethodID? { methodRaw.flatMap { CompressMethodID(rawValue: $0) } }

    /// `GetMethodSpec()`: the name to emit, empty when the auto item is selected.
    var methodSpec: String {
        guard selectedMethodRaw != nil else { return "" }
        return estimatedMethodName
    }

    /// `GetMethodSpec(estimatedName)`: the name of the effective method (auto or explicit),
    /// used to compare against the stored `Method` setting.
    var estimatedMethodName: String {
        guard !methodItems.isEmpty, let raw = methodRaw else { return "" }
        if let m = CompressMethodID(rawValue: raw) { return m.name }
        let i = raw - CompressMethodID.allCases.count
        return (i >= 0 && i < externalMethods.count) ? externalMethods[i] : ""
    }

    /// `IsMethodEqualTo`: the stored `Method` names the same method as the current selection.
    func isMethodEqual(to stored: String) -> Bool {
        if stored.isEmpty { return methodSpec.isEmpty }
        return stored.caseInsensitiveCompare(estimatedMethodName) == .orderedSame
    }

    // MARK: dictionary (SetDictionary2, CompressDialog.cpp:1859-2153)

    /// `Combo_AddDict2`: `<N> B` / `<N> KB` / `<N> MB` (no GB branch upstream).
    static func dictText(_ size: UInt64) -> String {
        var moveBits: UInt64 = 0
        var suffix = ""
        if size & 0xFFFFF == 0 { moveBits = 20; suffix = "M" }
        else if size & 0x3FF == 0 { moveBits = 10; suffix = "K" }
        return "\(size >> moveBits) \(suffix)B"
    }

    /// `_auto_Dict` for the current method and level; nil when the method is unknown.
    var autoDictionary: UInt64? {
        guard let m = method else { return nil }
        let level = UInt64(level2)
        switch m {
        case .lzma, .lzma2:
            // 64-bit: level <= 4 -> 1 << (2L+16); level <= 8 -> 1 << (L+20); else 1 << 28.
            if level <= 4 { return UInt64(1) << (level * 2 + 16) }
            if level <= 8 { return UInt64(1) << (level + 20) }
            return UInt64(1) << 28
        case .ppmd, .ppmdZip:
            return UInt64(1) << (level + 19)
        case .deflate: return 1 << 15
        case .deflate64: return 1 << 16
        case .bzip2:
            if level >= 5 { return 900 << 10 }
            if level >= 3 { return 500 << 10 }
            return 100 << 10
        case .copy: return 0
        default: return nil
        }
    }

    /// The dictionary-size combo, in order. `storedDictionary` (the per-format `Dictionary`
    /// setting, only honoured when the stored `Method` matches) picks the largest item <= it.
    func dictionaryItems(storedDictionary: Int64?) -> (items: [CompressComboItem], selection: Int) {
        guard let m = method, let auto = autoDictionary else { return ([], -1) }
        var items: [CompressComboItem] = []
        var selection = -1

        func addAuto() {
            items.append(CompressComboItem(title: CompressModel.autoPrefix + CompressModel.dictText(auto),
                                           data: CompressModel.autoValue))
            selection = 0
        }
        func add(_ real: UInt64, show: UInt64? = nil) -> Int {
            items.append(CompressComboItem(title: CompressModel.dictText(show ?? real), data: Int64(bitPattern: real)))
            return items.count - 1
        }

        // -2 is the "at least 4 GB" marker written by SaveOptionsInMem.
        var stored: UInt64? = nil
        if let s = storedDictionary, s != -1 {
            stored = (s == -2) ? UInt64.max : UInt64(bitPattern: s)
        }

        switch m {
        case .lzma, .lzma2:
            if var s = stored, s >= CompressModel.lzmaMaxDictSize { s = CompressModel.lzmaMaxDictSize; stored = s }
            let maxUp: UInt64 = 1 << 32                      // kLzmaMaxDictSize_Up on 64-bit
            addAuto()
            var i = (16 - 1) * 2
            while i <= (32 - 1) * 2 {
                defer { i += 1 }
                if i < (20 - 1) * 2 && i != (16 - 1) * 2 && i != (18 - 1) * 2 { continue }
                if i == (20 - 1) * 2 + 1 { continue }
                let dictUp = UInt64(2 + (i & 1)) << UInt64(i / 2)
                let dict = dictUp >= CompressModel.lzmaMaxDictSize ? CompressModel.lzmaMaxDictSize : dictUp
                let index = add(dict)
                if let s = stored, dict <= s || selection <= 0 { selection = index }
                if dictUp >= maxUp { break }
            }
        case .ppmd:
            let ppmdDefault4g = UInt64(UInt32.max) - (1 << 10) + 1   // (UInt32)0 - (1 << 10)
            let maxUp: UInt64 = 1 << 30                              // kPpmd_MaxDictSize_Up on 64-bit
            if let s = stored, s >= (15 << 28) { stored = ppmdDefault4g }
            addAuto()
            var i = (20 - 1) * 2
            while i <= (32 - 1) * 2 {
                defer { i += 1 }
                if i == (20 - 1) * 2 + 1 { continue }
                let dictUp = UInt64(2 + (i & 1)) << UInt64(i / 2)
                let dict = dictUp >= ppmdDefault4g ? ppmdDefault4g : dictUp
                let index = add(dict, show: dictUp)
                if let s = stored, dict <= s || selection <= 0 { selection = index }
                if dictUp >= maxUp { break }
            }
        case .ppmdZip:
            addAuto()
            for i in 20...28 {
                let dict = UInt64(1) << UInt64(i)
                let index = add(dict)
                if let s = stored, dict <= s || selection <= 0 { selection = index }
            }
        case .deflate, .deflate64:
            addAuto()
        case .bzip2:
            addAuto()
            for i in 1...9 {
                let dict = (UInt64(i) * 100) << 10
                _ = add(dict)
                if let s = stored, UInt64(i) <= s / 100_000 || selection <= 0 { selection = items.count - 1 }
            }
        case .copy:
            _ = add(0)
            selection = 0
        default:
            return ([], -1)
        }
        return (items, selection)
    }

    /// `GetDict2()`: the effective dictionary (auto resolved), or nil for an unknown method.
    var effectiveDictionary: UInt64? {
        if dictionary == CompressModel.autoValue { return autoDictionary }
        return UInt64(bitPattern: dictionary)
    }

    /// `GetDictSpec()`: the value to emit, nil when auto.
    var dictionarySpec: UInt64? {
        dictionary == CompressModel.autoValue ? nil : UInt64(bitPattern: dictionary)
    }

    // MARK: word size (SetOrder2, CompressDialog.cpp:2213-2362)

    /// `_auto_Order`.
    var autoOrder: Int? {
        guard let m = method else { return nil }
        let level = level2
        switch m {
        case .lzma, .lzma2: return level < 7 ? 32 : 64
        case .deflate, .deflate64:
            if level >= 9 { return 128 }
            if level >= 7 { return 64 }
            return 32
        case .ppmd:
            if level >= 9 { return 32 }
            if level >= 7 { return 16 }
            if level >= 5 { return 6 }
            return 4
        case .ppmdZip: return level + 3
        default: return nil
        }
    }

    func orderItems(storedOrder: Int64?) -> (items: [CompressComboItem], selection: Int) {
        guard let m = method, let auto = autoOrder else { return ([], -1) }
        var items: [CompressComboItem] = []
        var selection = -1
        items.append(CompressComboItem(title: CompressModel.autoPrefix + "\(auto)", data: CompressModel.autoValue))
        selection = 0
        let stored: Int64? = (storedOrder == -1) ? nil : storedOrder

        func add(_ order: Int) -> Int {
            items.append(CompressComboItem(title: "\(order)", data: Int64(order)))
            return items.count - 1
        }

        switch m {
        case .lzma, .lzma2:
            for i in (2 * 2)..<(8 * 2) {
                var order = (2 + (i & 1)) << (i / 2)
                if order > 256 { order = 273 }
                let index = add(order)
                if let s = stored, Int64(order) <= s || selection <= 0 { selection = index }
            }
        case .deflate, .deflate64:
            for i in (2 * 2)..<(8 * 2) {
                var order = (2 + (i & 1)) << (i / 2)
                if order > 256 { order = (m == .deflate64) ? 257 : 258 }
                let index = add(order)
                if let s = stored, Int64(order) <= s || selection <= 0 { selection = index }
            }
        case .ppmd:
            var i = 0
            while true {
                var order = i + 2
                if i >= 2 { order = (4 + ((i - 2) & 3)) << ((i - 2) / 4) }
                let index = add(order)
                if let s = stored, Int64(order) <= s || selection <= 0 { selection = index }
                if order >= 32 { break }
                i += 1
            }
        case .ppmdZip:
            for i in 2...16 {
                let index = add(i)
                if let s = stored, Int64(i) <= s || selection <= 0 { selection = index }
            }
        default:
            return ([], -1)
        }
        return (items, selection)
    }

    /// `GetOrderSpec()`.
    var orderSpec: Int64? { order == CompressModel.autoValue ? nil : order }
    /// `GetOrderMode()`.
    var orderMode: Bool { method?.usesOrderMode ?? false }

    // MARK: solid block size (SetSolidBlockSize2, CompressDialog.cpp:2405-2521)

    /// `Add_Size`: `<N> B/KB/MB/GB`.
    static func sizeText(_ value: UInt64) -> String {
        var moveBits: UInt64 = 0
        var suffix = ""
        if value & 0x3FFF_FFFF == 0 { moveBits = 30; suffix = "G" }
        else if value & 0xFFFFF == 0 { moveBits = 20; suffix = "M" }
        else if value & 0x3FF == 0 { moveBits = 10; suffix = "K" }
        return "\(value >> moveBits) \(suffix)B"
    }

    /// `Get_Lzma2_ChunkSize(dict)`: `dict * 4` clamped to 1 MB … 256 MB, never below `dict`,
    /// rounded up to a multiple of 1 MB.
    static func lzma2ChunkSize(_ dict: UInt64) -> UInt64 {
        var cs = dict << 2
        let minSize: UInt64 = 1 << 20
        let maxSize: UInt64 = 1 << 28
        if cs < minSize { cs = minSize }
        if cs > maxSize { cs = maxSize }
        if cs < dict { cs = dict }
        cs += minSize - 1
        cs &= ~(minSize - 1)
        return cs
    }

    /// `_auto_Solid`, or nil when the combo is not offered (non-solid format, or level 0).
    var autoSolidBlockSize: UInt64? {
        guard staticFormat.flags.contains(.solid), level2 != 0, level != 0 else { return nil }
        let dict = effectiveDictionary ?? (1 << 25)   // default dict for unknown methods
        let cs = CompressModel.lzma2ChunkSize(dict)
        var blockSize = cs                             // xz: the chunk size itself
        if is7z {
            var maxSize: UInt64 = 1 << 32
            if method == .lzma2 {
                blockSize = cs << 6
                maxSize = 1 << 34
            } else {
                var dict2 = dict
                if method == .bzip2 {
                    dict2 /= 100_000
                    if dict2 < 1 { dict2 = 1 }
                    dict2 *= 100_000
                }
                blockSize = dict2 << 7
            }
            let minSize: UInt64 = 1 << 24
            if blockSize < minSize { blockSize = minSize }
            if blockSize > maxSize { blockSize = maxSize }
        }
        return blockSize
    }

    func solidItems(storedBlockLogSize: Int64?,
                    localize: (UInt32, String) -> String) -> (items: [CompressComboItem], selection: Int) {
        guard let auto = autoSolidBlockSize else { return ([], -1) }
        var items: [CompressComboItem] = []
        var selection = 0
        items.append(CompressComboItem(title: CompressModel.autoPrefix + CompressModel.sizeText(auto),
                                       data: CompressModel.autoValue))
        let stored: Int64? = (storedBlockLogSize == -1) ? nil : storedBlockLogSize

        if is7z {
            items.append(CompressComboItem(title: localize(4072, "Non-solid"),
                                           data: CompressModel.solidLogNonSolid))
            if stored == CompressModel.solidLogNonSolid { selection = items.count - 1 }
        }
        for i in 20...36 {
            items.append(CompressComboItem(title: CompressModel.sizeText(UInt64(1) << UInt64(i)), data: Int64(i)))
            let index = items.count - 1
            if let s = stored, Int64(i) <= s || index <= 1 { selection = index }
        }
        items.append(CompressComboItem(title: localize(4073, "Solid"), data: CompressModel.solidLogFullSolid))
        if stored == CompressModel.solidLogFullSolid { selection = items.count - 1 }
        return (items, selection)
    }

    /// `GetBlockSizeSpec()`.
    var blockLogSizeSpec: Int64? { blockLogSize == CompressModel.autoValue ? nil : blockLogSize }

    /// `OnOK` (CompressDialog.cpp:1160-1168): the `s=` value, nil when nothing is emitted.
    var solidBlockSizeBytes: UInt64? {
        guard staticFormat.flags.contains(.solid) else { return nil }
        guard let log = blockLogSizeSpec else { return nil }
        if log == 0 { return 0 }
        if log >= 64 { return UInt64.max }
        return UInt64(1) << UInt64(log)
    }

    // MARK: threads (SetNumThreads2, CompressDialog.cpp:2559-2712)

    /// In-process test hook: the hardware the figures are computed for. The `wincompare` scope sets
    /// it to the reference Windows PC (8 threads, 21 240 692 736 bytes) so the thread lists and
    /// memory figures can be compared with 7zG's line by line; nil (always, in the product) means
    /// this Mac.
    static var hardwareOverride: (threads: Int, ram: UInt64)?

    /// Process thread count (`CProcessAffinity::Get_NumProcessThreads`).
    static var processThreadCount: Int { hardwareOverride?.threads ?? ProcessInfo.processInfo.activeProcessorCount }
    /// System thread count.
    static var systemThreadCount: Int { hardwareOverride?.threads ?? ProcessInfo.processInfo.processorCount }

    /// `IDT_COMPRESS_HARDWARE_THREADS 112`: "/ N" or "/ N / M".
    var hardwareThreadsText: String {
        let cpus = CompressModel.processThreadCount
        let hw = CompressModel.systemThreadCount
        return cpus == hw ? "/ \(cpus)" : "/ \(cpus) / \(hw)"
    }

    /// `numAlgoThreadsMax` (CompressDialog.cpp:2609-2627).
    var maxAlgorithmThreads: Int {
        if isZip { return 8 << (8 / 2) }          // 128 on 64-bit
        if isXz { return 256 * 2 }
        switch method {
        case .lzma: return 2
        case .lzma2: return 256 * 2
        case .bzip2: return 64
        case .copy, .ppmd, .deflate, .deflate64, .ppmdZip: return 1
        default: return CompressModel.systemThreadCount * 2
        }
    }

    /// `_auto_NumThreads`: `min(numCPUs, max)`, then reduced while the memory estimate is over
    /// the limit (zip one thread at a time, LZMA2 in units of block threads).
    var autoNumThreads: Int {
        guard staticFormat.flags.contains(.multiThread) else { return 1 }
        let maxThreads = maxAlgorithmThreads
        var autoThreads = min(CompressModel.processThreadCount, maxThreads)
        guard ramSizeDefined, autoThreads > 1 else { return autoThreads }
        let limit = memUseLimitBytes
        if isZip {
            while autoThreads > 1 {
                let usage = memoryUsage(threads: autoThreads, dictionary: effectiveDictionary).compressed
                if let usage, usage <= limit { break }
                if usage == nil { break }
                autoThreads -= 1
            }
        } else if method == .lzma2 {
            let threads1 = level2 >= 5 ? 2 : 1
            var numBlockThreads = autoThreads / threads1
            while numBlockThreads > 1 {
                autoThreads = numBlockThreads * threads1
                let usage = memoryUsage(threads: autoThreads, dictionary: effectiveDictionary).compressed
                if let usage, usage <= limit { break }
                if usage == nil { break }
                numBlockThreads -= 1
            }
            autoThreads = numBlockThreads * threads1
        }
        return autoThreads
    }

    func threadItems(storedNumThreads: Int64?) -> (items: [CompressComboItem], selection: Int) {
        guard staticFormat.flags.contains(.multiThread) else { return ([], -1) }
        var items: [CompressComboItem] = []
        var selection = -1
        let auto = autoNumThreads
        let maxThreads = maxAlgorithmThreads
        let useAuto = (storedNumThreads == nil || storedNumThreads == -1)
        items.append(CompressComboItem(title: CompressModel.autoPrefix + "\(auto)", data: CompressModel.autoValue))
        if useAuto { selection = 0 }
        if maxThreads != auto || auto != 1 {
            var i = 1
            while i <= CompressModel.systemThreadCount * 2 && i <= maxThreads {
                items.append(CompressComboItem(title: "\(i)", data: Int64(i)))
                if !useAuto, Int64(i) == storedNumThreads { selection = items.count - 1 }
                i += 1
            }
        }
        if selection < 0 { selection = 0 }
        return (items, selection)
    }

    /// `GetNumThreadsSpec()`.
    var numThreadsSpec: Int64? { numThreads == CompressModel.autoValue ? nil : numThreads }
    /// `GetNumThreads2()`: the effective count.
    var effectiveNumThreads: Int { numThreads == CompressModel.autoValue ? autoNumThreads : Int(numThreads) }

    // MARK: memory use combo (SetMemUseCombo, CompressDialog.cpp:2767-2855)

    /// `AddMemSize`: `<N> MB` or `<N> GB`.
    static func memSizeText(_ size: UInt64) -> String {
        if size >= (UInt64(1) << 31) && size & 0x3FFF_FFFF == 0 { return "\(size >> 30) GB" }
        return "\(size >> 20) MB"
    }

    /// One mem-use item: `title` for the combo, `spec` for the `MemUse` setting and `memuse=`.
    struct MemUseItem: Equatable {
        let title: String
        /// "" for the auto item (nothing is emitted), else "NN%" or "<N>M"/"<N>G".
        let spec: String
    }

    /// The combo's items and the selection for `stored` (the per-format `MemUse` string).
    func memUseItems(stored: String) -> (items: [MemUseItem], selection: Int) {
        guard staticFormat.flags.contains(.memUse) else { return ([], -1) }
        var items: [MemUseItem] = []
        var selection = 0
        var curPercents: UInt64 = 0
        var curBytes: UInt64 = 0
        var needPercents = false
        var needBytes = false
        if let mu = CompressMemUse(spec: stored) {
            if mu.isPercent { curPercents = mu.value; needPercents = true }
            else { curBytes = mu.bytes(ram: ramSizeReduced); needBytes = true }
        }

        func addPercent(_ v: UInt64, isDefault: Bool = false) -> Int {
            let text = "\(v)%"
            items.append(MemUseItem(title: isDefault ? CompressModel.autoPrefix + text : text,
                                    spec: isDefault ? "" : text))
            return items.count - 1
        }
        func addBytes(_ v: UInt64) -> Int {
            let title = CompressModel.memSizeText(v)
            // The stored spec drops the spaces and the trailing "B": "512M", "3G".
            var spec = title.replacingOccurrences(of: " ", with: "")
            if spec.hasSuffix("B") { spec.removeLast() }
            items.append(MemUseItem(title: title, spec: spec))
            return items.count - 1
        }

        _ = addPercent(80, isDefault: true)        // 80 % is the handlers' own auto limit

        var i: UInt64 = 10
        while true {
            let size: UInt64? = i > 100 ? nil : i
            if needPercents, let s = size, s >= curPercents {
                selection = addPercent(curPercents)
                needPercents = false
                if s == curPercents { i += 10; continue }
            } else if needPercents, size == nil {
                selection = addPercent(curPercents)
                needPercents = false
            }
            guard let s = size else { break }
            _ = addPercent(s)
            i += 10
        }
        var j = 27 * 2
        while true {
            // 3 << 43 is the top absolute size on a 64-bit build.
            let size: UInt64? = j > (20 + 8 * 3 - 1) * 2 ? nil : UInt64(2 + (j & 1)) << UInt64(j / 2)
            if needBytes, let s = size, s >= curBytes {
                selection = addBytes(curBytes)
                needBytes = false
                if s == curBytes { j += 1; continue }
            } else if needBytes, size == nil {
                selection = addBytes(curBytes)
                needBytes = false
            }
            guard let s = size else { break }
            _ = addBytes(s)
            j += 1
        }
        return (items, selection)
    }

    /// `Get_MemUse_Bytes()`: the limit the estimate is compared against.
    var memUseLimitBytes: UInt64 {
        if let mu = CompressMemUse(spec: memUseSpec) { return mu.bytes(ram: ramSizeReduced) }
        return ramUsageAuto
    }

    // MARK: memory estimation (GetMemoryUsage_Threads_Dict_DecompMem, :2901-3070)

    struct MemoryEstimate {
        /// nil = "?" (unknown method / unknown dictionary).
        let compressed: UInt64?
        let decompressed: UInt64?
    }

    var memoryEstimate: MemoryEstimate {
        memoryUsage(threads: effectiveNumThreads, dictionary: effectiveDictionary)
    }

    func memoryUsage(threads numThreads: Int, dictionary dict64: UInt64?) -> MemoryEstimate {
        if level2 == 0 {
            return MemoryEstimate(compressed: 1 << 20, decompressed: 1 << 20)
        }
        var size: UInt64 = 0
        if staticFormat.flags.contains(.filter) && level2 >= 9 {
            size += (12 << 20) * 2 + (5 << 20)          // the BCJ2 branch converter
        }
        var numMainZipThreads = 1
        if isZip {
            var numSubThreads = 1
            if method == .lzma && numThreads > 1 && level2 >= 5 { numSubThreads = 2 }
            numMainZipThreads = numThreads / numSubThreads
            if numMainZipThreads > 1 {
                size += UInt64(numMainZipThreads) * (8 << 23)     // sizeof(size_t) << 23
            } else {
                numMainZipThreads = 1
            }
        }
        guard let dict64 else { return MemoryEstimate(compressed: nil, decompressed: nil) }
        guard let m = method else { return MemoryEstimate(compressed: nil, decompressed: nil) }

        switch m {
        case .lzma, .lzma2:
            let dict = UInt32(truncatingIfNeeded: min(dict64, CompressModel.lzmaMaxDictSize))
            var hs = dict &- 1
            hs |= (hs >> 1); hs |= (hs >> 2); hs |= (hs >> 4); hs |= (hs >> 8)
            hs >>= 1
            if hs >= (1 << 24) { hs >>= 1 }
            hs |= (1 << 16) - 1
            if level2 < 5 { hs |= (256 << 10) - 1 }
            hs = hs &+ 1
            var size1 = UInt64(hs) * 4
            size1 += UInt64(dict) * 4
            if level2 >= 5 { size1 += UInt64(dict) * 4 }
            size1 += 2 << 20
            var numThreads1: UInt64 = 1
            if numThreads > 1 && level2 >= 5 {
                size1 += (2 << 20) + (4 << 20)
                numThreads1 = 2
            }
            var numBlockThreads = UInt64(numThreads) / numThreads1
            var chunkSize: UInt64 = 0
            if m != .lzma && numBlockThreads != 1 {
                chunkSize = CompressModel.lzma2ChunkSize(UInt64(dict))
                if isXz, let log = blockLogSizeSpec {
                    if log == CompressModel.solidLogFullSolid {
                        numBlockThreads = 1
                        chunkSize = 0
                    } else if log != CompressModel.solidLogNonSolid {
                        chunkSize = UInt64(1) << UInt64(log)
                    }
                }
            }
            if chunkSize == 0 {
                let blockSizeMax = UInt64(UInt32.max) - (1 << 16) + 1
                var blockSize = UInt64(dict) + (1 << 16) + (numThreads1 > 1 ? (1 << 20) : 0)
                blockSize += blockSize >> (blockSize < (UInt64(1) << 30) ? 1 : 2)
                if blockSize >= blockSizeMax { blockSize = blockSizeMax }
                size += numBlockThreads * (size1 + blockSize)
            } else {
                size += numBlockThreads * (size1 + chunkSize)
                let numPackChunks = numBlockThreads + (numBlockThreads / 8) + 1
                size += numPackChunks * chunkSize
            }
            return MemoryEstimate(compressed: size, decompressed: UInt64(dict) + (2 << 20))
        case .ppmd:
            let decomp = dict64 + (2 << 20)
            return MemoryEstimate(compressed: size + decomp, decompressed: decomp)
        case .deflate, .deflate64:
            let size1: UInt64 = (3 << 20) + (1 << 20)
            size += size1 * UInt64(numMainZipThreads)
            return MemoryEstimate(compressed: size, decompressed: 2 << 20)
        case .bzip2:
            return MemoryEstimate(compressed: size + (10 << 20) * UInt64(numThreads), decompressed: 7 << 20)
        case .ppmdZip:
            let decomp = dict64 + (2 << 20)
            return MemoryEstimate(compressed: size + decomp * UInt64(numThreads), decompressed: decomp)
        default:
            return MemoryEstimate(compressed: nil, decompressed: nil)
        }
    }

    /// `AddMemUsage`: MB up to 16 GB, GB up to 64 TB, then TB, rounded up.
    static func memUsageText(_ value: UInt64) -> String {
        if value <= (UInt64(16) << 30) { return "\((value + (1 << 20) - 1) >> 20) MB" }
        if value <= (UInt64(64) << 40) { return "\((value + (1 << 30) - 1) >> 30) GB" }
        var v = value + (UInt64(1) << 40) - 1
        if v < value { v = value }
        return "\(v >> 40) TB"
    }

    /// `PrintMemUsage(IDT_COMPRESS_MEMORY_VALUE)`: `<usage> / <limit> / <RAM>`, "?" when unknown.
    var memoryUsageText: String {
        guard let usage = memoryEstimate.compressed else { return "?" }
        var s = CompressModel.memUsageText(usage)
        if let mu = CompressMemUse(spec: memUseSpec) {
            s += " / " + CompressModel.memUsageText(mu.bytes(ram: ramSizeReduced))
        } else if ramSizeDefined {
            s += " / " + CompressModel.memUsageText(ramUsageAuto)
        }
        if ramSizeDefined {
            s += " / " + CompressModel.memUsageText(ramSize)
        }
        return s
    }

    /// `PrintMemUsage(IDT_COMPRESS_MEMORY_DE_VALUE)`.
    var decompressionMemoryText: String {
        guard let d = memoryEstimate.decompressed else { return "?" }
        return CompressModel.memUsageText(d)
    }

    // MARK: encryption (SetEncryptionMethod, CompressDialog.cpp:1721-1752)

    /// The encryption-method combo items and the index of the default one (whose spec is not
    /// emitted). Empty for a format without `kFF_Encrypt`.
    func encryptionMethodItems(stored: String) -> (items: [String], selection: Int, defaultIndex: Int) {
        if is7z { return (["AES-256"], 0, 0) }
        if isZip {
            let selection = stored.lowercased().hasPrefix("aes") ? 1 : 0
            return (["ZipCrypto", "AES-256"], selection, 0)
        }
        return ([], -1, -1)
    }

    /// `GetEncryptionMethodSpec()`: the name without "-", only when it is not the default item.
    func encryptionMethodSpec(selectedIndex: Int, items: [String], defaultIndex: Int) -> String {
        guard !items.isEmpty, selectedIndex >= 0, selectedIndex != defaultIndex,
              selectedIndex < items.count else { return "" }
        return items[selectedIndex].replacingOccurrences(of: "-", with: "")
    }
}

// ---------------------------------------------------------------------------
// MARK: - NCompression::CMemUse

/// `NCompression::CMemUse::Parse` (ZipRegistry.h:53-79): "NN%" or "<N>[bkmgt]".
struct CompressMemUse: Equatable {
    let isPercent: Bool
    let value: UInt64

    init?(spec: String) {
        let s = spec.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        var digits = ""
        var iterator = s.startIndex
        while iterator < s.endIndex, s[iterator].isNumber {
            digits.append(s[iterator])
            iterator = s.index(after: iterator)
        }
        guard let n = UInt64(digits) else { return nil }
        let rest = String(s[iterator...]).lowercased()
        if rest == "%" { self.isPercent = true; self.value = n; return }
        var shift: UInt64 = 0
        switch rest {
        case "", "b": shift = 0
        case "k": shift = 10
        case "m": shift = 20
        case "g": shift = 30
        case "t": shift = 40
        default: return nil
        }
        guard shift == 0 || n < (UInt64(1) << (64 - shift)) else { return nil }
        self.isPercent = false
        self.value = n << shift
    }

    func bytes(ram: UInt64) -> UInt64 {
        isPercent ? CompressModel.percent(of: ram, value) : value
    }

    /// The `memuse=` value: "NN%" or "<bytes>b".
    var propertyValue: String { isPercent ? "\(value)%" : "\(value)b" }
}

// ---------------------------------------------------------------------------
// MARK: - Volume sizes (SplitUtils.cpp)

enum CompressVolumes {
    /// `k_Sizes[]` (SplitUtils.cpp:64-75) — the Split dialog's presets, reused by
    /// `AddVolumeItems(m_Volume)` (CompressDialog.cpp:495).
    static let presets = ["10M", "100M", "1000M", "650M - CD", "700M - CD", "4092M - FAT",
                          "4480M - DVD", "8128M - DVD DL", "23040M - BD"]

    /// `ParseVolumeSizes` (SplitUtils.cpp:9-59). nil = the text is invalid
    /// (IDS_INCORRECT_VOLUME_SIZE 7307). An empty result means "no volumes".
    static func parse(_ text: String) -> [UInt64]? {
        var values: [UInt64] = []
        var previousWasNumber = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            i += 1
            if c == " " { continue }
            if c == "-" { return values }             // "650M - CD": the comment is ignored
            if previousWasNumber {
                previousWasNumber = false
                var numBits: UInt64 = 0
                switch Character(c.lowercased()) {
                case "b": continue
                case "k": numBits = 10
                case "m": numBits = 20
                case "g": numBits = 30
                case "t": numBits = 40
                default: break
                }
                if numBits != 0 {
                    guard var val = values.last, val < (UInt64(1) << (64 - numBits)) else { return nil }
                    val <<= numBits
                    values[values.count - 1] = val
                    while i < chars.count, chars[i] != " " { i += 1 }
                    continue
                }
            }
            i -= 1
            var digits = ""
            while i < chars.count, chars[i].isNumber {
                digits.append(chars[i])
                i += 1
            }
            guard let val = UInt64(digits), val != 0 else { return nil }
            values.append(val)
            previousWasNumber = true
        }
        return values
    }

    /// `GetNumberOfVolumes` (SplitUtils.cpp:82-96): how many volumes `size` needs.
    static func count(forSize size: UInt64, volumeSizes: [UInt64]) -> UInt64? {
        if size == 0 || volumeSizes.isEmpty { return 1 }
        var remaining = size
        for (i, volSize) in volumeSizes.enumerated() {
            if volSize >= remaining { return UInt64(i + 1) }
            remaining -= volSize
        }
        guard let last = volumeSizes.last, last != 0 else { return nil }
        return UInt64(volumeSizes.count) + (remaining - 1) / last + 1
    }
}

// ---------------------------------------------------------------------------
// MARK: - Timestamp precision (COptionsDialog::AddPrec / SetPrec)

enum CompressTimePrecision {
    /// `kTimePrec_Win` 0, `_Unix` 1, `_DOS` 2, `_1ns` 3 and `k_PropVar_TimePrec_Base` 16
    /// (C/7zTypes.h:586) … base + 9 = 25 (`k_PropVar_TimePrec_1ns`).
    static let win = 0, unix = 1, dos = 2, ns1 = 3
    static let propVarBase = 16
    static let propVarMax = 25

    /// `AddPrec` (CompressDialog.cpp:3455-3480).
    static func title(_ prec: Int, secText: String, nsText: String) -> String {
        switch prec {
        case win: return "100 \(nsText) : Windows"
        case unix: return "1 \(secText) : Unix"
        case dos: return "2 \(secText) : DOS"
        case ns1: return "1 \(nsText) : Linux"
        case propVarBase: return "1 \(secText)"
        default:
            if prec > propVarBase && prec <= propVarMax {
                var d: UInt64 = 1
                for _ in prec..<(propVarBase + 9) { d *= 10 }
                return "\(d) \(nsText)"
            }
            return "\(prec)"
        }
    }

    /// The precisions the handler offers: `Get_TimePrecFlags()` plus the default one.
    static func available(timeFlags: UInt32, defaultPrecision: Int) -> [Int] {
        // NArcInfoTimeFlags: bits 0..25 are the mask, bits 27..31 the default.
        var flags = timeFlags & ((1 << 26) - 1)
        if defaultPrecision != 0 { flags |= (UInt32(1) << UInt32(defaultPrecision)) }
        return (0...propVarMax).filter { (flags >> UInt32($0)) & 1 == 1 }
    }

    /// `Get_DefaultTimePrec()`; gzip is forced to Unix (`SetPrec`).
    static func defaultPrecision(timeFlags: UInt32, isGZip: Bool) -> Int {
        if isGZip { return unix }
        return Int((timeFlags >> 27) & ((1 << 5) - 1))
    }
}

// ---------------------------------------------------------------------------
// MARK: - The complete dialog result

/// What the Compress dialog produced: `NCompressDialog::CInfo` plus what
/// `UpdateGUI.cpp`'s `ShowDialog` turns it into.
struct CompressDialogResult {
    var archivePath = ""                  // GetFinalPath_Smart, with the extension
    var formatIndex: Int = -1             // engine format index
    var formatName = ""
    var level: Int = -1                   // -1 = not set
    var method = ""                       // "" = auto
    var dictionary: UInt64?               // nil = auto
    var order: Int64?                     // nil = auto
    var orderMode = false                 // PPMd: emit mem/o instead of d/fb
    var numThreads: Int64?                // nil = auto
    var memUse: CompressMemUse?           // nil = auto
    var solidBlockSize: UInt64?           // nil = not specified
    var encryptionMethod = ""             // "" = the default method
    var encryptHeaders = false
    var encryptHeadersIsAllowed = false
    var parameters = ""                   // the free "Parameters" text
    var updateMode: SZUpdateMode = .add
    var pathMode: SZCompressPathMode = .relative
    var sfxMode = false
    var sfxModulePath: String?            // nil = the bundled 7z.sfx (CompressDialogInput.sfxModulePath)
    var openShareForWrite = false
    var deleteAfterCompressing = false
    var password: String?
    var volumeSizes: [UInt64] = []
    // Compress Options sheet
    var timePrecision: Int?               // nil = not set
    var mTime: Bool?
    var cTime: Bool?
    var aTime: Bool?
    var setArcMTime: Bool?
    var preserveATime: Bool?
    var symLinks: Bool?
    var hardLinks: Bool?
    var altStreams: Bool?
    var ntSecurity: Bool?

    /// `SplitOptionsToStrings` (UpdateGUI.cpp:141-152): split on whitespace and strip a
    /// leading "-m" from each token.
    var parameterTokens: [String] {
        parameters.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map { token -> String in
            var s = String(token)
            if s.count > 2, s.hasPrefix("-"), s.dropFirst().first?.lowercased() == "m" {
                s.removeFirst(2)
            }
            return s
        }
    }

    /// `IsThereMethodOverride` (UpdateGUI.cpp:154-174): a `0=`-style token for 7z, `m=` otherwise.
    var hasMethodOverride: Bool {
        let is7z = formatName.caseInsensitiveCompare("7z") == .orderedSame
        for s in parameterTokens {
            if is7z {
                // ConvertStringToUInt64 stops at the first non-digit; n == 0 && *end == '='
                // means the token starts with "0=" (or "00=", …).
                var digits = ""
                for ch in s {
                    if ch.isNumber { digits.append(ch) } else { break }
                }
                if !digits.isEmpty, UInt64(digits) == 0, s.dropFirst(digits.count).first == "=" {
                    return true
                }
            } else {
                if s.hasPrefix("m=") { return true }
            }
        }
        return false
    }

    /// `SetOutProperties` (UpdateGUI.cpp:205-284) followed by `ParseAndAddPropertires`
    /// (:176-194): the `-m` list in the exact order the Windows dialog emits it.
    var properties: [SZUpdateProperty] {
        let is7z = formatName.caseInsensitiveCompare("7z") == .orderedSame
        let setMethod = !hasMethodOverride
        var props: [SZUpdateProperty] = []
        func add(_ name: String, _ value: String) {
            props.append(SZUpdateProperty(name: name, value: value))
        }
        if level >= 0 { add("x", "\(level)") }
        if setMethod {
            if !method.isEmpty { add(is7z ? "0" : "m", method) }
            if let dictionary {
                add((is7z ? "0" : "") + (orderMode ? "mem" : "d"), "\(dictionary)b")
            }
            if let order {
                add((is7z ? "0" : "") + (orderMode ? "o" : "fb"), "\(order)")
            }
        }
        if !encryptionMethod.isEmpty { add("em", encryptionMethod) }
        if encryptHeadersIsAllowed { add("he", encryptHeaders ? "on" : "off") }
        if let solidBlockSize { add("s", "\(solidBlockSize)b") }
        if let numThreads { add("mt", "\(numThreads)") }
        if let memUse { add("memuse", memUse.propertyValue) }
        if let mTime { add("tm", mTime ? "on" : "off") }
        if let cTime { add("tc", cTime ? "on" : "off") }
        if let aTime { add("ta", aTime ? "on" : "off") }
        if let timePrecision { add("tp", "\(timePrecision)") }
        // Then the user's own tokens; later duplicates win in the handler.
        for token in parameterTokens {
            if let eq = token.firstIndex(of: "=") {
                add(String(token[token.startIndex..<eq]), String(token[token.index(after: eq)...]))
            } else if !token.isEmpty {
                add(token, "")
            }
        }
        return props
    }

    /// The `SZUpdateOptions` this result asks for.
    func updateOptions() -> SZUpdateOptions {
        let options = SZUpdateOptions(archivePath: archivePath)
        options.formatIndex = formatIndex
        options.formatName = formatName
        options.properties = properties
        options.updateMode = updateMode
        options.pathMode = pathMode
        options.nameMode = .smart
        options.sfxMode = sfxMode
        if sfxMode, let sfxModulePath { options.sfxModulePath = sfxModulePath }
        options.volumeSizes = volumeSizes.map { NSNumber(value: $0) }
        options.password = (password?.isEmpty ?? true) ? nil : password
        options.deleteAfterCompressing = deleteAfterCompressing
        options.setArchiveMTime = setArcMTime ?? false
        options.openShareForWrite = openShareForWrite
        options.preserveATime = preserveATime.map { NSNumber(value: $0) }
        options.storeSymLinks = symLinks.map { NSNumber(value: $0) }
        options.storeHardLinks = hardLinks.map { NSNumber(value: $0) }
        options.storeAltStreams = altStreams.map { NSNumber(value: $0) }
        options.storeNtSecurity = ntSecurity.map { NSNumber(value: $0) }
        return options
    }
}
