// ArchiveNaming.swift -- the pure string code the Explorer shell extension runs while it builds
// its menu, ported verbatim so the sandboxed Finder Sync extension can compute the very same
// labels and target paths without loading the engine.
//
// Windows originals (03-shell-integration-inventory.md section 1.6):
//   Get_Correct_FsFile_Name        CPP/7zip/UI/Common/ExtractingFilePath.cpp:170-194
//   GetSubFolderNameForExtract     CPP/7zip/UI/Explorer/ContextMenu.cpp:447-470
//   CreateArchiveName              CPP/7zip/UI/Common/ArchiveName.cpp:32-176
//   ReduceString / GetQuotedReducedString   ContextMenu.cpp:472-492
//   kExtractExcludeExtensions / DoNeedExtract / FindExt   ContextMenu.cpp:494-552
//   kOpenTypes                     ContextMenu.cpp:523-534
//
// Foundation only: this file is compiled into the app, into the Finder Sync extension, into the
// Quick Action extensions and into the unit-test bundle. `SevenZipKitTests/ArchiveNaming.swift`
// is a symlink to it, and `FinderCommandTests` cross-checks every function against the engine's
// own `SZArchiveExtractor.subfolderName(forArchiveNamed:)` and
// `SZUpdater.archiveBaseName(forItemPaths:isHash:baseName:)`.

import Foundation

enum ArchiveNaming {

    // MARK: - Get_Correct_FsFile_Name (ExtractingFilePath.cpp:170-194)

    /// `Correct_PathPart` + the empty-name replacement, with the **POSIX** branch of
    /// `ReplaceIncorrectChars`: only the path separator is illegal off Windows
    /// (`WCHAR_PATH_SEPARATOR`), `g_PathTrailReplaceMode` is false, and
    /// `CorrectUnsupportedName` is `#ifdef _WIN32`. `.` and `..` become empty first, and an
    /// empty result becomes `_` (`k_EmptyReplaceName`).
    static func correctFileSystemName(_ name: String) -> String {
        if name == "." || name == ".." { return "_" }
        var out = ""
        out.reserveCapacity(name.count)
        for ch in name {
            out.append(ch == "/" ? "_" : ch)
        }
        return out.isEmpty ? "_" : out
    }

    // MARK: - GetSubFolderNameForExtract (ContextMenu.cpp:447-470)

    /// Extensions whose *inner* extension is stripped in front of `.001` (`kArcExts`).
    static let volumeInnerExtensions = ["7z", "bz2", "gz", "rar", "zip"]

    /// Inner extensions stripped in front of `.rar`.
    static let rarPartExtensions = ["part001", "part01", "part1"]

    /// The name of the sub-folder `Extract to "<x>/"` proposes for one archive.
    ///
    /// 1. no dot at all -> `Get_Correct_FsFile_Name(name) + "~"`
    /// 2. strip the last extension, `TrimRight` the remainder
    /// 3. strip an inner `7z|bz2|gz|rar|zip` before `.001`, or `part001|part01|part1` before
    ///    `.rar`, then `TrimRight` again
    /// 4. `Get_Correct_FsFile_Name`
    static func subfolderNameForExtract(_ archiveName: String) -> String {
        guard let dotPos = archiveName.lastIndex(of: ".") else {
            return correctFileSystemName(archiveName) + "~"
        }
        let ext = String(archiveName[archiveName.index(after: dotPos)...])
        var res = trimRight(String(archiveName[archiveName.startIndex..<dotPos]))
        if let dotPos2 = res.lastIndex(of: "."), dotPos2 != res.startIndex {
            let ext2 = String(res[res.index(after: dotPos2)...])
            let isSplitVolume = ext.caseInsensitiveCompare("001") == .orderedSame
                && volumeInnerExtensions.contains { $0.caseInsensitiveCompare(ext2) == .orderedSame }
            let isRarPart = ext.caseInsensitiveCompare("rar") == .orderedSame
                && rarPartExtensions.contains { $0.caseInsensitiveCompare(ext2) == .orderedSame }
            if isSplitVolume || isRarPart {
                res = String(res[res.startIndex..<dotPos2])
            }
            res = trimRight(res)
        }
        return correctFileSystemName(res)
    }

    /// `UString::TrimRight`: drops trailing spaces and tabs.
    private static func trimRight(_ s: String) -> String {
        var out = s
        while let last = out.last, last == " " || last == "\t" { out.removeLast() }
        return out
    }

    // MARK: - CreateArchiveName (ArchiveName.cpp:32-176)

    /// The archive extensions whose `_<N>` collision suffix is looked for (`g_ArcExts`).
    static let collisionArchiveExtensions = ["7z", "zip", "tar", "wim"]

    /// `g_HashExts`.
    static let collisionHashExtensions = ["sha256"]

    /// The base name `Add to "<name>.7z"` and `SHA-256 -> <name>.sha256` propose.
    ///
    /// - `paths`: the selected items, absolute or bare names.
    /// - `firstItemIsDirectory`: `fi->IsDir()` of the single selected item. Only consulted when
    ///   `paths.count == 1`, which is exactly when the shell extension passes `&fi0`.
    /// - `isHash`: `keepName` — the file extension is kept and `.sha256` is the collision
    ///   extension.
    /// - `baseName`: the name **without** the `_<N>` suffix (what the `>= 16 items` Explorer
    ///   label shows as `<base>_`).
    static func createArchiveName(paths: [String], isHash: Bool,
                                  firstItemIsDirectory: Bool = false,
                                  baseName: inout String) -> String {
        let keepName = isHash
        var name = "Archive"

        if paths.count == 1 {
            // `fi3.Find(path)`: the port trusts the caller's isDirectory flag instead of
            // stat'ing, so the sandboxed extension needs no file access (Finder hands out
            // directory URLs with a trailing slash).
            name = lastComponent(paths[0])
            if !firstItemIsDirectory && !keepName {
                // The extension is removed only when the name holds exactly one dot.
                if let dotPos = name.firstIndex(of: "."), dotPos != name.startIndex,
                   name[name.index(after: dotPos)...].firstIndex(of: ".") == nil {
                    name = String(name[name.startIndex..<dotPos])
                }
            }
        } else if let first = paths.first {
            // Several items: the name of their common parent folder (`GetOnlyDirPrefix` +
            // `ReverseFind_PathSepar`), "Archive" when there is none.
            var dirPrefix = directoryPrefix(first)
            if dirPrefix.hasSuffix("/") {
                dirPrefix.removeLast()
                if !dirPrefix.isEmpty {
                    if let slash = dirPrefix.lastIndex(of: "/"),
                       slash != dirPrefix.index(before: dirPrefix.endIndex) {
                        name = String(dirPrefix[dirPrefix.index(after: slash)...])
                    } else if FileManager.default.fileExists(atPath: dirPrefix) {
                        // `fi3.Find(dirPrefix)`: a bare relative folder name is its own name.
                        // Selections coming from Finder are always absolute, so this branch is
                        // only reachable from the command line and from the tests.
                        name = dirPrefix
                    }
                }
            }
        }
        name = correctFileSystemName(name)

        // The `_<N>` collision scan: for every selected name that starts with `name`, see
        // whether the tail is `.<arcExt>` (simple collision) or `_<N>.<arcExt>`.
        var ids: [UInt32] = []
        var simpleIsAllowed = true
        let exts = isHash ? collisionHashExtensions : collisionArchiveExtensions
        for path in paths {
            let itemName = lastComponent(path)
            // IsPath1PrefixedByPath2 -> IsString1PrefixedByString2_NoCase, because
            // `g_CaseSensitive` is false on macOS (Wildcard.cpp:9-20).
            guard itemName.count >= name.count,
                  itemName.prefix(name.count).lowercased() == name.lowercased() else { continue }
            let tail = String(itemName.dropFirst(name.count))
            for ext in exts {
                guard tail.count > ext.count else { continue }
                guard tail.lowercased().hasSuffix(ext.lowercased()) else { continue }
                var n = String(tail.dropLast(ext.count))
                guard n.last == "." else { continue }
                n.removeLast()
                if n.isEmpty {
                    simpleIsAllowed = false
                    break
                }
                guard n.count >= 2, n.first == "_" else { continue }
                let digits = String(n.dropFirst())
                guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                      let v = UInt32(digits) else { continue }
                ids.append(v)
                break
            }
        }

        baseName = name
        guard !simpleIsAllowed else { return name }

        ids.sort()
        var v: UInt32 = 2
        for id in ids {
            if id > v { break }
            if id == v { v = id + 1 }
        }
        return name + "_\(v)"
    }

    /// Convenience overload for callers that do not need the `_<N>`-free base name.
    static func createArchiveName(paths: [String], isHash: Bool,
                                  firstItemIsDirectory: Bool = false) -> String {
        var base = ""
        return createArchiveName(paths: paths, isHash: isHash,
                                 firstItemIsDirectory: firstItemIsDirectory, baseName: &base)
    }

    // MARK: - Labels (ContextMenu.cpp:472-492)

    /// `ReduceString`: 64 characters maximum, with ` ... ` spliced into the middle.
    static func reduceString(_ s: String) -> String {
        let maxSize = 64
        let chars = Array(s)
        guard chars.count > maxSize else { return s }
        let half = maxSize / 2
        // s.Delete(32, len - 64) then s.Insert(32, " ... ")
        let head = String(chars[0..<half])
        let tail = String(chars[(chars.count - (maxSize - half))...])
        return head + " ... " + tail
    }

    /// `GetQuotedReducedString`: reduce, escape `&` for the Win32 menu, then quote. macOS menus
    /// have no `&` mnemonic, so the doubling is **not** applied — see `ai/api/finder.md`.
    static func quotedReducedString(_ s: String) -> String { "\"" + reduceString(s) + "\"" }

    // MARK: - kExtractExcludeExtensions (ContextMenu.cpp:494-516)

    /// The exclude list, verbatim and in source order. Membership, not signature sniffing, is
    /// how the shell extension decides "this could be an archive".
    static let extractExcludeExtensions: Set<String> = [
        "3gp",
        "aac", "ans", "ape", "asc", "asm", "asp", "aspx", "avi", "awk",
        "bas", "bat", "bmp",
        "c", "cs", "cls", "clw", "cmd", "cpp", "csproj", "css", "ctl", "cxx",
        "def", "dep", "dlg", "dsp", "dsw",
        "eps",
        "f", "f77", "f90", "f95", "fla", "flac", "frm",
        "gif",
        "h", "hpp", "hta", "htm", "html", "hxx",
        "ico", "idl", "inc", "ini", "inl",
        "java", "jpeg", "jpg", "js",
        "la", "lnk", "log",
        "mak", "manifest", "wmv", "mov", "mp3", "mp4", "mpe", "mpeg", "mpg", "m4a",
        "ofr", "ogg",
        "pac", "pas", "pdf", "php", "php3", "php4", "php5", "phptml", "pl", "pm", "png", "ps",
        "py", "pyo",
        "ra", "rb", "rc", "reg", "rka", "rm", "rtf",
        "sed", "sh", "shn", "shtml", "sln", "sql", "srt", "swa",
        "tcl", "tex", "tiff", "tta", "txt",
        "vb", "vcproj", "vbs",
        "mkv", "wav", "webm", "wma", "wv",
        "xml", "xsd", "xsl", "xslt",
    ]

    /// `FindExt`: the extension after the last dot, 1...32 characters, lower-cased. nil when
    /// there is no dot or the extension is empty or longer than 32 characters — in which case
    /// `DoNeedExtract` returns true.
    static func extractableExtension(of name: String) -> String? {
        guard let dot = name.lastIndex(of: ".") else { return nil }
        let ext = String(name[name.index(after: dot)...])
        guard !ext.isEmpty, ext.count <= 32 else { return nil }
        return ext.lowercased()
    }

    /// `DoNeedExtract`: false when the extension is on the exclude list.
    static func needsExtract(name: String) -> Bool {
        guard let ext = extractableExtension(of: name) else { return true }
        return !extractExcludeExtensions.contains(ext)
    }

    // MARK: - kOpenTypes (ContextMenu.cpp:523-534)

    /// The `Open archive >` children. `""` is the plain "Open archive" entry, which is skipped
    /// when the `kOpen` item is already present.
    static let openTypes = ["", "*", "#", "#:e", "7z", "zip", "cab", "rar"]

    // MARK: - small path helpers (ReverseFind_PathSepar / GetOnlyDirPrefix)

    static func lastComponent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    /// `GetOnlyDirPrefix`: everything up to and including the last separator, `""` when there
    /// is none.
    static func directoryPrefix(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[path.startIndex...slash])
    }

    /// A directory path with exactly one trailing `/` (`Add_PathSepar`).
    static func withTrailingSeparator(_ path: String) -> String {
        if path.isEmpty { return path }
        return path.hasSuffix("/") ? path : path + "/"
    }
}
