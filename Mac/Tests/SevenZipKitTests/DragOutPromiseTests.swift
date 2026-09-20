// DragOutPromiseTests.swift -- the lazy-extraction contract behind dragging archive members out
// to Finder (01-fm-feature-inventory.md §3.15, 03-shell-integration-inventory.md §4.1).
//
// The app fulfils such a drag with an NSFilePromiseProvider whose delegate calls
// `ArchiveDragOut.extract` (Mac/docs/api/extract.md §5), which is
// `SZFolder.extractItems(at:toPath:pathMode:.curPaths, overwriteMode:.overwrite, testMode:false)`
// plus the Progress dialog. Neither `ArchiveDragOut` nor `PanelViewController` is linked into this
// (framework-only) test target, so the delegate below makes exactly that bridge call: what is
// covered here is the promise machinery -- Finder asks the provider for its file and the promised
// bytes appear at the destination it chose -- and the `kCurPaths` semantics a drag needs.
// A real drag to Finder cannot be scripted on this machine; see Mac/docs/reports/cleanup.md.

import XCTest
import AppKit
import UniformTypeIdentifiers
import SevenZipKit

/// What `PanelViewController` does as `NSFilePromiseProviderDelegate`: report the item's name
/// while the drag is in flight, extract on the drop into the directory the receiver chose.
private final class ArchiveDragOutPromiseDelegate: NSObject, NSFilePromiseProviderDelegate {

    let folder: SZFolder
    /// Set by `writePromiseTo` so a test can see where the receiver asked for the file.
    private(set) var writtenDirectories: [String] = []
    private(set) var fulfilmentError: Error?

    init(folder: SZFolder) {
        self.folder = folder
        super.init()
    }

    private func info(_ provider: NSFilePromiseProvider) -> (index: Int, name: String)? {
        guard let dict = provider.userInfo as? [String: Any],
              let index = dict["index"] as? Int,
              let name = dict["name"] as? String else { return nil }
        return (index, name)
    }

    /// ArchiveDragOut.promisedNames(indices:from:): the names Finder shows before anything is
    /// extracted.
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                             fileNameForType fileType: String) -> String {
        info(filePromiseProvider)?.name ?? "item"
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        ArchiveDragOutPromiseDelegate.queue
    }

    static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "test.filePromise"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        guard let item = info(filePromiseProvider) else {
            completionHandler(NSError(domain: "test", code: 1))
            return
        }
        // ArchiveDragOut.extract: kCurPaths, so the paths stay relative to the folder dragged
        // from and a dragged directory keeps its subtree (CAgentFolder::CopyTo for a drag).
        let directory = url.deletingLastPathComponent().path
        writtenDirectories.append(directory)
        do {
            _ = try folder.extractItems(at: [NSNumber(value: item.index)],
                                        toPath: directory.hasSuffix("/") ? directory : directory + "/",
                                        pathMode: .curPaths, overwriteMode: .overwrite,
                                        testMode: false, progress: nil)
            completionHandler(nil)
        } catch {
            fulfilmentError = error
            completionHandler(error)
        }
    }
}

final class DragOutPromiseTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        try? SZCodecs.loadCodecs()
        try? SZLang.shared.loadLanguage(code: "-")
    }

    private var fixtures: String {
        guard let url = Bundle(for: DragOutPromiseTests.self).resourceURL else { fatalError("no resources") }
        return url.appendingPathComponent("Fixtures").path
    }

    private func fixture(_ name: String) -> String { (fixtures as NSString).appendingPathComponent(name) }

    private func workDirectory() -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("sz-dragout-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        return dir
    }

    private func index(of name: String, in folder: SZFolder) throws -> Int {
        for i in 0..<folder.itemCount where folder.nameOfItem(at: i) == name { return i }
        throw XCTSkip("item \(name) not found")
    }

    private func provider(for name: String, in folder: SZFolder,
                          delegate: ArchiveDragOutPromiseDelegate) throws -> NSFilePromiseProvider {
        let index = try self.index(of: name, in: folder)
        let type = (UTType(filenameExtension: (name as NSString).pathExtension) ?? .data).identifier
        let provider = NSFilePromiseProvider(fileType: type, delegate: delegate)
        provider.userInfo = ["name": name, "index": index]
        return provider
    }

    // MARK: - the promise round trip

    /// Finder's side of a drag-out: nothing exists while the drag is in flight, the provider
    /// reports the promised name, and the promised bytes appear in the directory the receiver
    /// chose once it asks for the file.
    ///
    /// An `NSFilePromiseReceiver` read back from a pasteboard does not fulfil in a headless test
    /// bundle (it needs the drag session Finder provides), so the provider's delegate is asked
    /// the same two questions AppKit asks it.
    func testPromiseIsFulfilledWithTheExtractedBytes() throws {
        let folder = try SZFolder.folder(forPath: fixture("test.7z"), passwordDelegate: nil)
        try folder.loadItems()
        let delegate = ArchiveDragOutPromiseDelegate(folder: folder)
        let provider = try provider(for: "readme.txt", in: folder, delegate: delegate)

        // The provider really is a file promise on the pasteboard (what Finder reads as a
        // promised file), and it names a file that does not exist yet -- the HDROP of
        // CPanel::OnDrag only names files that *will* exist.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("sz-dragout-\(UUID().uuidString)"))
        pasteboard.clearContents()
        // AppKit's own promise type for "the name of the file I will hand you", which the
        // provider fills by asking the delegate -- ArchiveDragOut.promisedNames(indices:from:).
        let promisedName = NSPasteboard.PasteboardType("com.apple.pasteboard.promised-suggested-file-name")
        XCTAssertTrue(provider.writableTypes(for: pasteboard).contains(promisedName))
        XCTAssertEqual(provider.pasteboardPropertyList(forType: promisedName) as? String, "readme.txt")

        let destination = workDirectory()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination), [],
                       "nothing may be extracted while the drag is only in flight")

        // The drop: the receiver asks for the file at <destination>/readme.txt.
        try fulfil(provider, named: "readme.txt", into: destination, delegate: delegate)

        XCTAssertNil(delegate.fulfilmentError)
        XCTAssertEqual(delegate.writtenDirectories, [destination])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination), ["readme.txt"])
        let file = (destination as NSString).appendingPathComponent("readme.txt")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: file)),
                       Data("hello 7-zip\n".utf8))
    }

    /// The same fulfilment driven directly, for the two cases a drag must get right:
    /// `kCurPaths` keeps a dragged directory's subtree, and a nested member is written flat into
    /// the receiver's directory rather than under its archive path.
    func testFulfilmentKeepsSubtreeAndRelativePaths() throws {
        let folder = try SZFolder.folder(forPath: fixture("test.7z"), passwordDelegate: nil)
        try folder.loadItems()
        let delegate = ArchiveDragOutPromiseDelegate(folder: folder)

        let subDestination = workDirectory()
        let subProvider = try provider(for: "sub", in: folder, delegate: delegate)
        try fulfil(subProvider, named: "sub", into: subDestination, delegate: delegate)
        let inner = (subDestination as NSString).appendingPathComponent("sub/deep/inner.txt")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: inner)),
                       Data("deep file\n".utf8), "a dragged folder keeps its subtree")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: (subDestination as NSString).appendingPathComponent("sub/big.txt")))

        // Dragging out of a sub-folder of the archive: the folder the drag starts in is the root
        // of the promised paths, so "inner.txt" lands directly in the destination.
        let deep = try folder.bindToFolder(at: try index(of: "sub", in: folder))
        try deep.loadItems()
        let deeper = try deep.bindToFolder(at: try index(of: "deep", in: deep))
        try deeper.loadItems()
        let deepDelegate = ArchiveDragOutPromiseDelegate(folder: deeper)
        let deepDestination = workDirectory()
        let deepProvider = try provider(for: "inner.txt", in: deeper, delegate: deepDelegate)
        try fulfil(deepProvider, named: "inner.txt", into: deepDestination, delegate: deepDelegate)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: deepDestination),
                       ["inner.txt"])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath:
            (deepDestination as NSString).appendingPathComponent("inner.txt"))),
                       Data("deep file\n".utf8))
    }

    private func fulfil(_ provider: NSFilePromiseProvider, named name: String, into directory: String,
                        delegate: ArchiveDragOutPromiseDelegate) throws {
        let done = expectation(description: "wrote \(name)")
        var failure: Error?
        delegate.filePromiseProvider(provider,
                                     writePromiseTo: URL(fileURLWithPath:
                                        (directory as NSString).appendingPathComponent(name))) { error in
            failure = error
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
        if let failure { throw failure }
    }
}
