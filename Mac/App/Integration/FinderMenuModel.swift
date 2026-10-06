// FinderMenuModel.swift -- `CZipContextMenu::QueryContextMenu` as a value tree.
//
// One pass, the same insertion order, the same conditions and the same generated command lines as
// `CPP/7zip/UI/Explorer/ContextMenu.cpp:585-1176` + `CPP/7zip/UI/Common/CompressCall.cpp:186-330`
// (03-shell-integration-inventory.md section 1.4). The Finder Sync extension turns the tree into
// an `NSMenu`; the unit tests assert the tree, so the item set and every switch are covered
// without Finder.
//
// Foundation only: no AppKit, no bridge. The selection is appended at **invoke** time (Explorer
// recomputes it too, ContextMenu.cpp:1305-1323), so merely showing the menu writes no list file.

import Foundation

/// The selection Finder handed over, with no file-system access required: Finder gives directory
/// URLs a trailing slash, which is `fi0.IsDir()` / `_attribs.FirstDirIndex`.
struct FinderSelection {
    /// Absolute POSIX paths, in Finder's order.
    var paths: [String] = []
    /// `isDirectory` per path, parallel to `paths`.
    var directoryFlags: [Bool] = []
    /// The drop target in drop mode; nil = `folderPrefix`, the first item's own folder.
    var dropPath: String?

    init(paths: [String], directoryFlags: [Bool], dropPath: String? = nil) {
        self.paths = paths
        self.directoryFlags = directoryFlags
        self.dropPath = dropPath
    }

    /// Convenience for URLs handed out by `FIFinderSyncController.selectedItemURLs()`.
    init(urls: [URL], dropPath: String? = nil) {
        self.init(paths: urls.map(\.path), directoryFlags: urls.map(\.hasDirectoryPath),
                  dropPath: dropPath)
    }

    var isEmpty: Bool { paths.isEmpty }
    var names: [String] { paths.map(ArchiveNaming.lastComponent) }

    /// `fi0`: the first item.
    var firstName: String { names.first ?? "" }
    var firstIsDirectory: Bool { directoryFlags.first ?? false }

    /// `_attribs.FirstDirIndex`: the index of the first selected directory, -1 when there is none.
    var firstDirectoryIndex: Int { directoryFlags.firstIndex(of: true) ?? -1 }

    /// `folderPrefix` (ContextMenu.cpp:707): the first item's folder with a trailing separator,
    /// or the drop target in drop mode (`:831-832`).
    var baseFolder: String {
        if let dropPath { return ArchiveNaming.withTrailingSeparator(dropPath) }
        guard let first = paths.first else { return "" }
        return ArchiveNaming.directoryPrefix(first)
    }

    var isDropMode: Bool { dropPath != nil }
}

/// One invokable item: the verb `GetCommandString` returns, the label, and the argv split around
/// the place where the selection switches go.
struct FinderMenuCommand: Equatable {
    /// The Windows verb, so the item stays auditable and scriptable by the same name.
    let verb: String
    let title: String
    /// Everything before the selection switches (the command letter and its options).
    let prefixArguments: [String]
    /// Which censor the selection joins, nil when the command carries no selection (Open).
    let selectionKind: CommandURL.SelectionKind?
    /// Everything after the selection switches (`-t`, `-sa*`, `--`, the archive path).
    let suffixArguments: [String]
    /// `InvokeCommandCommon` refuses extract/test when a directory is selected, with
    /// IDS_SELECT_FILES 3015 (ContextMenu.cpp:1280-1284).
    let refusesDirectories: Bool

    init(verb: String, title: String, prefixArguments: [String],
         selectionKind: CommandURL.SelectionKind?, suffixArguments: [String] = [],
         refusesDirectories: Bool = false) {
        self.verb = verb
        self.title = title
        self.prefixArguments = prefixArguments
        self.selectionKind = selectionKind
        self.suffixArguments = suffixArguments
        self.refusesDirectories = refusesDirectories
    }

    /// The full argv for `paths`, plus the temporary list files the receiver must delete.
    func argv(for paths: [String],
              listFileDirectory: String = CommandURL.temporaryRoot)
        -> (argv: [String], temporaryFiles: [String]) {
        guard let kind = selectionKind else {
            return (prefixArguments + suffixArguments, [])
        }
        let selection = CommandURL.selectionArguments(paths: paths, kind: kind,
                                                      listFileDirectory: listFileDirectory)
        return (prefixArguments + selection.arguments + suffixArguments, selection.temporaryFiles)
    }
}

indirect enum FinderMenuNode: Equatable {
    case command(FinderMenuCommand)
    case separator
    case submenu(title: String, verb: String, children: [FinderMenuNode])

    var title: String {
        switch self {
        case .command(let c): return c.title
        case .separator: return "-"
        case .submenu(let title, _, _): return title
        }
    }
}

enum FinderMenuModel {

    /// `kMainVerb` and the two cascaded verbs (ContextMenu.cpp:kMainVerb, :1013-1069).
    static let mainVerb = "SevenZip"
    static let openCascadedVerb = "SevenZip.OpenWithType."
    static let checksumCascadedVerb = "SevenZip.Checksum"

    /// `g_HashCommands` (ContextMenu.cpp:294-309): label, verb suffix, `-scrc` method name.
    static let hashCommands: [(label: String, verb: String, method: String)] = [
        ("CRC-32", "Calc.CRC32", "CRC32"),
        ("CRC-64", "Calc.CRC64", "CRC64"),
        ("XXH64", "Calc.XXH64", "XXH64"),
        ("MD5", "Calc.MD5", "MD5"),
        ("SHA-1", "Calc.SHA1", "SHA1"),
        ("SHA-256", "Calc.SHA256", "SHA256"),
        ("SHA-384", "Calc.SHA384", "SHA384"),
        ("SHA-512", "Calc.SHA512", "SHA512"),
        ("SHA3-256", "Calc.SHA3-256", "SHA3-256"),
        ("BLAKE2sp", "Calc.BLAKE2sp", "BLAKE2sp"),
        ("*", "Calc.*", "*"),
    ]

    /// `MyFormatNew`: replaces `{0}` in a lang template.
    static func format(_ template: String, _ argument: String) -> String {
        template.replacingOccurrences(of: "{0}", with: argument)
    }

    // MARK: - The whole menu

    /// The top-level nodes to append to Finder's contextual menu.
    ///
    /// - `extendedVerbs`: `CMF_EXTENDEDVERBS` (Shift held), which relaxes the extension filter for
    ///   the extract group (`:797`, `:806`).
    static func build(selection: FinderSelection, settings: IntegrationSettings,
                      extendedVerbs: Bool = false) -> [FinderMenuNode] {
        let items = sevenZipItems(selection: selection, settings: settings,
                                  extendedVerbs: extendedVerbs)
        let crcRoot = checksumSubmenu(selection: selection, settings: settings)

        var top: [FinderMenuNode] = []
        if settings.cascadedMenu {
            var children = items
            // `insertHashMenuTo7zipMenu` (:1046-1049): inside the 7-Zip submenu iff cascaded and
            // kCRC_Cascaded is set.
            let inside = settings.flags.contains(.crcCascaded)
            if let crcRoot, inside { children.append(crcRoot) }
            if !children.isEmpty {
                top.append(.submenu(title: "7-Zip", verb: mainVerb, children: children))
            }
            if let crcRoot, !inside { top.append(crcRoot) }
        } else {
            // Flat mode: a separator, then the items inline (`:667-675`).
            if !items.isEmpty { top.append(.separator) }
            top += items
            if let crcRoot { top.append(crcRoot) }
        }
        return top
    }

    /// Every command in the tree, submenu children included, in menu order. Used by the Services
    /// and the Quick Actions, which pick a command by its Windows verb and must not depend on the
    /// user's context-menu item mask.
    static func allCommands(selection: FinderSelection,
                            settings: IntegrationSettings = IntegrationSettings()) -> [FinderMenuCommand] {
        var everything = settings
        everything.flags = .all
        var out: [FinderMenuCommand] = []
        func walk(_ nodes: [FinderMenuNode]) {
            for node in nodes {
                switch node {
                case .command(let c): out.append(c)
                case .separator: break
                case .submenu(_, _, let children): walk(children)
                }
            }
        }
        walk(sevenZipItems(selection: selection, settings: everything, extendedVerbs: true))
        if let crc = checksumSubmenu(selection: selection, settings: everything) { walk([crc]) }
        return out
    }

    // MARK: - Invocation across Finder's process boundary (finderfix)

    /// Every command of a built tree, submenu children included, in menu order (depth first).
    /// The Finder Sync extension numbers its `NSMenuItem`s in exactly this order.
    static func flattenCommands(_ nodes: [FinderMenuNode]) -> [FinderMenuCommand] {
        var out: [FinderMenuCommand] = []
        func walk(_ nodes: [FinderMenuNode]) {
            for node in nodes {
                switch node {
                case .command(let c): out.append(c)
                case .separator: break
                case .submenu(_, _, let children): walk(children)
                }
            }
        }
        walk(nodes)
        return out
    }

    /// The `NSMenuItem.tag` of the command at `index` in `flattenCommands` order. Never 0, which
    /// is what an item that was not numbered carries.
    static func menuTag(forIndex index: Int) -> Int { index + 1 }

    /// The command a clicked Finder Sync menu item stands for.
    ///
    /// Finder does not show the extension's `NSMenu`: it copies it into its own process, and the
    /// copy keeps an item's title, image, tag and action but **not** its `representedObject` or
    /// target. The action message Finder sends back to the extension therefore carries a fresh
    /// item whose `representedObject` is nil -- measured: `invoke` received `rep=nil, tag=0` for
    /// "Add to archive..." and "Open archive" (Mac/docs/reports/finderfix.md). So the command is
    /// found again from what does survive: the tree is rebuilt for the current selection, the tag
    /// picks the item, and the title must agree. A tag that does not match (the settings changed
    /// between showing the menu and the click) falls back to the unique item with that title.
    static func resolveInvocation(tag: Int, title: String,
                                  nodes: [FinderMenuNode]) -> FinderMenuCommand? {
        let commands = flattenCommands(nodes)
        let index = tag - 1
        if commands.indices.contains(index), commands[index].title == title {
            return commands[index]
        }
        let byTitle = commands.filter { $0.title == title }
        // Two "Open archive" items (A1 and the first child of A2) run the same command line.
        if let first = byTitle.first, byTitle.allSatisfy({ $0.prefixArguments == first.prefixArguments
            && $0.suffixArguments == first.suffixArguments && $0.selectionKind == first.selectionKind }) {
            return first
        }
        return nil
    }

    /// The one command with that verb, or nil when the selection does not offer it.
    static func command(verb: String, selection: FinderSelection,
                        settings: IntegrationSettings = IntegrationSettings()) -> FinderMenuCommand? {
        allCommands(selection: selection, settings: settings).first { $0.verb == verb }
    }

    // MARK: - Blocks A and B

    /// A1...B10 in insertion order.
    static func sevenZipItems(selection: FinderSelection, settings: IntegrationSettings,
                              extendedVerbs: Bool) -> [FinderMenuNode] {
        var nodes: [FinderMenuNode] = []
        let flags = settings.flags
        let zone = settings.zoneIDSwitchValue

        // ---- Block A: exactly one selected file whose extension is not excluded (:740-786)
        if selection.paths.count == 1, !selection.firstIsDirectory,
           ArchiveNaming.needsExtract(name: selection.firstName) {
            let path = selection.paths[0]
            let openTitle = settings.localize(2322, "Open archive")          // IDS_CONTEXT_OPEN
            let hasMainOpenItem = flags.contains(.open)
            if hasMainOpenItem {
                nodes.append(.command(openCommand(path: path, type: nil, title: openTitle)))
            }
            if flags.contains(.openAs) {
                // A2: the submenu is titled IDS_CONTEXT_OPEN; its children are the raw type
                // strings, and the empty first entry is skipped when A1 is present (:764-782).
                var children: [FinderMenuNode] = []
                for (index, type) in ArchiveNaming.openTypes.enumerated() {
                    if index == 0 {
                        if hasMainOpenItem { continue }
                        children.append(.command(openCommand(path: path, type: nil,
                                                             title: openTitle)))
                        continue
                    }
                    children.append(.command(openCommand(path: path, type: type, title: type)))
                }
                nodes.append(.submenu(title: openTitle, verb: openCascadedVerb,
                                      children: children))
            }
        }

        guard !selection.isEmpty else { return nodes }

        // ---- needExtract (:799-824)
        var needExtract = selection.firstDirectoryIndex == -1 && !selection.firstIsDirectory
        if needExtract && !extendedVerbs {
            needExtract = selection.names.allSatisfy { ArchiveNaming.needsExtract(name: $0) }
        }

        let baseFolder = selection.baseFolder
        if needExtract {
            // `specFolder` (:834-837): the sub-folder name for one archive, the literal `*` for
            // several, always with a trailing separator.
            let specFolder = (selection.paths.count == 1
                ? ArchiveNaming.subfolderNameForExtract(selection.firstName)
                : "*") + "/"

            if flags.contains(.extractFiles) {
                // B1: `x -o"<dir><spec>/" [-snzN] -ad -an -ai…`
                var prefix = ["x", "-o" + baseFolder + specFolder]
                if let zone { prefix.append("-snz\(zone)") }
                prefix.append("-ad")
                nodes.append(.command(FinderMenuCommand(
                    verb: "SevenZipExtract",
                    title: settings.localize(2323, "Extract files..."),
                    prefixArguments: prefix, selectionKind: .archives,
                    refusesDirectories: true)))
            }
            if flags.contains(.extractHere) {
                // B2: `x -o"<dir>" [-snzN] -an -ai…`
                var prefix = ["x", "-o" + baseFolder]
                if let zone { prefix.append("-snz\(zone)") }
                nodes.append(.command(FinderMenuCommand(
                    verb: "SevenZipExtractHere",
                    title: settings.localize(2326, "Extract Here"),
                    prefixArguments: prefix, selectionKind: .archives,
                    refusesDirectories: true)))
            }
            if flags.contains(.extractTo) {
                // B3: `x -o"<dir><spec>/" [-spe] [-snzN] -an -ai…`
                var prefix = ["x", "-o" + baseFolder + specFolder]
                if settings.eliminateDuplicateRoot { prefix.append("-spe") }
                if let zone { prefix.append("-snz\(zone)") }
                nodes.append(.command(FinderMenuCommand(
                    verb: "SevenZipExtractTo",
                    title: format(settings.localize(2327, "Extract to {0}"),
                                  ArchiveNaming.quotedReducedString(specFolder)),
                    prefixArguments: prefix, selectionKind: .archives,
                    refusesDirectories: true)))
            }
            if flags.contains(.test) {
                // B4: `t -an -ai…`
                nodes.append(.command(FinderMenuCommand(
                    verb: "SevenZipTest",
                    title: settings.localize(2325, "Test archive"),
                    prefixArguments: ["t"], selectionKind: .archives,
                    refusesDirectories: true)))
            }
        }

        // ---- Block B compress items: any non-empty selection, folders included (:878-1000)
        var archiveBase = ""
        let archiveName = ArchiveNaming.createArchiveName(
            paths: selection.paths, isHash: false,
            firstItemIsDirectory: selection.firstIsDirectory, baseName: &archiveBase)
        let name7z = archiveName + ".7z"
        let nameZip = archiveName + ".zip"

        if flags.contains(.compress) {
            // B5: `a -i… -ad -saa -- "<dir><name>"`
            nodes.append(.command(FinderMenuCommand(
                verb: "SevenZipCompress",
                title: settings.localize(2324, "Add to archive..."),
                prefixArguments: ["a"], selectionKind: .items,
                suffixArguments: ["-ad", "-saa", "--", baseFolder + archiveName])))
        }
        if flags.contains(.compressEmail), !selection.isDropMode {
            // B6: `a -i… -seml. -ad -saa -- "<name>"` -- no directory: 7zG builds the archive in
            // its own temp folder and deletes it after sending (03 section 2.5).
            nodes.append(.command(FinderMenuCommand(
                verb: "SevenZipCompressEmail",
                title: settings.localize(2329, "Compress and email..."),
                prefixArguments: ["a"], selectionKind: .items,
                suffixArguments: ["-seml.", "-ad", "-saa", "--", archiveName])))
        }
        if flags.contains(.compressTo7z),
           name7z.caseInsensitiveCompare(selection.firstName) != .orderedSame {
            // B7: `a -i… -t7z -sae -- "<dir><name>.7z"`
            nodes.append(.command(FinderMenuCommand(
                verb: "SevenZipCompressTo7z",
                title: format(settings.localize(2328, "Add to {0}"),
                              ArchiveNaming.quotedReducedString(name7z)),
                prefixArguments: ["a"], selectionKind: .items,
                suffixArguments: ["-t7z", "-sae", "--", baseFolder + name7z])))
        }
        if flags.contains(.compressTo7zEmail), !selection.isDropMode {
            // B8
            nodes.append(.command(FinderMenuCommand(
                verb: "SevenZipCompressTo7zEmail",
                title: format(settings.localize(2330, "Compress to {0} and email"),
                              ArchiveNaming.quotedReducedString(name7z)),
                prefixArguments: ["a"], selectionKind: .items,
                suffixArguments: ["-t7z", "-seml.", "-sae", "--", name7z])))
        }
        if flags.contains(.compressToZip),
           nameZip.caseInsensitiveCompare(selection.firstName) != .orderedSame {
            // B9
            nodes.append(.command(FinderMenuCommand(
                verb: "SevenZipCompressToZip",
                title: format(settings.localize(2328, "Add to {0}"),
                              ArchiveNaming.quotedReducedString(nameZip)),
                prefixArguments: ["a"], selectionKind: .items,
                suffixArguments: ["-tzip", "-sae", "--", baseFolder + nameZip])))
        }
        if flags.contains(.compressToZipEmail), !selection.isDropMode {
            // B10
            nodes.append(.command(FinderMenuCommand(
                verb: "SevenZipCompressToZipEmail",
                title: format(settings.localize(2330, "Compress to {0} and email"),
                              ArchiveNaming.quotedReducedString(nameZip)),
                prefixArguments: ["a"], selectionKind: .items,
                suffixArguments: ["-tzip", "-seml.", "-sae", "--", nameZip])))
        }
        return nodes
    }

    /// A1 / A2 children: the app opened on one archive, optionally with `-t<type>`. This is the
    /// `7zFM.exe "<file>" [-t<type>]` argv (`:1264-1274`), which the same executor recognises.
    static func openCommand(path: String, type: String?, title: String) -> FinderMenuCommand {
        var prefix = [path]
        var verb = "SevenZipOpen"
        if let type, !type.isEmpty {
            prefix.append("-t" + type)
            verb = "SevenZip.Open." + type
        }
        return FinderMenuCommand(verb: verb, title: title, prefixArguments: prefix,
                                 selectionKind: nil)
    }

    // MARK: - Block C: CRC SHA

    /// The `CRC SHA >` submenu, or nil when neither `kCRC` nor `kCRC_Cascaded` is set
    /// (`:1030-1142`). Shown for any selection, files, folders or a mix.
    static func checksumSubmenu(selection: FinderSelection,
                                settings: IntegrationSettings) -> FinderMenuNode? {
        guard !selection.isEmpty else { return nil }
        guard settings.flags.contains(.crc) || settings.flags.contains(.crcCascaded) else {
            return nil
        }
        var children: [FinderMenuNode] = []
        for hash in hashCommands {
            // C1...C11: `h -scrc<M> -i…`
            children.append(.command(FinderMenuCommand(
                verb: checksumCascadedVerb + "." + hash.verb,
                title: hash.label,
                prefixArguments: ["h", "-scrc" + hash.method],
                selectionKind: .items)))
        }
        children.append(.separator)

        // C12: `a -i… -thash -sae -- "<dir><hname>.sha256"`; <hname> is CreateArchiveName with
        // isHash, which keeps the file extension (`:1101-1116`).
        var hashBase = ""
        let hashName = ArchiveNaming.createArchiveName(
            paths: selection.paths, isHash: true,
            firstItemIsDirectory: selection.firstIsDirectory, baseName: &hashBase) + ".sha256"
        children.append(.command(FinderMenuCommand(
            verb: checksumCascadedVerb + ".Generate.SHA256",
            title: "SHA-256 -> " + hashName,
            prefixArguments: ["a"], selectionKind: .items,
            suffixArguments: ["-thash", "-sae", "--", selection.baseFolder + hashName])))

        // C13: `t -thash -an -ai…`; the label is IDS_CONTEXT_TEST + " : " + kpidChecksum's name.
        children.append(.command(FinderMenuCommand(
            verb: checksumCascadedVerb + ".Test.Hash",
            title: settings.localize(2325, "Test archive") + " : "
                + settings.localize(1046, "Checksum"),
            prefixArguments: ["t", "-thash"], selectionKind: .archives,
            refusesDirectories: true)))

        return .submenu(title: "CRC SHA", verb: checksumCascadedVerb, children: children)
    }
}

// ---------------------------------------------------------------------------
// MARK: - Dropping on the Dock icon (03 section 1.7, section 6.2)

/// Where an "open these documents" request came from, because macOS delivers a Dock drop, a
/// double-click and "Open With" through the same `kAEOpenDocuments` event.
enum DocumentOpenSource: Equatable {
    /// Finder double-click, "Open With", `open -a`, a `sevenzip://` open — open the items.
    case document
    /// A drop on the Dock icon: Windows' `DragDropHandlers` gesture (`03 section 1.7`).
    case dockDrop
}

/// What a Dock drop should do. Windows registers 7-Zip as an Explorer **drop handler**, so dragging
/// a selection onto it offers the compress items rather than opening anything
/// (`03 section 1.7`, `ContextMenu.cpp:_dropMode`). macOS has no such handler for folders, but the
/// Dock icon is the same gesture, so the port maps it onto "Add to archive…".
enum DockDropAction: Equatable {
    case nothing
    /// Hand these paths to the file manager, exactly as a double-click does.
    case open([String])
    /// Run the `SevenZipCompress` verb ("Add to archive…", `a … -ad -saa -- <dir><name>`).
    case addToArchive
}

enum DockDropRouter {

    /// The rule, and why it is this rule:
    ///
    ///  * **one single archive stays an open.** The Dock is a legitimate way to open an archive
    ///    without Finder, and the item is indistinguishable from a double-click, which must open.
    ///    The test is Block A's own condition (`ContextMenu.cpp:740-786`): one item, not a
    ///    directory, `needsExtract` (its extension is not in `kExtractExcludeExtensions`), plus the
    ///    engine actually recognising the extension — otherwise a dropped `notes` or `image.png`
    ///    would open an empty panel instead of being compressed.
    ///  * **everything else is "Add to archive…".** Several items, a folder, or one file that is
    ///    not an archive: that is the drop-handler gesture, and Windows answers it with the
    ///    compress items.
    ///
    /// `isRecognisedArchive` is `CCodecs::FindFormatForArchiveName` at the call site; it is a
    /// parameter so this stays Foundation-only and testable without the engine.
    static func action(paths: [String], directoryFlags: [Bool],
                       isRecognisedArchive: (String) -> Bool) -> DockDropAction {
        guard !paths.isEmpty else { return .nothing }
        if paths.count == 1, !(directoryFlags.first ?? false),
           ArchiveNaming.needsExtract(name: ArchiveNaming.lastComponent(paths[0])),
           isRecognisedArchive(paths[0]) {
            return .open(paths)
        }
        return .addToArchive
    }
}
