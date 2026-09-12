// SZRootFolder.mm -- see SZRootFolder.h

#import "SZRootFolder.h"
#import "Internal/SZBridgeUtils.h"
#import "Internal/SZFolder+Internal.h"

using namespace NMacFolders;

@implementation SZRootFolder

+ (SZRootFolder *)rootFolder
{
  CRootFolderMac *spec = new CRootFolderMac;
  CMyComPtr<IFolderFolder> raw = spec;
  spec->Init();
  SZRootFolder *folder = [[SZRootFolder alloc] initWithRawFolder:raw archive:nil];
  [folder loadItems:NULL];
  return folder;
}

+ (SZFolder *)volumesFolder
{
  CVolumesFolderMac *spec = new CVolumesFolderMac;
  CMyComPtr<IFolderFolder> raw = spec;
  SZRootFolder *folder = [[SZRootFolder alloc] initWithRawFolder:raw archive:nil];
  [folder loadItems:NULL];
  return folder;
}

+ (NSArray<NSString *> *)rootEntryNames
{
  UString names[kNumRootFolderItems];
  RootFolder_GetNames(names);
  NSMutableArray *result = [NSMutableArray arrayWithCapacity:kNumRootFolderItems];
  for (unsigned i = 0; i < kNumRootFolderItems; i++)
    [result addObject:SZStringFromUString(names[i])];
  return result;
}

- (NSString *)fullPath
{
  NSString *p = self.path;
  return p.length ? [p stringByAppendingString:@"/"] : @"";
}

@end
