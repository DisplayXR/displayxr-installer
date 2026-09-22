package com.displayxr.installer

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Agreement tests against REAL release asset lists.
 *
 * The fixtures below are the actual `assets[].name` of the pinned releases
 * (v2.20.1 / v1.0.4 / v0.8.1 / v1.27.1), so a matcher that starts picking the
 * wrong file — the desktop installer, the .deb, the vendor-neutral runtime —
 * fails here rather than on someone's tablet. This is the half of
 * `install-android-bundle.sh --links` that can be checked without a device.
 */
class CatalogTest {

    private fun pick(id: String, assets: List<String>): List<String> {
        val c = Catalog.COMPONENTS.first { it.id == id }
        return assets.filter { c.assetMatch(it) }
    }

    /** The runtime variant that bundles the vendor display plug-in (ADR-038). */
    private val vendorRuntimeApk = "DisplayXR-Runtime-Leia-2.20.1-android-arm64.apk" // leia_plugin variant

    @Test
    fun `runtime picks the vendor variant and never the neutral one`() {
        val assets = listOf(
            "DisplayXR-Client-2.20.1.aar",
            "DisplayXR-Installer-2.20.1.pkg",
            "DisplayXR-Runtime-2.20.1-android-arm64.apk",   // vendor-neutral: installs, weaves nothing
            vendorRuntimeApk,
            "displayxr-runtime_2.20.1_amd64.deb",
            "DisplayXRSetup-2.20.1.exe",
        )
        assertEquals(listOf(vendorRuntimeApk), pick("runtime", assets))
    }

    @Test
    fun `browser picks its android apk, not the windows setup`() {
        val assets = listOf(
            "DisplayXR-Browser-1.0.4-android-arm64.apk",
            "DisplayXR-Browser-Setup-1.0.4.exe",
        )
        assertEquals(listOf("DisplayXR-Browser-1.0.4-android-arm64.apk"), pick("browser", assets))
    }

    @Test
    fun `demos pick exactly one apk out of four platform artifacts`() {
        val earthview = listOf(
            "displayxr-earthview_0.8.1_amd64.deb",
            "DisplayXREarthView-0.8.1-android.apk",
            "DisplayXREarthView-0.8.1.pkg",
            "DisplayXREarthViewSetup-0.8.1.exe",
        )
        assertEquals(listOf("DisplayXREarthView-0.8.1-android.apk"), pick("earthview", earthview))

        val gauss = listOf(
            "displayxr-gaussiansplat_1.27.1_amd64.deb",
            "DisplayXRGaussianSplat-1.27.1.apk",
            "DisplayXRGaussianSplat-1.27.1.pkg",
            "DisplayXRGaussianSplatSetup-1.27.1.exe",
        )
        assertEquals(listOf("DisplayXRGaussianSplat-1.27.1.apk"), pick("gaussiansplat", gauss))
    }

    @Test
    fun `a release with no android asset matches nothing, so it is reported and not guessed at`() {
        val desktopOnly = listOf("DisplayXRMediaPlayer-1.9.10.pkg", "DisplayXRMediaPlayerSetup-1.9.10.exe")
        assertTrue(pick("mediaplayer", desktopOnly).isEmpty())
    }

    @Test
    fun `every component has a distinct pin field and package name`() {
        val fields = Catalog.COMPONENTS.map { it.pinField }
        val packages = Catalog.COMPONENTS.map { it.packageName }
        assertEquals(fields.size, fields.toSet().size)
        assertEquals(packages.size, packages.toSet().size)
    }

    @Test
    fun `the browser is the only opt-in component and the runtime is first`() {
        assertEquals(listOf("browser"), Catalog.COMPONENTS.filter { it.optIn }.map { it.id })
        assertEquals("runtime", Catalog.COMPONENTS.first().id)
    }
}

class VersionsTest {

    @Test
    fun `tag and versionName compare equal`() {
        assertTrue(Versions.same("2.20.1", "v2.20.1"))
        assertTrue(Versions.same("v2.20.1", "2.20.1"))
    }

    /**
     * The case the browser gate exists for: a locally built runtime reports a
     * git-describe suffix. It is NOT the pinned runtime and must not be treated
     * as one — that pairing is what renders browser 3D black.
     */
    @Test
    fun `a dev build of the pinned version is not the pinned version`() {
        assertTrue(!Versions.same("2.20.1-14-gabc1234", "v2.20.1"))
        assertTrue(!Versions.same(null, "v2.20.1"))
    }

    @Test
    fun `ordering is numeric, not lexicographic`() {
        assertTrue(Versions.compare("2.9.0", "v2.10.0") < 0)   // lexicographically the other way round
        assertTrue(Versions.compare("v2.20.1", "2.20.1") == 0)
        assertTrue(Versions.compare("2.21.0", "v2.20.1") > 0)
    }

    @Test
    fun `an unparseable versionName never claims to be newer`() {
        assertEquals(0, Versions.compare("weird", "weird"))
        assertTrue(Versions.compare("weird", "v2.20.1") < 0)
    }

    @Test
    fun `strip only removes the tag prefix`() {
        assertEquals("2.20.1", Versions.strip("v2.20.1"))
        assertEquals("2.20.1", Versions.strip("2.20.1"))
        assertNull(null)
    }
}
