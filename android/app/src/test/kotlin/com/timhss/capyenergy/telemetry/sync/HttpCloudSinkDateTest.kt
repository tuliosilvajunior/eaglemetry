package com.timhss.capyenergy.telemetry.sync

import com.timhss.capyenergy.telemetry.ClockAnchorStore
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.ServerSocket
import java.net.Socket
import java.nio.charset.StandardCharsets
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * T4: the first cloud call of a boot offers the response `Date` header to
 * the anchor store. The header is forged by a local socket server: real,
 * shifted, missing, malformed.
 *
 * Each test below guards one DoD clause; each was proven red by deleting
 * the clause it protects before being accepted.
 */
class HttpCloudSinkDateTest {

    private val realWall = 1_789_214_400_000L // Sat 2026-09-12 12:00:00 GMT
    private val elapsed = 100_000_000_000L // 100 s into the boot

    @Before
    fun reset() {
        ClockAnchorStore.reset()
    }

    @Test
    fun `first cloud call with a real Date anchors the pair`() = runBlocking {
        withServer(dateHeaderValue(realWall)) {
            val sink = testSink(it)

            sink.upsert("session", listOf(mapOf("id" to "s1")), listOf("id"), merge = false)
        }

        val anchor = ClockAnchorStore.anchor()
        assertEquals(realWall, anchor?.wallMillis)
        assertEquals(elapsed, anchor?.elapsedNanos)
        assertEquals(ClockAnchorStore.Source.SERVER_DATE, anchor?.source)
        // One source only: the boot stays pending until GPS corroborates.
        assertFalse(ClockAnchorStore.isLearned())
    }

    @Test
    fun `shifted Date with reference history resolves nothing`() = runBlocking {
        ClockAnchorStore.setReferenceOffset(realWall - elapsed / 1_000_000L)
        withServer(dateHeaderValue(realWall + 2 * 3_600_000L)) {
            val sink = testSink(it)

            sink.upsert("session", listOf(mapOf("id" to "s1")), listOf("id"), merge = false)
        }

        assertNull(ClockAnchorStore.anchor())
        assertFalse(ClockAnchorStore.isLearned())
    }

    @Test
    fun `missing Date anchors nothing`() = runBlocking {
        withServer(dateHeader = null) {
            val sink = testSink(it)

            sink.upsert("session", listOf(mapOf("id" to "s1")), listOf("id"), merge = false)
        }

        assertNull(ClockAnchorStore.anchor())
    }

    @Test
    fun `malformed Date anchors nothing`() = runBlocking {
        withServer(dateHeader = "not-a-date") {
            val sink = testSink(it)

            sink.upsert("session", listOf(mapOf("id" to "s1")), listOf("id"), merge = false)
        }

        assertNull(ClockAnchorStore.anchor())
    }

    @Test
    fun `failed call offers no Date`() = runBlocking {
        var threw = false
        withServer(dateHeaderValue(realWall), code = 500) {
            val sink = testSink(it)

            try {
                sink.upsert("session", listOf(mapOf("id" to "s1")), listOf("id"), merge = false)
            } catch (_: Exception) {
                threw = true
            }
        }

        assertTrue(threw)
        assertNull(ClockAnchorStore.anchor())
    }

    private fun testSink(baseUrl: String): HttpCloudSink =
        HttpCloudSink(
            baseUrl = baseUrl,
            anonKey = "test-anon-key",
            carTokenProvider = { null },
            monotonicNanos = { elapsed },
        )

    private fun dateHeaderValue(wallMillis: Long): String {
        val format = SimpleDateFormat("EEE, dd MMM yyyy HH:mm:ss zzz", Locale.US)
        format.timeZone = TimeZone.getTimeZone("GMT")
        return format.format(java.util.Date(wallMillis))
    }

    private suspend fun withServer(dateHeader: String?, code: Int = 201, block: suspend (baseUrl: String) -> Unit) {
        val server = ForgedDateServer(dateHeader, code)
        server.start()
        Thread.sleep(50)
        val base = "http://127.0.0.1:${server.actualPort}"
        try {
            block(base)
        } finally {
            server.await()
        }
    }

    private class ForgedDateServer(val dateHeader: String?, val code: Int) {
        private val serverSocket = ServerSocket(0)
        val actualPort: Int = serverSocket.localPort
        private val latch = CountDownLatch(1)
        private var thread: Thread? = null

        fun start() {
            thread = Thread {
                try {
                    serverSocket.soTimeout = 5000
                    val socket: Socket = serverSocket.accept()
                    socket.use { s ->
                        val reader = BufferedReader(InputStreamReader(s.getInputStream(), StandardCharsets.UTF_8))
                        var contentLength = 0
                        while (true) {
                            val l = reader.readLine() ?: break
                            if (l.isEmpty()) break
                            if (l.lowercase().startsWith("content-length:")) {
                                contentLength = l.substringAfter(":").trim().toIntOrNull() ?: 0
                            }
                        }
                        if (contentLength > 0) {
                            val buf = CharArray(contentLength)
                            var read = 0
                            while (read < contentLength) {
                                val n = reader.read(buf, read, contentLength - read)
                                if (n == -1) break
                                read += n
                            }
                        }
                        val body = "[]".toByteArray(StandardCharsets.UTF_8)
                        val statusText = if (code in 200..299) "Created" else "Server Error"
                        val out = s.getOutputStream()
                        val head = StringBuilder("HTTP/1.1 $code $statusText\r\n")
                        if (dateHeader != null) head.append("Date: ").append(dateHeader).append("\r\n")
                        head.append("Content-Type: application/json\r\n")
                            .append("Content-Length: ${body.size}\r\n")
                            .append("Connection: close\r\n\r\n")
                        out.write(head.toString().toByteArray(StandardCharsets.UTF_8))
                        out.write(body)
                        out.flush()
                    }
                } catch (_: Exception) {
                } finally {
                    latch.countDown()
                    try { serverSocket.close() } catch (_: Exception) {}
                }
            }
            thread!!.isDaemon = true
            thread!!.start()
        }

        fun await() {
            latch.await(5, TimeUnit.SECONDS)
            thread?.join(2000)
        }
    }
}
