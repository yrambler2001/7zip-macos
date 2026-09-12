// FSFolderMac.cpp -- see FSFolderMac.h. Modelled on UI/FileManager/FSFolder.cpp (Windows).

#include "FSFolderMac.h"

#include <sys/stat.h>
#include <errno.h>

#include "../../../CPP/Common/ComTry.h"
#include "../../../CPP/Common/Defs.h"
#include "../../../CPP/Windows/FileIO.h"
#include "../../../CPP/Common/StringConvert.h"
#include "../../../CPP/Windows/FileDir.h"
#include "../../../CPP/Windows/FileName.h"
#include "../../../CPP/Windows/PropVariant.h"
#include "../../../CPP/Windows/TimeUtils.h"
#include "../../../CPP/7zip/PropID.h"

#include "FSEventsWatcher.h"

using namespace NWindows;
using namespace NFile;
using namespace NFind;

namespace NMacFolders {

// Column order as 7zFM shows them for FSFolder (01-fm-feature-inventory.md 3.2).
static const Byte kProps[] =
{
  kpidName,
  kpidSize,
  kpidMTime,
  kpidCTime,
  kpidATime,
  kpidAttrib
};

CFSFolderMac::CFSFolderMac(): _watcher(NULL) {}

CFSFolderMac::~CFSFolderMac()
{
  delete _watcher;
}

bool CFSFolderMac::IsDirectory(const FString &path)
{
  struct stat st;
  if (stat(path, &st) != 0)
    return false;
  return S_ISDIR(st.st_mode);
}

HRESULT CFSFolderMac::Init(const FString &path)
{
  FString p = path;
  if (p.IsEmpty())
    return E_INVALIDARG;
  if (!NName::IsAbsolutePath(fs2us(p)))
  {
    FString full;
    if (!NDir::MyGetFullPathName(p, full))
      return GetLastError_noZero_HRESULT();
    p = full;
  }
  NName::NormalizeDirPathPrefix(p);
  if (!IsDirectory(p))
    return E_INVALIDARG;
  _path = p;
  _items.Clear();
  return S_OK;
}

FString CFSFolderMac::GetItemPath(UInt32 index) const
{
  FString s = _path;
  s += _items[index].Info.Name;
  return s;
}

Z7_COM7F_IMF(CFSFolderMac::LoadItems())
{
  COM_TRY_BEGIN
  _items.Clear();
  CEnumerator enumerator;
  enumerator.SetDirPrefix(_path);
  for (;;)
  {
    CDirEntry de;
    bool found;
    if (!enumerator.Next(de, found))
      return GetLastError_noZero_HRESULT();
    if (!found)
      break;
    CFSItem item;
    item.Info.ClearBase();
    item.Info.Name = de.Name;
    item.IsDir = false;
    const FString full = _path + de.Name;
    struct stat st;
    if (lstat(full, &st) == 0)
    {
      item.Info.SetFrom_stat(st);
      // "Created" column = birth time on macOS (the engine keeps st_ctime for compatibility)
      item.Info.CTime = st.st_birthtimespec;
      item.IsDir = S_ISDIR(st.st_mode);
      if (!item.IsDir && S_ISLNK(st.st_mode))
      {
        struct stat st2;
        if (stat(full, &st2) == 0 && S_ISDIR(st2.st_mode))
          item.IsDir = true;   // symlink to a directory navigates like a directory
      }
    }
    item.Name = fs2us(de.Name);
    _items.Add(item);
  }
  return S_OK;
  COM_TRY_END
}

Z7_COM7F_IMF(CFSFolderMac::GetNumberOfItems(UInt32 *numItems))
{
  *numItems = _items.Size();
  return S_OK;
}

Z7_COM7F_IMF(CFSFolderMac::GetProperty(UInt32 itemIndex, PROPID propID, PROPVARIANT *value))
{
  COM_TRY_BEGIN
  NCOM::CPropVariant prop;
  if (itemIndex >= _items.Size())
    return E_INVALIDARG;
  const CFSItem &item = _items[itemIndex];
  const CFileInfo &fi = item.Info;
  switch (propID)
  {
    case kpidIsDir: prop = item.IsDir; break;
    case kpidName: prop = item.Name; break;
    case kpidSize: if (!item.IsDir) prop = fi.Size; break;
    case kpidAttrib: prop = (UInt32)fi.GetWinAttrib(); break;
    case kpidPosixAttrib: prop = (UInt32)fi.GetPosixAttrib(); break;
    case kpidCTime: PropVariant_SetFrom_FiTime(prop, fi.CTime); break;
    case kpidATime: PropVariant_SetFrom_FiTime(prop, fi.ATime); break;
    case kpidMTime: PropVariant_SetFrom_FiTime(prop, fi.MTime); break;
    case kpidINode: prop = (UInt64)fi.ino; break;
    case kpidLinks: prop = (UInt32)fi.nlink; break;
    case kpidSymLink: if (fi.IsPosixLink()) prop = true; break;
    default: break;
  }
  prop.Detach(value);
  return S_OK;
  COM_TRY_END
}

HRESULT CFSFolderMac::BindToFolderSpec(const FString &path, IFolderFolder **resultFolder)
{
  *resultFolder = NULL;
  CFSFolderMac *folderSpec = new CFSFolderMac;
  CMyComPtr<IFolderFolder> subFolder = folderSpec;
  RINOK(folderSpec->Init(path))
  *resultFolder = subFolder.Detach();
  return S_OK;
}

Z7_COM7F_IMF(CFSFolderMac::BindToFolder(UInt32 index, IFolderFolder **resultFolder))
{
  COM_TRY_BEGIN
  *resultFolder = NULL;
  if (index >= _items.Size())
    return E_INVALIDARG;
  if (!_items[index].IsDir)
    return E_INVALIDARG;   // files (archives) are opened by SZArchiveOpener
  return BindToFolderSpec(GetItemPath(index), resultFolder);
  COM_TRY_END
}

Z7_COM7F_IMF(CFSFolderMac::BindToFolder(const wchar_t *name, IFolderFolder **resultFolder))
{
  COM_TRY_BEGIN
  *resultFolder = NULL;
  const UString u = name;
  FString path;
  if (NName::IsAbsolutePath(u))
    path = us2fs(u);
  else
    path = _path + us2fs(u);
  return BindToFolderSpec(path, resultFolder);
  COM_TRY_END
}

Z7_COM7F_IMF(CFSFolderMac::BindToParentFolder(IFolderFolder **resultFolder))
{
  COM_TRY_BEGIN
  *resultFolder = NULL;
  if (_path.Len() <= 1)
    return S_OK;   // "/" has no parent here; the caller falls back to the root folder
  FString parent = _path;
  parent.DeleteBack();   // trailing '/'
  const int pos = parent.ReverseFind_PathSepar();
  if (pos < 0)
    return S_OK;
  parent.DeleteFrom((unsigned)pos + 1);
  return BindToFolderSpec(parent, resultFolder);
  COM_TRY_END
}

IMP_IFolderFolder_Props(CFSFolderMac)

Z7_COM7F_IMF(CFSFolderMac::GetFolderProperty(PROPID propID, PROPVARIANT *value))
{
  COM_TRY_BEGIN
  NCOM::CPropVariant prop;
  switch (propID)
  {
    case kpidType: prop = "FSFolder"; break;
    case kpidPath: prop = fs2us(_path); break;
    default: break;
  }
  prop.Detach(value);
  return S_OK;
  COM_TRY_END
}

// ---- IFolderGetItemName --------------------------------------------------------

Z7_COM7F_IMF(CFSFolderMac::GetItemName(UInt32 index, const wchar_t **name, unsigned *len))
{
  *name = NULL;
  *len = 0;
  if (index >= _items.Size())
    return E_INVALIDARG;
  const UString &s = _items[index].Name;
  *name = s.Ptr();
  *len = s.Len();
  return S_OK;
}

Z7_COM7F_IMF(CFSFolderMac::GetItemPrefix(UInt32 index, const wchar_t **name, unsigned *len))
{
  UNUSED_VAR(index)
  *name = NULL;
  *len = 0;
  return S_OK;
}

Z7_COM7F_IMF2(UInt64, CFSFolderMac::GetItemSize(UInt32 index))
{
  if (index >= _items.Size())
    return 0;
  const CFSItem &item = _items[index];
  return item.IsDir ? 0 : item.Info.Size;
}

// ---- IFolderWasChanged (FSEvents) ------------------------------------------------

Z7_COM7F_IMF(CFSFolderMac::WasChanged(Int32 *wasChanged))
{
  *wasChanged = BoolToInt(false);
  if (!_watcher)
  {
    // lazily started on first poll so that folders nobody watches cost nothing
    _watcher = new CFSEventsWatcher(_path);
    return S_OK;
  }
  *wasChanged = BoolToInt(_watcher->ConsumeChanged());
  return S_OK;
}

// ---- IFolderClone ----------------------------------------------------------------

Z7_COM7F_IMF(CFSFolderMac::Clone(IFolderFolder **resultFolder))
{
  COM_TRY_BEGIN
  return BindToFolderSpec(_path, resultFolder);
  COM_TRY_END
}

// ---- IFolderCompare (PanelSort.cpp CompareItems2 property rules) -------------------

static int CompareExtensions(const UString &a, const UString &b)
{
  const int pa = a.ReverseFind_Dot();
  const int pb = b.ReverseFind_Dot();
  const wchar_t *ea = pa < 0 ? L"" : a.Ptr((unsigned)pa + 1);
  const wchar_t *eb = pb < 0 ? L"" : b.Ptr((unsigned)pb + 1);
  return CompareFileNames_ForFolderList(ea, eb);
}

Z7_COM7F_IMF2(Int32, CFSFolderMac::CompareItems(UInt32 index1, UInt32 index2, PROPID propID, Int32 propIsRaw))
{
  UNUSED_VAR(propIsRaw)
  if (index1 >= _items.Size() || index2 >= _items.Size())
    return 0;
  const CFSItem &a = _items[index1];
  const CFSItem &b = _items[index2];
  switch (propID)
  {
    case kpidName: return CompareFileNames_ForFolderList(a.Name, b.Name);
    case kpidExtension: return CompareExtensions(a.Name, b.Name);
    case kpidIsDir: return MyCompare((int)a.IsDir, (int)b.IsDir);
    case kpidSize: return MyCompare(a.IsDir ? 0 : a.Info.Size, b.IsDir ? 0 : b.Info.Size);
    case kpidAttrib: return MyCompare(a.Info.GetWinAttrib(), b.Info.GetWinAttrib());
    case kpidCTime: return Compare_FiTime(&a.Info.CTime, &b.Info.CTime);
    case kpidATime: return Compare_FiTime(&a.Info.ATime, &b.Info.ATime);
    case kpidMTime: return Compare_FiTime(&a.Info.MTime, &b.Info.MTime);
    case kpidINode: return MyCompare((UInt64)a.Info.ino, (UInt64)b.Info.ino);
    case kpidLinks: return MyCompare((UInt32)a.Info.nlink, (UInt32)b.Info.nlink);
    default: return 0;
  }
}

// ---- IFolderOperations: TODO (Wave "fs-ops"). The interface is in place so that
// QueryInterface(IID_IFolderOperations) succeeds and the panel can enable the menu
// items; every method reports E_NOTIMPL until FSFolderCopy-equivalent code lands
// (copy/move with progress + overwrite prompts, trash via NSFileManager, rename,
// mkdir, create file, comment via TextPairs, CopyFromFile).

Z7_COM7F_IMF(CFSFolderMac::CreateFolder(const wchar_t *name, IProgress *progress))
{
  UNUSED_VAR(name) UNUSED_VAR(progress)
  return E_NOTIMPL;   // TODO: NDir::CreateDir(_path + name)
}

Z7_COM7F_IMF(CFSFolderMac::CreateFile(const wchar_t *name, IProgress *progress))
{
  UNUSED_VAR(name) UNUSED_VAR(progress)
  return E_NOTIMPL;   // TODO: NIO::COutFile::Create_NEW
}

Z7_COM7F_IMF(CFSFolderMac::Rename(UInt32 index, const wchar_t *newName, IProgress *progress))
{
  UNUSED_VAR(index) UNUSED_VAR(newName) UNUSED_VAR(progress)
  return E_NOTIMPL;   // TODO: NDir::MyMoveFile
}

Z7_COM7F_IMF(CFSFolderMac::Delete(const UInt32 *indices, UInt32 numItems, IProgress *progress))
{
  UNUSED_VAR(indices) UNUSED_VAR(numItems) UNUSED_VAR(progress)
  return E_NOTIMPL;   // TODO: trash (NSFileManager trashItemAtURL) or permanent delete
}

Z7_COM7F_IMF(CFSFolderMac::CopyTo(Int32 moveMode, const UInt32 *indices, UInt32 numItems,
    Int32 includeAltStreams, Int32 replaceAltStreamCharsMode,
    const wchar_t *path, IFolderOperationsExtractCallback *callback))
{
  UNUSED_VAR(moveMode) UNUSED_VAR(indices) UNUSED_VAR(numItems)
  UNUSED_VAR(includeAltStreams) UNUSED_VAR(replaceAltStreamCharsMode)
  UNUSED_VAR(path) UNUSED_VAR(callback)
  return E_NOTIMPL;   // TODO: FSFolderCopy.cpp equivalent with progress + AskWrite
}

Z7_COM7F_IMF(CFSFolderMac::CopyFrom(Int32 moveMode, const wchar_t *fromFolderPath,
    const wchar_t * const *itemsPaths, UInt32 numItems, IProgress *progress))
{
  UNUSED_VAR(moveMode) UNUSED_VAR(fromFolderPath) UNUSED_VAR(itemsPaths)
  UNUSED_VAR(numItems) UNUSED_VAR(progress)
  return E_NOTIMPL;   // TODO
}

Z7_COM7F_IMF(CFSFolderMac::SetProperty(UInt32 index, PROPID propID, const PROPVARIANT *value, IProgress *progress))
{
  UNUSED_VAR(index) UNUSED_VAR(propID) UNUSED_VAR(value) UNUSED_VAR(progress)
  return E_NOTIMPL;   // TODO: kpidComment via descript.ion (CPairsStorage)
}

Z7_COM7F_IMF(CFSFolderMac::CopyFromFile(UInt32 index, const wchar_t *fullFilePath, IProgress *progress))
{
  UNUSED_VAR(index) UNUSED_VAR(fullFilePath) UNUSED_VAR(progress)
  return E_NOTIMPL;   // TODO
}

}
