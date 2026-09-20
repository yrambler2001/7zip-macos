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

        // -i / -x / -ai / -ax (AddSwitchWildcardsToCensor).
        var include = try resolve(parser["i"].postStrings, include: true, out: &out)
        out.includePaths = include
        include = try resolve(parser["x"].postStrings, include: false, out: &out)
        out.excludePaths = include
        include = try resolve(parser["ai"].postStrings, include: true, out: &out)
        out.archivePaths = include
        include = try resolve(parser["ax"].postStrings, include: false, out: &out)
        out.archiveExcludePaths = include

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
        out.itemPaths = nonSwitch

        return out
    }

    /// `AddSwitchWildcardsToCensor` (:707-850): the `r`/`w`/`m` modifiers, then one of the three
    /// source markers `!` (immediate name), `@` (list file), `#` (Win32 shared-memory map).
    private static func resolve(_ strings: [String], include: Bool,
                                out: inout SevenZipCommandLine) throws -> [String] {
        var names: [String] = []
        for spec in strings {
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
                    if pos < chars.count, chars[pos] == "0" || chars[pos] == "-" {
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
                    pos += 1
                    if pos < chars.count, chars[pos] == "-" { pos += 1 }
                } else if c == "m" {
                    if typeUsed { throw SevenZipArgumentError("inorrect switch", spec) }
                    typeUsed = true
                    pos += 1
                    if pos < chars.count, chars[pos] == "-" || chars[pos] == "2" { pos += 1 }
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
                names.append(tail)
            case "@":
                names += try readListFile(tail)
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
