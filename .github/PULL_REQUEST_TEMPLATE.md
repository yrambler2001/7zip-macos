## What and why

<!-- What does this change, and which issue does it address? -->

## How it maps to 7-Zip on Windows

<!-- Same behaviour as the Windows File Manager, or a deliberate difference? Cite the inventory
section (e.g. 01 §3.7) if you implemented Windows behaviour. -->

## Checklist

- [ ] `Mac/scripts/build.sh` succeeds with no new warnings
- [ ] `Mac/scripts/test.sh` and `Mac/scripts/test.sh -H` pass
- [ ] UI tests (`Mac/scripts/test.sh -u`) run, or not applicable / not possible here (say which)
- [ ] No changes to `C/`, `CPP/`, `Asm/`, `DOC/` — or a guarded patch recorded in `Mac/docs/upstream-patches.md`
- [ ] Docs and `CHANGELOG.md` updated if user-visible
- [ ] Screenshots for UI changes (no personal paths or user names visible)
