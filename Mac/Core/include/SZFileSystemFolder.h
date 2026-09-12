// SZFileSystemFolder.h -- a directory (the macOS replacement for FSFolder).
// C++ implementation: Mac/Core/Internal/FSFolderMac.cpp (IFolderFolder, IFolderGetItemName,
// IFolderWasChanged (FSEvents), IFolderClone, IFolderCompare; IFolderOperations stubbed).

#ifndef SZ_FILE_SYSTEM_FOLDER_H
#define SZ_FILE_SYSTEM_FOLDER_H

#import <Foundation/Foundation.h>
#import <SevenZipKit/SZFolder.h>

NS_ASSUME_NONNULL_BEGIN

@interface SZFileSystemFolder : SZFolder

/// Binds and loads a directory. Fails with SZErrorCodeNotFolder / SZErrorCodeFileNotFound.
+ (nullable SZFileSystemFolder *)folderWithPath:(NSString *)directoryPath error:(NSError **)error NS_SWIFT_NAME(folder(withPath:));

/// Absolute directory path with a trailing "/".
@property (nonatomic, readonly, copy) NSString *directoryPath;
/// Absolute path of an item.
- (NSString *)fullPathOfItemAtIndex:(NSInteger)index NS_SWIFT_NAME(fullPathOfItem(at:));
/// Columns hidden by default in 7zFM for file-system folders (kpidATime, kpidAttrib, ...).
@property (class, nonatomic, readonly) NSSet<NSNumber *> *defaultHiddenPropIDs;

@end

NS_ASSUME_NONNULL_END

#endif
