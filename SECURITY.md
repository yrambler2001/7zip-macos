# Security policy

## Reporting a vulnerability

Please report security problems **privately** through GitHub:
[Security ▸ Report a vulnerability](https://github.com/yrambler2001/7zip-macos/security/advisories/new)
(GitHub Security Advisories). Do not open a public issue for them.

Include the app version (7-Zip ▸ About 7-Zip), the macOS version, what an attacker controls (an
archive, a file name, a URL) and, if you can, a sample file or steps to reproduce. You will get an
answer as soon as possible; this is a volunteer project, so please allow some days.

## Scope

- **Archive parsing is attack surface.** The app opens untrusted archives with the 7-Zip engine.
  A crash or memory-safety bug while listing, extracting or testing an archive may be exploitable.
- **The Mac-specific code** is in scope: the SevenZipKit bridge (`Mac/Core/`), the app, the Finder
  extensions, the `sevenzip://` URL scheme and command mode, path handling during extraction
  (path traversal, symbolic links), the quarantine attribute, and the update check.
- **The Quick Look preview extension** (`Mac/QuickLook/`), which lists an archive as soon as it is
  selected in Finder.
- **Engine vulnerabilities** that also affect 7-Zip on other platforms (the same archive crashes
  `7zz` or 7-Zip on Windows) belong upstream: report them to Igor Pavlov via
  [7-zip.org](https://www.7-zip.org). Tell us as well, so the fix is picked up here when upstream
  releases it.

## Supported versions

Only the latest release receives fixes. The app's engine is updated with upstream 7-Zip releases.
