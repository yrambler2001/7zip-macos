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
        └── QuickActionCompress.appex
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
app through the `sevenzip://` URL scheme.

## Resources

`Mac/Resources/`: `Lang/`, `SFX/`, `Help/` (from the official release, see
[building.md](building.md#bundled-assets)), `Icons/` and `Assets.xcassets` (the original 7-Zip icons
converted by `Mac/scripts/make-icons.sh`), `Info.plist` files and entitlements.

The detailed design notes and the per-component APIs are in [`ai/architecture.md`](../ai/architecture.md)
and [`ai/api/`](../ai/api/).
