// ArgumentGrammar.swift -- the 7zG command line, parsed exactly as `CArcCmdLineParser` parses it.
//
// Windows originals (03-shell-integration-inventory.md section 2):
//   NCommandLineParser::CParser::ParseString / ParseStrings   CPP/Common/CommandLineParser.cpp:96-220
//   kSwitchForms, ParseArchiveCommand, g_Commands             CPP/7zip/UI/Common/ArchiveCommandLine.cpp:278-455
//   AddSwitchWildcardsToCensor, ParseMapWithPaths             ArchiveCommandLine.cpp:649-840
//   AddToCensorFromListFile, ReadNamesFromListFile2           ArchiveCommandLine.cpp:526-548,
//                                                            CPP/Common/ListFileUtils.cpp:20-140
//   Parse2 (archive name, -sa, -spe, -snz, -seml, -scrc, ...)  ArchiveCommandLine.cpp:1400-1830
//   Main2 dispatch and exit codes                             CPP/7zip/UI/GUI/GUI.cpp:137-493
//
// Foundation only: shared by the app, the Finder Sync extension, the Quick Actions and the unit
// tests. Every switch in the table of 03 section 2.2 is accepted; the ones the GUI ignores are
// recorded in `ignoredSwitches` so a report can show them, and the ones it honours become typed
// fields. Parse failures carry the upstream message so the official Lang files keep working.

import Foundation

// MARK: - Commands (g_Commands, ArchiveCommandLine.cpp:432-454)

/// `NCommandType::EEnum`: the index into `g_Commands` = "audtexlbih", plus `rn`.
enum SevenZipCommandType: Int, CaseIterable {
    case add = 0            // a
    case update = 1         // u
    case delete = 2         // d
    case test = 3           // t
    case extractNoPaths = 4 // e
    case extractFull = 5    // x
    case list = 6           // l
    case benchmark = 7      // b
    case info = 8           // i
    case hash = 9           // h
    case rename = 10        // rn

    static let commandLetters = "audtexlbih"

    /// `ParseArchiveCommand`: one ASCII letter from `g_Commands`, case-insensitive, or `rn`.
    static func parse(_ token: String) -> SevenZipCommandType? {
        let s = token.lowercased()
        if s.count == 1, let c = s.unicodeScalars.first, c.isASCII,
           let index = commandLetters.firstIndex(of: Character(c)) {
            return SevenZipCommandType(rawValue: commandLetters.distance(from: commandLetters.startIndex, to: index))
        }
        if s == "rn" { return .rename }
        return nil
    }

    var letter: String {
        if self == .rename { return "rn" }
        let index = SevenZipCommandType.commandLetters.index(
            SevenZipCommandType.commandLetters.startIndex, offsetBy: rawValue)
        return String(SevenZipCommandType.commandLetters[index])
    }

    /// `CArcCommand::IsFromExtractGroup`.
    var isFromExtractGroup: Bool {
        self == .test || self == .extractNoPaths || self == .extractFull
    }

    /// `CArcCommand::IsFromUpdateGroup`.
    var isFromUpdateGroup: Bool {
        self == .add || self == .update || self == .delete || self == .rename
    }

    var isTestCommand: Bool { self == .test }

    /// `CArcCommand::GetPathMode`: `t` and `x` keep full paths, `e` drops them.
    var defaultExtractPathMode: Int { (self == .test || self == .extractFull) ? 0 : 2 }

    /// 7zG dispatches only these; `l` and `i` throw "Unsupported command" (GUI.cpp:396-399).
    var isSupportedByGUI: Bool {
        isFromExtractGroup || isFromUpdateGroup || self == .hash || self == .benchmark
    }
}

/// `NExitCode::EEnum` (CPP/7zip/UI/Common/ExitCode.h:10-21).
enum SevenZipExitCode: Int32 {
    case success = 0
    case warning = 1
    case fatalError = 2
    case userError = 7
    case memoryError = 8
    case userBreak = 255
}

/// `CArcCmdLineException` / `CMessagePathException`: a message and the offending token, which
/// `WinMain` shows in a message box and turns into exit code 7 (GUI.cpp:461-470).
struct SevenZipArgumentError: Error, CustomStringConvertible {
    let message: String
    let line: String

    init(_ message: String, _ line: String = "") {
        self.message = message
        self.line = line
    }

    /// The box text `CMessagePathException` produces: message, then the path on its own line.
    var description: String {
        line.isEmpty ? message : message + "\n" + line
    }
}

// MARK: - The generic switch parser (CommandLineParser.cpp)

enum SwitchValueType {
    case simple     // NSwitchType::kSimple
    case minus      // kMinus:  only "-" may follow
    case string     // kString: the rest of the token
    case postChar   // kChar:   exactly one character out of a set
}

struct SwitchForm {
    let key: String
    let type: SwitchValueType
    let multi: Bool
    let minLength: Int
    let postCharSet: String?

    init(_ key: String, _ type: SwitchValueType, multi: Bool = false,
         minLength: Int = 0, postCharSet: String? = nil) {
        self.key = key
        self.type = type
        self.multi = multi
        self.minLength = minLength
        self.postCharSet = postCharSet
    }
}

struct SwitchResult {
    var thereIs = false
    var withMinus = false
    var postCharIndex = -1
    var postStrings: [String] = []
}

/// `NCommandLineParser::CParser`, including its five error messages.
struct SwitchParser {

    var results: [String: SwitchResult] = [:]
    var nonSwitchStrings: [String] = []
    /// Index in `nonSwitchStrings` at which `--` appeared, or nil.
    var stopSwitchIndex: Int?

    private let forms: [SwitchForm]

    init(forms: [SwitchForm]) { self.forms = forms }

    subscript(_ key: String) -> SwitchResult { results[key] ?? SwitchResult() }

    mutating func parse(_ tokens: [String]) throws {
        for token in tokens {
            if stopSwitchIndex == nil {
                if token == "--" {
                    stopSwitchIndex = nonSwitchStrings.count
                    continue
                }
                if let first = token.first, first == "-" {
                    try parseSwitch(token)
                    continue
                }
            }
            nonSwitchStrings.append(token)
        }
    }

    /// `CParser::ParseString`: longest ASCII-case-insensitive prefix match wins.
    private mutating func parseSwitch(_ token: String) throws {
        let chars = Array(token)
        var pos = 1
        var matched: SwitchForm?
        var maxLen = -1
        for form in forms {
            let keyLen = form.key.count
            if keyLen <= maxLen || pos + keyLen > chars.count { continue }
            let candidate = String(chars[pos..<(pos + keyLen)]).lowercased()
            if candidate == form.key.lowercased() {
                matched = form
                maxLen = keyLen
            }
        }
        guard let form = matched else {
            throw SevenZipArgumentError("Unknown switch:", token)
        }
        pos += maxLen

        var result = results[form.key] ?? SwitchResult()
        if !form.multi && result.thereIs {
            throw SevenZipArgumentError("Multiple instances for switch:", token)
        }
        result.thereIs = true

        let rem = chars.count - pos
        if rem < form.minLength {
            throw SevenZipArgumentError("Too short switch:", token)
        }
        result.withMinus = false
        result.postCharIndex = -1

        switch form.type {
        case .minus:
            if rem == 1 {
                guard chars[pos] == "-" else {
                    throw SevenZipArgumentError("Incorrect switch postfix:", token)
                }
                result.withMinus = true
                results[form.key] = result
                return
            }
        case .postChar:
            if rem == 1 {
                let c = chars[pos]
                guard let set = form.postCharSet, c.isASCII,
                      let idx = set.firstIndex(of: c) else {
                    throw SevenZipArgumentError("Incorrect switch postfix:", token)
                }
                result.postCharIndex = set.distance(from: set.startIndex, to: idx)
                results[form.key] = result
                return
            }
        case .string:
            result.postStrings.append(String(chars[pos...]))
            results[form.key] = result
            return
        case .simple:
            break
        }

        if pos != chars.count {
            throw SevenZipArgumentError("Too long switch:", token)
        }
        results[form.key] = result
    }
}

// MARK: - The parsed 7zG command line

/// `EArcNameMode` (Update.h:15-20), mirrored so this file needs no bridge import.
enum ArchiveNameMode: Int {
    case smart = 0    // -sas (default)
    case exact = 1    // -sae
    case add = 2      // -saa
}

/// The `-ao{a,s,u,t}` forced overwrite mode, raw values matching `SZOverwriteMode`.
enum ForcedOverwriteMode: Int {
    case overwrite = 1
    case skip = 2
    case rename = 3
    case renameExisting = 4
}

/// `-snz[0-2]` -> the `com.apple.quarantine` propagation mode (raw values = `SZZoneIDMode`).
enum ZoneIDModeSpec: Int {
    case none = 0
    case all = 1
    case office = 2
}

/// `NRecursedType::EEnum` (Update.h:59-65), raw values matching `SZRecursedType`.
enum SevenZipRecursedType: Int {
    case recursed = 0                 // -r  / -ir!…
    case wildcardOnlyRecursed = 1     // -r0 / -ir0!…
    case nonRecursed = 2              // -r-, and the default

    /// `GetRecursedTypeFromIndex` (:418-429) over `kRecursedPostCharSet` = "0-".
    static func fromPostCharIndex(_ index: Int) -> SevenZipRecursedType {
        switch index {
        case 0: return .wildcardOnlyRecursed
        case 1: return .nonRecursed
        default: return .recursed
        }
    }
}

/// `NWildcard::kMark_*` (Common/Wildcard.h:56-58), raw values matching `SZWildcardMarkMode`.
enum SevenZipMarkMode: Int {
    case fileOrDir = 0                // kMark_FileOrDir, the default (`m-`)
    case strictFile = 1               // kMark_StrictFile (`m`)
    case strictFileIfWildcard = 2     // kMark_StrictFile_IfWildcard (`m2`)
}

/// One resolved include or exclude name **with the modifiers its switch carried** — `CNameOption`
/// plus the name `AddNameToCensor` receives (:459-495, :707-850). Keeping the modifiers is what
/// lets the bridge hand the name to the engine's censor unexpanded, so `EnumerateItems` does the
/// wildcard matching (03 section 2.2 `-i`/`-x`).
struct SevenZipPathSpec: Equatable {
    var path: String
    var include = true
    var recursedType: SevenZipRecursedType = .nonRecursed
    var wildcardMatching = true
    var markMode: SevenZipMarkMode = .fileOrDir

    /// `AddPreItem_NoWildcard`: an include entry that is a literal file-system path.
    static func literal(_ path: String) -> SevenZipPathSpec {
        SevenZipPathSpec(path: path, include: true, recursedType: .nonRecursed,
                         wildcardMatching: false, markMode: .fileOrDir)
    }

    var containsWildcard: Bool {
        wildcardMatching && path.contains(where: { $0 == "*" || $0 == "?" })
    }
}

/// One `rn` old/new pair (`CRenamePair`, Update.h:67-78).
struct SevenZipRenamePair: Equatable {
    var oldName: String
    var newName: String
    /// `CRenamePair::WildcardParsing`; `-spd` and a `w-` postfix turn it off.
    var wildcardParsing = true

    /// `CRenamePair::Prepare()` (Update.cpp:288-295): with wildcard parsing on, the **old** name
    /// must not contain a wildcard. `RecursedType` is always `kNonRecursed` here (:616).
    var isSupported: Bool {
        guard wildcardParsing else { return true }
        return !oldName.contains(where: { $0 == "*" || $0 == "?" })
    }
}

/// Everything 7zG takes from its argv. One field per switch the GUI honours; the rest are in
/// `ignoredSwitches` (accepted for parity, no effect — 03 section 2.2).
struct SevenZipCommandLine: Equatable {

    var command: SevenZipCommandType = .add

    /// The one non-switch string after the command, unless `-an`, `b`, `i` or `h`.
    var archiveName: String?
    /// `-an`.
    var noArchiveName = false
    /// Positional paths after the archive name (the item censor).
    var itemPaths: [String] = []
    /// `-i` include sources, already resolved (`!name`, `@listfile`).
    var includePaths: [String] = []
    /// `-ai` archive include sources, already resolved.
    var archivePaths: [String] = []
    /// `-x` / `-ax` exclude sources, already resolved.
    var excludePaths: [String] = []
    var archiveExcludePaths: [String] = []
    /// List files consumed by `-i@` / `-ai@`; the receiver deletes them (03 section 6.4).
    var consumedListFiles: [String] = []

    /// The same four lists as censor entries, with the `r`/`w`/`m` modifiers of the switch each
    /// name came from. `includeSpecs`/`excludeSpecs` carry only the `-i`/`-x` names; the positional
    /// paths join through `itemSpecs`, the archive name through `archiveSpecs`.
    var includeSpecs: [SevenZipPathSpec] = []
    var excludeSpecs: [SevenZipPathSpec] = []
    var archiveIncludeSpecs: [SevenZipPathSpec] = []
    var archiveExcludeSpecs: [SevenZipPathSpec] = []
    /// `rn`: the old/new pairs the positional strings formed (:600-625).
    var renamePairs: [SevenZipRenamePair] = []
    /// The `CNameOption` the positional paths inherit: `-r`, `-spd`.
    var defaultRecursedType: SevenZipRecursedType = .nonRecursed
    var defaultWildcardMatching = true

    var showDialog = false                        // -ad
    var yesToAll = false                          // -y
    var outputDirectory: String?                  // -o
    var formatHint: String?                       // -t
    var excludedFormats: [String] = []            // -stx
    var methodProperties: [String] = []           // -m (raw "name=value" texts)
    var eliminateDuplicateRoot: Bool?             // -spe / -spe-  (CBoolPair)
    var overwriteMode: ForcedOverwriteMode?       // -ao{a,s,u,t}
    var archiveNameMode: ArchiveNameMode = .smart // -sa{s,e,a}
    var zoneIDMode: ZoneIDModeSpec?               // -snz[0-2]
    var hashMethods: [String] = []                // -scrc (repeatable)
    var emailMode = false                         // -seml
    var emailRemoveAfter = false                  // -seml.
    var emailAddress: String?                     // -seml[.]<address>
    var password: String?                         // -p<pwd>
    var passwordEnabled = false                   // -p with or without a value
    var workingDirectory: String?                 // -w[dir]
    var volumeSizes: [String] = []                // -v
    var updateActions: [String] = []              // -u
    var sfxModule: String?                        // -sfx[module]
    var memoryLimitSpec: String?                  // -smemx
    var hashDirectory: String?                    // -shd
    var deleteAfterCompressing = false            // -sdel
    var setArchiveMTime = false                   // -stl
    var preserveAccessTime = false                // -ssp
    var openShareForWrite = false                 // -ssw
    var stopAfterOpenError = false                // -sse
    var storeSymLinks: Bool?                      // -snl / -snl-
    var storeHardLinks: Bool?                     // -snh / -snh-
    var storeAltStreams: Bool?                    // -sns / -sns-
    var restoreNtSecurity = false                 // -sni
    var disableWildcards = false                  // -spd
    var excludeDirectoryItems = false             // -x!td
    var excludeFileItems = false                  // -x!tf
    var fullPathMode: Int?                        // -spf / -spf2
    var outDirMode: Int?                          // -spo{d,c,r}
    var recursionSpec: Int?                       // -r / -r0 / -r-
    var stdInName: String?                        // -si
    var stdOut = false                            // -so
    /// Switches accepted and ignored by the port, in the order they appeared.
    var ignoredSwitches: [String] = []

    /// The archives an extract-group command works on: `-ai` sources plus, when `-an` was not
    /// given, the archive name itself.
    var resolvedArchivePaths: [String] {
        var out: [String] = []
        if let archiveName, !archiveName.isEmpty { out.append(archiveName) }
        out += archivePaths
        return out
    }

    /// The files a hash or update command works on: `-i` sources plus the positional paths.
    var resolvedItemPaths: [String] { includePaths + itemPaths }

    /// The item censor as the engine wants it: the `-i` entries, the positional paths with the
    /// global `CNameOption`, then the `-x` entries. When neither an `-i` switch nor a positional
    /// path was given, `AddToCensorFromNonSwitchesStrings` adds the universal wildcard `*`
    /// (:574-591) — the bridge does that itself when no include entry arrives.
    var itemSpecs: [SevenZipPathSpec] {
        var out = includeSpecs
        for path in itemPaths {
            out.append(SevenZipPathSpec(path: path, include: true,
                                        recursedType: defaultRecursedType,
                                        wildcardMatching: defaultWildcardMatching))
        }
        return out + excludeSpecs
    }

    /// The archive censor (`options.arcCensor`, :1670-1701): `-ai`, then the archive name with
    /// `nopArc` (never recursed, :1671-1676), then `-ax`.
    var archiveSpecs: [SevenZipPathSpec] {
        var out = archiveIncludeSpecs
        if let archiveName, !archiveName.isEmpty {
            out.append(SevenZipPathSpec(path: archiveName, include: true,
                                        recursedType: .nonRecursed,
                                        wildcardMatching: defaultWildcardMatching))
        }
        return out + archiveExcludeSpecs
    }

    /// True when the engine's directory walk is needed for this censor: an include entry with a
    /// wildcard to expand, or any exclude entry to apply. A Finder selection has neither (one
    /// `-aiw-!<path>` per item), so the common case answers false and nothing on disk is touched.
    static func needsCensorWalk(_ specs: [SevenZipPathSpec]) -> Bool {
        specs.contains { !$0.include || $0.containsWildcard }
    }
}

// MARK: - The parser

enum SevenZipArguments {

    /// `kSwitchForms` (ArchiveCommandLine.cpp:278-367), in source order. The keys are the map
    /// keys of `SwitchParser.results`.
    static let switchForms: [SwitchForm] = [
        SwitchForm("?", .simple),
        SwitchForm("h", .simple),
        SwitchForm("-help", .simple),

        SwitchForm("ba", .simple),
        SwitchForm("bd", .simple),
        SwitchForm("bt", .simple),
        SwitchForm("bb", .string, minLength: 0),

        SwitchForm("bso", .postChar, minLength: 1, postCharSet: "012"),
        SwitchForm("bse", .postChar, minLength: 1, postCharSet: "012"),
        SwitchForm("bsp", .postChar, minLength: 1, postCharSet: "012"),

        SwitchForm("y", .simple),

        SwitchForm("ad", .simple),
        SwitchForm("ao", .postChar, minLength: 1, postCharSet: "asut"),

        SwitchForm("t", .string, minLength: 1),
        SwitchForm("stx", .string, multi: true, minLength: 1),

        SwitchForm("m", .string, multi: true, minLength: 1),
        SwitchForm("o", .string, minLength: 1),
        SwitchForm("w", .string),

        SwitchForm("i", .string, multi: true, minLength: 2),
        SwitchForm("x", .string, multi: true, minLength: 2),
        SwitchForm("ai", .string, multi: true, minLength: 2),
        SwitchForm("ax", .string, multi: true, minLength: 2),
        SwitchForm("an", .simple),

        SwitchForm("u", .string, multi: true, minLength: 1),
        SwitchForm("v", .string, multi: true, minLength: 1),
        SwitchForm("r", .postChar, minLength: 0, postCharSet: "0-"),

        SwitchForm("stm", .string),
        SwitchForm("sfx", .string),
        SwitchForm("seml", .string, minLength: 0),
        SwitchForm("scrc", .string, multi: true, minLength: 0),
        SwitchForm("shd", .string, minLength: 1),
        SwitchForm("smemx", .string),

        SwitchForm("si", .string),
        SwitchForm("so", .simple),

        SwitchForm("slp", .string),
        SwitchForm("scs", .string),
        SwitchForm("scc", .string),
        SwitchForm("slt", .simple),
        SwitchForm("slf", .string, minLength: 1),
        SwitchForm("slsl", .minus),
        SwitchForm("slmu", .minus),

        SwitchForm("ssp", .simple),
        SwitchForm("ssw", .simple),
        SwitchForm("sse", .simple),
        SwitchForm("ssc", .minus),
        SwitchForm("sa", .postChar, minLength: 1, postCharSet: "sea"),

        SwitchForm("spm", .string, minLength: 0),
        SwitchForm("spd", .simple),
        SwitchForm("spe", .minus),
        SwitchForm("spf", .string, minLength: 0),
        SwitchForm("spo", .postChar, minLength: 1, postCharSet: "dcr"),

        SwitchForm("snh", .minus),
        SwitchForm("snld", .string),
        SwitchForm("snl", .minus),
        SwitchForm("sni", .simple),

        SwitchForm("snoi", .minus),
        SwitchForm("snon", .minus),

        SwitchForm("snz", .string, minLength: 0),
        SwitchForm("sns", .minus),
        SwitchForm("snr", .simple),
        SwitchForm("snc", .simple),

        SwitchForm("snt", .minus),

        SwitchForm("sdel", .simple),
        SwitchForm("stl", .simple),

        SwitchForm("p", .string),
    ]

    /// Switches the port accepts and ignores (03 section 2.2, section 6.4). Console output
    /// control, large pages, thread affinity and the NT-only stream options.
    static let ignoredSwitchKeys: Set<String> = [
        "?", "h", "-help",
        "ba", "bd", "bt", "bb", "bso", "bse", "bsp",
        "slp", "stm",
        "scs", "scc", "slt", "slf", "slsl", "slmu",
        "sni", "snoi", "snon", "snr", "snc", "snt", "snld",
        "spm", "ssc",
    ]

    /// `Main2` + `Parse1` + `Parse2`: turn an argv (**without** argv[0]) into the command line.
    /// Throws `SevenZipArgumentError` for every syntax problem, with the upstream text.
    static func parse(_ argv: [String]) throws -> SevenZipCommandLine {
        guard let commandToken = argv.first else {
            throw SevenZipArgumentError("Specify command")
        }
        guard let command = SevenZipCommandType.parse(commandToken) else {
            throw SevenZipArgumentError("Unsupported command:", commandToken)
        }

        var parser = SwitchParser(forms: switchForms)
        try parser.parse(Array(argv.dropFirst()))

        var out = SevenZipCommandLine()
        out.command = command

        for key in ignoredSwitchKeys where parser[key].thereIs {
            out.ignoredSwitches.append("-" + key)
        }

        out.yesToAll = parser["y"].thereIs
        out.showDialog = parser["ad"].thereIs
        out.stdOut = parser["so"].thereIs
        out.deleteAfterCompressing = parser["sdel"].thereIs
        out.setArchiveMTime = parser["stl"].thereIs
        out.preserveAccessTime = parser["ssp"].thereIs
        out.openShareForWrite = parser["ssw"].thereIs
        out.stopAfterOpenError = parser["sse"].thereIs
        out.restoreNtSecurity = parser["sni"].thereIs
        out.disableWildcards = parser["spd"].thereIs
        out.noArchiveName = parser["an"].thereIs

        if parser["ao"].thereIs {
            // k_OverwriteModes = { kOverwrite, kSkip, kRename, kRenameExisting } (:255-262)
            out.overwriteMode = ForcedOverwriteMode(rawValue: parser["ao"].postCharIndex + 1)
        }
        if parser["sa"].thereIs {
            out.archiveNameMode = ArchiveNameMode(rawValue: parser["sa"].postCharIndex) ?? .smart
        }
        if parser["spe"].thereIs {
            out.eliminateDuplicateRoot = !parser["spe"].withMinus
        }
        if parser["snh"].thereIs { out.storeHardLinks = !parser["snh"].withMinus }
        if parser["snl"].thereIs { out.storeSymLinks = !parser["snl"].withMinus }
        if parser["sns"].thereIs { out.storeAltStreams = !parser["sns"].withMinus }
        if parser["r"].thereIs { out.recursionSpec = parser["r"].postCharIndex }
        if parser["spo"].thereIs { out.outDirMode = parser["spo"].postCharIndex }

        if parser["spf"].thereIs {
            let s = parser["spf"].postStrings.first ?? ""
            if s.isEmpty {
                out.fullPathMode = 2                       // k_AbsPath
            } else if s == "2" {
                out.fullPathMode = 1                       // k_FullPath
            } else {
                throw SevenZipArgumentError("Unsupported -spf:", s)
            }
        }

        if parser["t"].thereIs { out.formatHint = parser["t"].postStrings.first }
        out.excludedFormats = parser["stx"].postStrings
        out.methodProperties = parser["m"].postStrings
        out.volumeSizes = parser["v"].postStrings
        out.updateActions = parser["u"].postStrings
        // `options.HashMethods = parser[kHash].PostStrings` verbatim (:1431): a bare `-scrc`
        // contributes an empty name, which `CHashBundle::SetMethods` treats as "the default".
        out.hashMethods = parser["scrc"].postStrings
        if parser["shd"].thereIs { out.hashDirectory = parser["shd"].postStrings.first }
        if parser["smemx"].thereIs { out.memoryLimitSpec = parser["smemx"].postStrings.first }
        if parser["sfx"].thereIs { out.sfxModule = parser["sfx"].postStrings.first ?? "" }
        if parser["si"].thereIs { out.stdInName = parser["si"].postStrings.first ?? "" }
        if parser["w"].thereIs { out.workingDirectory = parser["w"].postStrings.first ?? "" }

        if parser["o"].thereIs, let dir = parser["o"].postStrings.first {
            // ":1728-1735": separators normalised, one trailing separator added.
            out.outputDirectory = ArchiveNaming.withTrailingSeparator(dir)
        }

        if parser["snz"].thereIs {
            let s = parser["snz"].postStrings.first ?? ""
            if s.isEmpty {
                out.zoneIDMode = .all
            } else if let v = Int(s), let mode = ZoneIDModeSpec(rawValue: v) {
                out.zoneIDMode = mode
            } else {
                throw SevenZipArgumentError("Unsupported -snz:", s)
            }
        }

        if parser["seml"].thereIs {
            // ":1798-1808": a leading "." means "delete the archive after sending".
            var s = parser["seml"].postStrings.first ?? ""
            out.emailMode = true
            if s.hasPrefix(".") {
                out.emailRemoveAfter = true
                s.removeFirst()
            }
            if !s.isEmpty { out.emailAddress = s }
        }

        if parser["p"].thereIs {
            out.passwordEnabled = true
            let s = parser["p"].postStrings.first ?? ""
            if !s.isEmpty { out.password = s }
        }

        // ":1816-1828": -si and -so cannot be combined with the GUI's own dialogs.
        if out.stdOut && out.stdInName != nil {
            throw SevenZipArgumentError(
                "I won't write data and program's messages to same stream")
        }

        // ":1485-1491": the `CNameOption` every name starts from — `-r` and `-spd`.
        if parser["r"].thereIs {
            out.defaultRecursedType = .fromPostCharIndex(parser["r"].postCharIndex)
        }
        out.defaultWildcardMatching = !parser["spd"].thereIs

        // -i / -x / -ai / -ax (AddSwitchWildcardsToCensor).
        let base = SevenZipPathSpec(path: "", include: true,
                                    recursedType: out.defaultRecursedType,
                                    wildcardMatching: out.defaultWildcardMatching)
        var specs = try resolve(parser["i"].postStrings, base: base, include: true, out: &out)
        out.includeSpecs = specs
        out.includePaths = specs.map(\.path)
        specs = try resolve(parser["x"].postStrings, base: base, include: false, out: &out)
        out.excludeSpecs = specs
        out.excludePaths = specs.map(\.path)
        // ":1671-1676": nopArc keeps `nop`'s wildcard matching and mark mode but never recurses.
        var archiveBase = base
        archiveBase.recursedType = .nonRecursed
        specs = try resolve(parser["ai"].postStrings, base: archiveBase, include: true, out: &out)
        out.archiveIncludeSpecs = specs
        out.archivePaths = specs.map(\.path)
        specs = try resolve(parser["ax"].postStrings, base: archiveBase, include: false, out: &out)
        out.archiveExcludeSpecs = specs
        out.archiveExcludePaths = specs.map(\.path)

        // ":1527-1553": the archive name is the first non-switch string after the command,
        // unless -an or a command that has no archive.
        var nonSwitch = parser.nonSwitchStrings
        let thereIsArchiveName = !out.noArchiveName
            && command != .benchmark && command != .info && command != .hash
            && !(command.isFromExtractGroup && out.stdInName != nil)
        if thereIsArchiveName {
            guard !nonSwitch.isEmpty else {
                throw SevenZipArgumentError("Cannot find archive name")
            }
            let name = nonSwitch.removeFirst()
            guard !name.isEmpty else {
                throw SevenZipArgumentError("Archive name cannot by empty")
            }
            out.archiveName = name
        }

        if command == .rename {
            // ":600-625" `AddToCensorFromNonSwitchesStrings` with `renamePairs`: the positional
            // strings are old/new pairs; a `@listfile` among them contributes pairs of its own and
            // must hold an even number of names.
            var names: [String] = []
            for token in nonSwitch {
                guard !token.isEmpty else { throw SevenZipArgumentError("Empty file path") }
                if token.hasPrefix("@") {
                    let file = String(token.dropFirst())
                    let listed = try Self.readListFile(file)
                    guard listed.count % 2 == 0 else {
                        throw SevenZipArgumentError(
                            "Incorrect item in listfile.\nCheck charset encoding and -scs switch.",
                            file)
                    }
                    out.consumedListFiles.append(file)
                    names += listed
                } else {
                    names.append(token)
                }
            }
            var index = 0
            while index + 1 < names.count {
                out.renamePairs.append(SevenZipRenamePair(
                    oldName: names[index], newName: names[index + 1],
                    wildcardParsing: out.defaultWildcardMatching))
                index += 2
            }
            if index < names.count {
                // ":624": an odd number of names is a user error, not a silent drop.
                throw SevenZipArgumentError("There is no second file name for rename pair:",
                                           names[index])
            }
            for pair in out.renamePairs where !pair.isSupported {
                // `AddRenamePair` (:511-522): "Unsupported rename command:" + old, new, recursion.
                throw SevenZipArgumentError("Unsupported rename command:",
                                           pair.oldName + "\n" + pair.newName)
            }
        } else {
            out.itemPaths = nonSwitch
        }

        return out
    }

    /// `AddSwitchWildcardsToCensor` (:707-850): the `r`/`w`/`m` modifiers, then one of the three
    /// source markers `!` (immediate name), `@` (list file), `#` (Win32 shared-memory map).
    private static func resolve(_ strings: [String], base: SevenZipPathSpec, include: Bool,
                                out: inout SevenZipCommandLine) throws -> [SevenZipPathSpec] {
        var names: [SevenZipPathSpec] = []
        for spec in strings {
            var nop = base
            nop.include = include
            let chars = Array(spec)
            guard chars.count >= 2 else {
                throw SevenZipArgumentError("Too short switch", spec)
            }
            if !include {
                if spec.lowercased() == "td" { out.excludeDirectoryItems = true; continue }
                if spec.lowercased() == "tf" { out.excludeFileItems = true; continue }
            }
            var pos = 0
            var recursedUsed = false
            var matchingUsed = false
            var typeUsed = false
            while pos < chars.count {
                if chars[pos].lowercased() == "r" {
                    if recursedUsed { throw SevenZipArgumentError("inorrect switch", spec) }
                    recursedUsed = true
                    pos += 1
                    // ":757-771": the character after `r` is looked up in "0-"; a hit sets the
                    // type and is consumed, a miss means bare `-ir` = kRecursed.
                    nop.recursedType = .recursed
                    if pos < chars.count, chars[pos] == "0" || chars[pos] == "-" {
                        nop.recursedType = chars[pos] == "0" ? .wildcardOnlyRecursed : .nonRecursed
                        pos += 1
                        continue
                    }
                    // No post character: fall through to the `w`/`m` test with the character
                    // that followed the `r`, exactly as upstream re-uses its `c`.
                }
                if pos >= chars.count { break }
                let c = chars[pos].lowercased()
                if c == "w" {
                    if matchingUsed { throw SevenZipArgumentError("inorrect switch", spec) }
                    matchingUsed = true
                    nop.wildcardMatching = true
                    pos += 1
                    if pos < chars.count, chars[pos] == "-" {
                        nop.wildcardMatching = false
                        pos += 1
                    }
                } else if c == "m" {
                    if typeUsed { throw SevenZipArgumentError("inorrect switch", spec) }
                    typeUsed = true
                    nop.markMode = .strictFile
                    pos += 1
                    if pos < chars.count, chars[pos] == "-" || chars[pos] == "2" {
                        nop.markMode = chars[pos] == "2" ? .strictFileIfWildcard : .fileOrDir
                        pos += 1
                    }
                } else {
                    break
                }
            }
            guard chars.count >= pos + 2 else {
                throw SevenZipArgumentError("Too short switch", spec)
            }
            let marker = chars[pos]
            let tail = String(chars[(pos + 1)...])
            switch marker {
            case "!":
                var entry = nop
                entry.path = tail
                names.append(entry)
            case "@":
                for name in try readListFile(tail) {
                    var entry = nop
                    entry.path = name
                    names.append(entry)
                }
                out.consumedListFiles.append(tail)
            case "#":
                // Win32 named shared memory. There is none on macOS, so the shape is validated
                // and the upstream error strings are produced (03 section 1.5, section 6.4).
                throw SevenZipArgumentError(mapError(tail), spec)
            default:
                throw SevenZipArgumentError("Incorrect wildcard type marker", spec)
            }
        }
        return names
    }

    /// `ParseMapWithPaths` (:651-703), minus the mapping itself: `name:size:event`, the size a
    /// multiple of `sizeof(wchar_t)` in `[2, 2^31]`, then "Cannot open mapping" because the
    /// Win32 section does not exist here.
    static func mapError(_ spec: String) -> String {
        guard let colon = spec.firstIndex(of: ":") else { return "Incorrect Map command" }
        let rest = spec[spec.index(after: colon)...]
        guard let colon2 = rest.firstIndex(of: ":") else { return "Incorrect Map command" }
        let sizeText = String(rest[rest.startIndex..<colon2])
        guard let size = UInt32(sizeText), size >= 2, size <= (UInt32(1) << 31),
              size % 2 == 0 else {
            return "Unsupported Map data size"
        }
        return "Cannot open mapping"
    }

    /// `ReadNamesFromListFile2` with the default list-file charset (UTF-8): skip the BOMs, split
    /// on CR and LF, `Trim()` each name, strip one pair of surrounding quotes, drop the empties.
    static func readListFile(_ path: String) throws -> [String] {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw SevenZipArgumentError("The file operation error for listfile", path)
        }
        guard var text = String(data: data, encoding: .utf8) else {
            throw SevenZipArgumentError(
                "Incorrect item in listfile.\nCheck charset encoding and -scs switch.", path)
        }
        while text.first == "\u{FEFF}" { text.removeFirst() }
        var names: [String] = []
        var current = ""

        func addName() {
            // `AddName` (ListFileUtils.cpp:20-30): Trim(), then strip one pair of quotes, then drop
            // the empties.
            var s = current.trimmingCharacters(in: .whitespacesAndNewlines)
            current = ""
            if s.count >= 2, s.first == "\"", s.last == "\"" {
                s.removeFirst()
                s.removeLast()
            }
            if !s.isEmpty { names.append(s) }
        }

        // Scalar by scalar, because Swift folds "\r\n" into one Character that equals neither of
        // the two separators upstream splits on.
        for scalar in text.unicodeScalars {
            if scalar == "\n" || scalar == "\r" {
                addName()
            } else {
                current.unicodeScalars.append(scalar)
            }
        }
        addName()
        return names
    }
}

// ---------------------------------------------------------------------------
// MARK: - The exception ladder

/// One arm of `WinMain`'s `catch` chain (CPP/7zip/UI/GUI/GUI.cpp:437-494): the process exit code,
/// and the text for the "7-Zip" box — nil where upstream shows nothing, which is only `E_ABORT`.
struct SevenZipFailure: Equatable {
    var exitCode: SevenZipExitCode
    var message: String?
}

/// `WinMain`'s exception ladder as a pure classifier, so every way a command can fail lands on the
/// exit code and the message the Windows launcher would produce (03 section 2.7):
///
///     CNewException                    -> IDS_MEM_ERROR box          -> 8   kMemoryError
///     CMessagePathException            -> box with message + path    -> 7   kUserError
///     CSystemException(E_ABORT)        -> no box                     -> 255 kUserBreak
///     CSystemException(E_OUTOFMEMORY)  -> IDS_MEM_ERROR box (:132)   -> 8   kMemoryError
///     CSystemException(other)          -> HResultToMessage box       -> 2   kFatalError
///     UString/AString/wchar_t*/char*   -> box with the text          -> 2   kFatalError
///     int v                            -> "Error: <v>" box           -> 2   kFatalError
///     ...                              -> "Unknown error" box        -> 2   kFatalError
///
/// Swift cannot catch a C++ exception, so the bridge does it: `SZHandleCurrentException`
/// (Mac/Core/SZBridgeUtils.mm:107-153) turns every arm into an HRESULT plus a message and
/// `SZErrors.errorWithHRESULT:message:` wraps that in an `NSError`. `CNewException` **is**
/// `std::bad_alloc` on this platform (Common/NewHandler.h:99-102), so an allocation failure arrives
/// as `E_OUTOFMEMORY` -> `SZError.Code.outOfMemory` — which is what makes exit code 8 reachable.
///
/// Foundation only, because this file is compiled into the two sandboxed appex targets as well and
/// they must not link `SevenZipKit`; the three bridge constants are therefore spelled out here and
/// `CommandModeTests.testFailureLadderConstantsMatchTheBridge` asserts they still agree, exactly
/// as `ContextMenuItemFlags` mirrors `Settings.ContextMenuFlags`.
enum SevenZipFailureLadder {

    /// `SZErrorDomain` (Mac/Core/SZError.mm:6).
    static let errorDomain = "com.yrambler2001.7zip.SevenZipKit"
    /// `SZErrorHRESULTKey` (Mac/Core/SZError.mm:7).
    static let hresultUserInfoKey = "SZErrorHRESULT"
    /// `SZPathExceptionUserInfoKey` (Mac/Core/SZUpdater.mm): the bridge saw a
    /// `CMessagePathException` — a censor path that named nothing, a duplicate archive path — which
    /// `WinMain` maps to exit code **7**, not the generic 2 (GUI.cpp:452-456). It cannot be told from
    /// any other `UString` exception once it is an HRESULT, so the bridge flags it.
    static let pathExceptionUserInfoKey = "SZPathException"
    /// `SZErrorCodeCancelled` = 3, `SZErrorCodeOutOfMemory` = 4 (Mac/Core/include/SZError.h:23-24).
    static let cancelledErrorCode = 3
    static let outOfMemoryErrorCode = 4

    /// `E_OUTOFMEMORY` / `E_ABORT` as the bridge reports them in `SZErrorHRESULTKey`.
    static let outOfMemoryHRESULT: UInt32 = 0x8007_000E
    static let abortHRESULT: UInt32 = 0x8000_4004

    /// The built-in English of IDS_MEM_ERROR 3000 (GUI/Extract.rc:7). The app passes the localized
    /// text; a Foundation-only caller gets this.
    static let englishMemoryErrorMessage = "The system cannot allocate the required amount of memory"

    /// Classifies any error a command path can produce, in `WinMain`'s own order.
    /// `memoryMessage` is IDS_MEM_ERROR resolved through the active language file.
    static func classify(_ error: Error,
                         memoryMessage: String = englishMemoryErrorMessage) -> SevenZipFailure {
        // CMessagePathException: the two-line "message\npath" box, exit 7 (:452-456).
        if let argumentError = error as? SevenZipArgumentError {
            return SevenZipFailure(exitCode: .userError, message: argumentError.description)
        }

        let nsError = error as NSError
        let hresult = (nsError.userInfo[hresultUserInfoKey] as? NSNumber)?.uint32Value

        if nsError.domain == errorDomain {
            // CSystemException(E_ABORT) -> 255 and no box at all (:457-462).
            if nsError.code == cancelledErrorCode || hresult == abortHRESULT {
                return SevenZipFailure(exitCode: .userBreak, message: nil)
            }
            // CNewException / CSystemException(E_OUTOFMEMORY) -> IDS_MEM_ERROR, 8 (:447-451).
            if nsError.code == outOfMemoryErrorCode || hresult == outOfMemoryHRESULT {
                return SevenZipFailure(exitCode: .memoryError, message: memoryMessage)
            }
            // CMessagePathException -> the same arm as a command-line syntax error, exit 7.
            if nsError.userInfo[pathExceptionUserInfoKey] != nil {
                return SevenZipFailure(exitCode: .userError, message: text(of: nsError))
            }
            return SevenZipFailure(exitCode: .fatalError, message: text(of: nsError))
        }

        // A Foundation/POSIX allocation failure is the same class as CNewException.
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOMEM) {
            return SevenZipFailure(exitCode: .memoryError, message: memoryMessage)
        }
        if hresult == outOfMemoryHRESULT {
            return SevenZipFailure(exitCode: .memoryError, message: memoryMessage)
        }

        return SevenZipFailure(exitCode: .fatalError, message: text(of: nsError))
    }

    /// Just the exit code, for a failure whose box has already been shown — the Progress dialog puts
    /// the error in its own final message, exactly as `CProgressThreadVirt` does (01b section 4.17).
    static func exitCode(for error: Error) -> SevenZipExitCode { classify(error).exitCode }

    /// The message an error contributes, with the two arms the bridge spells differently from
    /// `WinMain` normalised back:
    ///  * `catch (int n)` becomes "Internal Error #N" in `SZHandleCurrentException`; upstream's box
    ///    says "Error: N" (:479-486);
    ///  * no text at all is upstream's `catch (...)` arm, "Unknown error" (:490-493).
    private static func text(of error: NSError) -> String {
        let description = error.localizedDescription
        if let number = internalErrorNumber(in: description) { return "Error: \(number)" }
        return description.isEmpty ? "Unknown error" : description
    }

    private static func internalErrorNumber(in text: String) -> String? {
        let prefix = "Internal Error #"
        guard text.hasPrefix(prefix) else { return nil }
        let digits = text.dropFirst(prefix.count)
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return String(digits)
    }
}
