// SZArchiveOpener.h -- open an archive (CAgent / IInFolderArchive) into folders.

#ifndef SZ_ARCHIVE_OPENER_H
#define SZ_ARCHIVE_OPENER_H

#import <Foundation/Foundation.h>
#import <SevenZipKit/SZFolder.h>

NS_ASSUME_NONNULL_BEGIN

/// Answers ICryptoGetTextPassword during open (encrypted 7z headers, RAR, ...).
/// Called on the engine thread; the app marshals to the main thread and blocks.
@protocol SZPasswordDelegate <NSObject>
/// Return nil to cancel (the open then fails with SZErrorCodeCancelled).
- (nullable NSString *)passwordForArchiveAtPath:(NSString *)path;
@end

/// An opened archive; owns the agent. Close explicitly or let it deallocate.
@interface SZArchive : NSObject

- (instancetype)init NS_UNAVAILABLE;

/// The path used to open it: a file-system path, or "<outer full path>/<item name>" for nested archives.
@property (nonatomic, readonly, copy) NSString *path;
/// Handler name of the outermost level ("7z", "zip", "gzip", ...).
@property (nonatomic, readonly, copy) NSString *type;
/// CAgent::GetErrorMessage(): warnings collected while opening, or nil.
@property (nonatomic, readonly, copy, nullable) NSString *errorMessage;
/// The folder this archive was opened from (nil when opened by path).
@property (nonatomic, readonly, nullable) SZFolder *outerFolder;
@property (nonatomic, readonly) NSInteger outerItemIndex;
@property (nonatomic, readonly) BOOL isReadOnly;      ///< no handler in the chain can update
/// Temp folder (7zO...) holding the extracted copy of a nested archive whose item stream was
/// not seekable; removed when the archive is closed / deallocated. nil otherwise.
@property (nonatomic, readonly, copy, nullable) NSString *tempDirectory;
@property (nonatomic, readonly, nullable) SZArcProps *arcProps;

/// IInFolderArchive::BindToRootFolder, items loaded.
- (nullable SZFolder *)rootFolder:(NSError **)error NS_SWIFT_NAME(rootFolder());
/// IInFolderArchive::ReOpen with the same callback.
- (BOOL)reopen:(NSError **)error NS_SWIFT_NAME(reopen());
- (void)close;

@end

@interface SZArchiveOpener : NSObject

/// Opens a file. formatHint: nil/"" = detect by signature and extension, a handler name ("7z"),
/// "*" = first matching handler, "#" = parser mode (02-engine-api.md 2.5.1). Loads codecs
/// on demand. Encrypted archives without a delegate fail with SZErrorCodePasswordRequired.
+ (nullable SZArchive *)openArchiveAtPath:(NSString *)path
                               formatHint:(nullable NSString *)formatHint
                         passwordDelegate:(nullable id<SZPasswordDelegate>)passwordDelegate
                                    error:(NSError **)error NS_SWIFT_NAME(openArchive(atPath:formatHint:passwordDelegate:));

/// Opens item `index` of `folder` as an archive. In a file-system folder the file is opened.
/// Inside an archive the item's stream is used directly when the handler provides a seekable
/// one (IInArchiveGetStream: tar, xz, cpio, disk images, ...); otherwise (zip, 7z, gzip, ...)
/// the item is extracted to a temp folder first, exactly like 7zFM (PanelItemOpen.cpp).
+ (nullable SZArchive *)openArchiveInFolder:(SZFolder *)folder
                                  itemIndex:(NSInteger)index
                                 formatHint:(nullable NSString *)formatHint
                           passwordDelegate:(nullable id<SZPasswordDelegate>)passwordDelegate
                                      error:(NSError **)error NS_SWIFT_NAME(openArchive(in:itemIndex:formatHint:passwordDelegate:));

@end

NS_ASSUME_NONNULL_END

#endif
