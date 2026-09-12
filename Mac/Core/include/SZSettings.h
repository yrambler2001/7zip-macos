// SZSettings.h -- typed access to the shared preferences domain (com.yrambler2001.7zip).
// Keys mirror the Windows registry value names with the key path as a dotted prefix
// (01b-fm-dialogs-settings.md section 5.7): "Lang", "FM.PanelPath0", "Extraction.ExtractMode",
// "Compression.Options.7z.Level", "Options.WorkDirType". The engine-side ZipRegistry accessors
// (Mac/Core/Platform/ZipRegistryMac.cpp) read and write the same keys.

#ifndef SZ_SETTINGS_H
#define SZ_SETTINGS_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// HKCU\Software\7-Zip
FOUNDATION_EXPORT NSString * const SZSettingsKeyLang;                 // "Lang"
// HKCU\Software\7-Zip\FM
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMPosition;           // "FM.Position" (window frame string)
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMMaximized;          // "FM.Maximized"
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMNumPanels;          // "FM.Panels.numPanels"
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMCurrentPanel;       // "FM.Panels.currentPanel"
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMSplitterPos;        // "FM.Panels.splitterPos" (ratio 0..1)
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMToolbars;           // "FM.Toolbars"
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMListMode0;          // "FM.ListMode0"
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMListMode1;          // "FM.ListMode1"
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMPanelPath0;         // "FM.PanelPath0"
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMPanelPath1;         // "FM.PanelPath1"
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMFlatViewArc0;       // "FM.FlatViewArc0"
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMFlatViewArc1;       // "FM.FlatViewArc1"
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMFolderHistory;      // "FM.FolderHistory"
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMFolderShortcuts;    // "FM.FolderShortcuts"
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMCopyHistory;        // "FM.CopyHistory"
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMShowDots;           // "FM.ShowDots"
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMShowRealFileIcons;  // "FM.ShowRealFileIcons"
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMFullRow;            // "FM.FullRow"
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMShowGrid;           // "FM.ShowGrid"
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMSingleClick;        // "FM.SingleClick"
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMAlternativeSelection; // "FM.AlternativeSelection"
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMShowSystemMenu;     // "FM.ShowSystemMenu"
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMViewer;             // "FM.Viewer"
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMEditor;             // "FM.Editor"
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMDiff;               // "FM.Diff"
// HKCU\Software\7-Zip\Options
FOUNDATION_EXPORT NSString * const SZSettingsKeyWorkDirType;          // "Options.WorkDirType"
FOUNDATION_EXPORT NSString * const SZSettingsKeyWorkDirPath;          // "Options.WorkDirPath"
FOUNDATION_EXPORT NSString * const SZSettingsKeyTempRemovableOnly;    // "Options.TempRemovableOnly"

@interface SZSettings : NSObject

@property (class, nonatomic, readonly) NSString *applicationID;

+ (nullable NSString *)stringForKey:(NSString *)key NS_SWIFT_NAME(string(forKey:));
+ (void)setString:(nullable NSString *)value forKey:(NSString *)key;   ///< nil removes

+ (NSInteger)integerForKey:(NSString *)key defaultValue:(NSInteger)defaultValue NS_SWIFT_NAME(integer(forKey:defaultValue:));
+ (void)setInteger:(NSInteger)value forKey:(NSString *)key;

+ (double)doubleForKey:(NSString *)key defaultValue:(double)defaultValue NS_SWIFT_NAME(double(forKey:defaultValue:));
+ (void)setDouble:(double)value forKey:(NSString *)key;

+ (BOOL)boolForKey:(NSString *)key defaultValue:(BOOL)defaultValue;
+ (void)setBool:(BOOL)value forKey:(NSString *)key;

/// CBoolPair: nil = undefined (registry value absent).
+ (nullable NSNumber *)boolPairForKey:(NSString *)key NS_SWIFT_NAME(boolPair(forKey:));
+ (void)setBoolPair:(nullable NSNumber *)value forKey:(NSString *)key;

+ (nullable NSArray<NSString *> *)stringArrayForKey:(NSString *)key NS_SWIFT_NAME(stringArray(forKey:));
+ (void)setStringArray:(nullable NSArray<NSString *> *)value forKey:(NSString *)key;

+ (BOOL)hasKey:(NSString *)key NS_SWIFT_NAME(hasKey(_:));
+ (void)removeKey:(NSString *)key NS_SWIFT_NAME(removeKey(_:));
+ (NSArray<NSString *> *)keysWithPrefix:(NSString *)prefix NS_SWIFT_NAME(keys(withPrefix:));
+ (void)synchronize;

@end

/// NWorkDir::CInfo (the one engine setting read implicitly by every Agent update).
typedef NS_ENUM(NSInteger, SZWorkDirMode) {
    SZWorkDirModeSystem = 0,
    SZWorkDirModeCurrent = 1,
    SZWorkDirModeSpecified = 2
};

@interface SZWorkDirSettings : NSObject
@property (nonatomic) SZWorkDirMode mode;
@property (nonatomic, copy) NSString *path;
@property (nonatomic) BOOL forRemovableOnly;
/// NWorkDir::CInfo::Load() / Save() through the engine's own accessor.
+ (SZWorkDirSettings *)loadFromSettings NS_SWIFT_NAME(loadFromSettings());
- (void)save;
@end

NS_ASSUME_NONNULL_END

#endif
