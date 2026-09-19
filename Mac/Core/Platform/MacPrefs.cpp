// MacPrefs.cpp -- see MacPrefs.h

#include "../../../CPP/Common/Common.h"

#include <CoreFoundation/CoreFoundation.h>

#include "../../../CPP/Common/StringConvert.h"

#include "../../../CPP/Windows/Synchronization.h"

#include "MacPrefs.h"

#include <stdlib.h>

namespace NMacPrefs {

const char * const kAppID = "com.yrambler2001.7zip";
const char * const kSuiteEnvVar = "SEVENZIP_DEFAULTS_SUITE";

static NWindows::NSynchronization::CCriticalSection g_AppIDCS;

AString ApplicationID()
{
  const char *env = getenv(kSuiteEnvVar);
  if (env && *env)
    return AString(env);
  return AString(kAppID);
}

// The CFString of the current domain. The environment variable is re-read on every call so a
// test can switch domains with setenv(); the string is rebuilt only when the value changed.
static CFStringRef AppID()
{
  NWindows::NSynchronization::CCriticalSectionLock lock(g_AppIDCS);
  static CFStringRef s_id = NULL;
  static AString s_name;
  const AString want = ApplicationID();
  if (!s_id || !s_name.IsEqualTo(want.Ptr()))
  {
    if (s_id)
      CFRelease(s_id);
    s_id = CFStringCreateWithCString(kCFAllocatorDefault, want.Ptr(), kCFStringEncodingUTF8);
    s_name = want;
  }
  return s_id;
}

static CFStringRef MakeKey(const char *key)
{
  return CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingUTF8);
}

static CFStringRef MakeString(const UString &s)
{
  const AString utf8 = UnicodeStringToMultiByte(s, CP_UTF8);
  return CFStringCreateWithCString(kCFAllocatorDefault, utf8.Ptr(), kCFStringEncodingUTF8);
}

static bool CFStringToUString(CFStringRef cf, UString &dest)
{
  dest.Empty();
  if (!cf)
    return false;
  const CFIndex len = CFStringGetLength(cf);
  const CFIndex maxBytes = CFStringGetMaximumSizeForEncoding(len, kCFStringEncodingUTF8) + 1;
  AString buf;
  char *p = buf.GetBuf((unsigned)maxBytes);
  const Boolean ok = CFStringGetCString(cf, p, maxBytes, kCFStringEncodingUTF8);
  buf.ReleaseBuf_CalcLen((unsigned)maxBytes);
  if (!ok)
    return false;
  dest = MultiByteToUnicodeString(buf, CP_UTF8);
  return true;
}

static CFPropertyListRef CopyValue(const char *key)
{
  CFStringRef k = MakeKey(key);
  CFPropertyListRef v = CFPreferencesCopyAppValue(k, AppID());
  CFRelease(k);
  return v;
}

static void SetValue(const char *key, CFPropertyListRef value)
{
  CFStringRef k = MakeKey(key);
  CFPreferencesSetAppValue(k, value, AppID());
  CFRelease(k);
}

bool GetUInt32(const char *key, UInt32 &value)
{
  CFPropertyListRef v = CopyValue(key);
  if (!v)
    return false;
  bool ok = false;
  if (CFGetTypeID(v) == CFNumberGetTypeID())
  {
    long long ll = 0;
    if (CFNumberGetValue((CFNumberRef)v, kCFNumberLongLongType, &ll))
    {
      value = (UInt32)ll;
      ok = true;
    }
  }
  else if (CFGetTypeID(v) == CFBooleanGetTypeID())
  {
    value = CFBooleanGetValue((CFBooleanRef)v) ? 1 : 0;
    ok = true;
  }
  CFRelease(v);
  return ok;
}

bool GetBool(const char *key, bool &value)
{
  CFPropertyListRef v = CopyValue(key);
  if (!v)
    return false;
  bool ok = false;
  if (CFGetTypeID(v) == CFBooleanGetTypeID())
  {
    value = CFBooleanGetValue((CFBooleanRef)v) != 0;
    ok = true;
  }
  else if (CFGetTypeID(v) == CFNumberGetTypeID())
  {
    long long ll = 0;
    if (CFNumberGetValue((CFNumberRef)v, kCFNumberLongLongType, &ll))
    {
      value = ll != 0;
      ok = true;
    }
  }
  CFRelease(v);
  return ok;
}

bool GetString(const char *key, UString &value)
{
  CFPropertyListRef v = CopyValue(key);
  if (!v)
    return false;
  bool ok = false;
  if (CFGetTypeID(v) == CFStringGetTypeID())
    ok = CFStringToUString((CFStringRef)v, value);
  CFRelease(v);
  return ok;
}

bool GetStrings(const char *key, UStringVector &values)
{
  values.Clear();
  CFPropertyListRef v = CopyValue(key);
  if (!v)
    return false;
  bool ok = false;
  if (CFGetTypeID(v) == CFArrayGetTypeID())
  {
    ok = true;
    const CFIndex n = CFArrayGetCount((CFArrayRef)v);
    for (CFIndex i = 0; i < n; i++)
    {
      CFTypeRef item = CFArrayGetValueAtIndex((CFArrayRef)v, i);
      UString s;
      if (item && CFGetTypeID(item) == CFStringGetTypeID() && CFStringToUString((CFStringRef)item, s))
        values.Add(s);
    }
  }
  CFRelease(v);
  return ok;
}

void SetUInt32(const char *key, UInt32 value)
{
  const long long ll = value;
  CFNumberRef n = CFNumberCreate(kCFAllocatorDefault, kCFNumberLongLongType, &ll);
  SetValue(key, n);
  CFRelease(n);
}

void SetBool(const char *key, bool value)
{
  SetValue(key, value ? kCFBooleanTrue : kCFBooleanFalse);
}

void SetString(const char *key, const UString &value)
{
  CFStringRef s = MakeString(value);
  SetValue(key, s);
  CFRelease(s);
}

void SetStrings(const char *key, const UStringVector &values)
{
  CFMutableArrayRef arr = CFArrayCreateMutable(kCFAllocatorDefault, (CFIndex)values.Size(), &kCFTypeArrayCallBacks);
  FOR_VECTOR (i, values)
  {
    CFStringRef s = MakeString(values[i]);
    CFArrayAppendValue(arr, s);
    CFRelease(s);
  }
  SetValue(key, arr);
  CFRelease(arr);
}

bool Exists(const char *key)
{
  CFPropertyListRef v = CopyValue(key);
  if (!v)
    return false;
  CFRelease(v);
  return true;
}

void Remove(const char *key)
{
  SetValue(key, NULL);
}

void ListKeys(const char *prefix, AStringVector &keys)
{
  keys.Clear();
  CFArrayRef list = CFPreferencesCopyKeyList(AppID(), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
  if (!list)
    return;
  const size_t prefixLen = strlen(prefix);
  const CFIndex n = CFArrayGetCount(list);
  for (CFIndex i = 0; i < n; i++)
  {
    CFTypeRef item = CFArrayGetValueAtIndex(list, i);
    if (!item || CFGetTypeID(item) != CFStringGetTypeID())
      continue;
    UString u;
    if (!CFStringToUString((CFStringRef)item, u))
      continue;
    const AString a = UnicodeStringToMultiByte(u, CP_UTF8);
    if (strncmp(a.Ptr(), prefix, prefixLen) == 0)
      keys.Add(a);
  }
  CFRelease(list);
}

void Sync()
{
  CFPreferencesAppSynchronize(AppID());
}

}
