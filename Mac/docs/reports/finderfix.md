# finderfix — Finder menu items and Quick Actions did nothing

Branch `mac/finderfix` (from `macos` ca84f86). Parity references: `03-shell-integration-inventory.md`
§1.4 (the Explorer context-menu items), §6.1 (Quick Actions), §6.4 (the sandboxed hand-off).

## 1. The report

With 7-Zip installed in `/Applications`, Finder's right-click menu showed the **7-Zip** submenu, but
**Open archive** and **Add to archive…** did nothing, and **Quick Actions ▸ Extract with 7-Zip**
did nothing either.

## 2. Root causes, with evidence

Public `os_log` lines were added to the Finder Sync extension, the Quick Actions and the app's URL
handler. A Release build carrying them was installed in `/Applications`. Then **Finder's own
context menu was driven through XCUITest** (a real right-click on a `.zip` in a Finder window, the
arrow keys to enter the submenu, Return to choose). No Automation permission is needed for that.

**The app side was fine.** `open "sevenzip:///run?argv=<[…/t.zip]>"` from Terminal opened the
archive (`lsof` showed the app holding `t.zip`, and an on-screen window appeared). A malformed command
(`x -zzz …`, `sevenzip:///bogus`) put up an on-screen "7-Zip" error panel at window layer 8. So the
app was never the problem, and it does not fail silently.

**Cause 1: Finder Sync. The click arrives, but with no command attached.** The log from the
original code, for the two reported items:

```
FinderSync  DIAG invoke title=Add to archive... tag=0 rep=nil sel=Optional([".../probe.zip"]) targeted=...
FinderSync  DIAG invoke title=Open archive tag=0 rep=nil sel=Optional([".../probe.zip"]) ...
```

The action does fire in the extension, and the selection is available. Finder does not show the
extension's `NSMenu`, though. It copies the menu into its own process, and the copy keeps title,
image, tag and action but drops `representedObject` (and `target`). `invoke` started with
`guard let target = sender.representedObject as? InvocationTarget else { return }`, so every item
returned silently. Every Finder Sync item was affected, not only the two reported.

**Cause 2: Quick Actions. Finder never provides a file URL.**

```
QuickActionExtract  DIAG items=1 providers=[["public.zip-archive"]]
QuickActionExtract  DIAG run urls=[]
```

The attachment is registered only under the file's own content type. The code asked only for
`public.file-url`, skipped everything else, ended up with an empty list, and `run` returned
silently. This hit Extract and Compress alike.

**Cause 3: "Compress with 7-Zip" never appeared.** Finder's Quick Actions submenu showed only
"Extract with 7-Zip" for a `.zip` and only "Customize…" for a `.txt`. The appex is `+` in PlugInKit
and active in `pbs` `FinderActive`. Its rule was the `NSExtensionActivationSupportsFileWithMaxCount`
dictionary. After a UTI predicate replaced that rule (and Finder was relaunched, because Finder
caches activation rules), the action appeared and worked. The old rule was not re-tested after a
Finder relaunch, so "the old rule never matches" is likely but not proven in isolation.

**Not the cause, but a real hazard: other registered copies.** The extensions used an unaimed
`NSWorkspace.open(URL)`. On this machine `lsregister -dump` listed **39 bundles** claiming
`sevenzip:` (every worktree's Debug build, the main tree's Debug and Release, two e2e temp copies,
the mounted DMG). `urlForApplication` happened to pick `/Applications/7-Zip.app`. A rebuild could
change that choice, and a build could also take over Finder's extension registration.

## 3. The fix

| Where | What |
|---|---|
| `Mac/App/Integration/FinderMenuBuilder.swift` (new) | Builds the Finder Sync `NSMenu`. Each command item gets `tag = index + 1` in `FinderMenuModel.flattenCommands` order. No `representedObject`, no `target`. |
| `FinderMenuModel.swift` | `flattenCommands`, `menuTag(forIndex:)`, `resolveInvocation(tag:title:nodes:)`: rebuild the tree for the current selection, pick by tag, require the title to match, and fall back to a unique title (a stale tag after a settings change). The A1 / A2-first-child "Open archive" pair resolves to the same command line. |
| `Mac/FinderSync/FinderSync.swift` | `invoke` re-reads the selection (or the one the menu was built for), resolves the command, and hands off. Each failure reports to the app instead of returning silently. Shift (`CMF_EXTENDEDVERBS`) is kept process-wide, because the click may reach another instance. |
| `Mac/App/Integration/QuickActionInput.swift` (new) | Resolves attachments in this order: `public.file-url`; `loadInPlaceFileRepresentation` of the content type, accepted only when **in place** (a temporary copy would extract next to the copy); `loadItem` of the content type when it returns a file URL. Order is kept, and unusable attachments are dropped. |
| `Mac/QuickAction/QuickActionController.swift` | Uses `QuickActionInput`, reports a missing selection or command to the app, and completes the extension request only after the hand-off has been answered. |
| `Mac/App/Integration/ExtensionHandoff.swift` (new) | `NSWorkspace.open(_:withApplicationAt:)` **aimed at the containing app**, with the URL scheme as a fallback only. Measured: every hand-off from the sandboxed appexes was delivered `(aimed)`. |
| `CommandURL.swift`, `URLCommands.swift` | `sevenzip:///error?code=noitems\|command\|unavailable` puts up the matching fixed message in an error box. Unknown codes are rejected, so no arbitrary text can be shown. Every received URL is logged (path public). |
| `Mac/QuickAction/Compress/Info.plist` | Activation rule: `SUBQUERY(… UTI-CONFORMS-TO "public.item").@count >= 1`. |
| `Mac/scripts/finderext-registration.sh` | Hands **all three** extension identifiers back after a build or test run (it used to handle FinderSync only). When the copy Finder used before is outside this tree's `Mac/build`, it also `lsregister -u`s this tree's built `7-Zip.app`s, so they stop answering `sevenzip:` and the archive types. |
| `Mac/project.yml` | Compiles the three new shared files into the appexes, plus `ExtensionHandoff` / `FinderMenuBuilder` / `QuickActionInput` into the unit tests. |

Logging is permanent (subsystem `com.yrambler2001.7zip`, categories `FinderSync`, `QuickAction`,
`URL`), with outcomes public and paths private. To diagnose: `log stream --predicate 'subsystem == "com.yrambler2001.7zip"'`.

## 4. Verification

**End to end, through Finder** (`FinderContextMenuTests`, input shard, five cases), against the fixed
build installed in `/Applications`:

| Click in Finder | Log | Observed |
|---|---|---|
| 7-Zip ▸ Add to archive… | `invoke: tag 13 "Add to archive..."` → `invoke: SevenZipCompress` → `hand-off delivered (aimed)` → app `received sevenzip URL /run` | Add to Archive dialog |
| 7-Zip ▸ Open archive | `invoke: tag 1 "Open archive"` → `SevenZipOpen` → delivered (aimed) | window titled `…/probe.zip/` |
| 7-Zip ▸ Extract to "probe/" | `SevenZipExtractTo` → delivered (aimed) | `probe/readme.txt` on disk |
| Quick Actions ▸ Extract with 7-Zip | `1 attachments, types [["public.zip-archive"]]` → `resolved 1 of 1` → delivered (aimed) | `probe/…` extracted next to the archive |
| Quick Actions ▸ Compress with 7-Zip (`.txt`) | `types [["public.plain-text"]]` → `resolved 1 of 1` → delivered (aimed) | Add to Archive dialog |

These tests skip (rather than fail) when Finder shows no 7-Zip submenu or no Quick Actions,
because then the extension is switched off on that machine.

**Unit** (`FinderHandoffTests`, 13 cases):
- Every item of the menu Finder receives (copied with only title and tag) resolves to its own command.
- The Open and Add argv, and their URL round trip.
- Tag 0 and stale-tag fallbacks.
- The error URL for every code, plus a forged code rejected.
- Aimed open first, the scheme only on failure, and `.failed` when both fail.
- Quick Action input:
  - the Finder shape (content type only, in place) resolves to the original file;
  - `loadItem` returning a URL works;
  - the old `public.file-url` path still works;
  - order is kept and a non-file attachment is dropped, where a temporary copy used to come back.
- The Compress activation predicate matches `.txt` and folders.

**App reaction** (`FinderIntegrationTests.testExtensionFailureURLShowsAnErrorBox`): sending
`sevenzip:///error?code=noitems` shows the error box.

| Command | Result |
|---|---|
| `Mac/scripts/build.sh` (Debug), `build.sh -r` | exit 0, no warnings; registrations stay with `/Applications` |
| `Mac/scripts/test.sh` | 401 passed, 0 failed |
| `Mac/scripts/test.sh -H` | 255 passed, 0 failed |
| `Mac/scripts/test.sh -u` | **blocked by the machine**; see §6 |

**Machine state left behind:**
- `/Applications/7-Zip.app` is this branch's Release build (ad-hoc signed).
- `pluginkit` lists only the `/Applications` copies of the three extensions, all `+`.
- `NSWorkspace.urlsForApplications(toOpen: sevenzip:)` returns only `/Applications/7-Zip.app`. Every other copy was unregistered, including the main tree's `Mac/build/.../{Debug,Release}`, the worktree builds and the mounted DMG copy.
- The previous copy was kept at `~/7-Zip-backup.app` during the work and then removed.

## 5. What the user should check in Finder

1. Relaunch Finder once, so it reloads the extensions and Quick Action rules: Option-right-click
   Finder's Dock icon, then **Relaunch**.
2. Eject the old "7-Zip 26.03" disk image if it is still mounted, so its copy cannot register
   itself again.
3. Right-click any `.zip` and choose **7-Zip ▸ Open archive**. 7-Zip opens the archive in a window.
4. Right-click it again and choose **7-Zip ▸ Add to archive…**. The Add to Archive dialog appears;
   Cancel closes it.
5. Choose **7-Zip ▸ Extract to "<name>/"**. A folder `<name>` appears next to the archive.
6. Choose **Quick Actions ▸ Extract with 7-Zip** on a `.zip`. Same folder result (delete the first
   one before trying).
7. Choose **Quick Actions ▸ Compress with 7-Zip** on any file. The Add to Archive dialog appears.
   If it is missing, enable it under **Quick Actions ▸ Customize…**.
8. If anything does nothing, run
   `log stream --predicate 'subsystem == "com.yrambler2001.7zip"'` in Terminal, repeat the click, and
   send the lines. They show whether the menu was built, which item was clicked, whether the
   hand-off was delivered and what the app received.

## 6. UI suite

**Not green, and not because of this branch.** Two full `test.sh -u` runs, at 04:31 and at 04:57
after a 15-minute pause, died before their first test in all three shards. The error was
`Failed to initialize for UI testing: Timed out while enabling automation mode`, and
`automationmodetool` reported "Automation Mode is disabled. This device requires user
authentication to enable Automation Mode". This is the intermittent failure recorded in
`requests.md` (uiverify) and `HANDOFF.md`. A human has to approve it, or run
`sudo automationmodetool enable-automationmode-without-authentication` once.

What did run, before automation mode stopped being granted:
- `FinderContextMenuTests`, **5 of 5 passed** at 04:16–04:19 against the installed fix, through
  `xcodebuild test-without-building` with the same test bundle (the table in §4).
- During development, the same Finder-driving steps on the *original* code reproduced the bug:
  `rep=nil` for the clicked items, and `urls=[]` for the Quick Action.

`testExtensionFailureURLShowsAnErrorBox` has not run yet. Its behaviour was checked by hand:
`open "sevenzip:///error?code=noitems"` showed a second on-screen window titled "7-Zip" (the error
box) beside the panel window, and logged `received sevenzip URL /error` and
`extension reported noitems`. **The orchestrator should re-run `test.sh -u` once automation mode is
granted.**

## 7. Known gaps and follow-ups

- **Security (for the orchestrator):** any process can open `sevenzip:///run?argv=…` (a browser asks
  first). Commands that run without a dialog, such as `x -o<dir>`, therefore execute on request. A
  per-launch token or a check on the sender (the extension's audit token is not available through
  `NSWorkspace`) would close this. It is not in this scope.
- Finder caches Quick Action activation rules until it is relaunched. The fix cannot force that.
- The "7-Zip" `NSRunningApplication` that the UI tests query is the copy whose extension Finder runs.
  During `test.sh -u` that can briefly be the freshly built Debug copy, which is the same code.
- Two shared files outside this scope's table were edited: `Mac/project.yml` (source lists, additive)
  and `Mac/scripts/finderext-registration.sh` (harness). Both are needed for this fix.
