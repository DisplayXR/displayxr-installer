package com.displayxr.installer

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import java.util.Collections
import kotlin.concurrent.thread

/**
 * The NP02J browser download: 1,686,822 of "-1" bytes, then discarded, no retry.
 * Pinned here against a real local HTTP server that drops the connection mid-body
 * and honours Range, the way GitHub's release CDN does.
 */
class DownloadResumeTest {

    private val body = ByteArray(3_000_000) { (it * 7 + it / 1000).toByte() }
    // A deliberately tiny HTTP/1.1 server on a raw socket: the unit-test classpath is
    // android.jar, which has no com.sun.net.httpserver. One request per connection.
    private lateinit var server: ServerSocket
    private val requests: MutableList<Map<String, String?>> = Collections.synchronizedList(ArrayList())

    /** How many of the first requests die after [cutAfter] bytes of body. */
    @Volatile private var dropFirst = 0
    @Volatile private var cutAfter = 1_000_000
    @Volatile private var honourRange = true
    @Volatile private var status = 200

    private val url get() = "http://127.0.0.1:${server.localPort}/asset.apk"

    @Before
    fun start() {
        server = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
        thread(isDaemon = true) {
            while (!server.isClosed) {
                val sock = try { server.accept() } catch (e: Exception) { break }
                sock.use { so ->
                    val input = so.getInputStream().bufferedReader(Charsets.ISO_8859_1)
                    input.readLine() ?: return@use
                    val headers = HashMap<String, String>()
                    while (true) {
                        val l = input.readLine() ?: break
                        if (l.isEmpty()) break
                        val i = l.indexOf(':')
                        if (i > 0) headers[l.substring(0, i).trim().lowercase()] = l.substring(i + 1).trim()
                    }
                    val range = headers["range"]
                    requests += mapOf("Range" to range, "Accept-Encoding" to headers["accept-encoding"])
                    val out = so.getOutputStream()
                    if (status != 200) {
                        out.write("HTTP/1.1 $status X\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
                        out.flush(); return@use
                    }
                    val from = if (honourRange && range != null) range.removePrefix("bytes=").removeSuffix("-").toInt() else 0
                    val slice = body.copyOfRange(from, body.size)
                    val head = buildString {
                        append(if (from > 0) "HTTP/1.1 206 Partial\r\n" else "HTTP/1.1 200 OK\r\n")
                        append("Content-Length: ${slice.size}\r\n")
                        if (from > 0) append("Content-Range: bytes $from-${body.size - 1}/${body.size}\r\n")
                        append("Connection: close\r\n\r\n")
                    }
                    out.write(head.toByteArray())
                    // Body shorter than Content-Length: the client sees a dropped stream.
                    if (requests.size <= dropFirst) out.write(slice, 0, minOf(cutAfter, slice.size))
                    else out.write(slice)
                    out.flush()
                }
            }
        }
    }

    @After
    fun stop() = server.close()

    private fun fetch(dest: File, expected: Long = body.size.toLong(), policy: RetryPolicy = RetryPolicy()): List<Int> {
        val retries = ArrayList<Int>()
        Net.download(url, "asset.apk", dest, expected, policy, sleep = {}, onRetry = { a, _, _ -> retries += a }) { _, _ -> }
        return retries
    }

    @Test
    fun `a dropped connection resumes with Range and the file is whole`() {
        dropFirst = 2
        val dest = File.createTempFile("download", ".apk")
        val retries = fetch(dest)
        assertTrue(dest.readBytes().contentEquals(body))
        assertEquals(listOf(1, 2), retries)
        assertEquals(null, requests[0]["Range"])
        assertEquals("bytes=1000000-", requests[1]["Range"])
        assertEquals("bytes=2000000-", requests[2]["Range"])
        dest.delete()
    }

    @Test
    fun `every request asks for identity encoding so the length is knowable`() {
        fetch(File.createTempFile("download", ".apk"))
        assertTrue(requests.all { it["Accept-Encoding"] == "identity" })
    }

    @Test
    fun `a server that ignores Range restarts the file instead of appending garbage`() {
        dropFirst = 1
        honourRange = false
        val dest = File.createTempFile("download", ".apk")
        fetch(dest)
        assertTrue(dest.readBytes().contentEquals(body))
        dest.delete()
    }

    @Test
    fun `giving up deletes the partial file and says how far it got`() {
        dropFirst = 100
        cutAfter = 100_000   // three resumed 100 KB chunks cannot complete 3 MB
        val dest = File.createTempFile("download", ".apk")
        try {
            fetch(dest, policy = RetryPolicy(maxAttempts = 3))
            fail("expected a Truncated failure")
        } catch (e: InstallerFailure.Truncated) {
            assertTrue(e.message!!, e.message!!.contains("after 300000 of 3000000 bytes"))
            assertTrue(e.message!!, e.message!!.contains("3 attempts"))
        }
        assertFalse(dest.exists())
        assertEquals(3, requests.size)
    }

    @Test
    fun `a 404 is not retried`() {
        status = 404
        val dest = File.createTempFile("download", ".apk")
        try {
            fetch(dest)
            fail("expected an Http failure")
        } catch (e: InstallerFailure.Http) {
            assertEquals(404, e.code)
        }
        assertEquals(1, requests.size)
    }

    @Test
    fun `a file shorter than the release API's size is never accepted`() {
        // Server sends a complete 3,000,000-byte body; the API said it is bigger.
        val dest = File.createTempFile("download", ".apk")
        try {
            fetch(dest, expected = body.size + 10L, policy = RetryPolicy(maxAttempts = 2))
            fail("expected a Truncated failure")
        } catch (e: InstallerFailure.Truncated) {
            // expected
        }
        assertFalse(dest.exists())
    }
}

class ResumeDecisionTest {

    @Test
    fun `content range parses, including an unknown total`() {
        assertEquals(100L to 1000L, ResumeDecision.parseContentRange("bytes 100-999/1000"))
        assertEquals(100L to null, ResumeDecision.parseContentRange("bytes 100-999/*"))
        assertEquals(null, ResumeDecision.parseContentRange("garbage"))
        assertEquals(null, ResumeDecision.parseContentRange(null))
    }

    @Test
    fun `206 from where we are appends, from elsewhere restarts`() {
        assertEquals(ResumeDecision.Append(1000), ResumeDecision.decide(100, 206, "bytes 100-999/1000", 900, -1))
        assertEquals(ResumeDecision.Restart(1000), ResumeDecision.decide(100, 206, "bytes 0-999/1000", 1000, -1))
        assertEquals(ResumeDecision.Restart(-1), ResumeDecision.decide(100, 206, null, 900, -1))
    }

    @Test
    fun `200 means Range was ignored`() {
        assertEquals(ResumeDecision.Restart(1000), ResumeDecision.decide(100, 200, null, 1000, -1))
        // The -1 of the NP02J run: no length in the headers, the release API's size wins.
        assertEquals(ResumeDecision.Restart(346279221), ResumeDecision.decide(0, 200, null, -1, 346279221))
    }

    @Test
    fun `a known total beats the headers`() {
        assertEquals(ResumeDecision.Append(5000), ResumeDecision.decide(100, 206, "bytes 100-999/1000", 900, 5000))
    }

    @Test
    fun `416 is complete only when we hold exactly the known size`() {
        assertEquals(ResumeDecision.Complete(1000), ResumeDecision.decide(1000, 416, null, -1, 1000))
        assertEquals(ResumeDecision.Restart(-1), ResumeDecision.decide(1000, 416, null, -1, -1))
    }

    @Test
    fun `other statuses fail`() {
        assertEquals(ResumeDecision.Fail(404), ResumeDecision.decide(0, 404, null, -1, -1))
    }

    @Test
    fun `retry policy backs off, caps, and never retries a 4xx or a rate limit`() {
        val p = RetryPolicy(maxAttempts = 6, firstBackoffMs = 2_000, maxBackoffMs = 30_000)
        assertEquals(listOf(2_000L, 4_000L, 8_000L, 16_000L, 30_000L), (1..5).map { p.backoffMs(it) })
        assertTrue(p.retryable(InstallerFailure.Truncated("x", 1, 2)))
        assertTrue(p.retryable(InstallerFailure.Http(503, "u", "")))
        assertFalse(p.retryable(InstallerFailure.Http(404, "u", "")))
        assertFalse(p.retryable(InstallerFailure.RateLimited(60)))
    }
}
