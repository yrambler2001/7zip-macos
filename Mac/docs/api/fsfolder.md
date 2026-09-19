# `fsfolder` — the file-system folder and the volumes root

What `SZFileSystemFolder` and `SZRootFolder` expose after Wave 2, the exact semantics of every
operation, the callback contract the C++ side relies on, and what the `panel` scope must know.

Sources: `Mac/Core/Internal/FSFolderMac.{h,cpp}`, `RootFolderMac.{h,cpp}`,
`FSEventsWatcher.{h,cpp}`, `MacFileOps.{h,mm}`, `Mac/Core/SZFileSystemFolder.mm`,
`Mac/Core/SZRootFolder.mm`. Parity reference: `01-fm-feature-inventory.md` §3.2, §3.4, §3.11,
§3.17, §6.2, §6.3, §6.4 and the "Windows-only" table §9 (#5, #7, #8, #9, #19, #20, #24).

## 1. Interfaces

`CFSFolderMac` implements, and `QueryInterface` answers, exactly:

| Interface | Notes |
|---|---|
| `IFolderFolder` | listing, columns, navigation |
| `IFolderGetItemName` | zero-copy `GetItemName` / `GetItemPrefix` / `GetItemSize` |
| `IFolderWasChanged` | FSEvents, §3.17 |
| `IFolderOperations` | copy / move / delete / rename / mkdir / create file / comment |
| `IFolderCalcItemFullSize` | F3 on a folder |
| `IFolderGetItemFullSize` | same, as a value (calculates on demand) |
| `IFolderSetFlatMode` | recursive listing with `kpidPrefix` |
| `IFolderClone` | copies path, flat mode, `showHiddenFiles`, `deleteToTrash` |
| `IFolderCompare` | the property rules of `PanelSort.cpp` |

Not implemented (deliberately): `IFolderAltStreams` (alternate streams are hidden, §9 #6),
`IFolderGetSystemIconIndex` (icons come from `Support/Icons` in Swift), `IArchiveGetRawProps`
(the reparse buffer is exposed as a normal string column instead).

`CVolumesFolderMac` implements `IFolderFolder`, `IFolderGetItemName` and `IFolderWasChanged`.
`CRootFolderMac` implements `IFolderFolder` and `IFolderGetItemName`.

## 2. Columns and item properties (`SZFileSystemFolder`)

Declared columns, in order — this is `FSFolder.cpp`'s `kProps` with the Windows security /
reparse slots replaced by their macOS equivalents (§9 #7, #8):

| # | PROPID | Name (lang `1000 + propID`) | Value |
|---|---|---|---|
| 0 | `kpidName` 4 | Name | entry name |
| 1 | `kpidSize` 7 | Size | `st_size`; **empty for directories** until `calculateFullSize` |
| 2 | `kpidMTime` 12 | Modified | `st_mtimespec` |
| 3 | `kpidCTime` 10 | Created | `st_birthtimespec` |
| 4 | `kpidATime` 11 | Accessed | `st_atimespec` |
| 5 | `kpidChangeTime` 98 | Metadata Changed | `st_ctimespec` |
| 6 | `kpidAttrib` 9 | Attributes | Windows bits, see §3 |
| 7 | `kpidPackSize` 8 | Packed Size | physical size on disk = `st_blocks * 512`; empty for directories until calculated |
| 8 | `kpidPosixAttrib` 53 | Mode | `st_mode` |
| 9 | `kpidUser` 25 | User | `getpwuid`, resolved lazily |
| 10 | `kpidGroup` 26 | Group | `getgrgid`, resolved lazily |
| 11 | `kpidNtReparse` 89 | Link | `readlink()` target, empty for non-links |
| 12 | `kpidINode` 91 | iNode | `st_ino` |
| 13 | `kpidLinks` 37 | Links | `st_nlink` |
| 14 | `kpidComment` 28 | Comment | `descript.ion` in this folder |
| 15 | `kpidNumSubDirs` 31 | Folders | only after `calculateFullSize` |
| 16 | `kpidNumSubFiles` 32 | Files | only after `calculateFullSize` |
| 17 | `kpidPrefix` 30 | Path Prefix | **flat view only**: `GetNumberOfProperties` returns 17 instead of 18 when flat mode is off, exactly like Windows |

Additional item values that are **not** columns (answered by `GetProperty`, as on Windows):
`kpidIsDir` 6, `kpidIsAltStream` 63 (always false), `kpidExtension` 5 (the panel sorts by it),
`kpidSymLink` 54 (same string as `kpidNtReparse`), `kpidUserId` 99, `kpidGroupId` 100.

Folder properties: `kpidType` = `"FSFolder"`, `kpidPath` = the absolute prefix with a
trailing `/`.

`SZFileSystemFolder.defaultHiddenPropIDs` = `GetColumnVisible` (`PanelItems.cpp:25-51`):
`kpidATime`, `kpidChangeTime`, `kpidAttrib`, `kpidPackSize`, `kpidINode`, `kpidLinks`,
`kpidNtReparse`, plus the macOS-only `kpidPosixAttrib`, `kpidUser`, `kpidGroup`. Everything
else is visible by default; widths and default sort are the panel's business (§3.2).

`kpidNtSecure` and the alternate-stream properties are never offered, so the Properties dialog
and the column menu never show them.

## 3. The Attributes column

`kpidAttrib` is the engine's `Get_WinAttribPosix_From_PosixMode(st_mode)`
(`FILE_ATTRIBUTE_DIRECTORY` or `ARCHIVE`, `READONLY` when no write bit,
`FILE_ATTRIBUTE_UNIX_EXTENSION` and `mode << 16`) with these macOS additions, so that
`ConvertWinAttribToString` (`PropIDUtils.cpp`, chars `RHS8DAdNTsLCOIEV`) prints something real:

| Char | Bit | Set when |
|---|---|---|
| `D` | `DIRECTORY` 0x10 | `S_ISDIR` |
| `A` | `ARCHIVE` 0x20 | not a directory |
| `R` | `READONLY` 0x1 | no write bit, or `UF_IMMUTABLE` / `SF_IMMUTABLE` (Finder "Locked") |
| `L` | `REPARSE_POINT` 0x400 | `S_ISLNK` |
| `H` | `HIDDEN` 0x2 | name starts with `.`, or `UF_HIDDEN` |
| `C` | `COMPRESSED` 0x800 | `UF_COMPRESSED` (HFS+/APFS transparent compression) |
| `O` | `OFFLINE` 0x1000 | `SF_DATALESS` (iCloud / dataless placeholder) |
| `S` | `SYSTEM` 0x4 | `SF_RESTRICTED` (SIP) or `SF_NOUNLINK` |

The mode string follows after a space (`A -rw-r--r--`), as on Linux builds of 7-Zip.

## 4. Listing rules

* `folder(withPath:)` normalizes to an absolute `/`-terminated prefix and fails with
  `SZErrorCodeNotFolder` / `SZErrorCodeFileNotFound`.
* `lstat` only: symlinks are **not** followed for the listing, so Size is the length of the
  target string and the times are the link's. A symlink whose target is a directory still
  reports `kpidIsDir = true` and can be entered (Windows treats directory symlinks the same).
* Packages and bundles are ordinary directories; `isPackage(at:)` tells the panel when to show
  a document icon and to open rather than enter. Entering still works.
* `showHiddenFiles` (default from `SZFileSystemFolderShowHiddenFilesKey` = `"FM.ShowHiddenFiles"`,
  default `YES`) decides whether dotfiles and `UF_HIDDEN` entries are listed. Windows 7zFM has no
  such option — `FindFirstFile` always returns hidden files — so `YES` is the parity default; the
  key exists because "show hidden files" is a macOS expectation. Changing it needs `loadItems`.
* Flat mode (`flatMode = true` then `loadItems`) recurses into **real** directories only, never
  into symlinked ones, so it always terminates. `prefixOfItem(at:)` / `kpidPrefix` give the
  relative directory with a trailing `/`; `fullPathOfItem(at:)` includes it.
* `compareItem(at:with:propID:)` handles Name / Extension / IsDir / Size / PackSize / Attrib /
  Mode / the four timestamps / iNode / Links / UserId / GroupId / Link / Folders / Files /
  Prefix; anything else returns 0 and the panel falls back to comparing values.

## 5. Operations

All of them are synchronous and must run off the main thread. Each takes an optional
`id<SZProgressDelegate>`; the bridge wraps it in an `IFolderOperationsExtractCallback`.

### 5.1 Copy and move — `copyItems(at:toPath:move:delegate:)`

`IFolderOperations::CopyTo`, ported from `FSFolderCopy.cpp`.

* **Destination form (Windows rule):** a path ending in `/` is a destination *directory* and each
  item keeps its name; a path without a trailing `/` is the exact target path and exactly one
  index is allowed (otherwise `E_INVALIDARG`). The bridge preserves the trailing separator, so
  pass `"…/dest/"` when you mean "into this folder".
* **Progress:** the total is precomputed by a recursive walk, then `SetTotal(bytes)` and
  `SetNumFiles(n)`; `SetCompleted(bytes)` is sent for every 64 KiB chunk and once more at the end
  so the bar always ends full (a same-volume rename transfers no bytes).
* **The overwrite question** is asked through `AskWrite` before every file, and only when the
  destination exists — see §6.
* **Move:** `rename(2)` first. On the same volume that moves a file or a whole subtree at once.
  `EXDEV` falls back to copy + delete (`MOVEFILE_COPY_ALLOWED`); any other error is reported and
  aborts. Directories are removed only after their contents moved successfully.
* **Preserved:** timestamps (mtime/atime, set after the data), POSIX mode, owner where permitted,
  ACLs, all extended attributes — and therefore resource forks, which live in
  `com.apple.ResourceFork` — via `copyfile(3)` `COPYFILE_SECURITY | COPYFILE_XATTR`, then the
  user BSD flags (`UF_IMMUTABLE`, `UF_HIDDEN`, `UF_NODUMP`, `UF_APPEND`, `UF_OPAQUE`) last, so
  locking the destination cannot block the other two steps.
* **Symlinks are copied as links** (`readlink` + `symlink`), never followed, even when they point
  at a directory.
* **Errors** are sent as `ShowMessage("<text> : <path>")` and abort with `E_ABORT`, with the
  upstream wording: `"Cannot copy file onto itself"`, `"Cannot move file onto itself"`,
  `"Cannot copy folder onto itself"`, `"Cannot move folder onto itself"`, `"Cannot create folder"`,
  `"Cannot remove folder"`, `"Cannot find the file"`; anything else is the `errno` text.
* A cancelled or failed file copy removes the truncated destination.

### 5.2 Copy from outside — `copy(paths:move:delegate:)` and `SZFileSystemFolder.copy(paths:toDirectory:move:delegate:)`

The `CopyFrom` direction and `FSFolderCopy.cpp`'s exported `CopyFileSystemItems`, with exactly
the rules of §5.1. The class method is the drag & drop / paste entry point. The C++ free function
`NMacFolders::CopyFileSystemItems(paths, destDirPrefix, moveMode, callback)` is available to
other scopes that already have an `IFolderOperationsExtractCallback`.

`IFolderOperations::CopyFrom` works when the `IProgress` passed in also answers
`IID_IFolderOperationsExtractCallback`, and returns `E_NOTIMPL` otherwise.

### 5.3 Delete — `deleteItems(at:toTrash:delegate:)`

* `toTrash: true` → `NSFileManager.trashItemAtURL:` per item (the recycle-bin replacement,
  §9 #9). `toTrash: false` → permanent recursive removal, clearing the read-only bit and the
  immutable / append BSD flags first, like `DeleteFileAlways` clears `FILE_ATTRIBUTE_READONLY`.
* A symlink is unlinked, never followed.
* `IFolderOperations::Delete` follows the `deleteToTrash` property (default `YES`), so the panel
  can bind plain Delete to the Trash and Option-Delete to a permanent delete without a second
  interface.
* Progress is `SetTotal(numItems)` + `SetCompleted(i + 1)`, as in `FSFolder::Delete`.
* Errors: reported per item through `ShowMessage` and the first one is returned at the end, so a
  multi-item delete is not stopped by a single protected file. With no message sink the call
  aborts on the first error with its `errno` HRESULT, which is the Windows behaviour.

### 5.4 Rename, create folder, create file

* `renameItem(at:to:)` moves inside the folder's own prefix; `"sub/name"` moves the item into a
  sub-folder (§3.11). An existing destination fails with the `EEXIST` HRESULT
  (`renamex_np(RENAME_EXCL)`), because plain `rename(2)` would silently replace it while
  Windows' `MoveFile` fails with `ERROR_ALREADY_EXISTS`.
* `createFolder(named:)` creates complex paths (`a/b/c`) and fails when the leaf exists.
* `createFile(named:)` is `O_CREAT|O_EXCL` — fails when the name exists (`CREATE_NEW`).

### 5.5 Calculate full size — `calculateFullSize(at:delegate:)`

`IFolderCalcItemFullSize`: recursive walk storing Size, Packed Size, Folders and Files on the
item, so the three columns fill in for that row. Cancellable (the walk calls
`SetCompleted(NULL)` per directory). `IFolderGetItemFullSize` does the same and returns the size.
`sizeOfItem(at:)` (the zero-copy `GetItemSize`) keeps reporting 0 for directories, as upstream.

### 5.6 Comments — `setComment(_:forItem:)`

`SetProperty(index, kpidComment, …)` rewrites `descript.ion` in this folder with `CPairsStorage`
(`TextPairs.cpp`), like Windows (§9 #19). `nil` removes the entry. Only entries of the folder
itself, never flat-view children (`E_NOTIMPL`, as upstream).

### 5.7 Not implemented

`CopyFromFile` → `E_NOTIMPL`: file-system items are edited in place, same as Windows. The
`temp-file open / edit` flow (PROGRESS §2.4) therefore never needs it for FS folders.

## 6. Callback contract

The C++ side talks only to `IFolderOperationsExtractCallback`
(`IProgress::SetTotal/SetCompleted` + `AskWrite` / `ShowMessage` / `SetCurrentFilePath` /
`SetNumFiles`). **Any of them returning something other than `S_OK` aborts the operation**, which
surfaces as `SZErrorCodeCancelled` (`E_ABORT`); that is the only cancellation channel, so a
callback must not swallow the break.

The bridge's own adapter maps it to `SZProgressDelegate`:

| Callback | Delegate |
|---|---|
| `SetTotal(bytes)` | `progressSetTotal:` |
| `SetCompleted(bytes)` | `progressSetCompleted:` |
| `SetNumFiles(n)` | `progressSetNumFilesProcessed:` |
| `SetCurrentFilePath(src)` | `progressSetCurrentFile:isDirectory:` (always `NO`) |
| `ShowMessage(text)` | `progressShowMessage:` |
| every one of them | then `progressCheckBreak` → `E_ABORT` |

`AskWrite` copies `CExtractCallbackImp::AskWrite` (`ExtractCallback.cpp:710-807`):

1. destination does not exist → answer yes, no question asked.
2. source is a folder and the destination is a file → `"Cannot replace file with folder with same
   name"` + `E_ABORT`; destination is a folder and the source a file → `"Cannot replace folder
   with file with same name"`, item skipped.
3. otherwise `progressAskOverwriteExisting:…` with both names, times and sizes.
   `.yes` overwrite once, `.yesToAll` overwrite for the rest of the operation, `.no` skip once,
   `.noToAll` skip the rest, `.autoRename` rename this and every later collision
   (`AutoRenamePath`, i.e. `name_2.ext`; a non-nil `suggestedName` is used as the base),
   `.cancel` → `E_ABORT`.
4. A skipped file's size is subtracted from the total and `SetTotal` is re-sent, so the
   percentage stays right.
5. With **no delegate** the adapter answers "overwrite" and never breaks.

Progress callbacks arrive on the thread that called the operation (the bridge does not create
threads); a delegate shared with the UI must marshal to the main thread itself.

## 7. Change notification

* `wasChanged` is `IFolderWasChanged`. The FSEvents stream is started lazily on the **first**
  poll, so the first call always returns `NO` — arm it right after binding.
* Non-recursive by default: an event only counts when its path is the watched directory itself
  (compared against the path and its `realpath`, because FSEvents reports canonical paths such as
  `/private/var/...`). In flat view the watcher is recursive, because the listing is.
  `kFSEventStreamEventFlagMustScanSubDirs`, dropped-event flags and mount/unmount always count.
* Bursts are coalesced by a 0.5 s latency into one flag, and the flag is consumed by the poll —
  cheap enough for the panel's one-second refresh timer.
* `directoryWasRemoved` (sticky, from `kFSEventStreamEventFlagRootChanged`) means the watched
  directory was deleted, renamed or moved: **the panel should navigate up** rather than reload.
  A rename keeps the stream alive on the same inode, so a reload after a rename still works.

## 8. The root and the volumes folder (`SZRootFolder`)

* `makeRootFolder()` — type `"RootFolder"`, `kpidPath` = `""`, one column (`kpidName`), four
  items: **Computer** (`IDS_COMPUTER 7100`) → `/`, **Volumes** → the volumes folder, **Home** →
  `$HOME`, **Documents** (`IDS_DOCUMENTS 7102`) → `~/Documents`. Windows' Network item is
  dropped (§9 #5). `BindToParentFolder` returns nothing (the bridge hands back a fresh root).
* `bindToFolder(named:)` resolves any typed path: an entry name, `Computer` / `My Computer`,
  `Documents` / `My Documents`, `~`, `~/x`, or an absolute path.
* `makeVolumesFolder()` — type `"FSDrives"` (kept so column layouts persist under the same key).
  One item per `FileManager.mountedVolumeURLs` entry, skipping the volumes the Finder hides.
  Columns: Name, Total Size, Free Space, Type, Label, File System, Cluster Size. Item values:
  `kpidPath` = the mount point with a trailing `/` (also `mountPathOfItem(at:)`), `kpidOutName`
  (the name to use when copying the volume out), `kpidIsDir` = true.
  `Type` is one of `Fixed` / `Removable` / `Remote` / `CD-ROM` from the volume resource keys plus
  the file-system name — the subset of Windows' `kDriveTypes` that macOS can tell apart.
  Total / Free come from `URLResourceValues`, File System and Cluster Size from `statfs`.
* Navigating into a volume returns the `SZFileSystemFolder` of its mount point;
  `bindToParentFolder` returns the root folder.
* The volumes folder implements `IFolderWasChanged` over a `getfsstat` fingerprint, so
  `wasChanged` is `YES` when a volume is mounted or unmounted; `loadItems` refreshes.
* Physical-drive imaging (`\\.\PhysicalDriveN`, `CopyTo` to `<drive>.<fs>`) is **not** exposed
  (§9 #5); the volumes folder offers no `IFolderOperations` at all.
* A file-system folder that is a **mount point** (its `st_dev` differs from its parent's) goes up
  to the volumes folder, the way a Windows drive root goes up to Computer. `/` is the exception:
  it goes up to the root folder, which is where the "As built" panel expects to land.

## 9. Deliberate differences from Windows

1. **Symlinks are copied as links**, including directory symlinks; Windows recurses into a
   directory reparse point and copies the contents.
2. **`Delete` honours `deleteToTrash`.** Windows' `IFolderOperations::Delete` is always
   permanent and 7zFM calls `SHFileOperation(FOF_ALLOWUNDO)` itself for the recycle bin; the
   Cocoa Trash API is per item, so it belongs in the folder.
3. **A multi-item delete continues past a failing item** when a message sink exists (all errors
   are reported, the first is returned). Windows aborts on the first error.
4. **`Rename` refuses an existing destination** (`RENAME_EXCL`). Upstream relies on `MoveFile`
   failing; POSIX `rename(2)` would replace silently, which would lose data.
5. **`CopyFrom` is implemented** when the progress object is also the copy callback; upstream
   returns `E_NOTIMPL` unconditionally and the FM calls `CopyFileSystemItems` directly.
6. **`kpidCTime` is the birth time**, not `st_ctime`; `st_ctime` is the separate "Metadata
   Changed" column. The engine's own `SetFrom_stat` keeps `st_ctime` in `CTime` for archive
   compatibility, which would have shown the wrong value in a "Created" column.
7. **`kpidPackSize` is `st_blocks * 512`** (real allocated size). Windows falls back to
   `Size` when `GetCompressedFileSize` fails, and upstream leaves the call commented out in
   `LoadSubItems`.
8. **`kpidNtReparse` is a normal string column**, not a raw property: on macOS the "reparse data"
   is just the `readlink` target, so there is nothing to hex-dump. `kpidSymLink` returns the same
   string.
9. **`kpidPosixAttrib`, `kpidUser`, `kpidGroup` are extra columns** (hidden by default) in place
   of the Windows security columns (§9 #7).
10. **`"Cannot copy/move folder onto itself"` is not swapped.** `FSFolderCopy.cpp:577-580` prints
    the *copy* message in move mode and vice versa; we print the matching one.
11. **Alternate streams** have no folder: `IFolderAltStreams` is absent and `kpidIsAltStream` is
    always false (§9 #6 is a later, optional "extended attributes folder").

## 10. Known gaps

* Extended attributes are preserved on copy but not browsable (no `AltStreamsFolder`
  equivalent); `com.apple.quarantine` propagation is the `extract` scope's business (§9 #23).
* `IFolderGetSystemIconIndex` is not implemented: the panel uses `Support/Icons`.
* No hard-link detection on copy: two hard links to one inode become two independent files
  (Windows behaves the same for `CopyFileEx`).
* `kpidComment` is `descript.ion` only; the Finder comment xattr is not read (§9 #19 leaves the
  choice open).
* Case sensitivity: comparisons use the engine's case-insensitive `CompareFileNames`, not the
  per-volume `volumeSupportsCaseSensitiveNames` flag (§9 #24). This only matters for the
  "onto itself" checks on a case-sensitive volume, where it is conservative.
