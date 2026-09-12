// SZFolder.mm -- see SZFolder.h

#import "SZFolder.h"
#import "SZFileSystemFolder.h"
#import "SZRootFolder.h"
#import "SZArchiveOpener.h"
#import "SZError.h"
#import "Internal/SZBridgeUtils.h"
#import "Internal/SZFolder+Internal.h"

static_assert((uint32_t)SZPropIDNumDefined == (uint32_t)kpid_NUM_DEFINED, "SZPropID is out of sync with PropID.h");
static_assert((uint32_t)SZPropIDPath == kpidPath && (uint32_t)SZPropIDName == kpidName &&
              (uint32_t)SZPropIDIsDir == kpidIsDir && (uint32_t)SZPropIDSize == kpidSize &&
              (uint32_t)SZPropIDMTime == kpidMTime && (uint32_t)SZPropIDAttrib == kpidAttrib &&
              (uint32_t)SZPropIDType == kpidType && (uint32_t)SZPropIDReadOnly == kpidReadOnly &&
              (uint32_t)SZPropIDDevMinor == kpidDevMinor, "SZPropID values drifted");
static_assert((int)SZTimestampLevelMin == kTimestampPrintLevel_MIN && (int)SZTimestampLevelDay == kTimestampPrintLevel_DAY &&
              (int)SZTimestampLevelNS == kTimestampPrintLevel_NS, "SZTimestampLevel drifted");

// ---------------------------------------------------------------------------
@implementation SZPropertyInfo
{
  NSString *_localizedName;
}

- (instancetype)initWithPropID:(SZPropID)propID varType:(SZVarType)varType handlerName:(NSString *)name
{
  self = [super init];
  if (!self)
    return nil;
  _propID = propID;
  _varType = varType;
  _handlerName = [name copy];
  return self;
}

- (NSString *)localizedName
{
  if (!_localizedName)
  {
    const UString handlerName = SZUStringFromNSString(_handlerName);
    _localizedName = SZStringFromUString(GetNameOfProperty((PROPID)_propID, _handlerName ? handlerName.Ptr() : NULL));
  }
  return _localizedName;
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<SZPropertyInfo %u '%@' vt=%u>", (unsigned)_propID, self.localizedName, (unsigned)_varType];
}

@end

// ---------------------------------------------------------------------------
static NSArray<SZPropertyInfo *> *SZReadPropertyInfos(UInt32 count, HRESULT (^getInfo)(UInt32, BSTR *, PROPID *, VARTYPE *))
{
  NSMutableArray *result = [NSMutableArray arrayWithCapacity:count];
  for (UInt32 i = 0; i < count; i++)
  {
    CMyComBSTR name;
    PROPID propID = 0;
    VARTYPE vt = VT_EMPTY;
    if (getInfo(i, &name, &propID, &vt) != S_OK)
      continue;
    NSString *handlerName = nil;
    if ((LPCOLESTR)name)
      handlerName = SZStringFromWChars((LPCOLESTR)name, SysStringLen((BSTR)(LPCOLESTR)name));
    [result addObject:[[SZPropertyInfo alloc] initWithPropID:(SZPropID)propID varType:(SZVarType)vt handlerName:handlerName]];
  }
  return result;
}

@implementation SZArcProps
{
  CMyComPtr<IFolderArcProps> _props;
}

- (instancetype)initWithRawProps:(IFolderArcProps *)props
{
  self = [super init];
  if (!self)
    return nil;
  _props = props;
  return self;
}

- (NSInteger)levelCount
{
  UInt32 n = 0;
  if (_props->GetArcNumLevels(&n) != S_OK)
    return 0;
  return n;
}

- (NSArray<SZPropertyInfo *> *)propertiesAtLevel:(NSInteger)level
{
  UInt32 n = 0;
  if (_props->GetArcNumProps((UInt32)level, &n) != S_OK)
    return @[];
  IFolderArcProps *p = _props;
  return SZReadPropertyInfos(n, ^HRESULT(UInt32 i, BSTR *name, PROPID *propID, VARTYPE *vt) {
    return p->GetArcPropInfo((UInt32)level, i, name, propID, vt);
  });
}

- (id)propertyAtLevel:(NSInteger)level propID:(SZPropID)propID
{
  NWindows::NCOM::CPropVariant prop;
  if (_props->GetArcProp((UInt32)level, (PROPID)propID, &prop) != S_OK)
    return nil;
  return SZObjectFromPropVariant(prop);
}

- (NSString *)displayStringAtLevel:(NSInteger)level propID:(SZPropID)propID
{
  NWindows::NCOM::CPropVariant prop;
  if (_props->GetArcProp((UInt32)level, (PROPID)propID, &prop) != S_OK)
    return @"";
  return SZDisplayStringFromPropVariant(prop, (PROPID)propID, kTimestampPrintLevel_SEC);
}

- (NSArray<SZPropertyInfo *> *)properties2AtLevel:(NSInteger)level
{
  UInt32 n = 0;
  if (_props->GetArcNumProps2((UInt32)level, &n) != S_OK)
    return @[];
  IFolderArcProps *p = _props;
  return SZReadPropertyInfos(n, ^HRESULT(UInt32 i, BSTR *name, PROPID *propID, VARTYPE *vt) {
    return p->GetArcPropInfo2((UInt32)level, i, name, propID, vt);
  });
}

- (id)property2AtLevel:(NSInteger)level propID:(SZPropID)propID
{
  NWindows::NCOM::CPropVariant prop;
  if (_props->GetArcProp2((UInt32)level, (PROPID)propID, &prop) != S_OK)
    return nil;
  return SZObjectFromPropVariant(prop);
}

@end

// ---------------------------------------------------------------------------
@implementation SZFolder
{
  CMyComPtr<IFolderFolder> _folder;
  CMyComPtr<IFolderGetItemName> _getItemName;
  CMyComPtr<IFolderWasChanged> _wasChangedIface;
  CMyComPtr<IFolderSetFlatMode> _setFlatMode;
  CMyComPtr<IFolderCompare> _compare;
  CMyComPtr<IGetFolderArcProps> _getArcProps;
  SZArchive *_archive;
  NSInteger _itemCount;
  BOOL _flatMode;
  NSString *_folderType;
  NSString *_path;
  NSArray<SZPropertyInfo *> *_properties;
}

+ (SZFolder *)folderWithRawFolder:(IFolderFolder *)folder archive:(SZArchive *)archive
{
  NWindows::NCOM::CPropVariant prop;
  NSString *type = @"";
  if (folder->GetFolderProperty(kpidType, &prop) == S_OK && prop.vt == VT_BSTR)
    type = SZObjectFromPropVariant(prop);
  Class cls = [SZFolder class];
  if ([type isEqualToString:@"FSFolder"])
    cls = [SZFileSystemFolder class];
  else if ([type isEqualToString:@"RootFolder"] || [type isEqualToString:@"FSDrives"])
    cls = [SZRootFolder class];
  return [[cls alloc] initWithRawFolder:folder archive:archive];
}

- (instancetype)initWithRawFolder:(IFolderFolder *)folder archive:(SZArchive *)archive
{
  self = [super init];
  if (!self)
    return nil;
  _folder = folder;
  _archive = archive;
  _folder.QueryInterface(IID_IFolderGetItemName, &_getItemName);
  _folder.QueryInterface(IID_IFolderWasChanged, &_wasChangedIface);
  _folder.QueryInterface(IID_IFolderSetFlatMode, &_setFlatMode);
  _folder.QueryInterface(IID_IFolderCompare, &_compare);
  _folder.QueryInterface(IID_IGetFolderArcProps, &_getArcProps);
  return self;
}

- (IFolderFolder *)rawFolder
{
  return _folder;
}

- (SZArchive *)archive
{
  return _archive;
}

#pragma mark - Opening by path

+ (SZFolder *)folderForPath:(NSString *)path
           passwordDelegate:(id<SZPasswordDelegate>)passwordDelegate
                      error:(NSError **)error
{
  NSString *p = path ?: @"";
  if ([p hasPrefix:@"~"])
    p = [p stringByExpandingTildeInPath];
  if (p.length == 0)
    return [SZRootFolder rootFolder];

  if (![p hasPrefix:@"/"])
  {
    // "Computer", "Volumes", "Home", "Documents" (any language) or "Volumes/<name>"
    SZFolder *root = [SZRootFolder rootFolder];
    NSArray<NSString *> *parts = [p componentsSeparatedByString:@"/"];
    NSError *e = nil;
    SZFolder *f = [root bindToFolderNamed:parts[0] error:&e];
    if (!f)
    {
      if (error)
        *error = e ?: [SZErrors errorWithCode:SZErrorCodeFileNotFound message:[NSString stringWithFormat:@"Folder not found: %@", path]];
      return nil;
    }
    NSString *rest = [[parts subarrayWithRange:NSMakeRange(1, parts.count - 1)] componentsJoinedByString:@"/"];
    if (rest.length == 0)
      return f;
    return [f bindToPath:rest passwordDelegate:passwordDelegate error:error];
  }

  NSFileManager *fm = [NSFileManager defaultManager];
  BOOL isDir = NO;
  if ([fm fileExistsAtPath:p isDirectory:&isDir] && isDir)
    return [SZFileSystemFolder folderWithPath:p error:error];

  // Walk down until a component is a file (archive) or missing.
  NSArray<NSString *> *comps = [p pathComponents];   // "/" first
  NSString *prefix = @"/";
  NSUInteger i = 1;
  for (; i < comps.count; i++)
  {
    NSString *next = [prefix stringByAppendingPathComponent:comps[i]];
    if (![fm fileExistsAtPath:next isDirectory:&isDir])
    {
      if (error)
        *error = [SZErrors errorWithCode:SZErrorCodeFileNotFound message:[NSString stringWithFormat:@"Path not found: %@", next]];
      return nil;
    }
    prefix = next;
    if (!isDir)
      break;
  }
  // prefix is a file: open it as an archive, continue inside
  SZArchive *archive = [SZArchiveOpener openArchiveAtPath:prefix formatHint:nil passwordDelegate:passwordDelegate error:error];
  if (!archive)
    return nil;
  SZFolder *folder = [archive rootFolder:error];
  if (!folder)
    return nil;
  if (i + 1 >= comps.count)
    return folder;
  NSString *rest = [[comps subarrayWithRange:NSMakeRange(i + 1, comps.count - i - 1)] componentsJoinedByString:@"/"];
  return [folder bindToPath:rest passwordDelegate:passwordDelegate error:error];
}

#pragma mark - Items

- (BOOL)loadItems:(NSError **)error
{
  IFolderFolder *f = _folder;
  NSString *msg = nil;
  const HRESULT hr = SZRunCatching(&msg, [&]() { return f->LoadItems(); });
  if (SZFail(hr, error, msg))
    return NO;
  UInt32 n = 0;
  if (SZFail(_folder->GetNumberOfItems(&n), error, nil))
    return NO;
  _itemCount = n;
  _properties = nil;
  return YES;
}

- (NSInteger)itemCount
{
  return _itemCount;
}

- (NSString *)nameOfItemAtIndex:(NSInteger)index
{
  if (_getItemName)
  {
    const wchar_t *name = NULL;
    unsigned len = 0;
    if (_getItemName->GetItemName((UInt32)index, &name, &len) == S_OK)
      return SZStringFromWChars(name, len);
  }
  id v = [self propertyOfItemAtIndex:index propID:SZPropIDName];
  return [v isKindOfClass:[NSString class]] ? v : @"";
}

- (NSString *)prefixOfItemAtIndex:(NSInteger)index
{
  if (_getItemName)
  {
    const wchar_t *name = NULL;
    unsigned len = 0;
    if (_getItemName->GetItemPrefix((UInt32)index, &name, &len) == S_OK)
      return SZStringFromWChars(name, len);
  }
  id v = [self propertyOfItemAtIndex:index propID:SZPropIDPrefix];
  return [v isKindOfClass:[NSString class]] ? v : @"";
}

- (uint64_t)sizeOfItemAtIndex:(NSInteger)index
{
  if (_getItemName)
    return _getItemName->GetItemSize((UInt32)index);
  id v = [self propertyOfItemAtIndex:index propID:SZPropIDSize];
  return [v isKindOfClass:[NSNumber class]] ? [v unsignedLongLongValue] : 0;
}

- (BOOL)isDirectoryAtIndex:(NSInteger)index
{
  NWindows::NCOM::CPropVariant prop;
  if (_folder->GetProperty((UInt32)index, kpidIsDir, &prop) != S_OK)
    return NO;
  return prop.vt == VT_BOOL && prop.boolVal != VARIANT_FALSE;
}

- (id)propertyOfItemAtIndex:(NSInteger)index propID:(SZPropID)propID
{
  NWindows::NCOM::CPropVariant prop;
  if (_folder->GetProperty((UInt32)index, (PROPID)propID, &prop) != S_OK)
    return nil;
  return SZObjectFromPropVariant(prop);
}

- (SZVarType)varTypeOfItemAtIndex:(NSInteger)index propID:(SZPropID)propID
{
  NWindows::NCOM::CPropVariant prop;
  if (_folder->GetProperty((UInt32)index, (PROPID)propID, &prop) != S_OK)
    return SZVarTypeEmpty;
  return (SZVarType)prop.vt;
}

- (NSString *)displayStringOfItemAtIndex:(NSInteger)index propID:(SZPropID)propID timestampLevel:(SZTimestampLevel)level
{
  NWindows::NCOM::CPropVariant prop;
  if (_folder->GetProperty((UInt32)index, (PROPID)propID, &prop) != S_OK)
    return @"";
  return SZDisplayStringFromPropVariant(prop, (PROPID)propID, (int)level);
}

- (NSArray<SZPropertyInfo *> *)properties
{
  if (!_properties)
  {
    UInt32 n = 0;
    if (_folder->GetNumberOfProperties(&n) != S_OK)
      return @[];
    IFolderFolder *f = _folder;
    _properties = SZReadPropertyInfos(n, ^HRESULT(UInt32 i, BSTR *name, PROPID *propID, VARTYPE *vt) {
      return f->GetPropertyInfo(i, name, propID, vt);
    });
  }
  return _properties;
}

#pragma mark - Folder properties

- (id)folderPropertyForID:(SZPropID)propID
{
  NWindows::NCOM::CPropVariant prop;
  if (_folder->GetFolderProperty((PROPID)propID, &prop) != S_OK)
    return nil;
  return SZObjectFromPropVariant(prop);
}

- (NSString *)folderType
{
  if (!_folderType)
  {
    id v = [self folderPropertyForID:SZPropIDType];
    _folderType = [v isKindOfClass:[NSString class]] ? v : @"";
  }
  return _folderType;
}

- (NSString *)path
{
  if (!_path)
  {
    id v = [self folderPropertyForID:SZPropIDPath];
    _path = [v isKindOfClass:[NSString class]] ? v : @"";
  }
  return _path;
}

- (NSString *)fullPath
{
  if (_archive)
  {
    NSString *inner = self.path;
    NSString *base = [_archive.path stringByAppendingString:@"/"];
    return inner.length ? [base stringByAppendingString:inner] : base;
  }
  return self.path;
}

- (BOOL)isArchive
{
  return _archive != nil || [self.folderType hasPrefix:@"7-Zip."];
}

- (BOOL)isFileSystem
{
  return [self.folderType isEqualToString:@"FSFolder"];
}

- (BOOL)isRootFolder
{
  return [self.folderType isEqualToString:@"RootFolder"];
}

- (BOOL)isReadOnly
{
  id v = [self folderPropertyForID:SZPropIDReadOnly];
  return [v isKindOfClass:[NSNumber class]] && [v boolValue];
}

- (SZArcProps *)arcProps
{
  if (!_getArcProps)
    return nil;
  CMyComPtr<IFolderArcProps> props;
  if (_getArcProps->GetFolderArcProps(&props) != S_OK || !props)
    return nil;
  return [[SZArcProps alloc] initWithRawProps:props];
}

#pragma mark - Navigation

- (SZFolder *)wrapBound:(IFolderFolder *)raw error:(NSError **)error
{
  SZFolder *sub = [SZFolder folderWithRawFolder:raw archive:_archive];
  if (![sub loadItems:error])
    return nil;
  return sub;
}

- (SZFolder *)bindToFolderAtIndex:(NSInteger)index error:(NSError **)error
{
  IFolderFolder *f = _folder;
  CMyComPtr<IFolderFolder> sub;
  NSString *msg = nil;
  const HRESULT hr = SZRunCatching(&msg, [&]() { return f->BindToFolder((UInt32)index, &sub); });
  if (hr == E_INVALIDARG || (hr == S_OK && !sub))
  {
    if (error)
      *error = [SZErrors errorWithCode:SZErrorCodeNotFolder
                              message:[NSString stringWithFormat:@"'%@' is not a folder", [self nameOfItemAtIndex:index]]];
    return nil;
  }
  if (SZFail(hr, error, msg))
    return nil;
  return [self wrapBound:sub error:error];
}

- (SZFolder *)bindToFolderNamed:(NSString *)name error:(NSError **)error
{
  IFolderFolder *f = _folder;
  CMyComPtr<IFolderFolder> sub;
  const UString uname = SZUStringFromNSString(name);
  NSString *msg = nil;
  const HRESULT hr = SZRunCatching(&msg, [&]() { return f->BindToFolder(uname.Ptr(), &sub); });
  if (hr == E_INVALIDARG || (hr == S_OK && !sub))
  {
    if (error)
      *error = [SZErrors errorWithCode:SZErrorCodeNotFolder message:[NSString stringWithFormat:@"Folder not found: %@", name]];
    return nil;
  }
  if (SZFail(hr, error, msg))
    return nil;
  return [self wrapBound:sub error:error];
}

- (NSInteger)indexOfItemNamed:(NSString *)name
{
  const NSInteger n = self.itemCount;
  for (NSInteger i = 0; i < n; i++)
    if ([[self nameOfItemAtIndex:i] isEqualToString:name])
      return i;
  for (NSInteger i = 0; i < n; i++)
    if ([[self nameOfItemAtIndex:i] caseInsensitiveCompare:name] == NSOrderedSame)
      return i;
  return NSNotFound;
}

- (SZFolder *)bindToPath:(NSString *)relativePath
        passwordDelegate:(id<SZPasswordDelegate>)passwordDelegate
                   error:(NSError **)error
{
  SZFolder *current = self;
  for (NSString *component in [relativePath componentsSeparatedByString:@"/"])
  {
    if (component.length == 0 || [component isEqualToString:@"."])
      continue;
    if ([component isEqualToString:@".."])
    {
      SZFolder *parent = [current bindToParentFolder:error];
      if (!parent)
        return nil;
      current = parent;
      continue;
    }
    NSError *bindError = nil;
    SZFolder *next = [current bindToFolderNamed:component error:&bindError];
    if (next)
    {
      current = next;
      continue;
    }
    const NSInteger index = [current indexOfItemNamed:component];
    if (index == NSNotFound || [current isDirectoryAtIndex:index])
    {
      if (error)
        *error = bindError ?: [SZErrors errorWithCode:SZErrorCodeFileNotFound message:[NSString stringWithFormat:@"Not found: %@", component]];
      return nil;
    }
    SZArchive *archive = [SZArchiveOpener openArchiveInFolder:current itemIndex:index formatHint:nil
                                             passwordDelegate:passwordDelegate error:error];
    if (!archive)
      return nil;
    SZFolder *root = [archive rootFolder:error];
    if (!root)
      return nil;
    current = root;
  }
  return current;
}

- (SZFolder *)bindToParentFolder:(NSError **)error
{
  IFolderFolder *f = _folder;
  CMyComPtr<IFolderFolder> parent;
  NSString *msg = nil;
  const HRESULT hr = SZRunCatching(&msg, [&]() { return f->BindToParentFolder(&parent); });
  if (SZFail(hr, error, msg))
    return nil;
  if (parent)
    return [self wrapBound:parent error:error];
  if (_archive)
  {
    SZFolder *outer = _archive.outerFolder;
    if (outer)
    {
      if (![outer loadItems:error])
        return nil;
      return outer;
    }
      // opened by path but the directory could not be listed: fall back to the root
    return [SZRootFolder rootFolder];
  }
  return [SZRootFolder rootFolder];   // "/", virtual folders and the root itself go up to the root
}

#pragma mark - Optional interfaces

- (BOOL)supportsFlatMode
{
  return _setFlatMode != NULL;
}

- (BOOL)flatMode
{
  return _flatMode;
}

- (void)setFlatMode:(BOOL)flatMode
{
  _flatMode = flatMode;
  if (_setFlatMode)
    _setFlatMode->SetFlatMode(BoolToInt(flatMode));
}

- (BOOL)supportsChangeNotification
{
  return _wasChangedIface != NULL;
}

- (BOOL)wasChanged
{
  if (!_wasChangedIface)
    return NO;
  Int32 changed = 0;
  if (_wasChangedIface->WasChanged(&changed) != S_OK)
    return NO;
  return changed != 0;
}

- (BOOL)supportsCompare
{
  return _compare != NULL;
}

- (NSInteger)compareItemAtIndex:(NSInteger)index1 withItemAtIndex:(NSInteger)index2 propID:(SZPropID)propID
{
  if (_compare)
    return _compare->CompareItems((UInt32)index1, (UInt32)index2, (PROPID)propID, 0);
  if (propID == SZPropIDName || propID == SZPropIDPath || propID == SZPropIDExtension)
    return [SZFolder compareFileName:[self nameOfItemAtIndex:index1] withFileName:[self nameOfItemAtIndex:index2]];
  id a = [self propertyOfItemAtIndex:index1 propID:propID];
  id b = [self propertyOfItemAtIndex:index2 propID:propID];
  if (!a && !b) return 0;
  if (!a) return -1;
  if (!b) return 1;
  if ([a isKindOfClass:[NSNumber class]] && [b isKindOfClass:[NSNumber class]])
    return [(NSNumber *)a compare:b];
  if ([a isKindOfClass:[NSDate class]] && [b isKindOfClass:[NSDate class]])
    return [(NSDate *)a compare:b];
  if ([a isKindOfClass:[NSString class]] && [b isKindOfClass:[NSString class]])
    return [SZFolder compareFileName:a withFileName:b];
  return 0;
}

+ (BOOL)timestampShowUTC
{
  return g_Timestamp_Show_UTC;
}

+ (void)setTimestampShowUTC:(BOOL)show
{
  g_Timestamp_Show_UTC = show;
}

+ (NSInteger)compareFileName:(NSString *)name1 withFileName:(NSString *)name2
{
  const UString a = SZUStringFromNSString(name1);
  const UString b = SZUStringFromNSString(name2);
  return CompareFileNames_ForFolderList(a.Ptr(), b.Ptr());
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<%@ %@ '%@' items=%lu>", NSStringFromClass([self class]), self.folderType, self.fullPath, (unsigned long)_itemCount];
}

@end
