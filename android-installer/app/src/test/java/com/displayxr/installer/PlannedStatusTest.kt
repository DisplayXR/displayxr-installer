package com.displayxr.installer

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The browser-version findings from the K68 run, pinned as tests.
 *
 * On the tablet the browser row read `pinned v1.0.4 / installed 154.0.8037.17`,
 * concluded "installed is NEWER than the pin" — the only conclusion that
 * comparison can ever reach — and offered to uninstall the tester's browser,
 * dropping its profile, to resolve a conflict that did not exist.
 *
 * So the rule under test is narrow and absolute: an installed version that
 * cannot be compared NEVER yields [RowStatus.NEWER_INSTALLED], because that
 * status is what put a destructive action on screen.
 */
class PlannedStatusTest {

    private val browser = Catalog.COMPONENTS.first { it.id == "browser" }
    private val runtime = Catalog.runtime

    // ---- item 1: the three cases the coordinator asked for -----------------

    /** Stamp present: the APK carries com.displayxr.BROWSER_VERSION, so compare like for like. */
    @Test
    fun `browser with a DisplayXR version stamp compares like for like`() {
        assertEquals(RowStatus.UP_TO_DATE, plannedStatus(Installed.Exact("1.0.4"), "v1.0.4"))
        assertEquals(RowStatus.UPDATE, plannedStatus(Installed.Exact("1.0.3"), "v1.0.4"))
        assertEquals(RowStatus.NEWER_INSTALLED, plannedStatus(Installed.Exact("1.0.5"), "v1.0.4"))
    }

    /** Stamp absent but the package is there: unknown, and offered as an install. */
    @Test
    fun `browser with no stamp is unverifiable, not up to date and not newer`() {
        val status = plannedStatus(Installed.Opaque("Chromium 154.0.8037.17"), "v1.0.4")
        assertEquals(RowStatus.UPDATE_UNVERIFIABLE, status)
        assertTrue("it must still be offered for install", status in PLANNED_STATUSES)
    }

    /**
     * The exact K68 reading. This is the regression: the Chromium versionName
     * must not produce a "newer" verdict, whatever else it produces.
     */
    @Test
    fun `a Chromium versionName never produces a newer verdict`() {
        val chromiumOnly = Installed.Opaque("Chromium 154.0.8037.17")
        assertNotEquals(RowStatus.NEWER_INSTALLED, plannedStatus(chromiumOnly, "v1.0.4"))

        // And the shape that caused it: comparing the raw Chromium number
        // against the pin DOES say "newer", which is why Opaque exists at all.
        assertEquals(
            RowStatus.NEWER_INSTALLED,
            plannedStatus(Installed.Exact("154.0.8037.17"), "v1.0.4"),
        )
    }

    @Test
    fun `a missing package is an install, whatever the component`() {
        assertEquals(RowStatus.INSTALL, plannedStatus(Installed.Absent, "v1.0.4"))
        assertEquals(RowStatus.INSTALL, plannedStatus(Installed.Absent, "v2.20.1"))
    }

    // ---- the catalog wiring that decides which path a component takes ------

    @Test
    fun `only the browser declares a version stamp, and it is the agreed key`() {
        assertEquals(
            listOf("browser"),
            Catalog.COMPONENTS.filter { it.versionStampKey != null }.map { it.id },
        )
        assertEquals("com.displayxr.BROWSER_VERSION", browser.versionStampKey)
        assertEquals("Chromium", browser.opaqueVersionLabel)
    }

    @Test
    fun `the runtime and demos read their version from versionName`() {
        assertEquals(null, runtime.versionStampKey)
        assertTrue(Catalog.COMPONENTS.filter { it.id != "browser" }.all { it.versionStampKey == null })
    }

    // ---- what the row actually says ---------------------------------------

    @Test
    fun `an unreadable version is labelled unknown and still names what IS known`() {
        assertEquals("unknown (Chromium 154.0.8037.17)", Installed.Opaque("Chromium 154.0.8037.17").label())
        assertEquals("not installed", Installed.Absent.label())
        assertEquals("2.20.1", Installed.Exact("2.20.1").label())
    }
}
