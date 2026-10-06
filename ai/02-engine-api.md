# 02 — 7-Zip engine API surface for the macOS app

Repository: `~/things/a.noindex/7zip` (7-Zip 26.03, branch `macos`).
All paths below are relative to the repository root unless absolute. `file:line` references
were taken from the tree at the time of writing (26.03 sources, `C/7zVersion.h:1-13`:
`MY_VER_MAJOR 26`, `MY_VER_MINOR 3`, `MY_DATE "2026-09-03"`).

How this document was produced (nothing in the tree was modified):

1. The stock macOS build (`make -f ../../cmpl_mac_arm64.mak` from `CPP/7zip/Bundles/Alone2`)
   was dry-run (`make -n`) and then really built into a scratch directory with
   `DEVELOPER_DIR=/Applications/Xcode.app` (Xcode 26.6, Apple clang 21.0.0, arm64). It builds
   clean with the stock `-Werror -Weverything` flags: 323 translation units, a 2.99 MB `7zz`,
   `7zz i` reports `7-Zip (z) 26.03 (arm64) ... ASM`.
2. Every `.cpp` in `CPP/7zip/UI/Agent`, `CPP/7zip/UI/Common`, `CPP/7zip/UI/FileManager`,
   `CPP/7zip/UI/GUI`, `CPP/7zip/UI/Explorer`, `CPP/7zip/UI/Console`, `CPP/Common`,
   `CPP/Windows` and `CPP/Windows/Control` (199 files) was compiled twice with the exact 7zz
   flags: once "strict" (the stock `-Werror -Wall -Wextra -Weverything -Wfatal-errors ...`
   line) and once "lax" (`-w`, so that every real error is listed, not only the first).
   Section 3 is the result.
3. The Agent (`CPP/7zip/UI/Agent/*`) was patched in an overlay copy (section 4.2 has the
   unified diff), compiled with the strict flags, linked against the 7zz objects minus the
   console objects, and a smoke program opened a `.7z`, listed it through `IFolderFolder`,
   extracted it through `IInFolderArchive::Extract`, ran a test-mode extract through
   `IArchiveFolder::Extract`, created a folder inside the archive through
   `IFolderOperations::CreateFolder` (temp file -> move -> `ReOpen`) and listed it again. All
   steps returned `S_OK`. The recipe is in Appendix A.

Table of contents

1. How 7zz is built on macOS today (make chain, flags, exact source list)
2. Engine interfaces the GUI needs (types, IFolder, Agent, UI/Common, Windows/, callback protocols)
3. Portability audit (per-file classification with compile evidence)
4. Recommendation (SevenZipCore source list, upstream patches, bridge seams, threading, codecs, errors, strings)
5. Console app as a behavioural reference (password, overwrite, progress, error summaries, exit codes)
Appendix A. Smoke-test recipe. Appendix B. Scratch artifacts.

---

## 1. How 7zz is built on macOS today

### 1.1 The make chain

`DOC/readme.txt:162-163` documents the macOS command:

```
cd CPP/7zip/Bundles/Alone2
make -j -f ../../cmpl_mac_arm64.mak
```

The include chain (every file is tiny except `7zip_gcc.mak`):

| File | What it contributes |
|---|---|
| `CPP/7zip/cmpl_mac_arm64.mak:1-3` | `include ../../var_mac_arm64.mak`, `include ../../warn_clang_mac.mak`, `include makefile.gcc` |
| `CPP/7zip/var_mac_arm64.mak:1-13` | `PLATFORM=arm64`, `O=b/m_arm64`, `IS_ARM64=1`, `IS_X64=`/`IS_X86=` empty, `MY_ARCH=-arch arm64` (the `-march=armv8-a` line is overridden by the next assignment), `USE_ASM=1`, `CC=clang`, `CXX=clang++`, `USE_CLANG=1` |
| `CPP/7zip/warn_clang_mac.mak:1-9` | `CFLAGS_WARN = -Weverything -Wfatal-errors -Wno-poison-system-directories`; `CXX_STD_FLAGS` is assigned several times, the last assignment (`-std=c++11`, line 9) wins |
| `CPP/7zip/Bundles/Alone2/makefile.gcc:1-108` | `PROG = 7zz`, `CONSOLE_VARIANT_FLAGS=-DZ7_PROG_VARIANT_Z` (line 3), `include ../Format7zF/Arc_gcc.mak` (line 9), `SYS_OBJS = $O/MyWindows.o` on non-MinGW (lines 37-39), `LOCAL_FLAGS = $(LOCAL_FLAGS_SYS) $(LOCAL_FLAGS_ST)` (both empty on macOS, lines 43-45), then `UI_COMMON_OBJS` (48-68), `CONSOLE_OBJS` (70-81), `COMMON_OBJS_2` (83-87), `WIN_OBJS_2` (89-92), `7ZIP_COMMON_OBJS_2` (94-97), `OBJS` (99-106), `include ../../7zip_gcc.mak` (108) |
| `CPP/7zip/Bundles/Format7zF/Arc_gcc.mak` | `include ../../LzmaDec_gcc.mak`; `ST_MODE` -> `LOCAL_FLAGS_ST = -DZ7_ST` (not set for 7zz), `MT_OBJS` (LzFindMt, LzFindOpt, Threads, MemBlocks, OutMemStream, ProgressMt, StreamBinder, Synchronization, VirtThread), `COMMON_OBJS`, `WIN_OBJS`, `7ZIP_COMMON_OBJS`, `AR_OBJS`, `AR_COMMON_OBJS`, `7Z_OBJS`, `CAB_OBJS`, `CHM_OBJS`, `ISO_OBJS`, `NSIS_OBJS`, `RAR_OBJS` (unless `DISABLE_RAR`), `TAR_OBJS`, `UDF_OBJS`, `WIM_OBJS`, `ZIP_OBJS`, `COMPRESS_OBJS` (+ Rar decoders unless `DISABLE_RAR_COMPRESS`), `CRYPTO_OBJS` (+ Rar crypto unless `DISABLE_RAR`), `C_OBJS`, `ARC_OBJS` = all of the above |
| `CPP/7zip/LzmaDec_gcc.mak` | `USE_ASM` + `IS_ARM64` -> `USE_LZMA_DEC_ASM=1` -> `LZMA_DEC_OPT_OBJS = $O/LzmaDecOpt.o` |
| `CPP/7zip/7zip_gcc.mak` | the generic rules: `CFLAGS_WARN_WALL = -Werror -Wall -Wextra` (27), `FLAGS_BASE =` empty (35), `CFLAGS_BASE_LIST = -c` (38), `CFLAGS_DEBUG = -DNDEBUG` (46), `CFLAGS_BASE = -O2 -c -Werror -Wall -Wextra $(CFLAGS_WARN) -DNDEBUG -D_REENTRANT -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -fPIC` (53-55), `FLAGS_FLTO = $(FLAGS_BASE)` = empty (59), `LIB2 = -lpthread -ldl` (165, last assignment wins), `CFLAGS` (172), `CONSOLE_ASM_FLAGS=-DZ7_7ZIP_ASM` when `USE_ASM` (203-207), `CXXFLAGS` (213), `LFLAGS_ALL` (254), link rule (260-261), per-file rules (283-1352) |
| `CPP/7zip/Asm.mak` | nmake-only (Windows); on macOS the `.S` rule lives in `7zip_gcc.mak:1331-1334` |

`CPP/7zip/var_mac_x64.mak` is the Intel variant: `PLATFORM=x64`, `IS_X64=1`, `MY_ARCH=-arch x86_64`, **`USE_ASM=` empty** (no asmc/uasm on macOS), so the x86_64 build uses the C fallbacks for everything and gets neither `LzmaDecOpt` nor `-DZ7_7ZIP_ASM`.

### 1.2 Effective command lines (captured from `make -n`)

Every C++ file (267 of them) is compiled with exactly:

```
clang++ -arch arm64 -O2 -c -Werror -Wall -Wextra -Weverything -Wfatal-errors \
  -Wno-poison-system-directories -DNDEBUG -D_REENTRANT -D_FILE_OFFSET_BITS=64 \
  -D_LARGEFILE_SOURCE -fPIC -std=c++11 -o $O/<name>.o <source>
```

Every C file (52 of them) with:

```
clang -arch arm64 -O2 -c -Werror -Wall -Wextra -Weverything -Wfatal-errors \
  -Wno-poison-system-directories -DNDEBUG -D_REENTRANT -D_FILE_OFFSET_BITS=64 \
  -D_LARGEFILE_SOURCE -fPIC -o $O/<name>.o <source>
```

Per-file specials (these are the only deviations in the whole build):

| Source | Extra flags | Rule |
|---|---|---|
| `C/LzmaDec.c` | `-DZ7_LZMA_DEC_OPT` (use the asm inner loop) | `7zip_gcc.mak:1336-1337` |
| `Asm/arm64/LzmaDecOpt.S` (includes `Asm/arm64/7zAsm.S`) | compiled with the **C** driver `clang` and the C flags above; `$(ASM_FLAGS)` is empty on macOS (`-Wno-unused-macros` is only set in `var_clang_arm64.mak:16`) | `7zip_gcc.mak:1331-1334` |
| `CPP/7zip/UI/Console/Main.cpp` | `-DZ7_PROG_VARIANT_Z -DZ7_7ZIP_ASM` (only affects the `7zz i`/copyright banner) | `7zip_gcc.mak:963-964` |
| `CPP/7zip/Archive/Zip/ZipHandler.cpp` | `$(ZIP_FLAGS)` (empty) | `7zip_gcc.mak:698-699` |

Not present in the macOS 7zz build (worth stating explicitly because the question comes up):

* No `-DZ7_ST` anywhere (`grep Z7_ST make-n.log` -> 0). `ST_MODE=1` would add `-DZ7_ST` to *every* TU and drop the `MT_OBJS` list; 7zz is multithreaded.
* No `-DZ7_EXTERNAL_CODECS`, no `-DZ7_LARGE_PAGES`, no `-DZ7_LONG_PATH`, no `-DZ7_DEVICE_FILE` (that one is MinGW-only, `Alone2/makefile.gcc:21-24`), no `-DUNICODE`/`-D_UNICODE` (so `CSysString = AString`, `FString = AString`).
* No `-I` include paths at all. Every `#include` in the tree is a relative path (`"../../../Common/MyString.h"`), so an Xcode target needs **no** `HEADER_SEARCH_PATHS` for the engine itself. (Only a foreign file that includes an engine header from outside the tree needs an `-I`; see Appendix A for the trick used by the smoke test.)
* No precompiled header: every `.cpp` includes its directory's `StdAfx.h`, which is just `#include "../../../Common/Common.h"` (e.g. `CPP/7zip/UI/Agent/StdAfx.h:1-11`).
* `-fPIC` is on; there is no `-fvisibility` flag.

Link (from `7zip_gcc.mak:254,260-261`):

```
clang++ -o $O/7zz -arch arm64 -DNDEBUG <all 323 objects> -lpthread -ldl
```

(`LFLAGS_STRIP` is empty for clang, `LDFLAGS = $(LDFLAGS_STATIC) = -DNDEBUG`, `LFLAGS_NOEXECSTACK` evaluates to empty on macOS because the `-z noexecstack` probe at `7zip_gcc.mak:248` fails.)

### 1.3 Mapping to an Xcode static-library target

* Use the C++ list of 1.4 verbatim; set `CLANG_CXX_LANGUAGE_STANDARD = c++11` (or newer; the sources compile as C++17 too, the makefile simply pins c++11), `GCC_PREPROCESSOR_DEFINITIONS = NDEBUG _REENTRANT _FILE_OFFSET_BITS=64 _LARGEFILE_SOURCE` (`_FILE_OFFSET_BITS`/`_LARGEFILE_SOURCE` are no-ops on Darwin but harmless), `GCC_OPTIMIZATION_LEVEL = 2`.
* Per-file flags: `C/LzmaDec.c` -> `-DZ7_LZMA_DEC_OPT` **only for the arm64 slice**; `Asm/arm64/LzmaDecOpt.S` -> arm64 slice only (Xcode compiles `.S` through clang with the C flags, which is exactly what the makefile does). For a universal binary, the x86_64 slice must compile `C/LzmaDec.c` without the define and must not include the `.S` (mirror `var_mac_x64.mak`: `USE_ASM=`). Xcode: `OTHER_CFLAGS[arch=arm64] = -DZ7_LZMA_DEC_OPT` on that one file, and `EXCLUDED_SOURCE_FILE_NAMES[arch=x86_64] = LzmaDecOpt.S`.
* Do **not** carry `-Weverything -Werror` into Xcode: a newer clang in a future Xcode will add warnings and break the build. `-Wall -Wextra` is what upstream considers mandatory (`CFLAGS_WARN_WALL`). The tree is clean under Xcode 26.6 today.
* `-fPIC` is irrelevant for a static library linked into an app; keep it or drop it.
* The engine must be linked with `-lpthread -ldl` (system libs; both are in libSystem on macOS, so no explicit framework is needed in Xcode).
* `C/Threads.h:16-19` defines `Z7_AFFINITY_SUPPORTED` only when `!__APPLE__`, so all CPU-affinity code paths are compiled out on macOS automatically (`CPP/Windows/System.h:168-196` has the non-affinity `CProcessAffinity`).

### 1.4 Exact source list of 7zz on macOS arm64 (323 translation units)

Group headers correspond to the makefile variables. Paths are repository-relative. Unless
noted, the flags are the generic ones of 1.2.

**Assembly (1) — `LZMA_DEC_OPT_OBJS`, arm64 only**

```
Asm/arm64/LzmaDecOpt.S          (compiled with `clang`; includes Asm/arm64/7zAsm.S)
```

**C (53) — `C_OBJS` + `MT_OBJS` C parts + the arch-dependent C fallbacks**

```
C/7zBuf2.c        C/7zCrc.c         C/7zCrcOpt.c      C/7zStream.c      C/Aes.c
C/AesOpt.c        C/Alloc.c         C/Bcj2.c          C/Bcj2Enc.c       C/Blake2s.c
C/Bra.c           C/Bra86.c         C/BraIA64.c       C/BwtSort.c       C/CpuArch.c
C/Delta.c         C/HuffEnc.c       C/LzFind.c        C/LzFindMt.c      C/LzFindOpt.c
C/Lzma2Dec.c      C/Lzma2DecMt.c    C/Lzma2Enc.c      C/LzmaDec.c (+ -DZ7_LZMA_DEC_OPT)
C/LzmaEnc.c       C/Md5.c           C/MtCoder.c       C/MtDec.c         C/Ppmd7.c
C/Ppmd7Dec.c      C/Ppmd7Enc.c      C/Ppmd7aDec.c     C/Ppmd8.c         C/Ppmd8Dec.c
C/Ppmd8Enc.c      C/Sha1.c          C/Sha1Opt.c       C/Sha256.c        C/Sha256Opt.c
C/Sha3.c          C/Sha512.c        C/Sha512Opt.c     C/Sort.c          C/SwapBytes.c
C/Threads.c       C/Xxh64.c         C/Xz.c            C/XzCrc64.c       C/XzCrc64Opt.c
C/XzDec.c         C/XzEnc.c         C/XzIn.c          C/ZstdDec.c
```

Notes: `7zCrcOpt.c`, `AesOpt.c`, `Sha1Opt.c`, `Sha256Opt.c`, `Sort.c`, `XzCrc64Opt.c`,
`LzFindOpt.c` are the C fallbacks that the x86 builds replace with `Asm/x86/*.asm`
(`7zip_gcc.mak:1277-1322`); on arm64 they are always the C files (they contain the NEON /
ARMv8 crypto intrinsic paths selected at run time via `CpuArch.c`).

**C++ — `CPP/Common` (30) — `COMMON_OBJS` + `COMMON_OBJS_2` + `SYS_OBJS`**

```
CPP/Common/CRC.cpp                CPP/Common/CommandLineParser.cpp   CPP/Common/CrcReg.cpp
CPP/Common/DynLimBuf.cpp          CPP/Common/IntToString.cpp         CPP/Common/ListFileUtils.cpp
CPP/Common/LzFindPrepare.cpp      CPP/Common/Md5Reg.cpp              CPP/Common/MyMap.cpp
CPP/Common/MyString.cpp           CPP/Common/MyVector.cpp            CPP/Common/MyWindows.cpp
CPP/Common/MyXml.cpp              CPP/Common/NewHandler.cpp          CPP/Common/Sha1Prepare.cpp
CPP/Common/Sha1Reg.cpp            CPP/Common/Sha256Prepare.cpp       CPP/Common/Sha256Reg.cpp
CPP/Common/Sha3Reg.cpp            CPP/Common/Sha512Prepare.cpp       CPP/Common/Sha512Reg.cpp
CPP/Common/StdInStream.cpp        CPP/Common/StdOutStream.cpp        CPP/Common/StringConvert.cpp
CPP/Common/StringToInt.cpp        CPP/Common/UTFConvert.cpp          CPP/Common/Wildcard.cpp
CPP/Common/Xxh64Reg.cpp           CPP/Common/XzCrc64Init.cpp         CPP/Common/XzCrc64Reg.cpp
```

**C++ — `CPP/Windows` (13) — `WIN_OBJS` + `WIN_OBJS_2` + `Synchronization` from `MT_OBJS`**

```
CPP/Windows/ErrorMsg.cpp     CPP/Windows/FileDir.cpp     CPP/Windows/FileFind.cpp
CPP/Windows/FileIO.cpp       CPP/Windows/FileLink.cpp    CPP/Windows/FileName.cpp
CPP/Windows/PropVariant.cpp  CPP/Windows/PropVariantConv.cpp  CPP/Windows/PropVariantUtils.cpp
CPP/Windows/Synchronization.cpp  CPP/Windows/System.cpp  CPP/Windows/SystemInfo.cpp
CPP/Windows/TimeUtils.cpp
```

**C++ — `CPP/7zip/Common` (24) — `7ZIP_COMMON_OBJS` + `7ZIP_COMMON_OBJS_2` + MT parts**

```
CPP/7zip/Common/CWrappers.cpp        CPP/7zip/Common/CreateCoder.cpp     CPP/7zip/Common/FilePathAutoRename.cpp
CPP/7zip/Common/FileStreams.cpp      CPP/7zip/Common/FilterCoder.cpp     CPP/7zip/Common/InBuffer.cpp
CPP/7zip/Common/InOutTempBuffer.cpp  CPP/7zip/Common/LimitedStreams.cpp  CPP/7zip/Common/LockedStream.cpp
CPP/7zip/Common/MemBlocks.cpp        CPP/7zip/Common/MethodId.cpp        CPP/7zip/Common/MethodProps.cpp
CPP/7zip/Common/MultiOutStream.cpp   CPP/7zip/Common/OffsetStream.cpp    CPP/7zip/Common/OutBuffer.cpp
CPP/7zip/Common/OutMemStream.cpp     CPP/7zip/Common/ProgressMt.cpp      CPP/7zip/Common/ProgressUtils.cpp
CPP/7zip/Common/PropId.cpp           CPP/7zip/Common/StreamBinder.cpp    CPP/7zip/Common/StreamObjects.cpp
CPP/7zip/Common/StreamUtils.cpp      CPP/7zip/Common/UniqBlocks.cpp      CPP/7zip/Common/VirtThread.cpp
```

**C++ — `CPP/7zip/Archive` (107) — `AR_OBJS`, `AR_COMMON_OBJS`, `7Z_OBJS`, `CAB/CHM/ISO/NSIS/RAR/TAR/UDF/WIM/ZIP_OBJS`**

```
CPP/7zip/Archive/ApfsHandler.cpp    CPP/7zip/Archive/ApmHandler.cpp     CPP/7zip/Archive/ArHandler.cpp
CPP/7zip/Archive/ArjHandler.cpp     CPP/7zip/Archive/Base64Handler.cpp  CPP/7zip/Archive/Bz2Handler.cpp
CPP/7zip/Archive/ComHandler.cpp     CPP/7zip/Archive/CpioHandler.cpp    CPP/7zip/Archive/CramfsHandler.cpp
CPP/7zip/Archive/DeflateProps.cpp   CPP/7zip/Archive/DmgHandler.cpp     CPP/7zip/Archive/ElfHandler.cpp
CPP/7zip/Archive/ExtHandler.cpp     CPP/7zip/Archive/FatHandler.cpp     CPP/7zip/Archive/FlvHandler.cpp
CPP/7zip/Archive/GptHandler.cpp     CPP/7zip/Archive/GzHandler.cpp      CPP/7zip/Archive/HandlerCont.cpp
CPP/7zip/Archive/HfsHandler.cpp     CPP/7zip/Archive/IhexHandler.cpp    CPP/7zip/Archive/LpHandler.cpp
CPP/7zip/Archive/LzhHandler.cpp     CPP/7zip/Archive/LzmaHandler.cpp    CPP/7zip/Archive/MachoHandler.cpp
CPP/7zip/Archive/MbrHandler.cpp     CPP/7zip/Archive/MslzHandler.cpp    CPP/7zip/Archive/MubHandler.cpp
CPP/7zip/Archive/NtfsHandler.cpp    CPP/7zip/Archive/PeHandler.cpp      CPP/7zip/Archive/PpmdHandler.cpp
CPP/7zip/Archive/QcowHandler.cpp    CPP/7zip/Archive/RpmHandler.cpp     CPP/7zip/Archive/SparseHandler.cpp
CPP/7zip/Archive/SplitHandler.cpp   CPP/7zip/Archive/SquashfsHandler.cpp CPP/7zip/Archive/SwfHandler.cpp
CPP/7zip/Archive/UefiHandler.cpp    CPP/7zip/Archive/VdiHandler.cpp     CPP/7zip/Archive/VhdHandler.cpp
CPP/7zip/Archive/VhdxHandler.cpp    CPP/7zip/Archive/VmdkHandler.cpp    CPP/7zip/Archive/XarHandler.cpp
CPP/7zip/Archive/XzHandler.cpp      CPP/7zip/Archive/ZHandler.cpp       CPP/7zip/Archive/ZstdHandler.cpp
(not built: AvbHandler.cpp, LvmHandler.cpp — commented out in Arc_gcc.mak)

CPP/7zip/Archive/Common/CoderMixer2.cpp     CPP/7zip/Archive/Common/DummyOutStream.cpp
CPP/7zip/Archive/Common/FindSignature.cpp   CPP/7zip/Archive/Common/HandlerOut.cpp
CPP/7zip/Archive/Common/InStreamWithCRC.cpp CPP/7zip/Archive/Common/ItemNameUtils.cpp
CPP/7zip/Archive/Common/MultiStream.cpp     CPP/7zip/Archive/Common/OutStreamWithCRC.cpp
CPP/7zip/Archive/Common/OutStreamWithSha1.cpp CPP/7zip/Archive/Common/ParseProperties.cpp

CPP/7zip/Archive/7z/7zCompressionMode.cpp   CPP/7zip/Archive/7z/7zDecode.cpp    CPP/7zip/Archive/7z/7zEncode.cpp
CPP/7zip/Archive/7z/7zExtract.cpp           CPP/7zip/Archive/7z/7zFolderInStream.cpp CPP/7zip/Archive/7z/7zHandler.cpp
CPP/7zip/Archive/7z/7zHandlerOut.cpp        CPP/7zip/Archive/7z/7zHeader.cpp    CPP/7zip/Archive/7z/7zIn.cpp
CPP/7zip/Archive/7z/7zOut.cpp               CPP/7zip/Archive/7z/7zProperties.cpp CPP/7zip/Archive/7z/7zRegister.cpp
CPP/7zip/Archive/7z/7zSpecStream.cpp        CPP/7zip/Archive/7z/7zUpdate.cpp

CPP/7zip/Archive/Cab/CabBlockInStream.cpp   CPP/7zip/Archive/Cab/CabHandler.cpp CPP/7zip/Archive/Cab/CabHeader.cpp
CPP/7zip/Archive/Cab/CabIn.cpp              CPP/7zip/Archive/Cab/CabRegister.cpp
CPP/7zip/Archive/Chm/ChmHandler.cpp         CPP/7zip/Archive/Chm/ChmIn.cpp
CPP/7zip/Archive/Iso/IsoHandler.cpp         CPP/7zip/Archive/Iso/IsoHeader.cpp  CPP/7zip/Archive/Iso/IsoIn.cpp
CPP/7zip/Archive/Iso/IsoRegister.cpp
CPP/7zip/Archive/Nsis/NsisDecode.cpp        CPP/7zip/Archive/Nsis/NsisHandler.cpp CPP/7zip/Archive/Nsis/NsisIn.cpp
CPP/7zip/Archive/Nsis/NsisRegister.cpp
CPP/7zip/Archive/Rar/Rar5Handler.cpp        CPP/7zip/Archive/Rar/RarHandler.cpp
CPP/7zip/Archive/Tar/TarHandler.cpp         CPP/7zip/Archive/Tar/TarHandlerOut.cpp CPP/7zip/Archive/Tar/TarHeader.cpp
CPP/7zip/Archive/Tar/TarIn.cpp              CPP/7zip/Archive/Tar/TarOut.cpp     CPP/7zip/Archive/Tar/TarRegister.cpp
CPP/7zip/Archive/Tar/TarUpdate.cpp
CPP/7zip/Archive/Udf/UdfHandler.cpp         CPP/7zip/Archive/Udf/UdfIn.cpp
CPP/7zip/Archive/Wim/WimHandler.cpp         CPP/7zip/Archive/Wim/WimHandlerOut.cpp CPP/7zip/Archive/Wim/WimIn.cpp
CPP/7zip/Archive/Wim/WimRegister.cpp
CPP/7zip/Archive/Zip/ZipAddCommon.cpp       CPP/7zip/Archive/Zip/ZipHandler.cpp CPP/7zip/Archive/Zip/ZipHandlerOut.cpp
CPP/7zip/Archive/Zip/ZipIn.cpp              CPP/7zip/Archive/Zip/ZipItem.cpp    CPP/7zip/Archive/Zip/ZipOut.cpp
CPP/7zip/Archive/Zip/ZipRegister.cpp        CPP/7zip/Archive/Zip/ZipUpdate.cpp
```

**C++ — `CPP/7zip/Compress` (50) — `COMPRESS_OBJS`**

```
CPP/7zip/Compress/BZip2Crc.cpp        CPP/7zip/Compress/BZip2Decoder.cpp   CPP/7zip/Compress/BZip2Encoder.cpp
CPP/7zip/Compress/BZip2Register.cpp   CPP/7zip/Compress/Bcj2Coder.cpp      CPP/7zip/Compress/Bcj2Register.cpp
CPP/7zip/Compress/BcjCoder.cpp        CPP/7zip/Compress/BcjRegister.cpp    CPP/7zip/Compress/BitlDecoder.cpp
CPP/7zip/Compress/BranchMisc.cpp      CPP/7zip/Compress/BranchRegister.cpp CPP/7zip/Compress/ByteSwap.cpp
CPP/7zip/Compress/CopyCoder.cpp       CPP/7zip/Compress/CopyRegister.cpp   CPP/7zip/Compress/Deflate64Register.cpp
CPP/7zip/Compress/DeflateDecoder.cpp  CPP/7zip/Compress/DeflateEncoder.cpp CPP/7zip/Compress/DeflateRegister.cpp
CPP/7zip/Compress/DeltaFilter.cpp     CPP/7zip/Compress/ImplodeDecoder.cpp CPP/7zip/Compress/LzOutWindow.cpp
CPP/7zip/Compress/LzfseDecoder.cpp    CPP/7zip/Compress/LzhDecoder.cpp     CPP/7zip/Compress/Lzma2Decoder.cpp
CPP/7zip/Compress/Lzma2Encoder.cpp    CPP/7zip/Compress/Lzma2Register.cpp  CPP/7zip/Compress/LzmaDecoder.cpp
CPP/7zip/Compress/LzmaEncoder.cpp     CPP/7zip/Compress/LzmaRegister.cpp   CPP/7zip/Compress/LzmsDecoder.cpp
CPP/7zip/Compress/LzxDecoder.cpp      CPP/7zip/Compress/PpmdDecoder.cpp    CPP/7zip/Compress/PpmdEncoder.cpp
CPP/7zip/Compress/PpmdRegister.cpp    CPP/7zip/Compress/PpmdZip.cpp        CPP/7zip/Compress/QuantumDecoder.cpp
CPP/7zip/Compress/Rar1Decoder.cpp     CPP/7zip/Compress/Rar2Decoder.cpp    CPP/7zip/Compress/Rar3Decoder.cpp
CPP/7zip/Compress/Rar3Vm.cpp          CPP/7zip/Compress/Rar5Decoder.cpp    CPP/7zip/Compress/RarCodecsRegister.cpp
CPP/7zip/Compress/ShrinkDecoder.cpp   CPP/7zip/Compress/XpressDecoder.cpp  CPP/7zip/Compress/XzDecoder.cpp
CPP/7zip/Compress/XzEncoder.cpp       CPP/7zip/Compress/ZDecoder.cpp       CPP/7zip/Compress/ZlibDecoder.cpp
CPP/7zip/Compress/ZlibEncoder.cpp     CPP/7zip/Compress/ZstdDecoder.cpp
```

**C++ — `CPP/7zip/Crypto` (14) — `CRYPTO_OBJS`**

```
CPP/7zip/Crypto/7zAes.cpp        CPP/7zip/Crypto/7zAesRegister.cpp  CPP/7zip/Crypto/HmacSha1.cpp
CPP/7zip/Crypto/HmacSha256.cpp   CPP/7zip/Crypto/MyAes.cpp          CPP/7zip/Crypto/MyAesReg.cpp
CPP/7zip/Crypto/Pbkdf2HmacSha1.cpp CPP/7zip/Crypto/RandGen.cpp      CPP/7zip/Crypto/Rar20Crypto.cpp
CPP/7zip/Crypto/Rar5Aes.cpp      CPP/7zip/Crypto/RarAes.cpp         CPP/7zip/Crypto/WzAes.cpp
CPP/7zip/Crypto/ZipCrypto.cpp    CPP/7zip/Crypto/ZipStrong.cpp
```

**C++ — `CPP/7zip/UI/Common` (20) — `UI_COMMON_OBJS`**

```
CPP/7zip/UI/Common/ArchiveCommandLine.cpp   CPP/7zip/UI/Common/ArchiveExtractCallback.cpp
CPP/7zip/UI/Common/ArchiveOpenCallback.cpp  CPP/7zip/UI/Common/Bench.cpp
CPP/7zip/UI/Common/DefaultName.cpp          CPP/7zip/UI/Common/EnumDirItems.cpp
CPP/7zip/UI/Common/Extract.cpp              CPP/7zip/UI/Common/ExtractingFilePath.cpp
CPP/7zip/UI/Common/HashCalc.cpp             CPP/7zip/UI/Common/LoadCodecs.cpp
CPP/7zip/UI/Common/OpenArchive.cpp          CPP/7zip/UI/Common/PropIDUtils.cpp
CPP/7zip/UI/Common/SetProperties.cpp        CPP/7zip/UI/Common/SortUtils.cpp
CPP/7zip/UI/Common/TempFiles.cpp            CPP/7zip/UI/Common/Update.cpp
CPP/7zip/UI/Common/UpdateAction.cpp         CPP/7zip/UI/Common/UpdateCallback.cpp
CPP/7zip/UI/Common/UpdatePair.cpp           CPP/7zip/UI/Common/UpdateProduce.cpp
(not in 7zz but in the same directory: ArchiveName.cpp, CompressCall.cpp, CompressCall2.cpp, WorkDir.cpp, ZipRegistry.cpp — see section 3)
```

**C++ — `CPP/7zip/UI/Console` (11) — `CONSOLE_OBJS` (the part the GUI replaces)**

```
CPP/7zip/UI/Console/BenchCon.cpp     CPP/7zip/UI/Console/ConsoleClose.cpp   CPP/7zip/UI/Console/ExtractCallbackConsole.cpp
CPP/7zip/UI/Console/HashCon.cpp      CPP/7zip/UI/Console/List.cpp           CPP/7zip/UI/Console/Main.cpp (+ -DZ7_PROG_VARIANT_Z -DZ7_7ZIP_ASM)
CPP/7zip/UI/Console/MainAr.cpp       CPP/7zip/UI/Console/OpenCallbackConsole.cpp CPP/7zip/UI/Console/PercentPrinter.cpp
CPP/7zip/UI/Console/UpdateCallbackConsole.cpp CPP/7zip/UI/Console/UserInputUtils.cpp
```

Totals: 1 `.S` + 53 `.c` + 269 `.cpp` = 323 objects (30 + 13 + 24 + 107 + 50 + 14 + 20 + 11 = 269 C++).

---
## 2. Engine interfaces the GUI needs

Conventions used by every header below:

* Interfaces are declared with X-macros: `#define Z7_IFACEM_<Name>(x) x(method(args)) ...`
  followed by `Z7_IFACE_CONSTR_*(Name, subId)`. `CPP/7zip/IDecl.h:18-27` turns that into
  `struct Name : public Base { virtual HRESULT method(args) throw() = 0; ... }` plus
  `IID_Name` = `{23170F69-40C1-278A-0000-00<group>00<subId>0000}` (`IDecl.h:9-23`). Group ids:
  `IProgress` 0 (`IProgress.h:16`), `IFolderArchive` family 1 (`IFileExtractCallback.h:15-20`),
  streams 3 (`IStream.h:14-19`), coders 4 (`ICoder.h:10`), password 5 (`IPassword.h:12-14`),
  archive 6 (`IArchive.h:13-18`), folder 8 (`IFolder.h:11-16`), folder manager 9 (`IFolder.h:165`).
* `Z7_COM7F_IMF(f)` = `HRESULT f throw()` (`IDecl.h:47-50`); implementers use
  `Z7_IFACE_COM7_IMP(Name)` inside the class and `Z7_COM7F_IMF(Class::method(...))` in the
  `.cpp`. Non-COM "UI" interfaces use `Z7_IFACEN_<Name>(x)` + `Z7_IFACE_DECL_PURE`
  (`IDecl.h:60-74`) and are implemented with `Z7_IFACE_IMP(Name)`.
* All COM methods return `HRESULT` and never throw (bodies are wrapped in
  `COM_TRY_BEGIN/COM_TRY_END`, `CPP/Common/ComTry.h:10-11`, which maps *any* C++ exception to
  `E_OUTOFMEMORY`).

### 2.0 Foundation types (what an Objective-C++ bridge has to speak)

`CPP/Common/MyWindows.h` (non-`_WIN32` branch, lines 24-323) is the whole "COM on POSIX" shim:

| Symbol | Definition | Line |
|---|---|---|
| `BOOL`, `BYTE`, `WORD`, `SHORT`, `USHORT`, `CHAR` | ints; `BOOL` is `int` | 36-54 |
| `LONGLONG/ULONGLONG`, `LARGE_INTEGER/ULARGE_INTEGER` | `{ QuadPart }` structs | 66-70 |
| `WCHAR = wchar_t`, `OLECHAR`, `BSTR = OLECHAR*`, `LPCOLESTR`, `LPCWSTR`, `LPCSTR`, `TCHAR = char` | | 72-80 |
| `FILETIME { dwLowDateTime, dwHighDateTime }` | 100 ns units since 1601 | 82-86 |
| `SUCCEEDED/FAILED`, `PROPID = ULONG`, `SCODE` | | 88-91 |
| `S_OK 0`, `S_FALSE 1`, `E_NOTIMPL 0x80004001`, `E_NOINTERFACE 0x80004002`, `E_ABORT 0x80004004`, `E_FAIL 0x80004005`, `STG_E_INVALIDFUNCTION`, `CLASS_E_CLASSNOTAVAILABLE` | | 94-101 |
| `IUnknown { QueryInterface, AddRef, Release }` (no virtual dtor, `Z7_USE_VIRTUAL_DESTRUCTOR_IN_IUNKNOWN` off) | | 168-184 |
| `VARENUM` (`VT_EMPTY, VT_BSTR=8, VT_BOOL=11, VT_UI1=17, VT_UI4=19, VT_UI8=21, VT_FILETIME=64`, ...) | | 191-220 |
| `PROPVARIANT { vt, wReserved1..3, union { ... uhVal, boolVal, filetime, bstrVal } }` | timestamps carry precision in `wReserved1/2` (see `PropID.h:142-163`) | 227-250 |
| `VariantClear/VariantCopy`, `SysAllocString*/SysFreeString/SysStringLen`, `GetLastError/SetLastError`, `CompareFileTime`, `GetCurrentThreadId/ProcessId`, `FileTimeTo(Local)FileTime`, `FileTimeToSystemTime`, `GetTickCount` | implemented in `CPP/Common/MyWindows.cpp:40-232` (malloc-backed BSTRs with a length prefix) | 256-312 |
| `MAX_PATH 1024`, `CP_ACP 0`, `CP_OEMCP 1`, `CP_UTF8 65001`, `STREAM_SEEK_SET/CUR/END` | | 280-291 |

`HRESULT`/`WRes` on POSIX (`C/7zTypes.h`): `WRes` is `int` = `errno` (line 77);
`HRESULT_FROM_WIN32(x)` = `MY_SRes_HRESULT_FROM_WRes(x)` which packs an errno as
`0x8000_0000 | (0x800 << 16) | errno` (`MY_FACILITY_ERRNO = 0x800`, lines 79-93);
`E_OUTOFMEMORY` = `HRESULT_FROM_errno(ENOMEM)`, `E_INVALIDARG` = `HRESULT_FROM_errno(EINVAL)`
(137-140); `ERROR_NEGATIVE_SEEK 131` (102); `MY_HRES_ERROR_INTERNAL_ERROR 0x8007054F` (216);
`RINOK(x)` = `{ const int r = (x); if (r != 0) return r; }` (166);
`FILE_ATTRIBUTE_READONLY 0x0001`, `_DIRECTORY 0x0010`, `_REPARSE_POINT 0x0400`,
`FILE_ATTRIBUTE_UNIX_EXTENSION 0x8000` ("high 16 bits contain the POSIX mode") (145-160);
`CHAR_PATH_SEPARATOR '/'`, `WCHAR_PATH_SEPARATOR L'/'`, `STRING_PATH_SEPARATOR "/"` (575-578);
`k_PropVar_TimePrec_0 0, _Unix 1, _DOS 2, _HighPrec 3, _Base 16, _100ns (16+7), _1ns (16+9)` (582-588).
Note that `INVALID_FILE_ATTRIBUTES` is **only** defined in `C/7zWindows.h:69` (Windows), which is
the root of the Agent's first compile error (section 3).

`CPP/Common/MyTypes.h:12-38`: `struct CBoolPair { bool Val; bool Def; Init(); SetTrueTrue(); SetVal_as_Defined(bool); }` — the "tri-state option" used by every options struct.

`CPP/Common/Common0.h`: `Z7_final`(192), `Z7_override`(231), `Z7_CLASS_NO_COPY`(239), `MY_UNCOPYABLE`(252), `Z7_DECLSPEC_NOVTABLE`(272-274), `Z7_PURE_INTERFACES_BEGIN/END`(278-286), `Z7_ARRAY_SIZE`(`7zTypes.h:562`), `UNUSED_VAR`.

`CPP/Common/MyCom.h`:

* `template<class T> class CMyComPtr` (9-71): `CMyComPtr(T*)` AddRefs, dtor Releases, `operator T*()`, `T** operator&()` (**for out-params of an empty pointer only**), `operator->`, `Attach(T*)` (no AddRef), `T* Detach()`, `QueryInterface(REFGUID, Q**)` (65-70). `CMyComPtr2<iface,cls>` (73-140) and `CMyComPtr2_Create<iface,cls>` (141-188) hold an implementation object and expose `ClsPtr()`/`Interface()`/`Create_if_Empty()`.
* `class CMyComBSTR` (190-281): owns a `BSTR`, `BSTR* operator&()`, `operator LPCOLESTR()`. `CMyComBSTR_Wipe` (282) zeroes on release (passwords).
* `class CMyUnknownImp` (305-316): the reference counter `ULONG _m_RefCount`. **The count is NOT atomic** unless `Z7_COM_USE_ATOMIC` is defined (`MyCom.h:358-392`; default off, and it is off in 7zz). See section 4.4.
* QueryInterface builders: `Z7_COM_QI_BEGIN`/`Z7_COM_QI_BEGIN2(i)`/`Z7_COM_QI_ENTRY(i)`/`Z7_COM_QI_END`/`Z7_COM_ADDREF_RELEASE` (321-392), `Z7_COM_UNKNOWN_IMP_0..8(i...)` (402-483), `Z7_CLASS_IMP_COM_0..7(c, i...)` (535-613, declares `class c Z7_final : public i..., public CMyUnknownImp` with QI), `Z7_CLASS_IMP_NOQIB_0..5` (615-682, no QI beyond IUnknown), `Z7_CLASS_IMP_IInStream` (684).

`CPP/Common/MyString.h`:

* `class AString` (268-506): 8-bit string (UTF-8 on macOS). `class UString` (556-799): `wchar_t` string; **on macOS `wchar_t` is 32-bit (UTF-32 code points)**; `Z7_WCHART_IS_16BIT` is only set for `_WIN32` or 16-bit `WCHAR_MAX` (1057-1063). `UString2` (860-928) is a lightweight variant used inside handlers. `AString_Wipe`/`UString_Wipe` (508, 801) for secrets.
* `AStringVector`, `UStringVector` (949-950). `CSysString` = `AString` on macOS (no `_UNICODE`, 952-958).
* `FChar`/`FString` (964-1030): `USE_UNICODE_FSTRING` is only defined for `_WIN32` (966-969), therefore on macOS `FChar = char`, **`FString = AString`** (UTF-8 file-system string), `fs2us(const FChar*)`/`fs2us(const FString&)` -> `UString`, `us2fs(const wchar_t*)` -> `FString` (1023-1026, implemented in `MyString.cpp:1744-1756` through `UnicodeStringToMultiByte(s, GetCurrentCodePage())`), `fas2fs`/`fs2fas` are identity macros, `CFSTR = const FChar*` (1035), `FStringVector` (1037), `FTEXT("x")`, `FCHAR_PATH_SEPARATOR`, `FSTRING_PATH_SEPARATOR` (1030-1033).
* Helpers: `IS_PATH_SEPAR(c)`/`IsPathSepar` (49-56), `MyStringLen/Copy/Cat`, `MyCharUpper/Lower(_Ascii)` (139-203; the non-ASCII versions use `towupper/towlower` on POSIX), `StringsAreEqualNoCase*`, `MyStringCompareNoCase` (217-236), `SplitString(const UString&, UStringVector&)` (1047), `CStringFinder` (1039-1045).

`CPP/Common/StringConvert.h`: `MultiByteToUnicodeString(const AString&|const char*, UINT codePage = CP_ACP)` (9-10), `MultiByteToUnicodeString2(UString&, const AString&, UINT)` (13), `UnicodeStringToMultiByte(2)` (15-18), `GetUnicodeString(...)` (20-32), `GetAnsiString` (34-38), `GetOemString` (46-49), `GetSystemString` (61-69: on macOS this is the non-`_UNICODE` branch, i.e. `UString -> AString`), `MY_SetLocale()`, `GetLocale()`, `IsNativeUTF8()` (97-104), `extern bool g_ForceToUTF8` (107). On macOS `StringConvert.cpp:260` sets `g_ForceToUTF8 = true`, so `MultiByteToUnicodeString2` always runs `ConvertUTF8ToUnicode` (262-273) regardless of `codePage`, and `UnicodeStringToMultiByte2` always runs `ConvertUnicodeToUTF8` (397-403). Practical rule for the bridge: **every `AString`/`FString`/`char*` that crosses the engine boundary is UTF-8, every `UString` is UTF-32; convert `NSString` <-> `UString` via UTF-8 + `MultiByteToUnicodeString(s, CP_UTF8)` / `UnicodeStringToMultiByte(u, CP_UTF8)`** (or via `UTFConvert.h:176-249`: `ConvertUTF8ToUnicode(const AString&, UString&)`, `ConvertUnicodeToUTF8(const UString&, AString&)`, `Convert_UTF16_To_UTF32/Convert_UTF32_To_UTF16(const UString&, UString&)` (255-256) if you want to pass UTF-16 to Swift). The console calls `MY_SetLocale()` once at startup (`Console/Main.cpp:848`); the app should do the same (it seeds `towupper` etc.).

`CPP/Common/MyVector.h`: `template<class T> class CRecordVector` (13-478) for PODs (`Add`, `AddInReserved`, `Size()`, `Back()`, `ConstData()`, `Sort`, `Delete`, ...), `CIntVector/CUIntVector/CBoolVector/CByteVector/CPointerVector` (479-483), `template<class T> class CObjectVector` (486-735) for objects (owns `T*`, `AddNew()`, `Front()/Back()`), `FOR_VECTOR(i, v)` (737).

`CPP/Windows/PropVariant.h` (`NWindows::NCOM`): `AllocBstrFromAscii` (13), `PropVariant_Clear` (15), `PropVarEm_Set_UInt32/UInt64/FileTime64_Prec/Bool` (20-46), `class CPropVariant : public tagPROPVARIANT` (49-169): ctor sets `VT_EMPTY`; assignment from `bool`, `Byte`, `UInt32`, `UInt64`, `FILETIME`, `BSTR`, `LPCOLESTR`, `UString`, `UString2`, `const char*`, `AString` (132-154; `Int16/Int32/Int64` are deliberately private, use `Set_Int32/Set_Int64` 156-157), `SetAsTimeFrom_FT_Prec[_Ns100]` (78-99), `Get_Ns100` (101), `AllocBstr(numChars)` (159), `Clear/Copy/Attach/Detach` (161-164), `Compare` (168). Typical read pattern: `CPropVariant prop; archive->GetProperty(i, kpidSize, &prop); if (prop.vt == VT_UI8) ...; ` — the destructor frees any `BSTR`.

`CPP/Windows/PropVariantConv.h`: `g_Timestamp_Show_UTC` (10), `kTimestampPrintLevel_*` (12-17), `ConvertUtcFileTimeToString[2](const FILETIME&, [ns100,] char*|wchar_t*, level[, flags])` (24-27, buffer >= 32 chars), `ConvertPropVariantToShortString(const PROPVARIANT&, char*|wchar_t*)` (31-32, not for `VT_BSTR`), `ConvertPropVariantToUInt64` (34-45, throws `151199` on a non-integer type).

`CPP/7zip/PropID.h`: the `kpid*` enum (8-119): `kpidPath 3, kpidName 4, kpidExtension 5, kpidIsDir 6, kpidSize 7, kpidPackSize 8, kpidAttrib 9, kpidCTime 10, kpidATime 11, kpidMTime 12, kpidSolid 13, kpidEncrypted 15, kpidCRC 19, kpidType 20, kpidMethod 22, kpidHostOS 23, kpidComment 28, kpidNumSubDirs 31, kpidNumSubFiles 32, kpidPhySize 54, kpidPosixAttrib 63, kpidSymLink 64, kpidError 65, kpidIsAltStream 73, kpidIsAux 74, kpidIsDeleted 75, kpidIsTree 76, kpidErrorType 79, kpidNumErrors 80, kpidErrorFlags 81, kpidWarningFlags 82, kpidWarning 83, kpidNumStreams 84, kpidNumAltStreams 85, kpidAltStreamsSize 86, kpidUnpackSize 88, kpidReadOnly 103, kpidHardLink 100, kpidINode 101, kpidUserId 109, kpidGroupId 110, ... kpid_NUM_DEFINED, kpidUserDefined 0x10000`; `k7z_PROPID_To_VARTYPE[]` (121, defined in `7zip/Common/PropId.cpp`); `kpv_ErrorFlags_*` bits (123-133: `IsNotArc 1<<0, HeadersError 1<<1, EncryptedHeadersError 1<<2, UnavailableStart 1<<3, UnconfirmedStart 1<<4, UnexpectedEnd 1<<5, DataAfterEnd 1<<6, UnsupportedMethod 1<<7, UnsupportedFeature 1<<8, DataError 1<<9, CrcError 1<<10`); the timestamp precision contract (142-163).

`CPP/7zip/IProgress.h:12-17`: `IProgress { SetTotal(UInt64 total); SetCompleted(const UInt64 *completeValue); }` (GUID group 0, id 5).

`CPP/7zip/IStream.h`: `ISequentialInStream::Read(void*, UInt32 size, UInt32 *processedSize)` (47-49, partial reads allowed, contract in the comment 22-46), `ISequentialOutStream::Write(const void*, UInt32, UInt32*)` (68-70), `IInStream::Seek(Int64 offset, UInt32 seekOrigin, UInt64 *newPosition)` (98-100), `IOutStream::Seek + SetSize(UInt64)` (102-105), `IStreamGetSize::GetSize(UInt64*)` (107-109), `IOutStreamFinish` (111-113), `IStreamGetProps::GetProps(UInt64 *size, FILETIME *c, *a, *m, UInt32 *attrib)` (115-117), `CStreamFileProps` + `IStreamGetProps2` (120-136), `IStreamGetProp::GetProperty/ReloadProps` (138-141), `IStreamSetRestriction::SetRestriction(UInt64 begin, UInt64 end)` (204-207). The concrete file streams are `CInFileStream`/`COutFileStream` in `CPP/7zip/Common/FileStreams.h` (built into 7zz).

`CPP/7zip/ICoder.h` (the parts the GUI touches): `ICompressProgressInfo::SetRatioInfo(const UInt64 *inSize, const UInt64 *outSize)` (14-16, group 4 id 4) — the "packed/unpacked so far" side-channel that all UI progress classes implement; `ICompressSetCoderMt::SetNumberOfThreads` (206-208); `ICompressSetMemLimit` (221-223); `ICompressCodecsInfo` (368-373, only with external codecs); `IHasher { Init(); Update(const void*, UInt32); Final(Byte *digest); GetDigestSize(); }` (453-458, id 0xC0); `IHashers { GetNumHashers(); GetHasherProp(index, propID, PROPVARIANT*); CreateHasher(index, IHasher**); }` (460-464). The built-in hashers are registered statically (`Common/*Reg.cpp`: CRC32, CRC64, XXH64, MD5, SHA1, SHA256, SHA3-256, SHA512, BLAKE2sp) and are created through `CreateHasher_Index/CreateHasher(name)` in `CPP/7zip/Common/CreateCoder.h`.

`CPP/7zip/IPassword.h`: `ICryptoGetTextPassword::CryptoGetTextPassword(BSTR *password)` (26-28, id 0x10) — caller passes `*password == NULL`, callee allocates with `SysAllocString`/`StringToBstr`, caller frees. `ICryptoGetTextPassword2::CryptoGetTextPassword2(Int32 *passwordIsDefined, BSTR *password)` (49-51, id 0x11) — used on the *update* side; `*passwordIsDefined == 0` means "do not encrypt".

`CPP/7zip/Archive/IArchive.h` (the low-level engine contract that `UI/Common` wraps):

* `NFileTimeType::EEnum { kNotDefined = -1, kWindows, kUnix, kDOS, k1ns }` (44-54); `NArcInfoFlags` (56-80); `NArchive::NHandlerPropID` (99-116).
* `NArchive::NExtract::NAskMode { kExtract = 0, kTest, kSkip, kReadExternal }` (121-130) and `NArchive::NExtract::NOperationResult { kOK = 0, kUnsupportedMethod, kDataError, kCRCError, kUnavailable, kUnexpectedEnd, kDataAfterEnd, kIsNotArc, kHeadersError, kWrongPassword }` (132-148) — every "operation result" integer in the UI callbacks is one of these.
* `NEventIndexType { kNoIndex, kInArcIndex, kBlockIndex, kOutArcIndex }` (151-160); `NUpdate::NOperationResult { kOK }` (163-175).
* `IArchiveOpenCallback { SetTotal(const UInt64 *files, const UInt64 *bytes); SetCompleted(const UInt64 *files, const UInt64 *bytes); }` (177-181, id 0x10). Handlers additionally `QueryInterface` the open callback for `IArchiveOpenVolumeCallback { GetProperty(PROPID, PROPVARIANT*); GetStream(const wchar_t *name, IInStream**); }` (262-265, multi-volume), `ICryptoGetTextPassword`, `IArchiveOpenSetSubArchiveName::SetSubArchiveName(const wchar_t*)` (272-274).
* `IArchiveExtractCallback : IProgress { GetStream(UInt32 index, ISequentialOutStream **outStream, Int32 askExtractMode); PrepareOperation(Int32 askExtractMode); SetOperationResult(Int32 opRes); }` (234-239, id 0x20). Threading contract in the comment at 183-232: *"7-Zip doesn't call GetStream/PrepareOperation/SetOperationResult from different threads simultaneously. But 7-Zip can call IProgress or ICompressProgressInfo functions from another threads simultaneously with calls for IArchiveExtractCallback"*. `IArchiveExtractCallbackMessage2::ReportExtractResult(UInt32 indexType, UInt32 index, Int32 opRes)` (258-260) reports errors that are not tied to the current item.
* `IInArchive { Open(IInStream*, const UInt64 *maxCheckStartPosition, IArchiveOpenCallback*); Close(); GetNumberOfItems(UInt32*); GetProperty(UInt32 index, PROPID, PROPVARIANT*); Extract(const UInt32 *indices, UInt32 numItems, Int32 testMode, IArchiveExtractCallback*); GetArchiveProperty(PROPID, PROPVARIANT*); GetNumberOfProperties(UInt32*); GetPropertyInfo(UInt32 index, BSTR *name, PROPID*, VARTYPE*); GetNumberOfArchiveProperties(UInt32*); GetArchivePropertyInfo(...); }` (316-328, id 0x60). `indices == NULL && numItems == (UInt32)-1` means "all items".
* `IArchiveGetRawProps` (365-371), `IArchiveGetRootProps` (373-377), `IArchiveOpenSeq` (379-382), `IArchiveOpen2` (409-411), `IInArchiveGetStream::GetStream(UInt32 index, ISequentialInStream**)` (268-270; `CAgentFolder` re-exports it for "open item as stream").
* `IArchiveUpdateCallback : IProgress { GetUpdateItemInfo(UInt32 index, Int32 *newData, Int32 *newProps, UInt32 *indexInArchive); GetProperty(UInt32 index, PROPID, PROPVARIANT*); GetStream(UInt32 index, ISequentialInStream **inStream); SetOperationResult(Int32 operationResult); }` (445-451, id 0x80, semantics 416-443), `IArchiveUpdateCallback2::GetVolumeSize/GetVolumeStream` (454-458), `NUpdateNotifyOp { kAdd = 0, kUpdate, kAnalyze, kReplicate, kRepack, kSkip, kDelete, kHeader, kHashRead, kInFileChanged }` (460-474), `IArchiveUpdateCallbackFile::GetStream2(index, inStream, notifyOp) / ReportOperation(indexType, index, notifyOp)` (486-490), `IArchiveGetDiskProperty` (493-496), `IArchiveRequestMemoryUseCallback::RequestMemoryUse(...)` (613-616; asks the UI before allocating > limit, answered with `NRequestMemoryAnswerFlags`, 568-611).
* `IOutArchive { UpdateItems(ISequentialOutStream *outStream, UInt32 numItems, IArchiveUpdateCallback*); GetFileTimeType(UInt32 *type); }` (530-534, id 0xA0); `ISetProperties::SetProperties(const wchar_t * const *names, const PROPVARIANT *values, UInt32 numProps)` (547-550, id 0x03) — the `-m` switches; `IArchiveKeepModeForNextOpen` (552-555); `IArchiveAllowTail` (562-565).
* Static handler registration: `Func_CreateInArchive/Func_CreateOutArchive/Func_IsArc` typedefs (699-717), `CArcInfo` + `RegisterArc()` in `CPP/7zip/Common/RegisterArc.h:8-29` with the `REGISTER_ARC_*` macros (44-78) used by every `*Register.cpp`/`*Handler.cpp`.

### 2.1 `CPP/7zip/UI/FileManager/IFolder.h` — the browsing model (GUID group 8)

This header is pure interface declarations (no Win32 types except `BSTR`/`PROPVARIANT`/`FILETIME`, which the shim provides), and it is the contract that `CAgentFolder` implements for archives. A macOS panel talks to an archive exclusively through these:

| Interface (id) | Methods | Lines |
|---|---|---|
| `NPlugin::{kName, kType, kClassID, kOptionsClassID}` | plugin-info property indices (unused on macOS) | 18-27 |
| `IFolderFolder` (0x00) | `LoadItems()`; `GetNumberOfItems(UInt32*)`; `GetProperty(UInt32 itemIndex, PROPID, PROPVARIANT*)`; `BindToFolder(UInt32 index, IFolderFolder**)`; `BindToFolder(const wchar_t *name, IFolderFolder**)`; `BindToParentFolder(IFolderFolder**)`; `GetNumberOfProperties(UInt32*)`; `GetPropertyInfo(UInt32 index, BSTR *name, PROPID*, VARTYPE*)`; `GetFolderProperty(PROPID, PROPVARIANT*)` | 29-40 |
| `IFolderAltStreams` (0x17) | `BindToAltStreams(UInt32 index, IFolderFolder**)` (`(UInt32)-1` = alt streams of the folder itself); `BindToAltStreams(const wchar_t*, ...)`; `AreAltStreamsSupported(UInt32 index, Int32*)` | 42-52 |
| `IFolderWasChanged` (0x04) | `WasChanged(Int32*)` | 54-56 |
| `IFolderOperationsExtractCallback : IProgress` (0x0B) | `AskWrite(const wchar_t *srcPath, Int32 srcIsFolder, const FILETIME *srcTime, const UInt64 *srcSize, const wchar_t *destPathRequest, BSTR *destPathResult, Int32 *writeAnswer)`; `ShowMessage(const wchar_t*)`; `SetCurrentFilePath(const wchar_t*)`; `SetNumFiles(UInt64)` | 58-73 |
| `IFolderOperations` (0x13) | `CreateFolder(const wchar_t *name, IProgress*)`; `CreateFile(const wchar_t *name, IProgress*)`; `Rename(UInt32 index, const wchar_t *newName, IProgress*)`; `Delete(const UInt32 *indices, UInt32 numItems, IProgress*)`; `CopyTo(Int32 moveMode, const UInt32 *indices, UInt32 numItems, Int32 includeAltStreams, Int32 replaceAltStreamCharsMode, const wchar_t *path, IFolderOperationsExtractCallback*)`; `CopyFrom(Int32 moveMode, const wchar_t *fromFolderPath, const wchar_t * const *itemsPaths, UInt32 numItems, IProgress*)`; `SetProperty(UInt32 index, PROPID, const PROPVARIANT*, IProgress*)`; `CopyFromFile(UInt32 index, const wchar_t *fullFilePath, IProgress*)` | 76-89 |
| `IFolderGetSystemIconIndex` (0x07) | `GetSystemIconIndex(UInt32 index, Int32 *iconIndex)` (Windows shell icons; not implemented by the Agent) | 98-100 |
| `IFolderGetItemFullSize` (0x08) / `IFolderCalcItemFullSize` (0x14) | `GetItemFullSize(UInt32, PROPVARIANT*, IProgress*)`, `CalcItemFullSize(UInt32, IProgress*)` (FS folders only) | 102-108 |
| `IFolderClone` (0x09) | `Clone(IFolderFolder**)` | 110-112 |
| `IFolderSetFlatMode` (0x0A) | `SetFlatMode(Int32 flatMode)` — flat = recursive listing with `kpidPrefix` | 114-116 |
| `IFolderProperties` (0x0E) | `GetNumberOfFolderProperties(UInt32*)`; `GetFolderPropertyInfo(UInt32 index, BSTR *name, PROPID*, VARTYPE*)` | 124-128 |
| `IFolderArcProps` (0x10) | `GetArcNumLevels(UInt32*)`; `GetArcProp(UInt32 level, PROPID, PROPVARIANT*)`; `GetArcNumProps(level, UInt32*)`; `GetArcPropInfo(level, index, BSTR*, PROPID*, VARTYPE*)`; `GetArcProp2/GetArcNumProps2/GetArcPropInfo2` (the "2" variants are the handler-declared archive properties; the "1" variants are the synthesised ones: path, type, error, error flags...) | 130-139 |
| `IGetFolderArcProps` (0x11) | `GetFolderArcProps(IFolderArcProps**)` | 141-143 |
| `IFolderCompare` (0x15) | `Int32 CompareItems(UInt32 index1, UInt32 index2, PROPID propID, Int32 propIsRaw)` (`x##2` = returns `Int32`, not `HRESULT`) | 145-147 |
| `IFolderGetItemName` (0x16) | `GetItemName(UInt32 index, const wchar_t **name, unsigned *len)`; `GetItemPrefix(UInt32 index, const wchar_t **name, unsigned *len)`; `UInt64 GetItemSize(UInt32 index)` — zero-copy accessors for list views | 149-154 |
| `IFolderManager` (group 9, id 5) | `OpenFolderFile(IInStream *inStream, const wchar_t *filePath, const wchar_t *arcFormat, IFolderFolder **resultFolder, IProgress *progress)`; `GetExtensions(BSTR*)`; `GetIconPath(const wchar_t *ext, BSTR *iconPath, Int32 *iconIndex)` | 157-166 |
| helper macros | `IMP_IFolderFolder_GetProp`, `IMP_IFolderFolder_Props(c)` build `GetNumberOfProperties/GetPropertyInfo` from a `kProps[]` table | 172-180 |
| free function | `int CompareFileNames_ForFolderList(const wchar_t *s1, const wchar_t *s2)` — declared here, **defined in `FileManager/PanelSort.cpp:14-45`** (natural/numeric-aware, case-insensitive compare). The Agent calls it (`Agent.cpp:557-611`), so a non-Windows build must provide it (section 4.3). | 183 |

### 2.2 The Agent (`CPP/7zip/UI/Agent/`) — the archive-as-folder layer

`IFolderArchive.h` (GUID group 1; macros `Z7_IFACE_CONSTR_FOLDERARC[_SUB]` come from `IFileExtractCallback.h:15-20`):

| Interface (id) | Methods | Lines |
|---|---|---|
| `IArchiveFolder` (0x0D) | `Extract(const UInt32 *indices, UInt32 numItems, Int32 includeAltStreams, Int32 replaceAltStreamCharsMode, NExtract::NPathMode::EEnum pathMode, NExtract::NOverwriteMode::EEnum overwriteMode, const wchar_t *path, Int32 testMode, IFolderArchiveExtractCallback *extractCallback2)` — extract/test *selected items of this folder* | 26-35 |
| `IInFolderArchive` (0x0E) | `Open(IInStream *inStream, const wchar_t *filePath, const wchar_t *arcFormat, BSTR *archiveTypeRes, IArchiveOpenCallback *openArchiveCallback)`; `ReOpen(IArchiveOpenCallback*)`; `Close()`; `GetNumberOfProperties(UInt32*)`; `GetPropertyInfo(UInt32, BSTR*, PROPID*, VARTYPE*)`; `BindToRootFolder(IFolderFolder**)`; `Extract(NExtract::NPathMode::EEnum, NExtract::NOverwriteMode::EEnum, const wchar_t *path, Int32 testMode, IFolderArchiveExtractCallback*)` — extract the whole archive | 43-54 |
| `IFolderArchiveUpdateCallback : IProgress` (0x0B) | `CompressOperation(const wchar_t *name)`; `DeleteOperation(const wchar_t *name)`; `OperationResult(Int32 opRes)`; `UpdateErrorMessage(const wchar_t *message)`; `SetNumFiles(UInt64 numFiles)` | 56-63 |
| `IOutFolderArchive` (0x0F) | `SetFolder(IFolderFolder*)`; `SetFiles(const wchar_t *folderPrefix, const wchar_t * const *names, UInt32 numNames)`; `DeleteItems(ISequentialOutStream *outArchiveStream, const UInt32 *indices, UInt32 numItems, IFolderArchiveUpdateCallback*)`; `DoOperation(FStringVector *requestedPaths, FStringVector *processedPaths, CCodecs *codecs, int index, ISequentialOutStream *outArchiveStream, const Byte *stateActions, const wchar_t *sfxModule, IFolderArchiveUpdateCallback*)`; `DoOperation2(requestedPaths, processedPaths, outArchiveStream, stateActions, sfxModule, callback)` | 65-82 |
| `IFolderArchiveUpdateCallback2` (0x10) | `OpenFileError(const wchar_t *path, HRESULT)`; `ReadingFileError(const wchar_t *path, HRESULT)`; `ReportExtractResult(Int32 opRes, Int32 isEncrypted, const wchar_t *path)`; `ReportUpdateOperation(UInt32 notifyOp, const wchar_t *path, Int32 isDir)` | 85-91 |
| `IFolderScanProgress` (0x11) | `ScanError(const wchar_t *path, HRESULT)`; `ScanProgress(UInt64 numFolders, UInt64 numFiles, UInt64 totalSize, const wchar_t *path, Int32 isDir)` | 94-98 |
| `IFolderSetZoneIdMode` (0x12) / `IFolderSetZoneIdFile` (0x13) | `SetZoneIdMode(NExtract::NZoneIdMode::EEnum)`, `SetZoneIdFile(const Byte*, UInt32)` — NTFS "Zone.Identifier" propagation; no-ops on macOS (`Agent.cpp:1535-1542` is `#if defined(_WIN32)`) | 101-109 |
| `IFolderArchiveUpdateCallback_MoveArc` (0x14) | `MoveArc_Start(const wchar_t *srcTempPath, const wchar_t *destFinalPath, UInt64 size, Int32 updateMode)`; `MoveArc_Progress(UInt64 totalSize, UInt64 currentSize)`; `MoveArc_Finish()`; `Before_ArcReopen()` (the callee must clear its "user break" state, comment at 112-113) | 112-120 |

`Agent.h`:

* `extern CCodecs *g_CodecsObj; HRESULT LoadGlobalCodecs(); void FreeGlobalCodecs();` (19-21). Implementation `Agent.cpp:29-107`: `g_CodecsObj` is a process-wide singleton kept alive by `CMyComPtr<IUnknown> g_CodecsRef` (43-47), guarded by a `static NSynchronization::CCriticalSection g_CriticalSection` (`MT_LOCK`, 49-54); `LoadGlobalCodecs` is idempotent, calls `g_CodecsObj->Load()` and `Codecs_AddHashArcHandler(g_CodecsObj)` (95-101) and returns `E_NOTIMPL` if no formats were registered.
* `IArchiveFolderInternal::GetAgentFolder(CAgentFolder**)` (27-29, id 0xC) — lets `CAgent::SetFolder` find the `CAgentFolder` behind an `IFolderFolder`.
* `struct CProxyItem { unsigned DirIndex; unsigned Index; }` (33-37); `enum AGENT_OP { AGENT_OP_Uni, AGENT_OP_Delete, AGENT_OP_CreateFolder, AGENT_OP_Rename, AGENT_OP_CopyFromFile, AGENT_OP_Comment }` (41-49).
* `class CAgentFolder Z7_final` (51-168) implements `IFolderFolder, IFolderAltStreams, IFolderProperties, IArchiveGetRawProps, IGetFolderArcProps, IFolderCompare, IFolderGetItemName, IArchiveFolder, IArchiveFolderInternal, IInArchiveGetStream, IFolderSetZoneIdMode, IFolderSetZoneIdFile, IFolderOperations, IFolderSetFlatMode`. Public state: `_flatMode`, `_loadAltStreams`, `_proxy`/`_proxy2` (the two directory-tree models), `_proxyDirIndex`, `_zoneMode`, `_agent` (`CMyComPtr<IInFolderArchive>` — keeps the `CAgent` alive), `_agentSpec`, `_items` (152-167). Helpers: `Init(proxy, proxy2, proxyDirIndex, agent)` (122-136), `GetPathParts` (138), `CommonUpdateOperation(AGENT_OP, bool moveMode, const wchar_t *newItemName, const CActionSet*, const UInt32 *indices, UInt32 numItems, IProgress*)` (139-145), `GetPrefix/GetName/GetFullPrefix` (148-150), `GetRealIndex/GetRealIndices` (104-106), `CompareItems2/3`, `ComparePrefixes` (108-110).
* `class CAgent Z7_final` (172-327) implements `IInFolderArchive, IFolderArcProps, IOutFolderArchive, ISetProperties`. Public state: `_proxy`, `_proxy2`, `CArchiveLink _archiveLink` (223), `UString ArchiveType`, `FStringVector _names`, `FString _folderPrefix` (files to add), `UString _updatePathPrefix`, `CAgentFolder *_agentFolder`, `UString _archiveFilePath`, `DWORD _attrib`, `bool _isDeviceFile`, `bool _isHashHandler`, `FString _hashBaseFolderPrefix`, `m_PropNames/m_PropValues` (pending `ISetProperties`), `_progress_ArchiveOpenCallback_for_Open`, `_progress_for_Open` (221-249). Helpers: `GetArc()`, `GetArchive()` (254-255), `CanUpdate()` (256, `Agent.cpp:1611-1625`: false for parsers, device files, nested archives, archives with a tail), `Is_Attrib_ReadOnly()` (258-261), `IsThere_ReadOnlyArc()` (263-274), `GetTypeOfArc()` (276-281), `UString GetErrorMessage()` (283-324: multi-level "Cannot open the file as [type] archive" / "[type]: message" text — the same text the FM shows), `KeepModeForNextOpen()` (326). Update helpers: `CommonUpdate`, `CreateFolder`, `RenameItem`, `CommentItem`, `UpdateOneFile` (198-214).
* `struct CCodecIcons` (332-344) and `CArchiveFolderManager : IFolderManager` (347-361). The icon part is Win32 resource based (section 3/4).

Implementation facts the bridge must know (all in `Agent.cpp` unless noted):

* `CAgent::Open` (1627-1711): if `inStream == NULL` the archive is stat'ed with `NFind::CFileInfo::Find` (1640-1655) and the parent dir becomes `_hashBaseFolderPrefix`; then `LoadGlobalCodecs()`, `ParseOpenTypes(*g_CodecsObj, arcFormat, types)` (1659-1662 — **`arcFormat` must be a non-NULL wide string; pass `L""` for auto-detect**, a NULL pointer crashes in `UString(const wchar_t*)`, verified by the smoke test), `COpenOptions` filled with `stream`, `filePath`, `callback = openArchiveCallback` (1676-1685), `_archiveLink.Open(options)` (1687). Returns `S_OK`, `S_FALSE` ("not an archive" / partially opened; look at `_archiveLink.NonOpen_ErrorInfo`), or an error `HRESULT`. `*archiveTypeRes` receives the format name (`"7z"`, `"zip"`, ... or `"Parser"`). The open callback may be NULL for plain single-file archives (the smoke test also ran with NULL), but must be non-NULL for multi-volume, encrypted-header and progress reporting — `CArchiveFolderManager::OpenFolderFile` (`ArchiveFolderOpen.cpp:92-132`) QI's it from the `IProgress` argument and the FM always passes a `COpenCallbackImp` (see 2.5.1).
* `CAgent::ReOpen` (1713-1742): drops the proxies, re-runs `CArchiveLink::ReOpen`, then `ReadItems`. `Close` (1744-1749).
* `CAgent::ReadItems` (1758-1806): chooses `CProxyArc2` when the handler supports `IArchiveGetRawProps` and reports `kpidIsTree` (1763-1769), caps proxy memory at 3/4 of RAM via `NSystem::GetRamSize` (1771-1779), then `Load(arc, progress)`.
* `CAgent::BindToRootFolder` (1808-1821) creates the root `CAgentFolder` (`k_Proxy_RootDirIndex = 0`, `AgentProxy.h:22`).
* `CAgentFolder::GetProperty` (299-413): `kpidPrefix` (flat mode), `kpidIsDir`, `kpidName`, folder `kpidSize/kpidPackSize` (only in non-flat mode; from `CProxyDir::Size/PackSize`), `kpidNumSubDirs/kpidNumSubFiles`, `kpidCRC`; every other property is forwarded to `IInArchive::GetProperty(arcIndex, ...)`. `GetNumberOfProperties/GetPropertyInfo` (1159-1230) = the handler's property table + `kProps[] = { kpidNumSubDirs, kpidNumSubFiles, kpidPrefix }` (1143-1149). `GetFolderProperty` (1241-1303) answers `kFolderProps[] = { kpidSize, kpidPackSize, kpidNumSubDirs, kpidNumSubFiles, kpidCRC }` (1232-1239).
* `CAgentFolder::Extract` (1474-1590): builds a `CArchiveExtractCallback` (`UI/Common`), `InitForMulti(false, pathMode, overwriteMode, _zoneMode, k_keepEmptyDirPrefixes)` (1503-1508), forwards `SetTotal(GetEstmatedPhySize())` to the UI callback (1510-1511), creates the target dir (1513-1523), `Init(...)` (1544-1552), `SetBaseParentFolderIndex` for tree archives (1554-1555), `GetRealIndices` (1560-1564), `PrepareHardLinks` unless test mode (1566-1573), then `IInArchive::Extract(realIndices, ..., testMode, extractCallback)` and `CArchiveExtractCallback_Closer` (1575-1586).
* `CAgent::Extract` (1823-1872): same, for the whole archive (`indices = NULL`).
* `CAgentFolder::CopyTo` (`ArchiveFolder.cpp:32-57`): QI's `IFolderArchiveExtractCallback` from the `IFolderOperationsExtractCallback` (so a GUI extract callback must implement **both**), chooses `kCurPaths` (or `kNoPaths[Alt]` in flat mode), always `kAsk` overwrite mode, then calls `Extract`. `moveMode != 0` -> `E_NOTIMPL`.
* `CAgentFolder::CommonUpdateOperation` (`ArchiveFolderOut.cpp:93-375`) is the "edit inside archive" engine: refuses when `!CanUpdate()` (105); QI's `IFolderArchiveUpdateCallback` from the `IProgress` argument (107-109); `CWorkDirTempFile::CreateTempFile(archivePath)` (127); copies any SFX/leading bytes (`arc.ArcStreamOffset`, 133-145); dispatches `Delete/CreateFolder/Rename/Comment/UpdateOneFile/DoOperation2` (149-181); `KeepModeForNextOpen(); _agent->Close()` (184-185); QI's `IFolderArchiveUpdateCallback_MoveArc` and moves the temp file over the original with progress (`tempFile.MoveToOriginal(true, &prox)`, 195-241; `Before_ArcReopen()` is called even after `E_ABORT`, 233); in move mode deletes the source files/empty dirs (244-259); `ReOpen` with an `IArchiveOpenCallback` QI'd from the update callback (261-266); `BindToRootFolder` and re-descends to the previous folder (277-320). Any `UString` thrown inside is converted into `UpdateErrorMessage("Error: ...")` + `E_FAIL` (362-373). `CopyFrom` (377-391) = `AGENT_OP_Uni` with `k_ActionSet_Add`; `CopyFromFile` (393-400); `Delete` (402-408); `CreateFolder` (410-430); `Rename` (432-438); `CreateFile` -> `E_NOTIMPL` (440-443); `SetProperty` only supports `kpidComment` on zip (445-457).
* `CAgent::DoOperation` (`AgentOut.cpp:254-471`): enumerates the disk items with `CDirItems::EnumerateItems2(folderPrefix, _updatePathPrefix, _names, requestedPaths)` reporting through `IFolderScanProgress` (274-297), creates/QI's `IOutArchive` (306-324), `GetFileTimeType` (327-332), enumerates archive items (346-360), `GetUpdatePairInfoList` + `UpdateProduce` with the action set (362-369), `SetNumFiles(numFiles)` (371-382), wires `CUpdateCallbackAgent` -> `CArchiveUpdateCallback` (384-394), applies pending `ISetProperties` (`m_PropNames/m_PropValues`, 407-437), optional SFX prefix copy (439-445), and finally `outArchive->UpdateItems(outArchiveStream, updatePairs2.Size(), updateCallback)` (447). `DoOperation2` (473-480) uses `g_CodecsObj` and `formatIndex = -1`. `CAgent::SetProperties` (765-774) just stores names/values for the next `DoOperation`.
* `CUpdateCallbackAgent` (`UpdateCallbackAgent.h:10-20`, `.cpp:13-208`) adapts `IUpdateCallbackUI` (the non-COM interface `UI/Common/Update*.cpp` talk to) onto the COM `IFolderArchiveUpdateCallback` (+ `IFolderArchiveUpdateCallback2`, `ICompressProgressInfo`, `ICryptoGetTextPassword2` obtained by QI in `SetCallback`, 13-23). `CheckBreak()` always returns `S_OK` (60-63) — cancellation on the Agent path arrives through the `HRESULT` returned by `SetCompleted`/`SetTotal` etc. `OpenFileError/ReadingFileError` (72-118) convert the errno to a message when there is no `Callback2`. `ReportExtractResult` (138-154) calls the **externally defined** `void SetExtractErrorMessage(Int32 opRes, Int32 encrypted, const wchar_t *fileName, UString &s)` (declared at 136, defined only in `FileManager/ExtractCallback.cpp:277`) — another symbol the macOS layer must provide.

`AgentProxy.h` (portable; compiled clean with the strict flags): `CProxyFile { Name, NameLen, NeedDeleteName }` (8-20), `CProxyDir { Name, NameLen, ArcIndex, ParentDir, SubDirs, SubDirs2, SubFiles, Size, PackSize, Crc, NumSubDirs, NumSubFiles, CrcIsDefined, Is_Changed_LongPath }` (24-47), `class CProxyArc { Dirs, Files, NumFiles, Are_Changed_LongPaths, MemUsage, MemUsage_Limit; FindSubDir; GetDirPathParts_isChanged; GetDirPath_as_Prefix[_from_Base]; AddRealIndices; GetRealIndex; GetRealIndices_Unsorted; HRESULT Load(const CArc&, IArchiveOpenCallback *progress); }` (49-84) — the flat "path string" model; `CProxyFile2` (91-117), `CProxyDir2` (119-138), `k_Proxy2_RootDirIndex 0 / k_Proxy2_AltRootDirIndex 1` (140-142), `class CProxyArc2 { ...; HRESULT Load(const CArc&, IProgress*); FindItem(dirIndex, name, foldersOnly); IsAltDir; ... }` (144-191) — the parent-index ("tree") model used for NTFS/APFS/HFS images with alt streams.

### 2.3 `CPP/7zip/UI/Common/` — the shared "engine front-end"

**`LoadCodecs.h`** — the format table.

* `struct CArcExtInfo { UString Ext; UString AddExt; }` (85-93).
* `struct CArcInfoEx` (96-232): `Flags`, `TimeFlags`, `Func_CreateInArchive CreateInArchive`, `Func_IsArc IsArcFunc`, `UString Name`, `CObjectVector<CArcExtInfo> Exts`, `Func_CreateOutArchive CreateOutArchive`, `bool UpdateEnabled`, `bool NewInterface`, `UInt32 SignatureOffset`, `CObjectVector<CByteBuffer> Signatures`; predicates `Flags_KeepName/FindSignature/AltStreams/NtSecurity/SymLinks/HardLinks/UseGlobalOffset/StartOpen/BackwardOpen/PreArc/PureStartOpen/ByExtOnlyOpen/HashHandler/CTime/ATime/MTime[_Default]` (144-166), `Get_TimePrecFlags/Get_DefaultTimePrec` (168-178), `GetMainExt()` (181-186), `FindExtension(const UString&)` (187), `Is_7z/Is_Split/Is_Xz/Is_BZip2/Is_GZip/Is_Tar/Is_Zip/Is_Rar/Is_Zstd` (189-197), `AddExts` (213).
* `struct CCodecError` (271-277), `struct CCodecInfoUser` (280-291).
* `class CCodecs Z7_final : public IUnknown, public CMyUnknownImp` (294-466; without `Z7_EXTERNAL_CODECS` it is a plain refcounted object): `CObjectVector<CArcInfoEx> Formats` (357), `CaseSensitive_Change/CaseSensitive` (364-365), `GetFormatNamePtr(int formatIndex)` (380-383; `"#"` for -1), `HRESULT Load()` (385; `LoadCodecs.cpp:791-...` iterates the static `g_Arcs[]` table filled by `RegisterArc()` at static-init time, `LoadCodecs.cpp:113-121`), `FindFormatForArchiveName(const UString&)`, `FindFormatForExtension(const UString&)`, `FindFormatForArchiveType(const UString&)`, `FindFormatForArchiveType(const UString&, CIntVector&)` (388-391), `CreateInArchive(unsigned formatIndex, CMyComPtr<IInArchive>&)` (413-428), `CreateOutArchive(unsigned, CMyComPtr<IOutArchive>&)` (432-448), `FindOutFormatFromName(const UString&)` (450-461), `Get_CodecsInfoUser_Vector` (463).
* `CREATE_CODECS_OBJECT` macro (476-480): `CCodecs *codecs = new CCodecs; CMyComPtr<IUnknown> _codecsRef = codecs;` — the pattern the console uses (`Console/Main.cpp:1010-1015`); the Agent uses the global `g_CodecsObj` instead.

**`OpenArchive.h`** — opening, including nested/multi-volume archives.

* `Archive_GetItemBoolProp`, `Archive_IsItem_Dir/Aux/AltStream/Deleted` (19-23); `FindAltStreamColon_in_Path` (26).
* `struct COpenSpecFlags { CanReturnFrontal, CanReturnTail, CanReturnMid }` (44-59).
* `struct COpenType` (61-115): `int FormatIndex` (-1 = any), `SpecForcedType/SpecMainType/SpecWrongExt/SpecUnknownExt`, `Recursive` (open nested archives), `CanReturnArc`, `CanReturnParser`, `IsHashType`, `EachPos`, `ZerosTailIsAllowed`, `MaxStartOffset[_Defined]`. Build these with `bool ParseOpenTypes(CCodecs&, const UString &s, CObjectVector<COpenType>&)` (446) from a `-t` style string (`"7z"`, `"zip:tar"`, `"#"`...).
* `struct COpenOptions` (117-145): `CCodecs *codecs; COpenType openType; const CObjectVector<COpenType> *types; const CIntVector *excludedFormats; IInStream *stream; ISequentialInStream *seqStream; IArchiveOpenCallback *callback; COpenCallbackImp *callbackSpec; const CObjectVector<CProperty> *props; bool stdInMode; UString filePath;`.
* `UInt32 GetOpenArcErrorFlags(const CPropVariant&, bool *isDefinedProp)` (147).
* `struct CArcErrorInfo` (149-226): `ThereIsTail`, `UnexpecedEnd`, `IgnoreTail`, `ErrorFlags_Defined`, `ErrorFlags`, `WarningFlags`, `int ErrorFormatIndex` (-1 none; `== FormatIndex` means "opened with offset"), `TailSize`, `UString ErrorMessage`, `UString WarningMessage`; `IsArc_After_NonOpen()` (170-173), `ClearErrors[_Full]`, `IsThereErrorOrWarning()` (196-204), `AreThereErrors/Warnings()`, `NeedTailWarning()`, `GetWarningFlags()/GetErrorFlags()` (211-225). Filled by `CArc::ReadBasicProps` (`OpenArchive.cpp:1241-...`) from `kpidErrorFlags/kpidWarningFlags/kpidError/kpidWarning`.
* `struct CReadArcItem` (228-262): `Path`, `PathParts`, `MainPath`, `AltStreamName`, `IsAltStream`, `WriteToAltStreamIfColon`, `IsDir`, `MainIsDir`, `ParentIndex`, `_use_baseParentFolder_mode`, `_baseParentFolder`.
* `class CArc` (267-388): `CMyComPtr<IInArchive> Archive; CMyComPtr<IInStream> InStream; GetRawProps; GetRootProps; IsParseArc; IsTree; IsReadOnly; Ask_Deleted/AltStream/Aux/INode; IgnoreSplit; UString Path; filePath; DefaultName; int FormatIndex; UInt32 SubfileIndex; CArcTime MTime; Int64 Offset; UInt64 PhySize; PhySize_Defined; FileSize; AvailPhySize; CArcErrorInfo ErrorInfo; CArcErrorInfo NonOpen_ErrorInfo; UInt64 ArcStreamOffset;` — methods `GetEstmatedPhySize()` (321), `GetGlobalOffset()` (324), `ReadBasicProps` (341), `Close()` (343-347), `GetItem_Path/GetItem_DefaultPath/GetItem_Path2` (349-353), `GetItem(UInt32, CReadArcItem&)` (355), `GetItem_Size` (357), `GetItem_MTime` (369), `IsItem_Anti` (371), `OpenStream/OpenStreamOrFile/ReOpen/CreateNewTailStream` (375-380), `IsHashHandler(const COpenOptions&)` (382-387).
* `struct CArchiveLink` (390-444): `CObjectVector<CArc> Arcs` (Arcs[0] = outer file, `Arcs.Back()` = the archive the user sees), `UStringVector VolumePaths`, `UInt64 VolumesSize`, `bool IsOpen`, `bool PasswordWasAsked`, `UString NonOpen_ArcPath`, `CArcErrorInfo NonOpen_ErrorInfo`; `KeepModeForNextOpen()`, `Close()`, `Release()`, `GetArc()/GetArchive()/GetArchiveGetRawProps()/GetArchiveGetRootProps()` (419-422); the four open entry points documented at 424-429: `Open(COpenOptions&)` (uses `options.callback` as-is — what the Agent uses), `Open2(COpenOptions&, IOpenCallbackUI*)` (creates the `COpenCallbackImp` proxy that handles volumes + password: `OpenArchive.cpp:3386-3425`), `Open3` (= `Open2` + `callbackUI->Open_Finished()`, 3473-3481), `Open_Strict` (435-441: also `S_FALSE` when a nested level failed to open), `ReOpen(COpenOptions&)` (443, 3483-3525).
* `struct CDirPathSortPair` (451-467).

**`ArchiveOpenCallback.h`**

* Non-COM `IOpenCallbackUI` (33-40): `Open_CheckBreak()`, `Open_SetTotal(const UInt64 *files, const UInt64 *bytes)`, `Open_SetCompleted(const UInt64 *files, const UInt64 *bytes)`, `Open_Finished()`, `Open_CryptoGetTextPassword(BSTR *password)` (unless `Z7_NO_CRYPTO`).
* `class CMultiStreams` (45-85): LRU of open volume files (`NumOpenFiles_AllowedMax`).
* `class COpenCallbackImp Z7_final` (97-180) implements `IArchiveOpenCallback, IArchiveOpenVolumeCallback, IArchiveOpenSetSubArchiveName, ICryptoGetTextPassword, IProgress`; state `PasswordWasAsked`, `FileNames`, `FileNames_WasUsed`, `FileSizes`, `IArchiveOpenCallback *ReOpenCallback`, `IOpenCallbackUI *Callback` (raw pointers, not refcounted, 141-156), `CMultiStreams Volumes`; `Init2(const FString &folderPrefix, const FString &fileName)` (174), `SetSecondFileInfo` (176-179). Behaviour (`ArchiveOpenCallback.cpp`): `SetTotal/SetCompleted` forward to `ReOpenCallback` or `Callback->Open_SetTotal/Open_SetCompleted` (56-76); `GetProperty(kpidName/IsDir/Size/Attrib/CTime/ATime/MTime)` answers from the stat of the base file or the sub-archive name (79-110); `GetStream(name)` (284-367) opens sibling volume files relative to `_folderPrefix` (rejects unsafe/absolute names via `IsSafePath`, returns `S_FALSE` if missing) and records them; `CryptoGetTextPassword` (370-386) sets `PasswordWasAsked = true` and forwards to `Callback->Open_CryptoGetTextPassword`; `IProgress::SetCompleted` maps to `Open_CheckBreak` (395-402).

**`Extract.h`**

* `NExtractOutDirMode::EEnum { k_Direct, k_AddArcName, k_ReplaceAsterisk }` (17-24).
* `struct CExtractOptionsBase` (26-55): `CBoolPair ElimDup; bool ExcludeDirItems, ExcludeFileItems, PathMode_Force, OverwriteMode_Force; NExtract::NPathMode::EEnum PathMode (kFullPaths); NExtract::NOverwriteMode::EEnum OverwriteMode (kAsk); NExtract::NZoneIdMode::EEnum ZoneMode; NExtractOutDirMode::EEnum OutDirMode (k_ReplaceAsterisk); CExtractNtOptions NtOptions; FString OutputDir (normalized, trailing separator); UString HashDir;`.
* `struct CExtractOptions : CExtractOptionsBase` (57-83): `StdInMode, StdOutMode, YesToAll, TestMode, CObjectVector<CProperty> Properties`.
* `struct CDecompressStat { NumArchives, UnpackSize, AltStreams_UnpackSize, PackSize, NumFolders, NumFiles, NumAltStreams; Clear(); }` (85-99).
* `HRESULT Extract(CCodecs *codecs, const CObjectVector<COpenType> &types, const CIntVector &excludedFormats, UStringVector &archivePaths, UStringVector &archivePathsFull, const NWildcard::CCensorNode &wildcardCensor, const CExtractOptions &options, IOpenCallbackUI *openCallback, IExtractCallbackUI *extractCallback, IFolderArchiveExtractCallback *faeCallback, IHashCalc *hash, UString &errorMessage, CDecompressStat &st)` (101-116) — the multi-archive driver used by `7zz x/e/t` and by `ExtractGUI`.

**`ExtractMode.h`**: `NExtract::NPathMode::EEnum { kFullPaths, kCurPaths, kNoPaths, kAbsPaths, kNoPathsAlt }` (8-18), `NExtract::NOverwriteMode::EEnum { kAsk, kOverwrite, kSkip, kRename, kRenameExisting }` (20-30), `NExtract::NZoneIdMode::EEnum { kNone, kAll, kOffice }` (32-40).

**`ExtractingFilePath.h`**: `Correct_AltStream_Name(UString&)` (9), `UString Get_Correct_FsFile_Name(const UString &name)` (13: replaces unsupported chars and `.`/`..`/empty by `[]`), `Correct_FsPath(bool absIsAllowed, bool keepAndReplaceEmptyPrefixes, UStringVector &parts, bool isDir)` (27), `UString MakePathFromParts(const UStringVector&)` (29).

**`IFileExtractCallback.h`** (GUID group 1):

* `NOverwriteAnswer::EEnum { kYes, kYesToAll, kNo, kNoToAll, kAutoRename, kCancel }` (22-33).
* `IFolderArchiveExtractCallback : IProgress` (0x07, 54-63): `AskOverwrite(const wchar_t *existName, const FILETIME *existTime, const UInt64 *existSize, const wchar_t *newName, const FILETIME *newTime, const UInt64 *newSize, Int32 *answer)`; `PrepareOperation(const wchar_t *name, Int32 isFolder, Int32 askExtractMode, const UInt64 *position)`; `MessageError(const wchar_t *message)`; `SetOperationResult(Int32 opRes, Int32 encrypted)`.
* `IFolderArchiveExtractCallback2` (0x08, 65-68): `ReportExtractResult(Int32 opRes, Int32 encrypted, const wchar_t *name)`.
* Non-COM `IExtractCallbackUI` (83-93): `BeforeOpen(const wchar_t *name, bool testMode)`, `OpenResult(const CCodecs*, const CArchiveLink&, const wchar_t *name, HRESULT result)`, `ThereAreNoFiles()`, `ExtractResult(HRESULT result)`, `SetPassword(const UString&)`.
* `IGetProp::GetProp(PROPID, PROPVARIANT*)` (0x20, 97-100) and `IFolderExtractToStreamCallback` (0x31, 102-108): `UseExtractToStream(Int32 *res)`, `GetStream7(const wchar_t *name, Int32 isDir, ISequentialOutStream **outStream, Int32 askExtractMode, IGetProp*)`, `PrepareOperation7(Int32)`, `SetOperationResult8(Int32 resultEOperationResult, Int32 encrypted, UInt64 size)` — the "extract into memory/QuickLook" hook: if the UI callback also implements this and answers `UseExtractToStream -> 1`, `CArchiveExtractCallback` hands every item to `GetStream7` instead of creating files (`ArchiveExtractCallback.cpp:371-378, 1946, 2025, 2836`). The FM uses it for in-memory "open item" (`CVirtFileSystem`, `ExtractCallback.h:119-175`).

**`ArchiveExtractCallback.h`** — the concrete `IArchiveExtractCallback` that writes to the file system.

* `COutStreamWithHash` (26-47), `struct CExtractNtOptions` (51-92): `NtSecurity, SymLinks, HardLinks, AltStreams` (CBoolPair, links default true), `ReplaceColonForAltStream`, `WriteToAltStreamIfColon`, `ExtractOwner`, `PreAllocateOutFile` (false on POSIX), `PreserveATime`, `OpenShareForWrite`, `SymLinks_DangerousLevel (5)`, `MemLimit`.
* `SUPPORT_LINKS` (95-99), `CHardLinkNode/CHardLinks` (104-131), `CIndexToPathPair` (135-147), `CFiTimesCAM/CDirPathTime` (153-181), `ELinkType`, `CLinkInfo` (186-229), `CProcessedFileInfo` (235-292; on POSIX carries `COwnerInfo Owner/Group`), `CPostLink` (297-306).
* `class CArchiveExtractCallback Z7_final` (322-607) implements `IArchiveExtractCallback, IArchiveExtractCallbackMessage2, ICryptoGetTextPassword, ICompressProgressInfo, IArchiveUpdateCallbackFile, IArchiveGetDiskProperty, IArchiveRequestMemoryUseCallback`. Public API: `Is_elimPrefix_Mode` (364), `_ntOptions` (369), `_dirPathPrefix_Full` (407), `SendMessageError*` (475-479), `LocalProgressSpec` (486, a `CLocalProgress` that forwards ratio/`SetCompleted` to the UI callback), counters `NumFolders/NumFiles/NumAltStreams/UnpackSize/AltStreams_UnpackSize` (488-492), `DirPathPrefix_for_HashFiles` (494), `InitForMulti(bool multiArchives, NPathMode, NOverwriteMode, NZoneIdMode, bool keepAndReplaceEmptyDirPrefixes)` (498-514), `SetHashMethods(IHashCalc*)` (518-525), `InitBeforeNewArchive()` (529), `Init(const CExtractNtOptions&, const NWildcard::CCensorNode *wildcardCensor, const CArc *arc, IFolderArchiveExtractCallback *extractCallback2, bool stdOutMode, bool testMode, const FString &directoryPath, const UStringVector &removePathParts, bool removePartsForAltStreams, UInt64 packSize)` (531-539), `CreateHardLink2/DeleteLinkFileAlways_or_RemoveEmptyDir/PrepareHardLinks(const CRecordVector<UInt32> *realIndices)` (561-564), `SetBaseParentFolderIndex(UInt32)` (577-581), `CloseArc()` (584). `struct CArchiveExtractCallback_Closer` (610-631) is the RAII guard that calls `CloseArc()` (flushes post-links and directory timestamps). Free functions: `CensorNode_CheckPath`, `Is_ZoneId_StreamName`, `ReadZoneFile_Of_BaseFile`, `WriteZoneFile_To_BaseFile` (634-638).
* Behaviour that matters to the UI (`ArchiveExtractCallback.cpp`): `Init` QI's the UI callback for `IFolderArchiveExtractCallback2`, `IFolderExtractToStreamCallback`, `ICryptoGetTextPassword` lazily (2924-2932), `IArchiveRequestMemoryUseCallback` (3037-3041); `SetTotal` forwards only when `!_multiArchives` (397-405); `SetCompleted` rescales the handler's progress into "packed bytes of the whole batch" in multi-archive mode (430-446); `SetRatioInfo` -> `LocalProgressSpec` (451-455); `CheckExistFile` (1246-1320) implements `kSkip`/`kAsk` (`AskOverwrite` with the on-disk file's real name, mtime, size and the archive item's `Path`, `MTime` if defined, size if known; answers map to `E_ABORT`/skip/`kSkip`-for-the-rest/`kOverwrite`-for-the-rest/`kRename`) and `kRename`/`kRenameExisting` (via `AutoRenamePath`, `FilePathAutoRename.h`); `PrepareOperation` (2018-2050) forwards `_item.Path, IsDir, askExtractMode, position`; `SetOperationResult` (2825-2892) finalises hashes, closes the file, sets attributes/owner, updates counters and forwards `(opRes, encrypted)`; `ReportExtractResult` (2896-2921) resolves the item path (or `#index`) and forwards to `IFolderArchiveExtractCallback2`.

**`Update.h`**

* `enum EArcNameMode { k_ArcNameMode_Smart, k_ArcNameMode_Exact, k_ArcNameMode_Add }` (15-20); `struct CArchivePath` (22-42: `OriginalPath, Prefix, Name, BaseExtension, VolExtension, Temp, TempPrefix, TempPostfix; ParseFromPath(const UString&, EArcNameMode); GetFinalPath(); GetFinalVolPath(); GetTempPath()`); `struct CUpdateArchiveCommand { UserArchivePath; ArchivePath; NUpdateArchive::CActionSet ActionSet; }` (44-49); `struct CCompressionMethodMode { bool Type_Defined; COpenType Type; CObjectVector<CProperty> Properties; }` (51-58); `NRecursedType` (60-65); `struct CRenamePair` (67-78).
* `struct CUpdateOptions` (80-157): `UpdateArchiveItself (true), SfxMode, PreserveATime, OpenShareForWrite, StopAfterOpenError, StdInMode, StdOutMode, EMailMode, EMailRemoveAfter, DeleteAfterCompressing, SetArcMTime, RenameMode; CBoolPair NtSecurity, AltStreams, HardLinks, SymLinks, StoreOwnerId, StoreOwnerName; EArcNameMode ArcNameMode; NWildcard::ECensorPathMode PathMode; CCompressionMethodMode MethodMode; CObjectVector<CUpdateArchiveCommand> Commands; CArchivePath ArchivePath; FString SfxModule; UString StdInFileName; UString EMailAddress; FString WorkingDir; CObjectVector<CRenamePair> RenamePairs; CRecordVector<UInt64> VolumesSizes;` — `InitFormatIndex(const CCodecs*, const CObjectVector<COpenType>&, const UString &arcPath)` (124), `SetArcPath(const CCodecs*, const UString&)` (125), `SetActionCommand_Add()` (150-156).
* `struct CUpdateErrorInfo { DWORD SystemError; AString Message; FStringVector FileNames; ThereIsError(); Get_HRESULT_Error(); SetFromLastError(const char*[, const FString&]); SetFromError_DWORD(...); }` (160-173); `struct CFinishArchiveStat { OutArcFileSize; NumVolumes; IsMultiVolMode; }` (175-182).
* Non-COM `IUpdateCallbackUI2 : IUpdateCallbackUI, IDirItemsCallback` (189-207): `OpenResult(const CCodecs*, const CArchiveLink&, const wchar_t *name, HRESULT)`, `StartScanning()`, `FinishScanning(const CDirItemsStat&)`, `StartOpenArchive(const wchar_t*)`, `StartArchive(const wchar_t *name, bool updating)`, `FinishArchive(const CFinishArchiveStat&)`, `DeletingAfterArchiving(const FString&, bool isDir)`, `FinishDeletingAfterArchiving()`, `MoveArc_Start(srcTempPath, destFinalPath, size, updateMode)`, `MoveArc_Progress(total, current)`, `MoveArc_Finish()`.
* `HRESULT UpdateArchive(CCodecs*, const CObjectVector<COpenType> &types, const UString &cmdArcPath2, NWildcard::CCensor &censor, CUpdateOptions&, CUpdateErrorInfo&, IOpenCallbackUI *openCallback, IUpdateCallbackUI2 *callback, bool needSetPath)` (210-219) — the `7zz a/u/d/rn` driver used by `UpdateGUI`.

**`UpdateCallback.h`**

* `struct CArcToDoStat { CDirItemsStat2 NewData, OldData, DeleteData; Get_NumDataItems_Total(); }` (18-28).
* Non-COM `IUpdateCallbackUI` (33-60): `WriteSfx(const wchar_t *name, UInt64 size)`, `SetTotal(UInt64)`, `SetCompleted(const UInt64*)`, `SetRatioInfo(const UInt64 *inSize, const UInt64 *outSize)`, `CheckBreak()`, `SetNumItems(const CArcToDoStat&)`, `GetStream(const wchar_t *name, bool isDir, bool isAnti, UInt32 mode)` (mode = `NUpdateNotifyOp`), `OpenFileError(const FString &path, DWORD systemError)`, `ReadingFileError(const FString&, DWORD)`, `SetOperationResult(Int32 opRes)`, `ReportExtractResult(Int32 opRes, Int32 isEncrypted, const wchar_t *name)`, `ReportUpdateOperation(UInt32 op, const wchar_t *name, bool isDir)`, `CryptoGetTextPassword2(Int32 *passwordIsDefined, BSTR *password)`, `CryptoGetTextPassword(BSTR*)`, `ShowDeleteFile(const wchar_t *name, bool isDir)`.
* `class CArchiveUpdateCallback Z7_final` (78-195) implements the COM side (`IArchiveUpdateCallback2, IArchiveUpdateCallbackFile, IArchiveExtractCallbackMessage2, IArchiveGetRawProps, IArchiveGetRootProps, ICryptoGetTextPassword2, ICryptoGetTextPassword, ICompressProgressInfo, IInFileStream_Callback`) and forwards to `IUpdateCallbackUI *Callback` (149). Inputs: `DirItems`, `ParentDirItem`, `Arc`, `Archive`, `ArcItems`, `UpdatePairs`, `VolumesSizes`, `VolName`, `VolExt`, `ArcFileName`, `NewNames`, `Comment`, `CommentIndex`, `ProcessedItemsStatuses` (151-173); flags `PreserveATime, ShareForWrite, StopAfterOpenError, StdInMode, KeepOriginalItemNames, StoreNtSecurity, StoreHardLinks, StoreSymLinks, StoreOwnerId, StoreOwnerName, Need_LatestMTime` (120-134).

**`UpdateAction.h`**: `NUpdateArchive::NPairState::EEnum { kNotMasked, kOnlyInArchive, kOnlyOnDisk, kNewInArchive, kOldInArchive, kSameFiles, kUnknowNewerFiles }` (8-21), `NPairAction::EEnum { kIgnore, kCopy, kCompress, kCompressAsAnti }` (23-32), `struct CActionSet { NPairAction::EEnum StateActions[7]; IsEqualTo; NeedScanning(); }` (34-57), `k_ActionSet_Add/Update/Fresh/Sync/Delete` (59-63). **`UpdatePair.h`**: `CUpdatePair { State, ArcIndex, DirIndex, HostIndex }`, `GetUpdatePairInfoList(const CDirItems&, const CObjectVector<CArcItem>&, NFileTimeType::EEnum, CRecordVector<CUpdatePair>&)` (11-25). **`UpdateProduce.h`**: `CUpdatePair2 { NewData, NewProps, UseArcProps, IsAnti, DirIndex, ArcIndex, NewNameIndex, IsMainRenameItem, IsSameTime; SetAs_NoChangeArcItem(); ExistOnDisk(); ExistInArchive(); }` (8-44), `IUpdateProduceCallback::ShowDeleteFile(unsigned arcIndex)` (48-51), `UpdateProduce(const CRecordVector<CUpdatePair>&, const CActionSet&, CRecordVector<CUpdatePair2>&, IUpdateProduceCallback*)` (54-58).

**`DirItem.h`**: `struct CDirItemsStat { NumDirs, NumFiles, NumAltStreams, FilesSize, AltStreamsSize, NumErrors; Get_NumDataItems(); GetTotalBytes(); IsEmpty(); }` (20-50), `CDirItemsStat2` (+ `Anti_*`, 53-72), non-COM `IDirItemsCallback { ScanError(const FString &path, DWORD systemError); ScanProgress(const CDirItemsStat&, const FString &path, bool isDir); }` (77-81), `struct CArcTime { FILETIME FT; UInt16 Prec; Byte Ns100; bool Def; ... Write_To_FiTime(CFiTime&); Set_From_FiTime(const CFiTime&); Set_From_Prop(const PROPVARIANT&); Get_DosTime(); GetNumDigits(); }` (86-228), `struct CDirItem : NFind::CFileInfoBase { UString Name; CByteBuffer ReparseData; int PhyParent, LogParent, SecureIndex; int OwnerNameIndex, OwnerGroupIndex (POSIX); }` (231-295), `class CDirItems` (299-383): `Items`, `SymLinks`, `ScanAltStreams`, `ExcludeDirItems/ExcludeFileItems`, `ShareForWrite`, `Stat`, `OwnerNameMap/OwnerGroupMap/StoreOwnerName` (POSIX), `IDirItemsCallback *Callback`, `EnumerateItems2(const FString &phyPrefix, const UString &logPrefix, const FStringVector &filePaths, FStringVector *requestedPaths)` (376-380), `GetPhyPath/GetLogPath` (367-368); `struct CArcItem { Size, Name, MTime, IsDir, IsAltStream, Size_Defined, Censored, IndexInServer }` (388-405).

**`EnumDirItems.h`**: `EnumerateItems(const NWildcard::CCensor&, NWildcard::ECensorPathMode, const UString &addPathPrefix, CDirItems&)` (11-15), `struct CMessagePathException : UString` (18-22; thrown by the command-line/censor code — catch it at the bridge), `EnumerateDirItemsAndSort(NWildcard::CCensor&, ECensorPathMode, const UString &addPathPrefix, UStringVector &sortedPaths, UStringVector &sortedFullPaths, CDirItemsStat&, IDirItemsCallback*)` (25-32).

**`HashCalc.h`**: `k_HashCalc_DigestSize_Max 64`, `k_HashCalc_ExtraSize 8`, `k_HashCalc_NumGroups 4` (15-17), `HashHexToString(char *dest, const Byte *data, size_t size)` (23), digest group indices `k_HashCalc_Index_Current/DataSum/NamesSum/StreamsSum` (25-31), `struct CHasherState { CMyComPtr<IHasher> Hasher; AString Name; UInt32 DigestSize; UInt64 NumSums[4]; Byte Digests[4][72]; AddDigest; WriteToString(unsigned digestIndex, char *s); }` (33-65), non-COM `IHashCalc { InitForNewFile(); Update(const void*, UInt32); SetSize(UInt64); Final(bool isDir, bool isAltStream, const UString &path); }` (71-77), `struct CHashBundle Z7_final : IHashCalc { CObjectVector<CHasherState> Hashers; NumDirs, NumFiles, NumAltStreams, FilesSize, AltStreamsSize, NumErrors, CurSize; UString MainName, FirstFileName; HRESULT SetMethods(const UStringVector &methods); }` (81-109), non-COM `IHashCallbackUI : IDirItemsCallback { StartScanning(); FinishScanning(const CDirItemsStat&); SetNumFiles(UInt64); SetTotal(UInt64); SetCompleted(const UInt64*); CheckBreak(); BeforeFirstFile(const CHashBundle&); GetStream(const wchar_t *name, bool isFolder); OpenFileError(const FString&, DWORD); SetOperationResult(UInt64 fileSize, const CHashBundle&, bool showHash); AfterLastFile(CHashBundle&); }` (115-128), `CHashOptionsLocal` (133-185), `struct CHashOptions { UStringVector Methods; PreserveATime, OpenShareForWrite, StdInMode, AltStreamsMode; CBoolPair SymLinks; NWildcard::ECensorPathMode PathMode; }` (188-208), `HRESULT HashCalc(const NWildcard::CCensor&, const CHashOptions&, AString &errorInfo, IHashCallbackUI*)` (211-216), the `NHash::CHandler` "hash file as archive" handler (222-315) and `Codecs_AddHashArcHandler(CCodecs*)` (317).

**`Bench.h`**: `Benchmark_GetUsage_Percents` (11), `struct CBenchInfo { GlobalTime, GlobalFreq, UserTime, UserFreq, UnpackSize, PackSize, NumIterations; GetUsage(); GetRatingPerUsage(); GetSpeed(); GetRating_LzmaEnc/Dec(); }` (13-43), `struct CTotalBenchRes` (46-71), `kBenchMinDicLogSize 18` (74), `GetBenchMemoryUsage(UInt32 numThreads, int level, UInt64 dictionary, bool totalBench)` (76), non-COM `IBenchCallback { SetEncodeResult(const CBenchInfo&, bool final); SetDecodeResult(...); }` (79-84), `IBenchPrintCallback { Print(const char*); NewLine(); CheckBreak(); }` (86-91), `IBenchFreqCallback` (93-97), `HRESULT Bench(IBenchPrintCallback*, IBenchCallback*, const CObjectVector<CProperty> &props, UInt32 numIterations, bool multiDict, IBenchFreqCallback* = NULL)` (100-107), `GetSysInfo/GetCpuName/AddCpuFeatures` (111-113).

**`PropIDUtils.h`**: `ConvertPropertyToShortString2(char *dest (>= 64), const PROPVARIANT&, PROPID, int level = 0)` (9), `ConvertPropertyToString2(UString&, const PROPVARIANT&, PROPID, int level = 0)` (10) — the canonical "property -> display string" used by the console `l` command and the FM columns (handles timestamps with precision, attributes as `D....A`, posix modes, CRC hex...), `ConvertNtReparseToString`, `ConvertNtSecureToString`, `CheckNtSecure`, `ConvertWinAttribToString(char *s, UInt32 wa)` (12-16).

**`ArchiveName.h`**: `UString CreateArchiveName(const UStringVector &paths, bool isHash, const NFind::CFileInfo *fi, UString &baseName)` (10-14) — proposes `<dir>.7z` / `<file>` names like the FM "Add to archive" dialog.

**`ZipRegistry.h`** — persisted settings (the Windows implementation is the registry; see 4.3 for the macOS replacement): `NExtract::CInfo { PathMode, OverwriteMode, PathMode_Force, OverwriteMode_Force; CBoolPair SplitDest, ElimDup, NtSecurity, ShowPassword; UStringVector Paths; Save(); Load(); }` (23-42), `NExtract::Save_ShowPassword/Read_ShowPassword/Save_LimitGB/Read_LimitGB` (44-48), `NCompression::CMemUse { IsDefined, IsPercent, Val; GetBytes(ramSize); Parse(const UString&); }` (53-81), `NCompression::CFormatOptions { Level, Dictionary, Order, BlockLogSize, NumThreads, TimePrec; CBoolPair MTime, ATime, CTime, SetArcMTime; CSysString FormatID; UString Method, Options, EncryptionMethod, MemUse; ... }` (83-134), `NCompression::CInfo { Level, ShowPassword, EncryptHeaders; CBoolPair NtSecurity, AltStreams, HardLinks, SymLinks, PreserveATime; UString ArcType; UStringVector ArcPaths; CObjectVector<CFormatOptions> Formats; Save(); Load(); }` (136-156), `NWorkDir::NMode::EEnum { kSystem, kCurrent, kSpecified }` and `NWorkDir::CInfo { Mode, ForRemovableOnly, FString Path; SetDefault(); Save(); Load(); }` (159-187), `CContextMenuInfo` (190-210).

**`WorkDir.h`**: `FString GetWorkDir(const NWorkDir::CInfo&, const FString &path, FString &fileName)` (12; `WorkDir.cpp:14-59`: `kSystem` -> `MyGetTempPath()` which on POSIX is `/tmp/` or `./` (`Windows/FileDir.cpp:864-874`), `kCurrent` -> the archive's directory, `kSpecified` -> `Path`), `class CWorkDirTempFile { CMyComPtr<IOutStream> OutStream; Get_OriginalFilePath(); Get_TempFilePath(); HRESULT CreateTempFile(const FString &originalPath); HRESULT MoveToOriginal(bool deleteOriginal, ICopyFileProgress *progress = NULL); }` (14-28). `CreateTempFile` calls `NWorkDir::CInfo::Load()` (`WorkDir.cpp:63-64`) — that is why the Agent needs a `ZipRegistry` replacement at link time.

**`TempFiles.h`**: `class CTempFiles { FStringVector Paths; bool NeedDeleteFiles; ~CTempFiles() deletes them }` (8-17). **`SetProperties.h`**: `HRESULT SetProperties(IUnknown *unknown, const CObjectVector<CProperty> &properties)` (8) — QI's `ISetProperties` and pushes `-m` style name/value pairs (parses `"x=9"`, `"mt=4"`, booleans, sizes). **`Property.h`**: `struct CProperty { UString Name; UString Value; }` (8-12). **`ExitCode.h`**: `NExitCode::EEnum { kSuccess = 0, kWarning = 1, kFatalError = 2, kUserError = 7, kMemoryError = 8, kUserBreak = 255 }` (8-23). **`DefaultName.h`**: `GetDefaultName2(fileName, extension, addSubExtension)` (8). **`SortUtils.h`**: `SortFileNames(const UStringVector&, CUIntVector &indices)` (8). **`CompressCall.h`** (both implementations are Windows-only, see 3): `GetQuotedString` (8), `CompressFiles(arcPathPrefix, arcName, arcType, addExtension, names, email, showDialog, waitFinish)` (10-16), `ExtractArchives(arcPaths, outFolder, showDialog, elimDup, writeZone)` (18), `TestArchives(arcPaths, hashMode)` (19), `CalcChecksum(paths, methodName, arcPathPrefix, arcFileName)` (21-24), `Benchmark(totalMode)` (26) — this is exactly the set of "commands" the macOS app has to offer, and the in-process implementation (`CompressCall2.cpp`) is the template for the bridge (section 4.3).

**`ArchiveCommandLine.h`** (in 7zz, portable): `CArcCmdLineOptions` (49-158) bundles `CExtractOptionsBase ExtractOptions`, `CUpdateOptions UpdateOptions`, `CHashOptions HashOptions`, `CObjectVector<CProperty> Properties`, `NWildcard::CCensor Censor`, `Password/PasswordEnabled`, `ArcType`, etc.; `CArcCmdLineParser` (161-...) parses an argv vector. Useful for reusing `-m`/`-t`/`-o` semantics and the overwrite/path mode mapping (`ArchiveCommandLine.cpp:255-262, 1745-1751`: `-ao{a,s,u,t}` -> `kOverwrite/kSkip/kRename/kRenameExisting`, `-y` -> `kOverwrite`).

### 2.4 `CPP/Windows/` — the portable OS layer (all of these are in 7zz)

* **`FileDir.h`** (`NWindows::NFile::NDir`): `SetDirTime(CFSTR, const CFiTime *c, *a, *m)` (26), `SetLinkFileTime` (33), POSIX-only `my_chown/my_chown_Link` (48-49), `SetFileAttrib_PosixHighDetect(CFSTR, DWORD attrib)` (53; the POSIX version chmods from the high 16 bits when `FILE_ATTRIBUTE_UNIX_EXTENSION` is set), `PROGRESS_CONTINUE/PROGRESS_CANCEL` + non-COM `ICopyFileProgress { DWORD CopyFileProgress(UInt64 total, UInt64 current); }` (56-69), `MyMoveFile`, `MyMoveFile_with_Progress` (71-74; POSIX: `rename()` then copy+delete fallback with progress), `MyCreateHardLink` (78), `RemoveDir`, `CreateDir`, `CreateComplexDir` (81-89), `DeleteFileAlways`, `RemoveDirWithSubItems` (91-92), `MyGetFullPathName`, `GetFullPathAndSplit`, `GetOnlyDirPrefix` (99-101), `SetCurrentDir/GetCurrentDir` (105-106), `MyGetTempPath` (110), `CreateTempFile2` (112), `class CTempFile { GetPath(); Create(CFSTR pathPrefix, NIO::COutFile*); CreateRandomInTempFolder(...); Remove(); MoveTo(CFSTR name, bool deleteDestBefore, ICopyFileProgress*); }` (114-129), `CCurrentDirRestorer` (149-168). `SetFileAttrib(CFSTR, DWORD)` (38) and `CTempDir` (133-145) are **Windows-only**.
* **`FileFind.h`** (`NWindows::NFile::NFind`): `DoesFileExist_Raw/_FollowLink`, `DoesDirExist(name[, followLink])`, `DoesFileOrDirExist`, `GetFileAttrib` (23-35), POSIX `Get_WinAttribPosix_From_PosixMode(UInt32 mode)` (61; `FileFind.cpp:1104-1112`: `FILE_ATTRIBUTE_DIRECTORY|ARCHIVE|READONLY | FILE_ATTRIBUTE_UNIX_EXTENSION | (mode << 16)`), `class CFileInfoBase` (65-156): `Size, CTime, ATime, MTime` (`CFiTime` = `timespec`), POSIX members `dev, ino, mode, nlink, uid, gid, rdev` (88-94; **no `Attrib`, `IsAltStream`, `IsDevice` on POSIX** — the source of two Agent compile errors), `ClearBase()`, `SetAs_StdInFile()`, `GetPosixAttrib()`, `GetWinAttrib()`, `IsDir()`, `SetAsDir()`, `SetFrom_stat()`, `IsReadOnly()`, `IsPosixLink()`, `IsOsSymLink()` (127-155); `struct CFileInfo : CFileInfoBase { FString Name; IsDots(); Find(CFSTR path, bool followLink = false); Find_FollowLink(); Find_DontFill_Name(); }` (158-175); POSIX `struct CDirEntry { ino_t iNode; Byte Type; FString Name; IsDots(); }` (275-294, **no `IsDir()`** — third Agent error) and `class CEnumerator { SetDirPrefix(const FString&); Next(CDirEntry&, bool &found); Fill_FileInfo(const CDirEntry&, CFileInfo&, bool followLink); DirEntry_IsDir(const CDirEntry&, bool followLink); }` (296-324). Windows-only: `NAttributes`, `CFindFile`, `CStreamInfo/CFindStream/CStreamEnumerator`, `CFindChangeNotification`, `MyGetLogicalDriveStrings` (37-270).
* **`FileIO.h`** (`NWindows::NFile::NIO`, POSIX part 365-505): `NDir::C_umask g_umask` (368-374), `GetReparseData(CFSTR, CByteBuffer&)`, `SetSymLink(CFSTR from, CFSTR to)`, `SetSymLink_UString` (378-383), `k_OutFile_mode_default 0666` (385), `class CFileBase { int _handle; bool PreserveATime; Close(); GetLength(UInt64&); seek/seekToBegin/seekToCur; my_fstat; }` (387-421), `class CInFile { Open(const char*); OpenShared(const char*, bool shareForWrite); read_part; ReadFull(void*, size_t, size_t&); }` (423-439), `class COutFile { mode_for_Create; Close(); Open_EXISTING; Create_ALWAYS_or_Open_ALWAYS; Create_ALWAYS; Create_NEW; write_part/write_full/WriteFull; SetLength; SetLength_KeepPosition; SetTime; Set_Time_and_WinAttrib(c, a, m, DWORD attrib); SetMTime; }` (441-501). Also `CReparseShortInfo/CReparseAttr` (96-137) and `HRESULT GetLastError_noZero_HRESULT()` (55) = `HRESULT_FROM_WIN32(errno)` with a non-zero guarantee.
* **`FileName.h`** (`NWindows::NFile::NName`): `FindSepar` (12-15), `NormalizeDirPathPrefix(FString&|UString&)` (17-18), `IsDrivePath(const wchar_t*)` (24), `IsAltPathPrefix(CFSTR)` (26), `IsAbsolutePath(const wchar_t*)`, `GetRootPrefixSize(const wchar_t*)` (86-87), POSIX `GetRootPrefixSize_WINDOWS(const wchar_t*)` (95), `GetFullPath(CFSTR dirPrefix, CFSTR path, FString&)`, `GetFullPath(CFSTR, FString&)` (137-138). Everything between lines 33-84 (`IsDevicePath`, `IsSuperUncPath`, `IsNetworkPath`, `IsDrivePath_SuperAllowed`, `IsSuperPath`, **`IsAltStreamPrefixWithColon`** (57), `FindAltStreamColon`, `GetRootPrefixSize(CFSTR)`...) is `#if defined(_WIN32) && !defined(UNDER_CE)` — the fourth Agent error.
* **`TimeUtils.h`**: `FILETIME_To_UInt64/FILETIME_Clear/FILETIME_IsZero` (10-24), POSIX `CFiTime = timespec` (52), `Compare_FiTime`, `FILETIME_To_timespec`, `FiTime_To_FILETIME[_ns100]`, `FiTime_Clear` (54-62), `ST_MTIME/ST_ATIME/ST_CTIME(st)` = `st_mtimespec/...` on `__APPLE__` (64-67), `NTime::DosTime_To_FileTime`, `UtcFileTime_To_LocalDosTime`, `FileTime_To_DosTime`, `UnixTime_To_FileTime[64]`, `UnixTime64_To_FileTime[64]`, `FileTime64_To_UnixTime64`, `FileTime_To_UnixTime[64]`, `FileTime_To_UnixTime64_and_Quantums`, `GetSecondsSince1601`, `GetCurUtc_FiTime(CFiTime&)`, POSIX `GetCurUtcFileTime(FILETIME&)` (89-115), `PropVariant_SetFrom_UnixTime/NtfsTime/FiTime/DosTime` (119-152). Rule: FILETIME <-> `Date`: `unixSeconds = (ft64 / 10^7) - 11644473600`.
* **`System.h`** (`NWindows::NSystem`): `GetNumberOfProcessors()` (18), POSIX `struct CProcessAffinity { UInt32 numSysThreads; GetNumSystemThreads(); Get(); InitST(); GetNumProcessThreads(); CpuZero/CpuSet/IsCpuSet; SetProcAffinity() -> FALSE/ENOSYS on macOS; }` (138-197), `bool GetRamSize(size_t&)` (202; `sysctl` on Apple, `System.cpp:303-381`), `Get_File_OPEN_MAX()`, `Get_File_OPEN_MAX_Reduced_for_3_tasks()` (204-205).
* **`Synchronization.h`** (`NWindows::NSynchronization`): `CBaseEvent { IsCreated; Close; Set; Reset; Lock; }` (19-52), `CManualResetEvent { Create(bool initiallyOwn=false); CreateIfNotCreated_Reset(); }` (54-73), `CAutoResetEvent` (75-90), `CSemaphore { Create(init,max); OptCreateInit; Release([n]); Lock(); }` (138-163), `CCriticalSection { Enter(); Leave(); }` (165-173), `CCriticalSectionLock` RAII (175-182); POSIX-only `CSynchro` (pthread mutex+cond, 211-258) and the `*_WFMO` classes (261-380) that emulate `WaitForMultipleObjects` for the MT coders. All backed by `C/Threads.c`.
* **`Thread.h`**: `class NWindows::CThread { IsCreated(); WRes Close(); WRes Wait_Close(); WRes Create(THREAD_FUNC_TYPE startAddress, LPVOID param); Create_With_Affinity(...); Create_With_CpuSet(...); }` (12-42); `THREAD_FUNC_DECL`/`THREAD_FUNC_TYPE` = `void * (*)(void *)` on POSIX (`C/Threads.h:86-137`).
* **`ErrorMsg.h`**: `UString NWindows::NError::MyFormatMessage(DWORD errorCode)` / `(HRESULT)` (11-12). POSIX implementation `ErrorMsg.cpp:52-102`: known COM codes get fixed texts (`"E_ABORT : Operation aborted"`, `"E_OUTOFMEMORY : Can't allocate required memory"`, ...), `0x8008xxxx` (FACILITY_ERRNO) codes are unpacked to `errno` and rendered as `"errno=N : strerror"`, any other negative code becomes `"Error #XXXXXXXX"`. This is the string the console prints after `"System ERROR:"`; the app can map the same codes to `NSError`.
* **`DLL.h`** (not in 7zz, compiles clean): POSIX `typedef void *HMODULE` + `GetProcAddress` (8-13), `NDLL::CLibrary { Load(CFSTR) (dlopen RTLD_LOCAL|RTLD_NOW); Free(); }` (78-93), `MyGetModuleFileName(FString&)`, `GetModuleDirPrefix()` (97-99). Only needed if the app ever wants `Z7_EXTERNAL_CODECS` plug-ins.
* **`PropVariantUtils.h`** (in 7zz): flag/enum-to-text helpers used by handlers (`FlagsToString`, `TypeToString`, ...).

### 2.5 Callback protocols

All examples name the *concrete* classes the console and the Windows GUI use, so the macOS bridge can copy either.

#### 2.5.1 Open (password, volumes, progress, "not an archive")

Two ways to drive an open:

1. Through `CArchiveLink::Open2/Open3/Open_Strict(COpenOptions&, IOpenCallbackUI*)` (`OpenArchive.h:431-441`): `Open2` (`OpenArchive.cpp:3386-3425`) creates a `COpenCallbackImp`, sets `openCallbackSpec->Callback = callbackUI`, calls `Init2(dirPrefix, name)` (stats the file; `E_FAIL`/errno if missing), and after the open copies `PasswordWasAsked`, `VolumePaths` and `VolumesSize` into the link. This is what `Extract()`/`UpdateArchive()` do for the console and the GUI (`Extract.cpp:430`, `Update.cpp:1286`). Implement `IOpenCallbackUI` (console: `COpenCallbackConsole`, `OpenCallbackConsole.h:12-71`; GUI: `COpenArchiveCallback`, `FileManager/OpenCallback.h:16-67`, and `CExtractCallbackImp`/`CUpdateCallbackGUI` which also implement it).
2. Through the Agent: `IInFolderArchive::Open(inStream, filePath, arcFormat, &type, IArchiveOpenCallback*)`. Here the *caller* supplies the COM callback; the FM builds a `COpenCallbackImp` itself (`FileFolderPluginOpen.cpp:277-292`: `openCallbackSpec->Callback = &COpenArchiveCallback; Init2(dirPrefix, fileName)` or `SetSubArchiveName` for nested opens) and passes it as the `IProgress` of `IFolderManager::OpenFolderFile` (line 47), which QI's it back to `IArchiveOpenCallback` (`ArchiveFolderOpen.cpp:96-101`). The bridge should do the same: allocate a `COpenCallbackImp`, point its `Callback` at the app's `IOpenCallbackUI`, call `Init2`, and pass it to `CAgent::Open`. That gives multi-volume (`.001`, `.z01`, `.r00`...) and password support for free.

Calls the app's `IOpenCallbackUI` receives, in order:

* `Open_SetTotal(files, bytes)` / `Open_SetCompleted(files, bytes)` — either pointer can be NULL; handlers with many items report `files`, stream-scanning handlers report `bytes`. Console: `OpenCallbackConsole.cpp:20-66` picks whichever total is defined for the percent line. Every `Open_Set*` must return `E_ABORT` to cancel (`Open_CheckBreak` is polled from volume opens and `IProgress::SetCompleted`, `ArchiveOpenCallback.cpp:290-294, 395-402`).
* `Open_CryptoGetTextPassword(BSTR *password)` — only for encrypted headers (7z `-mhe`, RAR `-hp`, zip AES central dir...). Console (`OpenCallbackConsole.cpp:79-92`): closes the percent line, prompts once, caches `PasswordIsDefined`. GUI (`ExtractCallback.cpp:151-176`, `UpdateCallbackGUI.cpp:214-236`): shows `CPasswordDialog`, returns `E_ABORT` on Cancel. Return the string with `StringToBstr(Password, password)` (`MyCom.h:186-188`).
* `Open_Finished()` (only via `Open3`).

Result interpretation (`OpenArchive.h:424-441`): `S_OK` = opened (possibly with warnings: check `arcLink.Arcs[i].ErrorInfo.GetWarningFlags()/WarningMessage`, and `ErrorInfo.ErrorFormatIndex` for "opened as X although the extension says Y"); `S_FALSE` = not an archive / could not open the innermost level — `arcLink.NonOpen_ErrorInfo`, `NonOpen_ArcPath` describe the failed level, `Arcs` may still contain outer levels; `E_ABORT` = cancelled; other = I/O error (`MyFormatMessage`). The FM turns this into text in `GetFolderError` (`FileFolderPluginOpen.cpp:173-236`) using `IFolderArcProps` (`kpidPath`, `kpidType`, `kpidErrorType`, `kpidError`, `kpidErrorFlags` per level), the console in `CExtractCallbackConsole::OpenResult` (section 5.4). `CAgent::GetErrorMessage()` (`Agent.h:283-324`) produces the same multi-level text without a UI.

#### 2.5.2 Extract (ask overwrite, ask write, set operation result, message)

Engine side: `IInArchive::Extract` -> `CArchiveExtractCallback` (2.3) -> the app's `IFolderArchiveExtractCallback` (+ optional `IFolderArchiveExtractCallback2`, `ICryptoGetTextPassword`, `ICompressProgressInfo`, `IFolderExtractToStreamCallback`, `IArchiveRequestMemoryUseCallback`, all found by `QueryInterface` on the same object). The three concrete implementations to copy: console `CExtractCallbackConsole` (`ExtractCallbackConsole.h:87-209`), GUI `CExtractCallbackImp` (`FileManager/ExtractCallback.h:181-345`), and the smoke test in Appendix A (minimal).

Per archive (driver `Extract()` / `DecompressArchive()` in `Extract.cpp:36-250`, 278-583; the Agent paths skip the `IExtractCallbackUI` calls):

1. `IExtractCallbackUI::BeforeOpen(name, testMode)` (`Extract.cpp:387`), open (2.5.1), `OpenResult(codecs, arcLink, name, hr)` (436, 465).
2. `IProgress::SetTotal(packSize)` on the folder callback — total of all archives in the batch (`Extract.cpp:348, 514, 571`); the Agent sends `GetEstmatedPhySize()` (`Agent.cpp:1510-1511`).
3. Per item: `PrepareOperation(name, isFolder, askExtractMode, position)` (`ArchiveExtractCallback.cpp:2043`; `askExtractMode` is `NAskMode::kExtract/kTest/kSkip/kReadExternal`) — this is where the UI shows "Extracting <name>"; `AskOverwrite(...)` only when the file exists and mode is `kAsk` (1269-1275; the answer may switch the mode for the rest of the run: `kNoToAll -> kSkip`, `kYesToAll -> kOverwrite`, `kAutoRename -> kRename`; `kCancel -> E_ABORT`); `MessageError(text)` for any file-system failure (`SendMessageError*`, 584-628, text already formatted: `"<message> : <path>"` or with errno text); `SetOperationResult(opRes, encrypted)` at the end of each item (2889) — `opRes != kOK` is a per-item error (CRC, wrong password...), `encrypted` tells the UI to suggest "wrong password?"; `ReportExtractResult(opRes, encrypted, name)` (2917) for errors reported out-of-band by the handler.
4. `IProgress::SetCompleted(&value)` (445) and `ICompressProgressInfo::SetRatioInfo(&in, &out)` (454) arrive **from worker threads** interleaved with the above (see 4.4). Return `E_ABORT` from any of them to cancel; the engine unwinds and `Extract` returns `E_ABORT`.
5. `IExtractCallbackUI::ExtractResult(hr)` (250), `ThereAreNoFiles()` (169) when the censor matched nothing.

`IFolderOperationsExtractCallback::AskWrite(srcPath, srcIsFolder, srcTime, srcSize, destPathRequest, BSTR *destPathResult, Int32 *writeAnswer)` (`IFolder.h:61-68`) is used only by the **file-system** folder copy (`FSFolderCopy.cpp`) and by `CAgentFolder::CopyTo` indirectly via QI (`ArchiveFolder.cpp:37-41` needs the object to *also* be an `IFolderArchiveExtractCallback`); the FM implementation (`ExtractCallback.cpp:710-807`) shows the overwrite dialog and can return a renamed destination. On macOS, if the file-system side is native, `AskWrite/ShowMessage/SetCurrentFilePath/SetNumFiles` only need trivial implementations so the QI in `CopyTo` succeeds.

`SetExtractErrorMessage(opRes, encrypted, [name,] out)` — the canonical texts for `opRes` are in the console (`ExtractCallbackConsole.cpp:211-221, 417-463`): `Unsupported Method`, `CRC Failed`, `CRC Failed in encrypted file. Wrong password?`, `Data Error`, `Data Error in encrypted file. Wrong password?`, `Unavailable data`, `Unexpected end of data`, `There are some data after the end of the payload data`, `Is not archive`, `Headers Error`, `Wrong password`. The open-error flag texts are `k_ErrorFlagsMessages[]` (`ExtractCallbackConsole.cpp:223-236`, indexed by the `kpv_ErrorFlags_*` bit).

#### 2.5.3 Update (add / delete / rename / create folder)

Two drivers:

* `UpdateArchive(codecs, types, arcPath, censor, options, errorInfo, IOpenCallbackUI*, IUpdateCallbackUI2*, needSetPath)` (`Update.cpp:1123-...`) — the command-line/GUI "Add to archive" path. Sequence seen by `IUpdateCallbackUI2`: `StartOpenArchive(name)` (1284) -> open of the existing archive (`Open_Strict`, 1286) -> `OpenResult(...)` (1291); `StartScanning()` (1379) -> `IDirItemsCallback::ScanProgress(stat, path, isDir)` / `ScanError(path, errno)` during `EnumerateItems` (1397) -> `FinishScanning(stat)` (1409); optional `SetPassword`; `StartArchive(name, isUpdating)` (1582) -> `Compress()` (347-946): `SetNumItems(CArcToDoStat)` (617), `WriteSfx` (773), then `IOutArchive::UpdateItems` (853) which drives `IUpdateCallbackUI` through `CArchiveUpdateCallback`: `SetTotal`, `GetStream(name, isDir, isAnti, notifyOp)` before each file is opened (the "Compressing <name>" status), `OpenFileError/ReadingFileError(path, errno)` (non-fatal: the file is skipped and counted), `SetOperationResult(kOK)` per item, `ReportUpdateOperation(op, name, isDir)` for `kAdd/kUpdate/kAnalyze/kReplicate/kRepack/kSkip/kDelete/kHeader...`, `ReportExtractResult` when a re-packed item fails to decode, `SetCompleted/SetRatioInfo` from worker threads, `CryptoGetTextPassword2(&defined, &bstr)` when the format supports encryption (once), `ShowDeleteFile(name, isDir)` for `d`/`sync`; `FinishArchive(CFinishArchiveStat)` (1602); then the temp-file move: `MoveArc_Start(tempPath, arcPath, size, updateMode)` (1644), `MoveArc_Progress(total, current)` via `ICopyFileProgress` (1108), `MoveArc_Finish()` (1682); optionally `DeletingAfterArchiving(path, isDir)`/`FinishDeletingAfterArchiving()` for `-sdel`. `errorInfo` carries `Message/FileNames/SystemError` for the final report (`WarningsCheck`, section 5.4). `CheckBreak()` is polled between steps; return `E_ABORT`.
* The Agent path (`IOutFolderArchive`/`IFolderOperations`, 2.2): the app implements `IFolderArchiveUpdateCallback` (+ `IFolderArchiveUpdateCallback2`, `IFolderScanProgress`, `IFolderArchiveUpdateCallback_MoveArc`, `ICryptoGetTextPassword2`, `ICryptoGetTextPassword`, `IArchiveOpenCallback` (for the automatic `ReOpen`), `ICompressProgressInfo` — the FM's `CUpdateCallback100Imp`, `UpdateCallback100.h:16-47`, implements exactly this set with `Z7_COM_UNKNOWN_IMP_8`). `CUpdateCallbackAgent` translates the `IUpdateCallbackUI` calls above into `SetNumFiles`, `SetTotal/SetCompleted`, `SetRatioInfo`, `CompressOperation(name)`/`DeleteOperation(name)` (or `ReportUpdateOperation` if `Callback2` exists), `OperationResult(opRes)`, `UpdateErrorMessage(text)`, `OpenFileError/ReadingFileError(path, HRESULT)`, `ReportExtractResult`, `CryptoGetTextPassword[2]`. `FinishArchive`/`StartArchive` have no Agent equivalent; the move phase is reported through `IFolderArchiveUpdateCallback_MoveArc` (`ArchiveFolderOut.cpp:195-241`) and `Before_ArcReopen()` tells the app to clear its cancel flag so the reopen succeeds (`UpdateCallback100.cpp:124-128` -> `Sync.Clear_Stop_Status()`).

#### 2.5.4 Progress semantics (`ICompressProgressInfo`, `SetTotal/SetCompleted`, ratio)

* `IProgress::SetTotal(total)` is called at most once per operation before data flows; `SetCompleted(&completed)` repeatedly (may be NULL); units are whatever the handler chose (`IArchive.h:211-221`: unpacked bytes if `SetTotal` was called for extraction, packed otherwise; `Extract()` rescales to packed bytes across a batch). Percent = `completed * 100 / total` with `total` unknown -> show MiB (`PercentPrinter.cpp:58-79`).
* `ICompressProgressInfo::SetRatioInfo(&inSize, &outSize)` is a second channel with the coder's own in/out counters; the GUI shows "Processed/Packed/Ratio" from it (`CProgressSync::Set_Ratio`, `ProgressDialog2.cpp:176-183`). Either pointer may be NULL. The console ignores it for extraction (`SetRatioInfo` -> `CheckBreak2()`, `UpdateCallbackConsole.cpp:620-623`).
* File counters: `SetNumFiles(n)` (Agent) / `SetNumItems(stat)` (update) / the FM counts `SetOperationResult` calls (`ExtractCallback.cpp:390-395`).
* The FM's thread-safe hand-off object is `CProgressSync` (`ProgressDialog2.h:32-103`, implementation `ProgressDialog2.cpp:80-260`): every setter takes `_cs`, stores the value, and returns `CheckStop()` which returns `E_ABORT` when `_stopped`, and **blocks in a 100 ms sleep loop while `_paused`** (100-110) — that is how Pause works: the worker thread parks inside the callback. `AddError_Message/_Name/_Code_Name` (222-250) accumulate the error list shown at the end. A Swift/ObjC++ equivalent is a class with an `os_unfair_lock`, the same fields, a cancel flag and a pause condition, polled by a timer on the main thread — see 4.4.

#### 2.5.5 Hashing

`HashCalc(censor, options, errorInfo, IHashCallbackUI*)` (`HashCalc.cpp:466-671`): `StartScanning()` (485) -> `EnumerateItems` with `ScanProgress/ScanError` (494) -> `FinishScanning(stat)` (505) -> `SetNumFiles` (518) -> `SetTotal(totalSize)` (523) -> `BeforeFirstFile(hb)` (533) -> per file: `GetStream(path, isDir)` (615), `OpenFileError(path, errno)` (591), `SetCompleted(&done)` (627, 657), `SetOperationResult(fileSize, hb, showHash)` (656; `hb.Hashers[i].Digests[k_HashCalc_Index_Current]` holds the file digest, `WriteToString` renders it) -> `AfterLastFile(hb)` (671) where `hb.Hashers[i].Digests[k_HashCalc_Index_DataSum/NamesSum/StreamsSum]` are the aggregate sums. `CHashBundle::SetMethods({"CRC32","SHA256",...})` selects hashers (`HashCalc.cpp:47-...`; names are matched case-insensitively against the registered hashers, `*` = all). Result presentation: console `PrintHashStat` (`HashCon.cpp:371-383`: `"<NAME> for data:              <hex>"`, `"for data and names:"`, `"for streams and names:"`), GUI `AddHashBundleRes` (`HashGUI.cpp:179-231`: pairs `Name/Files/Folders/Size/<NAME> for data/...`). Extraction can hash on the fly: pass a `CHashBundle*` as `IHashCalc*` to `Extract()` (`Extract.h:113`) or `SetHashMethods` on `CArchiveExtractCallback`; the digests are then in the bundle after `Extract` returns (the console prints them with `PrintHashStat`, `Main.cpp:1506-1510`).

---
## 3. Portability audit

### 3.1 Method

For each of the 199 `.cpp` files in the audited directories two compiles were run with
`DEVELOPER_DIR=/Applications/Xcode.app` (Apple clang 21.0.0 / macOS 26 SDK), no `-I`:

* **strict**: `clang++ -arch arm64 -O2 -c -Werror -Wall -Wextra -Weverything -Wfatal-errors -Wno-poison-system-directories -DNDEBUG -D_REENTRANT -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -fPIC -std=c++11 -o x.o file.cpp` (the exact 7zz line);
* **lax**: same with `-w` instead of the warning flags (so that *all* errors are reported, not only the first).

Categories: **(a)** compiled into 7zz on macOS today; **(b)** portable as-is — compiles clean in *strict* mode although not part of 7zz; **(c)** needs small `#ifdef _WIN32`/`__APPLE__` work (the exact offending symbols are listed); **(d)** Win32-only UI/OS code to be reimplemented in Swift/AppKit (or simply not needed).

Summary (strict-pass = lax-pass in every case except the two `StdAfx.cpp` files that trip `-Wundef` on `_MSC_VER`):

| Directory | files | compile clean | fail |
|---|---|---|---|
| `CPP/7zip/UI/Agent` | 7 | 1 (`AgentProxy.cpp`) | 6 -> all fixed by the patch in 4.2 (then 7/7 strict-clean) |
| `CPP/7zip/UI/Common` | 25 | 22 | 3 (`CompressCall.cpp`, `CompressCall2.cpp`, `ZipRegistry.cpp`) |
| `CPP/7zip/UI/Console` | 12 | 12 | 0 |
| `CPP/7zip/UI/FileManager` | 67 | 5 | 62 |
| `CPP/7zip/UI/GUI` | 10 | 0 (+1 `StdAfx.cpp` lax-only) | 10 |
| `CPP/7zip/UI/Explorer` | 5 | 0 (+1 `StdAfx.cpp` lax-only) | 5 |
| `CPP/Common` | 35 | 35 | 0 |
| `CPP/Windows` | 32 | 16 | 16 |
| `CPP/Windows/Control` | 6 | 0 | 6 |
| **total** | **199** | **91** (+2) | **106** |

### 3.2 `CPP/7zip/UI/Agent/` — category (c) as-is, (b) after the patch

| File | Result | Offending symbols (lax compile) |
|---|---|---|
| `Agent.h` | (c) | `INVALID_FILE_ATTRIBUTES` (260, only defined in `C/7zWindows.h`), `HMODULE` in `CCodecIcons::LoadIcons` (342; `HMODULE` is only typedef'd by `Windows/DLL.h`, which `Agent.h` does not include) |
| `Agent.cpp` | (c) | header errors + `NFile::NName::IsAltStreamPrefixWithColon` (1520, Windows-only declaration), `CFileInfo::Attrib` (1647), `CFileInfo::IsDevice` (1648, 1694) |
| `AgentOut.cpp` | (c) | header errors + `IsAltStreamPrefixWithColon` (285), `CDirItem::IsAltStream` (297), `CDirItem::Attrib` (568), `FILETIME -> timespec` assignment (578: `di.CTime = ... = ft` with a `FILETIME`) |
| `AgentProxy.cpp` | **(b)** | strict-clean |
| `ArchiveFolder.cpp` | (c) | header errors only |
| `ArchiveFolderOpen.cpp` | (c) | `HINSTANCE` (13, and via `Windows/ResourceString.h:12`), `MyLoadString(HMODULE, ...)` (20): the codec-icon table is loaded from a Win32 string resource (`kIconTypesResId = 100`) |
| `ArchiveFolderOut.cpp` | (c) | header errors + `NFind::CDirEntry::IsDir()` (47, POSIX `CDirEntry` has no `IsDir`), `SetFileAttrib` (61, Windows-only) |
| `UpdateCallbackAgent.cpp` | (c) | `UINT64` (39, 46 — Windows typedef; the engine type is `UInt64`) |

With the patch of section 4.2 applied in an overlay, all 7 files compile clean in **strict** mode and link/run (Appendix A).

### 3.3 `CPP/7zip/UI/Common/`

| File | Category | Notes |
|---|---|---|
| `ArchiveCommandLine.cpp`, `ArchiveExtractCallback.cpp`, `ArchiveOpenCallback.cpp`, `Bench.cpp`, `DefaultName.cpp`, `EnumDirItems.cpp`, `Extract.cpp`, `ExtractingFilePath.cpp`, `HashCalc.cpp`, `LoadCodecs.cpp`, `OpenArchive.cpp`, `PropIDUtils.cpp`, `SetProperties.cpp`, `SortUtils.cpp`, `TempFiles.cpp`, `Update.cpp`, `UpdateAction.cpp`, `UpdateCallback.cpp`, `UpdatePair.cpp`, `UpdateProduce.cpp` | (a) | in 7zz |
| `ArchiveName.cpp` | (b) | strict-clean; the drive-letter special case is already `#if defined(_WIN32)` (69-76) |
| `WorkDir.cpp` | (b) | strict-clean (removable-drive check is `_WIN32`-only, 18-37); **links only if `NWorkDir::CInfo::Load/Save` are provided** (they live in `ZipRegistry.cpp`) |
| `ZipRegistry.cpp` | (d) | 100% `NWindows::NRegistry::CKey` / `HKEY_CURRENT_USER\Software\7-Zip\{Extraction,Compression,Options,...}` (20-35, 91-101, 203-223). The header is portable; reimplement the `Save()/Load()` bodies over `NSUserDefaults`/a plist (4.3) |
| `CompressCall.cpp` | (d) | spawns `7zG.exe` with a file-mapping for the file list (`CreateFileMapping/MapViewOfFile`, `Psapi.h`, `SE_LOCK_MEMORY_NAME`); the out-of-process model has no macOS equivalent worth keeping |
| `CompressCall2.cpp` | (d) | the in-process model: `CompressFiles/ExtractArchives/TestArchives/CalcChecksum/Benchmark` calling `UpdateGUI/ExtractGUI/HashCalcGUI/Benchmark dialog` (`#include "../../UI/GUI/*.h"`, 13-18). Fails only through those Win32 dialog headers. Its *logic* (how it fills `CUpdateOptions`, `CExtractOptions`, `NWildcard::CCensor` and loads codecs, 90-303) is the blueprint for the ObjC++ bridge |

### 3.4 `CPP/7zip/UI/Console/` — all 12 files are (a). They are a behavioural reference (section 5), not something the app links.

### 3.5 `CPP/7zip/UI/FileManager/`

Only five files compile clean; everything else pulls `Windows/Window.h` (`LRESULT/ATOM/HWND/RegisterClass...`), `Windows/Control/*.h` (`CommCtrl.h`), `Windows/Registry.h` (`HKEY`), `Windows/ResourceString.h` (`HINSTANCE`) or a Windows SDK header.

| File | Category | Notes / Win32 usage |
|---|---|---|
| `StringUtils.cpp` (`SplitStringToTwoStrings`), `TextPairs.cpp` (`CPairsStorage` — the archive comment "id=value" store), `ProgramLocation.cpp` (empty), `StdAfx.cpp`, `RegistryPlugins.cpp` (compiles but is about `7-Zip\Plugins` DLLs; unused) | (b) | strict-clean |
| `SplitUtils.cpp/.h` | (c) | only `AddVolumeItems(NControl::CComboBox&)` and the `k_Sizes[]` table it uses are Win32; `ParseVolumeSizes` / `GetNumberOfVolumes` are pure. Patch = wrap those in `#ifdef _WIN32` (4.2) -> strict-clean |
| `FormatUtils.cpp` (`NumberToString`, `MyFormatNew(format, arg)`, `MyFormatNew(UINT resId, arg)`), `PropertyName.cpp` (`GetNameOfProperty(propID, name)` -> `LangString(1000 + propID)`) | (c) | fail only because `LangUtils.h` includes `Windows/ResourceString.h` whose second overload takes `HINSTANCE`. With that overload guarded (4.2) both compile strict-clean; at link time they need `MyLoadString(UINT[, UString&])` from the app (string table -> `NSLocalizedString`) |
| `LangUtils.cpp` | (d)/(c) | half portable: `LangOpen`, `GetLangDirPrefix`, `LoadLangOneTime`, `LangString*`, `FindShortNames`, `Lang_GetShortNames_for_DefaultLang` use `CLang` (`Common/Lang.cpp`, portable) + `MyLoadString`; the rest is `HWND`/`SetDlgItemText` (49-135), `GetSystemDefaultLangID/GetUserDefaultLangID/LANGID/PRIMARYLANGID` (242-277), `ReadRegLang` (311). Reimplement `LangString(UInt32)` natively; optionally keep `CLang` to load 7-Zip `.txt` translations |
| `ExtractCallback.cpp` (`CExtractCallbackImp` — the GUI's `IFolderArchiveExtractCallback/IExtractCallbackUI/IOpenCallbackUI/IFolderOperationsExtractCallback/IFolderExtractToStreamCallback` implementation) | (d) | `COverwriteDialog`, `CPasswordDialog`, `CMemDialog`, `CProgressDialog`, `LangString` throughout. Logic to port: `AskOverwrite` mapping (201-233), `PrepareOperation` status texts (235-251), `SetOperationResult/ReportExtractResult` (375-413), `OpenResult/ExtractResult` (621-674), `SetExtractErrorMessage` (277-373, the `IDS_EXTRACT_MSG_*` texts), `CVirtFileSystem` in-memory extraction (`ExtractCallback.h:72-175`, `.cpp` `FlushToDisk`, `GetStream7`, 844-1010) |
| `UpdateCallback100.cpp` (`CUpdateCallback100Imp`) | (d) | pure forwarding to `CProgressDialog::Sync` + `ShowAskPasswordDialog`; 147 lines, trivially re-expressed in ObjC++ |
| `ProgressDialog2.cpp` | (d) | Win32 modal dialog + timer; **`CProgressSync` (80-260) and `CProgressThreadVirt::Process` (1432-1475) are the portable core** (see 4.4) |
| `OpenCallback.cpp/.h` (`COpenArchiveCallback : IOpenCallbackUI`) | (d) | `HWND ParentWindow`, `CProgressDialog`; the `IOpenCallbackUI` part is 30 lines |
| `FileFolderPluginOpen.cpp` (`CFfpOpen::OpenFileFolderPlugin`) | (d) | the FM "open archive" flow (thread + progress dialog + `GetFolderError`); the flow itself is documented in 2.5.1 and reproduced by the smoke test |
| `FSFolder.cpp/.h`, `FSFolderCopy.cpp` | (d) | `winternl.h`/`NtQueryInformationFile`, `CopyFileW/CopyProgressRoutine`, `GetModuleHandle`, `FILE_ATTRIBUTE_*`, `CFindChangeNotification`, compressed size via `GetCompressedFileSize`. This is the *file-system* `IFolderFolder`; on macOS the file-system browser should be native (FileManager/NSURL), so nothing to port. `FSFolder.h:191-218` (`CCopyStateIO`, `CopyFileSystemItems`) is also Win32 |
| `FSDrives.cpp`, `RootFolder.cpp`, `NetFolder.cpp`, `AltStreamsFolder.cpp` | (d) | drive letters (`GetLogicalDrives`, `SHGetFileInfo`), `ShlObj.h`, WNet, NTFS alt streams |
| `PanelCrc.cpp` | (d) | `CDirEnumerator` (29-160) + `CThreadCrc : CProgressThreadVirt` hashing selected panel items; the app should call `HashCalc()` (2.5.5) instead — same engine, no panel coupling |
| `ViewSettings.cpp`, `RegistryUtils.cpp`, `RegistryAssociations.cpp` | (d) | `NRegistry::CKey` everywhere (`Software\7-Zip\FM`, `\Options`, `\Associations`); reimplement over `NSUserDefaults` |
| `SysIconUtils.cpp`, `HelpUtils.cpp`, `MyLoadMenu.cpp`, `EnumFormatEtc.cpp`, `PanelDrag.cpp`, `ClassDefs.cpp`, `FilePlugins.cpp` | (d) | shell icons (`SHGetFileInfo`, `CommCtrl.h`), HtmlHelp, menus, OLE drag & drop (`FORMATETC/IEnumFORMATETC`), `ShObjIdl.h` |
| `Panel*.cpp`, `App.cpp`, `FM.cpp`, `*Dialog*.cpp`, `*Page.cpp`, `VerCtrl.cpp`, `MessagesDialog.cpp`, `ListViewDialog.cpp`, `MemDialog.cpp`, `OverwriteDialog.cpp`, `PasswordDialog.cpp`, `ProgressDialog.cpp`, `SplitDialog.cpp`, `CopyDialog.cpp`, `ComboDialog.cpp`, `EditDialog.cpp`, `LinkDialog.cpp`, `BrowseDialog*.cpp`, `AboutDialog.cpp`, `LangPage.cpp`, `MenuPage.cpp`, `SettingsPage.cpp`, `SystemPage.cpp`, `FoldersPage.cpp`, `EditPage.cpp`, `OptionsDialog.cpp` | (d) | the Win32 UI proper (`windowsx.h`, `ShlObj.h`, `CommCtrl.h`, `prsht.h`, `TlHelp32.h`, `Shlwapi.h`); AppKit replaces all of it |

### 3.6 `CPP/7zip/UI/GUI/` and `CPP/7zip/UI/Explorer/`

| File | Category | Notes |
|---|---|---|
| `ExtractGUI.cpp/.h` | (d) | `ExtractGUI(codecs, formatIndices, excludedFormatIndices, archivePaths, archivePathsFull, wildcardCensor, CExtractOptions&, CHashBundle *hb, showDialog, bool &messageWasDisplayed, CExtractCallbackImp*, HWND)` (`ExtractGUI.h:22-37`): shows `CExtractDialog`, normalises `OutputDir`, then `CThreadExtracting : CProgressThreadVirt` whose `ProcessVirt` (101-165) is just `Extract(...)` + result formatting. Port = the 65 lines of `ProcessVirt` |
| `UpdateGUI.cpp/.h` | (d) | `UpdateGUI(codecs, formatIndices, cmdArcPath, censor, CUpdateOptions&, showDialog, messageWasDisplayed, CUpdateCallbackGUI*, HWND)` (`UpdateGUI.h:22-31`): `ShowDialog` (315-541) maps `CCompressDialog` fields to `CUpdateOptions` (`SetOutProperties`, 205-282, is the **level/dictionary/threads/solid/encryption -> `-m` property** encoder worth copying), `CThreadUpdating::ProcessVirt` (51-64) = `UpdateArchive(...)` |
| `HashGUI.cpp/.h` | (d) | `HashCalcGUI(censor, CHashOptions&, bool &messageWasDisplayed)` (`HashGUI.h:9-13`) = `CHashCallbackGUI : CProgressThreadVirt, IHashCallbackUI` (25-56, 77-157) + `AddHashBundleRes` (179-254) |
| `UpdateCallbackGUI.cpp/.h`, `UpdateCallbackGUI2.cpp/.h` | (d) | `CUpdateCallbackGUI : IOpenCallbackUI, IUpdateCallbackUI2` (`UpdateCallbackGUI.h:11-30`) — all methods forward to `CProgressDialog::Sync` (`UpdateCallbackGUI.cpp:23-295`); `CUpdateCallbackGUI2` (`UpdateCallbackGUI2.h:8-53`) holds password state, `NumFiles`, the `k_UpdNotifyLangs[]` status strings and `MoveArc_*_Base` |
| `GUI.cpp`, `CompressDialog.cpp`, `ExtractDialog.cpp`, `BenchmarkDialog.cpp` | (d) | `7zG.exe` main + dialogs (`Shlwapi.h`, `CommCtrl.h`). `BenchmarkDialog.cpp` contains the only GUI wrapper around `Bench()`; re-do it over `IBenchCallback/IBenchPrintCallback` |
| `Explorer/*` | (d) | shell extension (`OleCtl.h`, menus, registry) |

### 3.7 `CPP/Windows/` and `CPP/Windows/Control/`

| File | Category | Notes |
|---|---|---|
| `ErrorMsg`, `FileDir`, `FileFind`, `FileIO`, `FileLink`, `FileName`, `PropVariant`, `PropVariantConv`, `PropVariantUtils`, `Synchronization`, `System`, `SystemInfo`, `TimeUtils` (13) | (a) | in 7zz; Apple specifics already handled (`System.cpp:303-381` sysctl RAM/CPU, `SystemInfo.cpp:19-20, 477` sysctl CPU name, `FileFind.cpp:1147-...` `st_ctimespec`, `FileDir.cpp:1162` `getcwd(NULL,0)`) |
| `DLL.cpp`, `COM.cpp` (empty on POSIX), `FileSystem.cpp` (body is `_WIN32`-only) | (b) | strict-clean, not needed |
| `Clipboard.cpp` (`HWND/HGLOBAL`, `ShlObj.h`), `CommonDialog.cpp` (`GetOpenFileName`), `Console.cpp` (`ReadConsoleInput`...), `FileMapping.cpp`, `MemoryGlobal.cpp` (`GlobalAlloc`), `MemoryLock.cpp` (`SE_LOCK_MEMORY_NAME`, large pages), `Menu.cpp` (`HMENU`), `NationalTime.cpp` (`GetTimeFormat/LCID` — replace with `DateFormatter`), `Net.cpp` (`WNetOpenEnum`), `ProcessMessages.cpp` (`PeekMessage`), `ProcessUtils.cpp` (`Psapi.h`, `CreateProcess` — replace with `NSWorkspace`/`Process`), `Registry.cpp`, `ResourceString.cpp` (`LoadStringW`), `SecurityUtils.cpp` (`NTSecAPI.h`), `Shell.cpp` (`ShlObj.h`, `SHBrowseForFolder`, `IDList`), `Window.cpp` (16) | (d) | pure Win32 |
| `Control/ComboBox.cpp`, `Dialog.cpp`, `ImageList.cpp`, `ListView.cpp`, `PropertyPage.cpp`, `Window2.cpp` (6) | (d) | `CommCtrl.h`/`prsht.h` wrappers |

### 3.8 `CPP/Common/` — all 35 compile strict-clean; 30 are in 7zz, the other five (`C_FileIO.cpp`, `CksumReg.cpp` (`cksum` hasher, needed only for `-scrc*`), `Lang.cpp` (`CLang` 7-Zip `.txt` language files), `Random.cpp`, `TextConfig.cpp`) are (b).

### 3.9 Missing-header inventory (what the Win32-only files pull in)

`winternl.h` (FSFolder), `windowsx.h` (Panel, BrowseDialog2), `ShlObj.h`/`ShObjIdl.h` (RootFolder, PanelKey/Items/Menu/Sort, SystemPage, BrowseDialog, ClassDefs, Shell, Clipboard), `CommCtrl.h` (all Control/* users), `prsht.h` (property pages), `Shlwapi.h` (FM.cpp, GUI.cpp), `TlHelp32.h` (PanelItemOpen), `HtmlHelp.h` (HelpUtils), `Psapi.h` (ProcessUtils, CompressCall, ContextMenu), `NTSecAPI.h` (SecurityUtils), `OleCtl.h` (DllExportsExplorer). None of these have a macOS analogue that is worth emulating; the files that include them are all (d).

---
## 4. Recommendation

### 4.1 `SevenZipCore` static library — proposed source list

Take the 7zz list of 1.4 **minus the 11 `CPP/7zip/UI/Console/*.cpp`**, i.e. 312 TUs:
1 `.S` + 53 `.c` + 30 `CPP/Common` + 13 `CPP/Windows` + 24 `CPP/7zip/Common` + 107
`CPP/7zip/Archive` + 50 `CPP/7zip/Compress` + 14 `CPP/7zip/Crypto` + 20 `CPP/7zip/UI/Common`
(keep `ArchiveCommandLine.cpp`, `Bench.cpp`, `StdInStream.cpp`, `StdOutStream.cpp`,
`CommandLineParser.cpp`, `ListFileUtils.cpp`: they are small, portable and `ArchiveCommandLine`
gives you the `-m`/`-t`/`-ao` semantics for free), **plus**:

| Add | Why |
|---|---|
| `CPP/7zip/UI/Agent/Agent.cpp`, `AgentOut.cpp`, `AgentProxy.cpp`, `ArchiveFolder.cpp`, `ArchiveFolderOpen.cpp`, `ArchiveFolderOut.cpp`, `UpdateCallbackAgent.cpp` (with the patch of 4.2) | the archive-as-folder model (`IFolderFolder`), item properties, extract/test of selections, in-archive edits |
| `CPP/7zip/UI/Common/WorkDir.cpp` | temp-file/move logic used by the Agent's update path |
| `CPP/7zip/UI/Common/ArchiveName.cpp` | default archive names for "Add to archive" |
| `CPP/7zip/UI/FileManager/StringUtils.cpp`, `TextPairs.cpp`, `SplitUtils.cpp` (patched) | tiny portable helpers (`TextPairs` is the zip-comment "key=value" store used by `CAgentFolder::SetProperty(kpidComment)`) |
| `CPP/7zip/UI/FileManager/FormatUtils.cpp`, `PropertyName.cpp` (needs the `ResourceString.h` guard) | optional: `GetNameOfProperty(propID)` column titles / `MyFormatNew`; they only need `MyLoadString(UINT)` from the app |
| `CPP/Common/Lang.cpp` | optional: read 7-Zip `Lang/*.txt` translations with `CLang` |
| `CPP/Common/CksumReg.cpp` | optional: the `CKSUM` hasher |
| one new TU owned by the app, e.g. `Mac/Core/SevenZipCoreMac.cpp` | `#include "CPP/Common/MyInitGuid.h"` exactly once (defines every `IID_*`; the console does this in `Console/Main.cpp:44`, the FM in `FileManager/ClassDefs.cpp:7`), plus the platform-provided symbols of 4.3 |

Compile the library exactly as 1.2/1.3 says. No `-I` paths are required for the engine files.
For app files that include engine headers from outside the tree, either use repository-relative
includes (`#include "../../CPP/7zip/UI/Agent/Agent.h"`) or add
`-I$(SRCROOT)/CPP/7zip/UI/Agent -I$(SRCROOT)/CPP/Windows` (the pattern used by the smoke test —
the engine headers' own relative includes are resolved relative to the *header's* directory, so
this works).

Do **not** add: `CompressCall.cpp`/`CompressCall2.cpp`, `ZipRegistry.cpp`, any
`FileManager/*` or `GUI/*` beyond the files above, `Windows/Registry.cpp`,
`Windows/ResourceString.cpp`, `Windows/Control/*`, `Windows/DLL.cpp` (unless
`Z7_EXTERNAL_CODECS`).

### 4.2 Minimal upstream patches (verified: strict-clean compile + link + run)

The complete unified diff is reproduced here (it is also at
`scratchpad/ovl/agent_mac.patch`). Every hunk is a pure `#ifdef _WIN32` split or a
Windows-typedef fix; behaviour on Windows is unchanged.

```diff
--- a/CPP/7zip/UI/Agent/Agent.h
+++ b/CPP/7zip/UI/Agent/Agent.h
@@ -15,6 +15,10 @@
 
 #include "AgentProxy.h"
 #include "IFolderArchive.h"
+
+#ifndef INVALID_FILE_ATTRIBUTES
+#define INVALID_FILE_ATTRIBUTES ((DWORD)-1)
+#endif
 
 extern CCodecs *g_CodecsObj;
 HRESULT LoadGlobalCodecs();
@@ -329,6 +333,7 @@
 
 // #ifdef NEW_FOLDER_INTERFACE
 
+#ifdef _WIN32
 struct CCodecIcons
 {
   struct CIconPair
@@ -342,14 +347,17 @@
   void LoadIcons(HMODULE m);
   bool FindIconIndex(const UString &ext, int &iconIndex) const;
 };
+#endif // _WIN32
 
 
 Z7_CLASS_IMP_COM_1(
   CArchiveFolderManager
   , IFolderManager
 )
+#ifdef _WIN32
   CObjectVector<CCodecIcons> CodecIconsVector;
   CCodecIcons InternalIcons;
+#endif
   bool WasLoaded;
 
   void LoadFormats();
--- a/CPP/7zip/UI/Agent/Agent.cpp
+++ b/CPP/7zip/UI/Agent/Agent.cpp
@@ -1517,7 +1517,10 @@
   {
     pathU = us2fs(path);
     if (!pathU.IsEmpty()
-      && !NFile::NName::IsAltStreamPrefixWithColon(path))
+      #ifdef _WIN32
+      && !NFile::NName::IsAltStreamPrefixWithColon(path)
+      #endif
+      )
     {
       NFile::NName::NormalizeDirPathPrefix(pathU);
       NFile::NDir::CreateComplexDir(pathU);
@@ -1644,8 +1647,13 @@
       return GetLastError_noZero_HRESULT();
     if (fi.IsDir())
       return E_FAIL;
+   #ifdef _WIN32
     _attrib = fi.Attrib;
     _isDeviceFile = fi.IsDevice;
+   #else
+    _attrib = fi.GetWinAttrib();
+    _isDeviceFile = S_ISCHR(fi.mode) || S_ISBLK(fi.mode);
+   #endif
     FString dirPrefix, fileName;
     if (NFile::NDir::GetFullPathAndSplit(us2fs(_archiveFilePath), dirPrefix, fileName))
     {
@@ -1691,7 +1699,7 @@
     if (!inStream)
     {
       arc.MTime.Set_From_FiTime(fi.MTime);
-      arc.MTime.Def = !fi.IsDevice;
+      arc.MTime.Def = !_isDeviceFile;
     }
     
     ArchiveType = GetTypeOfArc(arc);
--- a/CPP/7zip/UI/Agent/AgentOut.cpp
+++ b/CPP/7zip/UI/Agent/AgentOut.cpp
@@ -282,13 +282,18 @@
 
   {
     FString folderPrefix = _folderPrefix;
+   #ifdef _WIN32
     if (!NFile::NName::IsAltStreamPrefixWithColon(fs2us(folderPrefix)))
+   #endif
       NFile::NName::NormalizeDirPathPrefix(folderPrefix);
     
     RINOK(dirItems.EnumerateItems2(folderPrefix, _updatePathPrefix, _names, requestedPaths))
 
     if (_updatePathPrefix_is_AltFolder)
     {
+     #ifndef _WIN32
+      return E_NOTIMPL;
+     #else
       FOR_VECTOR(i, dirItems.Items)
       {
         CDirItem &item = dirItems.Items[i];
@@ -296,6 +301,7 @@
           return E_NOTIMPL;
         item.IsAltStream = true;
       }
+     #endif
     }
   }
 
@@ -565,7 +571,11 @@
 
   CDirItem di;
 
+ #ifdef _WIN32
   di.Attrib = FILE_ATTRIBUTE_DIRECTORY;
+ #else
+  di.SetAsDir();
+ #endif
   di.Size = 0;
   if (_proxy2)
     di.Name = _proxy2->GetDirPath_as_Prefix(_agentFolder->_proxyDirIndex /* , isAltStreamFolder */);
@@ -573,8 +583,8 @@
     di.Name = _proxy->GetDirPath_as_Prefix(_agentFolder->_proxyDirIndex);
   di.Name += folderName;
 
-  FILETIME ft;
-  NTime::GetCurUtcFileTime(ft);
+  CFiTime ft;
+  NTime::GetCurUtc_FiTime(ft);
   di.CTime = di.ATime = di.MTime = ft;
 
   dirItems.Items.Add(di);
--- a/CPP/7zip/UI/Agent/ArchiveFolderOut.cpp
+++ b/CPP/7zip/UI/Agent/ArchiveFolderOut.cpp
@@ -44,7 +44,11 @@
           return false;
         if (!found)
           break;
+       #ifdef _WIN32
         if (fileInfo.IsDir())
+       #else
+        if (enumerator.DirEntry_IsDir(fileInfo, false))
+       #endif
           names.Add(fileInfo.Name);
       }
     }
@@ -57,9 +61,11 @@
     if (!res)
       return false;
   }
+ #ifdef _WIN32
   // we clear read-only attrib to remove read-only dir
   if (!SetFileAttrib(path, 0))
     return false;
+ #endif
   return RemoveDir(path);
 }
 
--- a/CPP/7zip/UI/Agent/UpdateCallbackAgent.cpp
+++ b/CPP/7zip/UI/Agent/UpdateCallbackAgent.cpp
@@ -36,14 +36,14 @@
 }
 
 
-HRESULT CUpdateCallbackAgent::SetTotal(UINT64 size)
+HRESULT CUpdateCallbackAgent::SetTotal(UInt64 size)
 {
   if (Callback)
     return Callback->SetTotal(size);
   return S_OK;
 }
 
-HRESULT CUpdateCallbackAgent::SetCompleted(const UINT64 *completeValue)
+HRESULT CUpdateCallbackAgent::SetCompleted(const UInt64 *completeValue)
 {
   if (Callback)
     return Callback->SetCompleted(completeValue);
--- a/CPP/7zip/UI/Agent/ArchiveFolderOpen.cpp
+++ b/CPP/7zip/UI/Agent/ArchiveFolderOpen.cpp
@@ -6,10 +6,13 @@
 
 #include "../../../Common/StringToInt.h"
 #include "../../../Windows/DLL.h"
+#ifdef _WIN32
 #include "../../../Windows/ResourceString.h"
+#endif
 
 #include "Agent.h"
 
+#ifdef _WIN32
 extern HINSTANCE g_hInstance;
 static const UINT kIconTypesResId = 100;
 
@@ -58,6 +61,7 @@
   }
   return false;
 }
+#endif // _WIN32
 
 
 void CArchiveFolderManager::LoadFormats()
@@ -67,6 +71,7 @@
 
   LoadGlobalCodecs();
 
+ #ifdef _WIN32
   #ifdef Z7_EXTERNAL_CODECS
   CodecIconsVector.Clear();
   FOR_VECTOR (i, g_CodecsObj->Libs)
@@ -76,6 +81,7 @@
   }
   #endif
   InternalIcons.LoadIcons(g_hInstance);
+ #endif // _WIN32
   WasLoaded = true;
 }
 
@@ -151,6 +157,7 @@
 }
 */
 
+#ifdef _WIN32
 static void AddIconExt(const CCodecIcons &lib, UString &dest)
 {
   FOR_VECTOR (i, lib.IconPairs)
@@ -161,11 +168,14 @@
 }
 
 
+#endif
+
 Z7_COM7F_IMF(CArchiveFolderManager::GetExtensions(BSTR *extensions))
 {
   *extensions = NULL;
   LoadFormats();
   UString res;
+ #ifdef _WIN32
   
   #ifdef Z7_EXTERNAL_CODECS
   /*
@@ -179,6 +189,17 @@
   AddIconExt(
       // g_CodecsObj->
       InternalIcons, res);
+ #else
+  FOR_VECTOR (i, g_CodecsObj->Formats)
+  {
+    const CObjectVector<CArcExtInfo> &exts = g_CodecsObj->Formats[i].Exts;
+    FOR_VECTOR (k, exts)
+    {
+      res.Add_Space_if_NotEmpty();
+      res += exts[k].Ext;
+    }
+  }
+ #endif
 
   return StringToBstr(res, extensions);
 }
@@ -189,7 +210,9 @@
   *iconPath = NULL;
   *iconIndex = 0;
   LoadFormats();
-
+ #ifndef _WIN32
+  UNUSED_VAR(ext)
+ #else
   #ifdef Z7_EXTERNAL_CODECS
   // FOR_VECTOR (i, g_CodecsObj->Libs)
   FOR_VECTOR (i, CodecIconsVector)
@@ -214,6 +237,7 @@
       return StringToBstr(fs2us(path), iconPath);
     }
   }
+ #endif // _WIN32
   return S_OK;
 }
 
--- a/CPP/7zip/UI/FileManager/SplitUtils.h
+++ b/CPP/7zip/UI/FileManager/SplitUtils.h
@@ -6,10 +6,14 @@
 #include "../../../Common/MyTypes.h"
 #include "../../../Common/MyString.h"
 
+#ifdef _WIN32
 #include "../../../Windows/Control/ComboBox.h"
+#endif
 
 bool ParseVolumeSizes(const UString &s, CRecordVector<UInt64> &values);
+#ifdef _WIN32
 void AddVolumeItems(NWindows::NControl::CComboBox &volumeCombo);
+#endif
 UInt64 GetNumberOfVolumes(UInt64 size, const CRecordVector<UInt64> &volSizes);
 
 #endif
--- a/CPP/7zip/UI/FileManager/SplitUtils.cpp
+++ b/CPP/7zip/UI/FileManager/SplitUtils.cpp
@@ -58,6 +58,8 @@
 }
 
 
+
+#ifdef _WIN32
 static const char * const k_Sizes[] =
 {
     "10M"
@@ -78,6 +80,8 @@
     combo.AddString(CSysString(k_Sizes[i]));
 }
 
+#endif
+
 UInt64 GetNumberOfVolumes(UInt64 size, const CRecordVector<UInt64> &volSizes)
 {
   if (size == 0 || volSizes.Size() == 0)
--- a/CPP/Windows/ResourceString.h
+++ b/CPP/Windows/ResourceString.h
@@ -9,7 +9,9 @@
 namespace NWindows {
 
 UString MyLoadString(UINT resourceID);
+#ifdef _WIN32
 void MyLoadString(HINSTANCE hInstance, UINT resourceID, UString &dest);
+#endif
 void MyLoadString(UINT resourceID, UString &dest);
 
 }
```

Rationale per hunk:

| Hunk | Why |
|---|---|
| `Agent.h` `INVALID_FILE_ATTRIBUTES` | the constant only exists in `C/7zWindows.h:69`; `Is_Attrib_ReadOnly()` compares against it. A cleaner upstream location is next to the `FILE_ATTRIBUTE_*` fallbacks in `C/7zTypes.h:145-160` (that would also fix `FSFolder.h:204`), but the local define is the minimal change. |
| `Agent.h`/`ArchiveFolderOpen.cpp` icon code | `CCodecIcons` reads a Win32 string-table resource (`MyLoadString(HMODULE, 100, ...)`) to map extensions to icon indices in `7z.dll`/`7zFM.exe`. Meaningless on macOS; `GetExtensions` now enumerates `g_CodecsObj->Formats[i].Exts` instead (the same information, from the format table), `GetIconPath` returns `S_OK` with no path. |
| `Agent.cpp` 1517-1523 / `AgentOut.cpp` 282-287 | `IsAltStreamPrefixWithColon` (`"name:"` -> NTFS alternate stream prefix) is declared only for `_WIN32` in `FileName.h:57`. |
| `Agent.cpp` 1647-1655, 1702 | POSIX `CFileInfoBase` has `mode/dev/...` instead of `Attrib/IsDevice` (`FileFind.h:75-96`); `GetWinAttrib()` yields the same "Windows attrib + POSIX mode in the high word" value the engine uses everywhere else; character/block devices are the only things 7-Zip considers "device files". |
| `AgentOut.cpp` 291-305 | updating *into* an alternate-stream folder (`_updatePathPrefix_is_AltFolder`) requires `CDirItem::IsAltStream` (Windows-only, `FileFind.h:77`); return `E_NOTIMPL` instead. |
| `AgentOut.cpp` 571-590 (`CreateFolder`) | `di.Attrib` does not exist on POSIX; `SetAsDir()` (`FileFind.h:133`, `mode = S_IFDIR | 0777`) is the portable equivalent; `GetCurUtc_FiTime` + `CFiTime` are the portable spellings (`TimeUtils.h:110-115`; on Windows `CFiTime == FILETIME` and `GetCurUtcFileTime` is a macro for the same function, so Windows is unchanged). |
| `ArchiveFolderOut.cpp` 47-51, 64-68 | POSIX `CDirEntry` has no `IsDir()`, `CEnumerator::DirEntry_IsDir` is the portable accessor (`FileFind.h:309-323`); clearing the read-only attribute before `rmdir` is a Windows-only need. |
| `UpdateCallbackAgent.cpp` 39, 46 | `UINT64` is a Windows SDK typedef; the declaration in `UpdateCallback.h:35-36` already says `UInt64`. |
| `SplitUtils.*` | `AddVolumeItems` fills a Win32 combo box; the parser/counter are pure. |
| `ResourceString.h` | the `HINSTANCE` overload has no meaning without a Win32 module; guarding it lets `LangUtils.h`-dependent utilities compile. The `UINT` overloads become the app's string-table hook. |

Verification: after the patch, `Agent.cpp`, `AgentOut.cpp`, `AgentProxy.cpp`, `ArchiveFolder.cpp`,
`ArchiveFolderOpen.cpp`, `ArchiveFolderOut.cpp`, `UpdateCallbackAgent.cpp`, `SplitUtils.cpp`,
`FormatUtils.cpp`, `PropertyName.cpp` all compile with the **strict** 7zz flags (0 warnings), and
the Agent objects link and run against the 7zz objects (Appendix A).

### 4.3 Symbols the platform layer must provide, and where the Objective-C++ bridge attaches

**Link-time obligations** (discovered by linking the Agent against the 7zz objects; each one is a
free function or a member of a portable header whose Windows implementation lives in a (d) file):

| Symbol | Declared in | Windows implementation | macOS implementation |
|---|---|---|---|
| `int CompareFileNames_ForFolderList(const wchar_t*, const wchar_t*)` | `FileManager/IFolder.h:183` | `FileManager/PanelSort.cpp:14-45` (numeric-aware, case-insensitive) | copy those 30 lines into the app TU, or `return CompareFileNames(s1, s2)` (`Common/Wildcard.h:8`) as the smoke test does; better: `[NSString localizedStandardCompare:]` for Finder-like order |
| `void SetExtractErrorMessage(Int32 opRes, Int32 encrypted, const wchar_t *fileName, UString &s)` | forward-declared in `Agent/UpdateCallbackAgent.cpp:136` (also `GUI/UpdateCallbackGUI.cpp:146`) | `FileManager/ExtractCallback.cpp:277-373` (`IDS_EXTRACT_MSG_*` strings) | produce `"<message> : <fileName>"` from the table in 2.5.2 / `ExtractCallbackConsole.cpp:211-221` |
| `NWorkDir::CInfo::Load()` / `Save()` | `UI/Common/ZipRegistry.h:170-186` | `ZipRegistry.cpp` (registry) | `Load()` -> `Mode = kSpecified; Path = NSTemporaryDirectory()` (sandbox-safe; `kSystem` would use `/tmp/`, `FileDir.cpp:864-874`) or `kCurrent` to stay on the same volume for a cheap `rename()` |
| `NExtract::CInfo::Load/Save`, `NExtract::Read_ShowPassword/Save_ShowPassword/Read_LimitGB/Save_LimitGB`, `NCompression::CInfo::Load/Save`, `NCompression::CMemUse::Parse` | `ZipRegistry.h:23-156` | `ZipRegistry.cpp` | only needed if the app's option models reuse these structs (recommended — `ExtractGUI/UpdateGUI` logic expects them); back them with `UserDefaults` |
| `NWindows::MyLoadString(UINT)` / `MyLoadString(UINT, UString&)` | `Windows/ResourceString.h:11-13` | `Windows/ResourceString.cpp` (`LoadStringW`) | only if `FormatUtils.cpp`/`PropertyName.cpp` are linked: map the `IDS_*` ids (`FileManager/PropertyNameRes.h`, `GUI/ExtractRes.h`, `FileManager/resourceGui.h`) to `NSLocalizedString` |
| `IID_*` GUID definitions | every `Z7_DECL_IFACE_7ZIP` | `MyInitGuid.h` included from `Console/Main.cpp:44` / `FileManager/ClassDefs.cpp:7` | include `CPP/Common/MyInitGuid.h` in exactly one app TU |

**Bridge seams** (where Objective-C++ code should sit; everything above the line is engine, everything below is AppKit/Swift):

1. **Codecs**: call `LoadGlobalCodecs()` once at startup (`Agent.cpp:74-107`), `FreeGlobalCodecs()` at exit. `g_CodecsObj->Formats` is the format table for "Open with type", "Archive format" popups (`CArcInfoEx::Name`, `Exts`, `UpdateEnabled`, `Flags_HashHandler()`). `MY_SetLocale()` first (`StringConvert.h:98`).
2. **Open / browse**: an ObjC++ `SZArchive` owning `CMyComPtr<IInFolderArchive>` (`CAgent`) + a `COpenCallbackImp` whose `Callback` points to an `IOpenCallbackUI` adapter that forwards password/progress/cancel to Swift closures (2.5.1). `BindToRootFolder` -> `SZFolder` owning `CMyComPtr<IFolderFolder>`; item rows read `IFolderGetItemName::GetItemName/GetItemSize` (zero copy) and `IFolderFolder::GetProperty` for columns, `IFolderCompare::CompareItems` for sorting, `IFolderSetFlatMode` for "flat view", `IFolderArcProps` (QI via `IGetFolderArcProps`) for the Info/Properties panel, `IInArchiveGetStream::GetStream(index)` for QuickLook/preview of a single item (or `IFolderExtractToStreamCallback` for the general case). Navigation = `BindToFolder(index|name)` / `BindToParentFolder`.
3. **Extract / test**: `IArchiveFolder::Extract(indices, ..., pathMode, overwriteMode, path, testMode, cb)` for selections inside an open archive; `Extract()` (`Extract.h:101`) with `IOpenCallbackUI + IExtractCallbackUI + IFolderArchiveExtractCallback` (one object, like `CExtractCallbackImp`) for "Extract archives..." from Finder/file lists; the callback object is the ObjC++ class implementing `IFolderArchiveExtractCallback` (+ `IFolderArchiveExtractCallback2`, `ICryptoGetTextPassword`, `ICompressProgressInfo`, `IFolderOperationsExtractCallback`, `IArchiveRequestMemoryUseCallback` for the "archive needs N GB of RAM, continue?" prompt) forwarding to a Swift progress model.
4. **Add / update**: `UpdateArchive()` (`Update.h:210`) with `IOpenCallbackUI + IUpdateCallbackUI2` for "Add to archive..." (build `CUpdateOptions` the way `UpdateGUI.cpp:205-282, 315-541` does: `ArchivePath.ParseFromPath`, `MethodMode.Type` from `ParseOpenTypes`, `MethodMode.Properties` = `x`, `d`, `mt`, `s`, `m0`, `he`, `p`... as `CProperty` pairs, `VolumesSizes` from `ParseVolumeSizes`, `Commands` via `SetActionCommand_Add()`; `censor.AddPreItem_NoWildcard(path)` per selected item then `censor.AddPathsToCensor(NWildcard::k_AbsPath)`); `IFolderOperations` on the open `IFolderFolder` for drag-into-archive (`CopyFrom`), delete, rename, new folder, comment (`SetProperty(kpidComment)`), with an `IFolderArchiveUpdateCallback`-family object like `CUpdateCallback100Imp`.
5. **Hash**: `HashCalc()` with an `IHashCallbackUI` adapter (2.5.5); `CHashBundle::SetMethods` from the menu selection.
6. **Benchmark**: `Bench()` (`Bench.h:100-107`) with `IBenchPrintCallback` (text mode, what `7zz b` prints) or `IBenchCallback` (structured, what `BenchmarkDialog.cpp` uses).
7. **Errors -> `NSError`**: `HRESULT` + `NWindows::NError::MyFormatMessage` (2.4) + the `CArcErrorInfo` fields (2.3); the per-item `opRes` table of 2.5.2.
8. **Settings**: the `ZipRegistry.h` structs as the model, persisted by the app.

### 4.4 Threading model and cancellation

* **Everything that opens, lists, extracts, updates or hashes must run off the main thread.** The engine is synchronous: `IInArchive::Open/Extract`, `IOutArchive::UpdateItems`, `CArchiveLink::Open*`, `Extract()`, `UpdateArchive()`, `HashCalc()`, `Bench()`, `CAgentFolder::LoadItems/Extract/CommonUpdateOperation` all block until done. The Windows FM runs each of them on a `NWindows::CThread` (`FileFolderPluginOpen.cpp:346-349`, `ProgressDialog2.cpp:1412-1419`: `thread.Create(MyThreadFunction, this)` then the modal dialog pumps messages until `ProcessWasFinished()` posts `kCloseMessage`). On macOS: a dedicated `Thread`/`DispatchQueue` per operation (not `DispatchQueue.global()` if you use Pause, because the worker blocks inside the callback).
* **Callbacks arrive on engine threads.** The interface-level contract (`IArchive.h:183-190`): item callbacks (`GetStream/PrepareOperation/SetOperationResult`, hence `AskOverwrite`, `MessageError`, `CryptoGetTextPassword`) are serialised, but `IProgress::SetCompleted`/`ICompressProgressInfo::SetRatioInfo` **may be called concurrently from other worker threads** (the MT LZMA2/xz/bzip2 coders, `Lzma2DecMt`, `MtCoder`). The console therefore takes a global lock in every callback (`static NSynchronization::CCriticalSection g_CriticalSection; #define MT_LOCK`, `ExtractCallbackConsole.cpp:187-192`, `UpdateCallbackConsole.cpp:23-27`), and the FM funnels everything through `CProgressSync` whose every method locks `_cs`. The bridge must do the same: lock, store into a plain struct, return; never touch AppKit from inside a callback. Push to the main thread with `DispatchQueue.main.async` only for *events* (password request, overwrite question, memory-use question, final messages) and block the engine thread on a semaphore until the user answers — that is exactly what `CPasswordDialog`/`COverwriteDialog` do (`ExtractCallback.cpp:218-219, 693-694`: `ProgressDialog->WaitCreating(); dialog.Create(*ProgressDialog)` runs the modal dialog on the *worker* thread on Windows; on macOS the worker must instead wait for the main thread).
* **Progress display** should be pulled by a timer on the main thread from the locked struct (the FM uses a 200 ms `WM_TIMER`, `ProgressDialog2.cpp:33-38`, `kTimerElapse`), not pushed per callback (`SetCompleted` can fire thousands of times per second).
* **Cancellation** is cooperative: return `E_ABORT` from *any* callback (`CProgressSync::CheckStop`, `ProgressDialog2.cpp:100-110`; console `CheckBreak2()` = `TestBreakSignal() ? E_ABORT : S_OK`, `ExtractCallbackConsole.cpp:30-33`, polled in every callback; `IOpenCallbackUI::Open_CheckBreak`; `IUpdateCallbackUI::CheckBreak`; `IHashCallbackUI::CheckBreak`; `IBenchPrintCallback::CheckBreak`). The engine propagates it and the top-level call returns `E_ABORT` (the console maps that to exit code 255, section 5.5). Partially written files are closed and left on disk (the console prints nothing special; the FM shows nothing). `E_ABORT` returned during the Agent's *move* phase is deliberately swallowed until the archive is reopened (`ArchiveFolderOut.cpp:222-233` + `Before_ArcReopen()`), so the app's cancel flag must be cleared in `Before_ArcReopen`.
* **Pause** = block inside the callback (`CProgressSync::CheckStop` sleeps 100 ms while `_paused`). Fine for a dedicated thread.
* **Reference counting is not thread-safe** (`MyCom.h:378-392`: `++_m_RefCount`/`--_m_RefCount`, `Z7_COM_USE_ATOMIC` is off). Rule: create a callback object on the thread that starts the operation, hold one `CMyComPtr` there until the operation has returned, and never `AddRef/Release` engine objects from Swift/main-thread code while a worker is running. If the app needs to share engine objects across threads, define `Z7_COM_USE_ATOMIC` for the whole library (`MyCom.h:358-376` then uses `InterlockedIncrement/Decrement`, which on POSIX must be provided — `C/Threads.h` offers atomics in newer versions; check before enabling) — simpler to keep the one-thread-per-object discipline.
* `LoadGlobalCodecs/FreeGlobalCodecs` are guarded by `g_CriticalSection` (`Agent.cpp:49-54`); `CCodecs` itself is read-only after `Load()` and may be shared by concurrent operations. Two operations on the *same* `CAgent`/`IInArchive` must not run concurrently (handlers keep per-archive state, e.g. the current `IInStream` position); two operations on different archives may.
* The console installs `SIGINT/SIGTERM` handlers that only set a counter (`ConsoleClose.cpp:63-84`); a GUI does not need that.

### 4.5 Codec loading model

* Every handler/coder/hasher registers itself in a static constructor: `REGISTER_ARC_*` (`Common/RegisterArc.h:44-78`) -> `RegisterArc(&g_ArcInfo)` -> `g_Arcs[g_NumArcs++]` (`LoadCodecs.cpp:113-121`); coders through `REGISTER_CODEC*` in `7zip/Common/RegisterCodec.h` -> `g_Codecs[]`, hashers -> `g_Hashers[]` (used by `CreateCoder.cpp`). Consequence for a **static library**: the linker only pulls an object if something references it, and nothing references `*Register.cpp`. Either add `-force_load $(BUILT_PRODUCTS_DIR)/libSevenZipCore.a` (or `-all_load`) to the app's `OTHER_LDFLAGS`, or make the registration objects part of the app target directly. (A plain executable like 7zz lists all objects on the link line, so it does not have this problem.) A missing registration shows up as `CCodecs::Load()` returning fewer formats — `g_CodecsObj->Formats.Size()` should be **61** with the full list of 1.4 (`LoadGlobalCodecs: formats=61` in the smoke run) and `LoadGlobalCodecs()` returns `E_NOTIMPL` when it is 0 (`Agent.cpp:92-96`).
* `CCodecs::Load()` (`LoadCodecs.cpp:791-...`) copies `g_Arcs` into `Formats` (name, extensions split from the `"7z"`/`"zip jar xpi..."` strings, signatures, flags, `CreateInArchive/CreateOutArchive` function pointers), sorts them, and `Codecs_AddHashArcHandler` appends the virtual "hash file" handler (`HashCalc.cpp`). No file system access, no `dlopen` (that is the `Z7_EXTERNAL_CODECS` build of `7z.exe`, not used here).
* Format lookup: `FindFormatForArchiveName(path)` / `FindFormatForExtension(ext)` / `FindFormatForArchiveType("7z")` / `FindOutFormatFromName` (`LoadCodecs.h:388-391, 450-461`); open-type strings through `ParseOpenTypes` (`OpenArchive.h:446`).
* Hashers/coders by name: `CreateHasher`/`FindHashMethod` and `CreateCoder_Id/CreateDecoder` in `CPP/7zip/Common/CreateCoder.h` (all internal; `DECL_EXTERNAL_CODECS_LOC_VARS` expands to nothing).
* Ownership: `g_CodecsObj` (raw) + `g_CodecsRef` (owning `CMyComPtr<IUnknown>`, `Agent.cpp:43-47`). Handlers do **not** keep references to `CCodecs`, so `FreeGlobalCodecs()` after all archives are closed is safe.

### 4.6 Exceptions and `HRESULT` conventions

* Public COM methods never let exceptions escape: `COM_TRY_BEGIN/END` (`ComTry.h:10-11`) turns anything into `E_OUTOFMEMORY`. Handlers additionally return `S_FALSE` for "not this format" on `Open`, and specific codes: `E_NOTIMPL` (unsupported operation/format/feature, e.g. update on a read-only handler, alt-stream folders on macOS), `E_INVALIDARG`, `E_ABORT` (cancelled), `E_FAIL`, `HRESULT_FROM_WIN32(errno)` for I/O (`GetLastError_noZero_HRESULT()`, `FileIO.h:55`), `MY_HRES_ERROR_INTERNAL_ERROR`, plus the Win32-facility constants that survive on POSIX: `ERROR_DISK_FULL`, `ERROR_FILE_EXISTS`, `ERROR_INVALID_PARAMETER`, `ERROR_NEGATIVE_SEEK` (`7zTypes.h:100-134`). Decode with `MyFormatMessage` (2.4) and `(hr >> 16) & 0x1FFF == 0x800` -> `errno = hr & 0xFFFF`.
* The **non-COM** drivers in `UI/Common` (`Extract`, `UpdateArchive`, `HashCalc`, `EnumerateItems`, censor/command-line code) **do throw**: `CSystemException{HRESULT ErrorCode}` (`Common/MyException.h:8-12`), `CMessagePathException : UString` (`EnumDirItems.h:18-22`), `CNewException` (from `operator new` when `Z7_REDEFINE_OPERATOR_NEW`, `Common/NewHandler.h:50-51`), and literal `const char*`/`const wchar_t*`/`UString`/`AString`/`int` values (e.g. `throw 141717` in `WorkDir.cpp:56`, `throw kUpdateIsNotSupoorted` in `Update.cpp:375`, `throw 151199` in `PropVariantConv.h:43`). The console's `main` catches every one of these (`MainAr.cpp:126-232`) and the FM's worker thread catches `const wchar_t*`, `const UString&`, `const char*`, `int` and `...` (`ProgressDialog2.cpp:1436-1444`). **The bridge must wrap every engine entry point in the same catch ladder** and never let a C++ exception reach Swift (undefined behaviour). Suggested mapping: `CSystemException` -> its `HRESULT`; `CMessagePathException`/strings -> `E_FAIL` + message; `CNewException`/`std::bad_alloc` -> `E_OUTOFMEMORY`; `int` -> `E_FAIL` + `"Internal Error #N"`.
* `S_FALSE` is *not* an error for `Open` (see 2.5.1) and for `IArchiveUpdateCallback::GetStream` (skip file); check `hr == S_OK` explicitly rather than `SUCCEEDED(hr)` where the distinction matters.
* Never mix `RINOK` (returns the code) semantics with exceptions inside a callback; callbacks are `throw()`.

### 4.7 String encoding rules

* `UString` = `wchar_t` = **UTF-32** on macOS (`MyString.h:1057-1063`: `Z7_WCHART_IS_16BIT` is not defined). Every archive item name, property string, error message and `BSTR` is UTF-32. `BSTR` is a `malloc`ed `wchar_t*` with a 4-byte length prefix (`MyWindows.cpp:40-107`); free with `SysFreeString`, create with `StringToBstr(const UString&, BSTR*)` (`MyCom.h:186`). Bridge: `NSString` <- `[NSString initWithBytes:length:encoding:NSUTF32LittleEndianStringEncoding]` or go through UTF-8 (`UnicodeStringToMultiByte(u, CP_UTF8)` -> `AString`).
* `AString`/`FString`/`CFSTR`/`CSysString` = **UTF-8** (`FString = AString` because `USE_UNICODE_FSTRING` is `_WIN32`-only, `MyString.h:966-969`); `g_ForceToUTF8 = true` (`StringConvert.cpp:260`) makes `MultiByteToUnicodeString`/`UnicodeStringToMultiByte` ignore the `codePage` argument and always convert UTF-8 (`StringConvert.cpp:262-273, 397-403`). `GetSystemString(UString)` therefore returns UTF-8 `AString` (`StringConvert.h:61-69`, non-`_UNICODE` branch), `fs2us/us2fs` convert between the two (`MyString.cpp:1744-1756`). Paths handed to the engine (`CAgent::Open`, `Extract` output dir, `CUpdateOptions::ArchivePath`, censor items) are `UString`s built from UTF-8 with `MultiByteToUnicodeString(utf8, CP_UTF8)`; HFS+/APFS normalisation is not touched by 7-Zip (it passes bytes through), so feed it `fileSystemRepresentation` and expect the same back.
* Console-only: `CStdOutStream::CodePage`, `IsTerminalMode`, `Normalize*` (`Common/StdOutStream.h`) handle the "unprintable characters in a terminal" problem; irrelevant for a GUI.
* Invalid UTF-8 in archive names is escaped by `UTFConvert` (`Z7_UTF_FLAG_FROM_UTF8_USE_ESCAPE`, `UTFConvert.h:91-93`) and `Get_Correct_FsFile_Name` (`ExtractingFilePath.h:13`) sanitises extraction paths; the item `Path` given to callbacks is the *archive* name, the `FString` given to `MessageError` is the *disk* path.

### 4.8 Settings the engine reads

Only through the `ZipRegistry.h` accessors (4.3) — the engine has no other persistent state.
`NWorkDir::CInfo::Load()` is the one call that happens implicitly (`WorkDir.cpp:63-64`, from every
Agent update), so its macOS implementation must exist even in a first prototype.

---
## 5. The console app as a behavioural reference (`CPP/7zip/UI/Console/`)

`Main.cpp:Main2` (`Console/Main.cpp:848-1656`) is the whole program: `MY_SetLocale()` (848),
parse (`CArcCmdLineParser`), pick the percent stream (`-bsp`, 921-923), console width (988-1005:
80 default, `ioctl(TIOCGWINSZ)` on POSIX), `CREATE_CODECS_OBJECT` + `codecs->Load()` +
`Codecs_AddHashArcHandler` (1010-1015), `ParseOpenTypes` for `-t` (1030-1061), then one of:
`BenchCon` (1283), extract group (1349-1512), `ListArchives` (1526-1557), `UpdateArchive`
(1560-1620), `HashCalc` (1622-1643); finally `ThrowException_if_Error(hresultMain)` (1654) and
`return retCode`.

### 5.1 Password prompts

* Prompt function: `GetPassword(CStdOutStream*, UString&)` (`UserInputUtils.cpp:63-107`): prints `"\nEnter password:"` — on Windows adds `" (will not be echoed)"` and disables `ENABLE_ECHO_INPUT`; **on POSIX the password is echoed** (`MY_DISABLE_ECHO` is `_WIN32`-only, 57-61) — then reads one line with `g_StdIn.ScanUStringUntilNewLine`. `GetPassword_HRESULT` (109-118): `E_INVALIDARG` if the read failed, `E_FAIL` on stream error, `E_ABORT` on EOF with an empty password, else `S_OK`.
* Open/extract: `COpenCallbackConsole::Open_CryptoGetTextPassword` (`OpenCallbackConsole.cpp:79-92`): `CheckBreak2()`, close the percent line, prompt only if `!PasswordIsDefined`, cache in `Password/PasswordIsDefined`, return `StringToBstr`. `CExtractCallbackConsole::CryptoGetTextPassword` (`ExtractCallbackConsole.cpp:526-532`) forwards to it under `MT_LOCK`, so one password serves header decryption and every encrypted item; a wrong password surfaces as `SetOperationResult(kDataError|kCRCError, encrypted=1)` -> `"Data Error in encrypted file. Wrong password?"` / `"CRC Failed in encrypted file. Wrong password?"` (417-463) or `kWrongPassword` for formats that can verify (RAR5, zip AES, 7z with `-mhe`). `-p<pw>` presets it (`Main.cpp:1356-1357, 1374-1375`).
* Update: `CUpdateCallbackConsole::CryptoGetTextPassword2` (`UpdateCallbackConsole.cpp:830-857`): asks only if `AskPassword` (= `-p` given with an empty password, `Main.cpp:1587`), otherwise reports `*passwordIsDefined = 0` -> no encryption; `CryptoGetTextPassword` (859-882) (used when an existing encrypted archive must be re-read) always asks once.

### 5.2 Overwrite prompts

`CExtractCallbackConsole::AskOverwrite` (`ExtractCallbackConsole.cpp:284-326`): `MT_LOCK`, `CheckBreak2()`, close percents, print

```
Would you like to replace the existing file:
  Path:     <existing on-disk path>
  Size:     <bytes> bytes (<n> KiB)      (only if known)
  Modified: <YYYY-MM-DD HH:MM:SS>        (only if known)
with the file from archive:
  Path:     <item path>
  Size:     ...
  Modified: ...
```

then `ScanUserYesNoAllQuit` (`UserInputUtils.cpp:23-55`) loops on `"? (Y)es / (N)o / (A)lways / (S)kip all / A(u)to rename all / (Q)uit? "` accepting single letters `y n a s u q` (case-insensitive); mapping: `kYes -> NOverwriteAnswer::kYes`, `kNo -> kNo`, `kYesAll -> kYesToAll`, `kNoAll -> kNoToAll`, `kAutoRenameAll -> kAutoRename`, `kQuit`/EOF -> `E_ABORT`, read error -> `E_FAIL`. Non-interactive equivalents: `-y` (`YesToAll` -> `kOverwrite`, `ArchiveCommandLine.cpp:1751`), `-aoa/-aos/-aou/-aot` (`kOverwrite/kSkip/kRename/kRenameExisting`, 255-262, 1745-1750). The prompt is only reached in `kAsk` mode from `CArchiveExtractCallback::CheckExistFile` (`ArchiveExtractCallback.cpp:1257-1296`).

### 5.3 Progress percent

`CPercentPrinter` (`PercentPrinter.h:27-64`, `PercentPrinter.cpp`): state = `Completed`, `Total`, `Files`, `Command`, `FileName`. `Print()` (`.cpp:89-186`) is rate-limited to `_tickStep` = 200 ms (`GetTickCount`), re-prints only when something changed, formats `"<NN>%"` (or `"<N>M"` MiB when `Total` is unknown/0, 58-79), then `" <files>"` if `Files != 0`, `" <Command>"` (extract: `"T"` test, `"-"` extract, `"."` skip, `"H"` read-external, `"Open"` while opening — `ExtractCallbackConsole.cpp:194-197, 646`; update: `"+"` add, `"U"` update, `"A"` analyze, `"="` replicate, `"R"` repack, `"."` skip, `"D"` delete, `UpdateCallbackConsole.cpp:793-801` (`LogLevel` gates which appear)), then `" <file name>"` shortened in the middle with `" . "` to fit `MaxLen` = console width - 1 (140-170). `ClosePrint` (25-56) erases the line with `\b`+spaces+`\b` on POSIX (`\r` on Windows) and optionally flushes. Sources of the values: `SetTotal/SetCompleted` (`ExtractCallbackConsole.cpp:238-261`, `UpdateCallbackConsole.cpp:595-618`, `OpenCallbackConsole.cpp:20-66` for the open phase, `HashCon.cpp:79-97`), `PrepareOperation` sets `Command/FileName` and prints the file line if `LogLevel`/`-bb` asks (`ExtractCallbackConsole.cpp:328-396`), `SetOperationResult(kOK)` increments `Files` (465-476). `-bd` disables it (`DisablePrint`), `-bsp0/1/2` picks the stream, percent output goes to stdout only if it is a terminal.

### 5.4 Error summaries and messages

* Per archive (`CExtractCallbackConsole`): `BeforeOpen` prints `"\nExtracting archive: <path>"` / `"Testing archive: "` (625-647); `OpenResult` (723-880) prints, per nesting level, `"ERRORS:"` + the flag texts (`k_ErrorFlagsMessages`, 223-236) and/or the handler's `ErrorMessage` to **stderr** (counts `NumOpenArcErrors`, sets `ThereIsError_in_Current`), `"WARNINGS:"` + warning flags/message to **stdout** (`NumOpenArcWarnings`), the `"WARNING:\n<path>\nThe archive is open with offset"` / `"Cannot open the file as [X] archive\nThe file is open as [Y] archive"` note (`Print_ErrorFormatIndex_Warning`, 700-720), then on success `Print_OpenArchive_Props` (type, physical size, headers size, method... from `List.cpp`), on failure `"ERROR: <path>"` + `Print_OpenArchive_Error` + (`S_FALSE`: nothing more; `E_OUTOFMEMORY`: `"Can't allocate required memory"`; else `MyFormatMessage(result)`) and `NumCantOpenArcs++` (851-877). `MessageError` prints `"ERROR: <text>"` (398-415). `SetOperationResult` (465-502): on failure prints `"<opRes text> : <item path>"` to stderr and increments `NumFileErrors[_in_Current]`. `ExtractResult` (895-954): `S_OK` -> `"Everything is Ok"` if no item/open errors (warnings count as `NumArcsWithWarnings`), else `"Sub items Errors: N"` and `NumArcsWithError++`; other `HRESULT` -> `"ERROR: <MyFormatMessage>"` (`E_ABORT` and `ERROR_DISK_FULL` are returned without counting).
* Batch summary (`Main.cpp:1425-1512`): if more than one archive `"Archives: N"`, `"OK archives: N"`; `"Can't open as archive: N"`, `"Archives with Errors: N"`, `"Archives with Warnings: N"`, `"Warnings: N"`, `"Open Errors: N"`, `"Sub items Errors: N"` (each only if non-zero; the *error* ones set `retCode = kFatalError`); on a fully clean run `"Folders: N"` (if any), `"Files: N"`, `"Alternate Streams..."`, `"Size:       <unpacked>"`, `"Compressed: <packed>"`, then `PrintHashStat` (`HashCon.cpp:371-383`) if `-scrc` was given. A non-empty `errorMessage` from `Extract()` (e.g. `"Cannot create output directory"`) prints `"ERROR:\n<message>"` and forces `E_FAIL` (1418-1423).
* Update/hash summary (`WarningsCheck`, `Main.cpp:443-522`): `"Scan WARNINGS for files and folders:"` + list + `"Scan WARNINGS: N"` -> `kWarning`; `result != S_OK || errorInfo.ThereIsError()` -> `"\nError:\n<Message>\n<FileNames...>\n<MyFormatMessage(SystemError)>"` -> `kFatalError`; open-failed files -> `"WARNINGS for files:"` + list + `"WARNING: Cannot open N file(s)"` -> `kWarning`; otherwise `"Everything is Ok"`. `FinishArchive` prints `"Files read from disk: N"`, `"Archive size: <bytes> (KiB/MiB)"`, `"Volumes: N"` (`UpdateCallbackConsole.cpp:337-362`); `FinishScanning` prints the scan stats; `SetNumItems` prints `"Delete data from archive: ..."`/`"Add new data to archive: ..."` (574-593).
* `Print_ErrorFlags`/`GetOpenArcErrorMessage` (653-689) render unknown flag bits as `0x<hex>`.

### 5.5 Exit codes (`ExitCode.h`, `MainAr.cpp:126-232`)

| Code | Meaning | Where |
|---|---|---|
| 0 `kSuccess` | no errors | |
| 1 `kWarning` | scan warnings / files that could not be opened during add or hash | `WarningsCheck` |
| 2 `kFatalError` | open/extract/update errors, `CSystemException` with any other `HRESULT` ("System ERROR:" + `MyFormatMessage`), thrown strings ("ERROR:" + text), unknown exceptions ("Unknown Error"), `throw int` ("Internal Error #N") | `Main.cpp:1479, 1554`, `MainAr.cpp:157-232` |
| 7 `kUserError` | command-line error (`CMessagePathException` -> `"Command Line Error:"` + text, or `kUserErrorMessage`) | `MainAr.cpp:150-156`, `Main.cpp:221-225` |
| 8 `kMemoryError` | `CNewException` or `CSystemException(E_OUTOFMEMORY)` -> `"ERROR: Can't allocate required memory!"` | `MainAr.cpp:138-142, 159-163` |
| 255 `kUserBreak` | `CSystemException(E_ABORT)` -> `"Break signaled"` | `MainAr.cpp:164-168` |

Ctrl-C (`ConsoleClose.cpp:63-84`): `SIGINT`/`SIGTERM` increment `g_BreakCounter`; every callback polls `TestBreakSignal()` and returns `E_ABORT`; a third signal calls `exit(EXIT_FAILURE)`.

---

## Appendix A. Smoke-test recipe (scratch only; nothing in the tree was changed)

Scratchpad: `/private/tmp/claude-501/-Users-user-things-a-noindex-7zip/b4d1b51c-0613-4961-b8bd-030e239365dd/scratchpad` (`$SP`).

1. Build 7zz out of tree (all 323 objects land in `$SP/b/m_arm64`):

```
cd CPP/7zip/Bundles/Alone2
DEVELOPER_DIR=/Applications/Xcode.app make -j10 -f ../../cmpl_mac_arm64.mak O=$SP/b/m_arm64
$SP/b/m_arm64/7zz i        # 7-Zip (z) 26.03 (arm64) ... Threads:10 ... ASM
```

2. Overlay the patch of 4.2: `$SP/ovl/make_overlay.py` copies `CPP/7zip/UI/Agent/*`, `FileManager/{SplitUtils,FormatUtils,PropertyName,LangUtils,StringUtils,TextPairs}.*` and `Windows/ResourceString.h` into `$SP/ovl/<same relative path>` and applies the hunks; `$SP/ovl/compile.sh` compiles each with the strict flags plus `-I$REPO/CPP/7zip/UI/Agent` (resp. `-I.../FileManager -I$REPO/CPP/Windows`) so that the overlay files' `../Common/...` includes resolve into the real tree. Result: `strict=0 lax=0` for all 10 files.

3. `$SP/ovl/7zip/UI/Agent/agent_smoke.cpp` (compiled with the lax flags + `-I$REPO/CPP/7zip/UI/Agent`), essentials:

```cpp
#include "StdAfx.h"
#include "../../../Common/MyInitGuid.h"          // IIDs, exactly once
#include "../../../Common/StringConvert.h"
#include "../../../Windows/PropVariant.h"
#include "../../../Windows/PropVariantConv.h"
#include "../Common/ZipRegistry.h"
#include "Agent.h"

// symbols the platform layer must provide (4.3):
void SetExtractErrorMessage(Int32 opRes, Int32 encrypted, const wchar_t *fileName, UString &s)
{ s = "opRes="; s.Add_UInt32((UInt32)opRes); s += encrypted ? " (encrypted) " : " "; s += fileName; }
void NWorkDir::CInfo::Load() { SetDefault(); }
void NWorkDir::CInfo::Save() const {}
int CompareFileNames_ForFolderList(const wchar_t *s1, const wchar_t *s2) { return CompareFileNames(s1, s2); }

class COpenCb Z7_final: public IArchiveOpenCallback, public ICryptoGetTextPassword, public CMyUnknownImp
{ Z7_COM_UNKNOWN_IMP_2(IArchiveOpenCallback, ICryptoGetTextPassword)
  Z7_IFACE_COM7_IMP(IArchiveOpenCallback) Z7_IFACE_COM7_IMP(ICryptoGetTextPassword) };
// SetTotal/SetCompleted -> S_OK; CryptoGetTextPassword -> StringToBstr(UString(L"secret"), password)

class CExtractCb Z7_final: public IFolderArchiveExtractCallback, public CMyUnknownImp
{ Z7_COM_UNKNOWN_IMP_1(IFolderArchiveExtractCallback)
  Z7_IFACE_COM7_IMP(IProgress) Z7_IFACE_COM7_IMP(IFolderArchiveExtractCallback) };
// SetTotal stores; SetCompleted prints %; AskOverwrite -> *answer = NOverwriteAnswer::kYesToAll;
// PrepareOperation prints mode/dir/name; MessageError prints; SetOperationResult counts errors

int main(...) {
  LoadGlobalCodecs();                                   // formats=61
  CAgent *agentSpec = new CAgent; CMyComPtr<IInFolderArchive> agent = agentSpec;
  COpenCb *ocb = new COpenCb; CMyComPtr<IArchiveOpenCallback> openCb = ocb;
  CMyComBSTR type;
  agent->Open(NULL, arcPath, L"" /* arcFormat must NOT be NULL */, &type, openCb);   // S_OK, "7z"
  CMyComPtr<IFolderFolder> root; agent->BindToRootFolder(&root);
  // list: root->LoadItems(); GetNumberOfItems; GetProperty(i, kpidName|kpidSize|kpidIsDir); BindToFolder(i)
  CExtractCb *ecb = new CExtractCb; CMyComPtr<IFolderArchiveExtractCallback> cb = ecb;
  agent->Extract(NExtract::NPathMode::kFullPaths, NExtract::NOverwriteMode::kAsk, outDir, 0, cb);   // S_OK
  CMyComPtr<IArchiveFolder> af; root.QueryInterface(IID_IArchiveFolder, &af);
  UInt32 idx[1] = { 0 };
  af->Extract(idx, 1, 1, 0, NExtract::NPathMode::kCurPaths, NExtract::NOverwriteMode::kAsk, NULL, 1 /*test*/, cb2); // S_OK
  CMyComPtr<IFolderOperations> ops; root.QueryInterface(IID_IFolderOperations, &ops);
  ops->CreateFolder(L"created_by_smoke", NULL);          // S_OK: temp file -> move -> ReOpen
  agent->Close(); FreeGlobalCodecs();
}
```

4. Link (`$SP/smoke/build.sh`): the smoke object + the 7 overlay Agent objects + `$SP/audit/obj/CPP_7zip_UI_Common_WorkDir.cpp.strict.o` + every `$SP/b/m_arm64/*.o` **except** `BenchCon ConsoleClose ExtractCallbackConsole HashCon List Main MainAr OpenCallbackConsole PercentPrinter UpdateCallbackConsole UserInputUtils`, with `clang++ -arch arm64 ... -lpthread -ldl`. Binary: 2,998,104 bytes.

5. Run against `test.7z` (made with `7zz a test.7z readme.txt License.txt sub/`):

```
LoadGlobalCodecs: 0x00000000, formats=61
  open total files=- bytes=y
Open: 0x00000000 type=7z
BindToRootFolder: 0x00000000
    [D] sub  26530
            copying.txt  26530
        License.txt  6190
        readme.txt  10542
  progress 0% ... op mode=0 dir=1 sub ... op mode=0 dir=0 License.txt ... readme.txt ... sub/copying.txt ... progress 100%
Extract: 0x00000000 ops=4 errors=0
  op mode=1 dir=1 sub / op mode=2 dir=0 License.txt / op mode=2 dir=0 readme.txt / op mode=1 dir=0 sub/copying.txt
IArchiveFolder::Extract(test, item 0): 0x00000000 ops=4
IFolderOperations::CreateFolder: 0x00000000
    [D] created_by_smoke  0
    [D] sub  26530
            copying.txt  26530
        License.txt  6190
        readme.txt  10542
exit=0 ; out/License.txt out/readme.txt out/sub/copying.txt
```

(`mode=2` = `NAskMode::kSkip` for the items that share the solid block but were not selected — the expected 7z behaviour.)

Two pitfalls found on the way, both documented above: `arcFormat == NULL` crashes in `ParseOpenTypes` (pass `L""`), and the unpatched `CompareFileNames_ForFolderList`/`SetExtractErrorMessage`/`NWorkDir::CInfo::Load` are unresolved externals.

## Appendix B. Scratch artifacts (for re-checking; not part of the repository)

| Path under `$SP` | Content |
|---|---|
| `make-n.log`, `srclist.txt` | `make -n` dry run of the macOS 7zz build and the per-source compiler/flag list derived from it (section 1.4) |
| `build.log`, `b/m_arm64/` | full build log (0 errors), 323 objects, `7zz` |
| `audit/run_audit.sh`, `audit/results.tsv`, `audit/log/*.{strict,lax}.log`, `audit/obj/` | the 199-file portability compile (section 3); columns: path, strict rc, lax rc, first strict error, first lax error |
| `ovl/make_overlay.py`, `ovl/compile.sh`, `ovl/agent_mac.patch`, `ovl/obj/` | the patched overlay (section 4.2) and its strict-clean objects |
| `smoke/build.sh`, `ovl/7zip/UI/Agent/agent_smoke.cpp`, `smoke/smoke`, `smoke/test.7z`, `smoke/out/` | Appendix A |
