// FSFolderMac.h -- IFolderFolder for a directory (the macOS FSFolder), built on the
// portable NWindows::NFile::NFind layer. Exposes the 7zFM columns Name, Size, Modified,
// Created, Accessed, Attributes (+ kpidIsDir as an item value), IFolderGetItemName,
// IFolderWasChanged (FSEvents), IFolderClone, IFolderCompare. IFolderOperations is
// declared and stubbed (copy/move/delete/rename/create are a later wave).

#ifndef ZIP7_INC_MAC_FS_FOLDER_H
#define ZIP7_INC_MAC_FS_FOLDER_H

#include "../../../CPP/Common/Common.h"
#include "../../../CPP/Common/MyCom.h"
#include "../../../CPP/Common/MyString.h"
#include "../../../CPP/Windows/FileFind.h"
#include "../../../CPP/7zip/UI/FileManager/IFolder.h"

namespace NMacFolders {

class CFSEventsWatcher;

struct CFSItem
{
  NWindows::NFile::NFind::CFileInfo Info;   // lstat of the entry (CTime = birth time)
  UString Name;                              // Info.Name as UString
  bool IsDir;                                // directory, or symlink to a directory
};

class CFSFolderMac Z7_final:
  public IFolderFolder,
  public IFolderGetItemName,
  public IFolderWasChanged,
  public IFolderOperations,
  public IFolderClone,
  public IFolderCompare,
  public CMyUnknownImp
{
  Z7_COM_QI_BEGIN2(IFolderFolder)
    Z7_COM_QI_ENTRY(IFolderGetItemName)
    Z7_COM_QI_ENTRY(IFolderWasChanged)
    Z7_COM_QI_ENTRY(IFolderOperations)
    Z7_COM_QI_ENTRY(IFolderClone)
    Z7_COM_QI_ENTRY(IFolderCompare)
  Z7_COM_QI_END
  Z7_COM_ADDREF_RELEASE

  Z7_IFACE_COM7_IMP(IFolderFolder)
  Z7_IFACE_COM7_IMP(IFolderGetItemName)
  Z7_IFACE_COM7_IMP(IFolderWasChanged)
  Z7_IFACE_COM7_IMP(IFolderOperations)
  Z7_IFACE_COM7_IMP(IFolderClone)
  Z7_IFACE_COM7_IMP(IFolderCompare)

  FString _path;                 // absolute, trailing '/'
  CObjectVector<CFSItem> _items;
  CFSEventsWatcher *_watcher;

  HRESULT BindToFolderSpec(const FString &path, IFolderFolder **resultFolder);

public:
  CFSFolderMac();
  ~CFSFolderMac();

  // Fails with E_INVALIDARG when `path` is not a directory.
  HRESULT Init(const FString &path);
  const FString &GetPath() const { return _path; }
  FString GetItemPath(UInt32 index) const;
  unsigned NumItems() const { return _items.Size(); }
  const CFSItem &Item(unsigned i) const { return _items[i]; }

  static bool IsDirectory(const FString &path);
};

}

#endif
