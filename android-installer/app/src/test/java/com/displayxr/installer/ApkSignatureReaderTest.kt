package com.displayxr.installer

import com.android.apksig.ApkSigner
import com.android.apksig.SigningCertificateLineage
import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.BeforeClass
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.cert.X509Certificate
import java.util.Date
import java.util.Random
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/**
 * [ApkSignatureReader] against APKs signed AT TEST TIME with apksig (the library apksigner
 * is built on) and throwaway self-signed keys — no vendor bytes and no key in the repo.
 *
 * The case that matters is the first one: a v2-ONLY APK, which is exactly how the vendor
 * display services are signed and exactly what the initial Android 13 framework failed to
 * read through `getPackageArchiveInfo(GET_SIGNING_CERTIFICATES)` (0.4.0 on the NP02J/K68).
 *
 * The real vendor APKs are exercised too, but only when `DXR_SERVICE_APK_DIR` points at a
 * local copy (device-service.apk + headtracking-service.apk) — they are never committed.
 */
class ApkSignatureReaderTest {

    @get:Rule val tmp = TemporaryFolder()

    private class Key(val name: String, val key: PrivateKey, val cert: X509Certificate) {
        val sha256: String get() = hex(MessageDigest.getInstance("SHA-256").digest(cert.encoded))
    }

    companion object {
        private lateinit var rsaA: Key
        private lateinit var rsaB: Key
        private lateinit var ecC: Key

        @BeforeClass @JvmStatic
        fun keys() {
            rsaA = key("A", "RSA", 2048, "SHA256withRSA")
            rsaB = key("B", "RSA", 2048, "SHA256withRSA")
            ecC = key("C", "EC", 256, "SHA256withECDSA")
        }

        private fun key(name: String, alg: String, bits: Int, sigAlg: String): Key {
            val kp = KeyPairGenerator.getInstance(alg).apply { initialize(bits) }.generateKeyPair()
            val dn = X500Name("CN=DisplayXR test signer $name")
            val now = System.currentTimeMillis()
            val holder = JcaX509v3CertificateBuilder(
                dn, BigInteger.valueOf(now), Date(now - 86_400_000L), Date(now + 3_650L * 86_400_000L), dn, kp.public,
            ).build(JcaContentSignerBuilder(sigAlg).build(kp.private))
            return Key(name, kp.private, JcaX509CertificateConverter().getCertificate(holder))
        }

        fun hex(b: ByteArray) = b.joinToString("") { "%02x".format(it) }
    }

    /** A plausible unsigned APK: > 2 MiB so the content digest spans several 1 MiB chunks. */
    private fun unsigned(): File {
        val f = tmp.newFile()
        ZipOutputStream(f.outputStream()).use { z ->
            z.putNextEntry(ZipEntry("AndroidManifest.xml")); z.write("not a real manifest".toByteArray()); z.closeEntry()
            val stored = ByteArray(2_500_000).also { Random(7).nextBytes(it) }
            val e = ZipEntry("classes.dex").apply {
                method = ZipEntry.STORED; size = stored.size.toLong(); compressedSize = stored.size.toLong()
                crc = java.util.zip.CRC32().also { it.update(stored) }.value
            }
            z.putNextEntry(e); z.write(stored); z.closeEntry()
            z.putNextEntry(ZipEntry("res/raw/a.txt")); z.write(ByteArray(50_000) { (it % 7).toByte() }); z.closeEntry()
        }
        return f
    }

    private fun sign(
        vararg signers: Key,
        v1: Boolean = false, v2: Boolean = true, v3: Boolean = false,
        lineage: SigningCertificateLineage? = null, rotationMinSdk: Int? = null,
    ): File {
        val out = tmp.newFile()
        ApkSigner.Builder(signers.map { ApkSigner.SignerConfig.Builder(it.name, it.key, listOf(it.cert)).build() })
            .setInputApk(unsigned()).setOutputApk(out)
            .setMinSdkVersion(24)
            .setV1SigningEnabled(v1).setV2SigningEnabled(v2).setV3SigningEnabled(v3)
            .apply { if (lineage != null) setSigningCertificateLineage(lineage) }
            .apply { if (rotationMinSdk != null) setMinSdkVersionForRotation(rotationMinSdk) }
            .build().sign()
        return out
    }

    private fun verified(r: ApkSignatureReader.Result): ApkSignatureReader.Result.Verified {
        assertTrue("expected Verified, got $r", r is ApkSignatureReader.Result.Verified)
        return r as ApkSignatureReader.Result.Verified
    }

    private fun invalid(r: ApkSignatureReader.Result, containing: String) {
        assertTrue("expected Invalid, got $r", r is ApkSignatureReader.Result.Invalid)
        assertTrue("message was: ${(r as ApkSignatureReader.Result.Invalid).why}", r.why.contains(containing))
    }

    private fun flipByteAt(f: File, offset: Long) {
        java.io.RandomAccessFile(f, "rw").use { raf ->
            raf.seek(offset); val b = raf.read(); raf.seek(offset); raf.write(b xor 0x01)
        }
    }

    private fun indexOf(hay: ByteArray, needle: ByteArray): Int {
        outer@ for (i in 0..hay.size - needle.size) {
            for (j in needle.indices) if (hay[i + j] != needle[j]) continue@outer
            return i
        }
        return -1
    }

    // ---- what it reads -----------------------------------------------------------------

    @Test
    fun `a v2-only APK yields exactly its signer's certificate digest`() {
        val r = verified(ApkSignatureReader.read(sign(rsaA, v2 = true), 33))
        assertEquals("v2", r.scheme)
        assertEquals(listOf(rsaA.sha256), r.certSha256)
        // Every API the installer supports reads it the same way (v2 has no SDK range).
        for (sdk in 29..35) assertEquals(listOf(rsaA.sha256), verified(ApkSignatureReader.read(sign(rsaA), sdk)).certSha256)
    }

    @Test
    fun `an ECDSA v2 signer verifies too`() {
        assertEquals(listOf(ecC.sha256), verified(ApkSignatureReader.read(sign(ecC), 33)).certSha256)
    }

    @Test
    fun `v1 plus v2 reads the v2 block`() {
        val r = verified(ApkSignatureReader.read(sign(rsaA, v1 = true, v2 = true), 31))
        assertEquals("v2", r.scheme)
        assertEquals(listOf(rsaA.sha256), r.certSha256)
    }

    @Test
    fun `v2 plus v3 reads the v3 block`() {
        val r = verified(ApkSignatureReader.read(sign(rsaA, v2 = true, v3 = true), 33))
        assertEquals("v3", r.scheme)
        assertEquals(listOf(rsaA.sha256), r.certSha256)
    }

    @Test
    fun `after a key rotation it is the CURRENT key, as Android compares it`() {
        val lineage = SigningCertificateLineage.Builder(
            SigningCertificateLineage.SignerConfig.Builder(rsaA.key, rsaA.cert).build(),
            SigningCertificateLineage.SignerConfig.Builder(rsaB.key, rsaB.cert).build(),
        ).build()
        // Rotation applied from API 28: v3 carries B (new), v2 still A (old).
        val apk = sign(rsaA, rsaB, v2 = true, v3 = true, lineage = lineage, rotationMinSdk = 28)
        val r = verified(ApkSignatureReader.read(apk, 31))
        assertEquals(listOf(rsaB.sha256), r.certSha256)

        // Rotation targeting API 33 (apksig's default): v3.1 carries B for 33+, v3 keeps A below.
        val apk31 = sign(rsaA, rsaB, v2 = true, v3 = true, lineage = lineage, rotationMinSdk = 33)
        assertEquals(listOf(rsaB.sha256), verified(ApkSignatureReader.read(apk31, 33)).certSha256)
        assertEquals(listOf(rsaA.sha256), verified(ApkSignatureReader.read(apk31, 31)).certSha256)
    }

    @Test
    fun `two v2 signers yield both, and the pin rule refuses that set`() {
        val r = verified(ApkSignatureReader.read(sign(rsaA, rsaB, v2 = true), 33))
        assertEquals(setOf(rsaA.sha256, rsaB.sha256), r.certSha256.toSet())
        assertEquals(2, r.certSha256.size)
        // Even when one of them is the pinned vendor key, a set of two is not the pinned signer.
        val svc = realManifest().services.first { it.packageName == DisplayServices.DEVICE_SERVICE }
        val pinned = DisplayServices.PINNED_SIGNERS.getValue(DisplayServices.DEVICE_SERVICE)
        assertNotNull(DisplayServices.archiveProblem(svc, svc.packageName, svc.versionCode, listOf(pinned, rsaA.sha256)))
    }

    // ---- what it refuses ---------------------------------------------------------------

    @Test
    fun `a v1-only APK has no signing block - Android must answer, not this reader`() {
        val r = ApkSignatureReader.read(sign(rsaA, v1 = true, v2 = false), 33)
        assertTrue("got $r", r is ApkSignatureReader.Result.NoSigningBlock)
    }

    @Test
    fun `an unsigned APK has no signing block`() {
        assertTrue(ApkSignatureReader.read(unsigned(), 33) is ApkSignatureReader.Result.NoSigningBlock)
    }

    @Test
    fun `a file that is not a ZIP has no signing block`() {
        val f = tmp.newFile().apply { writeBytes(ByteArray(4096) { 0x41 }) }
        assertTrue(ApkSignatureReader.read(f, 33) is ApkSignatureReader.Result.NoSigningBlock)
    }

    @Test
    fun `one byte changed in the contents after signing is refused`() {
        val apk = sign(rsaA)
        flipByteAt(apk, 1_500_000) // inside classes.dex, in the second 1 MiB chunk
        invalid(ApkSignatureReader.read(apk, 33), "modified after signing")
    }

    @Test
    fun `one byte changed in the central directory is refused`() {
        val apk = sign(rsaA)
        val bytes = apk.readBytes()
        val cd = indexOf(bytes, byteArrayOf(0x50, 0x4b, 0x01, 0x02)) // first central-directory header
        assertTrue(cd > 0)
        flipByteAt(apk, cd + 30L + 4) // inside a file name
        invalid(ApkSignatureReader.read(apk, 33), "modified after signing")
    }

    @Test
    fun `a certificate altered inside the signing block is refused`() {
        // The forgery that matters: someone else's certificate in the block, without their key.
        val apk = sign(rsaA)
        val bytes = apk.readBytes()
        val at = indexOf(bytes, rsaA.cert.encoded)
        assertTrue(at > 0)
        flipByteAt(apk, at + rsaA.cert.encoded.size - 3L) // in the cert's own signature: still parses
        invalid(ApkSignatureReader.read(apk, 33), "does not verify")
    }

    @Test
    fun `a truncated APK is refused or unreadable, never Verified`() {
        val apk = sign(rsaA)
        val cut = tmp.newFile().apply { writeBytes(apk.readBytes().copyOf(apk.length().toInt() - 10)) }
        val r = ApkSignatureReader.read(cut, 33)
        assertTrue("got $r", r !is ApkSignatureReader.Result.Verified)
    }

    // ---- combining with what Android says ----------------------------------------------

    @Test
    fun `the Android 13 case - platform empty, reader verified - uses the reader`() {
        val v = ApkSignatureReader.Result.Verified("v2", listOf(rsaA.sha256))
        assertEquals(SignerReading(listOf(rsaA.sha256), null), DisplayServices.combineSigners(v, emptyList()))
        assertEquals(SignerReading(listOf(rsaA.sha256), null), DisplayServices.combineSigners(v, listOf(rsaA.sha256.uppercase())))
    }

    @Test
    fun `platform and reader disagreeing is refused`() {
        val v = ApkSignatureReader.Result.Verified("v2", listOf(rsaA.sha256))
        val r = DisplayServices.combineSigners(v, listOf(rsaB.sha256))
        assertTrue(r.signers.isEmpty())
        assertNotNull(r.problem)
    }

    @Test
    fun `an invalid block is refused whatever Android says`() {
        val r = DisplayServices.combineSigners(ApkSignatureReader.Result.Invalid("tampered"), listOf(rsaA.sha256))
        assertTrue(r.signers.isEmpty())
        assertEquals("tampered", r.problem)
        val svc = realManifest().services.first()
        val why = DisplayServices.archiveProblem(svc, svc.packageName, svc.versionCode, r.signers, r.problem)!!
        assertTrue(why, why.contains("tampered") && why.contains("could not be verified"))
    }

    @Test
    fun `no signing block falls back to Android, and nothing from either is still refused`() {
        val none = ApkSignatureReader.Result.NoSigningBlock("v1 only")
        assertEquals(listOf(rsaA.sha256), DisplayServices.combineSigners(none, listOf(rsaA.sha256)).signers)
        val empty = DisplayServices.combineSigners(none, emptyList())
        assertTrue(empty.signers.isEmpty())
        val svc = realManifest().services.first()
        assertNotNull(DisplayServices.archiveProblem(svc, svc.packageName, svc.versionCode, empty.signers, empty.problem))
    }

    @Test
    fun `a synthetic signer that verifies is still not the vendor key`() {
        val svc = realManifest().services.first()
        val r = DisplayServices.combineSigners(ApkSignatureReader.read(sign(rsaA), 33), emptyList())
        assertEquals(listOf(rsaA.sha256), r.signers)
        assertTrue(DisplayServices.archiveProblem(svc, svc.packageName, svc.versionCode, r.signers, r.problem)!!.contains("Refused"))
    }

    // ---- the real vendor APKs, local only ----------------------------------------------

    private fun realManifest(): ServiceManifest {
        val json = javaClass.classLoader!!.getResource("services-manifest-v0.10.69.json")!!.readText()
        return DisplayServices.parseManifest(json, DisplayServices.manifestUrl("v0.10.69"), "v0.10.69")
    }

    @Test
    fun `the real vendor services read as their pinned certificates (local, DXR_SERVICE_APK_DIR)`() {
        val dir = System.getenv("DXR_SERVICE_APK_DIR")?.let(::File)
        assumeTrue("DXR_SERVICE_APK_DIR not set — vendor APKs are never committed", dir != null && dir.isDirectory)
        val files = mapOf(
            DisplayServices.DEVICE_SERVICE to File(dir, "device-service.apk"),
            DisplayServices.HEADTRACKING to File(dir, "headtracking-service.apk"),
        )
        val m = realManifest()
        for ((pkg, f) in files) {
            for (sdk in listOf(29, 31, 33, 35)) {
                val r = verified(ApkSignatureReader.read(f, sdk))
                assertEquals("v2", r.scheme)
                assertEquals(listOf(DisplayServices.PINNED_SIGNERS.getValue(pkg)), r.certSha256)
                println("REAL $pkg api$sdk ${r.scheme} ${r.certSha256}")
            }
            // End to end through the same decision the app makes, with Android 13's empty answer.
            val svc = m.services.first { it.packageName == pkg }
            val reading = DisplayServices.combineSigners(ApkSignatureReader.read(f, 33), emptyList())
            assertNull(DisplayServices.archiveProblem(svc, pkg, svc.versionCode, reading.signers, reading.problem))
        }
    }
}
