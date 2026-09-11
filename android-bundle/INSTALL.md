# Updating a DisplayXR 3D tablet

Everything needed to bring a Leia tablet up to the current CNSDK + displayxr stack.
Unzip this folder anywhere and follow **one** of the three routes below.

---

## Optional first step — wipe to a VIRGIN tablet for a clean-slate test

Only if you want a *virgin* install rather than an upgrade — this is how the bundle
itself is validated, so a test that starts here proves the bundle, not the leftovers:

```bash
./scripts/reset-to-virgin.sh          # dry run — lists what would be done
./scripts/reset-to-virgin.sh --yes    # do it; ends with a reboot + unlock
```

It removes the OpenXR runtime, every `com.displayxr.*` demo and the browser, reverts
`com.leialoft.display.config` and `com.leia.headtrackingservice` to the **factory**
builds in `/system/app` (they are updated system apps, so "uninstall" can only remove
the update — that is exactly what the OEM shipped), deletes the browser flag file and
the persisted EarthView key property, reboots, and unlocks. Every app-op and runtime
permission goes with the uninstalls. It then prints an audit.

(`scripts/uninstall-displayxr.sh` is the older, gentler variant that leaves the two
services at their current version. Use it for a quick DisplayXR-only reinstall; use
`reset-to-virgin.sh` when the question is "does this bundle work on a fresh tablet".)

---

## Route A — from a computer (recommended)

Needs `adb` ([Android platform-tools](https://developer.android.com/tools/releases/platform-tools)).

1. On the tablet: **Settings → About → tap Build number 7×**, then
   **Settings → System → Developer options → USB debugging → ON**.
2. Connect by USB. Accept the *"Allow USB debugging?"* prompt on the tablet.
3. ```bash
   ./scripts/install-from-computer.sh
   ```
4. **Reboot the tablet.**

The script installs in dependency order, reports each package, prints the resulting
versions, and stops with a non-zero exit if anything failed.

---

## Route B — on the tablet, no computer

1. Copy this whole folder (or the zip) to the tablet and unzip it.
2. Install **Termux** (or any terminal app).
3. ```sh
   cd /sdcard/Download/displayxr-tablet-bundle-<date>   # the folder you unzipped
   sh scripts/install-on-tablet.sh
   ```
4. Accept the install-permission prompt if Android shows one.
5. **Reboot the tablet.**

---

## Route C — fully manual (no terminal at all)

Open a file manager on the tablet and tap each APK **in this order**:

| order | folder | what |
|---|---|---|
| 1 | `apks/1-cnsdk-services/` | device-service — **the important one**, see below |
| 2 | `apks/1-cnsdk-services/` | headTracking-service |
| 3 | `apks/2-displayxr-runtime/` | the OpenXR runtime |
| 4 | `apks/3-demos/` | any or all demos |
| 5 | `apks/4-browser/` | the browser |

Android will ask permission to install from unknown sources — allow it for your file
manager. Then **reboot**.

**Verified on an NP02J, 2026-09-11.** The step people expect to fail is APK #1: the two CNSDK
services are updates to *built-in* apps, and a file manager is not a privileged installer. It
works. Tapping `device-service-…apk` in the stock File Manager over the factory 0.8.29 gives
the normal "not allowed to install unknown apps from this source" gate, and after allowing that
source Android shows **"Do you want to install an update to this built-in application? Your
existing data will not be lost."** for *Leia DisplayConfig*, with the installation source listed
as File Manager. INSTALL succeeds; the service reports 0.10.68 afterwards. This works because
the APKs are the vendor's own, signed with the key of the built-in app they replace — the same
reason a third party could not do it.

---

## After installing: five things that are not APKs

Installing the APKs is **not** sufficient on a clean device. Route A does all of
these for you. On Routes B and C you must do them by hand, and each one fails in a
way that looks like a different bug.

### 1. Open the DisplayXR app once, before any other app

Uninstalling deregisters the runtime's `OpenXRRuntimeBroker` ContentProvider, and
Android's `FLAG_STOPPED` keeps it unresolvable until the app is opened. Skip this
and **every** OpenXR app dies at instance creation with
`XR_ERROR_RUNTIME_UNAVAILABLE` — which reads as a broken runtime, not as "nobody
opened it". Nothing clears it at boot. **This is the most common virgin-install
failure.**

### 2. Grant "Display over other apps" to the runtime

`SYSTEM_ALERT_WINDOW` is an app-op. It is never granted at install and is dropped by
uninstall+install. Without it, see-through apps render on a **black background**
while 3D and weaving keep working — so it looks like a content bug.

    adb shell appops set org.freedesktop.monado.openxr_runtime.out_of_process SYSTEM_ALERT_WINDOW allow

By hand: **Settings → Apps → DisplayXR → Display over other apps → Allow**.

### 3. Grant CAMERA to GaussianSplat and Avatar

Otherwise they open on a consent dialog instead of content. By hand: accept the
prompt on first launch.

### 3b. After the reboot: UNLOCK the tablet before opening any app

Launching a demo while the tablet sits at the lockscreen (e.g. `adb shell am start`
right after `adb reboot`) **crashes** modelviewer and gaussiansplat on this runtime:
the activity is stopped behind the keyguard mid-`xrCreateSession`, the runtime's
hosted surface path deadlocks against `native_app_glue` for 5 s, then dies with
`NullPointerException … requestTransparentRegion`. Unlock first; it does not recur
once the app is launched on an unlocked screen. Tracked: displayxr-runtime#1358.
(Avatar and MediaPlayer bind their own surface and are unaffected.)

### 3c. If an app shows "… has stopped … update the app in App Center or clear app data"

First launch may show:

> **DisplayXR Browser has stopped** — Can't launch "DisplayXR Browser" due to its own reason,
> please update the app in App Center or clear app data

This is a **known first-launch dialog on some tablets** (displayxr-browser#188). What causes it is
still being measured — do not assume it is or is not a real crash.

**Tap the app icon again.** If it repeats: **Settings → Apps → DisplayXR Browser → Storage → Clear
data**, then launch. The same dialog can appear for the **demos**; the same two steps apply.

If it still refuses, uninstall that app and reinstall it from the zip — a browser from before
2026-09-06 was signed with a different key, so a current build cannot install over it. (That case
should fail at INSTALL time with a signing error rather than at launch.)

If you can run adb and it happens to you, these three settle the cause without reproducing it:

    adb shell dumpsys activity exit-info org.chromium.chrome
    adb shell dumpsys dropbox --print | head -300
    adb shell pm list packages -i | grep chromium

An entry timed with the dialog means the app really did die; nothing there points elsewhere.

Note for whoever validates a bundle: `adb install` + `monkey` do not reproduce a tester's path, and
our pads carry `/data/local/tmp/chrome-command-line`, which testers do not — so a build can pass
every scripted check here and still fail someone's first launch.

### 4. UNINSTALL any older DisplayXR Browser before installing this one

**This bundle ships a RELEASE-SIGNED browser (0.1.28; every build since 0.1.25 is).** Every build up to
and including 0.1.24 was signed with Chromium's debug key. Android identifies an app by
its signing key and **refuses an install that changes it** — you get a bare
*"App not installed"* with nothing naming the cause.

    adb uninstall org.chromium.chrome        # or long-press the icon -> Uninstall

Or let the installer do it for you — **opt-in, because uninstalling wipes that app's
data**, so it is never the default:

    scripts/install-from-computer.sh --replace-mismatched

Without the flag the script still detects the mismatch and prints the exact
`adb uninstall` command; it just will not wipe anything on your behalf.

One time only; later browser releases upgrade normally. Fixes the OEM App Center refusal some
testers hit on first launch (browser#188).

Coming from 0.1.25, 0.1.26 or 0.1.27: no uninstall needed, the upgrade is in place.

0.1.28 also fixes the **3D tiles going black after the browser is swiped away and reopened**
(browser-pvt #34) — on 0.1.26/0.1.27 only a force-stop recovered it. If you see that on
this bundle, check the installed browser really is 0.1.28 (`scripts/audit-device.sh`).

### 5. Browser inline-3D — nothing to do (0.1.24 and later)

**The bundled browser 0.1.28 ships inline-3D ON by default.** No adb, no
command-line file, no step. Just open the browser.

This step existed for 0.1.23 and earlier, which gated 3D behind `--enable-inline-3d`
and could only receive it through an adb-written file — so the browser showed
**black where the 3D should be** and looked like a runtime fault. That cost two
people a runtime reinstall, a browser reinstall and a services update chasing a
phantom. It is fixed in the bundled build: the switch is now set in the earliest
startup callback (displayxr-browser#190).

If you are handed an older APK, the old procedure still applies:

    adb shell "echo 'chrome --disable-fre --enable-inline-3d' > /data/local/tmp/chrome-command-line"
    adb shell am force-stop org.chromium.chrome     # the flag is read at startup

To turn 3D **off** on 0.1.24+, pass `--disable-inline-3d` the same way. An explicit
`--enable-inline-3d` is harmless — it stays a no-op.

**Still seeing black tiles on 0.1.24?** It is not this flag. Check the runtime and
CNSDK services are installed and current (sections 1–2) — that is the other cause
with the same symptom.

### 6. EarthView asks for a Google Maps API key

On first run, entered in portrait. A keyboard suggestion strip can cover the Save
button — rotate or dismiss the keyboard if you cannot reach it.

---

## If a CI-built bundle stops appearing

The bundle is assembled by `build-android-bundle.yml` in `displayxr-installer`, which downloads the
two vendor display-service APKs from a private repo using the `LEIALOFT_GITHUB_TOKEN` secret. That
token is a fine-grained PAT scoped to read that one repo, and it **expires 2027-09-11**. When it
lapses the build fails at "Download the vendor display services" with a `gh release download` error
that does not mention expiry. Mint a new token (Contents: Read-only on that repo) and re-set the
secret; nothing else changes.

## Order matters, and here is why

**`device-service` (`com.leialoft.display.config`) is the package that carries the
CNSDK core** — `libleiaCore-impl.so`. Not the head-tracking service, and not the
runtime. This is genuinely surprising and it is the single most common mistake:

| package | carries the CNSDK core? |
|---|---|
| `com.leia.headtrackingservice` | **no** |
| the OpenXR runtime | **no** — it ships the *loader* |
| **`com.leialoft.display.config`** (device-service) | **YES** |

Installing only the head-tracking service updates nothing about 3D prediction.

`device-service` also owns backlight and display-mode control, so if an install goes
wrong the display may misbehave until it is reinstalled or the tablet is rebooted.

---

## After installing

Reboot, then open a demo. To confirm the stack is live, from a computer:

```bash
adb shell dumpsys package com.leialoft.display.config | grep versionName
```

`versionName` tells you the release (`0.10.65`) but not *which build* of it. For that,
read the manifest of the installed APK — **`dumpsys` does not print `<meta-data>`**
(verified on an NP02J, Android 13: it returns nothing, and `-f` / `--all-components`
do not help):

```bash
for P in com.leialoft.display.config com.leia.headtrackingservice \
         org.freedesktop.monado.openxr_runtime.out_of_process; do
  adb pull "$(adb shell pm path $P | head -1 | sed 's/package://' | tr -d '\r')" /tmp/$P.apk >/dev/null
  echo "== $P"
  aapt2 dump xmltree --file AndroidManifest.xml /tmp/$P.apk \
    | grep -A1 -E "CNSDK_LOADER_VERSION|CNSDK_LOADER_BUILD|com.leia.cnsdk.FULL_VERSION"
done
adb logcat -s LeiaSDK | grep "weave predictor backend"
```

Or simply `./scripts/audit-device.sh`, which does the pull-and-read for all three packages
and compares the runtime's loader against the installed services. To prove 3D is actually
running (not just installed): `./scripts/prove-3d.sh [package]`.

### Optional: the newer weave predictor

This release ships an opt-in predictor that is measurably better at turnarounds and
roughly halves jitter when you hold still. It is **off by default** because it has
not yet had soak time in the displayxr path.

```bash
adb shell setprop debug.cnsdk.predictor blend
# then restart the app. To go back:
adb shell setprop debug.cnsdk.predictor '""'
```

---

## Troubleshooting

**`INSTALL_FAILED_UPDATE_INCOMPATIBLE`** — an existing package was signed with a
different key. Uninstall it first: `adb uninstall <package>`. Note this wipes that
app's data.

**`INSTALL_FAILED_VERSION_DOWNGRADE`** — you are installing an older build than what
is on the tablet. The scripts already pass `-d` to allow this; if you are tapping
manually, uninstall first.

**3D looks unchanged after installing** — almost always because only the
head-tracking service was updated. Check `com.leialoft.display.config`'s version.

**A demo starts but is not 3D** — the runtime and its bundled Leia plug-in must be a
matched pair. A mismatched plug-in loads cleanly, reports its identity, and then
weaves nothing, with no error message. See `apks/2-displayxr-runtime/MISSING.txt`
for the exact check.

**Nothing installs in Route B** — the terminal app lacks install permission. Use
Route C.

---

## What is in this bundle

See `MANIFEST.md` for every file, its package name, version and provenance.

Before sending this bundle to anyone, run:

```bash
./scripts/verify-bundle.sh
```

It checks the things that otherwise fail silently on device — whether the CNSDK core
is in the package that actually carries it, and whether the runtime and its bundled
Leia plug-in are a matched pair. It caught a real defect in a released artifact
within seconds of being pointed at one.
