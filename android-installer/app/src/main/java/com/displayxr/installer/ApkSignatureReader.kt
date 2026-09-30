package com.displayxr.installer

import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.PublicKey
import java.security.Signature
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.security.spec.MGF1ParameterSpec
import java.security.spec.PSSParameterSpec
import java.security.spec.X509EncodedKeySpec

/**
 * Reads AND verifies the signer certificate(s) of an APK from its APK Signing Block
 * (APK Signature Scheme v2 / v3 / v3.1) — without asking Android.
 *
 * Why it exists: on the NP02J/K68 (Android 13, API 33) a display-service APK signed with
 * v2 only came back from `getPackageArchiveInfo(path, GET_SIGNING_CERTIFICATES)` with a
 * null `signingInfo`, and the installer refused the very update the tablet needed. The
 * cause is in the platform, not the file: in `android13-release` (the initial Android 13
 * framework) `PackageManager.getPackageArchiveInfo` calls `PackageParser.collectCertificates`
 * only when the flags contain the DEPRECATED `GET_SIGNATURES`; `GET_SIGNING_CERTIFICATES`
 * alone leaves `SigningDetails.UNKNOWN`, and `generatePackageInfo` turns that into
 * `signingInfo = null`. Android 12's `ApplicationPackageManager` and `android13-qpr1` onward
 * test either flag. So the answer depends on the tablet's framework build — the reason the
 * installer no longer rests this check on `getPackageArchiveInfo` alone.
 *
 * This is a verifier, not just a parser: a certificate pasted into a forged signing block
 * without the key must not read as "signed by the vendor". For the signer(s) the platform
 * would use on [sdkInt] it checks, like `ApkSignatureSchemeV2Verifier`/`V3Verifier`:
 *  - the signature over the signed data, with the signer's public key;
 *  - that public key equals the first certificate's;
 *  - the signature algorithms and the digest algorithms list the same IDs;
 *  - the whole-file content digest (1 MiB chunks over the three ZIP sections) equals the
 *    signed one — so a single flipped byte anywhere in the APK is refused.
 *
 * Scheme choice mirrors the platform: v3.1 when it has a signer for [sdkInt] (key rotation
 * targeting API 33+), else v3 when it has one, else v2. v3 carries the CURRENT key after a
 * rotation, v2 the original one, so the certificate returned is the one Android will
 * compare against the installed app's key. v1 (JAR) signatures are not read here: an APK
 * with no signing block is [Result.NoSigningBlock] and the caller falls back to Android.
 *
 * Pure JVM (java.io + java.security), so it is covered by JVM tests on real signed APKs.
 */
object ApkSignatureReader {

    sealed class Result {
        /** @param certSha256 lowercase hex SHA-256 of each verified signer's certificate (DER as stored). */
        data class Verified(val scheme: String, val certSha256: List<String>) : Result()

        /** No APK Signing Block, or none of v2/v3/v3.1 in it (e.g. a v1-only or unsigned APK). */
        data class NoSigningBlock(val why: String) : Result()

        /** Signed with only algorithms this reader does not implement; Android must decide. */
        data class Unsupported(val why: String) : Result()

        /** A signing block that does not verify: tampered, truncated or forged. Refuse. */
        data class Invalid(val why: String) : Result()
    }

    const val V2_BLOCK_ID = 0x7109871a
    const val V3_BLOCK_ID = 0xf05368c0.toInt()
    const val V31_BLOCK_ID = 0x1b93ad61

    private const val EOCD_MAGIC = 0x06054b50
    private const val EOCD_MIN = 22
    private const val MAGIC_LO = 0x20676953204b5041L // "APK Sig "
    private const val MAGIC_HI = 0x3234206b636f6c42L // "Block 42"
    private const val CHUNK = 1024 * 1024

    private class Malformed(msg: String) : Exception(msg)

    fun read(apk: File, sdkInt: Int): Result = try {
        RandomAccessFile(apk, "r").use { readImpl(it, sdkInt) }
    } catch (e: Malformed) {
        Result.Invalid(e.message ?: "malformed signing block")
    } catch (e: IOException) {
        Result.Invalid("could not read the file (${e.message})")
    }

    // ------------------------------------------------------------------ ZIP + block

    private class Layout(val sigBlockStart: Long, val cdOffset: Long, val eocdOffset: Long, val eocd: ByteArray)

    private fun readImpl(f: RandomAccessFile, sdkInt: Int): Result {
        val len = f.length()
        if (len < EOCD_MIN) return Result.NoSigningBlock("not a ZIP archive")
        // EOCD: scan back over at most a 65535-byte comment.
        val tailLen = minOf(len, (EOCD_MIN + 0xffff).toLong()).toInt()
        val tail = ByteArray(tailLen).also { f.seek(len - tailLen); f.readFully(it) }
        val tb = ByteBuffer.wrap(tail).order(ByteOrder.LITTLE_ENDIAN)
        var eocdPos = -1
        var i = tailLen - EOCD_MIN
        while (i >= 0) {
            if (tb.getInt(i) == EOCD_MAGIC && (tb.getShort(i + 20).toInt() and 0xffff) == tailLen - i - EOCD_MIN) {
                eocdPos = i; break
            }
            i--
        }
        if (eocdPos < 0) return Result.NoSigningBlock("not a ZIP archive (no end-of-central-directory record)")
        val eocdOffset = len - tailLen + eocdPos
        val eocd = tail.copyOfRange(eocdPos, tailLen)
        val cdOffset = tb.getInt(eocdPos + 16).toLong() and 0xffffffffL
        val cdSize = tb.getInt(eocdPos + 12).toLong() and 0xffffffffL
        if (cdOffset + cdSize != eocdOffset) throw Malformed("the central directory does not end at the end-of-central-directory record")
        if (cdOffset < 32) return Result.NoSigningBlock("no APK Signing Block")

        // Footer: u64 size, then the 16-byte magic, immediately before the central directory.
        val footer = ByteArray(24).also { f.seek(cdOffset - 24); f.readFully(it) }
        val fb = ByteBuffer.wrap(footer).order(ByteOrder.LITTLE_ENDIAN)
        if (fb.getLong(8) != MAGIC_LO || fb.getLong(16) != MAGIC_HI) {
            return Result.NoSigningBlock("no APK Signing Block (v1-signed or unsigned)")
        }
        val blockSize = fb.getLong(0)
        if (blockSize < 24 || blockSize > Int.MAX_VALUE - 8) throw Malformed("APK Signing Block size $blockSize is out of range")
        val sigBlockStart = cdOffset - blockSize - 8
        if (sigBlockStart < 0) throw Malformed("APK Signing Block starts before the file")
        val block = ByteArray((blockSize + 8).toInt()).also { f.seek(sigBlockStart); f.readFully(it) }
        val bb = ByteBuffer.wrap(block).order(ByteOrder.LITTLE_ENDIAN)
        if (bb.getLong(0) != blockSize) throw Malformed("APK Signing Block sizes disagree")

        // id-value pairs between the leading size and the footer.
        val pairs = HashMap<Int, ByteBuffer>()
        val pairsEnd = block.size - 24
        var p = 8
        while (p < pairsEnd) {
            if (pairsEnd - p < 8) throw Malformed("truncated id-value pair")
            val pl = bb.getLong(p)
            if (pl < 4 || pl > pairsEnd - p - 8) throw Malformed("id-value pair length $pl is out of range")
            val id = bb.getInt(p + 8)
            pairs.putIfAbsent(id, slice(bb, p + 12, (pl - 4).toInt()))
            p += 8 + pl.toInt()
        }

        val layout = Layout(sigBlockStart, cdOffset, eocdOffset, eocd)
        val candidates = listOf(
            Triple(V31_BLOCK_ID, "v3.1", true),
            Triple(V3_BLOCK_ID, "v3", true),
            Triple(V2_BLOCK_ID, "v2", false),
        )
        for ((id, name, isV3) in candidates) {
            val value = pairs[id] ?: continue
            val signers = parseSigners(value, isV3, sdkInt)
            if (signers.isEmpty()) continue // v3/v3.1 with no signer for this SDK: the platform falls through
            if (isV3 && signers.size != 1) throw Malformed("$name has ${signers.size} signers for API $sdkInt")
            return verify(f, layout, name, signers)
        }
        return Result.NoSigningBlock("the APK Signing Block has no v2/v3 signature")
    }

    // ------------------------------------------------------------------ signers

    private class SignerRec(
        val signedData: ByteArray,
        val digests: Map<Int, ByteArray>,
        val certs: List<ByteArray>,
        val signatures: List<Pair<Int, ByteArray>>,
        val publicKey: ByteArray,
    )

    private fun parseSigners(value: ByteBuffer, isV3: Boolean, sdkInt: Int): List<SignerRec> {
        val signersSeq = lp(value.duplicate().order(ByteOrder.LITTLE_ENDIAN))
        val out = ArrayList<SignerRec>()
        var count = 0
        while (signersSeq.hasRemaining()) {
            count++
            val signer = lp(signersSeq)
            val signedDataBuf = lp(signer)
            val signedData = bytes(signedDataBuf.duplicate())
            if (isV3) {
                val minSdk = u32(signer); val maxSdk = u32(signer)
                if (sdkInt < minSdk || sdkInt > maxSdk) {
                    // Parse the rest only to stay aligned; this signer is for another SDK.
                    lp(signer); lp(signer)
                    continue
                }
            }
            val sigsSeq = lp(signer)
            val publicKey = bytes(lp(signer))

            val sd = signedDataBuf.duplicate().order(ByteOrder.LITTLE_ENDIAN)
            val digestsSeq = lp(sd)
            val certsSeq = lp(sd)
            val digests = LinkedHashMap<Int, ByteArray>()
            while (digestsSeq.hasRemaining()) {
                val d = lp(digestsSeq); val alg = d.int; digests[alg] = bytes(lp(d))
            }
            val certs = ArrayList<ByteArray>()
            while (certsSeq.hasRemaining()) certs.add(bytes(lp(certsSeq)))
            if (isV3) {
                val sdMin = u32(sd); val sdMax = u32(sd)
                if (sdMin > sdkInt || sdMax < sdkInt) throw Malformed("v3 signed data SDK range disagrees with the signer's")
            }
            val sigs = ArrayList<Pair<Int, ByteArray>>()
            while (sigsSeq.hasRemaining()) {
                val s = lp(sigsSeq); val alg = s.int; sigs.add(alg to bytes(lp(s)))
            }
            out.add(SignerRec(signedData, digests, certs, sigs, publicKey))
        }
        if (count == 0) throw Malformed("a signature scheme block with no signers")
        return out
    }

    private enum class Alg(val digest: String, val strength: Int) { SHA256("SHA-256", 1), SHA512("SHA-512", 2) }

    private fun contentDigestOf(alg: Int): Alg? = when (alg) {
        0x0101, 0x0103, 0x0201, 0x0301 -> Alg.SHA256
        0x0102, 0x0104, 0x0202 -> Alg.SHA512
        else -> null // incl. the verity variants 0x0421/0x0423/0x0425
    }

    private fun verifySignature(alg: Int, key: PublicKey, data: ByteArray, sig: ByteArray): Boolean {
        val s: Signature = when (alg) {
            0x0101 -> pss("SHA-256", MGF1ParameterSpec.SHA256, 32)
            0x0102 -> pss("SHA-512", MGF1ParameterSpec.SHA512, 64)
            0x0103 -> Signature.getInstance("SHA256withRSA")
            0x0104 -> Signature.getInstance("SHA512withRSA")
            0x0201 -> Signature.getInstance("SHA256withECDSA")
            0x0202 -> Signature.getInstance("SHA512withECDSA")
            0x0301 -> Signature.getInstance("SHA256withDSA")
            else -> return false
        }
        s.initVerify(key)
        s.update(data)
        return s.verify(sig)
    }

    private fun pss(md: String, mgf: MGF1ParameterSpec, salt: Int): Signature {
        val spec = PSSParameterSpec(md, "MGF1", mgf, salt, 1)
        // Android (Conscrypt) names it "SHA256withRSA/PSS"; the JDK "RSASSA-PSS".
        return try {
            Signature.getInstance(md.replace("-", "") + "withRSA/PSS").also { it.setParameter(spec) }
        } catch (e: Exception) {
            Signature.getInstance("RSASSA-PSS").also { it.setParameter(spec) }
        }
    }

    private fun publicKeyOf(encoded: ByteArray): PublicKey {
        for (kf in listOf("RSA", "EC", "DSA")) {
            try {
                return KeyFactory.getInstance(kf).generatePublic(X509EncodedKeySpec(encoded))
            } catch (e: Exception) { /* next */ }
        }
        throw Malformed("a signer's public key is not RSA, EC or DSA")
    }

    private fun verify(f: RandomAccessFile, layout: Layout, scheme: String, signers: List<SignerRec>): Result {
        val wanted = HashMap<Alg, ByteArray>() // content digest each signer's strongest algorithm commits to
        val certDigests = ArrayList<String>()
        for (s in signers) {
            if (s.signatures.isEmpty()) throw Malformed("$scheme signer has no signatures")
            if (s.certs.isEmpty()) throw Malformed("$scheme signer has no certificate")
            if (s.signatures.map { it.first } != s.digests.keys.toList()) {
                throw Malformed("$scheme signature and digest algorithm lists differ")
            }
            val best = s.signatures.filter { contentDigestOf(it.first) != null }
                .maxByOrNull { contentDigestOf(it.first)!!.strength }
                ?: return Result.Unsupported("$scheme signer uses only signature algorithms " +
                    s.signatures.joinToString { "0x%04x".format(it.first) } + " this installer does not verify")
            val key = publicKeyOf(s.publicKey)
            val ok = try { verifySignature(best.first, key, s.signedData, best.second) } catch (e: Exception) { false }
            if (!ok) throw Malformed("$scheme signature over the signed data does not verify")

            val cert = try {
                CertificateFactory.getInstance("X.509")
                    .generateCertificate(ByteArrayInputStream(s.certs[0])) as X509Certificate
            } catch (e: Exception) {
                throw Malformed("$scheme signer certificate is not a valid X.509 certificate")
            }
            if (!cert.publicKey.encoded.contentEquals(s.publicKey)) {
                throw Malformed("$scheme signer public key is not its certificate's")
            }
            val alg = contentDigestOf(best.first)!!
            val d = s.digests.getValue(best.first)
            val prev = wanted[alg]
            if (prev != null && !prev.contentEquals(d)) throw Malformed("$scheme signers disagree on the content digest")
            wanted[alg] = d
            certDigests.add(hex(sha256(s.certs[0])))
        }
        for ((alg, expected) in wanted) {
            val actual = contentDigest(f, layout, alg)
            if (!actual.contentEquals(expected)) {
                throw Malformed("the APK's contents do not match its $scheme signature (modified after signing)")
            }
        }
        return Result.Verified(scheme, certDigests.distinct())
    }

    // ------------------------------------------------------------------ content digest

    /** The v2/v3 whole-file digest: 1 MiB chunks over [0, block), [cd, eocd), eocd with cd offset -> block. */
    private fun contentDigest(f: RandomAccessFile, layout: Layout, alg: Alg): ByteArray {
        val chunkDigests = java.io.ByteArrayOutputStream()
        var chunks = 0
        val md = MessageDigest.getInstance(alg.digest)
        val buf = ByteArray(CHUNK)
        val prefix = ByteArray(5)
        fun chunk(data: ByteArray, n: Int) {
            prefix[0] = 0xa5.toByte()
            ByteBuffer.wrap(prefix, 1, 4).order(ByteOrder.LITTLE_ENDIAN).putInt(n)
            md.update(prefix); md.update(data, 0, n)
            chunkDigests.write(md.digest()); chunks++
        }
        fun section(start: Long, end: Long) {
            var pos = start
            f.seek(start)
            while (pos < end) {
                val n = minOf(CHUNK.toLong(), end - pos).toInt()
                f.readFully(buf, 0, n)
                chunk(buf, n); pos += n
            }
        }
        section(0, layout.sigBlockStart)
        section(layout.cdOffset, layout.eocdOffset)
        val eocd = layout.eocd.copyOf()
        ByteBuffer.wrap(eocd).order(ByteOrder.LITTLE_ENDIAN).putInt(16, layout.sigBlockStart.toInt())
        var off = 0
        while (off < eocd.size) {
            val n = minOf(CHUNK, eocd.size - off)
            chunk(eocd.copyOfRange(off, off + n), n); off += n
        }
        val top = ByteArray(5)
        top[0] = 0x5a
        ByteBuffer.wrap(top, 1, 4).order(ByteOrder.LITTLE_ENDIAN).putInt(chunks)
        md.update(top); md.update(chunkDigests.toByteArray())
        return md.digest()
    }

    // ------------------------------------------------------------------ helpers

    private fun slice(b: ByteBuffer, pos: Int, len: Int): ByteBuffer {
        val d = b.duplicate(); d.position(pos); d.limit(pos + len)
        return d.slice().order(ByteOrder.LITTLE_ENDIAN)
    }

    /** A u32-length-prefixed field, consumed from [b]. */
    private fun lp(b: ByteBuffer): ByteBuffer {
        if (b.remaining() < 4) throw Malformed("truncated length prefix")
        val n = b.int
        if (n < 0 || n > b.remaining()) throw Malformed("length prefix $n exceeds the remaining ${b.remaining()} bytes")
        val s = slice(b, b.position(), n)
        b.position(b.position() + n)
        return s
    }

    private fun u32(b: ByteBuffer): Long {
        if (b.remaining() < 4) throw Malformed("truncated field")
        return b.int.toLong() and 0xffffffffL
    }

    private fun bytes(b: ByteBuffer): ByteArray = ByteArray(b.remaining()).also { b.get(it) }

    private fun sha256(b: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(b)

    private fun hex(b: ByteArray): String = b.joinToString("") { "%02x".format(it) }
}
