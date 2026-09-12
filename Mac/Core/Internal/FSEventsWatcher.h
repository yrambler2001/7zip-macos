// FSEventsWatcher.h -- "did anything change in this directory?" flag driven by FSEvents.
// Engine-free (no 7-Zip headers) so it can include CoreServices without typedef clashes.

#ifndef SZ_FSEVENTS_WATCHER_H
#define SZ_FSEVENTS_WATCHER_H

namespace NMacFolders {

class CFSEventsWatcher
{
  struct Impl;
  Impl *_impl;
public:
  // Starts watching `dirPath` (UTF-8, absolute). Non-recursive: only events for the
  // directory itself are reported.
  explicit CFSEventsWatcher(const char *dirPath);
  ~CFSEventsWatcher();
  bool IsActive() const;
  // Returns true once per batch of changes and clears the flag.
  bool ConsumeChanged();
private:
  CFSEventsWatcher(const CFSEventsWatcher &);
  CFSEventsWatcher &operator=(const CFSEventsWatcher &);
};

}

#endif
