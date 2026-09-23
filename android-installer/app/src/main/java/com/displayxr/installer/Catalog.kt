package com.displayxr.installer

/**
 * The component table.
 *
 * This is the Android-app transcription of the `COMPONENTS` array and the
 * `--links` asset resolution in `displayxr-runtime/scripts/install-android-bundle.sh`.
 * It is deliberately the SAME mapping — pin field -> repo -> release asset — and
 * not a second naming scheme: the whole reason `--links` generates its list
 * instead of letting anyone hand-write one is that two schemes drift, and a
 * runtime/browser pair that drifted apart blacks out all 3D in the browser while
 * every other app keeps working (displayxr-runtime#1302).
 *
 * If the shell script's mapping changes, change this with it.
 */
data class Component(
    /** Stable id, used for logging only. */
    val id: String,
    val displayName: String,
    /** GitHub repo that publishes the release asset. */
    val repo: String,
    /** Key in versions.json. */
    val pinField: String,
    /**
     * Expected application id. Only used to read the INSTALLED version before
     * anything is downloaded — see [ApkInstaller.packageOfArchive] for why the
     * authoritative name is read back out of the downloaded APK instead of
     * trusted from here.
     */
    val packageName: String,
    /** Opt-in components are not installed unless the user ticks them. */
    val optIn: Boolean = false,
    /**
     * Manifest `<meta-data>` key carrying this component's DisplayXR version,
     * for packages whose `versionName` is something else. Null means
     * `versionName` IS the DisplayXR version, which is true of everything
     * except the browser.
     */
    val versionStampKey: String? = null,
    /** What `versionName` actually is, when it is not the DisplayXR version. */
    val opaqueVersionLabel: String? = null,
    /** Picks this component's asset out of the release's asset list. */
    val assetMatch: (String) -> Boolean,
)

object Catalog {

    const val RUNTIME_PACKAGE = "org.freedesktop.monado.openxr_runtime.out_of_process"
    const val PINS_REPO = "DisplayXR/displayxr-installer"
    const val PINS_REF = "main"
    const val PINS_URL =
        "https://raw.githubusercontent.com/$PINS_REPO/$PINS_REF/versions.json"

    private const val RUNTIME_REPO = "DisplayXR/displayxr-runtime"

    /**
     * Manifest meta-data key the browser APK will carry from
     * displayxr-browser-pvt#159. Until a build that has it is installed, the
     * browser row reports its version as unknown — which is the truth.
     */
    const val BROWSER_VERSION_STAMP = "com.displayxr.BROWSER_VERSION"

    /**
     * The runtime ships two Android variants from one release. The vendor one
     * carries the vendor display plug-in (ADR-038); the vendor-neutral one
     * installs, self-tests and then weaves nothing, which on a 3D panel looks
     * exactly like a bug. So this installer resolves the VENDOR variant only —
     * the `--neutral` case belongs to the scripted install path, where the
     * person choosing it knows why.
     *
     * The pattern is the shell script's `RT_PAT`, unchanged.
     */
    private val RUNTIME_ASSET =
        Regex("""DisplayXR-Runtime-Leia-[0-9].*android-arm64\.apk""") // leia_plugin variant, ADR-038

    /** Every other component publishes exactly one Android asset: `*.apk`. */
    private val ANY_APK: (String) -> Boolean = { it.endsWith(".apk") }

    /**
     * Dependency order, and it is load-bearing: an app installed before the
     * runtime simply finds no runtime. The browser goes last because its gate
     * (see [InstallerViewModel.browserRefusal]) reads the runtime that is
     * actually on the device after the runtime leg has run.
     */
    val COMPONENTS: List<Component> = listOf(
        Component(
            id = "runtime",
            displayName = "DisplayXR runtime",
            repo = RUNTIME_REPO,
            pinField = "runtime",
            packageName = RUNTIME_PACKAGE,
            assetMatch = { RUNTIME_ASSET.containsMatchIn(it) },
        ),
        Component(
            id = "modelviewer",
            displayName = "Model Viewer",
            repo = "DisplayXR/displayxr-demo-modelviewer",
            pinField = "modelviewer_demo",
            packageName = "com.displayxr.model_viewer_vk_android",
            assetMatch = ANY_APK,
        ),
        Component(
            id = "mediaplayer",
            displayName = "Media Player",
            repo = "DisplayXR/displayxr-demo-mediaplayer",
            pinField = "mediaplayer_demo",
            packageName = "com.displayxr.mediaplayer_vk_android",
            assetMatch = ANY_APK,
        ),
        Component(
            id = "gaussiansplat",
            displayName = "Gaussian Splat",
            repo = "DisplayXR/displayxr-demo-gaussiansplat",
            // Three s. Matches neither the repo name nor the asset name, which
            // is why nothing here guesses a package name from a file name.
            packageName = "com.displayxr.gausssplat_vk_android",
            pinField = "gauss_demo",
            assetMatch = ANY_APK,
        ),
        Component(
            id = "earthview",
            displayName = "Earth View",
            repo = "DisplayXR/displayxr-demo-earthview",
            pinField = "earthview_demo",
            packageName = "com.displayxr.earthview_vk_android",
            assetMatch = ANY_APK,
        ),
        Component(
            id = "avatar",
            displayName = "Avatar",
            repo = "DisplayXR/displayxr-demo-avatar",
            pinField = "avatar_demo",
            packageName = "com.displayxr.avatar_vk_android",
            assetMatch = ANY_APK,
        ),
        Component(
            id = "browser",
            displayName = "DisplayXR Browser",
            repo = "DisplayXR/displayxr-browser",
            pinField = "browser",
            packageName = "org.chromium.chrome",
            optIn = true,
            // `org.chromium.chrome`'s versionName is the CHROMIUM version
            // (154.0.8037.17), not the DisplayXR release, and several DisplayXR
            // releases share one Chromium base — so there is no comparison to
            // make from it. Read the stamp when the APK carries one
            // (displayxr-browser-pvt#159 adds it); otherwise say "unknown"
            // rather than compare the wrong number. See Installed.Opaque.
            versionStampKey = BROWSER_VERSION_STAMP,
            opaqueVersionLabel = "Chromium",
            assetMatch = ANY_APK,
        ),
    )

    val runtime: Component = COMPONENTS.first { it.id == "runtime" }
}

/** Version helpers. Pins are tags (`v2.16.36`); versionName is bare (`2.16.36`). */
object Versions {

    fun strip(tagOrName: String): String = tagOrName.removePrefix("v").removePrefix("V")

    /**
     * Exact equality of the version string, tag prefix aside. Deliberately not a
     * "close enough" comparison: a locally built runtime reports something like
     * `2.16.36-14-gabc1234`, and that is precisely the configuration that must
     * NOT be treated as the pinned runtime.
     */
    fun same(installed: String?, pin: String?): Boolean =
        installed != null && pin != null && strip(installed) == strip(pin)

    /** -1 / 0 / +1 on the leading dotted-integer components; unknown -> 0. */
    fun compare(a: String, b: String): Int {
        val pa = numbers(a)
        val pb = numbers(b)
        for (i in 0 until maxOf(pa.size, pb.size)) {
            val x = pa.getOrElse(i) { 0 }
            val y = pb.getOrElse(i) { 0 }
            if (x != y) return if (x < y) -1 else 1
        }
        return 0
    }

    private fun numbers(v: String): List<Int> =
        strip(v).split('.', '-', '+', '_')
            .map { it.takeWhile { c -> c.isDigit() } }
            .takeWhile { it.isNotEmpty() }
            .map { it.toInt() }
}
