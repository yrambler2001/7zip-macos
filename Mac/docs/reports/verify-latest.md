# Verification run — 2026-10-03 14:40:05 +0200

* scope / branch: `uiverify`  (commit `8fb530d`)
* configuration: Debug (clean)
* command: `Mac/scripts/verify.sh`  → exit 0
* toolchain: `DEVELOPER_DIR=/Applications/Xcode.app`, Xcode 26.6

| result | step | time | detail |
|---|---|---|---|
| ok | clean build (Debug) | 40s | OK: ~/things/a.noindex/7zip/.worktrees/uiverify/Mac/build/Debug/7-Zip.app -> ~/things/a.noindex/7zip/.worktrees/uiverify/Mac/build/DerivedData/Build/Products/Debug/7-Zip.app |
| ok | all tests (sharded) | 704s | OK: tests passed |

## Parity (Mac/docs/PROGRESS.md)

```
scope          done  total    pct
scaffold         49     57    86%
fsfolder         56     58    97%
panel           108    108   100%
extract          56     57    98%
compress         51     52    98%
tools            39     40    98%
options          45     46    98%
finder           32     36    89%
packaging        11     22    50%
icons            20     20   100%
TOTAL           467    496    94%
```

Logs: `Mac/build/build-Debug.log`, `Mac/build/test-SevenZipKitTests.log`,
`Mac/build/test-SevenZipAppTests.log`, `Mac/build/test-7-ZipUITests.log`,
`Mac/build/test-7-ZipUITestsProbe1.log`, `Mac/build/test-7-ZipUITestsProbe2.log`.
Screenshots: `Mac/docs/reports/screenshots/`.
