# Mac/ — the macOS port

This directory holds the macOS app built on top of the upstream 7-Zip sources in `C/`, `CPP/` and
`Asm/`. The project's landing page is the [root README](../README.md).

| Path | Contents |
|---|---|
| `project.yml` | XcodeGen spec; `Mac/scripts/build.sh` generates `7-Zip.xcodeproj` from it |
| `Core/` | SevenZipKit, the Objective-C++ bridge to the engine |
| `App/` | the Swift + AppKit app |
| `FinderSync/`, `QuickAction/` | the Finder extensions |
| `QuickLook/` | the Quick Look preview extension (archive summary and contents) |
| `Resources/` | languages, SFX stubs, help pages, icons, Info.plists, entitlements |
| `scripts/` | build, run, test, verify, package, asset and icon tools |
| `Tests/` | unit, app-hosted and XCUITest suites, fixtures |
| `docs/` | the list of upstream patches and their exact diff |

Contributor docs: [building](../docs/building.md), [architecture](../docs/architecture.md),
[testing](../docs/testing.md), [upstream](../docs/upstream.md), [parity](../docs/parity.md).
How the port was made: [`ai/`](../ai/README.md).
