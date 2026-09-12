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
| 2 | `pad-lock.sh take <handle> <what>` | Claims the shared tablet. Prefer `pad-run.sh` (below), which claims it, runs your command, and hands it back. |
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

## `lib.sh`

Helpers shared by more than one script live in `lib.sh`, sourced as `. "$(dirname "$0")/lib.sh"`:
`restore_rotation`, `task_sz`, `wait_picker_done`, `open_mediaplayer_file`, `ver`, `require_pad`. It exists because
`restore_rotation` had been copied into seven scripts and had **already drifted into three
variants**, two of which silently skipped the check that the pad's rotation was handed back.

A lint step enforces it both ways: no script may redefine a name `lib.sh` defines, and any script
that calls one must source it — the second mistake otherwise surfaces only at runtime on the pad.
It also `bash -n`s every script.

So the scripts are **not standalone any more**: `lib.sh` must sit beside them. The bundle ships the
whole `scripts/` directory and `sync-from-repo.sh` keeps it complete, so this only bites if someone
copies a single script out on its own.

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

**The lock is now enforced, not merely advised.** Every script that changes device state calls
`require_pad` first and exits 1 if another handle holds the lock. Export `PAD_HANDLE=<your handle>`
when you hold it so your own runs pass. This exists because advice was not enough: on 2026-09-10 a
run began three seconds after another session took the lock — `pad-lock.sh` refused to hand it over,
but the caller had not checked its exit status, so the run proceeded anyway and force-stopped that
session's app, cleared its recents and dropped its rotation pin mid-measurement. `audit-device.sh` is
read-only and deliberately not gated; `install-on-tablet.sh` runs on-device with no `adb` and cannot
check.

### `pad-run.sh` — for anything that is not one of these scripts

```
PAD_RUN_OUT=<your scratch dir> ./scripts/pad-run.sh <handle> "<purpose, duration>" -- <command...>
PAD_RUN_OUT=/path/to/scratch  ./scripts/pad-run.sh mac/media3 "#71 phase 1, ~10 min" -- ./scripts/prove-3d.sh
```

Pass `PAD_RUN_OUT`. It defaults to a `mktemp -d` under `/tmp`, which is the one place the
after-the-fact evidence should *not* live — it is the only record of a contaminated window once
`logcat` has rolled.

**Pass `PAD_SERIAL` too, and say which device a measurement came from.** A lock lives on the
device, so it is inherently that device's — but nothing stopped a run from driving a *different*
device than you believed. On 2026-09-12 the USB cable moved from the tablet to the phone
mid-session; three sessions then read a lock none of them had written and spent an hour on
push-and-clock-drift theories before anyone checked `adb devices`. `ro.product.model` does not
save you: it reads the same on more than one of these units, so `ro.product.name` or the serial
is the discriminator. `pad-run.sh` refuses a `PAD_SERIAL` that is not attached, refuses when
several devices are attached and none is named, and prints the serial it is driving so the
transcript carries attribution. No serials are written down here — this is a public repo, and
`adb devices -l` prints yours.

`require_pad` only protects scripts that call it, and **it happened again on 2026-09-12** — a second
session drove the pad under a live measurement, having gated *writing its own lock* and then run the
device commands regardless. Neither collision was a `prove-*` script; both were ad-hoc `adb`
one-liners, which a guard inside the harness cannot see. `pad-run.sh` can, because it owns the
`exec`: nothing runs until the check passes. It refuses with **exit 75** (`EX_TEMPFAIL`, so a waiting
caller can tell "retry later" from "broken"), takes the lock, runs the command, restores the resting
rotation however the command exited, and releases the lock — only if it took it, so nesting cannot
strand it. Rotation is restored on the same condition: `restore_rotation` *unpins*, so an inner
wrapper restoring it would drop an outer run's deliberate landscape pin mid-measurement. Put ad-hoc pad commands behind it; wrapping a `prove-*` script adds the lock handling and
the audit trail below on top of that script's own `require_pad`.

**It also snapshots who else used the device, and prints the delta on exit.** This is the half a lock
cannot give you: a lock prevents a collision, it does not let you *audit* one afterwards. `logcat`
rolls within minutes on this pad, so by the time you learn a peer touched it, the line naming what
they did is gone — which on 2026-09-12 left a published measurement resting on file mtimes to infer
ordering, and it had to be withdrawn. `dumpsys usagestats` keeps per-package `ACTIVITY_RESUMED` rows
with wall-clock times long after `logcat` drops them, so the delta can still name a foreign launch
after the fact. Any reading that keys on a client connect/disconnect — `cgroup.freeze`, `oom adj`,
service lifetime — is invertible by **one** foreign app launch, so "my run looked clean" is not
evidence that it was.

One driver at a time, coordinated through `/data/local/tmp/pad.lock` holding
`<handle> <ISO timestamp> <what, and for how long>`. An **empty** lock file means held-by-unknown,
never free. Remove only your own entry, with `rm` — truncating leaves exactly that ambiguous state.
`pad-lock.sh` enforces all of this.

**That one line is the format. Never hand-write the lock.** `pad-lock.sh take` is the only writer,
and it is the only thing that claims the lock atomically — it creates with `set -C`, so two sessions
racing cannot both succeed, and it reads the lock back and refuses unless the lock is actually
yours. A hand-written `echo > pad.lock` does neither, and on 2026-09-12 one destroyed a claim made
17 seconds earlier; the session that did it had not read the file first, because `pad-lock.sh` was
not on its `PATH` and it did not go looking. The same session also wrote a four-line
`holder=`/`taken=`/`task=` form, which every reader mis-parsed as a handle three lines long — that
left the *holder* unable to release its own lock and unable to pass its own `require_pad`, with
nobody else permitted to clear the entry. Readers tolerate that shape (`pad_holder` in `lib.sh`) so a
stale one cannot strand the pad, but it is not a second supported format.

**It is not on your `PATH`, and that is how the clobber happened.** These scripts live in this repo,
while the work usually happens in a sibling checkout, so call it by path rather than improvising:

```
"$(git -C <your checkout> rev-parse --show-toplevel)/../displayxr-installer/android-bundle/scripts/pad-lock.sh" status
```

or `alias padlock=.../android-bundle/scripts/pad-lock.sh` for the session. Reaching for `echo` because
the tool is two directories away is the failure this paragraph exists to prevent.

Leave the tablet's rotation **unlocked** at rest (auto-rotate on, landscape current). Pin it only
for the duration of a run; every script restores it on exit, including on failure.

## The `expected/` files

`check-artifacts.sh` reads a plain list of `<glob> <sha256>` plus directives (`RUNTIME_STAMPS`,
`PLUGIN_EMBEDS`, `SERVICE_IMPL`). Hashes may be truncated; a prefix of 16 hex characters or more is
accepted. **Prove any new version marker discriminates**: run the gate against the *previous*
artifact and require it to fail. A marker present in both versions passed a wrong build once.
