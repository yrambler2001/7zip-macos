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
