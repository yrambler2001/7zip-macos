# Architecture

```
upstream engine (C/, CPP/, Asm/)          unchanged apart from a few guarded patches
        │  static library SevenZipCore
        ▼
SevenZipKit bridge (Mac/Core/)            Objective-C++; pure Objective-C headers, no C++ in Swift
        │  framework
        ▼
7-Zip.app (Mac/App/)                      Swift + AppKit: windows, panels, dialogs, menus, settings
        ├── FinderSync.appex              Finder context menu and toolbar button
        ├── QuickActionExtract.appex      Finder Quick Actions
        ├── QuickActionCompress.appex
        └── QuickLook.appex               Quick Look preview of archives (links the app's SevenZipKit)
```

## Engine

The 7-Zip engine is compiled in place from the upstream source tree (the `7zz` source set without
the console front end, plus the file-manager `UI/Agent` layer that browses archives as folders).
Edits to upstream files are kept to a minimum, guarded by `#ifdef _WIN32` / `__APPLE__`, and listed
in [`Mac/docs/upstream-patches.md`](../Mac/docs/upstream-patches.md). Platform pieces the engine
expects from Windows (string resources, settings, volume type) are implemented in
`Mac/Core/Platform/`.

## Bridge: SevenZipKit

`Mac/Core/include/` is the whole API Swift sees, prefixed `SZ`:

- `SZCodecs` (formats), `SZFolder` / `SZArchiveOpener` / `SZFileSystemFolder` / `SZRootFolder`
  (the folders a panel shows: archives, the file system, the volume list),
  `SZFolderOperations` (copy, move, delete, rename),
- `SZExtractor`, `SZUpdater` (add / update / delete), `SZHasher`, `SZBenchmark`, `SZSplitFile`,
- `SZLang` (the official `Lang/*.txt` files), `SZSettings` (settings under the Windows registry
  value names, stored in `UserDefaults`),
- `SZProgressDelegate` (progress, overwrite and password questions, messages).

Long operations run off the main thread; callbacks are marshalled back to it. Errors are `NSError`s
carrying the engine's HRESULT and message.

## App

`Mac/App/` mirrors the Windows file manager's structure:

| Folder | Contents |
|---|---|
| `MainMenu.swift`, `AppDelegate.swift` | the menu bar (every item keeps its Windows `IDM_*` ID in a comment), launch, open events |
| `MainWindow/` | the window, toolbar, two-panel split view |
| `Panel/` | one file-manager panel: list and icon views, address bar, navigation, selection, drag and drop, context menu |
| `Commands/` | one file per command family (extract, compress, tools, options) |
| `Dialogs/` | one file per Windows dialog (`IDD_*`) |
| `Support/` | settings, language, formatting, icons, the operation runner, temp files, theme |
| `Integration/` | Finder integration, the `sevenzip://` URL commands, the 7zG-style command line |

The app is not sandboxed (it is a file manager); the extensions are, and forward commands to the
app through the `sevenzip://` URL scheme — all but the Quick Look extension, which only reads.

### Quick Look preview

`Mac/QuickLook/` is a view-based `com.apple.quicklook.preview` extension for every archive type the
app declares. It links the app's `SevenZipKit.framework` through
`@executable_path/../../../../Frameworks`, so there is one engine in the bundle. On a background
queue `ArchivePreviewBuilder` opens the archive with `SZArchiveOpener` (no password delegate: an
archive with encrypted headers is reported, not unlocked), reads every item in flat mode into a
tree, and stops after 2 s or 10 000 entries; a `.tar.gz` / `.tar.bz2` / `.tar.xz` / `.tar.zst` is
listed from its decompressed stream (`SZStreamTar`: the outer handler writes into an in-memory
pipe that the tar handler reads sequentially), so nothing is ever extracted. `ArchivePreviewView`
draws it with the panel's own code (`Formatting`, `PanelArchiveIcons`, `ListFontChoice`,
`WinChrome`). The extension's only entitlement is the sandbox; the app pushes the language, theme
and time format into its container (`QuickLookPreferences`). Options ▸ macOS switches it through
PlugInKit (`QuickLookExtensionControl`), like the Finder extension. "Open in 7-Zip" opens the file
with the containing app through Launch Services, not through `sevenzip://`.

### Command URLs

Any process can open a URL, so the app accepts `sevenzip:///run` (and `x-7zip:`) only when both
hold:

- **The URL carries the app's secret** (`&token=`). The app creates 256 random bits on its first
  launch and stores them under `Integration.URLToken` in its settings domain. The Finder extension
  and the Quick Actions read it from the settings snapshot the app writes into their containers at
  every launch, or from the app's domain (read-only shared-preference entitlement). The comparison
  is constant-time. **Reset All Settings** discards it and the relaunched app makes a new one. An
  extension that finds none (the app has never been opened) does not send its command: it launches
  the app, which creates the secret and asks the user to choose the command again.
- **The command is one the extensions build** (`URLCommandPolicy`): the argv must equal what the
  Finder menu model produces for the items it names (extract into the archive's folder, test, add
  next to the items, compress and email, checksums, open), with list files only from the
  extensions' temporary folders, and no target in `~/Library` (except iCloud Drive and
  `CloudStorage`) or a system folder once symbolic links are resolved. Services apply the same
  target checks.

A refused URL runs nothing, is logged (`log stream --predicate 'subsystem == "com.yrambler2001.7zip"'`)
and shows one error box. `sevenzip:///settings` and `sevenzip:///error?code=` need no secret: they
only push settings, show the Options window or show one of a few fixed messages. The full 7zG
grammar remains available to the command line (`7-Zip.app/Contents/MacOS/7-Zip a …`).

## Resources

`Mac/Resources/`: `Lang/`, `SFX/`, `Help/` (from the official release, see
[building.md](building.md#bundled-assets)), `Icons/` and `Assets.xcassets` (the original 7-Zip icons
converted by `Mac/scripts/make-icons.sh`), `Info.plist` files and entitlements.

The detailed design notes and the per-component APIs are in [`ai/architecture.md`](../ai/architecture.md)
and [`ai/api/`](../ai/api/).
