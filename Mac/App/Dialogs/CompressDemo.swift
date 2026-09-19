// CompressDemo.swift -- verification harness for the `compress` scope (not part of the
// shipping UI, exactly like Commands/OpsInfraDemo.swift). Enabled only when the environment
// variable SZ_COMPRESS_DEMO is set:
//
//   SZ_COMPRESS_DEMO=dialog   registers a stand-in OperationContext over a freshly made
//                             temp folder and opens the Compress dialog, so every control,
//                             the dependent combos and the memory estimate can be driven
//                             with osascript and captured with screencapture.
//   SZ_COMPRESS_DEMO=options  the same, and clicks the Options button once the dialog is up.
//   SZ_COMPRESS_DEMO=quick    runs the "Compress to <name>.7z" quick command (no dialog) and
//                             logs the resulting archive.
//
// SZ_COMPRESS_DIR overrides the source folder. The stand-in provider exists only while the
// variable is set; the real provider is the `panel` scope's window controller
// (Mac/App/Support/OperationContext.swift).

import AppKit
import SevenZipKit

enum CompressDemo {

    /// Called from MainMenu.build() at startup; does nothing unless the variable is set.
    static func installIfRequested() {
        guard let mode = ProcessInfo.processInfo.environment["SZ_COMPRESS_DEMO"],
              !mode.isEmpty else { return }
        NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification,
                                               object: nil, queue: .main) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { run(mode: mode) }
        }
    }

    private static var provider: DemoContextProvider?

    static func run(mode: String) {
        guard let directory = sourceDirectory() else {
            NSLog("compress-demo: could not prepare the source folder")
            return
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory))?.sorted() ?? []
        let paths = names.map { (directory as NSString).appendingPathComponent($0) }
        NSLog("compress-demo: mode=%@ dir=%@ items=%@", mode, directory, names.joined(separator: ","))

        let folder: SZFolder
        do {
            folder = try SZFileSystemFolder.folder(withPath: directory)
        } catch {
            NSLog("compress-demo: cannot open %@: %@", directory, error.localizedDescription)
            return
        }
        let context = OperationContext(folder: folder, displayPath: directory, isArchive: false,
                                       isFileSystem: true, indices: Array(0..<names.count),
                                       names: names, paths: paths, folderPath: directory,
                                       otherPanelPath: nil, window: NSApp.mainWindow)
        let p = DemoContextProvider(context: context)
        provider = p
        ActiveContext.register(p)

        switch mode {
        case "quick":
            CompressCommands.compressTo(formatName: "7z", email: false)
            let expected = (directory as NSString)
                .appendingPathComponent(SZUpdater.archiveBaseName(forItemPaths: paths, isHash: false,
                                                                 baseName: nil) + ".7z")
            NSLog("compress-demo: quick archive exists=%d at %@",
                  FileManager.default.fileExists(atPath: expected) ? 1 : 0, expected)
        case "options":
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { clickOptionsButton() }
            CompressCommands.addToArchive(showDialog: true, email: false)
            NSLog("compress-demo: dialog closed")
        default:
            CompressCommands.addToArchive(showDialog: true, email: false)
            NSLog("compress-demo: dialog closed")
        }
    }

    /// Presses the Options button of the modal Compress dialog, so the sheet can be captured
    /// without a second osascript round-trip.
    private static func clickOptionsButton() {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.isKeyWindow }) else { return }
        func find(_ view: NSView) -> NSButton? {
            for sub in view.subviews {
                if let button = sub as? NSButton,
                   button.title == Lang.text(2100, "Options") { return button }
                if let found = find(sub) { return found }
            }
            return nil
        }
        guard let content = window.contentView, let button = find(content) else {
            NSLog("compress-demo: Options button not found")
            return
        }
        button.performClick(nil)
    }

    /// A small tree to compress: readme.txt, notes.md, sub/big.txt.
    private static func sourceDirectory() -> String? {
        if let given = ProcessInfo.processInfo.environment["SZ_COMPRESS_DIR"], !given.isEmpty {
            return given
        }
        let fm = FileManager.default
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("compress-demo")
        let sub = (dir as NSString).appendingPathComponent("sub")
        do {
            try? fm.removeItem(atPath: dir)
            try fm.createDirectory(atPath: sub, withIntermediateDirectories: true)
            try "hello 7-zip\n".write(toFile: (dir as NSString).appendingPathComponent("readme.txt"),
                                     atomically: true, encoding: .utf8)
            try "# notes\nsecond line\n".write(toFile: (dir as NSString).appendingPathComponent("notes.md"),
                                               atomically: true, encoding: .utf8)
            try String(repeating: "A", count: 4000)
                .write(toFile: (sub as NSString).appendingPathComponent("big.txt"),
                       atomically: true, encoding: .utf8)
            return dir
        } catch {
            NSLog("compress-demo: %@", error.localizedDescription)
            return nil
        }
    }

    private final class DemoContextProvider: NSObject, OperationContextProviding {
        let context: OperationContext
        init(context: OperationContext) { self.context = context }
        func currentOperationContext() -> OperationContext? { context }
        func refreshAfterOperation() { NSLog("compress-demo: refreshAfterOperation") }
        func refreshAllPanels() { NSLog("compress-demo: refreshAllPanels") }
    }
}
