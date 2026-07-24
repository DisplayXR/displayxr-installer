# displayxr-installer

End-user meta-installer for [DisplayXR](https://github.com/DisplayXR/displayxr-runtime) — a single `.exe` / `.pkg` bundle that chains the OpenXR runtime, Shell, Leia SR plug-in, and MCP Tools into one guided install.

Tracks issue [`DisplayXR/displayxr-runtime#284`](https://github.com/DisplayXR/displayxr-runtime/issues/284).

## Download

| Platform | Download |
|---|---|
| macOS 13+ | [latest `.pkg`](https://github.com/DisplayXR/displayxr-installer/releases/latest) |
| Windows 10/11 | [latest `.exe`](https://github.com/DisplayXR/displayxr-installer/releases/latest) |
| Linux (Debian/Ubuntu amd64) | [latest `.tar.gz`](https://github.com/DisplayXR/displayxr-installer/releases/latest) — unpack, then `sudo ./install.sh` |

## One-time install warning (unsigned)

Version 1 of the bundle ships unsigned. SmartScreen / Gatekeeper show a one-time prompt on the bundle itself, then everything inside installs silently.

- **macOS:** right-click the downloaded `.pkg` → **Open** → click **Open** in the dialog. Apple requires this for unsigned installers — notarization is tracked in [`DisplayXR/displayxr-runtime#280`](https://github.com/DisplayXR/displayxr-runtime/issues/280).
- **Windows:** if SmartScreen shows "Windows protected your PC", click **More info** → **Run anyway**. Authenticode signing is tracked in [`DisplayXR/displayxr-runtime#281`](https://github.com/DisplayXR/displayxr-runtime/issues/281).

## What gets installed

| Component | macOS | Windows | Linux |
|---|---|---|---|
| DisplayXR Runtime | ✅ | ✅ | ✅ |
| DisplayXR Shell | — (Windows-only today) | ✅ | — |
| Leia SR Plug-in | — (Windows-only, vendor SDK) | ✅ | ✅ |
| MCP Tools | — (Windows-only today) | ✅ | — |
| Demos (gauss, model viewer, media player, avatar, earthview) | ✅ | ✅ | ⏳ join when they ship a Linux `.deb` |

macOS users get a runtime-only install today; additional components join the bundle as they publish `.pkg` artifacts.

The exact version pins for each release live in [`versions.json`](versions.json) at the tagged commit.

## Linux bundle

The Linux bundle is a `.tar.gz` containing the component `.deb`s + an `install.sh`:

```bash
tar -xzf DisplayXRBundle-*-linux-amd64.tar.gz
cd DisplayXRBundle-*-linux-amd64
sudo ./install.sh          # sudo ./uninstall.sh to remove
```

It installs the DisplayXR runtime + Leia SR display-processor plug-in with **zero environment variables** — the runtime registers the OpenXR ActiveRuntime and searches `/usr/lib/displayxr/plugins` by default. Without the **Leia SR runtime** (the commercial `leiasr-runtime` package, shipped separately by Leia — **not** in this bundle) apps run on the built-in sim-display fallback; install it and the Leia display processor claims the display automatically. `install.sh` detects it and guides you.

Demos are **not** included on Linux yet — they ship Windows `.exe` / macOS `.pkg` today but no Linux `.deb`. `build-bundle-linux.sh` already loops over them and will pull each one in automatically once its repo publishes a `*_amd64.deb` release asset (and `components.sh` gains its `DEB_LINUX` glob). Tracks [`DisplayXR/displayxr-runtime#781`](https://github.com/DisplayXR/displayxr-runtime/issues/781).

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

Not auto-triggered on component releases — that would be brittle (e.g., a runtime patch release shouldn't republish a bundle that wasn't compat-tested against the latest Shell).

## License

[Apache-2.0](LICENSE).
