// SZArchiveOpener.mm -- see SZArchiveOpener.h. Mirrors the smoke test in
// 02-engine-api.md Appendix A: CAgent::Open with an IArchiveOpenCallback that also
// implements ICryptoGetTextPassword, then BindToRootFolder.

#import "SZArchiveOpener.h"
#import "SZFileSystemFolder.h"
#import "SZCodecs.h"
#import "SZError.h"
#import "SZSettings.h"          // SZSettings.temporaryDirectory (SZ_STATE_DIR)
#import "Internal/SZBridgeUtils.h"
#import "Internal/SZFolder+Internal.h"

// ---------------------------------------------------------------------------
// The open callback handed to CAgent::Open is the engine's own COpenCallbackImp, exactly as 7zFM
// builds it (FileFolderPluginOpen.cpp:317-330, 02-engine-api.md 2.5.1). It implements
// IArchiveOpenVolumeCallback, which is what the Split / RAR / zip handlers query to find the
// `.002`, `.003`, `.r00`, `.z01` ... siblings of a multi-volume set
// (COpenCallbackImp::GetStream, ArchiveOpenCallback.cpp:284-367) — so opening the first volume
// lists the whole archive. Without it the Split handler sees one truncated volume and CAgent::Open
// answers S_FALSE, i.e. SZErrorCodeNotArchive.
//
// COpenCallbackImp is `final` and does the volume bookkeeping itself; the app-side half it
// delegates to is the non-COM IOpenCallbackUI below, which answers the password. Upstream keeps
// that as a *raw* pointer (`Callback`) and uses it only during the open stage, so SZArchive owns
// the object and clears the pointer before releasing it.
class CSZOpenCallbackUI Z7_final: public IOpenCallbackUI
{
public:
  id<SZPasswordDelegate> Delegate;
  NSString *Path;
  UString Password;
  bool PasswordIsDefined;
  bool PasswordWasAsked;
  bool Cancelled;

  CSZOpenCallbackUI(): Delegate(nil), Path(nil), PasswordIsDefined(false),
      PasswordWasAsked(false), Cancelled(false) {}

  Z7_IFACE_IMP(IOpenCallbackUI)
};

HRESULT CSZOpenCallbackUI::Open_CheckBreak() { return S_OK; }

HRESULT CSZOpenCallbackUI::Open_SetTotal(const UInt64 * /* files */, const UInt64 * /* bytes */)
{
  return S_OK;
}

HRESULT CSZOpenCallbackUI::Open_SetCompleted(const UInt64 * /* files */, const UInt64 * /* bytes */)
{
  return S_OK;
}

HRESULT CSZOpenCallbackUI::Open_Finished() { return S_OK; }

HRESULT CSZOpenCallbackUI::Open_CryptoGetTextPassword(BSTR *password)
{
  *password = NULL;
  PasswordWasAsked = true;
  if (!PasswordIsDefined)
  {
    if (!Delegate)
      return E_ABORT;
    NSString *p = [Delegate passwordForArchiveAtPath:Path];
    if (!p)
    {
      Cancelled = true;
      return E_ABORT;
    }
    Password = SZUStringFromNSString(p);
    PasswordIsDefined = true;
  }
  return StringToBstr(Password, password);
}

// ---------------------------------------------------------------------------
// Minimal IFolderArchiveExtractCallback for extracting one nested archive to a temp
// folder: overwrite silently, remember the first failure, answer passwords via the delegate.
class CExtractToTempCallback Z7_final:
  public IFolderArchiveExtractCallback,
  public ICryptoGetTextPassword,
  public CMyUnknownImp
{
  Z7_COM_UNKNOWN_IMP_2(IFolderArchiveExtractCallback, ICryptoGetTextPassword)
  Z7_IFACE_COM7_IMP(IProgress)
  Z7_IFACE_COM7_IMP(IFolderArchiveExtractCallback)
  Z7_IFACE_COM7_IMP(ICryptoGetTextPassword)
public:
  id<SZPasswordDelegate> Delegate;
  NSString *Path;
  UString Password;
  bool PasswordIsDefined;
  bool PasswordWasAsked;
  bool Cancelled;
  Int32 FirstBadOpRes;
  NSString *ErrorMessage;

  CExtractToTempCallback(): Delegate(nil), Path(nil), PasswordIsDefined(false), PasswordWasAsked(false),
      Cancelled(false), FirstBadOpRes(NArchive::NExtract::NOperationResult::kOK), ErrorMessage(nil) {}
};

Z7_COM7F_IMF(CExtractToTempCallback::SetTotal(UInt64 /* total */)) { return S_OK; }
Z7_COM7F_IMF(CExtractToTempCallback::SetCompleted(const UInt64 * /* completeValue */)) { return S_OK; }

Z7_COM7F_IMF(CExtractToTempCallback::AskOverwrite(
    const wchar_t * /* existName */, const FILETIME * /* existTime */, const UInt64 * /* existSize */,
    const wchar_t * /* newName */, const FILETIME * /* newTime */, const UInt64 * /* newSize */,
    Int32 *answer))
{
  *answer = NOverwriteAnswer::kYesToAll;
  return S_OK;
}

Z7_COM7F_IMF(CExtractToTempCallback::PrepareOperation(const wchar_t * /* name */, Int32 /* isFolder */, Int32 /* askExtractMode */, const UInt64 * /* position */))
{
  return S_OK;
}

Z7_COM7F_IMF(CExtractToTempCallback::MessageError(const wchar_t *message))
{
  if (!ErrorMessage)
    ErrorMessage = SZStringFromUString(UString(message));
  return S_OK;
}

Z7_COM7F_IMF(CExtractToTempCallback::SetOperationResult(Int32 opRes, Int32 encrypted))
{
  if (opRes != NArchive::NExtract::NOperationResult::kOK && FirstBadOpRes == NArchive::NExtract::NOperationResult::kOK)
  {
    FirstBadOpRes = opRes;
    if (!ErrorMessage)
    {
      UString s;
      SetExtractErrorMessage(opRes, encrypted, Path ? SZUStringFromNSString(Path).Ptr() : L"", s);
      ErrorMessage = SZStringFromUString(s);
    }
  }
  return S_OK;
}

Z7_COM7F_IMF(CExtractToTempCallback::CryptoGetTextPassword(BSTR *password))
{
  *password = NULL;
  PasswordWasAsked = true;
  if (!PasswordIsDefined)
  {
    if (!Delegate)
      return E_ABORT;
    NSString *p = [Delegate passwordForArchiveAtPath:Path];
    if (!p)
    {
      Cancelled = true;
      return E_ABORT;
    }
    Password = SZUStringFromNSString(p);
    PasswordIsDefined = true;
  }
  return StringToBstr(Password, password);
}

// ---------------------------------------------------------------------------
/// The open-callback pair is private to this file, so it is declared here rather than in the
/// shared Internal/SZFolder+Internal.h (which the other bridge files include).
@interface SZArchive ()
- (void)adoptOpenCallbackImp:(COpenCallbackImp *)spec ui:(CSZOpenCallbackUI *)ui;
@end

@implementation SZArchive
{
  CMyComPtr<IInFolderArchive> _agent;
  CAgent *_agentSpec;
  CMyComPtr<IArchiveOpenCallback> _openCallback;
  /// The same object as _openCallback; kept typed so `Callback` can be cleared before the
  /// IOpenCallbackUI it points at is destroyed (the pointer is not reference counted).
  COpenCallbackImp *_openCallbackSpec;
  /// Owned by this archive: the app-side half of the open callback. For a multi-volume set
  /// COpenCallbackImp outlives the open stage, so this must outlive it too.
  CSZOpenCallbackUI *_openCallbackUI;
  CMyComPtr<IInStream> _inStream;
  BOOL _closed;
}

- (instancetype)initWithAgent:(IInFolderArchive *)agent
                    agentSpec:(CAgent *)agentSpec
                 openCallback:(IArchiveOpenCallback *)openCallback
                     inStream:(IInStream *)inStream
                         path:(NSString *)path
                         type:(NSString *)type
                  outerFolder:(SZFolder *)outerFolder
               outerItemIndex:(NSInteger)outerItemIndex
                tempDirectory:(NSString *)tempDirectory
{
  self = [super init];
  if (!self)
    return nil;
  _agent = agent;
  _agentSpec = agentSpec;
  _openCallback = openCallback;
  _inStream = inStream;
  _path = [path copy];
  _type = [type copy];
  _outerFolder = outerFolder;
  _outerItemIndex = outerItemIndex;
  _tempDirectory = [tempDirectory copy];
  return self;
}

- (void)adoptOpenCallbackImp:(COpenCallbackImp *)spec ui:(CSZOpenCallbackUI *)ui
{
  _openCallbackSpec = spec;
  _openCallbackUI = ui;
}

- (void)removeTempDirectory
{
  if (_tempDirectory)
  {
    [[NSFileManager defaultManager] removeItemAtPath:_tempDirectory error:NULL];
    _tempDirectory = nil;
  }
}

- (void)dealloc
{
  if (_agent && !_closed)
    _agent->Close();                    // releases the volume streams that hold _openCallback
  [self releaseOpenCallbackUI];
  [self removeTempDirectory];
}

/// The IOpenCallbackUI is reachable from COpenCallbackImp through a raw pointer, so the pointer
/// goes first. Called only when the archive is gone for good, never from -close, because
/// -reopen still needs the password answer.
- (void)releaseOpenCallbackUI
{
  if (_openCallbackSpec)
    _openCallbackSpec->Callback = NULL;
  delete _openCallbackUI;
  _openCallbackUI = NULL;
}

- (NSString *)errorMessage
{
  const UString s = _agentSpec->GetErrorMessage();
  return s.IsEmpty() ? nil : SZStringFromUString(s);
}

- (BOOL)isReadOnly
{
  return _agentSpec->IsThere_ReadOnlyArc() || _agentSpec->Is_Attrib_ReadOnly();
}

- (SZArcProps *)arcProps
{
  CMyComPtr<IFolderArcProps> props;
  _agent.QueryInterface(IID_IFolderArcProps, &props);
  if (!props)
    return nil;
  return [[SZArcProps alloc] initWithRawProps:props];
}

- (SZFolder *)rootFolder:(NSError **)error
{
  IInFolderArchive *agent = _agent;
  CMyComPtr<IFolderFolder> raw;
  NSString *msg = nil;
  const HRESULT hr = SZRunCatching(&msg, [&]() { return agent->BindToRootFolder(&raw); });
  if (SZFail(hr, error, msg))
    return nil;
  if (!raw)
  {
    if (error)
      *error = [SZErrors errorWithCode:SZErrorCodeUnknown message:@"BindToRootFolder returned no folder"];
    return nil;
  }
  SZFolder *folder = [SZFolder folderWithRawFolder:raw archive:self];
  if (![folder loadItems:error])
    return nil;
  return folder;
}

- (BOOL)reopen:(NSError **)error
{
  IInFolderArchive *agent = _agent;
  IArchiveOpenCallback *cb = _openCallback;
  NSString *msg = nil;
  const HRESULT hr = SZRunCatching(&msg, [&]() { return agent->ReOpen(cb); });
  if (hr != S_OK && msg == nil)
    msg = self.errorMessage;
  return !SZFail(hr, error, msg);
}

- (void)close
{
  if (_agent && !_closed)
  {
    _agent->Close();
    _closed = YES;
  }
  [self removeTempDirectory];
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<SZArchive %@ type=%@>", _path, _type];
}

@end

// ---------------------------------------------------------------------------
@implementation SZArchiveOpener

/// Extracts one item of an archive folder into a fresh "7zO" temp directory (kNoPaths, so the
/// file lands directly in it). Returns the file path; tempDirectory receives the directory.
+ (NSString *)extractItem:(NSInteger)index
                       of:(SZFolder *)folder
                    named:(NSString *)name
         passwordDelegate:(id<SZPasswordDelegate>)passwordDelegate
            tempDirectory:(NSString **)tempDirectory
                    error:(NSError **)error
{
  CMyComPtr<IArchiveFolder> archiveFolder;
  folder.rawFolder->QueryInterface(IID_IArchiveFolder, (void **)&archiveFolder);
  if (!archiveFolder)
  {
    if (error)
      *error = [SZErrors errorWithCode:SZErrorCodeUnsupported message:@"The folder cannot extract items"];
    return nil;
  }
  NSString *base = [SZSettings.temporaryDirectory stringByAppendingPathComponent:@"7zO-XXXXXX"];
  char *templ = strdup(base.fileSystemRepresentation);
  const char *made = mkdtemp(templ);
  if (!made)
  {
    free(templ);
    if (error)
      *error = [SZErrors errorWithHRESULT:(uint32_t)HRESULT_FROM_WIN32((DWORD)errno) message:@"Cannot create a temp folder"];
    return nil;
  }
  NSString *tempDir = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:made length:strlen(made)];
  free(templ);

  CExtractToTempCallback *cbSpec = new CExtractToTempCallback;
  CMyComPtr<IFolderArchiveExtractCallback> callback = cbSpec;
  cbSpec->Delegate = passwordDelegate;
  cbSpec->Path = [folder.fullPath stringByAppendingString:name];

  const UString uTemp = MultiByteToUnicodeString(SZFStringFromNSString(tempDir), CP_UTF8);
  const UInt32 idx = (UInt32)index;
  IArchiveFolder *af = archiveFolder;
  IFolderArchiveExtractCallback *cb = callback;
  NSString *msg = nil;
  const HRESULT hr = SZRunCatching(&msg, [&]() {
    return af->Extract(&idx, 1, BoolToInt(false), 0, NExtract::NPathMode::kNoPaths,
        NExtract::NOverwriteMode::kOverwrite, uTemp.Ptr(), BoolToInt(false), cb);
  });
  NSString *file = [tempDir stringByAppendingPathComponent:name];
  const BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:file];
  if (hr != S_OK || cbSpec->FirstBadOpRes != NArchive::NExtract::NOperationResult::kOK || !exists)
  {
    [[NSFileManager defaultManager] removeItemAtPath:tempDir error:NULL];
    if (error)
    {
      NSString *m = cbSpec->ErrorMessage ?: msg;
      if (cbSpec->PasswordWasAsked && !passwordDelegate)
        *error = [SZErrors errorWithCode:SZErrorCodePasswordRequired message:[NSString stringWithFormat:@"A password is required to extract %@", name]];
      else if (cbSpec->Cancelled || hr == E_ABORT)
        *error = [SZErrors errorWithCode:SZErrorCodeCancelled message:@"Cancelled"];
      else if (cbSpec->FirstBadOpRes == NArchive::NExtract::NOperationResult::kWrongPassword)
        *error = [SZErrors errorWithCode:SZErrorCodeWrongPassword message:m ?: @"Wrong password"];
      else if (hr != S_OK)
        *error = [SZErrors errorWithHRESULT:(uint32_t)hr message:m];
      else
        *error = [SZErrors errorWithCode:SZErrorCodeEngine message:m ?: [NSString stringWithFormat:@"Cannot extract %@", name]];
    }
    return nil;
  }
  *tempDirectory = tempDir;
  return file;
}

+ (SZArchive *)openWithStream:(IInStream *)inStream
                     openPath:(NSString *)openPath
                  displayPath:(NSString *)displayPath
                   formatHint:(NSString *)formatHint
             passwordDelegate:(id<SZPasswordDelegate>)passwordDelegate
                  outerFolder:(SZFolder *)outerFolder
               outerItemIndex:(NSInteger)outerItemIndex
                tempDirectory:(NSString *)tempDirectory
                        error:(NSError **)error
{
  if (![SZCodecs loadCodecs:error])
    return nil;

  CAgent *agentSpec = new CAgent;
  CMyComPtr<IInFolderArchive> agent = agentSpec;

  // FileFolderPluginOpen.cpp:317-330: a COpenCallbackImp whose Callback is the app-side
  // IOpenCallbackUI, then Init2(dirPrefix, fileName) for a real file (this is what gives
  // multi-volume support: _folderPrefix is where GetStream looks for the sibling volumes) or
  // SetSubArchiveName for an archive opened from a stream inside another archive.
  CSZOpenCallbackUI *uiSpec = new CSZOpenCallbackUI;
  uiSpec->Delegate = passwordDelegate;
  uiSpec->Path = displayPath;
  COpenCallbackImp *cbSpec = new COpenCallbackImp;
  CMyComPtr<IArchiveOpenCallback> callback = cbSpec;
  cbSpec->Callback = uiSpec;

  // For a file open the engine needs the file-system spelling of the path (UTF-8 bytes as
  // the kernel has them); for a stream open the path only feeds extension detection.
  const UString uPath = inStream
      ? SZUStringFromNSString(openPath)
      : MultiByteToUnicodeString(SZFStringFromNSString(openPath), CP_UTF8);
  const UString uHint = SZUStringFromNSString(formatHint ?: @"");   // must not be NULL (Appendix A)

  if (inStream)
  {
    cbSpec->SetSubArchiveName(SZUStringFromNSString([openPath lastPathComponent]).Ptr());
  }
  else
  {
    FString dirPrefix, fileName;
    if (NWindows::NFile::NDir::GetFullPathAndSplit(us2fs(uPath), dirPrefix, fileName))
    {
      NWindows::NFile::NName::NormalizeDirPathPrefix(dirPrefix);
      const HRESULT initRes = cbSpec->Init2(dirPrefix, fileName);
      if (initRes != S_OK)
      {
        cbSpec->Callback = NULL;
        delete uiSpec;
        if (error)
          *error = [SZErrors errorWithHRESULT:(uint32_t)initRes
                                      message:[NSString stringWithFormat:@"Cannot stat %@", displayPath]];
        return nil;
      }
    }
  }

  CMyComBSTR type;
  NSString *msg = nil;
  IInFolderArchive *agentPtr = agent;
  IArchiveOpenCallback *cbPtr = callback;
  const HRESULT hr = SZRunCatching(&msg, [&]() {
    return agentPtr->Open(inStream, uPath.Ptr(), uHint.Ptr(), &type, cbPtr);
  });

  if (hr != S_OK)
  {
    NSString *engineMsg = msg;
    const UString em = agentSpec->GetErrorMessage();
    if (!em.IsEmpty())
      engineMsg = SZStringFromUString(em);
    const bool passwordWasAsked = uiSpec->PasswordWasAsked;
    const bool cancelled = uiSpec->Cancelled;
    cbSpec->Callback = NULL;
    delete uiSpec;
    if (error)
    {
      if (passwordWasAsked && !passwordDelegate)
        *error = [SZErrors errorWithCode:SZErrorCodePasswordRequired
                                message:[NSString stringWithFormat:@"A password is required to open %@", displayPath]];
      else if (cancelled)
        *error = [SZErrors errorWithCode:SZErrorCodeCancelled message:@"Cancelled"];
      else if (hr == S_FALSE)
        *error = [SZErrors errorWithCode:SZErrorCodeNotArchive
                                message:engineMsg.length ? engineMsg : [NSString stringWithFormat:@"Cannot open %@ as archive", displayPath]];
      else
        *error = [SZErrors errorWithHRESULT:(uint32_t)hr message:engineMsg];
    }
    return nil;
  }

  NSString *typeString = @"";
  if ((LPCOLESTR)type)
    typeString = SZStringFromWChars((LPCOLESTR)type, SysStringLen((BSTR)(LPCOLESTR)type));
  SZArchive *archive = [[SZArchive alloc] initWithAgent:agent agentSpec:agentSpec openCallback:callback
                                              inStream:inStream path:displayPath type:typeString
                                           outerFolder:outerFolder outerItemIndex:outerItemIndex
                                         tempDirectory:tempDirectory];
  // The open callback survives the open stage for a multi-volume set, and it holds a raw pointer
  // to the IOpenCallbackUI, so the archive takes ownership of both.
  [archive adoptOpenCallbackImp:cbSpec ui:uiSpec];
  return archive;
}

+ (SZArchive *)openArchiveAtPath:(NSString *)path
                      formatHint:(NSString *)formatHint
                passwordDelegate:(id<SZPasswordDelegate>)passwordDelegate
                           error:(NSError **)error
{
  NSString *p = [[path stringByExpandingTildeInPath] stringByStandardizingPath];
  BOOL isDir = NO;
  if (![[NSFileManager defaultManager] fileExistsAtPath:p isDirectory:&isDir])
  {
    if (error)
      *error = [SZErrors errorWithCode:SZErrorCodeFileNotFound message:[NSString stringWithFormat:@"File not found: %@", path]];
    return nil;
  }
  if (isDir)
  {
    if (error)
      *error = [SZErrors errorWithCode:SZErrorCodeNotArchive message:[NSString stringWithFormat:@"%@ is a directory", path]];
    return nil;
  }
  // The containing directory becomes the archive's "outside" for Up-navigation.
  SZFolder *outer = [SZFileSystemFolder folderWithPath:[p stringByDeletingLastPathComponent] error:NULL];
  NSInteger outerIndex = NSNotFound;
  if (outer)
  {
    NSString *name = [p lastPathComponent];
    for (NSInteger i = 0; i < outer.itemCount; i++)
      if ([[outer nameOfItemAtIndex:i] isEqualToString:name]) { outerIndex = i; break; }
  }
  return [self openWithStream:NULL openPath:p displayPath:p formatHint:formatHint passwordDelegate:passwordDelegate
                  outerFolder:outer outerItemIndex:outerIndex tempDirectory:nil error:error];
}

+ (SZArchive *)openArchiveInFolder:(SZFolder *)folder
                         itemIndex:(NSInteger)index
                        formatHint:(NSString *)formatHint
                  passwordDelegate:(id<SZPasswordDelegate>)passwordDelegate
                             error:(NSError **)error
{
  if (index >= folder.itemCount)
  {
    if (error)
      *error = [SZErrors errorWithCode:SZErrorCodeInvalidArgument message:@"Item index out of range"];
    return nil;
  }
  if (!folder.isArchive)
  {
    // file system (or a virtual folder that maps to paths): open the file itself
    NSString *path = [folder isKindOfClass:[SZFileSystemFolder class]]
        ? [(SZFileSystemFolder *)folder fullPathOfItemAtIndex:index]
        : [folder.fullPath stringByAppendingString:[folder nameOfItemAtIndex:index]];
    return [self openWithStream:NULL openPath:path displayPath:path formatHint:formatHint passwordDelegate:passwordDelegate
                    outerFolder:folder outerItemIndex:index tempDirectory:nil error:error];
  }

  // Inside an archive: use the item's stream (PanelItemOpen.cpp:1526-1541).
  CMyComPtr<IInArchiveGetStream> getStream;
  IFolderFolder *raw = folder.rawFolder;
  raw->QueryInterface(IID_IInArchiveGetStream, (void **)&getStream);
  CMyComPtr<IInStream> inStream;
  if (getStream)
  {
    CMyComPtr<ISequentialInStream> seq;
    NSString *msg = nil;
    IInArchiveGetStream *gs = getStream;
    SZRunCatching(&msg, [&]() { return gs->GetStream((UInt32)index, &seq); });
    if (seq)
      seq.QueryInterface(IID_IInStream, &inStream);
  }
  NSString *name = [folder nameOfItemAtIndex:index];
  NSString *virtualPath = [folder.fullPath stringByAppendingString:name];
  if (inStream)
    return [self openWithStream:inStream openPath:virtualPath displayPath:virtualPath formatHint:formatHint
               passwordDelegate:passwordDelegate outerFolder:folder outerItemIndex:index tempDirectory:nil error:error];

  // No seekable stream: extract the item to a temp folder and open the copy (7zFM does the
  // same through CPanel::OpenItemAsArchive with a 7zO temp dir).
  NSString *tempDir = nil;
  NSString *tempFile = [self extractItem:index of:folder named:name passwordDelegate:passwordDelegate tempDirectory:&tempDir error:error];
  if (!tempFile)
    return nil;
  SZArchive *archive = [self openWithStream:NULL openPath:tempFile displayPath:virtualPath formatHint:formatHint
                           passwordDelegate:passwordDelegate outerFolder:folder outerItemIndex:index tempDirectory:tempDir error:error];
  if (!archive)
    [[NSFileManager defaultManager] removeItemAtPath:tempDir error:NULL];
  return archive;
}

@end
