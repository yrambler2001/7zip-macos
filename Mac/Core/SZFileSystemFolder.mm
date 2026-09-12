// SZFileSystemFolder.mm -- see SZFileSystemFolder.h

#import "SZFileSystemFolder.h"
#import "SZError.h"
#import "Internal/SZBridgeUtils.h"
#import "Internal/SZFolder+Internal.h"

using namespace NMacFolders;

@implementation SZFileSystemFolder

+ (SZFileSystemFolder *)folderWithPath:(NSString *)directoryPath error:(NSError **)error
{
  const FString path = SZFStringFromNSString([directoryPath stringByExpandingTildeInPath]);
  CFSFolderMac *spec = new CFSFolderMac;
  CMyComPtr<IFolderFolder> raw = spec;
  const HRESULT hr = spec->Init(path);
  if (hr == E_INVALIDARG)
  {
    if (error)
    {
      const BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:directoryPath];
      *error = [SZErrors errorWithCode:exists ? SZErrorCodeNotFolder : SZErrorCodeFileNotFound
                              message:[NSString stringWithFormat:exists ? @"Not a folder: %@" : @"Folder not found: %@", directoryPath]];
    }
    return nil;
  }
  if (SZFail(hr, error, nil))
    return nil;
  SZFileSystemFolder *folder = [[SZFileSystemFolder alloc] initWithRawFolder:raw archive:nil];
  if (![folder loadItems:error])
    return nil;
  return folder;
}

- (NSString *)directoryPath
{
  return self.path;
}

- (NSString *)fullPathOfItemAtIndex:(NSInteger)index
{
  return [self.path stringByAppendingString:[self nameOfItemAtIndex:index]];
}

+ (NSSet<NSNumber *> *)defaultHiddenPropIDs
{
  // GetColumnVisible (PanelItems.cpp:25-51)
  return [NSSet setWithArray:@[ @(SZPropIDATime), @(SZPropIDChangeTime), @(SZPropIDAttrib), @(SZPropIDPackSize),
                                @(SZPropIDINode), @(SZPropIDLinks), @(SZPropIDNtReparse) ]];
}

@end
