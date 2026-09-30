## Install DisplayXR on a Leia tablet (Lume Pad 2 / Nubia Pad 3D / Lume Phone)

You need only the tablet and Wi-Fi — no computer.

1. **On the tablet**, open this page in the browser and download **`DisplayXR-Installer-<version>.apk`** from the *Assets* list below.
2. Open the downloaded file (from the browser's download notification, or *Files → Downloads*). Android will ask to **allow installs from this source** — allow it for the browser / file manager, go back, and tap **Install**.
3. Open **DisplayXR Installer**. Tap **Allow this app to install apps** and switch it on, then go back.
4. Tick **Also install DisplayXR Browser** if you want it (large download, ~330 MB).
5. Tap **INSTALL / UPDATE**. The installer first updates the tablet's **display services** (they appear as *"an update to this built-in application"* — that is expected), then installs the DisplayXR runtime and apps.
6. Android asks you to confirm **each** package — tap **Install** on every prompt (about 9). If Android shows an *"App installed — DONE / OPEN"* screen, tap **DONE**.
7. When the runtime opens and asks to **allow notifications**, tap **Allow**.
8. **REBOOT the tablet** when the red card says so — hold the power button → *Restart*. **It is not optional**: without it the screen can stay flat 2D while every app reports 3D.
9. After the reboot, **unlock** the tablet. If a **USB mode** chooser pops up (seen on the Nubia Pad 3D), just dismiss it.
10. Open **DisplayXR Installer** again and tap **Open the setting** under *"Display over other apps"* → switch it **on** for DisplayXR. Without it, see-through apps show a black background.
   *Alternative path:* **Settings → Apps → DisplayXR → Display over other apps → Allow**.
11. If you installed DisplayXR Browser: on its **first launch** Chrome's first-run screens appear — tap **Stay signed out**, then **No thanks**.

The **display services update is downloaded automatically** by the installer and is **required** — do not skip it.


If the installer shows a red **"Display services update needed"** card, it could not download the display services — check the Wi-Fi and tap **Check again**. Until they are updated, **3D will not work correctly** (content stays 2D, parallax is wrong, apps can freeze).

**Already have DisplayXR Installer 0.4.1 or older? One time only:** uninstall the old **DisplayXR Installer** (*Settings → Apps → DisplayXR Installer → Uninstall*), then install this one — otherwise Android says *"App not installed"*. Your DisplayXR apps are not affected. Those older builds were signed with a temporary key; from 0.4.2 on every installer is signed with the same permanent key and updates in place.

---
