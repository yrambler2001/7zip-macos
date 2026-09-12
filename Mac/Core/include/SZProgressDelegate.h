// SZProgressDelegate.h -- the callback surface of every long operation (extract, update,
// copy, hash, test). Methods are invoked on the engine's worker thread; the implementation
// must be thread-safe and must not touch AppKit directly. Questions (askOverwrite,
// askPassword) block the worker until answered. checkBreak returning YES cancels
// (the engine receives E_ABORT); pausing is implemented by blocking inside checkBreak.
// Not used by the scaffold yet; SZExtractor/SZUpdater/SZHasher (later waves) drive it.

#ifndef SZ_PROGRESS_DELEGATE_H
#define SZ_PROGRESS_DELEGATE_H

#import <Foundation/Foundation.h>
#import <SevenZipKit/SZTypes.h>

NS_ASSUME_NONNULL_BEGIN

@protocol SZProgressDelegate <NSObject>

/// IProgress::SetTotal
- (void)progressSetTotal:(uint64_t)total;
/// IProgress::SetCompleted (may be called concurrently from several engine threads)
- (void)progressSetCompleted:(uint64_t)completed;
/// ICompressProgressInfo::SetRatioInfo
- (void)progressSetRatioInfoInSize:(uint64_t)inSize outSize:(uint64_t)outSize;
/// Current item (PrepareOperation / SetCurrentFilePath)
- (void)progressSetCurrentFile:(NSString *)path isDirectory:(BOOL)isDirectory;
/// SetNumFiles / files processed so far
- (void)progressSetNumFilesProcessed:(uint64_t)numFiles;
/// IFolderArchiveExtractCallback::AskOverwrite. `suggestedName` may receive a new name for SZOverwriteAnswerAutoRename.
- (SZOverwriteAnswer)progressAskOverwriteExisting:(NSString *)existName
                                        existTime:(nullable NSDate *)existTime
                                        existSize:(nullable NSNumber *)existSize
                                          newName:(NSString *)newName
                                          newTime:(nullable NSDate *)newTime
                                          newSize:(nullable NSNumber *)newSize
                                    suggestedName:(NSString * _Nullable * _Nullable)suggestedName;
/// ICryptoGetTextPassword; nil = cancel.
- (nullable NSString *)progressAskPasswordForPath:(NSString *)path;
/// MessageError / ShowMessage
- (void)progressShowMessage:(NSString *)message;
/// SetOperationResult / ReportExtractResult for one item
- (void)progressSetOperationResult:(SZOperationResult)result path:(NSString *)path isEncrypted:(BOOL)encrypted;
/// Polled from every callback; YES = cancel. Block here to pause.
- (BOOL)progressCheckBreak;

@end

NS_ASSUME_NONNULL_END

#endif
