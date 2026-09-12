// SZRootFolder.h -- the virtual root (Windows RootFolder + FSDrives): Computer ("/"),
// Volumes (mounted volumes from /Volumes with total/free space), Home, Documents.
// C++ implementation: Mac/Core/Internal/RootFolderMac.cpp.

#ifndef SZ_ROOT_FOLDER_H
#define SZ_ROOT_FOLDER_H

#import <Foundation/Foundation.h>
#import <SevenZipKit/SZFolder.h>

NS_ASSUME_NONNULL_BEGIN

@interface SZRootFolder : SZFolder

/// A fresh root folder with items loaded. folderType "RootFolder", path "".
+ (SZRootFolder *)rootFolder NS_SWIFT_NAME(makeRootFolder());
/// The volumes list (folderType "FSDrives"): kpidName, kpidTotalSize, kpidFreeSpace, kpidType,
/// kpidVolumeName, kpidFileSystem, kpidClusterSize.
+ (SZFolder *)volumesFolder NS_SWIFT_NAME(makeVolumesFolder());

/// Names of the root entries in the current language (index 0..3).
@property (class, nonatomic, readonly) NSArray<NSString *> *rootEntryNames;

@end

NS_ASSUME_NONNULL_END

#endif
