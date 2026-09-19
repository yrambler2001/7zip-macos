# Verification run — 2026-09-20 00:49:14 +0200

* scope / branch: `macos`  (commit `d4afec7`)
* configuration: Debug (clean)
* command: `Mac/scripts/verify.sh`  → exit 65
* toolchain: `DEVELOPER_DIR=/Applications/Xcode.app`, Xcode 26.6

| result | step | time | detail |
|---|---|---|---|
| ok | clean build (Debug) | 22s | OK: ~/things/a.noindex/7zip/Mac/build/Debug/7-Zip.app -> ~/things/a.noindex/7zip/Mac/build/DerivedData/Build/Products/Debug/7-Zip.app |
| ok | unit tests | 36s | OK: tests passed |
| **FAIL** | UI tests | 377s | rc=65: ~/things/a.noindex/7zip/Mac/Tests/UITests/PanelTests.swift:136: error: -[SevenZipUITests.PanelTests testCopyBetweenPanels] : XCTAssertTrue fai |

## Parity (Mac/docs/PROGRESS.md)

```
scope          done  total    pct
scaffold          0     57     0%
fsfolder         24     58    41%
panel           106    108    98%
extract          52     57    91%
compress         50     52    96%
tools            37     40    93%
options          44     46    96%
finder            0     36     0%
packaging         1     22     5%
icons            20     20   100%
TOTAL           334    496    67%
```

Logs: `Mac/build/build-Debug.log`, `Mac/build/test-SevenZipKitTests.log`, `Mac/build/test-7-ZipUITests.log`.
Screenshots: `Mac/docs/reports/screenshots/`.
