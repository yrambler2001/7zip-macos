// MacPrefs.h -- CFPreferences-backed key/value store used by the ZipRegistry
// accessors (ZipRegistryMac.cpp) and by SZSettings. Domain: the app bundle id
// (com.yrambler2001.7zip), current user, any host -- the same domain
// NSUserDefaults.standard uses inside the app, so Swift and the engine read the
// same values. Keys mirror the Windows registry value names, prefixed by the
// registry key path with dots: "Options.WorkDirType", "Extraction.ExtractMode",
// "Compression.Options.7z.Level" (01b-fm-dialogs-settings.md section 5.7).

#ifndef ZIP7_INC_MAC_PREFS_H
#define ZIP7_INC_MAC_PREFS_H

#include "../../../CPP/Common/MyString.h"

namespace NMacPrefs {

extern const char * const kAppID;   // "com.yrambler2001.7zip"

bool GetUInt32(const char *key, UInt32 &value);
bool GetBool(const char *key, bool &value);
bool GetString(const char *key, UString &value);
bool GetStrings(const char *key, UStringVector &values);

void SetUInt32(const char *key, UInt32 value);
void SetBool(const char *key, bool value);
void SetString(const char *key, const UString &value);
void SetStrings(const char *key, const UStringVector &values);

bool Exists(const char *key);
void Remove(const char *key);
// All keys of the domain that start with prefix (prefix is not stripped).
void ListKeys(const char *prefix, AStringVector &keys);
void Sync();

}

#endif
