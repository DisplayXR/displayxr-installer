package com.displayxr.installer

import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URL
import java.net.UnknownHostException
import java.util.concurrent.TimeUnit

/**
 * Every failure in here is typed and carries a sentence a tester can act on.
 *
 * That is the whole point of the class: the first thing this installer has to
 * beat is not a missing feature but a spinner that never resolves. A tablet with
 * no Wi-Fi, a pin whose release has no Android asset, and a download that dies at
 * 60% must each end up as text on the screen.
 */
sealed class InstallerFailure(message: String) : IOException(message) {

    /** No route to the host at all. */
    class Offline(host: String) :
        InstallerFailure("No network. Could not reach $host — connect this tablet to Wi-Fi and retry.")

    class Timeout(url: String) :
        InstallerFailure("Timed out talking to $url. The network is reachable but not answering; retry.")

    class Http(val code: Int, url: String, detail: String) :
        InstallerFailure("HTTP $code from $url${if (detail.isBlank()) "" else " — $detail"}")

    /** The pin resolved to a release, but that release publishes no Android APK. */
    class NoAndroidAsset(tag: String, repo: String) : InstallerFailure(
        "$tag publishes no Android APK on $repo. This is a pin problem, not a device problem: " +
            "versions.json names a release that has nothing to install here. Nothing older is " +
            "substituted on purpose — an unpinned version is exactly what breaks the matched set."
    )

    class NoSuchRelease(tag: String, repo: String) :
        InstallerFailure("$repo has no release tagged $tag. versions.json points at something that is not published.")

    class RateLimited(resetInSeconds: Long) : InstallerFailure(
        "GitHub is rate-limiting this tablet (60 API requests/hour for anonymous callers). " +
            "Retry in about ${maxOf(1L, resetInSeconds / 60)} min."
    )

    /** The stream ended before Content-Length said it would. */
    class Truncated(name: String, got: Long, expected: Long) : InstallerFailure(
        "Download of $name ended after $got of $expected bytes. The file on disk is incomplete, " +
            "so it was discarded rather than handed to the package installer."
    )

    class Malformed(what: String, detail: String) :
        InstallerFailure("Could not read $what: $detail")
}

object Net {

    private val CONNECT_TIMEOUT_MS = TimeUnit.SECONDS.toMillis(20).toInt()
    private val READ_TIMEOUT_MS = TimeUnit.SECONDS.toMillis(30).toInt()

    private fun open(url: String, accept: String?): HttpURLConnection {
        val c = URL(url).openConnection() as HttpURLConnection
        c.connectTimeout = CONNECT_TIMEOUT_MS
        c.readTimeout = READ_TIMEOUT_MS
        c.instanceFollowRedirects = true
        c.setRequestProperty("User-Agent", "DisplayXR-Installer-Android")
        if (accept != null) c.setRequestProperty("Accept", accept)
        return c
    }

    /** GET a small text body. Throws an [InstallerFailure] on anything that is not 200. */
    fun getText(url: String, accept: String? = null): String {
        val c = try {
            open(url, accept).also { it.connect() }
        } catch (e: UnknownHostException) {
            throw InstallerFailure.Offline(URL(url).host)
        } catch (e: SocketTimeoutException) {
            throw InstallerFailure.Timeout(url)
        }
        try {
            val code = c.responseCode
            if (code == 403 || code == 429) {
                val remaining = c.getHeaderField("X-RateLimit-Remaining")
                if (remaining == "0") {
                    val reset = c.getHeaderField("X-RateLimit-Reset")?.toLongOrNull() ?: 0L
                    throw InstallerFailure.RateLimited(reset - System.currentTimeMillis() / 1000)
                }
            }
            if (code !in 200..299) {
                val detail = c.errorStream?.bufferedReader()?.use { it.readText() }?.take(200).orEmpty()
                throw InstallerFailure.Http(code, url, detail.replace('\n', ' '))
            }
            return c.inputStream.bufferedReader().use { it.readText() }
        } catch (e: SocketTimeoutException) {
            throw InstallerFailure.Timeout(url)
        } finally {
            c.disconnect()
        }
    }

    /**
     * Download to [dest], reporting progress.
     *
     * A short read is an error here, not a smaller file: handing a truncated APK
     * to PackageInstaller produces `INSTALL_PARSE_FAILED_*`, which reads as "that
     * release is broken" rather than "the Wi-Fi dropped". The partial file is
     * deleted so a retry cannot pick it up.
     */
    fun download(
        url: String,
        name: String,
        dest: File,
        onProgress: (bytes: Long, total: Long) -> Unit,
    ) {
        val c = try {
            open(url, null).also { it.connect() }
        } catch (e: UnknownHostException) {
            throw InstallerFailure.Offline(URL(url).host)
        } catch (e: SocketTimeoutException) {
            throw InstallerFailure.Timeout(url)
        }
        try {
            val code = c.responseCode
            if (code !in 200..299) throw InstallerFailure.Http(code, url, "")
            val total = c.contentLengthLong
            var written = 0L
            var lastReport = 0L
            c.inputStream.use { input ->
                FileOutputStream(dest).use { out ->
                    val buf = ByteArray(128 * 1024)
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n)
                        written += n
                        if (written - lastReport > 512 * 1024) {
                            lastReport = written
                            onProgress(written, total)
                        }
                    }
                    out.fd.sync()
                }
            }
            onProgress(written, total)
            if (total > 0 && written != total) {
                dest.delete()
                throw InstallerFailure.Truncated(name, written, total)
            }
            if (written == 0L) {
                dest.delete()
                throw InstallerFailure.Truncated(name, 0, total)
            }
        } catch (e: SocketTimeoutException) {
            dest.delete()
            throw InstallerFailure.Timeout(url)
        } catch (e: IOException) {
            if (e is InstallerFailure) {
                dest.delete()
                throw e
            }
            val got = dest.length()
            dest.delete()
            throw InstallerFailure.Truncated(name, got, -1)
        } finally {
            c.disconnect()
        }
    }
}
