# Verification run — 2026-10-03 15:33:37 +0200

* scope / branch: `release`  (commit `b9c963b`)
* configuration: Debug (clean)
* command: `Mac/scripts/verify.sh`  → exit 0
* toolchain: `DEVELOPER_DIR=/Applications/Xcode.app`, Xcode 26.6

| result | step | time | detail |
|---|---|---|---|
| ok | clean build (Debug) | 42s | OK: ~/things/a.noindex/7zip/.worktrees/release/Mac/build/Debug/7-Zip.app -> ~/things/a.noindex/7zip/.worktrees/release/Mac/build/DerivedData/Build/Products/Debug/7-Zip.app |
| ok | all tests (sharded) | 724s | OK: tests passed |

## Parity (Mac/docs/PROGRESS.md)

```
scope          done  total    pct
scaffold         55     57    96%
fsfolder         58     58   100%
panel           108    108   100%
extract          57     57   100%
compress         52     52   100%
tools            40     40   100%
options          46     46   100%
finder           34     36    94%
packaging        20     22    91%
icons            20     20   100%
TOTAL           490    496    99%
```

Logs: `Mac/build/build-Debug.log`, `Mac/build/test-SevenZipKitTests.log`,
`Mac/build/test-SevenZipAppTests.log`, `Mac/build/test-7-ZipUITests.log`,
`Mac/build/test-7-ZipUITestsProbe1.log`, `Mac/build/test-7-ZipUITestsProbe2.log`.
Screenshots: `Mac/docs/reports/screenshots/`.
