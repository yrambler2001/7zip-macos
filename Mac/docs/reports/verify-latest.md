# Verification run — 2026-09-19 23:07:13 +0200

* scope / branch: `mac/harness`  (commit `496ca93`)
* configuration: Debug (clean)
* command: `Mac/scripts/verify.sh`  → exit 0
* toolchain: `DEVELOPER_DIR=/Applications/Xcode.app`, Xcode 26.6

| result | step | time | detail |
|---|---|---|---|
| ok | clean build (Debug) | 32s | OK: ~/things/a.noindex/7zip/.worktrees/harness/Mac/build/Debug/7-Zip.app -> ~/things/a.noindex/7zip/.worktrees/harness/Mac/build/DerivedData/Build/Products/Debug/7-Zip.app |
| ok | unit tests | 7s | OK: tests passed |
| ok | UI tests | 143s | OK: tests passed |

## Parity (Mac/docs/PROGRESS.md)

```
scope          done  total    pct
scaffold          0     57     0%
fsfolder          0     58     0%
panel             0    108     0%
extract           0     57     0%
compress          0     52     0%
tools             0     40     0%
options           0     46     0%
finder            0     36     0%
packaging         1     22     5%
TOTAL             1    476     0%
```

Logs: `Mac/build/build-Debug.log`, `Mac/build/test-SevenZipKitTests.log`, `Mac/build/test-7-ZipUITests.log`.
Screenshots: `Mac/docs/reports/screenshots/`.
