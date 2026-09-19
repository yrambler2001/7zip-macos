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
