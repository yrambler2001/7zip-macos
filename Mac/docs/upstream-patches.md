# Upstream patches applied for the macOS port

Every edit to `C/`, `CPP/`, `Asm/` is listed here. All hunks are pure `#ifdef _WIN32` /
`#ifndef _WIN32` splits or Windows-typedef fixes; Windows behaviour is unchanged. The exact
unified diff is `Mac/docs/upstream-patches.diff` (copied verbatim from
`02-engine-api.md` §4.2 and applied with `git apply`).

| File | Hunk | Reason |
|---|---|---|
| `CPP/7zip/UI/Agent/Agent.h` | `#define INVALID_FILE_ATTRIBUTES ((DWORD)-1)` fallback after the includes | the constant only exists in `C/7zWindows.h`; `CAgent::Is_Attrib_ReadOnly()` compares against it |
| `CPP/7zip/UI/Agent/Agent.h` | `struct CCodecIcons` and the `CodecIconsVector`/`InternalIcons` members of `CArchiveFolderManager` wrapped in `#ifdef _WIN32` | icon tables are read from a Win32 string-table resource; meaningless on macOS |
| `CPP/7zip/UI/Agent/Agent.cpp` | `IsAltStreamPrefixWithColon` test in the update path wrapped in `#ifdef _WIN32` | declared only for `_WIN32` in `Windows/FileName.h` |
| `CPP/7zip/UI/Agent/Agent.cpp` | `_attrib`/`_isDeviceFile` filled from `fi.GetWinAttrib()` / `S_ISCHR||S_ISBLK` on POSIX; `arc.MTime.Def = !_isDeviceFile` | POSIX `CFileInfoBase` has `mode` instead of `Attrib`/`IsDevice` |
| `CPP/7zip/UI/Agent/AgentOut.cpp` | `IsAltStreamPrefixWithColon` guard in `SetFiles`; updating into an alt-stream folder returns `E_NOTIMPL` on POSIX | `CDirItem::IsAltStream` is Windows-only |
| `CPP/7zip/UI/Agent/AgentOut.cpp` | `CreateFolder`: `di.SetAsDir()` instead of `di.Attrib = FILE_ATTRIBUTE_DIRECTORY`; `CFiTime` + `GetCurUtc_FiTime` | portable spellings (identical on Windows) |
| `CPP/7zip/UI/Agent/ArchiveFolderOut.cpp` | `enumerator.DirEntry_IsDir(fileInfo, false)` on POSIX; `SetFileAttrib(path, 0)` before `RemoveDir` only on Windows | POSIX `CDirEntry` has no `IsDir()`; read-only attribute clearing is a Windows need |
| `CPP/7zip/UI/Agent/UpdateCallbackAgent.cpp` | `UINT64` -> `UInt64` in `SetTotal`/`SetCompleted` | `UINT64` is a Windows SDK typedef; the declaration already uses `UInt64` |
| `CPP/7zip/UI/Agent/ArchiveFolderOpen.cpp` | icon code (`ResourceString.h`, `g_hInstance`, `CCodecIcons::LoadIcons`, `AddIconExt`, `GetIconPath` body) wrapped in `#ifdef _WIN32`; `GetExtensions` enumerates `g_CodecsObj->Formats[i].Exts` on non-Windows | same information from the format table without Win32 resources; `GetIconPath` returns `S_OK` with no path |
| `CPP/7zip/UI/FileManager/SplitUtils.h/.cpp` | `AddVolumeItems(NControl::CComboBox&)` and `k_Sizes[]` wrapped in `#ifdef _WIN32` | Win32 combo box; `ParseVolumeSizes`/`GetNumberOfVolumes` stay portable |
| `CPP/7zip/UI/Common/LoadCodecs.cpp` | `item.TimeFlags = arc.TimeFlags;` added to the static `CCodecs::Load()` loop under `#ifdef __APPLE__` | the static registration path (no `Z7_EXTERNAL_CODECS`) never copies `CArcInfo::TimeFlags`, so `Get_TimePrecFlags()` and `Get_DefaultTimePrec()` are 0 and the Compress Options timestamp-precision combo is empty. The DLL path reads the same value from `NHandlerPropID::kTimeFlags`; Windows builds use the DLL path and are unaffected. |
| `CPP/7zip/UI/Common/ArchiveExtractCallback.h/.cpp`, `CPP/7zip/UI/Common/Extract.cpp`, `CPP/7zip/UI/Agent/Agent.cpp` | the five Zone.Identifier guards `defined(_WIN32) && !defined(UNDER_CE)` widened to `|| defined(__APPLE__)`; `ReadZoneFile_Of_BaseFile` / `WriteZoneFile_To_BaseFile` get an `#ifdef __APPLE__` body that reads / writes the `com.apple.quarantine` extended attribute instead of the `:Zone.Identifier` stream (`<sys/xattr.h>` included under `__APPLE__`) | quarantine propagation on ordinary extraction (`-snz`, Options "Propagate Zone.Id stream", `01 §9 #23`; `mac/opsgaps`). Only the engine knows each extracted file's disk path at `CloseFile` time, so the kAll / kOffice policy (upstream's `kOfficeExtensions`) can only be applied there; post-processing from the bridge would have to guess which files the run wrote. Windows preprocesses exactly as before. |
| `CPP/Windows/ResourceString.h` | `MyLoadString(HINSTANCE, UINT, UString&)` overload wrapped in `#ifdef _WIN32` | no Win32 module handle on macOS; the `UINT` overloads are implemented by `Mac/Core/Platform/SevenZipCoreMac.cpp` |

Nothing else in `C/`, `CPP/`, `Asm/`, `DOC/` is modified. To verify: `git diff macos -- C CPP Asm DOC`.
