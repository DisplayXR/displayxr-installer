package com.displayxr.installer

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File
import java.security.MessageDigest

/**
 * The display services, fetched from updates.displayxr.org: the manifest, the
 * verification of what was downloaded, which devices get them, in what order, and what
 * the owner is told when they could not be updated.
 *
 * The fixture is the REAL manifest `scripts/make-services-manifest.sh` wrote from the
 * pinned CNSDK v0.10.69 APKs — every digest in it was computed from the files, so a
 * parser that rejects it would reject the published one.
 */
class DisplayServicesTest {

    private val tag = "v0.10.69"
    private val url = DisplayServices.manifestUrl(tag)
    private val real: String =
        javaClass.classLoader!!.getResource("services-manifest-v0.10.69.json")!!.readText()

    private fun parse(json: String = real, pin: String = tag) = DisplayServices.parseManifest(json, url, pin)

    /** The real manifest with one edit applied to its JSON tree. */
    private fun edited(edit: (JSONObject) -> Unit): String = JSONObject(real).also(edit).toString()

    private fun rejects(json: String, containing: String, pin: String = tag) {
        try {
            parse(json, pin)
            fail("expected the manifest to be refused ($containing)")
        } catch (e: ServiceManifestException) {
            assertTrue("message was: ${e.message}", e.message!!.contains(containing))
        }
    }

    // ---- the manifest ----------------------------------------------------------

    @Test
    fun `the real published manifest parses, in install order, with absolute URLs`() {
        val m = parse()
        assertEquals("v0.10.69", m.tag)
        assertEquals("0.10.69+193.8291a2e", m.build)
        assertEquals(listOf(DisplayServices.DEVICE_SERVICE, DisplayServices.HEADTRACKING), m.services.map { it.packageName })
        val ds = m.services[0]
        assertEquals(290010069L, ds.versionCode)
        assertEquals(13888346L, ds.size)
        assertEquals("0da2c8fca7a263af8228bc8a168e9335959cfe4bbeac8a6bd3440dcd52d29f35", ds.sha256)
        assertEquals("https://updates.displayxr.org/services/cnsdk/v0.10.69/device-service.apk", ds.url)
        assertEquals(300010069L, m.services[1].versionCode)
        assertEquals(
            listOf("LICENSE.txt", "LICENSE-3RD-PARTY.txt", "ZMQ.AUTHORS.txt", "SIMDJSON.AUTHORS.txt"),
            m.licenses.map { it.name },
        )
        assertEquals("https://updates.displayxr.org/services/cnsdk/v0.10.69/LICENSE.txt", m.licenses[0].url)
    }

    @Test
    fun `the manifest URL is derived from the pinned tag`() {
        assertEquals("https://updates.displayxr.org/services/cnsdk/v0.10.70/manifest.json", DisplayServices.manifestUrl("v0.10.70"))
    }

    @Test
    fun `device-service is first whatever order the manifest lists them in`() {
        val swapped = edited { o ->
            val a = o.getJSONArray("services")
            val first = a.getJSONObject(0)
            a.put(0, a.getJSONObject(1)); a.put(1, first)
        }
        assertEquals(DisplayServices.DEVICE_SERVICE, parse(swapped).services[0].packageName)
    }

    @Test
    fun `a manifest for another release than the pin is refused`() {
        rejects(real, "pins v0.10.70", pin = "v0.10.70")
    }

    @Test
    fun `a versionName that is not the tag is refused`() {
        rejects(edited { it.getJSONArray("services").getJSONObject(1).put("versionName", "0.10.68") }, "versionName 0.10.68")
    }

    @Test
    fun `a manifest claiming a different signing key is refused before anything is downloaded`() {
        rejects(edited { it.getJSONArray("services").getJSONObject(0).put("signer_sha256", "e".repeat(64)) }, "not the vendor key")
    }

    @Test
    fun `only one of the two services is refused, not half-installed`() {
        rejects(edited { it.getJSONArray("services").remove(1) }, DisplayServices.HEADTRACKING)
    }

    @Test
    fun `any other package is refused`() {
        rejects(
            edited { it.getJSONArray("services").getJSONObject(1).put("package", "com.example.evil") },
            "com.example.evil",
        )
    }

    @Test
    fun `a package listed twice is refused`() {
        rejects(edited { o -> o.getJSONArray("services").put(o.getJSONArray("services").getJSONObject(0)) }, "twice")
    }

    @Test
    fun `malformed fields are refused with a sentence`() {
        rejects("not json", "not valid JSON")
        rejects(edited { it.put("schema", 2) }, "schema 2")
        rejects(edited { it.remove("cnsdk_tag") }, "missing a field")
        rejects(edited { it.getJSONArray("services").getJSONObject(0).put("sha256", "abc") }, "64 hex")
        rejects(edited { it.getJSONArray("services").getJSONObject(0).put("size", 0) }, "size 0")
        rejects(edited { it.getJSONArray("services").getJSONObject(0).put("versionCode", -1) }, "versionCode -1")
    }

    @Test
    fun `file names cannot escape the manifest's directory`() {
        for (bad in listOf("../x.apk", "/etc/x.apk", "https://evil.example/x.apk", ".hidden.apk", "a\\b.apk")) {
            rejects(edited { it.getJSONArray("services").getJSONObject(0).put("file", bad) }, "bad file name")
        }
        rejects(edited { it.getJSONArray("licenses").getJSONObject(0).put("file", "../../x") }, "bad file name")
    }

    // ---- the pin in the app == the pin the publisher enforces ---------------------

    @Test
    fun `the app's pinned certificates are the ones the publishing script enforces`() {
        // Unit tests run with the module directory (app/) as the working directory.
        val tsv = File("../scripts/service-signers.tsv")
        assertTrue("missing $tsv", tsv.isFile)
        val rows = tsv.readLines().filter { it.isNotBlank() && !it.startsWith("#") }.map { it.split('\t') }
        assertEquals(DisplayServices.SERVICE_ORDER, rows.map { it[1] })
        assertEquals(DisplayServices.PINNED_SIGNERS, rows.associate { it[1] to it[2] })
        // And the real manifest agrees with both.
        parse().services.forEach { assertEquals(DisplayServices.PINNED_SIGNERS[it.packageName], it.signerSha256) }
    }

    // ---- verifying what was downloaded -------------------------------------------

    private fun sha(b: ByteArray) = MessageDigest.getInstance("SHA-256").digest(b).joinToString("") { "%02x".format(it) }

    private fun apkFor(bytes: ByteArray, pkg: String = DisplayServices.DEVICE_SERVICE) = ServiceApk(
        packageName = pkg,
        fileName = "device-service.apk",
        url = "https://updates.displayxr.org/services/cnsdk/v0.10.69/device-service.apk",
        versionName = "0.10.69",
        versionCode = 290010069,
        sha256 = sha(bytes),
        size = bytes.size.toLong(),
        signerSha256 = DisplayServices.PINNED_SIGNERS.getValue(pkg),
    )

    @Test
    fun `an intact download passes size and sha256`() {
        val bytes = ByteArray(300_000) { (it * 31).toByte() }
        val f = File.createTempFile("svc", ".apk").apply { writeBytes(bytes) }
        DisplayServices.verifyFile(f, apkFor(bytes))
        assertTrue(f.exists())
        f.delete()
    }

    @Test
    fun `a truncated or substituted download is refused and deleted`() {
        val bytes = ByteArray(10_000) { it.toByte() }
        val apk = apkFor(bytes)
        val f = File.createTempFile("svc", ".apk")

        f.writeBytes(bytes.copyOf(9_000))
        try {
            DisplayServices.verifyFile(f, apk); fail("a truncated download must not reach the package installer")
        } catch (e: ServiceVerificationException) {
            assertTrue(e.message!!.contains("nothing was installed"))
        }
        assertFalse(f.exists())

        f.writeBytes(bytes.copyOf().also { it[5] = 99 })  // same size, different bytes
        try {
            DisplayServices.verifyFile(f, apk); fail("a substituted download must not reach the package installer")
        } catch (e: ServiceVerificationException) {
            assertTrue(e.message!!.contains("sha256"))
        }
        assertFalse(f.exists())
    }

    @Test
    fun `the archive must be the pinned package, versionCode and vendor key`() {
        val apk = apkFor(ByteArray(1))
        val key = DisplayServices.PINNED_SIGNERS.getValue(DisplayServices.DEVICE_SERVICE)
        assertNull(DisplayServices.archiveProblem(apk, DisplayServices.DEVICE_SERVICE, 290010069, listOf(key)))
        assertNull(DisplayServices.archiveProblem(apk, DisplayServices.DEVICE_SERVICE, 290010069, listOf(key.uppercase())))

        assertNotNull(DisplayServices.archiveProblem(apk, null, null, emptyList()))
        assertTrue(DisplayServices.archiveProblem(apk, "com.example.evil", 290010069, listOf(key))!!.contains("com.example.evil"))
        assertTrue(DisplayServices.archiveProblem(apk, DisplayServices.DEVICE_SERVICE, 290010068, listOf(key))!!.contains("290010068"))
        // Unreadable signer: refused, never assumed.
        assertTrue(DisplayServices.archiveProblem(apk, DisplayServices.DEVICE_SERVICE, 290010069, emptyList())!!.contains("could not read"))
        // Wrong key — including the OTHER service's legitimate key.
        val other = DisplayServices.PINNED_SIGNERS.getValue(DisplayServices.HEADTRACKING)
        assertTrue(DisplayServices.archiveProblem(apk, DisplayServices.DEVICE_SERVICE, 290010069, listOf(other))!!.contains("Refused"))
        // An extra signer alongside the right one is not the pinned signer set.
        assertNotNull(DisplayServices.archiveProblem(apk, DisplayServices.DEVICE_SERVICE, 290010069, listOf(key, other)))
    }

    // ---- which devices ---------------------------------------------------------------

    @Test
    fun `service rows exist only where device-service shipped as a system app`() {
        assertTrue(DisplayServices.isTargetDevice(true))
        assertFalse("not installed: an ordinary phone", DisplayServices.isTargetDevice(null))
        assertFalse("sideloaded, not in the OEM image", DisplayServices.isTargetDevice(false))
    }

    @Test
    fun `a non-3D device gets exactly the stack, no service rows`() {
        assertEquals(Catalog.COMPONENTS, Catalog.components(targetDevice = false))
        assertEquals(Catalog.COMPONENTS, Catalog.components(targetDevice = false, manifest = parse()))
        assertTrue(Catalog.components(false).none { Catalog.isService(it) })
    }

    // ---- ordering ------------------------------------------------------------------

    @Test
    fun `on a 3D tablet the services come first, device-service before head tracking, then the runtime`() {
        for (m in listOf(parse(), null)) {  // with and without a readable manifest
            val ids = Catalog.components(targetDevice = true, manifest = m).map { it.id }
            assertEquals(
                listOf("service:com.leialoft.display.config", "service:com.leia.headtrackingservice", "runtime"),
                ids.take(3),
            )
            assertEquals(Catalog.COMPONENTS.map { it.id }, ids.drop(2))
        }
        val withManifest = Catalog.components(true, parse())
        assertNotNull(withManifest[0].service)
        assertNull("no manifest, nothing to download", Catalog.components(true, null)[0].service)
        assertTrue(withManifest.drop(2).all { it.service == null })
    }

    @Test
    fun `row ids and package names stay distinct once services are added`() {
        val all = Catalog.components(true, parse())
        assertEquals(all.size, all.map { it.id }.toSet().size)
        assertEquals(all.size, all.map { it.packageName }.toSet().size)
    }

    // ---- failure states: what the owner is told ---------------------------------------

    private val factory = mapOf(
        DisplayServices.DEVICE_SERVICE to Installed.Exact("0.8.29", 290008029),   // NP02J factory
        DisplayServices.HEADTRACKING to Installed.Exact("0.8.20", 300008020),
    )
    private val current = mapOf(
        DisplayServices.DEVICE_SERVICE to Installed.Exact("0.10.69", 290010069),
        DisplayServices.HEADTRACKING to Installed.Exact("0.10.69", 300010069),
    )

    @Test
    fun `a factory core is stale, with or without the manifest`() {
        assertEquals(DisplayServices.SERVICE_ORDER, DisplayServices.staleServices(factory, tag, parse()))
        // Host unreachable: decided on versionName, which for these packages IS the CNSDK release.
        assertEquals(DisplayServices.SERVICE_ORDER, DisplayServices.staleServices(factory, tag, null))
    }

    @Test
    fun `current services are not stale`() {
        assertTrue(DisplayServices.staleServices(current, tag, parse()).isEmpty())
        assertTrue(DisplayServices.staleServices(current, tag, null).isEmpty())
        val newer = mapOf(
            DisplayServices.DEVICE_SERVICE to Installed.Exact("0.10.70", 290010070),
            DisplayServices.HEADTRACKING to Installed.Exact("0.10.70", 300010070),
        )
        assertTrue(DisplayServices.staleServices(newer, tag, parse()).isEmpty())
    }

    @Test
    fun `only device-service updated still leaves head tracking stale, and a missing one is stale`() {
        val half = mapOf(
            DisplayServices.DEVICE_SERVICE to current.getValue(DisplayServices.DEVICE_SERVICE),
            DisplayServices.HEADTRACKING to factory.getValue(DisplayServices.HEADTRACKING),
        )
        assertEquals(listOf(DisplayServices.HEADTRACKING), DisplayServices.staleServices(half, tag, parse()))
        assertEquals(listOf(DisplayServices.HEADTRACKING), DisplayServices.staleServices(mapOf(DisplayServices.DEVICE_SERVICE to current.getValue(DisplayServices.DEVICE_SERVICE)), tag, parse()))
    }

    @Test
    fun `an unreadable version is never called stale`() {
        val opaque = current + (DisplayServices.HEADTRACKING to Installed.Opaque("?"))
        assertTrue(DisplayServices.staleServices(opaque, tag, parse()).isEmpty())
    }

    @Test
    fun `versionCode decides stale when the manifest is known, not versionName`() {
        // Sorts higher by name, lower by code: Android would install the pin over it.
        val odd = current + (DisplayServices.DEVICE_SERVICE to Installed.Exact("9.9.9", 290010000))
        assertEquals(listOf(DisplayServices.DEVICE_SERVICE), DisplayServices.staleServices(odd, tag, parse()))
    }

    @Test
    fun `the warning says 3D will not work and names what is installed and what is needed`() {
        val w = DisplayServices.staleWarning(DisplayServices.SERVICE_ORDER, factory, tag)
        assertTrue(w.startsWith("3D WILL NOT WORK CORRECTLY"))
        assertTrue(w.contains("installed 0.8.29"))
        assertTrue(w.contains("installed 0.8.20"))
        assertTrue(w.contains("CNSDK 0.10.69"))
    }
}

/**
 * Installed-vs-pinned for the display services. "Newer" is claimed only on Android's
 * own downgrade rule (versionCode), never on a versionName.
 */
class ServicePlannedStatusTest {

    private val pinned = ServiceApk(
        packageName = DisplayServices.DEVICE_SERVICE,
        fileName = "device-service.apk",
        url = "https://updates.displayxr.org/services/cnsdk/v0.10.69/device-service.apk",
        versionName = "0.10.69",
        versionCode = 290010069,
        sha256 = "a".repeat(64),
        size = 1,
        signerSha256 = DisplayServices.PINNED_SIGNERS.getValue(DisplayServices.DEVICE_SERVICE),
    )

    @Test
    fun `absent is an install`() {
        assertEquals(RowStatus.INSTALL, servicePlannedStatus(Installed.Absent, pinned))
    }

    @Test
    fun `the factory build is an update`() {
        // NP02J factory device-service; Lume Pad 2 factory is 0.8.20; Lume Phone 0.10.64.
        assertEquals(RowStatus.UPDATE, servicePlannedStatus(Installed.Exact("0.8.29", 290008029), pinned))
        assertEquals(RowStatus.UPDATE, servicePlannedStatus(Installed.Exact("0.10.64", 290010064), pinned))
    }

    @Test
    fun `the pinned build already installed is up to date`() {
        assertEquals(RowStatus.UP_TO_DATE, servicePlannedStatus(Installed.Exact("0.10.69", 290010069), pinned))
    }

    @Test
    fun `a higher versionCode is newer, because that is exactly what Android refuses`() {
        assertEquals(RowStatus.NEWER_INSTALLED, servicePlannedStatus(Installed.Exact("0.10.70", 290010070), pinned))
    }

    @Test
    fun `versionName never decides newer`() {
        assertEquals(RowStatus.UPDATE, servicePlannedStatus(Installed.Exact("9.9.9", 290010000), pinned))
        val noCode = servicePlannedStatus(Installed.Exact("9.9.9", null), pinned)
        assertNotEquals(RowStatus.NEWER_INSTALLED, noCode)
        assertEquals(RowStatus.UPDATE_UNVERIFIABLE, noCode)
        assertEquals(RowStatus.UP_TO_DATE, servicePlannedStatus(Installed.Exact("0.10.69", null), pinned))
    }

    @Test
    fun `same versionCode with a different name is offered, not asserted`() {
        val s = servicePlannedStatus(Installed.Exact("0.10.69-dev", 290010069), pinned)
        assertEquals(RowStatus.UPDATE_UNVERIFIABLE, s)
        assertTrue(s in PLANNED_STATUSES)
    }
}
