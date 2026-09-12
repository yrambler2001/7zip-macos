// RootFolderMac.cpp -- see RootFolderMac.h

#include "RootFolderMac.h"

#include <sys/mount.h>
#include <sys/param.h>
#include <sys/stat.h>
#include <dirent.h>
#include <pwd.h>
#include <unistd.h>

#include <errno.h>
#include <string.h>
#include "../../../CPP/Common/ComTry.h"
#include "../../../CPP/Common/Defs.h"
#include "../../../CPP/Windows/FileIO.h"
#include "../../../CPP/Common/StringConvert.h"
#include "../../../CPP/Windows/FileName.h"
#include "../../../CPP/Windows/PropVariant.h"
#include "../../../CPP/Windows/ResourceString.h"
#include "../../../CPP/7zip/PropID.h"

#include "FSFolderMac.h"

using namespace NWindows;
using namespace NFile;

namespace NMacFolders {

static FString HomeDir()
{
  const char *h = getenv("HOME");
  if (!h || !*h)
  {
    const struct passwd *pw = getpwuid(getuid());
    if (pw && pw->pw_dir)
      h = pw->pw_dir;
  }
  FString s(h ? h : "/");
  NName::NormalizeDirPathPrefix(s);
  return s;
}

void RootFolder_GetNames(UString names[kNumRootFolderItems])
{
  names[ROOT_INDEX_COMPUTER] = MyLoadString(7100);     // IDS_COMPUTER
  if (names[ROOT_INDEX_COMPUTER].IsEmpty())
    names[ROOT_INDEX_COMPUTER] = "Computer";
  names[ROOT_INDEX_VOLUMES] = "Volumes";
  names[ROOT_INDEX_HOME] = "Home";
  names[ROOT_INDEX_DOCUMENTS] = MyLoadString(7102);    // IDS_DOCUMENTS
  if (names[ROOT_INDEX_DOCUMENTS].IsEmpty())
    names[ROOT_INDEX_DOCUMENTS] = "Documents";
}

static HRESULT MakeFsFolder(const FString &path, IFolderFolder **resultFolder)
{
  *resultFolder = NULL;
  CFSFolderMac *spec = new CFSFolderMac;
  CMyComPtr<IFolderFolder> folder = spec;
  RINOK(spec->Init(path))
  *resultFolder = folder.Detach();
  return S_OK;
}

static HRESULT MakeVolumesFolder(IFolderFolder **resultFolder)
{
  *resultFolder = NULL;
  CVolumesFolderMac *spec = new CVolumesFolderMac;
  CMyComPtr<IFolderFolder> folder = spec;
  RINOK(folder->LoadItems())
  *resultFolder = folder.Detach();
  return S_OK;
}

static HRESULT MakeRootFolder(IFolderFolder **resultFolder)
{
  *resultFolder = NULL;
  CRootFolderMac *spec = new CRootFolderMac;
  CMyComPtr<IFolderFolder> folder = spec;
  spec->Init();
  *resultFolder = folder.Detach();
  return S_OK;
}

// ---- CRootFolderMac ----------------------------------------------------------------

static const Byte kRootProps[] = { kpidName };

void CRootFolderMac::Init()
{
  RootFolder_GetNames(_names);
}

Z7_COM7F_IMF(CRootFolderMac::LoadItems())
{
  Init();
  return S_OK;
}

Z7_COM7F_IMF(CRootFolderMac::GetNumberOfItems(UInt32 *numItems))
{
  *numItems = kNumRootFolderItems;
  return S_OK;
}

Z7_COM7F_IMF(CRootFolderMac::GetProperty(UInt32 itemIndex, PROPID propID, PROPVARIANT *value))
{
  NCOM::CPropVariant prop;
  if (itemIndex >= kNumRootFolderItems)
    return E_INVALIDARG;
  switch (propID)
  {
    case kpidIsDir: prop = true; break;
    case kpidName: prop = _names[itemIndex]; break;
    default: break;
  }
  prop.Detach(value);
  return S_OK;
}

Z7_COM7F_IMF(CRootFolderMac::BindToFolder(UInt32 index, IFolderFolder **resultFolder))
{
  COM_TRY_BEGIN
  *resultFolder = NULL;
  switch (index)
  {
    case ROOT_INDEX_COMPUTER: return MakeFsFolder(FString("/"), resultFolder);
    case ROOT_INDEX_VOLUMES: return MakeVolumesFolder(resultFolder);
    case ROOT_INDEX_HOME: return MakeFsFolder(HomeDir(), resultFolder);
    case ROOT_INDEX_DOCUMENTS: return MakeFsFolder(HomeDir() + "Documents/", resultFolder);
    default: return E_INVALIDARG;
  }
  COM_TRY_END
}

static bool AreEqualNames(const UString &path, const UString &name)
{
  const unsigned len = name.Len();
  if (len > path.Len() || len + 1 < path.Len())
    return false;
  if (len + 1 == path.Len() && !IS_PATH_SEPAR(path[len]))
    return false;
  return path.IsPrefixedBy_NoCase(name);
}

Z7_COM7F_IMF(CRootFolderMac::BindToFolder(const wchar_t *name, IFolderFolder **resultFolder))
{
  COM_TRY_BEGIN
  *resultFolder = NULL;
  UString name2 = name;
  name2.Trim();

  if (name2.IsEmpty())
    return MakeRootFolder(resultFolder);

  for (unsigned i = 0; i < kNumRootFolderItems; i++)
    if (AreEqualNames(name2, _names[i]))
      return BindToFolder((UInt32)i, resultFolder);

  if (AreEqualNames(name2, UString("Computer")) || AreEqualNames(name2, UString("My Computer")))
    return BindToFolder((UInt32)ROOT_INDEX_COMPUTER, resultFolder);
  if (AreEqualNames(name2, UString("Documents")) || AreEqualNames(name2, UString("My Documents")))
    return BindToFolder((UInt32)ROOT_INDEX_DOCUMENTS, resultFolder);

  if (name2[0] == L'~')
  {
    UString rest = name2.Ptr(1);
    if (rest.IsEmpty() || IS_PATH_SEPAR(rest[0]))
    {
      FString p = HomeDir();
      if (!rest.IsEmpty())
        p += us2fs(rest.Ptr(1));
      NName::NormalizeDirPathPrefix(p);
      return MakeFsFolder(p, resultFolder);
    }
  }

  if (!NName::IsAbsolutePath(name2))
    return E_INVALIDARG;
  FString p = us2fs(name2);
  NName::NormalizeDirPathPrefix(p);
  return MakeFsFolder(p, resultFolder);
  COM_TRY_END
}

Z7_COM7F_IMF(CRootFolderMac::BindToParentFolder(IFolderFolder **resultFolder))
{
  *resultFolder = NULL;
  return S_OK;
}

Z7_COM7F_IMF(CRootFolderMac::GetNumberOfProperties(UInt32 *numProperties))
{
  *numProperties = Z7_ARRAY_SIZE(kRootProps);
  return S_OK;
}

IMP_IFolderFolder_GetProp(CRootFolderMac::GetPropertyInfo, kRootProps)

Z7_COM7F_IMF(CRootFolderMac::GetFolderProperty(PROPID propID, PROPVARIANT *value))
{
  NCOM::CPropVariant prop;
  switch (propID)
  {
    case kpidType: prop = "RootFolder"; break;
    case kpidPath: prop = ""; break;
    default: break;
  }
  prop.Detach(value);
  return S_OK;
}

Z7_COM7F_IMF(CRootFolderMac::GetItemName(UInt32 index, const wchar_t **name, unsigned *len))
{
  *name = NULL;
  *len = 0;
  if (index >= kNumRootFolderItems)
    return E_INVALIDARG;
  *name = _names[index].Ptr();
  *len = _names[index].Len();
  return S_OK;
}

Z7_COM7F_IMF(CRootFolderMac::GetItemPrefix(UInt32 index, const wchar_t **name, unsigned *len))
{
  UNUSED_VAR(index)
  *name = NULL;
  *len = 0;
  return S_OK;
}

Z7_COM7F_IMF2(UInt64, CRootFolderMac::GetItemSize(UInt32 index))
{
  UNUSED_VAR(index)
  return 0;
}

// ---- CVolumesFolderMac (FSDrives) ----------------------------------------------------

static const Byte kVolProps[] =
{
  kpidName,
  kpidTotalSize,
  kpidFreeSpace,
  kpidType,
  kpidVolumeName,
  kpidFileSystem,
  kpidClusterSize
};

Z7_COM7F_IMF(CVolumesFolderMac::LoadItems())
{
  COM_TRY_BEGIN
  _volumes.Clear();
  DIR *dir = opendir("/Volumes");
  if (!dir)
    return GetLastError_noZero_HRESULT();
  for (;;)
  {
    errno = 0;
    const struct dirent *de = readdir(dir);
    if (!de)
      break;
    if (de->d_name[0] == '.')
      continue;
    FString path("/Volumes/");
    path += de->d_name;
    struct statfs fs;
    if (statfs(path, &fs) != 0)
      continue;
    struct stat st;
    if (stat(path, &st) != 0 || !S_ISDIR(st.st_mode))
      continue;
    CVolumeItem v;
    v.Name = MultiByteToUnicodeString(de->d_name, CP_UTF8);
    v.MountPath = fs.f_mntonname;
    NName::NormalizeDirPathPrefix(v.MountPath);
    v.FileSystem = MultiByteToUnicodeString(fs.f_fstypename, CP_UTF8);
    v.TotalSize = (UInt64)fs.f_blocks * fs.f_bsize;
    v.FreeSpace = (UInt64)fs.f_bavail * fs.f_bsize;
    v.ClusterSize = fs.f_bsize;
    if (strcmp(fs.f_fstypename, "cd9660") == 0 || strcmp(fs.f_fstypename, "udf") == 0)
      v.Type = "CD-ROM";
    else if ((fs.f_flags & MNT_LOCAL) == 0)
      v.Type = "Remote";
    else if (fs.f_flags & MNT_REMOVABLE)
      v.Type = "Removable";
    else
      v.Type = "Fixed";
    _volumes.Add(v);
  }
  closedir(dir);
  return S_OK;
  COM_TRY_END
}

Z7_COM7F_IMF(CVolumesFolderMac::GetNumberOfItems(UInt32 *numItems))
{
  *numItems = _volumes.Size();
  return S_OK;
}

Z7_COM7F_IMF(CVolumesFolderMac::GetProperty(UInt32 itemIndex, PROPID propID, PROPVARIANT *value))
{
  NCOM::CPropVariant prop;
  if (itemIndex >= _volumes.Size())
    return E_INVALIDARG;
  const CVolumeItem &v = _volumes[itemIndex];
  switch (propID)
  {
    case kpidIsDir: prop = true; break;
    case kpidName: prop = v.Name; break;
    case kpidVolumeName: prop = v.Name; break;
    case kpidTotalSize: prop = v.TotalSize; break;
    case kpidFreeSpace: prop = v.FreeSpace; break;
    case kpidClusterSize: prop = v.ClusterSize; break;
    case kpidType: prop = v.Type; break;
    case kpidFileSystem: prop = v.FileSystem; break;
    case kpidPath: prop = fs2us(v.MountPath); break;
    default: break;
  }
  prop.Detach(value);
  return S_OK;
}

Z7_COM7F_IMF(CVolumesFolderMac::BindToFolder(UInt32 index, IFolderFolder **resultFolder))
{
  COM_TRY_BEGIN
  *resultFolder = NULL;
  if (index >= _volumes.Size())
    return E_INVALIDARG;
  return MakeFsFolder(_volumes[index].MountPath, resultFolder);
  COM_TRY_END
}

Z7_COM7F_IMF(CVolumesFolderMac::BindToFolder(const wchar_t *name, IFolderFolder **resultFolder))
{
  COM_TRY_BEGIN
  *resultFolder = NULL;
  UString name2 = name;
  name2.Trim();
  FOR_VECTOR (i, _volumes)
    if (AreEqualNames(name2, _volumes[i].Name))
      return BindToFolder((UInt32)i, resultFolder);
  if (!NName::IsAbsolutePath(name2))
    return E_INVALIDARG;
  FString p = us2fs(name2);
  NName::NormalizeDirPathPrefix(p);
  return MakeFsFolder(p, resultFolder);
  COM_TRY_END
}

Z7_COM7F_IMF(CVolumesFolderMac::BindToParentFolder(IFolderFolder **resultFolder))
{
  COM_TRY_BEGIN
  return MakeRootFolder(resultFolder);
  COM_TRY_END
}

Z7_COM7F_IMF(CVolumesFolderMac::GetNumberOfProperties(UInt32 *numProperties))
{
  *numProperties = Z7_ARRAY_SIZE(kVolProps);
  return S_OK;
}

IMP_IFolderFolder_GetProp(CVolumesFolderMac::GetPropertyInfo, kVolProps)

Z7_COM7F_IMF(CVolumesFolderMac::GetFolderProperty(PROPID propID, PROPVARIANT *value))
{
  NCOM::CPropVariant prop;
  switch (propID)
  {
    case kpidType: prop = "FSDrives"; break;
    case kpidPath: prop = "Volumes"; break;
    default: break;
  }
  prop.Detach(value);
  return S_OK;
}

Z7_COM7F_IMF(CVolumesFolderMac::GetItemName(UInt32 index, const wchar_t **name, unsigned *len))
{
  *name = NULL;
  *len = 0;
  if (index >= _volumes.Size())
    return E_INVALIDARG;
  *name = _volumes[index].Name.Ptr();
  *len = _volumes[index].Name.Len();
  return S_OK;
}

Z7_COM7F_IMF(CVolumesFolderMac::GetItemPrefix(UInt32 index, const wchar_t **name, unsigned *len))
{
  UNUSED_VAR(index)
  *name = NULL;
  *len = 0;
  return S_OK;
}

Z7_COM7F_IMF2(UInt64, CVolumesFolderMac::GetItemSize(UInt32 index))
{
  UNUSED_VAR(index)
  return 0;
}

}
