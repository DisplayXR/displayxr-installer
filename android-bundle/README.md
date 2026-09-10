# Android tablet-bundle harness

Scripts that assemble, gate and **prove** the Android tablet bundle — the zip handed to a tester
containing the vendor display services, the OpenXR runtime, the demos and the browser.

They exist because a green scripted run repeatedly failed to mean a working tablet. Every guard here
was added after a specific false result, and each one carries a comment naming the failure it
prevents. Please keep those comments when editing: they are the reason the check exists.

## Run order

| # | Script | What it establishes |
|---|---|---|
| 1 | `check-artifacts.sh <expected-file>` | Every APK matches its release digest, the runtime's CNSDK stamps are right, and the bundled vendor plug-in embeds the strings that identify its version. Runs **before** anything is installed. |
| 2 | `pad-lock.sh take <handle> <what>` | Claims the shared tablet. |
| 3 | `reset-to-virgin.sh --yes [--revert-services]` | Optional clean slate: removes every DisplayXR package, optionally reverts the vendor services to their factory builds, reboots. |
| 4 | `install-from-computer.sh` | Installs in dependency order and performs the post-install steps that installs do not do. |
| 5 | `audit-device.sh` | Reads what is *actually installed* — including the vendor core's own hash — and compares it with the bundle. Needs `adb root`. |
| 6 | `prove-3d.sh <pkg>` | The 3D pipeline comes up: the vendor core loads and the display processor is created. |
| 7 | `prove-freeform.sh <pkg>` | The app survives the recents small-window toggle and weaves 1:1 inside it. |
| 8 | `prove-dropzone.sh <pkg>` | The drop-zone geometry weaves. **Contains a manual step** — see below. |
| 9 | `prove-exit-clean.sh <pkg> [n]` | Returning to fullscreen never leaves the view squashed. |
| 10 | `prove-browser-resume.sh [url]`, `prove-browser-freeform.sh` | The browser keeps its woven output across background/resume, and weaves at the small-window size. |
| 11 | `verify-bundle.sh` | Offline consistency of the zip itself. |
| 12 | `pad-lock.sh release <handle>` | Hands the tablet back. |

## Keeping a bundle folder in sync

This directory is the canonical copy. A bundle folder on someone's disk holds a **copy** of
`scripts/`, refreshed by `sync-from-repo.sh` — copy that one file into the bundle folder once and it
keeps both itself and `scripts/` current from a local checkout.

```
./sync-from-repo.sh            # take the repo copy; writes SCRIPTS-PROVENANCE.txt
./sync-from-repo.sh --check    # report drift, write nothing, exit 1 if drifted
```

**Before zipping a bundle, run `sync-from-repo.sh --check`** — a zip built from a drifted folder
ships a harness nobody reviewed. It refuses to sync when `android-bundle/` has uncommitted changes,
and refuses to `--delete` into a directory that does not look like a bundle. `SCRIPTS-PROVENANCE.txt`
records which commit the copy came from; it is a per-sync artifact and is not tracked here.

A copy, not a symlink, and deliberately so: macOS "Compress" in Finder uses `ditto`, which stores a
symlinked directory as a ~7-byte link instead of following it, so the zip would carry no scripts and
report no error. Only `zip -r` follows it. The script header repeats this — please keep it.

## What these scripts cannot prove

- **The drop-zone drag.** Swiping up, holding and dragging a window into the release corner is not
  reproducible from `adb` — the gesture recogniser rejects synthetic input. `prove-dropzone.sh` runs
  a geometry-only analogue, reports `ANALOGUE PASS`, and prints the manual steps. A human must
  answer whether the result is 3D and follows their head.
- **Whether the picture looks right.** Frame counts and geometry are measurable; "is this doubled"
  is not. Two real defects this year passed every scripted check.
- **A tester's install path.** These scripts install over `adb`, which is not what someone tapping
  APKs in a file manager does; at least one first-launch failure is invisible here.

## Shared-tablet protocol

One driver at a time, coordinated through `/data/local/tmp/pad.lock` holding
`<handle> <ISO timestamp> <what, and for how long>`. An **empty** lock file means held-by-unknown,
never free. Remove only your own entry, with `rm` — truncating leaves exactly that ambiguous state.
`pad-lock.sh` enforces all of this.

Leave the tablet's rotation **unlocked** at rest (auto-rotate on, landscape current). Pin it only
for the duration of a run; every script restores it on exit, including on failure.

## The `expected/` files

`check-artifacts.sh` reads a plain list of `<glob> <sha256>` plus directives (`RUNTIME_STAMPS`,
`PLUGIN_EMBEDS`, `SERVICE_IMPL`). Hashes may be truncated; a prefix of 16 hex characters or more is
accepted. **Prove any new version marker discriminates**: run the gate against the *previous*
artifact and require it to fail. A marker present in both versions passed a wrong build once.
