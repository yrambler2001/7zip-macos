# Test-support contract (frozen)

Owned by the orchestrator and frozen, like `OperationContext`. Two scopes compile against it in
parallel: `resetcmd` implements it in the app, `fastui` consumes it from the tests. Neither may
change the shape without the orchestrator's agreement.

## Why

The UI suite costs 28.7 seconds per test because every test quits and relaunches the app. Assertions
are a rounding error next to process launch. This contract removes the relaunch, kills animation
time, and lets several app instances coexist so read-only tests can run in parallel shards. Measured
baseline to beat: 52 UI tests in 1490 s, 311 unit tests in 24 s.

## Environment variables the app honours

| Variable | Meaning |
|---|---|
| `SZ_TEST_SUPPORT` | When set to `1`, the test-only affordances below exist. Unset means none of them do, and the `test` URL host is rejected. |
| `SZ_DISABLE_ANIMATIONS` | When `1`, window and view animation durations are zero, automatic window animation and window tabbing are off, and no dialog animates in or out. |
| `SEVENZIP_DEFAULTS_SUITE` | Already implemented. A preferences domain name or an absolute plist path used as the app's whole settings domain. |
| `SZ_STATE_DIR` | Absolute directory the instance uses for everything it would otherwise put in a shared location: work directory, temp extraction folders, caches. Two instances given different values must never touch the same file. |

## The reset command

`sevenzip://test/reset?<query>` returns the running app to a known state without quitting. Accepted
parameters, all optional:

| Parameter | Effect |
|---|---|
| `defaults` | Absolute path to a plist. Replaces the settings domain's contents with it and reloads everything that reads settings, including the language. |
| `lang` | Language code to load, as the Options Language page would. |
| `panels` | `1` or `2`. |
| `path0`, `path1` | Directory each panel shows. |
| `view` | Default view mode for both panels. |
| `ack` | Absolute path the app writes when the reset is complete. |

Reset must: close every sheet, dialog, alert and secondary window; cancel or finish any running
operation; reload settings; rebuild both panels at the requested paths; and return selection, sort
order, view mode and flat mode to their defaults. It must leave the app usable for the next test
without a relaunch.

## How a test knows the reset finished

Two signals, both required.

1. If `ack` is given, the app writes that file last, after everything else has settled. Content is
   the reset generation as decimal text. The app is not sandboxed, so it can write wherever the test
   asks.
2. The main window's accessibility value is the reset generation as a string, starting at `0` before
   the first reset. A test may poll for it to increase instead of using a file.

## Running several instances at once

The app must tolerate instances built with different bundle identifiers running simultaneously. No
fixed-path lock files, no single-instance assumptions, nothing keyed on a hard-coded bundle
identifier. Anything instance-specific derives from `SZ_STATE_DIR` when it is set, and otherwise from
the running bundle identifier.

## What stays out of scope

No test affordance may change behaviour when `SZ_TEST_SUPPORT` is unset, and none may weaken a real
code path to make a test easier. If a test needs something the app cannot honestly do, the test is
wrong.
