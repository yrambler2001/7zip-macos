// FSEventsWatcher.cpp -- see FSEventsWatcher.h

#include "FSEventsWatcher.h"

#include <CoreServices/CoreServices.h>
#include <dispatch/dispatch.h>

#include <atomic>
#include <memory>
#include <string>

namespace NMacFolders {

typedef std::shared_ptr<std::atomic<bool> > CFlagPtr;

struct CFSEventsWatcher::Impl
{
  FSEventStreamRef stream;
  CFlagPtr flag;
  std::string path;   // normalized, no trailing slash (except "/")
  Impl(): stream(NULL) {}
};

static dispatch_queue_t WatcherQueue()
{
  static dispatch_queue_t q = dispatch_queue_create("com.yrambler2001.7zip.fsevents", DISPATCH_QUEUE_SERIAL);
  return q;
}

static std::string NormalizeDir(const char *p)
{
  std::string s(p ? p : "");
  while (s.size() > 1 && s[s.size() - 1] == '/')
    s.erase(s.size() - 1);
  return s;
}

// The stream owns one heap-allocated shared_ptr to the flag (context info). It is freed by
// the release callback when the stream is invalidated; no retain callback (FSEvents stores
// the original info pointer regardless of what a retain callback returns).
static void ReleaseFlag(const void *info)
{
  delete (const CFlagPtr *)info;
}

static void Callback(ConstFSEventStreamRef, void *info, size_t numEvents,
    void *eventPaths, const FSEventStreamEventFlags[], const FSEventStreamEventId[])
{
  // The flag is shared with the owner; the stream keeps its own reference through the
  // context retain/release callbacks, so this is safe even after the owner is gone.
  CFlagPtr *flag = (CFlagPtr *)info;
  (void)numEvents; (void)eventPaths;
  (*flag)->store(true);
}

CFSEventsWatcher::CFSEventsWatcher(const char *dirPath): _impl(new Impl)
{
  _impl->path = NormalizeDir(dirPath);
  _impl->flag = CFlagPtr(new std::atomic<bool>(false));

  CFStringRef cfPath = CFStringCreateWithCString(kCFAllocatorDefault, _impl->path.c_str(), kCFStringEncodingUTF8);
  if (!cfPath)
    return;
  const void *paths[1] = { cfPath };
  CFArrayRef pathArray = CFArrayCreate(kCFAllocatorDefault, paths, 1, &kCFTypeArrayCallBacks);
  CFRelease(cfPath);
  if (!pathArray)
    return;

  CFlagPtr *ctxInfo = new CFlagPtr(_impl->flag);
  FSEventStreamContext ctx;
  ctx.version = 0;
  ctx.info = ctxInfo;
  ctx.retain = NULL;
  ctx.release = ReleaseFlag;
  ctx.copyDescription = NULL;

  // Without kFSEventStreamCreateFlagFileEvents the callback receives one event per changed
  // directory; changes inside sub-directories arrive with the sub-directory's path. We only
  // care that *something* changed under our own directory, so no filtering is needed: the
  // panel reloads and compares. Latency 0.5 s coalesces bursts.
  FSEventStreamRef stream = FSEventStreamCreate(kCFAllocatorDefault, Callback, &ctx,
      pathArray, kFSEventStreamEventIdSinceNow, 0.5,
      kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot);
  CFRelease(pathArray);
  if (!stream)
  {
    delete ctxInfo;
    return;
  }
  FSEventStreamSetDispatchQueue(stream, WatcherQueue());
  if (!FSEventStreamStart(stream))
  {
    FSEventStreamInvalidate(stream);
    FSEventStreamRelease(stream);
    return;
  }
  _impl->stream = stream;
}

CFSEventsWatcher::~CFSEventsWatcher()
{
  if (_impl->stream)
  {
    // Tear down on the callback queue itself so that no callback can be running while the
    // context info is released (the destructor never runs on that queue).
    FSEventStreamRef stream = _impl->stream;
    dispatch_sync(WatcherQueue(), ^{
      FSEventStreamStop(stream);
      FSEventStreamInvalidate(stream);
      FSEventStreamRelease(stream);
    });
  }
  delete _impl;
}

bool CFSEventsWatcher::IsActive() const
{
  return _impl->stream != NULL;
}

bool CFSEventsWatcher::ConsumeChanged()
{
  return _impl->flag->exchange(false);
}

}
