# `DisplayXR-Installer-<ver>.apk` — the single Android installer

The Android analogue of `DisplayXRBundle-*.exe`. One artifact the owner of a tablet taps; it
installs the pinned DisplayXR stack and then performs the post-install steps that installing
APKs does not do. Tracks [`displayxr-installer#62`](https://github.com/DisplayXR/displayxr-installer/issues/62).

Android offers no NSIS equivalent — an App Bundle or a set of split APKs describes exactly one
app, and `adb install-multiple` installs splits of one app, not a set of apps. So the only way to
get "one tappable thing" is an app that drives `PackageInstaller` itself.

## Why it downloads instead of embedding

It reads `versions.json` from `DisplayXR/displayxr-installer@main` — the same mirrored pin matrix
every other install path uses — and fetches each pinned asset from its GitHub release. ~7.5 MB
instead of ~75 MB, and, more importantly, it **cannot ship a stale matched pair**: the pins it
installs are the pins that are published at the moment it runs.

Asset resolution is the same mapping as `displayxr-runtime/scripts/install-android-bundle.sh`
(`--links`): pin field → repo → release asset, resolved by reading the release rather than
templating a URL. `Catalog.kt` is that table; if the shell script's mapping changes, change this
with it. **Two naming schemes is the failure this avoids** — the reason `--links` generates its
list instead of letting anyone hand-write one.

One deliberate divergence: the shell script falls back to an older release when a pin publishes no
Android APK. This app does not. Quietly installing an unpinned browser is exactly the state the
gate below exists to prevent, so a missing asset is reported as a missing asset.

## What it automates

Every item here is from [`../android-bundle/INSTALL.md`](../android-bundle/INSTALL.md) § *After
installing: five things that are not APKs*, with the failure each one prevents. Those failures are
why the step exists — please keep them attached to the code.

| Step | Automated? | The failure it prevents |
|---|---|---|
| Install in dependency order, runtime first | yes | An app installed before the runtime just finds no runtime. |
| **Open the runtime once** | **yes**, at the end of the run | Uninstalling deregisters the `OpenXRRuntimeBroker` ContentProvider and `FLAG_STOPPED` keeps it unresolvable; every OpenXR app then dies at instance creation with `XR_ERROR_RUNTIME_UNAVAILABLE`. Nothing clears it at boot. **The most common virgin-install failure.** |
| "Display over other apps" for the runtime | **deep-link only** | `SYSTEM_ALERT_WINDOW` is an app-op. No ordinary app can grant it to another package. Without it see-through apps render on a **black background** while 3D and weaving keep working, so it reads as a content bug. |
| Browser ↔ runtime pairing | yes, as a refusal | A browser paired with a runtime that is not its pinned match renders **all 3D content black**, with no error on screen, while every other app keeps weaving. |
| Per-app state (installed vs pinned) | yes, **where the version can be read** | It doubles as an updater — but see *Versions that cannot be read* below: a number that means something else is not a weaker signal, it is the wrong one. |
| A confirmation dialog that never appears | 20 s timeout → RETRY, 5 min → move on | On the K68 the first run sat on "confirm on screen" for an hour with nothing on screen to confirm. |
| Waiting for an unlocked screen before opening the runtime | yes | Launching an app behind the keyguard crashes Model Viewer and Gaussian Splat ([displayxr-runtime#1358](https://github.com/DisplayXR/displayxr-runtime/issues/1358)), and a long run ends unattended. |
| Signature-mismatch dead end | reported, never performed | Android refuses to upgrade across a signing-key change. The only fix drops that app's data, so the installer names the app and the Settings path, and stops. |
| Installed build newer than the pin | reported, skipped | Android refuses a downgrade. No uninstall is offered — see below. |

## What it does NOT do

- **It is not silent.** Android confirms **each** package unless the installer is a device owner or
  a privileged system app, and this is neither. One tap here is still N confirmations. The app asks
  for `USER_ACTION_NOT_REQUIRED`, which Android honours only for updating a package this installer
  itself installed — so a second run is quieter than the first, and that is all.
- **The vendor display services are out of scope.** They come from a private vendor repo and install
  as built-in-app updates only because they carry the OEM's signing key. This installer cannot fetch
  them and does not pretend it can.
- **It cannot grant CAMERA** to Gaussian Splat or Avatar. Accept the prompt on first launch.
- **It cannot unlock the tablet.** After a reboot, unlock before opening any app —
  launching a demo at the lockscreen crashes Model Viewer and Gaussian Splat
  ([displayxr-runtime#1358](https://github.com/DisplayXR/displayxr-runtime/issues/1358)).
- **It must never be proposed for Google Play.** Play forbids apps that install other apps.
  Irrelevant here — this is sideloaded, and the OEM App Center is the store-shaped channel — but the
  constraint is real.
- **It cannot read another app's overlay app-op.** That needs a privileged permission this app does
  not hold and should not ask for, so the UI says "look at the switch" rather than guessing.

## Versions that cannot be read, and why no uninstall button exists

`versionName` is the DisplayXR release version for the runtime and every demo. It is **not** for the
browser: `org.chromium.chrome` reports the **Chromium** version (`154.0.8037.17`), and several
DisplayXR browser releases share one Chromium base, so there is no comparison to make from it
(displayxr-browser-pvt#158).

The first build of this installer compared `v1.0.4` against `154.0.8037.17`, reached the only
conclusion that comparison can ever reach — "installed is newer" — and offered to **uninstall the
tester's browser, dropping its profile**, to resolve a conflict that did not exist. A tester
following the UI would have lost their profile and landed on an older build.

The rule that came out of it, and the one worth keeping: **a destructive action is never offered on
the strength of a comparison the code cannot make.** Concretely:

- the browser row shows `installed: unknown (Chromium 154.0.8037.17)`, never a bare number that
  invites a comparison;
- it is offered as an install/update, and can never reach "newer";
- there is **no uninstall button anywhere in the app**. Where an uninstall is genuinely the only way
  forward (a signing-key change), the row names the app and the Settings path and stops. That is
  also the safer choice on this hardware: on the K68's OEM build, `ACTION_DELETE` opened
  `UninstallerActivity` and returned within the same second, twice, without uninstalling anything —
  so a button there would have been a destructive-looking control that did nothing.

It is forward-compatible rather than permanent. When the browser APK carries a
`com.displayxr.BROWSER_VERSION` manifest `<meta-data>` (displayxr-browser-pvt#159 adds it), the row
reads it with `getApplicationInfo(GET_META_DATA)` and compares like for like, with no change here.
That is the same shape as `android-bundle/scripts/audit-device.sh` reading the CNSDK stamps: a real
signal from a stamp, not an unrelated number pressed into service.

## When the confirmation dialog does not appear

Android confirms each package separately, and on the K68 that confirmation **stopped arriving** after
the first package: the runtime installed cleanly, the next row moved to "Installing — confirm on
screen", and no dialog ever appeared. It sat there an hour. `usagestats` shows the runtime's own
`PackageInstallerActivity` opening and closing normally and then no second one, ever. Force-stopping
the app and re-tapping drove the remaining five packages straight through, so it was neither a bad
session nor a bad asset.

Two candidates are in the log and the cause is not settled: the OEM's `CpuFreezerManagerServiceV2`
freezing this app (`mFreezeType=3`, a freeze check every ~30 s), and a `STATUS_PENDING_USER_ACTION`
intent started while the app was not foreground and dropped as a background activity start. What was
indefensible either way is the UI contract — it claimed there was something on screen to confirm
when there was not, and offered no way out. So, cause-independently:

- **`ConfirmationWatchdog`** gives "waiting for the owner" a deadline: **20 s** with no answer flips
  the row to *"Android's confirmation dialog has not appeared"* with a visible **RETRY** that
  re-raises the stored confirmation intent; **5 minutes** in total, retries included, abandons the
  session and lets the run continue to the next package. An hour on one row is now impossible.
- The confirmation intent is started **from the resumed activity** whenever there is one, because a
  background activity start can be dropped silently. The application-context fallback always carries
  `FLAG_ACTIVITY_NEW_TASK`, and a start that throws is reported rather than assumed.
- A **stalled** confirmation is re-raised automatically when the app regains the foreground — and
  only a stalled one: re-raising an in-flight confirmation would fire every time the dialog itself
  pauses and resumes this activity, which is a loop, not a recovery.
- The window holds **`FLAG_KEEP_SCREEN_ON`** for the duration of a run, which keeps the app visible
  and foreground — both the legal footing for those activity starts and the simplest defence against
  a freezer that targets apps which are not.

No foreground service. It would need `FOREGROUND_SERVICE_DATA_SYNC`, a notification channel and a
runtime notification permission on API 33+, none of which can be validated from a build — and the
observed symptom is addressed by staying foreground. If the freezer turns out to be the cause and
`KEEP_SCREEN_ON` is not enough, that is the next step, not the first.

The state machine is pure Kotlin with an injected clock precisely so it is covered by JVM tests:
`ConfirmationWatchdogTest` drives the soft timeout, the retry, the hard cap despite repeated retries,
and the foreground re-raise rule.

## The lockscreen

A run ends by opening the runtime once, and after a large download it ends unattended. Launching an
app behind the keyguard is the documented crash path for Model Viewer and Gaussian Splat
(displayxr-runtime#1358) — the tablet was in fact on the lockscreen when the first device run
started. So `KeyguardManager.isKeyguardLocked()` is checked twice: a run will not **start** into a
locked screen, and the launch-once step **waits** for an unlocked one (polling every 2 s for up to
10 minutes, with an "Open the runtime once" button as the manual handle). Polling beats a dynamic
`ACTION_USER_PRESENT` receiver here: the receiver dies with the process, and this is only ever armed
while the app is alive and foreground anyway.

## The browser gate

The browser is **opt-in** (~326 MB), mirroring the desktop bundle's `--with browser` rule, and it is
refused unless the runtime **actually installed on the tablet** is the pinned runtime, exactly.

Exact, not "close enough": a locally built runtime reports something like `2.20.1-14-gabc1234`, and
that is precisely the configuration that must not be treated as the pinned runtime — a shared dev
pad with a dev-build runtime is how this breaks in practice. The refusal names both versions and
says what happens otherwise: all 3D content in the browser renders black, with no error on screen,
while the demos keep weaving perfectly, so people reinstall the wrong thing.

## Failure states

Nothing is allowed to end as a spinner. Each of these is a line of text on the row it belongs to,
or, for the one failure that stops everything, a card at the top with a Retry:

| Situation | What you see |
|---|---|
| No network / DNS | "No network. Could not reach raw.githubusercontent.com — connect this tablet to Wi-Fi and retry." |
| `versions.json` unreadable | The whole screen shows why. Nothing is installable without the pin matrix. |
| A pin with no Android asset | That row says so and names the tag. Nothing older is substituted. |
| A pin naming a release that does not exist | That row says so and names the repo. |
| GitHub API rate limit (60/h, anonymous) | That row says so and gives the minutes until reset. |
| Download dies mid-way | "Download of X ended after N of M bytes." The partial file is deleted, not installed. |
| Out of space | Reported before the stream starts, from the session's declared size. |
| Owner cancels a confirmation | "Cancelled at the Android confirmation dialog. Nothing was changed." |
| The confirmation never appears | After 20 s: "Android's confirmation dialog has not appeared" + a RETRY button. After 5 min: the session is abandoned, the row says so, and the run continues. |
| The tablet is locked | The run refuses to start, and the launch-once step waits for an unlock instead of launching into the keyguard. |
| The browser's version cannot be read | `installed: unknown (Chromium …)`, offered as an install. Never "newer", and never an uninstall. |
| The runtime leg fails | The run stops there and says why — an app installed without a runtime only fails later, at startup. |

## Building

Local, from a checkout (needs a JDK 17+ and an Android SDK; `ANDROID_HOME` must point at it):

```bash
cd android-installer
./gradlew :app:testDebugUnitTest :app:assembleDebug
# -> app/build/outputs/apk/debug/app-debug.apk
```

CI: `.github/workflows/build-android-installer.yml` runs the same two tasks on every PR that touches
this directory, and names the artifact `DisplayXR-Installer-<installerVersionName>.apk` from
`gradle.properties` — one property drives both the version inside the APK and the file name outside
it. Dispatch it with a `release_tag` to attach the APK to an existing `android-bundle-<date>`
release.

**Debug-signed, and the consequence is real:** this repo signs nothing, and an *unsigned* release APK
cannot be installed at all, so CI ships the debug variant. Each CI run signs with that runner's
throwaway debug key, so **upgrading the installer app itself in place fails** with
`INSTALL_FAILED_UPDATE_INCOMPATIBLE` — uninstall the old installer first. This affects only the
installer; everything it installs is release-signed by its own repo and upgrades normally.

## Minimum SDK

`minSdk 31`, and it is a requirement rather than a default: the two tablets this exists for are
Android 13 (K68 / NP02J) and Android 12 (Lume Pad 2). Raising it past 31 silently drops the
Lume Pad 2.

## Layout

```
android-installer/
├── gradle.properties            installerVersionName / installerVersionCode
└── app/src/main/java/com/displayxr/installer/
    ├── Catalog.kt               the component table — mirrors install-android-bundle.sh
    ├── UiModel.kt               row/phase model + plannedStatus (pure, JVM-tested)
    ├── ConfirmationWatchdog.kt  the pending-user-action deadline (pure, JVM-tested)
    ├── Net.kt                   HTTP + every typed failure the UI can show
    ├── GitHubReleases.kt        versions.json + pin -> release asset
    ├── ApkInstaller.kt          PackageInstaller sessions and their verdicts
    ├── InstallerViewModel.kt    the run: order, the browser gate, launch-once, keyguard
    └── MainActivity.kt          the screen
```
