# How the Mac app differs from 7-Zip on Windows

The Windows 7-Zip File Manager (`7zFM.exe`), its `7zG` launcher and its Explorer menu are the
specification: the same menus, dialogs and controls, keyboard map, settings and translations. This
page lists what is different. The full audit — every item, how it was verified, and what nobody has
checked by hand yet — is [`ai/parity.md`](../ai/parity.md).

## The same

Browsing archives as folders (including archives inside archives), two panels and four view modes,
Extract and Add to Archive with every option, Test, checksums (all hash methods), Benchmark, Split,
Combine, Link, Properties, comments, self-extracting archives (Windows SFX stubs), multi-volume
archives, encryption, the Options pages, the 93 official translations switched live, and the help
pages.

## Deliberately different

| Windows | macOS |
|---|---|
| Explorer context menu (shell DLL) | a Finder Sync extension (the 7-Zip submenu), two Quick Actions and five Services |
| `7zG.exe`, a separate process | the same app in command mode (`7-Zip.app/Contents/MacOS/7-Zip a archive.7z files…`) |
| Registry `HKCU\Software\7-Zip` | `UserDefaults`, under the same value names |
| Recycle Bin | the Trash; Shift-Command-Backspace deletes permanently |
| `Zone.Identifier` stream ("Propagate Zone.Id") | the `com.apple.quarantine` attribute, same policy |
| Ctrl shortcuts, Insert key | Command shortcuts; Space selects; Option-Space toggles the selection |
| Drive letters, network neighbourhood | mounted volumes |
| Alternate data streams, NT security | hidden; POSIX mode, owner, group and link target shown instead |
| One `7zFM.exe` per window | one app, one window per launch; File ▸ New Window; a Dock click shows the open windows |
| Language applied on OK | applied live; Cancel restores |

## Added on macOS

- **Theme**: Options ▸ macOS ▸ Theme — System, Light or Dark, independent of the system setting.
- **Options ▸ macOS tab**: the theme and grid lines; the other tabs are the Windows ones.
- **Finder integration**: the 7-Zip submenu on Finder's right-click menu (configurable like the
  Windows one), Quick Actions, Services, document icons for 40 archive types.
- **Back / Forward** (Command-[ / Command-]) over each panel's folder history.
- **Update check** (1.0.0): the app checks GitHub Releases for a new version at startup and from
  Help ▸ Check for Updates.

## Known limitations

- Right-to-left languages are translated but not mirrored.
- About a quarter of the upstream translations are incomplete and fall back to English.
- Finder's own context menu, a drag into Finder and a drop on the Dock icon are tested up to the
  macOS boundary but have not been checked by hand on a signed build.
- The Windows-only parts — NTFS streams, drive imaging, the 32-bit limits, `.chm` help (replaced by
  the bundled HTML pages) — are not ported.
