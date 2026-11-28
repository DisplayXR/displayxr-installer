# displayxr-installer

End-user meta-installer for [DisplayXR](https://github.com/DisplayXR/displayxr-runtime) — a single `.exe` / `.pkg` bundle that chains the OpenXR runtime, the Leia SR plug-in (and, once the plug-in no longer carries it, the Leia conversion component), MCP Tools, the open-model conversion provider and the demos into one guided install. The DisplayXR Shell is not in the bundle: it is an optional add-on (catalog id `displayxr-shell`), installed from the DisplayXR Dashboard or its own installer.

Tracks issue [`DisplayXR/displayxr-runtime#284`](https://github.com/DisplayXR/displayxr-runtime/issues/284).

## Download

| Platform | Download |
|---|---|
| macOS 13+ | [latest `.pkg`](https://github.com/DisplayXR/displayxr-installer/releases/latest) |
| Windows 10/11 | [latest `.exe`](https://github.com/DisplayXR/displayxr-installer/releases/latest) |
| Linux (Debian/Ubuntu amd64) | [latest `.tar.gz`](https://github.com/DisplayXR/displayxr-installer/releases/latest) — unpack, then `sudo ./install.sh` |
| Android 3D tablet (Lume Pad 2, Nubia Pad 3D, Lume Phone) | [latest `DisplayXR-Installer-<ver>.apk`](https://github.com/DisplayXR/displayxr-installer/releases/latest) — step by step: [Install DisplayXR on a Leia tablet](android-installer/README.md#install-displayxr-on-a-leia-tablet-lume-pad-2--nubia-pad-3d--lume-phone) |
| Android tablet bundle (offline, sideload/adb — testers) | [`displayxr-tablet-bundle.zip`](https://github.com/DisplayXR/displayxr-installer/releases/download/android-bundle-latest/displayxr-tablet-bundle.zip) — always the newest published bundle ([release page](https://github.com/DisplayXR/displayxr-installer/releases/tag/android-bundle-latest)) |

## One-time install warning (unsigned)

Version 1 of the bundle ships unsigned. SmartScreen / Gatekeeper show a one-time prompt on the bundle itself, then everything inside installs silently.

- **macOS:** right-click the downloaded `.pkg` → **Open** → click **Open** in the dialog. Apple requires this for unsigned installers — notarization is tracked in [`DisplayXR/displayxr-runtime#280`](https://github.com/DisplayXR/displayxr-runtime/issues/280).
- **Windows:** if SmartScreen shows "Windows protected your PC", click **More info** → **Run anyway**. Authenticode signing is tracked in [`DisplayXR/displayxr-runtime#281`](https://github.com/DisplayXR/displayxr-runtime/issues/281).

## What gets installed

| Component | macOS | Windows | Linux |
|---|---|---|---|
| DisplayXR Runtime | ✅ | ✅ | ✅ |
| DisplayXR Shell | not bundled: an add-on with its own installer | not bundled (Dashboard / own installer) | not bundled |
| Leia SR Plug-in | — (Windows-only, vendor SDK) | ✅ ticked only on a PC with a Leia SR display (below) | ✅ |
| Leia conversion (2D→3D conversion from the display maker) | — (no macOS build) | ⏳ from the first bundle whose Leia SR plug-in is ≥ 2.24.0 | ⏳ same rule |
| MCP Tools | ✅ | ✅ | — (no Linux build) |
| Open Conversion provider (open-model 2D→3D) | — (no macOS build today) | ✅ | ⏳ needs a `.deb`: it ships only a per-user tarball, and the Linux bundle installs system packages |
| Demos (gauss, model viewer, media player, avatar, earthview) | ✅ | ✅ | ⏳ join when they ship a Linux `.deb` |

On macOS the bundle carries the runtime, MCP Tools and the demos; other components join it as they publish `.pkg` artifacts.

### Windows: the Leia SR plug-in is ticked only where there is a Leia SR display

The *Leia SR plug-in* and *Leia conversion* rows start **unticked**. They come up ticked when:

- the component is already installed (an installed row is never unticked for you: unticking an installed row removes it), or
- the signed DisplayXR Catalog's detection finds a Leia SR display on this PC with **high** confidence. The bundle runs the catalog engine `dxr-get detect` of the runtime it chains (embedded in the bundle), which reads the monitors' EDID ids and the catalog's rules. A low-confidence match never ticks, and neither does a failed check (no network, no PowerShell): you can still tick the row by hand.

Silent installs (`/S`) follow the same rule. Overrides, for IT:

| Switch | Effect |
|---|---|
| `/LEIASR=1` | tick both rows whatever detection says (a display not connected yet, an offline install) |
| `/LEIASR=0` | skip detection; the rows are ticked only when already installed |
| `/CATALOG=<url\|file>` | hand dxr-get another signed catalog (testing) |

Why: the plug-in's own installer is going to fetch the display maker's platform software, so installing it on every PC would pull vendor software onto machines without the display.

### The DisplayXR Shell

Not part of the bundle on any platform. Upgrading with the bundle leaves an installed Shell exactly as it is (the bundle has no row for it, so it can neither update nor remove it); update it from the Dashboard or its own installer. Uninstalling the bundle uninstalls the runtime, and the runtime's uninstaller removes every registered workspace controller with it, so the Shell goes too.

The exact version pins for each release live in [`versions.json`](versions.json) at the tagged commit.

### Leia conversion: chained with the plug-in that stops carrying it

Up to its 2.23.x line the Leia SR plug-in installs the display maker's 2D→3D conversion provider itself. From plug-in 2.24.0 it does not, and the provider ships only as the separate **Leia conversion** component ([`displayxr-leia-conversion`](https://github.com/DisplayXR/displayxr-leia-conversion), pinned as `leia_conversion`). The bundle switches with the plug-in pin, in one step:

| `leia_plugin` pin | Bundle | Why |
|---|---|---|
| < v2.24.0 | does **not** chain `leia_conversion` (a build that tries fails) | that plug-in still writes the provider registration and would take it back from the component (Windows); the two `.deb`s conflict (Linux) |
| ≥ v2.24.0 | chains `leia_conversion`, and **requires** it | without it a display that had conversion loses it on upgrade |

On Windows it is the **Leia conversion** row under *Vendor plug-ins*: a sub-choice of *Leia SR plug-in* (unticking the plug-in unticks it), installed right after the plug-in. On Linux its `.deb` is installed in the same `apt-get` transaction as the plug-in's. It needs the Leia conversion runtime, which the display maker ships with its own installer — the bundle never installs it. The rule lives in `scripts/leia_conversion_gate.ps1` / `scripts/lib/leia-conversion-gate.sh`; `scripts/check_bundle_coverage.ps1` holds the bundle to it in both states.

## Linux bundle

The Linux bundle is a `.tar.gz` containing the component `.deb`s + an `install.sh`:

```bash
tar -xzf DisplayXRBundle-*-linux-amd64.tar.gz
cd DisplayXRBundle-*-linux-amd64
sudo ./install.sh          # sudo ./uninstall.sh to remove
```

To verify a download first, grab `SHA256SUMS` from the same release page into the same folder and run:

```bash
sha256sum -c SHA256SUMS --ignore-missing   # checks only the assets you downloaded
```

`SHA256SUMS` covers every bundle asset (`.exe`, `.pkg`, `.tar.gz`, `.apk`); the `.exe` line matches the **signed** installer.

It installs the DisplayXR runtime + Leia SR display-processor plug-in (+ the Leia conversion component, [when the plug-in no longer carries it](#leia-conversion-chained-with-the-plug-in-that-stops-carrying-it)) with **zero environment variables** — the runtime registers the OpenXR ActiveRuntime and searches `/usr/lib/displayxr/plugins` by default. Without the **Leia SR runtime** (the commercial `leiasr-runtime` package, shipped separately by Leia — **not** in this bundle) apps run on the built-in sim-display fallback; install it and the Leia display processor claims the display automatically. `install.sh` detects it and guides you.

Demos are **not** included on Linux yet — they ship Windows `.exe` / macOS `.pkg` today but no Linux `.deb`. `build-bundle-linux.sh` already loops over them and will pull each one in automatically once its repo publishes a `*_amd64.deb` release asset (and `components.sh` gains its `DEB_LINUX` glob). Tracks [`DisplayXR/displayxr-runtime#781`](https://github.com/DisplayXR/displayxr-runtime/issues/781).

## Android installer APK

Android has no NSIS equivalent — an App Bundle or a set of split APKs describes exactly one app —
so the "one tappable artifact" job is done by an app. `DisplayXR-Installer-<ver>.apk` reads the same
`versions.json` pin matrix, downloads each pinned component from its GitHub release, installs them
in dependency order — on a 3D tablet, starting with the pinned vendor display services, which it
downloads from `updates.displayxr.org` and verifies against the vendor certificate it carries (on the
factory services DisplayXR runs but 3D does not work) — and then performs the post-install steps that
installing APKs does not do:
opening the runtime once (without which every OpenXR app dies at instance creation with
`XR_ERROR_RUNTIME_UNAVAILABLE`), and deep-linking to the runtime's "Display over other apps" switch
(without which see-through apps render on black while 3D keeps working).

The browser is **opt-in**, mirroring the desktop `--with browser` rule, and is refused unless the
runtime actually on the tablet is the pinned one — the mismatched pair renders all 3D content in the
browser black with no error on screen.

It is **not silent**: Android confirms each package separately unless the installer is a device owner
or a privileged system app. Full scope, the steps it cannot automate, and the failure states:
[`android-installer/README.md`](android-installer/README.md). Tracks
[#62](https://github.com/DisplayXR/displayxr-installer/issues/62).

## Developer install

Building DisplayXR from source or running a dev box? Use the runtime repo's orchestrator instead:

```bash
# macOS / Linux
git clone https://github.com/DisplayXR/displayxr-runtime
cd displayxr-runtime
./scripts/setup-displayxr.sh
```

```cmd
:: Windows (elevated)
git clone https://github.com/DisplayXR/displayxr-runtime
cd displayxr-runtime
scripts\setup-displayxr.bat
```

The end-user bundle in this repo is a thin wrapper that chains the same per-component installers via NSIS / `productbuild`.

## Building the bundle locally

```bash
# macOS
./scripts/build-bundle.sh --version v0.1.0-rc1
# → _out/DisplayXRBundle-0.1.0-rc1.pkg

# Windows
scripts\build-bundle.bat --version v0.1.0-rc1
:: → _out\DisplayXRBundle-0.1.0-rc1.exe
```

Both scripts read `versions.json`, fetch the per-component asset table from the runtime repo at the pinned `runtime` tag, download each component's installer from its GitHub Release, and assemble the bundle.

## Release flow

Releases are cut by manual `workflow_dispatch` on `.github/workflows/publish-bundle.yml`:

1. Bump `versions.json` in a PR (pinning each component to a specific tag).
2. Merge.
3. Run **Publish bundle** → enter the bundle tag (e.g. `v0.1.0`) → workflow builds both platforms in parallel and attaches `.exe` + `.pkg` to a new GitHub Release.

Not auto-triggered on component releases — that would be brittle (e.g., a runtime patch release shouldn't republish a bundle that wasn't compat-tested against the components it chains).

## License

[Apache-2.0](LICENSE).
