# Verification run — 2026-09-20 16:12:28 +0200

* scope / branch: `mac/packaging`  (commit `b674de0`)
* configuration: Debug (clean)
* command: `Mac/scripts/verify.sh`  → exit 0
* toolchain: `DEVELOPER_DIR=/Applications/Xcode.app`, Xcode 26.6

| result | step | time | detail |
|---|---|---|---|
| ok | clean build (Debug) | 39s | OK: ~/things/a.noindex/7zip/.worktrees/packaging/Mac/build/Debug/7-Zip.app -> ~/things/a.noindex/7zip/.worktrees/packaging/Mac/build/DerivedData/Build/Products/Debug/7-Zip.app |
| ok | unit tests | 41s | OK: tests passed |
| ok | UI tests | 1095s | OK: tests passed |

## Parity (Mac/docs/PROGRESS.md)

```
scope          done  total    pct
scaffold         28     57    49%
fsfolder         24     58    41%
panel           103    108    95%
extract          51     57    89%
compress         50     52    96%
tools            36     40    90%
options          43     46    93%
finder           30     36    83%
packaging        11     22    50%
icons            20     20   100%
TOTAL           396    496    80%
```

Logs: `Mac/build/build-Debug.log`, `Mac/build/test-SevenZipKitTests.log`, `Mac/build/test-7-ZipUITests.log`.
Screenshots: `Mac/docs/reports/screenshots/`.
