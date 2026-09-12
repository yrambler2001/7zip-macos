// SZLang.h -- 7-Zip Lang/*.txt localisation (CPP/Common/Lang.cpp rules, see
// 01-fm-feature-inventory.md section 7 and 04-toolchain.md section 4). String IDs are the
// Windows resource IDs. The built-in English table is Lang/en.ttt from the framework bundle.

#ifndef SZ_LANG_H
#define SZ_LANG_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SZLanguageInfo : NSObject
@property (nonatomic, readonly, copy) NSString *code;          ///< file name without .txt ("de", "pt-br")
@property (nonatomic, readonly, copy) NSString *path;
@property (nonatomic, readonly, copy) NSString *englishName;   ///< string 1
@property (nonatomic, readonly, copy) NSString *nativeName;    ///< string 2
@property (nonatomic, readonly) NSInteger stringCount;
@end

@interface SZLang : NSObject

@property (class, nonatomic, readonly) SZLang *shared;

/// Lang string for an ID: current language file, else built-in English, else "".
- (NSString *)stringForID:(uint32_t)langID NS_SWIFT_NAME(string(forID:));
/// Same, with an explicit fallback when neither table has the ID.
- (NSString *)stringForID:(uint32_t)langID fallback:(NSString *)fallback NS_SWIFT_NAME(string(forID:fallback:));
/// Only from the loaded language file (LangString_OnlyFromLangFile); nil if absent or no file.
- (nullable NSString *)translatedStringForID:(uint32_t)langID NS_SWIFT_NAME(translatedString(forID:));
/// Built-in English (MyLoadString equivalent); "" if unknown.
- (NSString *)englishStringForID:(uint32_t)langID NS_SWIFT_NAME(englishString(forID:));

/// Loads Lang/<code>.txt. code nil or "" = pick from the system UI language; "-" = built-in
/// English only. A bad file leaves English active and returns NO.
- (BOOL)loadLanguageWithCode:(nullable NSString *)code error:(NSError **)error NS_SWIFT_NAME(loadLanguage(code:));
/// Loads a specific file (for tests / custom locations).
- (BOOL)loadLanguageFile:(NSString *)path error:(NSError **)error NS_SWIFT_NAME(loadLanguageFile(_:));
/// The code currently active ("" = none / built-in English).
@property (nonatomic, readonly, copy) NSString *currentLanguageCode;
/// Header comments of the loaded file (translator credits), as 7zFM's Language page shows them.
@property (nonatomic, readonly, copy) NSArray<NSString *> *comments;

/// Every Lang/*.txt in the bundle, sorted by code.
@property (nonatomic, readonly, copy) NSArray<SZLanguageInfo *> *availableLanguages;
@property (class, nonatomic, readonly) NSString *langDirectoryPath;
/// Number of strings in the English template (k_NumLangLines_EN, for completeness %).
@property (nonatomic, readonly) NSInteger englishStringCount;

/// Candidate codes for the system language, most specific first ("pt-br", "pt").
@property (class, nonatomic, readonly) NSArray<NSString *> *systemLanguageCandidates;

@end

NS_ASSUME_NONNULL_END

#endif
