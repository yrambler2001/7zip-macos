// SevenZipKit.h -- umbrella header of the Objective-C bridge to the 7-Zip engine.
// Swift: `import SevenZipKit`. No C++ types appear in these headers.

#ifndef SEVENZIPKIT_H
#define SEVENZIPKIT_H

#import <Foundation/Foundation.h>

FOUNDATION_EXPORT double SevenZipKitVersionNumber;
FOUNDATION_EXPORT const unsigned char SevenZipKitVersionString[];

#import <SevenZipKit/SZTypes.h>
#import <SevenZipKit/SZError.h>
#import <SevenZipKit/SZExtractor.h>
#import <SevenZipKit/SZCodecs.h>
#import <SevenZipKit/SZFolder.h>
#import <SevenZipKit/SZFolderOperations.h>
#import <SevenZipKit/SZFileSystemFolder.h>
#import <SevenZipKit/SZRootFolder.h>
#import <SevenZipKit/SZArchiveOpener.h>
#import <SevenZipKit/SZLang.h>
#import <SevenZipKit/SZSettings.h>
#import <SevenZipKit/SZProgressDelegate.h>

NS_ASSUME_NONNULL_BEGIN
/// 7-Zip engine version string ("26.03") from C/7zVersion.h.
FOUNDATION_EXPORT NSString *SZEngineVersionString(void);
/// 7-Zip engine copyright/date line.
FOUNDATION_EXPORT NSString *SZEngineCopyrightString(void);
NS_ASSUME_NONNULL_END

#endif
