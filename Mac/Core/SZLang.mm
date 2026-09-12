// SZLang.mm -- see SZLang.h. The parser is the engine's own CLang (CPP/Common/Lang.cpp), so
// the positional / consume-an-ID rules are exactly 7zFM's. This file also installs the
// MyLoadString hook used by the platform layer.

#import "SZLang.h"
#import "SZSettings.h"
#import "SZError.h"
#import "Internal/SZBridgeUtils.h"

#include <mutex>

@implementation SZLanguageInfo
- (instancetype)initWithCode:(NSString *)code path:(NSString *)path english:(NSString *)english native:(NSString *)native count:(NSInteger)count
{
  self = [super init];
  if (!self)
    return nil;
  _code = [code copy];
  _path = [path copy];
  _englishName = [english copy];
  _nativeName = [native copy];
  _stringCount = count;
  return self;
}
- (NSString *)description
{
  return [NSString stringWithFormat:@"<SZLanguageInfo %@ %@ / %@ (%lu)>", _code, _englishName, _nativeName, (unsigned long)_stringCount];
}
@end

static const wchar_t *SZLangHook(UInt32 langID);

@implementation SZLang
{
  CLang _english;
  CLang _current;
  std::mutex _mutex;
  NSString *_currentCode;
  NSArray<NSString *> *_comments;
  NSArray<SZLanguageInfo *> *_available;
}

+ (void)load
{
  g_SZ_LoadStringHook = SZLangHook;
}

+ (SZLang *)shared
{
  static SZLang *shared = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ shared = [[SZLang alloc] initPrivate]; });
  return shared;
}

- (instancetype)initPrivate
{
  self = [super init];
  if (!self)
    return nil;
  _currentCode = @"";
  _comments = @[];
  NSString *en = [[SZLang langDirectoryPath] stringByAppendingPathComponent:@"en.ttt"];
  if (![[NSFileManager defaultManager] fileExistsAtPath:en] || !_english.Open([en fileSystemRepresentation], "7-Zip"))
    NSLog(@"SevenZipKit: built-in English lang table not found at %@", en);
  return self;
}

+ (NSString *)langDirectoryPath
{
  NSBundle *bundle = [NSBundle bundleForClass:[SZLang class]];
  NSString *dir = [bundle pathForResource:@"Lang" ofType:nil];
  if (!dir)
    dir = [[bundle resourcePath] stringByAppendingPathComponent:@"Lang"];
  return dir;
}

- (const wchar_t *)wideStringForID:(uint32_t)langID
{
  std::lock_guard<std::mutex> lock(_mutex);
  const wchar_t *s = _current.IsEmpty() ? NULL : _current.Get(langID);
  if (!s)
    s = _english.Get(langID);
  return s;
}

- (NSString *)stringForID:(uint32_t)langID
{
  const wchar_t *s = [self wideStringForID:langID];
  return s ? SZStringFromWChars(s, (unsigned)wcslen(s)) : @"";
}

- (NSString *)stringForID:(uint32_t)langID fallback:(NSString *)fallback
{
  const wchar_t *s = [self wideStringForID:langID];
  return s ? SZStringFromWChars(s, (unsigned)wcslen(s)) : fallback;
}

- (NSString *)translatedStringForID:(uint32_t)langID
{
  std::lock_guard<std::mutex> lock(_mutex);
  if (_current.IsEmpty())
    return nil;
  const wchar_t *s = _current.Get(langID);
  return s ? SZStringFromWChars(s, (unsigned)wcslen(s)) : nil;
}

- (NSString *)englishStringForID:(uint32_t)langID
{
  std::lock_guard<std::mutex> lock(_mutex);
  const wchar_t *s = _english.Get(langID);
  return s ? SZStringFromWChars(s, (unsigned)wcslen(s)) : @"";
}

- (NSInteger)englishStringCount
{
  return _english._ids.Size();
}

- (NSString *)currentLanguageCode
{
  return _currentCode;
}

- (NSArray<NSString *> *)comments
{
  return _comments;
}

- (BOOL)loadLanguageFile:(NSString *)path error:(NSError **)error
{
  CLang lang;
  if (![[NSFileManager defaultManager] fileExistsAtPath:path])
  {
    if (error)
      *error = [SZErrors errorWithCode:SZErrorCodeFileNotFound message:[NSString stringWithFormat:@"Language file not found: %@", path]];
    return NO;
  }
  if (!lang.Open([path fileSystemRepresentation], "7-Zip"))
  {
    if (error)
      *error = [SZErrors errorWithCode:SZErrorCodeInvalidArgument message:[NSString stringWithFormat:@"Not a valid 7-Zip language file: %@", path]];
    return NO;
  }
  NSMutableArray *comments = [NSMutableArray array];
  FOR_VECTOR (i, lang.Comments)
    [comments addObject:SZStringFromUString(lang.Comments[i])];
  {
    std::lock_guard<std::mutex> lock(_mutex);
    _current.Clear();
    // CLang has no move/swap: re-open into the member (the file was just validated)
    _current.Open([path fileSystemRepresentation], "7-Zip");
    _comments = comments;
    _currentCode = [[path lastPathComponent] stringByDeletingPathExtension];
  }
  return YES;
}

- (void)unloadLanguage
{
  std::lock_guard<std::mutex> lock(_mutex);
  _current.Clear();
  _comments = @[];
  _currentCode = @"";
}

- (BOOL)loadLanguageWithCode:(NSString *)code error:(NSError **)error
{
  NSString *dir = [SZLang langDirectoryPath];
  if (code.length == 0)
  {
    // OpenDefaultLang (LangUtils.cpp:279-306): try the system language candidates
    for (NSString *candidate in [SZLang systemLanguageCandidates])
    {
      NSString *path = [dir stringByAppendingPathComponent:[candidate stringByAppendingPathExtension:@"txt"]];
      if ([[NSFileManager defaultManager] fileExistsAtPath:path] && [self loadLanguageFile:path error:NULL])
        return YES;
    }
    [self unloadLanguage];
    return YES;
  }
  if ([code isEqualToString:@"-"] || [code containsString:@"/"])
  {
    [self unloadLanguage];   // "-" = built-in English; a path separator is ignored (LangUtils.cpp:311-330)
    return YES;
  }
  NSString *file = [code containsString:@"."] ? code : [code stringByAppendingPathExtension:@"txt"];
  NSString *path = [dir stringByAppendingPathComponent:file];
  if ([self loadLanguageFile:path error:error])
    return YES;
  [self unloadLanguage];
  return NO;
}

- (NSArray<SZLanguageInfo *> *)availableLanguages
{
  if (_available)
    return _available;
  NSString *dir = [SZLang langDirectoryPath];
  NSArray<NSString *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL] ?: @[];
  NSMutableArray *result = [NSMutableArray array];
  for (NSString *file in [files sortedArrayUsingSelector:@selector(compare:)])
  {
    if (![[file pathExtension] isEqualToString:@"txt"])
      continue;
    NSString *path = [dir stringByAppendingPathComponent:file];
    CLang lang;
    if (!lang.Open([path fileSystemRepresentation], "7-Zip"))
      continue;
    const wchar_t *en = lang.Get(1);
    const wchar_t *native = lang.Get(2);
    [result addObject:[[SZLanguageInfo alloc] initWithCode:[file stringByDeletingPathExtension] path:path
                                                   english:en ? SZStringFromWChars(en, (unsigned)wcslen(en)) : @""
                                                    native:native ? SZStringFromWChars(native, (unsigned)wcslen(native)) : @""
                                                     count:lang._ids.Size()]];
  }
  _available = result;
  return result;
}

+ (NSArray<NSString *> *)systemLanguageCandidates
{
  // Lang_GetShortNames_for_DefaultLang (LangUtils.cpp:169-277) mapped to BCP-47 input.
  NSMutableArray *result = [NSMutableArray array];
  NSArray<NSString *> *preferred = [NSLocale preferredLanguages];
  NSString *first = preferred.count ? preferred[0] : @"en";
  NSDictionary *comps = [NSLocale componentsFromLocaleIdentifier:first];
  NSString *lang = [comps[NSLocaleLanguageCode] lowercaseString] ?: @"en";
  NSString *script = comps[NSLocaleScriptCode] ?: @"";
  NSString *region = [comps[NSLocaleCountryCode] lowercaseString] ?: @"";

  if ([lang isEqualToString:@"zh"])
  {
    if ([script isEqualToString:@"Hant"] || [region isEqualToString:@"tw"] || [region isEqualToString:@"hk"] || [region isEqualToString:@"mo"])
      [result addObject:@"zh-tw"];
    else
      [result addObject:@"zh-cn"];
  }
  else if ([lang isEqualToString:@"sr"])
    [result addObject:[script isEqualToString:@"Latn"] ? @"sr-spl" : @"sr-spc"];
  else if ([lang isEqualToString:@"uz"])
  {
    if ([script isEqualToString:@"Cyrl"])
      [result addObject:@"uz-cyrl"];
    [result addObject:@"uz"];
  }
  else if ([lang isEqualToString:@"pt"])
  {
    if ([region isEqualToString:@"br"])
      [result addObject:@"pt-br"];
    [result addObject:@"pt"];
  }
  else if ([lang isEqualToString:@"pa"])
    [result addObject:@"pa-in"];
  else if ([lang isEqualToString:@"ckb"])
    [result addObject:@"ku-ckb"];
  else if ([lang isEqualToString:@"no"] || [lang isEqualToString:@"nb"])
    [result addObject:@"nb"];
  else
  {
    if (region.length)
      [result addObject:[NSString stringWithFormat:@"%@-%@", lang, region]];
    [result addObject:lang];
  }
  return result;
}

@end

static const wchar_t *SZLangHook(UInt32 langID)
{
  return [[SZLang shared] wideStringForID:langID];
}
