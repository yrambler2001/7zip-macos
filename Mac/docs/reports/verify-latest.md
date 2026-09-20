# Verification run — 2026-09-20 14:33:41 +0200

* scope / branch: `mac/harness2`  (commit `da57e12`)
* configuration: Debug (clean)
* command: `Mac/scripts/verify.sh`  → exit 0
* toolchain: `DEVELOPER_DIR=/Applications/Xcode.app`, Xcode 26.6

| result | step | time | detail |
|---|---|---|---|
| ok | clean build (Debug) | 36s | OK: ~/things/a.noindex/7zip/.worktrees/harness2/Mac/build/Debug/7-Zip.app -> ~/things/a.noindex/7zip/.worktrees/harness2/Mac/build/DerivedData/Build/Products/Debug/7-Zip.app |
| ok | unit tests | 51s | OK: tests passed |
| ok | UI tests | 278s | OK: tests passed |

## Parity (Mac/docs/PROGRESS.md)

```
scope          done  total    pct
scaffold         28     57    49%
fsfolder         24     58    41%
panel           106    108    98%
extract          52     57    91%
compress         50     52    96%
tools            37     40    93%
options          44     46    96%
finder            0     36     0%
packaging         1     22     5%
icons            20     20   100%
TOTAL           362    496    73%
```

Logs: `Mac/build/build-Debug.log`, `Mac/build/test-SevenZipKitTests.log`, `Mac/build/test-7-ZipUITests.log`.
Screenshots: `Mac/docs/reports/screenshots/`.
