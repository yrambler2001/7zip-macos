// OpsInfraDemo.swift -- verification harness for the `opsinfra` scope (not part of the
// shipping UI). Enabled only when the environment variable SZ_OPSINFRA_DEMO is set:
//
//   SZ_OPSINFRA_DEMO=extract   real extraction of a fixture archive into a temp folder with
//                              the Progress dialog visible, then a short hold phase that
//                              keeps reporting progress so Pause / Background / Cancel can
//                              be exercised.
//   SZ_OPSINFRA_DEMO=errors    the same with collected messages, so the embedded message
//                              list, the Errors row and the "keep the window open" behaviour
//                              show up.
//   SZ_OPSINFRA_DEMO=dialogs   shows Overwrite, Password (extract and compress variants),
//                              Messages and Memory usage request in sequence.
//
// SZ_OPSINFRA_ARCHIVE overrides the fixture archive; otherwise Mac/Tests/Fixtures/test.7z is
// located by walking up from the app bundle.

import AppKit
import SevenZipKit

enum OpsInfraDemo {

    /// Called from MainMenu.build() at startup; does nothing unless the variable is set.
    static func installIfRequested() {
        guard let mode = ProcessInfo.processInfo.environment["SZ_OPSINFRA_DEMO"],
              !mode.isEmpty else { return }
        NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification,
                                              object: nil, queue: .main) { _ in
            // let the main window come up first
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { run(mode: mode) }
        }
    }

    static func run(mode: String) {
        NSLog("opsinfra-demo: mode=%@", mode)
        switch mode {
        case "dialogs": runDialogs()
        case "errors": runExtraction(withMessages: true)
        default: runExtraction(withMessages: false)
        }
        NSLog("opsinfra-demo: finished mode=%@", mode)
    }

    // MARK: extraction with the progress dialog

    private static func runExtraction(withMessages: Bool) {
        guard let archive = fixtureArchive() else {
            NSLog("opsinfra-demo: no fixture archive found (set SZ_OPSINFRA_ARCHIVE)")
            return
        }
        let destination = (TestSupport.temporaryDirectory as NSString)
            .appendingPathComponent("opsinfra-demo-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
        NSLog("opsinfra-demo: extracting %@ -> %@", archive, destination)

        var options = OperationRunner.Options(title: Lang.text(3300, "Extracting"))
        options.initialStatus = .extracting
        options.titleFileName = archive
        options.parentWindow = NSApp.mainWindow
        options.waitMode = false            // always show the dialog, even for a small archive
        let holdSeconds = Double(ProcessInfo.processInfo.environment["SZ_OPSINFRA_HOLD"] ?? "8") ?? 8

        let result = OperationRunner.run(options) { runner -> SZOperationSummary? in
            guard let folder = try? SZFolder.folder(forPath: archive, passwordDelegate: nil) else {
                return nil
            }
            let summary = try folder.extractItems(at: nil, toPath: destination, pathMode: .fullPaths,
                                                  overwriteMode: .overwrite, testMode: false,
                                                  progress: runner)
            if withMessages {
                // What MessageError / SetOperationResult would add to the list.
                runner.progressShowMessage("Data error : \(archive)/sub/big.txt")
                runner.progressShowMessage("CRC failed : \(archive)/readme.txt")
                runner.progressShowMessage("Demo diagnostic message")
            }
            // Hold phase (demo only): keep reporting progress so the dialog stays on screen
            // and Pause / Background / Cancel can be driven from the outside.
            let steps = Int(holdSeconds * 10)
            runner.progressSetTotal(UInt64(steps))
            var lastBand: Int32 = -1
            for step in 0...steps {
                // getpriority(PRIO_DARWIN_PROCESS) is 1 while the process runs in the Darwin
                // background band -- the macOS stand-in for IDLE_PRIORITY_CLASS.
                let band = getpriority(PRIO_DARWIN_PROCESS, 0)
                if band != lastBand {
                    lastBand = band
                    NSLog("opsinfra-demo: darwin process band=%d", band)
                }
                if runner.progressCheckBreak() {
                    NSLog("opsinfra-demo: checkBreak -> cancelling")
                    throw NSError(domain: SZErrorDomain, code: SZError.Code.cancelled.rawValue,
                                  userInfo: [NSLocalizedDescriptionKey: "cancelled"])
                }
                runner.progressSetCompleted(UInt64(step))
                runner.progressSetRatioInfo(inSize: UInt64(step) * 1024, outSize: UInt64(step) * 512)
                runner.progressSetCurrentFile("\(destination)/sub/deep/inner.txt", isDirectory: false)
                Thread.sleep(forTimeInterval: 0.1)
            }
            return summary
        }

        switch result {
        case .success(let summary):
            NSLog("opsinfra-demo: extraction OK files=%llu errors=%lu",
                  summary?.filesProcessed ?? 0, UInt(summary?.errorCount ?? 0))
        case .failure(let error):
            NSLog("opsinfra-demo: extraction failed: %@", error.localizedDescription)
        }
    }

    // MARK: the four question dialogs

    private static func runDialogs() {
        let parent = NSApp.mainWindow

        // IDD_OVERWRITE 3500
        let old = OverwriteDialog.FileInfo(path: "/tmp/opsinfra-demo/readme.txt", size: 12,
                                          time: Date(timeIntervalSince1970: 1_704_209_400))
        let new = OverwriteDialog.FileInfo(path: "test.7z/readme.txt", size: 4096,
                                          time: Date(), isFileSystemFile: false)
        let answer = OverwriteDialog.run(oldFile: old, newFile: new, showExtraButtons: true, parent: parent)
        NSLog("opsinfra-demo: overwrite answer=%ld suggested=%@",
              answer.answer.rawValue, answer.suggestedName ?? "-")

        // IDD_PASSWORD 3800, extract side
        let password = PasswordDialog.askPassword(forPath: "/tmp/secret.7z", parent: parent)
        NSLog("opsinfra-demo: password=%@", password ?? "(cancelled)")

        // IDD_PASSWORD 3800 + the compress-side extras (verify + encrypt file names)
        var compressOptions = PasswordDialog.Options()
        compressOptions.subject = "archive.7z"
        compressOptions.requiresVerification = true
        compressOptions.showsEncryptFileNames = true
        let compressResult = PasswordDialog.run(compressOptions, parent: parent)
        NSLog("opsinfra-demo: compress password=%@ encryptNames=%d",
              compressResult?.password ?? "(cancelled)", compressResult?.encryptFileNames == true ? 1 : 0)

        // IDD_MESSAGES 6602
        MessagesDialog.show(messages: [
            "Data error : test.7z/sub/big.txt",
            "CRC failed : test.7z/readme.txt",
            "Cannot open file '/tmp/broken.7z' as archive",
        ], parent: parent)

        // IDD_MEM 7800
        var memOptions = MemoryUseDialog.Options()
        memOptions.requiredGB = 6
        memOptions.limitGB = 1
        memOptions.ramGB = UInt32(ProcessInfo.processInfo.physicalMemory >> 30)
        memOptions.filePath = "big.dat"
        memOptions.archivePath = "/tmp/huge.7z"
        memOptions.showRemember = true
        let mem = MemoryUseDialog.run(memOptions, parent: parent)
        NSLog("opsinfra-demo: memory answer=%ld limit=%u remember=%d",
              mem?.answer.rawValue ?? -1, mem?.limitGB ?? 0, mem?.remember == true ? 1 : 0)
    }

    // MARK: fixture lookup

    private static func fixtureArchive() -> String? {
        if let path = ProcessInfo.processInfo.environment["SZ_OPSINFRA_ARCHIVE"],
           FileManager.default.fileExists(atPath: path) {
            return path
        }
        var directory = URL(fileURLWithPath: Bundle.main.bundlePath)
        for _ in 0..<12 {
            directory = directory.deletingLastPathComponent()
            let candidate = directory.appendingPathComponent("Mac/Tests/Fixtures/test.7z").path
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
            if directory.path == "/" { break }
        }
        return nil
    }
}
