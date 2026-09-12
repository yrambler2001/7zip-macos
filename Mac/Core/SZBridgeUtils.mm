// SZBridgeUtils.mm -- see Internal/SZBridgeUtils.h

#import "Internal/SZBridgeUtils.h"
#import "SZError.h"

#include <new>

NSString *SZStringFromWChars(const wchar_t *s, unsigned len)
{
  if (!s || len == 0)
    return @"";
  NSString *r = [[NSString alloc] initWithBytes:s length:(NSUInteger)len * sizeof(wchar_t)
                                       encoding:NSUTF32LittleEndianStringEncoding];
  return r ? r : @"";
}

NSString *SZStringFromUString(const UString &s)
{
  return SZStringFromWChars(s.Ptr(), s.Len());
}

UString SZUStringFromNSString(NSString *s)
{
  if (!s)
    return UString();
  const char *utf8 = [s UTF8String];
  return MultiByteToUnicodeString(utf8 ? utf8 : "", CP_UTF8);
}

NSString *SZStringFromFString(const FString &s)
{
  if (s.IsEmpty())
    return @"";
  NSString *r = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:s.Ptr() length:s.Len()];
  return r ? r : @"";
}

FString SZFStringFromNSString(NSString *s)
{
  if (!s || s.length == 0)
    return FString();
  return FString([s fileSystemRepresentation]);
}

NSDate *SZDateFromPropVariant(const PROPVARIANT &prop)
{
  if (prop.vt != VT_FILETIME)
    return nil;
  const FILETIME &ft = prop.filetime;
  if (ft.dwLowDateTime == 0 && ft.dwHighDateTime == 0)
    return nil;
  UInt32 quantums = 0;
  const Int64 sec = NWindows::NTime::FileTime_To_UnixTime64_and_Quantums(ft, quantums);
  double t = (double)sec + (double)quantums / 10000000.0;
  // sub-100ns part when the handler provided it (wReserved1 = 1ns precision level)
  if (prop.wReserved1 == k_PropVar_TimePrec_1ns && prop.wReserved2 < 100)
    t += (double)prop.wReserved2 / 1000000000.0;
  return [NSDate dateWithTimeIntervalSince1970:t];
}

id SZObjectFromPropVariant(const PROPVARIANT &prop)
{
  switch (prop.vt)
  {
    case VT_EMPTY: return nil;
    case VT_BSTR: return prop.bstrVal ? SZStringFromWChars(prop.bstrVal, SysStringLen(prop.bstrVal)) : @"";
    case VT_BOOL: return @(prop.boolVal != VARIANT_FALSE);
    case VT_UI1: return @((unsigned)prop.bVal);
    case VT_UI2: return @((unsigned)prop.uiVal);
    case VT_UI4: return @((unsigned)prop.ulVal);
    case VT_UI8: return @((unsigned long long)prop.uhVal.QuadPart);
    case VT_I2: return @((int)prop.iVal);
    case VT_I4: return @((int)prop.lVal);
    case VT_I8: return @((long long)prop.hVal.QuadPart);
    case VT_FILETIME: return SZDateFromPropVariant(prop);
    default: return nil;
  }
}

NSString *SZDisplayStringFromPropVariant(const PROPVARIANT &prop, PROPID propID, int timestampLevel)
{
  if (prop.vt == VT_EMPTY)
    return @"";
  if (prop.vt == VT_BSTR)
    return prop.bstrVal ? SZStringFromWChars(prop.bstrVal, SysStringLen(prop.bstrVal)) : @"";
  UString s;
  ConvertPropertyToString2(s, prop, propID, timestampLevel);
  return SZStringFromUString(s);
}

NSError *SZErrorFromHRESULT(HRESULT hr, NSString *engineMessage)
{
  if (hr == S_OK)
    return nil;
  return [SZErrors errorWithHRESULT:(uint32_t)hr message:engineMessage];
}

BOOL SZFail(HRESULT hr, NSError **error, NSString *engineMessage)
{
  if (hr == S_OK)
    return NO;
  if (error)
    *error = SZErrorFromHRESULT(hr, engineMessage);
  return YES;
}

HRESULT SZHandleCurrentException(NSString **message)
{
  if (message)
    *message = nil;
  try
  {
    throw;
  }
  catch (const CSystemException &e)
  {
    return e.ErrorCode;
  }
  catch (const UString &s)
  {
    if (message) *message = SZStringFromUString(s);
    return E_FAIL;
  }
  catch (const AString &s)
  {
    if (message) *message = [NSString stringWithUTF8String:s.Ptr()] ?: @"";
    return E_FAIL;
  }
  catch (const wchar_t *s)
  {
    if (message) *message = SZStringFromUString(UString(s));
    return E_FAIL;
  }
  catch (const char *s)
  {
    if (message) *message = [NSString stringWithUTF8String:s] ?: @"";
    return E_FAIL;
  }
  catch (int n)
  {
    if (message) *message = [NSString stringWithFormat:@"Internal Error #%d", n];
    return E_FAIL;
  }
  catch (const std::bad_alloc &)
  {
    return E_OUTOFMEMORY;
  }
  catch (...)
  {
    if (message) *message = @"Unknown error";
    return E_FAIL;
  }
}
