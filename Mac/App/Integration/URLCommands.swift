// URLCommands.swift -- the app side of the Finder integration: the `sevenzip://` scheme, the
// document-open path, the settings hand-off to the sandboxed extensions and the Launch Services
// registration.
//
// Windows equivalents: the `7zG.exe` process the shell extension spawns (CompressCall.cpp:74-98)
// and the `7zFM.exe "%1"` association command (03-shell-integration-inventory.md section 3.3).
// On macOS the extension is sandboxed and may not spawn anything, so it hands the identical argv
// to the running app through `NSWorkspace.open(URL)` (03 section 6.4 variant (b)).
//
// Everything here ends in `CommandExecutor.run(argv:)`, so a URL, a Service, a Quick Action, a
// document open and a real command line all behave the same.

import AppKit
import SevenZipKit

enum URLCommands {

    /// Handles one `sevenzip://` (or `x-7zip://`) URL. Returns the 7zG exit code, which the
    /// Services and the tests use; a URL sender gets no code back (`NSWorkspace.open` is fire and
    /// forget, exactly like `CreateProcess` without `waitFinish`).
    @discardableResult
    static func handle(_ url: URL, parentWindow: NSWindow? = nil) -> SevenZipExitCode {
        let action: CommandURL.Action
        do {
            action = try CommandURL.parse(url)
        } catch where url.host?.lowercased() == CommandURL.testHost {
            // The `test` host is refused *silently* (requests.md, `fastui` -> `resetcmd`; opsgaps):
            // an unattended run that sends a reset to an app without the affordances must not be
            // wedged behind a modal "Unsupported URL command" box that nothing can click away.
            NSLog("7-Zip: ignored %@ (test support is off)", url.absoluteString)
            return .userError
        } catch let error as SevenZipArgumentError {
            CommandExecutor.showError(error.description, parent: parentWindow)
            return .userError
        } catch {
            CommandExecutor.showError(error.localizedDescription, parent: parentWindow)
            return .userError
        }

        switch action {
        case .run(let argv, let temporaryFiles):
            NSApp.activate(ignoringOtherApps: true)
            return CommandExecutor.run(argv: argv, temporaryFiles: temporaryFiles,
                                       parentWindow: parentWindow ?? NSApp.mainWindow)
        case .settings(let show):
            FinderSettingsBridge.push()
            if show {
                Settings.optionsLastPage = 0
                OptionsWindowController.showOptions()
            }
            return .success
        case .testReset(let request):
            // `CommandURL.parse` has already refused the `test` host unless SZ_TEST_SUPPORT=1, so
            // reaching here means test support is on. No `NSApp.activate`: a reset must not steal
            // focus from the test runner, and the window is not being shown for the first time.
            return TestResetCoordinator.handle(request)
        }
    }

    /// The document-open path: `application(_:open:)` for file URLs, `Open With`, a drop on the
    /// Dock icon and a double-click in Finder. Each archive opens in its own window, which is what
    /// `7zFM.exe "%1"` does per file (03 section 6.2, 01 section 9 #32).
    ///
    /// `source` is `.dockDrop` only when the `kAEOpenDocuments` event came from the Dock
    /// (`DockDropDetector`). Windows answers that gesture with the compress items, because 7-Zip is
    /// registered as an Explorer drop handler (03 section 1.7), so a Dock drop of anything but one
    /// single archive starts "Add to archive…" instead of opening.
    @discardableResult
    static func openDocuments(_ urls: [URL], formatHint: String? = nil,
                              source: DocumentOpenSource = .document) -> SevenZipExitCode {
        let fileURLs = urls.filter(\.isFileURL)
        let paths = fileURLs.map(\.path)
        guard !paths.isEmpty else { return .success }

        if source == .dockDrop, formatHint == nil {
            let action = DockDropRouter.action(
                paths: paths,
                directoryFlags: fileURLs.map { isDirectory($0) },
                isRecognisedArchive: { SZCodecs.format(forArchiveName: $0) != nil })
            switch action {
            case .nothing:
                return .success
            case .addToArchive:
                return addToArchive(droppedPaths: paths, directoryFlags: fileURLs.map { isDirectory($0) })
            case .open(let openPaths):
                CommandExecutor.openInFileManager(paths: openPaths, formatHint: nil)
                return .success
            }
        }

        CommandExecutor.openInFileManager(paths: paths, formatHint: formatHint)
        return .success
    }

    /// The `SevenZipCompress` verb ("Add to archive…", `a <SEL> -ad -saa -- <dir><name>`) for a set
    /// of dropped items — the same command line Finder's own 7-Zip menu builds, so the two cannot
    /// drift (03 section 1.4 item B5). Falls back to opening the items when the user has switched
    /// that menu item off, so the drop is never a silent no-op.
    private static func addToArchive(droppedPaths paths: [String],
                                     directoryFlags: [Bool]) -> SevenZipExitCode {
        let selection = FinderSelection(paths: paths, directoryFlags: directoryFlags)
        guard let command = FinderMenuModel.command(verb: "SevenZipCompress", selection: selection,
                                                    settings: IntegrationSettings.loadFromPreferences())
        else {
            CommandExecutor.openInFileManager(paths: paths, formatHint: nil)
            return .success
        }
        NSApp.activate(ignoringOtherApps: true)
        let built = command.argv(for: selection.paths)
        return CommandExecutor.run(argv: built.argv, temporaryFiles: built.temporaryFiles,
                                   parentWindow: NSApp.mainWindow)
    }

    /// `URL.hasDirectoryPath` is only reliable for a URL Finder handed out with a trailing slash;
    /// the Dock does not always add one, so ask the file system.
    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

// ---------------------------------------------------------------------------

/// Writes the five `Options.*` values (plus the resolved menu texts) where the **sandboxed**
/// extensions can read them: their own containers. The app is unsandboxed, so it may write there;
/// a shared App Group is not an option for an ad-hoc build, because macOS 15+ rejects a group
/// identifier without a Team ID prefix (03 section 6.4).
enum FinderSettingsBridge {

    static let extensionBundleIDs = [
        SevenZipBundle.finderSync,
        SevenZipBundle.quickActionExtract,
        SevenZipBundle.quickActionCompress,
    ]

    /// The snapshot the extensions read, built from the app's own settings.
    static func snapshot() -> IntegrationSettings {
        var out = IntegrationSettings()
        out.cascadedMenu = Settings.cascadedMenuValue
        out.menuIcons = Settings.menuIconsValue
        out.eliminateDuplicateRoot = Settings.elimDupExtractValue
        out.writeZoneIdExtract = Settings.writeZoneIdExtract
        out.flags = ContextMenuItemFlags(rawValue: Settings.contextMenuFlags.rawValue)
        var titles: [String: String] = [:]
        for id in IntegrationSettings.menuLangIDs {
            if let text = Lang.translated(id), !text.isEmpty { titles[String(id)] = text }
        }
        out.localizedTitles = titles
        return out
    }

    /// Writes the snapshot into every extension container that exists. Containers are created by
    /// the system the first time an extension runs, so a missing one is not an error -- the
    /// extension then falls back to reading the app's preferences domain directly.
    @discardableResult
    static func push() -> [String] {
        let settings = snapshot()
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: settings.dictionary, format: .xml, options: 0) else { return [] }
        var written: [String] = []
        for bundleID in extensionBundleIDs {
            let url = IntegrationSettings.snapshotURL(forExtension: bundleID)
            // The container itself is created by the system when the extension first runs; only the
            // `Data/Library/Preferences` tree inside it is created here. A missing container means
            // the extension has never been enabled, so there is nothing to configure yet.
            let container = URL(fileURLWithPath: SevenZipBundle.realHomeDirectory)
                .appendingPathComponent("Library/Containers/\(bundleID)")
            guard FileManager.default.fileExists(atPath: container.path) else { continue }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            if (try? data.write(to: url, options: .atomic)) != nil {
                written.append(url.path)
            }
        }
        return written
    }
}

// ---------------------------------------------------------------------------

/// One-time system registrations: Launch Services (document types, the URL scheme) and the
/// Services menu. PROGRESS section 8.3 requires both after a build or an install.
enum LaunchServicesRegistration {

    /// One stamp per bundle identifier, so two copies of the app built with different identifiers
    /// (`Mac/docs/test-support-contract.md`, "Running several instances at once") do not ping-pong:
    /// each launch used to see the other's stamp, re-run `lsregister` and rewrite the key. The
    /// default identifier keeps the original key, so an existing installation is not re-registered.
    private static var stampKey: String {
        let id = Bundle.main.bundleIdentifier ?? SevenZipBundle.app
        return id == SevenZipBundle.app ? "FM.LaunchServicesStamp"
                                        : "FM.LaunchServicesStamp.\(id)"
    }

    static let lsregisterPath =
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework"
        + "/Support/lsregister"

    /// `lsregister -f <bundle>` plus `NSUpdateDynamicServices()`, at most once per bundle path
    /// and version. A Debug build moves around, so the stamp includes the path.
    static func registerIfNeeded() {
        // A test instance must not touch Launch Services: `lsregister -f` is a global, per-user
        // mutation that would make a throwaway build the system's 7-Zip handler, and it costs a
        // subprocess on every launch. Real launches are unaffected (SZ_TEST_SUPPORT unset).
        if TestSupport.isEnabled { return }
        let stamp = Bundle.main.bundleURL.path + "|"
            + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "")
        guard Settings.string(stampKey) != stamp else { return }
        register()
        Settings.setString(stamp, stampKey)
    }

    /// Forces the registration. Also reachable from the report's manual steps.
    static func register() {
        NSUpdateDynamicServices()
        guard FileManager.default.isExecutableFile(atPath: lsregisterPath) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: lsregisterPath)
        process.arguments = ["-f", Bundle.main.bundleURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}

// ---------------------------------------------------------------------------

/// Installed from `MainMenu.build()`, i.e. inside `applicationWillFinishLaunching`, which is the
/// only hook this scope owns. It wires the Services provider, runs a 7zG-mode command line, and
/// keeps the extensions' settings snapshot up to date.
enum FinderIntegration {

    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true

        // NSServices: the provider must exist before the first service is invoked.
        NSApp.servicesProvider = ServicesProvider.shared

        NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { _ in
            LaunchServicesRegistration.registerIfNeeded()
            // The copy the user runs is the one whose Finder extension Finder uses (appfeel).
            FinderExtensionControl.claimAtLaunchIfNeeded()
            FinderSettingsBridge.push()
            CompressCommands.purgeStaleEmailDirectories()
            SevenZipCommandLineEntry.runLaunchCommandIfNeeded()
        }

        // The extension re-reads the snapshot on every menu(for:), so pushing on change is enough
        // (Finder cannot be told that settings changed -- 03 section 6.2).
        NotificationCenter.default.addObserver(
            forName: Settings.Group.contextMenu.notificationName, object: nil, queue: .main) { _ in
            FinderSettingsBridge.push()
        }
        NotificationCenter.default.addObserver(
            forName: Settings.Group.language.notificationName, object: nil, queue: .main) { _ in
            FinderSettingsBridge.push()
        }
    }
}
