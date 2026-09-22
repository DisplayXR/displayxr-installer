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
| Per-app state (installed vs pinned) | yes | It doubles as an updater, and it makes "did that actually install?" answerable without adb. |
| Signature-mismatch dead end | reported, never performed | Android refuses to upgrade across a signing-key change. The only fix drops that app's data, so the installer names the app and stops. |
| Installed build newer than the pin | reported, skipped | Android refuses a downgrade. Offering the uninstall beats a failed install with no explanation. |

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
    ├── Net.kt                   HTTP + every typed failure the UI can show
    ├── GitHubReleases.kt        versions.json + pin -> release asset
    ├── ApkInstaller.kt          PackageInstaller sessions and their verdicts
    ├── InstallerViewModel.kt    the run: order, the browser gate, launch-once
    └── MainActivity.kt          the screen
```
