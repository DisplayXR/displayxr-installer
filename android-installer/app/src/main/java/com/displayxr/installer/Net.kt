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

    /** The stream ended before the file was whole. */
    class Truncated(name: String, got: Long, expected: Long, attempts: Int = 1) : InstallerFailure(
        "Download of $name ended after $got of ${if (expected > 0) "$expected" else "an unknown number of"} " +
            "bytes${if (attempts > 1) ", after $attempts attempts that each resumed where the last stopped" else ""}. " +
            "The file on disk is incomplete, so it was discarded rather than handed to the package " +
            "installer. Tap \"Retry download + install\" on this row to try again."
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
     * Download to [dest], reporting progress — resuming, not restarting, when the
     * connection drops.
     *
     * Found on the NP02J: the ~346 MB browser download ended after 1,686,822 bytes,
     * "of -1". Two defects in one line. The -1 was a missing Content-Length: the
     * platform HttpURLConnection asks for gzip on its own and then hides the length
     * of what it inflates, so a short read could not even be recognised as short.
     * And one dropped connection discarded everything, with no way to retry from the
     * screen short of relaunching the app. So:
     *  - `Accept-Encoding: identity`, and the size the release API reported
     *    ([expectedSize]) as the length to hold the file to, whatever the headers say;
     *  - up to [RetryPolicy.maxAttempts] attempts, each resuming with `Range:` from the
     *    bytes already on disk ([ResumeDecision] decides what the server's answer means);
     *  - only a FINAL failure deletes the partial file.
     *
     * A short read is still an error, never a smaller file: handing a truncated APK
     * to PackageInstaller produces `INSTALL_PARSE_FAILED_*`, which reads as "that
     * release is broken" rather than "the Wi-Fi dropped".
     */
    fun download(
        url: String,
        name: String,
        dest: File,
        expectedSize: Long = -1L,
        policy: RetryPolicy = RetryPolicy(),
        sleep: (Long) -> Unit = { Thread.sleep(it) },
        onRetry: (attempt: Int, failure: InstallerFailure, haveBytes: Long) -> Unit = { _, _, _ -> },
        onProgress: (bytes: Long, total: Long) -> Unit,
    ) {
        dest.delete()
        var total = if (expectedSize > 0) expectedSize else -1L
        var attempt = 0
        while (true) {
            attempt++
            try {
                if (fetchOnce(url, name, dest, total, onProgress).also { total = it } > 0 &&
                    dest.length() == total
                ) return
                // Unknown length and the stream ended cleanly: nothing to hold it to.
                if (total <= 0 && dest.length() > 0) return
                throw InstallerFailure.Truncated(name, dest.length(), total)
            } catch (e: IOException) {
                val f = classify(e, url, name, dest.length(), total)
                if (!policy.retryable(f) || attempt >= policy.maxAttempts) {
                    val got = dest.length()
                    dest.delete()
                    throw if (f is InstallerFailure.Truncated) {
                        InstallerFailure.Truncated(name, got, total, attempt)
                    } else f
                }
                onRetry(attempt, f, dest.length())
                sleep(policy.backoffMs(attempt))
            }
        }
    }

    /** One request. Returns the total length it now believes in (-1 = unknown). */
    private fun fetchOnce(
        url: String,
        name: String,
        dest: File,
        knownTotal: Long,
        onProgress: (Long, Long) -> Unit,
    ): Long {
        val have = if (dest.exists()) dest.length() else 0L
        if (knownTotal > 0 && have == knownTotal) return knownTotal

        val c = try {
            open(url, null).also {
                // Without this the platform stack negotiates gzip transparently and
                // reports Content-Length -1 — the length the NP02J run could not check.
                it.setRequestProperty("Accept-Encoding", "identity")
                if (have > 0) it.setRequestProperty("Range", "bytes=$have-")
                it.connect()
            }
        } catch (e: UnknownHostException) {
            throw InstallerFailure.Offline(URL(url).host)
        }
        try {
            val code = c.responseCode
            val decision = ResumeDecision.decide(
                have = have,
                code = code,
                contentRange = c.getHeaderField("Content-Range"),
                contentLength = c.contentLengthLong,
                knownTotal = knownTotal,
            )
            val (append, total) = when (decision) {
                is ResumeDecision.Complete -> return decision.total
                is ResumeDecision.Append -> true to decision.total
                is ResumeDecision.Restart -> false to decision.total
                is ResumeDecision.Fail -> throw InstallerFailure.Http(code, url, "")
            }
            var written = if (append) have else 0L
            var lastReport = 0L
            c.inputStream.use { input ->
                FileOutputStream(dest, append).use { out ->
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
            if (total > 0 && written > total) {
                // More bytes than the file has: whatever is on disk is not that file.
                dest.delete()
                throw InstallerFailure.Truncated(name, written, total)
            }
            return total
        } finally {
            c.disconnect()
        }
    }

    private fun classify(e: IOException, url: String, name: String, got: Long, total: Long): InstallerFailure =
        when (e) {
            is InstallerFailure -> e
            is SocketTimeoutException -> InstallerFailure.Timeout(url)
            is UnknownHostException -> InstallerFailure.Offline(URL(url).host)
            else -> InstallerFailure.Truncated(name, got, total)
        }
}

/**
 * How many times a download is attempted and how long to wait in between.
 *
 * Retried: a dropped or short stream, a timeout, a lost network, a 5xx. NOT
 * retried: a 4xx (the URL is wrong or gone — asking again changes nothing) and a
 * rate limit (asking again makes it worse).
 */
data class RetryPolicy(
    val maxAttempts: Int = 6,
    val firstBackoffMs: Long = 2_000,
    val maxBackoffMs: Long = 30_000,
) {
    fun backoffMs(attempt: Int): Long =
        minOf(maxBackoffMs, firstBackoffMs shl (attempt - 1).coerceIn(0, 20))

    fun retryable(f: InstallerFailure): Boolean = when (f) {
        is InstallerFailure.Truncated, is InstallerFailure.Timeout, is InstallerFailure.Offline -> true
        is InstallerFailure.Http -> f.code >= 500 || f.code == 408
        else -> false
    }
}

/**
 * What a server's answer to a (possibly ranged) GET means for the bytes on disk.
 * Pure, so it is JVM-tested against every answer a server or CDN actually gives.
 */
sealed class ResumeDecision {
    /** 206 from exactly where we are: append. */
    data class Append(val total: Long) : ResumeDecision()

    /** 200 (Range ignored) or a 206 from somewhere else: start the file over. */
    data class Restart(val total: Long) : ResumeDecision()

    /** 416 while we already hold every byte: nothing to fetch. */
    data class Complete(val total: Long) : ResumeDecision()

    data class Fail(val code: Int) : ResumeDecision()

    companion object {
        private val CONTENT_RANGE = Regex("""bytes\s+(\d+)-(\d+)/(\d+|\*)""")

        /** `bytes 100-199/1000` -> (100, 1000); total null when `*`. */
        fun parseContentRange(h: String?): Pair<Long, Long?>? {
            val m = CONTENT_RANGE.find(h ?: return null) ?: return null
            return m.groupValues[1].toLong() to m.groupValues[3].toLongOrNull()
        }

        fun decide(have: Long, code: Int, contentRange: String?, contentLength: Long, knownTotal: Long): ResumeDecision {
            // A known total always wins over headers: it came from the release API and
            // is the size the file must end up. Headers only fill it in when unknown.
            fun pick(fromHeaders: Long?): Long =
                if (knownTotal > 0) knownTotal else (fromHeaders?.takeIf { it > 0 } ?: -1L)

            return when (code) {
                206 -> {
                    val cr = parseContentRange(contentRange)
                    when {
                        cr == null -> Restart(pick(null))
                        cr.first == have -> Append(pick(cr.second))
                        else -> Restart(pick(cr.second))
                    }
                }

                in 200..299 -> Restart(pick(contentLength.takeIf { it > 0 }))
                416 ->
                    // "Range not satisfiable" for bytes=have- means have >= size. If we know
                    // the size and hold exactly that, the previous attempt had finished.
                    if (knownTotal > 0 && have == knownTotal) Complete(knownTotal) else Restart(pick(null))

                else -> Fail(code)
            }
        }
    }
}
