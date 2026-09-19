# fsfolder — state notes

Running log; the final report is at the bottom of the file when the scope is finished.

## Phase 1-4 (listing, operations, volumes root, change notification)

Exists and builds (`Mac/scripts/build.sh` OK, `Mac/scripts/test.sh` 17/17):

- `Mac/Core/Internal/MacFileOps.h/.mm` (new): Trash via `NSFileManager.trashItemAtURL:`,
  `copyfile(3)` metadata/xattr/resource-fork copy, `NSURLIsPackageKey` bundle test,
  `mountedVolumeURLs` volume list + `statfs` file-system name, `getfsstat` mount fingerprint,
  `realpath`. Engine-free header (Foundation only inside the `.mm`).
- `Mac/Core/Internal/FSFolderMac.h/.cpp`: full `CFSFolderMac`. Columns = FSFolder.cpp `kProps`
  (Name, Size, Modified, Created=birthtime, Accessed, Metadata Changed=st_ctimespec,
  Attributes, Packed Size=st_blocks*512, Mode, User, Group, Link, iNode, Links, Comment,
  Folders, Files, + Path Prefix in flat view). Windows attribute bits mapped from mode +
  BSD flags (D A R L H C O S). `IFolderOperations` (CopyTo / CopyFrom / Delete / Rename /
  CreateFolder / CreateFile / SetProperty(kpidComment) / CopyFromFile=E_NOTIMPL),
  `IFolderCalcItemFullSize`, `IFolderGetItemFullSize`, `IFolderSetFlatMode`, `IFolderClone`,
  `IFolderCompare`, `IFolderWasChanged`, plus the exported `CopyFileSystemItems()`.
- `Mac/Core/Internal/FSEventsWatcher.*`: non-recursive by default (events filtered against the
  directory's own path and its `realpath`), recursive in flat view, 0.5 s coalescing,
  `RootChanged()` when the watched directory is deleted or renamed.
- `Mac/Core/Internal/RootFolderMac.*`: volumes folder now built from `mountedVolumeURLs`
  (label, total/free from `URLResourceValues`, type from removable/ejectable/local + fstype),
  `kpidOutName`, `kpidPath` = mount point, and `IFolderWasChanged` on the mount fingerprint.
- `Mac/Core/include/SZFileSystemFolder.h` + `.mm`: the public Objective-C surface, including a
  private `IFolderOperationsExtractCallback` adapter over `SZProgressDelegate` (AskWrite copies
  `CExtractCallbackImp::AskWrite` semantics, incl. YesToAll/NoToAll memory and AutoRenamePath).
- `Mac/Core/include/SZRootFolder.h` + `.mm`: `isVolumesFolder`, `mountPathOfItem(at:)`.

Touched outside ownership: two assertions in
`Mac/Tests/SevenZipKitTests/SevenZipKitTests.swift` (`testFileSystemFolder`) that pinned the
old 6-column list.

Next: Swift unit tests for every operation (new file), then `Mac/docs/api/fsfolder.md`.

## Phase 5 (verification)

`Mac/Tests/SevenZipKitTests/FSFolderTests.swift` (new, 23 tests) with its own
`FSProgressStub: SZProgressDelegate` — no dependency on the `opsinfra` runner. Everything runs
against a per-test temporary tree. Covers: all columns and item properties, folders showing no
size until calculated, symlink listing (file / directory / broken, target as Link), hidden-file
filtering, packages, create folder / file (incl. collisions), rename (incl. collision and
`sub/name`), copy to a directory and to an exact path, xattr preservation, move within the
volume, "cannot move onto itself", CopyFrom + the drag & drop class method, all five overwrite
answers plus auto-rename, cancellation of an 8 MiB copy through the stub (partial destination
removed), delete to Trash and permanent delete (incl. a locked / read-only file), calc size on a
known tree (60 bytes / 2 dirs / 3 files) and its cancellation, flat mode with prefixes,
descript.ion comments, the volumes root with every column and mount path, change notification
for the current directory only, the watched directory disappearing, and a RAM-disk test for
cross-volume copy + move (EXDEV) and for the volumes folder noticing a mount and an unmount.

Two real bugs were found by the tests and fixed: `-stringByExpandingTildeInPath` silently
dropped the trailing "/" that `CopyTo` uses to distinguish "into this directory" from "to this
exact name", and a cancelled copy left a truncated destination file behind.

`Mac/scripts/build.sh` clean, `Mac/scripts/test.sh` 40/40.

---

# Final report — `fsfolder` (branch `mac/fsfolder`)

## What was implemented

The file-system folder is a full `IFolder.h` citizen. `Mac/docs/api/fsfolder.md` is the
contract for later waves (columns, operation semantics, callback contract, panel notes).

**Listing (01 §3.2, §6.4).** `CFSFolderMac` declares `FSFolder.cpp`'s `kProps` — Name, Size,
Modified, Created (`st_birthtimespec`), Accessed, Metadata Changed (`st_ctimespec`), Attributes,
Packed Size (`st_blocks * 512`), Mode, User, Group, Link, iNode, Links, Comment, Folders, Files,
and Path Prefix in flat view only (`GetNumberOfProperties` drops it otherwise, exactly like
Windows). `kpidIsDir`, `kpidIsAltStream` (always false), `kpidExtension`, `kpidSymLink`,
`kpidUserId`, `kpidGroupId` are answered as values. Directories report no Size / Packed Size /
Folders / Files until `CalcItemFullSize`. Windows attribute bits are derived from the POSIX mode
plus the BSD flags (D A R L H C O S, §9 #7), so the Attributes cell reads e.g. `A -rw-r--r--` or
`DH drwx------`. `kpidNtSecure` and alternate streams are never offered.

**Symlinks (§9 #8).** `lstat` only, so a link is listed as itself (size = target-string length);
`readlink` fills the "Link" column and `kpidSymLink`; a link to a directory still reports
`kpidIsDir` and can be entered. Bundles and packages are ordinary directories plus
`isPackage(at:)`.

**Operations (§6.4, `FSFolderCopy.cpp`).** `IFolderOperations` complete: `CopyTo` with a
precomputed byte total, per-chunk progress, `AskWrite` before every overwrite, Windows'
directory-vs-exact-path destination rule, same-volume `rename(2)` versus `EXDEV` copy + delete,
symlinks copied as links, timestamps / mode / owner / ACLs / xattrs (hence resource forks) and
user BSD flags preserved, upstream error wording; `CopyFrom` and the exported
`CopyFileSystemItems` for drag & drop; `Delete` to the Trash or permanently (clearing the
read-only bit and the immutable flags); `Rename` (with `sub/name` and a real collision error),
`CreateFolder` (complex paths), `CreateFile` (`CREATE_NEW`), `SetProperty(kpidComment)` through
`descript.ion`; `CopyFromFile` → `E_NOTIMPL` as upstream. Plus `IFolderCalcItemFullSize`,
`IFolderGetItemFullSize`, `IFolderSetFlatMode`, `IFolderClone`, `IFolderCompare`.

**Volumes root (§6.2, §6.3, §9 #5).** Root = Computer / Volumes / Home / Documents; the volumes
folder is built from `FileManager.mountedVolumeURLs` with Name, Total Size, Free Space, Type
(Fixed / Removable / Remote / CD-ROM), Label, File System, Cluster Size, the mount path
(`kpidPath`, `mountPathOfItem(at:)`) and `kpidOutName`; it implements `IFolderWasChanged` over a
`getfsstat` fingerprint, so mounts and unmounts refresh. Navigating into a volume lands in the
file-system folder of its mount point; a mount point navigates up to the volumes folder.

**Change notification (§3.17, §9 #20).** FSEvents, armed lazily on the first poll, filtered to
the watched directory itself (matched against the path and its `realpath`), recursive only in
flat view, 0.5 s coalescing, and `directoryWasRemoved` from `RootChanged` so the panel can
navigate up when the directory is deleted or renamed.

## Verified

`rm -rf Mac/build && Mac/scripts/build.sh && Mac/scripts/test.sh`: clean build, no warnings in
`Mac/` code, 40/40 tests (17 existing + 23 new). The new tests are listed in the Phase 5 note
above; the RAM-disk test really runs (3.4 s) and exercises the cross-volume `EXDEV` path and the
volumes-folder refresh on mount and unmount. No UI verification: the panel commands for these
operations land in a later wave, so no screenshots.

## Known gaps / follow-ups

- `GetSystemIconIndex` and the delete-confirmation strings (`IDS_CONFIRM_*`, `IDS_WANT_TO_DELETE_*`,
  `IDS_DELETING 6106`, `IDS_ERROR_DELETING 6107`) are panel-scope work; the bridge exposes
  `deleteToTrash` so plain Delete and Option-Delete map onto one interface.
- `IsCorrectFsName` / `CorrectFsPath` and per-volume case sensitivity
  (`volumeSupportsCaseSensitiveNames`, §9 #24) are not implemented; comparisons use the engine's
  case-insensitive `CompareFileNames`.
- Extended attributes are preserved on copy but not browsable (no `AltStreamsFolder` equivalent,
  §9 #6); quarantine propagation belongs to `extract` (§9 #23).
- Hard links are copied as independent files (as `CopyFileEx` does).
- `kpidComment` is `descript.ion` only; the Finder-comment xattr is not read (§9 #19).
- PROGRESS §2.3 (archives inside a panel) and §2.4 (temp-file open / edit) were out of scope for
  this wave and are untouched.

## Files touched outside the ownership table

- `Mac/Tests/SevenZipKitTests/SevenZipKitTests.swift`: two assertions in `testFileSystemFolder`
  pinned the old six-column list; replaced with the full column set. Nothing else in that file
  changed.
- `Mac/docs/PROGRESS.md` (§2.1 / §2.2 ticks only) and `Mac/docs/api/fsfolder.md` +
  `Mac/docs/reports/fsfolder.md`, which the orchestration file assigns to every scope.

Nothing in `C/`, `CPP/`, `Asm/`, `DOC/`, `Mac/project.yml`, `Mac/scripts/`, `Mac/App/` or
`Mac/docs/architecture.md` was modified. No new import was needed in
`Mac/Core/include/SevenZipKit.h` (both public headers were already listed).
