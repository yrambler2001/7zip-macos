# `ai/` — how this port was built

Most of the macOS port was written by AI agents (Claude Code) under the direction of the
maintainer. This folder keeps the working files of that process, unedited apart from path updates,
so anyone can see how a piece of the app came about and what was checked. None of it is needed to
build, use or contribute to the app; the contributor docs are in [`../docs/`](../docs/).

## The process

- **One orchestrator session** held the plan. It never wrote features itself; it wrote the
  contract ([`00-orchestration.md`](00-orchestration.md)), split the work into *scopes* (panel,
  extract, compress, finder, options, …) and merged the results into `macos`.
- **One scoped agent at a time.** For each scope the orchestrator created a git worktree
  (`.worktrees/<scope>/`, branch `mac/<scope>`) and spawned an agent with a written brief. Each
  scope owned a fixed set of files (ownership table in the contract), committed only on its own
  branch, and finished with a report in [`reports/<scope>.md`](reports/) and, where other scopes
  needed it, a public API note in [`api/<scope>.md`](api/).
- **The specification was Windows.** Before any code, inventories of the Windows 7-Zip File
  Manager were written from the upstream sources:
  [`01-fm-feature-inventory.md`](01-fm-feature-inventory.md) (menus, panels, keys, settings),
  [`01b-fm-dialogs-settings.md`](01b-fm-dialogs-settings.md) (every dialog and control),
  [`03-shell-integration-inventory.md`](03-shell-integration-inventory.md) (Explorer
  integration and its macOS replacements), plus [`02-engine-api.md`](02-engine-api.md) and
  [`04-toolchain.md`](04-toolchain.md) for the engine and the build. Code comments cite these as
  `01 §3.7`, `01b §4.19`, `03 §2.6`.
- **Compared against the real thing.** Later scopes (`wincompare`, `winmatch`, `listfeel`,
  `dlgfeel`, `recheck*`, `selcolors`) ran 7zFM on a Windows machine, dumped its windows and
  controls and captured them, and measured the Mac app against those captures. The raw captures
  were removed before publication; the reports keep the measurements.
- **Tested in sequence.** Unit tests (bridge), app-hosted tests (inside the running app) and
  XCUITest shards ran after every scope, one agent at a time, because UI tests need the machine's
  only GUI session. A shared app-launch lock and per-run preferences domains kept runs apart.
- **Requests between scopes** and corrections to the inventories went through
  [`requests.md`](requests.md); the state of the whole port is in [`PROGRESS.md`](PROGRESS.md)
  (the 496-item checklist) and [`parity.md`](parity.md) (complete / partial / different /
  missing / unverified).

## Reading this folder

| File | What it is |
|---|---|
| [`00-orchestration.md`](00-orchestration.md) | the contract every agent read first: goal, locked decisions, layout, branching, file ownership |
| [`requests.md`](requests.md) | cross-scope requests and spec corrections that override the inventories |
| [`HANDOFF.md`](HANDOFF.md) | what a fresh machine needs, the scope status, how to resume |
| [`PROGRESS.md`](PROGRESS.md) | the parity checklist, per scope |
| [`parity.md`](parity.md) | the detailed parity audit (the short version is [`../docs/parity.md`](../docs/parity.md)) |
| [`architecture.md`](architecture.md) | the design notes and the "As built" bridge API (the short version is [`../docs/architecture.md`](../docs/architecture.md)) |
| [`test-support-contract.md`](test-support-contract.md) | the environment variables and `sevenzip://test/reset` the app honours for tests |
| `01*`, `02`, `03`, `04` | the inventories and engine / toolchain notes described above |
| [`api/`](api/) | the public API each scope exposed to the others |
| [`reports/`](reports/) | one report per scope: what was built, how it maps to Windows, what was verified, what was left |

Reports are a record, not documentation: they describe the code as it was when the scope finished,
and later scopes may have changed it. Paths in them were updated when this folder moved here from
`Mac/docs/`; paths to removed screenshots and capture data are kept as written.

## Recognising AI-written commits

Commits made by an agent end with two trailers:

```
Co-Authored-By: Claude <model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_…
```

and are prefixed `mac(<scope>): `, naming the scope (and report) they belong to. Merge commits
`Merge mac/<scope> into macos` mark where a scope was integrated.
