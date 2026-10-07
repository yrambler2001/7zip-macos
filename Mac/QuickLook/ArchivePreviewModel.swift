// ArchivePreviewModel.swift -- what the Quick Look preview shows for one archive: a summary in the
// terms of 7zFM's Properties / Info (01 §3.11, "Properties (Alt+Enter)": the item sums Size,
// Packed Size, Folders, Files, then one block per archive level with Type, Physical Size and the
// handler's archive properties -- Method, Solid, Blocks, Headers Size, Volumes ...), and the archive's
// contents as a tree with 7zFM's Details columns Name, Size, Packed Size, Modified (01 §3.2,
// "Columns per folder type": an archive folder's kpidName / kpidSize / kpidPackSize / kpidMTime),
// sorted as 7zFM sorts by name: folders first, then CompareFileNames_ForFolderList (01 §3.3).
//
// quicklook scope, a macOS addition (7zFM has no shell preview handler). Foundation + SevenZipKit
// only, so the unit tests drive it directly.
//
// Quick Look parses an archive the moment a user *selects* it in Finder, so everything here is
// bounded and read-only:
//
//   * No password is ever asked for. An archive whose headers are encrypted fails to open with
//     SZErrorCodePasswordRequired and the preview says so; an archive whose *files* are encrypted
//     (a zip with ZipCrypto, a 7z without -mhe) lists normally with Encrypted "+".
//   * Time: the open and the listing together stop after `ArchivePreviewLimits.timeLimit` (2 s).
//     The open is aborted through the progress delegate's checkBreak (E_ABORT) -- a .tar.gz must
//     be decompressed end to end before tar's last header is known -- and then only the outer
//     stream level is opened (gzip, bzip2, xz, zstd, ... carry their size in a few header bytes),
//     so the preview can still say what the file is.
//   * Entries: at most `maxListedEntries` (10 000) items go into the tree; the rest are counted
//     ("... and N more"). The open itself refuses archives of more than `maxOpenedEntries` items
//     (its listing would be held in memory before the first one could be shown).
//   * Nothing is extracted and nothing is written: SZArchiveOpener.openArchive(atPath:) reads the
//     archive's headers through CAgent; no temp copy is made for a top-level archive, and nested
//     archives are shown as files, never opened.
//   * Multi-volume archives: only the previewed file is readable inside the sandbox, so the first
//     volume shows what it can (and the preview says it is part of a set); a failing open of a
//     volume says so instead of "cannot open".

import Foundation
import SevenZipKit

/// The preview's bounds (the brief: about 2 s and about 10 000 entries).
struct ArchivePreviewLimits: Equatable {
    /// Wall-clock budget for open + listing.
    var timeLimit: TimeInterval = 2
    /// Entries put into the tree; the rest are only counted.
    var maxListedEntries = 10_000
    /// An open that reports more items than this is stopped (memory bound).
    var maxOpenedEntries: UInt64 = 250_000
    /// Extra time the outer-level fallback open may take after a stopped open.
    var fallbackTimeLimit: TimeInterval = 1

    static let standard = ArchivePreviewLimits()
}

extension ArchivePreviewStatus {
    /// The status without its message, for the log.
    var kind: String {
        switch self {
        case .complete: return "complete"
        case .truncated(let n): return "truncated(\(n) more)"
        case .stopped(let open, let tooMany): return "stopped(open: \(open), tooMany: \(tooMany))"
        case .encrypted: return "encrypted"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        }
    }
}

/// One row of the tree.
final class ArchivePreviewNode {
    let name: String
    let isDirectory: Bool
    /// kpidSize; for a folder the sum of what it holds (as 7zFM shows an archive folder's size).
    var size: UInt64?
    /// kpidPackSize; for a folder the sum of what it holds.
    var packedSize: UInt64?
    /// kpidMTime as the list shows it (ConvertPropertyToString2 at the timestamp level).
    var modifiedText = ""
    var modified: Date?
    var isEncrypted = false
    /// Children, sorted folders first then by name once the tree is complete.
    private(set) var children: [ArchivePreviewNode] = []
    private var childByName: [String: ArchivePreviewNode] = [:]

    init(name: String, isDirectory: Bool) {
        self.name = name
        self.isDirectory = isDirectory
    }

    /// The child folder `name`, created when missing (an archive may list "a/b.txt" without "a").
    func folder(named name: String) -> ArchivePreviewNode {
        if let existing = childByName[name], existing.isDirectory { return existing }
        let node = ArchivePreviewNode(name: name, isDirectory: true)
        add(node)
        return node
    }

    func add(_ node: ArchivePreviewNode) {
        children.append(node)
        if childByName[node.name] == nil || node.isDirectory { childByName[node.name] = node }
    }

    /// Sorts every level: folders first, then CompareFileNames_ForFolderList (01 §3.3).
    func sortRecursively() {
        children.sort(by: ArchivePreviewNode.precedes)
        for child in children where child.isDirectory { child.sortRecursively() }
    }

    /// Folder sizes: the sums of their contents, kept nil when nothing inside defines one.
    @discardableResult
    func computeFolderSums() -> (size: UInt64?, packed: UInt64?) {
        guard isDirectory else { return (size, packedSize) }
        var size: UInt64?
        var packed: UInt64?
        for child in children {
            let sums = child.computeFolderSums()
            if let s = sums.size { size = (size ?? 0) &+ s }
            if let p = sums.packed { packed = (packed ?? 0) &+ p }
        }
        self.size = size
        self.packedSize = packed
        return (size, packed)
    }

    static func precedes(_ a: ArchivePreviewNode, _ b: ArchivePreviewNode) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        let order = SZFolder.compareFileName(a.name, with: b.name)
        return order != 0 ? order < 0 : a.name < b.name
    }

    /// Number of nodes below this one (not counting it).
    var descendantCount: Int { children.reduce(0) { $0 + 1 + $1.descendantCount } }
}

/// The summary block (01 §3.11).
struct ArchivePreviewSummary: Equatable {
    var fileName = ""
    /// kpidType of every archive level, outermost first: ["gzip", "tar"], ["Split", "7z"], ["7z"].
    var types: [String] = []
    /// kpidMethod of the innermost level ("LZMA2:12", "Deflate", ...).
    var method: String?
    /// kpidSolid of the innermost level.
    var solid: Bool?
    /// kpidNumBlocks of the innermost level.
    var blocks: UInt64?
    /// kpidHeadersSize of the innermost level.
    var headersSize: UInt64?
    /// kpidPhySize of the outermost level, else the file's size.
    var physicalSize: UInt64?
    /// Some item is encrypted (kpidEncrypted), or the headers are.
    var encrypted = false
    /// The headers are encrypted: nothing could be listed without the password.
    var headersEncrypted = false
    /// kpidNumVolumes > 1 or kpidIsVolume on some level, or a volume-style file name.
    var multiVolume = false
    var numVolumes: UInt64?
    /// Item counts over everything the archive lists (not just the shown part), unless the
    /// listing stopped early, then over what was read.
    var folders = 0
    var files = 0
    /// Sum of the files' kpidSize / kpidPackSize (nil when no item defines one).
    var size: UInt64?
    var packedSize: UInt64?
    /// kpidComment of the innermost level.
    var comment: String?
    /// The open's warnings (CAgent::GetErrorMessage) or the per-level error of a level that did
    /// not open (CFfpOpen::ErrorMessage).
    var warning: String?

    /// Compression ratio in percent, as 7zFM's progress shows it ("Compression ratio:" 3905,
    /// packed * 100 / unpacked): the packed sum when there is one, else the physical size.
    var ratioPercent: Int? {
        guard let size, size > 0, let packed = packedSize ?? physicalSize else { return nil }
        return Int((Double(packed) * 100 / Double(size)).rounded())
    }

    /// "gzip → tar".
    var typeText: String { types.joined(separator: " \u{2192} ") }
}

/// Why the tree is not the whole archive, or why there is no tree.
enum ArchivePreviewStatus: Equatable {
    /// Everything is listed.
    case complete
    /// More entries than `maxListedEntries`: `notShown` are counted but not in the tree.
    case truncated(notShown: Int)
    /// The time budget ran out (`openStopped`: during the open; the tree then shows only the outer
    /// level, if that could be opened), or the archive has more than `maxOpenedEntries` items.
    case stopped(openStopped: Bool, tooManyEntries: Bool)
    /// The headers are encrypted; no password is asked for.
    case encrypted
    /// The file could not be opened as an archive.
    case failed(message: String)
    /// Quick Look cancelled the preview.
    case cancelled
}

struct ArchivePreview {
    var summary = ArchivePreviewSummary()
    var root = ArchivePreviewNode(name: "", isDirectory: true)
    var status: ArchivePreviewStatus = .complete
    /// Entries in the tree (the archive's own items, not the folders made up for missing ones).
    var listedEntries = 0
    /// Entries the archive lists (counted while listing).
    var totalEntries = 0
}

// MARK: - building

enum ArchivePreviewBuilder {

    /// Opens `path` and builds the preview within `limits`. Blocking (runs the engine): call it off
    /// the main thread. `isCancelled` is polled throughout.
    static func build(path: String, limits: ArchivePreviewLimits = .standard,
                      timestampLevel: SZTimestampLevel = .min,
                      isCancelled: @escaping () -> Bool = { false }) -> ArchivePreview {
        var preview = ArchivePreview()
        preview.summary.fileName = (path as NSString).lastPathComponent
        preview.summary.physicalSize = fileSize(path)
        _ = try? SZCodecs.loadCodecs()

        let start = Date()
        let watchdog = OpenWatchdog(deadline: start.addingTimeInterval(limits.timeLimit),
                                    maxEntries: limits.maxOpenedEntries, isCancelled: isCancelled)
        let archive: SZArchive
        do {
            archive = try SZArchiveOpener.openArchive(atPath: path, formatHint: nil, passwordDelegate: nil,
                                                      progress: watchdog)
        } catch {
            let nsError = error as NSError
            if watchdog.stopReason == .cancelled || isCancelled() {
                preview.status = .cancelled
                return preview
            }
            if let reason = watchdog.stopReason {
                preview.status = .stopped(openStopped: true, tooManyEntries: reason == .tooManyEntries)
                openOuterLevel(path: path, into: &preview, limits: limits, timestampLevel: timestampLevel,
                               isCancelled: isCancelled)
                return preview
            }
            if nsError.domain == SZErrorDomain, nsError.code == SZError.Code.passwordRequired.rawValue {
                preview.status = .encrypted
                preview.summary.encrypted = true
                preview.summary.headersEncrypted = true
                preview.summary.types = formatName(forPath: path).map { [$0] } ?? []
                return preview
            }
            preview.summary.multiVolume = isVolumeName(preview.summary.fileName)
            if preview.summary.multiVolume {
                // What one volume says without the others: its format, by signature.
                preview.summary.types = signatureFormat(path).map { [$0] } ?? []
            }
            preview.status = .failed(message: failureText(nsError, path: path))
            return preview
        }
        defer { archive.close() }

        readArchiveProperties(archive, into: &preview.summary)
        if isVolumeName(preview.summary.fileName) { preview.summary.multiVolume = true }

        let deadline = start.addingTimeInterval(limits.timeLimit)
        do {
            let folder = try archive.rootFolder()
            list(folder, into: &preview, limits: limits, deadline: deadline,
                 timestampLevel: timestampLevel, isCancelled: isCancelled)
        } catch {
            preview.status = .failed(message: failureText(error as NSError, path: path))
            return preview
        }
        if let outer = streamedTarFormat(preview) {
            _ = listStreamedTar(path: path, outerFormat: outer, into: &preview, limits: limits, deadline: deadline,
                                timestampLevel: timestampLevel, isCancelled: isCancelled)
        }
        return preview
    }

    /// The outer handler's name when the archive is one stream compressor holding one ".tar".
    static func streamedTarFormat(_ preview: ArchivePreview) -> String? {
        guard preview.status == .complete, preview.summary.types.count == 1,
              let type = preview.summary.types.first, let format = SZCodecs.format(named: type), format.keepName,
              preview.root.children.count == 1, let item = preview.root.children.first, !item.isDirectory,
              (item.name as NSString).pathExtension.lowercased() == "tar" else { return nil }
        return format.name
    }

    // MARK: listing

    /// Collects entries into the tree and the counts, whatever reads them (the Agent folder or the
    /// streamed tar).
    struct Accumulator {
        let limits: ArchivePreviewLimits
        var anySize = false, anyPacked = false
        var size: UInt64 = 0, packed: UInt64 = 0

        init(limits: ArchivePreviewLimits) { self.limits = limits }

        /// One entry; `prefix` is its folder path inside the archive ("sub/deep/", "" at the top).
        mutating func add(prefix: String, name: String, isDirectory: Bool, size itemSize: UInt64?,
                          packed itemPacked: UInt64?, encrypted: Bool, modified: Date?,
                          modifiedText: @autoclosure () -> String, into preview: inout ArchivePreview) {
            if encrypted { preview.summary.encrypted = true }
            if isDirectory {
                preview.summary.folders += 1
            } else {
                preview.summary.files += 1
                if let itemSize { size &+= itemSize; anySize = true }
                if let itemPacked { packed &+= itemPacked; anyPacked = true }
            }
            preview.totalEntries += 1
            guard preview.listedEntries < limits.maxListedEntries, !name.isEmpty else { return }
            var parent = preview.root
            for component in prefix.split(separator: "/") where !component.isEmpty {
                parent = parent.folder(named: String(component))
            }
            let node = isDirectory ? parent.folder(named: name) : ArchivePreviewNode(name: name, isDirectory: false)
            if !isDirectory {
                node.size = itemSize
                node.packedSize = itemPacked
                parent.add(node)
            }
            node.isEncrypted = encrypted
            node.modified = modified
            node.modifiedText = ArchivePreviewBuilder.oneLine(modifiedText())
            preview.listedEntries += 1
        }

        /// Sums, sorting and the status.
        func finish(_ preview: inout ArchivePreview, stopped: Bool) {
            preview.summary.size = anySize ? size : nil
            preview.summary.packedSize = anyPacked ? packed : nil
            preview.root.computeFolderSums()
            preview.root.sortRecursively()
            if stopped {
                preview.status = .stopped(openStopped: false, tooManyEntries: false)
            } else if preview.totalEntries > preview.listedEntries {
                preview.status = .truncated(notShown: preview.totalEntries - preview.listedEntries)
            } else {
                preview.status = .complete
            }
        }
    }

    /// Reads every item of `folder` in flat mode (CAgentFolder with _flatMode: every item of every
    /// level, folders included, each with its kpidPrefix), counting them all and putting the first
    /// `maxListedEntries` into the tree.
    static func list(_ folder: SZFolder, into preview: inout ArchivePreview, limits: ArchivePreviewLimits,
                     deadline: Date, timestampLevel: SZTimestampLevel, isCancelled: () -> Bool) {
        if folder.supportsFlatMode {
            folder.flatMode = true
            try? folder.loadItems()
        }
        let flat = folder.supportsFlatMode
        var accumulator = Accumulator(limits: limits)
        var stopped = false
        for index in 0..<folder.itemCount {
            if index % 64 == 0 {
                if isCancelled() { preview.status = .cancelled; return }
                if Date() >= deadline { stopped = true; break }
            }
            // kpidPrefix: CAgentFolder::GetItemPrefix answers nothing on this build (no
            // Z7_AGENT_PROXY2_USE_DIR_PATH_PREFIX), the property does.
            var prefix = ""
            if flat {
                prefix = folder.propertyOfItem(at: index, propID: .prefix) as? String ?? ""
                if prefix.isEmpty { prefix = folder.prefixOfItem(at: index) }
            }
            accumulator.add(
                prefix: prefix, name: folder.nameOfItem(at: index), isDirectory: folder.isDirectory(at: index),
                size: (folder.propertyOfItem(at: index, propID: .size) as? NSNumber)?.uint64Value,
                packed: (folder.propertyOfItem(at: index, propID: .packSize) as? NSNumber)?.uint64Value,
                encrypted: (folder.propertyOfItem(at: index, propID: .encrypted) as? NSNumber)?.boolValue ?? false,
                modified: folder.propertyOfItem(at: index, propID: .mtime) as? Date,
                modifiedText: folder.displayStringOfItem(at: index, propID: .mtime, timestampLevel: timestampLevel),
                into: &preview)
        }
        accumulator.finish(&preview, stopped: stopped)
    }

    /// The single-stream compressors (KeepName handlers: gzip, bzip2, xz, zstd, lzma, Z) whose
    /// one item is a ".tar": 7zFM shows that one item and opens it from a temp copy (the stream is
    /// not seekable, so CArchiveLink cannot open the tar level in place). The preview reads the tar
    /// from the decompressed stream instead (`SZStreamTar`): nothing is written, and the listing is
    /// capped like any other. Returns false when the stream is not a tar.
    static func listStreamedTar(path: String, outerFormat: String, into preview: inout ArchivePreview,
                                limits: ArchivePreviewLimits, deadline: Date, timestampLevel: SZTimestampLevel,
                                isCancelled: @escaping () -> Bool) -> Bool {
        var streamed = ArchivePreview()
        streamed.summary = preview.summary
        streamed.summary.folders = 0
        streamed.summary.files = 0
        var accumulator = Accumulator(limits: limits)
        // Polled from the decompressing worker thread too: no captured state is mutated.
        let checkBreak: () -> Bool = { isCancelled() || Date() >= deadline }
        do {
            try SZStreamTar.listTarInsideFile(atPath: path, outerFormat: outerFormat, timestampLevel: timestampLevel,
                                              checkBreak: { checkBreak() }) { entry in
                var components = entry.path.split(separator: "/").map(String.init)
                let name = components.popLast() ?? ""
                let prefix = components.joined(separator: "/")
                accumulator.add(prefix: prefix, name: name, isDirectory: entry.isDirectory,
                                size: entry.isDirectory ? nil : entry.size, packed: nil, encrypted: false,
                                modified: entry.modified, modifiedText: entry.modifiedText, into: &streamed)
                return !checkBreak()
            }
        } catch {
            // Not a tar, or the stream ended early; what was read is still shown.
        }
        if isCancelled() {
            preview.status = .cancelled
            return true
        }
        guard streamed.totalEntries > 0 else {
            // Out of time before the first header: the outer level stays, marked as stopped.
            if Date() >= deadline { preview.status = .stopped(openStopped: false, tooManyEntries: false) }
            return false
        }
        accumulator.finish(&streamed, stopped: Date() >= deadline)
        streamed.summary.types = preview.summary.types + ["tar"]
        streamed.summary.solid = nil
        preview = streamed
        return true
    }

    /// After a stopped open: the outer stream level alone (gzip / bzip2 / xz / zstd / lzma / Z,
    /// the handlers with KeepName that wrap one stream), within `fallbackTimeLimit`. A container
    /// format (7z, zip, ...) is not reopened: it would only stop again.
    static func openOuterLevel(path: String, into preview: inout ArchivePreview, limits: ArchivePreviewLimits,
                               timestampLevel: SZTimestampLevel, isCancelled: @escaping () -> Bool) {
        guard let format = SZCodecs.format(forArchiveName: path), format.keepName else { return }
        let deadline = Date().addingTimeInterval(limits.fallbackTimeLimit)
        let watchdog = OpenWatchdog(deadline: deadline, maxEntries: limits.maxOpenedEntries, isCancelled: isCancelled)
        guard let archive = try? SZArchiveOpener.openArchive(atPath: path, formatHint: format.name,
                                                            passwordDelegate: nil, progress: watchdog) else { return }
        defer { archive.close() }
        let status = preview.status
        readArchiveProperties(archive, into: &preview.summary)
        if let folder = try? archive.rootFolder() {
            list(folder, into: &preview, limits: limits, deadline: deadline,
                 timestampLevel: timestampLevel, isCancelled: isCancelled)
        }
        preview.status = status
    }

    // MARK: archive properties (01 §3.11: one block per level)

    static func readArchiveProperties(_ archive: SZArchive, into summary: inout ArchivePreviewSummary) {
        summary.warning = [archive.errorMessage, archive.openErrorMessage]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.first
        guard let props = archive.arcProps, props.levelCount > 0 else {
            summary.types = [archive.type]
            return
        }
        var types: [String] = []
        for level in 0..<props.levelCount {
            let type = props.displayString(atLevel: level, propID: .type)
            types.append(type.isEmpty ? (level == props.levelCount - 1 ? archive.type : "?") : type)
            if let n = number(props.property(atLevel: level, propID: .numVolumes)), n > 1 {
                summary.multiVolume = true
                summary.numVolumes = max(summary.numVolumes ?? 0, n)
            }
            if (props.property(atLevel: level, propID: .isVolume) as? NSNumber)?.boolValue == true {
                summary.multiVolume = true
            }
            if (props.property(atLevel: level, propID: .encrypted) as? NSNumber)?.boolValue == true {
                summary.encrypted = true
            }
        }
        summary.types = types
        if let phy = number(props.property(atLevel: 0, propID: .phySize)) { summary.physicalSize = phy }
        let inner = props.levelCount - 1
        let method = props.displayString(atLevel: inner, propID: .method)
        summary.method = method.isEmpty ? nil : method
        summary.solid = (props.property(atLevel: inner, propID: .solid) as? NSNumber)?.boolValue
        summary.blocks = number(props.property(atLevel: inner, propID: .numBlocks))
        summary.headersSize = number(props.property(atLevel: inner, propID: .headersSize))
        let comment = props.displayString(atLevel: inner, propID: .comment)
        summary.comment = comment.isEmpty ? nil : comment
    }

    // MARK: helpers

    static func number(_ value: Any?) -> UInt64? {
        guard let n = value as? NSNumber else { return nil }
        return n.uint64Value
    }

    static func fileSize(_ path: String) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value
    }

    /// The first handler whose signature matches the file's first bytes (the open's first pass).
    static func signatureFormat(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 4096), !header.isEmpty else { return nil }
        return SZCodecs.formats(matchingHeader: header).first(where: { $0.signatureOffset == 0 })?.name
    }

    static func formatName(forPath path: String) -> String? {
        SZCodecs.format(forArchiveName: path)?.name
    }

    /// LF and CR as spaces (the list's VT_BSTR rule, `Formatting.oneLine`).
    static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    /// A name of one volume of a set: "x.7z.001", "x.part2.rar", "x.z01", "x.r00".
    static func isVolumeName(_ name: String) -> Bool {
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension
        if ext.count == 3, ext.allSatisfy(\.isNumber) { return true }                       // .001
        if ext.count == 3, let first = ext.first, "zr".contains(first),
           ext.dropFirst().allSatisfy(\.isNumber) { return true }                          // .z01 .r00
        let stem = (lower as NSString).deletingPathExtension
        let stemExt = (stem as NSString).pathExtension
        return ext == "rar" && stemExt.hasPrefix("part") && stemExt.dropFirst(4).allSatisfy(\.isNumber)
            && stemExt.count > 4
    }

    /// The engine's own text for a failed open: the per-level message when there is one
    /// (GetFolderError's nonOpen_Errors), else the error's description.
    static func failureText(_ error: NSError, path: String) -> String {
        if let message = error.userInfo[SZArchiveOpenErrorMessageKey] as? String, !message.isEmpty {
            // "<path>\nCannot open the file as [zip] archive\nErrors: ..." -- the file is the
            // preview's title already (and the engine may spell the path differently: /tmp for
            // /private/tmp), so any line naming it goes.
            let name = (path as NSString).lastPathComponent
            let lines = message.split(separator: "\n").map(String.init)
                .filter { !$0.isEmpty && $0 != name && !$0.hasSuffix("/" + name) }
            if !lines.isEmpty { return lines.joined(separator: "\n") }
        }
        if error.domain == SZErrorDomain, error.code == SZError.Code.notArchive.rawValue { return "" }
        return error.localizedDescription
    }
}

/// The open's progress delegate: never asks anything, stops the open when the time budget is
/// spent, when the archive reports more items than the preview may hold, or when Quick Look
/// cancelled (COpenArchiveCallback::Open_CheckBreak -> E_ABORT).
final class OpenWatchdog: NSObject, SZProgressDelegate {

    enum StopReason { case time, tooManyEntries, cancelled }

    private let deadline: Date
    private let maxEntries: UInt64
    private let isCancelled: () -> Bool
    private let lock = NSLock()
    private var reason: StopReason?

    init(deadline: Date, maxEntries: UInt64, isCancelled: @escaping () -> Bool) {
        self.deadline = deadline
        self.maxEntries = maxEntries
        self.isCancelled = isCancelled
    }

    var stopReason: StopReason? {
        lock.lock(); defer { lock.unlock() }
        return reason
    }

    private func stop(_ why: StopReason) {
        lock.lock(); defer { lock.unlock() }
        if reason == nil { reason = why }
    }

    private func checkEntries(_ n: UInt64) {
        if n > maxEntries { stop(.tooManyEntries) }
    }

    func progressCheckBreak() -> Bool {
        if isCancelled() { stop(.cancelled) }
        if Date() >= deadline { stop(.time) }
        return stopReason != nil
    }

    func progressSetTotal(_ total: UInt64) {}
    func progressSetCompleted(_ completed: UInt64) {}
    func progressSetRatioInfo(inSize: UInt64, outSize: UInt64) {}
    func progressSetCurrentFile(_ path: String, isDirectory: Bool) {}
    func progressSetNumFilesProcessed(_ numFiles: UInt64) { checkEntries(numFiles) }
    func progressSetTotalFiles(_ totalFiles: UInt64) { checkEntries(totalFiles) }
    func progressAskOverwriteExisting(_ existName: String, existTime: Date?, existSize: NSNumber?,
                                      newName: String, newTime: Date?, newSize: NSNumber?,
                                      suggestedName: AutoreleasingUnsafeMutablePointer<NSString?>?) -> SZOverwriteAnswer {
        .cancel
    }
    func progressAskPassword(forPath path: String) -> String? { nil }
    func progressShowMessage(_ message: String) {}
    func progressSetOperationResult(_ result: SZOperationResult, path: String, isEncrypted: Bool) {}
}
