// RootFolderMac.h -- the virtual root (RootFolder.cpp) and the volumes list (FSDrives.cpp)
// for macOS. Root items: Computer ("/"), Volumes, Home, Documents.

#ifndef ZIP7_INC_MAC_ROOT_FOLDER_H
#define ZIP7_INC_MAC_ROOT_FOLDER_H

#include "../../../CPP/Common/Common.h"
#include "../../../CPP/Common/MyCom.h"
#include "../../../CPP/Common/MyString.h"
#include "../../../CPP/7zip/UI/FileManager/IFolder.h"

namespace NMacFolders {

enum
{
  ROOT_INDEX_COMPUTER = 0,
  ROOT_INDEX_VOLUMES,
  ROOT_INDEX_HOME,
  ROOT_INDEX_DOCUMENTS,
  kNumRootFolderItems
};

// Localized names of the root entries (7100 Computer, 7102 Documents; "Volumes", "Home").
void RootFolder_GetNames(UString names[kNumRootFolderItems]);

class CRootFolderMac Z7_final:
  public IFolderFolder,
  public IFolderGetItemName,
  public CMyUnknownImp
{
  Z7_COM_QI_BEGIN2(IFolderFolder)
    Z7_COM_QI_ENTRY(IFolderGetItemName)
  Z7_COM_QI_END
  Z7_COM_ADDREF_RELEASE

  Z7_IFACE_COM7_IMP(IFolderFolder)
  Z7_IFACE_COM7_IMP(IFolderGetItemName)

  UString _names[kNumRootFolderItems];
public:
  void Init();
};

struct CVolumeItem
{
  UString Name;         // entry name in /Volumes
  FString MountPath;    // f_mntonname, trailing '/'
  UString FileSystem;   // f_fstypename
  UString Type;         // "Fixed", "Removable", "Remote", "CD-ROM"
  UInt64 TotalSize;
  UInt64 FreeSpace;
  UInt64 ClusterSize;
};

class CVolumesFolderMac Z7_final:
  public IFolderFolder,
  public IFolderGetItemName,
  public CMyUnknownImp
{
  Z7_COM_QI_BEGIN2(IFolderFolder)
    Z7_COM_QI_ENTRY(IFolderGetItemName)
  Z7_COM_QI_END
  Z7_COM_ADDREF_RELEASE

  Z7_IFACE_COM7_IMP(IFolderFolder)
  Z7_IFACE_COM7_IMP(IFolderGetItemName)

  CObjectVector<CVolumeItem> _volumes;
public:
  const CObjectVector<CVolumeItem> &Volumes() const { return _volumes; }
};

}

#endif
