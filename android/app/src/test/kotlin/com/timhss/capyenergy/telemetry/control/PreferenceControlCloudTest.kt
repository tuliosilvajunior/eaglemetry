package com.timhss.capyenergy.telemetry.control

import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStream
import java.net.ServerSocket
import java.net.Socket
import java.nio.charset.StandardCharsets
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The real [HttpPreferenceControlCloud] against an in-process HTTP server —
 * no framework, no network, same seam the pairing client tests use. The
 * point of this suite is the transport contract: every request must carry
 * `apikey` and the raw `x-car-token`, and the wire shape must match Step
 * 1b's tables.
 */
class PreferenceControlCloudTest {

    // ---- Tiny in-process HTTP server (asserts headers + captures body) -----

    private class CapturedRequest(
        val method: String,
        val path: String,
        val headers: Map<String, String>,
        val body: String,
    ) {
        fun header(name: String): String? =
            headers.entries.firstOrNull { it.key.equals(name, ignoreCase = true) }?.value
    }

    private class TinyHttpServer(
        val responses: List<ResponseSpec>,
        val captures: MutableList<CapturedRequest>,
    ) {
        data class ResponseSpec(val body: String, val code: Int)

        private val serverSocket = ServerSocket(0)
        val actualPort: Int = serverSocket.localPort
        private val latch = CountDownLatch(1)
        private var thread: Thread? = null
        private val maxRequests: Int = responses.size

        fun start() {
            thread = Thread {
                try {
                    serverSocket.soTimeout = 5000
                    repeat(maxRequests) {
                        val socket: Socket = serverSocket.accept()
                        socket.use { s ->
                            val reader = BufferedReader(
                                InputStreamReader(s.getInputStream(), StandardCharsets.UTF_8)
                            )
                            var method = ""
                            var path = ""
                            val headers = mutableMapOf<String, String>()
                            var contentLength = 0
                            var line: String?
                            var firstLine = true
                            while (reader.readLine().also { line = it } != null) {
                                val current = line!!
                                if (current.isEmpty()) break
                                if (firstLine) {
                                    firstLine = false
                                    val parts = current.split(" ")
                                    if (parts.size >= 3) {
                                        method = parts[0]
                                        path = parts[1]
                                    }
                                } else {
                                    val idx = current.indexOf(':')
                                    if (idx > 0) {
                                        headers[current.substring(0, idx).trim().lowercase()] =
                                            current.substring(idx + 1).trim()
                                    }
                                }
                                if (current.lowercase().startsWith("content-length:")) {
                                    contentLength = current.substringAfter(":").trim().toIntOrNull() ?: 0
                                }
                            }
                            var body = ""
                            if (contentLength > 0) {
                                val buf = CharArray(contentLength)
                                var read = 0
                                while (read < contentLength) {
                                    val n = reader.read(buf, read, contentLength - read)
                                    if (n == -1) break
                                    read += n
                                }
                                body = String(buf, 0, read)
                            }
                            captures.add(CapturedRequest(method, path, headers, body))

                            val spec = responses[Math.min(captures.size - 1, responses.size - 1)]
                            val bodyBytes = spec.body.toByteArray(StandardCharsets.UTF_8)
                            val statusText = when (spec.code) {
                                200 -> "OK"
                                201 -> "Created"
                                400 -> "Bad Request"
                                else -> "OK"
                            }
                            val header = "HTTP/1.1 ${spec.code} $statusText\r\n" +
                                "Content-Type: application/json\r\n" +
                                "Content-Length: ${bodyBytes.size}\r\n" +
                                "Connection: close\r\n\r\n"
                            val out: OutputStream = s.getOutputStream()
                            out.write(header.toByteArray(StandardCharsets.UTF_8))
                            out.write(bodyBytes)
                            out.flush()
                        }
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

    private suspend fun withServer(
        vararg responses: TinyHttpServer.ResponseSpec,
        block: suspend (baseUrl: String, captures: MutableList<CapturedRequest>) -> Unit,
    ) {
        val captures = mutableListOf<CapturedRequest>()
        val server = TinyHttpServer(responses.toList(), captures)
        server.start()
        Thread.sleep(50)
        val base = "http://127.0.0.1:${server.actualPort}"
        try {
            block(base, captures)
        } finally {
            server.await()
        }
    }

    private fun client(base: String, token: String = "tok-abc123") = HttpPreferenceControlCloud(
        baseUrl = base,
        anonKey = "anon-key-1",
        carTokenProvider = { token },
    )

    // ---- transport contract -----------------------------------------------

    @Test
    fun `real client sends x-car-token and apikey headers`() = runBlocking {
        withServer(TinyHttpServer.ResponseSpec("[]", 200)) { base, captures ->
            client(base, "RAW-TOKEN-999").desiredForVehicle("VIN-1")
            val req = captures.single()
            assertEquals("GET", req.method)
            assertEquals("RAW-TOKEN-999", req.header("x-car-token"))
            assertEquals("anon-key-1", req.header("apikey"))
        }
    }

    @Test
    fun `desired query filters by vehicle id`() = runBlocking {
        withServer(TinyHttpServer.ResponseSpec("""[{"account_id":"a1","vehicle_id":"VIN-1","key":"pack_capacity_wh","value":"64000","proposed_at_utc_millis":1000,"origin":"phone"}]""", 200)) { base, captures ->
            val rows = client(base).desiredForVehicle("VIN-1")
            assertEquals(1, rows.size)
            assertTrue(captures.single().path.contains("/rest/v1/preference_desired"))
            assertTrue(captures.single().path.contains("vehicle_id=eq.VIN-1"))
        }
    }

    @Test
    fun `desired row parses nullable value`() = runBlocking {
        withServer(TinyHttpServer.ResponseSpec("""[{"account_id":"a1","vehicle_id":"VIN-1","key":"pack_capacity_wh","value":null,"proposed_at_utc_millis":1000,"origin":"phone"}]""", 200)) { base, _ ->
            val rows = client(base).desiredForVehicle("VIN-1")
            assertEquals(1, rows.size)
            assertNull(rows.single().value)
        }
    }

    @Test
    fun `reported query and parse`() = runBlocking {
        val body = """[{"vehicle_id":"VIN-1","account_id":"a1","key":"pack_capacity_wh","value":"64000","status":"accepted","decided_at_utc_millis":5000,"reported_at_utc_millis":6000}]"""
        withServer(TinyHttpServer.ResponseSpec(body, 200)) { base, captures ->
            val rows = client(base).reportedForVehicle("VIN-1")
            assertTrue(captures.single().path.contains("/rest/v1/preference_reported"))
            assertTrue(captures.single().path.contains("vehicle_id=eq.VIN-1"))
            assertEquals("accepted", rows.single().status)
            assertEquals(5_000L, rows.single().decidedAtUtcMillis)
            assertEquals(6_000L, rows.single().reportedAtUtcMillis)
            assertEquals("64000", rows.single().value)
        }
    }

    @Test
    fun `report posts upsert path with ignore-duplicates and body shape`() = runBlocking {
        withServer(TinyHttpServer.ResponseSpec("[]", 201)) { base, captures ->
            client(base, "RAW-TOKEN-X").report(
                listOf(
                    PreferenceReportedRow(
                        vehicleId = "VIN-1",
                        accountId = "a1",
                        key = "pack_capacity_wh",
                        value = "64000",
                        status = PreferenceReportedRow.STATUS_ACCEPTED,
                        decidedAtUtcMillis = 5_000L,
                        reportedAtUtcMillis = 6_000L,
                    ),
                    PreferenceReportedRow(
                        vehicleId = "VIN-1",
                        accountId = "a1",
                        key = "default_charge_cost_per_kwh",
                        value = "0.75",
                        status = PreferenceReportedRow.STATUS_REFUSED,
                        decidedAtUtcMillis = 7_000L,
                        reportedAtUtcMillis = 8_000L,
                    ),
                )
            )
            val req = captures.single()
            assertEquals("POST", req.method)
            assertTrue(req.path.contains("/rest/v1/preference_reported"))
            assertTrue(req.path.contains("on_conflict=vehicle_id,key,decided_at_utc_millis"))
            assertEquals("resolution=ignore-duplicates,return=minimal", req.header("prefer"))
            assertEquals("RAW-TOKEN-X", req.header("x-car-token"))
            val payload = JSONArray(req.body)
            assertEquals(2, payload.length())
            val first = payload.getJSONObject(0)
            assertEquals("VIN-1", first.getString("vehicle_id"))
            assertEquals("a1", first.getString("account_id"))
            assertEquals("pack_capacity_wh", first.getString("key"))
            assertEquals("64000", first.getString("value"))
            assertEquals("accepted", first.getString("status"))
            assertEquals(5_000L, first.getLong("decided_at_utc_millis"))
            assertEquals(6_000L, first.getLong("reported_at_utc_millis"))
        }
    }

    @Test
    fun `report refuses carries desired value and refused status`() = runBlocking {
        withServer(TinyHttpServer.ResponseSpec("[]", 201)) { base, captures ->
            client(base).report(
                listOf(
                    PreferenceReportedRow(
                        vehicleId = "VIN-1",
                        accountId = "a1",
                        key = "pack_capacity_wh",
                        value = "60000",
                        status = PreferenceReportedRow.STATUS_REFUSED,
                        decidedAtUtcMillis = 9_000L,
                        reportedAtUtcMillis = 10_000L,
                    )
                )
            )
            val payload = JSONArray(captures.single().body)
            val row = payload.getJSONObject(0)
            assertEquals("refused", row.getString("status"))
            assertEquals("60000", row.getString("value"))
        }
    }

    @Test
    fun `report posts no request for an empty batch`() = runBlocking {
        withServer(TinyHttpServer.ResponseSpec("[]", 201)) { base, captures ->
            client(base).report(emptyList())
            assertTrue(captures.isEmpty())
        }
    }

    // ---- config gates -----------------------------------------------------

    @Test
    fun `not configured when url anon key or token missing`() {
        val base = "http://127.0.0.1:9"
        assertFalse(HttpPreferenceControlCloud(baseUrl = "", anonKey = "k", carTokenProvider = { "t" }).isConfigured)
        assertFalse(HttpPreferenceControlCloud(baseUrl = base, anonKey = "", carTokenProvider = { "t" }).isConfigured)
        assertFalse(HttpPreferenceControlCloud(baseUrl = base, anonKey = "k", carTokenProvider = { null }).isConfigured)
        assertTrue(HttpPreferenceControlCloud(baseUrl = base, anonKey = "k", carTokenProvider = { "t" }).isConfigured)
    }

    @Test
    fun `unconfigured build throws not configured on use`() = runBlocking {
        val cloud = HttpPreferenceControlCloud(baseUrl = "", anonKey = "", carTokenProvider = { null })
        var threw = false
        try {
            cloud.desiredForVehicle("VIN-1")
        } catch (e: PreferenceControlCloudException) {
            threw = true
            assertFalse(e.retryable)
        }
        assertTrue(threw)
    }

    @Test
    fun `non-2xx maps to retryable false for auth errors`() = runBlocking {
        withServer(TinyHttpServer.ResponseSpec("""{"message":"Invalid API key"}""", 401)) { base, _ ->
            val cloud = client(base)
            var threw = false
            try {
                cloud.desiredForVehicle("VIN-1")
            } catch (e: PreferenceControlCloudException) {
                threw = true
                assertFalse(e.retryable)
            }
            assertTrue(threw)
        }
    }
}