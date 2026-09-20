# Verification run — 2026-09-21 00:18:44 +0200

* scope / branch: `mac/fastui`  (commit `02a3250`)
* configuration: Debug (incremental)
* command: `Mac/scripts/verify.sh`  → exit 0
* toolchain: `DEVELOPER_DIR=/Applications/Xcode.app`, Xcode 26.6

| result | step | time | detail |
|---|---|---|---|
| ok | build (Debug) | 5s | OK: ~/things/a.noindex/7zip/.worktrees/fastui/Mac/build/Debug/7-Zip.app -> ~/things/a.noindex/7zip/.worktrees/fastui/Mac/build/DerivedData/Build/Products/Debug/7-Zip.app |
| ok | all tests (sharded) | 674s | OK: tests passed |

## Parity (Mac/docs/PROGRESS.md)

```
scope          done  total    pct
scaffold         29     57    51%
fsfolder         24     58    41%
panel           103    108    95%
extract          51     57    89%
compress         50     52    96%
tools            36     40    90%
options          43     46    93%
finder           32     36    89%
packaging        11     22    50%
icons            20     20   100%
TOTAL           399    496    80%
```

Logs: `Mac/build/build-Debug.log`, `Mac/build/test-SevenZipKitTests.log`,
`Mac/build/test-SevenZipAppTests.log`, `Mac/build/test-7-ZipUITests.log`,
`Mac/build/test-7-ZipUITestsProbe1.log`, `Mac/build/test-7-ZipUITestsProbe2.log`.
Screenshots: `Mac/docs/reports/screenshots/`.
