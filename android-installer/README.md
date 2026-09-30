# Install DisplayXR on a Leia tablet (Lume Pad 2 / Nubia Pad 3D / Lume Phone)

You need only the tablet and Wi-Fi — no computer.

1. **On the tablet**, open the [latest DisplayXR release](https://github.com/DisplayXR/displayxr-installer/releases/latest)
   and download **`DisplayXR-Installer-<version>.apk`** from its *Assets*.
2. Open the downloaded file (the browser's download notification, or *Files → Downloads*). Android
   asks to **allow installs from this source** — allow it for the browser / file manager, go back,
   tap **Install**.
3. Open **DisplayXR Installer**. Tap **Allow this app to install apps**, switch it on, go back.
4. Tick **Also install DisplayXR Browser** if you want it (large download, ~330 MB).
5. Tap **INSTALL / UPDATE**. It first updates the tablet's **display services** — they appear as
   *"an update to this built-in application"*, which is expected — then installs the DisplayXR
   runtime and apps.
6. Android confirms **each** package: tap **Install** on every prompt (about 9). If Android shows an
   *"App installed — DONE / OPEN"* screen, tap **DONE**.
7. When the DisplayXR runtime opens at the end and asks to **allow notifications**, tap **Allow**.
8. **REBOOT the tablet** when the red card says so (hold power → *Restart*). Not optional: without it
   the screen can stay flat 2D while every app reports 3D.
9. After the reboot, **unlock** the tablet. If a **USB mode** chooser pops up (Nubia Pad 3D), dismiss it.
10. Open **DisplayXR Installer** again → *Display over other apps* → **Open the setting** → switch it
    **on** for DisplayXR. Without it, see-through apps show a black background.

If a red **"Display services update needed"** card appears, the installer could not download the
display services: check the Wi-Fi and tap **Check again**. Until they are updated **3D will not work
correctly** (content stays 2D, parallax is wrong, apps can freeze). Coming from installer **0.4.1 or
older** (debug-signed): uninstall the old *DisplayXR Installer* first, once — Android says *"App not
installed"* otherwise (see *Signing*); the DisplayXR apps are not affected. From 0.4.2 on, the
installer updates in place.

The same instructions head every bundle release's notes (`.github/release-notes/bundle.md`).

---

# `DisplayXR-Installer-<ver>.apk` — the single Android installer

The Android analogue of `DisplayXRBundle-*.exe`. One artifact the owner of a tablet taps; it
installs the pinned DisplayXR stack and then performs the post-install steps that installing
APKs does not do. Tracks [`displayxr-installer#62`](https://github.com/DisplayXR/displayxr-installer/issues/62).

Android offers no NSIS equivalent — an App Bundle or a set of split APKs describes exactly one
app, and `adb install-multiple` installs splits of one app, not a set of apps. So the only way to
get "one tappable thing" is an app that drives `PackageInstaller` itself.

## The display services

On a 3D tablet the first two rows are the vendor **display services** — device-service
(`com.leialoft.display.config`, which carries the CNSDK core) and head tracking
(`com.leia.headtrackingservice`). They are not optional: on the **factory** services DisplayXR
installs and runs, but it is unusable — measured on an NP02J with factory 0.8.29 / 0.8.20, content
stays 2D, vertical parallax is inverted and apps freeze, because the factory core lacks
`leia_core_get_lookaround_eyes` / `get_non_predicted_eyes` and the #206 horizon sink. The Lume Pad 2
factory core has the same gap. Every tablet must be on the pinned CNSDK (`versions.json` →
`cnsdk_services`).

**Which devices.** The rows exist only when device-service is installed **as a system app** — it
shipped in the OEM image (`FLAG_SYSTEM`, which an update keeps). Anything else — an ordinary phone,
a sideloaded copy of the package — gets no service rows and nothing is fetched. The certificates are
the same on the NP02J/K68, the Lume Pad 2 and the Lume Phone (measured with apksigner).

**Where they come from.** `https://updates.displayxr.org/services/cnsdk/<tag>/manifest.json`, the
tag being the `cnsdk_services` pin — the manifest can never name a different release. It lists, per
APK: package, versionName, versionCode, sha256, size and signing-certificate SHA-256; plus the licence
notices. `publish-cnsdk-services.yml` puts it there — see *Publishing the display services* below.
There is no token in the app and none is needed: the host is public.

**What is trusted.** Not the host (the same stance as the browser feed on that host). The app
refuses, with a sentence on the row:

- a manifest whose `cnsdk_tag` is not the pin, whose versionName is not the tag, that lists any other
  package or only one of the two, or that declares a signer other than the one **compiled into the
  app** (`DisplayServices.PINNED_SIGNERS`: device-service `dbc2792f…811c`, head tracking
  `113ec052…5096`) — before a byte is downloaded;
- a download whose size or sha256 is not the manifest's (deleted, never handed to Android);
- an archive whose package, versionCode or **current signing certificate** is not the manifest's
  and the pin's. The certificate is read **and verified by the app itself** from the APK Signing
  Block (`ApkSignatureReader`: v3.1 → v3 → v2, the signer's signature over its signed data and the
  whole-file content digest, so a forged or modified file is refused), and cross-checked against
  `getPackageArchiveInfo`; if the two disagree, or the block does not verify, it is refused. Android's
  answer is not enough on its own: the initial Android 13 framework (the NP02J/K68's) collects an
  archive's certificates only for the deprecated `GET_SIGNATURES` flag, so 0.4.0, which asked with
  `GET_SIGNING_CERTIFICATES`, got no certificate for the v2-only vendor services and refused them.

And Android itself refuses an update to a built-in app not signed with that app's key. The pin in
the app and the pin the publisher enforces (`scripts/service-signers.tsv`) are one table in two
places; `DisplayServicesTest` fails if they differ.

**Order and pairing.** device-service, then head tracking, then the runtime — the order Routes A/B/C
use, device-service first because it carries the core. If device-service fails, head tracking is
**not** installed over the old core: the two are one vendor release, and a head-tracking update alone
"changes nothing about 3D prediction" while looking done.

**Installed vs pinned** is decided on `versionCode`, which is what Android's downgrade rule uses and
what the vendor sets meaningfully (`290010069` = device-service 0.10.69). "Newer" — the verdict that
skips a package — is claimed only when Android itself would refuse the install; a `versionName` never
decides it (`servicePlannedStatus`, JVM-tested).

**When they cannot be updated.** If the manifest is unreachable, both rows stay on screen: *"Display
services update needed — could not download it (<why>). Check the tablet's connection, then tap Check
again."* (unless the installed build already matches the pin, in which case there is nothing to
fetch). Whenever the installed services are older than the pin and this run cannot fix it — and after
**any** run that ends in that state — a red card says **3D will not work correctly until the display
services are updated**, and the run's summary starts with *NOT READY*. Read back from the device, not
from the run's bookkeeping, so a run that installed everything else never reads as done on a factory
core. Staleness uses versionCode when the manifest is known; without it, the versionName is compared
with the tag (for these packages it is the CNSDK release, e.g. 0.8.29 vs 0.10.69). That weaker signal
is acceptable only because this verdict produces a warning and never skips, removes or downgrades
anything.

**The reboot.** When a service actually changed, a red card stays at the top: *Reboot the tablet now
— it is not optional.* Skipping it is invisible — the lens-controller HAL can be left not answering,
every app weaves and tracks, everything reports 3D, and the glass stays 2D
(`../android-bundle/INSTALL.md`, "Reboot. It is not optional"). An app cannot reboot a tablet, so it
tells the owner, and keeps telling them (across relaunches) until the tablet has actually rebooted.

**Licences.** The services statically link libzmq (modified LGPLv3, whose static-link exception still
requires the notice to accompany the binary), Eigen (MPL-2.0) and Apache-2.0 components. The four
notices (`LICENSE.txt`, `LICENSE-3RD-PARTY.txt`, `ZMQ.AUTHORS.txt`, `SIMDJSON.AUTHORS.txt`) are
published beside the APKs — the publisher refuses to publish without them — and readable in-app via
*Licences for the display services*.

### Publishing the display services

`.github/workflows/publish-cnsdk-services.yml` (workflow_dispatch with an optional tag; also runs on
every push to `main` that touches `versions.json`, and exits in seconds when the host already serves
the pin):

1. downloads the two APKs + the licence notices from the private vendor release with
   `LEIALOFT_GITHUB_TOKEN`;
2. lays them out with `scripts/make-services-manifest.sh`, which reads every manifest value from the
   files (aapt2, apksigner, sha256) and **refuses** a wrong package, a versionName that is not the tag,
   two services disagreeing on the CNSDK build string, more than one signer, a certificate that is not
   in `scripts/service-signers.tsv`, or a missing licence notice;
3. uploads the result to a **draft** release `cnsdk-services-<tag>` of `DisplayXR/displayxr-browser`
   (with a publish-bot token) — a byte store invisible to the public;
4. sends `repository_dispatch: cnsdk-services` to that repo, whose `pages.yml` copies every
   `cnsdk-services-*` draft into the site at `/services/cnsdk/<tag>/` on **every** deploy (feed
   promotions included), re-verifying each file against the manifest;
5. is green only once `updates.displayxr.org` serves the manifest byte for byte and every file at the
   recorded size and sha256.

Why that shape: `updates.displayxr.org` is the GitHub Pages site of the public `displayxr-browser`
repo (it also serves the browser's update feed). Pages deploys an artifact, so ~60 MB of APKs per pin
never enter git — but each deploy replaces the whole site, so the bytes must be findable at every
deploy; a draft release is durable, private and readable by that repo's own workflow token. Nothing
links to `/services/`, and Pages has no directory listing.

### The retired `cnsdk` flavor

Until 0.4.0 there was a second build, `DisplayXR-Installer-<ver>-with-cnsdk.apk`
(`com.displayxr.installer.cnsdk`), that **carried** the service APKs inside itself and therefore
could never go on a public release — so the public APK could not fix a factory tablet. It is removed
(the flavor, its staging script, and its packaging in the tablet bundle). The rule it forced stays:
the public APK must carry no vendor bytes, and `build-android-installer.yml`, `build-android-bundle.yml`
and `publish-bundle.yml` each check that from the file (no `assets/cnsdk/`, no nested `.apk`, no
`cnsdk` in the name).

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
- **It cannot reboot the tablet.** It tells the owner to, when the display services changed.
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
| Display services host unreachable (3D tablet) | Both service rows: "Display services update needed — could not download it (<why>)…"; a red card: **3D will not work correctly until the display services are updated**; the rest of the stack can still be installed. |
| Services manifest refused (wrong tag, package, signer…) | The same rows and card, with the refusal as the reason. Nothing is downloaded. |
| A service download fails size / sha256 / certificate | That row: why, the file deleted, **Retry download + install**. If it was device-service, head tracking is not installed over the old core. |
| A run ends with services still older than the pin | The summary starts *NOT READY: 3D will not work correctly…* and the red card stays — never a plain success. |
| `versions.json` unreadable | The whole screen shows why. Nothing is installable without the pin matrix. |
| A pin with no Android asset | That row says so and names the tag. Nothing older is substituted. |
| A pin naming a release that does not exist | That row says so and names the repo. |
| GitHub API rate limit (60/h, anonymous) | That row says so and gives the minutes until reset. |
| Download dies mid-way | Resumed automatically with `Range:` from the bytes already on disk (6 attempts, backoff 2→30 s), with `Accept-Encoding: identity` and the release API's size as the length to hold the file to. Only after the last attempt: "Download of X ended after N of M bytes", the partial file deleted, and a **Retry download + install** button on the row. (NP02J: the browser once stopped at 1,686,822 of "-1" bytes — gzip had hidden the length — and the only way back was relaunching the app.) |
| Android's "App installed — DONE / OPEN" screen stays on top (built-in-app updates) | The installer re-launches itself on top after every package and does not open the next session until it is really in front; if Android refuses that, the row says "tap DONE (not OPEN) to continue". Raising the next confirmation under that screen is how a confirmation goes missing. |
| Any failed row, after a run | A per-row **Retry** runs just that component again. |
| Out of space | Reported before the stream starts, from the session's declared size. |
| Owner cancels a confirmation | "Cancelled at the Android confirmation dialog. Nothing was changed." |
| The confirmation never appears | After 20 s: "Android's confirmation dialog has not appeared" + a RETRY button. After 5 min: the session is abandoned, the row says so, and the run continues. |
| The tablet is locked | The run refuses to start, and the launch-once step waits for an unlock instead of launching into the keyguard. |
| Relaunching the app | The browser opt-in is remembered, and the red reboot card stays until the tablet has **actually** rebooted (recorded against `Settings.Global.BOOT_COUNT`, boot time as a fallback). On the NP02J both reset on relaunch: "Nothing to install" with the browser missing, and no reboot reminder on an unrebooted tablet. |
| The browser's version cannot be read | `installed: unknown (Chromium …)`, offered as an install. Never "newer", and never an uninstall. |
| The runtime leg fails | The run stops there and says why — an app installed without a runtime only fails later, at startup. |

## Building

Local, from a checkout (needs a JDK 17+ and an Android SDK; `ANDROID_HOME` must point at it):

```bash
cd android-installer
./gradlew :app:testDebugUnitTest :app:assembleRelease
# -> app/build/outputs/apk/release/app-release.apk  (debug-key signed unless the release key is set; see Signing)
```

Lay out the services for the host from a local copy of the vendor release (what the publishing
workflow runs; needs aapt2 + apksigner from the Android build-tools):

```bash
scripts/make-services-manifest.sh --tag v0.10.69 \
    --apks <dir with device-service-release-*.apk + headTracking-service-release-*.apk> \
    --licenses <dir with the four licence files> --out /tmp/services
```

CI:

- `.github/workflows/build-android-installer.yml` runs on every PR that touches this directory: the
  unit tests (incl. the certificate-pin agreement), the release APK, the release-key pin check (see
  *Signing*), and the no-vendor-bytes check. It names
  the artifact `DisplayXR-Installer-<installerVersionName>.apk` from `gradle.properties` — one
  property drives both the version inside the APK and the file name outside it. Dispatch it with a
  `release_tag` to attach the APK to an existing release.
- `publish-bundle.yml` calls it (`workflow_call`) and attaches the APK + `.sha256` to **every**
  `vX.Y.Z` bundle release, after re-checking the bytes carry nothing embedded; the release notes open
  with the tablet instructions from `.github/release-notes/bundle.md`.
- `build-android-bundle.yml` builds the same APK and puts it at the top of the tablet-bundle folder
  (INSTALL.md Route D).
- `publish-cnsdk-services.yml` publishes the display services to the host (above).

## Signing

**One release key, forever.** Android updates an installed app only from an APK signed with the same
key, so every published `DisplayXR-Installer-<ver>.apk` from **0.4.2** on is signed with the one
DisplayXR Installer key:

| | |
|---|---|
| Certificate | `CN=DisplayXR Installer, O=DisplayXR`, RSA 4096, SHA256withRSA, valid 2026-09-30 → 2126-09-06 |
| Certificate SHA-256 (the pin) | `7df5e3233c76abf9544311268e76d57e1240c83805a5fd33ac91a4ab5371f8ce` — [`release-signing-cert.sha256`](release-signing-cert.sha256) |
| Scheme | APK Signature Scheme v2 only, the shape every DisplayXR APK ships |
| Where the key is | GitHub environment **`android-installer-release`** on this repo (deployment branch: `main` only): `ANDROID_INSTALLER_KEYSTORE_B64`, `…_KEYSTORE_PASSWORD`, `…_KEY_ALIAS`, `…_KEY_PASSWORD`. An offline backup is held by the repo owner (outside any repo). |

How it is enforced:

- `app/build.gradle.kts` signs the **release** variant with the key when `ANDROID_INSTALLER_KEYSTORE_FILE`
  (+ the password/alias variables) is set, and with the **debug** key otherwise — so a fork's PR or a
  local build still compiles, tests and installs.
- CI always builds `assembleRelease`. The key is decoded only in runs on `main` (the environment's
  branch policy refuses every other ref, even from a workflow edited on a branch).
- [`scripts/verify-release-signature.sh`](scripts/verify-release-signature.sh) `<apk>` passes only an
  APK whose single signer's certificate equals the pin (plus a v2/v3 signature and the right package).
  `build-android-installer.yml` runs it on every build — required when a release depends on it — and
  proves on every run that it **refuses** the same APK re-signed with a throwaway key.
  `publish-bundle.yml` requires it in the build job **and** re-runs it on the downloaded bytes right
  before the release is created; `build-android-bundle.yml` requires it when `publish` is on. A
  debug-signed APK therefore fails the release, never a tablet. Debug-signed CI artifacts are named
  `…-DEBUGKEY.apk`.

**Crossing from 0.4.1 or older is the one exception.** Those builds were signed with each CI runner's
throwaway debug key; Android cannot update across a key change and no app can fix that for itself.
The upgrade is one-time: uninstall the old *DisplayXR Installer*, install 0.4.2. The apps it installed
are not affected (they are release-signed by their own repos). The release notes say so.

**Local release-signed build** (needs the keystore, which is never committed — `*.p12`/`*.jks` are
gitignored):

```bash
export ANDROID_INSTALLER_KEYSTORE_FILE=/path/to/displayxr-installer-release.p12
export ANDROID_INSTALLER_KEYSTORE_PASSWORD=… ANDROID_INSTALLER_KEY_PASSWORD=… ANDROID_INSTALLER_KEY_ALIAS=dxr-installer
./gradlew :app:assembleRelease
scripts/verify-release-signature.sh app/build/outputs/apk/release/app-release.apk
```

**If the key is lost**, every installed copy is stranded: each later installer is a different app to
the tablet. Keep the backup. **If it leaks**, do not simply swap keys (that strands every copy the same
way): rotate with an APK Signature Scheme v3 lineage (`apksigner rotate`, then sign with `--lineage`
and v3 on). Tablets (API ≥ 28; all supported ones are 31+) accept the new key as an update of a copy
signed with the old one, even though that copy was v2-only. Then change the pin to the new certificate
in the same PR.

Minification stays off (see `app/build.gradle.kts`): R8 cannot be validated without a tablet run.

Never commit a keystore, not even a "debug" one: an installer holding `REQUEST_INSTALL_PACKAGES`
signed with a public key can be updated by anyone to install anything.

## Minimum SDK

`minSdk 31`, and it is a requirement rather than a default: the two tablets this exists for are
Android 13 (K68 / NP02J) and Android 12 (Lume Pad 2). Raising it past 31 silently drops the
Lume Pad 2.

## Layout

```
android-installer/
├── gradle.properties                 installerVersionName / installerVersionCode
├── scripts/make-services-manifest.sh lays out + verifies the display services for the host
├── scripts/service-signers.tsv       the vendor certificate pin (== DisplayServices.PINNED_SIGNERS)
├── scripts/verify-release-signature.sh  the release gate: APK signer == release-signing-cert.sha256
├── release-signing-cert.sha256       the installer's own release-certificate pin
└── app/src/main/java/com/displayxr/installer/
    ├── Catalog.kt               the component table — mirrors install-android-bundle.sh
    ├── UiModel.kt               row/phase model + plannedStatus / servicePlannedStatus (pure, JVM-tested)
    ├── DisplayServices.kt       the display services: device gating, manifest, verification, staleness
    ├── ConfirmationWatchdog.kt  the pending-user-action deadline (pure, JVM-tested)
    ├── Net.kt                   HTTP + every typed failure the UI can show
    ├── GitHubReleases.kt        versions.json + pin -> release asset
    ├── ApkInstaller.kt          PackageInstaller sessions and their verdicts; archive identity
    ├── ApkSignatureReader.kt    v2/v3/v3.1 signing-block verifier: the archive's signer certificate (pure, JVM-tested)
    ├── InstallerViewModel.kt    the run: order, the services, the browser gate, launch-once, keyguard
    └── MainActivity.kt          the screen
```
