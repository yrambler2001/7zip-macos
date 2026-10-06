// FileTypes.swift -- the single source of truth for the file types 7-Zip associates itself with.
//
// Windows takes this list from string resource 100 of 7z.dll
// (CPP/7zip/Bundles/Format7zF/resource.rc:36-39, parsed by CCodecIcons::LoadIcons as "ext:index"
// pairs and turned into the Options > System rows by CExtDatabase::Read) -- see
// 03-shell-integration-inventory.md section 3.1. The pairs below are that resource string,
// verbatim and in the same order, with the icon index naming CPP/7zip/Archive/Icons/*.ico
// (resource.rc:6-32).
//
// NOTE: 03 section 3.1 and PROGRESS section 7.2 say "39 extensions"; the 26.03 resource string
// actually holds 40 (the prose miscounts its own table). All 40 are listed here.
//
// Plain data on purpose: no AppKit, no engine calls. The `finder` scope generates the
// CFBundleDocumentTypes / UTImportedTypeDeclarations entries from `FileTypes.all`; the Options >
// System page renders one row per entry. Shape documented in ai/api/options.md.

import Foundation
import UniformTypeIdentifiers

/// One associable file type (one row of the Options > System list, one document type).
struct SevenZipFileType: Equatable {

    /// Lowercase extension without a dot, as the resource lists it ("7z", "tbz2", "001").
    let ext: String

    /// Windows icon resource index inside 7z.dll (0-26); also the `DefaultIcon` index written by
    /// NRegistryAssoc::AddShellExtensionInfo.
    let iconIndex: Int

    /// Name of the archive handler that owns the extension (SZCodecs format name, lowercase as
    /// the engine reports it). `SZCodecs.format(forExtension:)` stays authoritative at runtime;
    /// this field lets the extension and the Info.plist generator work without loading codecs.
    let format: String

    /// `<EXT> Archive` -- the ProgID title Windows writes (SystemPage.cpp:304-305).
    var localizedDescription: String { ext.uppercased() + " Archive" }

    /// `7-Zip.<ext>` -- the Windows ProgID; kept as the imported UTI's identifier suffix so the
    /// two platforms stay auditable.
    var progID: String { "7-Zip." + ext }

    /// `CPP/7zip/Archive/Icons/<name>.ico` for `iconIndex`.
    var iconFileName: String { FileTypes.iconNames[iconIndex] ?? "7z" }

    /// The system UTI for the extension when macOS already declares one (public.zip-archive,
    /// com.apple.disk-image, ...), else nil: those need a UTImportedTypeDeclaration.
    var systemUTType: UTType? {
        guard let t = UTType(filenameExtension: ext), t.isDeclared, !t.identifier.hasPrefix("dyn.") else { return nil }
        return t
    }

    /// UTI to pass to `NSWorkspace.setDefaultApplication(at:toOpen:)`: the system type when there
    /// is one, else the type this app imports (`org.7-zip.<ext>-archive`).
    var utType: UTType? { systemUTType ?? UTType(importedTypeIdentifier) }

    /// Identifier this app declares for extensions macOS does not know (03 section 6.1).
    var importedTypeIdentifier: String { "org.7-zip." + ext + "-archive" }
}

enum FileTypes {

    /// 7z.dll string resource 100, in resource order. Format names from
    /// 03-shell-integration-inventory.md section 3.2 (REGISTER_ARC* tables).
    static let all: [SevenZipFileType] = [
        SevenZipFileType(ext: "7z", iconIndex: 0, format: "7z"),
        SevenZipFileType(ext: "zip", iconIndex: 1, format: "zip"),
        SevenZipFileType(ext: "rar", iconIndex: 3, format: "Rar5"),
        SevenZipFileType(ext: "001", iconIndex: 9, format: "Split"),
        SevenZipFileType(ext: "cab", iconIndex: 7, format: "Cab"),
        SevenZipFileType(ext: "iso", iconIndex: 8, format: "Iso"),
        SevenZipFileType(ext: "xz", iconIndex: 23, format: "xz"),
        SevenZipFileType(ext: "txz", iconIndex: 23, format: "xz"),
        SevenZipFileType(ext: "lzma", iconIndex: 16, format: "lzma"),
        SevenZipFileType(ext: "tar", iconIndex: 13, format: "tar"),
        SevenZipFileType(ext: "cpio", iconIndex: 12, format: "Cpio"),
        SevenZipFileType(ext: "bz2", iconIndex: 2, format: "bzip2"),
        SevenZipFileType(ext: "bzip2", iconIndex: 2, format: "bzip2"),
        SevenZipFileType(ext: "tbz2", iconIndex: 2, format: "bzip2"),
        SevenZipFileType(ext: "tbz", iconIndex: 2, format: "bzip2"),
        SevenZipFileType(ext: "gz", iconIndex: 14, format: "gzip"),
        SevenZipFileType(ext: "gzip", iconIndex: 14, format: "gzip"),
        SevenZipFileType(ext: "tgz", iconIndex: 14, format: "gzip"),
        SevenZipFileType(ext: "tpz", iconIndex: 14, format: "gzip"),
        SevenZipFileType(ext: "zst", iconIndex: 26, format: "zstd"),
        SevenZipFileType(ext: "tzst", iconIndex: 26, format: "zstd"),
        SevenZipFileType(ext: "z", iconIndex: 5, format: "Z"),
        SevenZipFileType(ext: "taz", iconIndex: 5, format: "Z"),
        SevenZipFileType(ext: "lzh", iconIndex: 6, format: "Lzh"),
        SevenZipFileType(ext: "lha", iconIndex: 6, format: "Lzh"),
        SevenZipFileType(ext: "rpm", iconIndex: 10, format: "Rpm"),
        SevenZipFileType(ext: "deb", iconIndex: 11, format: "Ar"),
        SevenZipFileType(ext: "arj", iconIndex: 4, format: "Arj"),
        SevenZipFileType(ext: "vhd", iconIndex: 20, format: "VHD"),
        SevenZipFileType(ext: "vhdx", iconIndex: 20, format: "VHDX"),
        SevenZipFileType(ext: "wim", iconIndex: 15, format: "wim"),
        SevenZipFileType(ext: "swm", iconIndex: 15, format: "wim"),
        SevenZipFileType(ext: "esd", iconIndex: 15, format: "wim"),
        SevenZipFileType(ext: "fat", iconIndex: 21, format: "FAT"),
        SevenZipFileType(ext: "ntfs", iconIndex: 22, format: "NTFS"),
        SevenZipFileType(ext: "dmg", iconIndex: 17, format: "Dmg"),
        SevenZipFileType(ext: "hfs", iconIndex: 18, format: "HFS"),
        SevenZipFileType(ext: "xar", iconIndex: 19, format: "Xar"),
        SevenZipFileType(ext: "squashfs", iconIndex: 24, format: "SquashFS"),
        SevenZipFileType(ext: "apfs", iconIndex: 25, format: "APFS"),
    ]

    /// Icon resource index -> `CPP/7zip/Archive/Icons/<name>.ico` (resource.rc:6-32).
    static let iconNames: [Int: String] = [
        0: "7z", 1: "zip", 2: "bz2", 3: "rar", 4: "arj", 5: "z", 6: "lzh", 7: "cab", 8: "iso",
        9: "split", 10: "rpm", 11: "deb", 12: "cpio", 13: "tar", 14: "gz", 15: "wim", 16: "lzma",
        17: "dmg", 18: "hfs", 19: "xar", 20: "vhd", 21: "fat", 22: "ntfs", 23: "xz",
        24: "squashfs", 25: "apfs", 26: "zst",
    ]

    static func type(forExtension ext: String) -> SevenZipFileType? {
        let lower = ext.lowercased()
        return all.first { $0.ext == lower }
    }

    /// Extensions in resource order.
    static var extensions: [String] { all.map(\.ext) }
}
