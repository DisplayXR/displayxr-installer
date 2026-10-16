# DisplayXR on Android 3D tablets: install and keep it healthy

This guide covers the **Lume Pad 2**, the **Nubia Pad 2** (nubia Pad 3D II) and the **Red Magic Explorer**. Menu names below are from the Nubia Pad 2; the other devices use the same system software family, so the steps are the same, but labels can differ slightly. It explains what to install, in which order, the few one-time settings that are not part of any APK, and how to recognise and fix the handful of problems that look like bugs but are not.

## What is on the device

A working 3D setup is five pieces. Four of them must match each other.

| Piece | Package | What it does |
|---|---|---|
| Display service | `com.leialoft.display.config` | The vendor 3D engine (CNSDK core), lens and backlight control. An update to a built-in app. |
| Head-tracking service | `com.leia.headtrackingservice` | Owns the front tracking camera and reports where your eyes are. An update to a built-in app. |
| DisplayXR runtime | `org.freedesktop.monado.openxr_runtime.out_of_process` (app name *DisplayXR*) | The OpenXR runtime. Carries the Leia plug-in and the CNSDK loader, which must match the two services. |
| DisplayXR apps | `com.displayxr.*` | Model Viewer, Gaussian Splat, Media Player, EarthView, Avatar. |
| DisplayXR Browser | `org.chromium.chrome` (app name *DisplayXR Browser*) | Web pages with glasses-free inline 3D. The only app that talks to the runtime as a separate background service. |

**Always install a matched set.** Every release bundle pins one CNSDK version for both services and builds the runtime against exactly that version. Updating only one service, or a runtime from a different bundle, gives a stack that starts without errors and then weaves nothing or tracks nothing.

## Install

### The easy way: the DisplayXR Installer app

1. Copy `DisplayXR-Installer-<version>.apk` to the tablet and tap it. Allow *install unknown apps* for the file manager or browser when Android asks.
2. Unlock the tablet and keep it awake. Open **DisplayXR Installer**, allow it to install apps, tick the browser if you want it, and tap **Install / update**.
3. Confirm each package (about nine). The two services show as *"an update to this built-in application"*. That is expected: they carry the manufacturer's signing key, which is why they can install at all. If Android shows *App installed — DONE / OPEN* after a service update, tap **DONE**.
4. **Reboot when the red card says so.** See [Reboot after a service update](#reboot-after-a-service-update).
5. Do the [one-time settings](#one-time-settings-after-installing) below.

The installer skips anything already at the pinned version and never uninstalls anything.

### From a computer (adb)

Enable USB debugging (**Settings → About → tap Build number 7 times**, then **Developer options → USB debugging**), connect, unzip the bundle and run:

```bash
./scripts/install-from-computer.sh
```

It installs in dependency order (display service, head-tracking service, runtime, apps, browser), prints the resulting versions and does the first two one-time settings for you. Then reboot.

### Order matters

1. Display service, 2. head-tracking service, 3. runtime, 4. apps, 5. browser. The display service is the package that carries the 3D engine; installing only the head-tracking service changes nothing about 3D.

### Upgrading from an old browser

Browsers older than 0.1.25 were signed with a different key. Android refuses to install over them with a bare *"App not installed"*. Uninstall the old browser first (this deletes its tabs and data), then install the new one. Later browser versions upgrade in place.

## Reboot after a service update

Rebooting after a display-service or head-tracking-service update **is not optional**. The display service is replaced under a running system. Without a reboot the lens controller can be left in a state where every app reports 3D, tracks your face and weaves, and the glass still shows flat 2D. The manufacturer's own 3D viewer shows the same thing, which is the tell. A reboot clears it.

After the reboot, **unlock the tablet before opening any 3D app**. On the Nubia Pad 2 a USB-mode chooser may pop up; dismiss it.

## One-time settings after installing

None of these are inside an APK, and each one fails in a way that looks like something else.

1. **Open the DisplayXR app once, before any other 3D app.** Until it has been opened, every 3D app fails to start with a "runtime unavailable" error. The installer and the adb script do this for you.
2. **Allow "Display over other apps" for DisplayXR.** *Settings → Apps → DisplayXR → Display over other apps → Allow.* Without it, see-through apps show a black background while 3D keeps working.
3. **Lock DisplayXR and DisplayXR Browser in Recents. This is the important one.** Open Recents, tap the **⋮** on the DisplayXR card, choose **Lock the app**. Do the same on the DisplayXR Browser card. A padlock appears on each card. Both apps must have been opened once to have a card.
4. **Allow "always run in background" for DisplayXR.** The first time DisplayXR opens it asks *"Let app always run in background?"* — tap **ALLOW**. If you missed it, open DisplayXR and tap the **background exemption: not granted (tap to request)** row. Helpful, but on its own it is not enough on these tablets (see below).
5. **Allow the camera** when Gaussian Splat and Avatar ask on first launch.

### Why the Recents lock matters

These tablets run an aggressive background manager that freezes apps it considers idle. The DisplayXR runtime runs as a background service for the browser, and the manager freezes it about a minute into a browser session **even while the browser is on screen**. While it is frozen the page stops weaving. The symptom is browser pages that lose 3D (or never get it) while every DisplayXR app works, because those run the runtime inside themselves.

Measured on a retail Nubia Pad 2, same browser session each time:

| Setting | Runtime frozen during the session? |
|---|---|
| Nothing set | Yes, for about 30 s |
| "Always run in background" allowed | Yes, for about 30 s |
| DisplayXR and DisplayXR Browser locked in Recents | No |

A foreground notification does not help either. The Recents lock does, and it survives reboots and app updates.

## Healthy-device checklist

Open **DisplayXR**. A healthy device shows:

- **SELF-TEST: PASS**, with `active_plugin — 'DisplayXR Leia CNSDK (Android)'`.
- **ACTIVE PLUG-IN** with the plug-in version from the release notes.
- **background exemption: granted** (if you allowed it), and a padlock on the DisplayXR and DisplayXR Browser cards in Recents.

Then open any DisplayXR app: it should be 3D and follow your head within a second or two.

From a computer, `./scripts/audit-device.sh` in the bundle reads all three versions and checks that the runtime's CNSDK loader matches the installed services; `./scripts/prove-3d.sh` proves 3D is actually running, not just installed.

## Keeping it healthy

- **Update as a set.** Use the installer, or the whole bundle, every time. Never sideload a single service or a runtime from a different release.
- **Reboot after every service update.**
- **Keep the runtime installed.** Uninstalling DisplayXR while a 3D app is running breaks that app until it is restarted; reinstalling resets the overlay permission, so redo one-time setting 2. The Recents lock and the background exemption are remembered by the tablet across reinstalls.
- **Avoid using the front camera in another app during a 3D session.** The head-tracking service owns the tracking camera. Another app opening a front camera interrupts tracking. Current services recover automatically within about 15 seconds; on older services tracking stayed lost until the device restarted.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Every 3D app fails to start ("runtime unavailable") | DisplayXR not opened since it was installed | Open DisplayXR once, then the app. |
| See-through apps show a black background | Overlay permission missing | One-time setting 2. |
| Browser shows no 3D, or loses it after a minute, but DisplayXR apps work | Background manager froze the runtime | Lock DisplayXR and DisplayXR Browser in Recents (one-time setting 3), then reload the page. |
| Glass stays flat 2D although apps report 3D | Lens controller left in a bad state by a service update | Reboot. |
| Apps are 2D and nothing follows your head | Head-tracking service not responding (fixed in display services 0.10.83; can still happen on older services) | Force-stop **Head Tracking Service** (Settings → Apps → show system apps), then reopen the app. |
| 3D image stops following your head mid-session | Tracking camera was interrupted (another app, camera fault) | Wait about 15 to 35 seconds; the service and the app reconnect on their own. If it does not come back, force-stop Head Tracking Service and reopen the app. |
| An app shows *"… has stopped … update the app in App Center or clear app data"* | Known first-launch dialog on some tablets | Tap the icon again; if it repeats, *Settings → Apps → that app → Storage → Clear data*. |
| *"App not installed"* when installing the browser | Old browser signed with a different key | Uninstall the old browser first. |
| A 3D app crashes when opened right after a reboot | Opened behind the lock screen | Unlock first, then open it. |
| EarthView asks for a Google Maps key | Required on first run | Enter it in portrait; dismiss the keyboard if it covers Save. |

## What is new in this release

- **Head tracking no longer locks up after a reboot** (display services 0.10.83). The head-tracking service could lock up within a minute of the device starting, leaving every app in 2D until the service was restarted. Fixed.
- **No more double image after waking the device** (display services 0.10.83, Lume Pad 2 class panels). After a sleep and wake the panel could be left in a mode that turned every 3D app into a double image until the app was reopened. The display service now resets the panel correctly once it has woken; you may see a brief 2D flash right after unlocking.
- **Tracking recovers by itself after a camera interruption.** If the tracking camera is lost mid-session (another app taking the front camera, a camera fault), the head-tracking service rebuilds its session with a short back-off, typically within about 15 seconds.
- **DisplayXR apps re-subscribe to tracking on their own.** If tracking frames stop mid-session, an app waits 30 seconds for the service to recover, then reconnects with back-off, and never gives up.
- **DisplayXR asks for the background exemption** on first launch and shows its state on the dashboard. On these tablets also lock DisplayXR and the browser in Recents; the exemption alone does not stop the freeze.
