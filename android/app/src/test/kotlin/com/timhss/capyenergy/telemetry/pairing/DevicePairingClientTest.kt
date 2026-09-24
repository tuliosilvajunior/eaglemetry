package com.timhss.capyenergy.telemetry.pairing

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
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DevicePairingClientTest {

    // ---- Fake split ---------------------------------------------------------

    @Test
    fun `fake start returns enqueued result and records call`() = runBlocking {
        val fake = FakeDevicePairingClient()
        val expected = PairingStartResult("111-222", "00000000-0000-4000-a000-000000000042", "2099-01-01T00:00:00.000Z")
        fake.enqueueStart(expected)
        val result = fake.start("VIN-1")
        assertEquals(expected, result)
        assertEquals(listOf("VIN-1"), fake.startCalls)
    }

    @Test
    fun `fake poll pending approved expired invalidCode`() = runBlocking {
        val fake = FakeDevicePairingClient()
        fake.enqueuePoll(PairingPollResult.Pending)
        fake.enqueuePoll(PairingPollResult.Approved("tok", "acct"))
        fake.enqueuePoll(PairingPollResult.Expired)
        fake.enqueuePoll(PairingPollResult.InvalidCode)

        assertTrue(fake.poll("code-1") is PairingPollResult.Pending)
        val approved = fake.poll("code-1") as PairingPollResult.Approved
        assertEquals("tok", approved.carToken)
        assertEquals("acct", approved.accountId)
        assertTrue(fake.poll("code-1") is PairingPollResult.Expired)
        assertTrue(fake.poll("code-1") is PairingPollResult.InvalidCode)
    }

    @Test
    fun `fake start error propagates`() = runBlocking {
        val fake = FakeDevicePairingClient()
        fake.enqueueStartError(DevicePairingException("network down"))
        var threw = false
        try {
            fake.start("VIN-1")
        } catch (e: DevicePairingException) {
            threw = true
            assertEquals("network down", e.message)
        }
        assertTrue(threw)
    }

    @Test
    fun `fake poll error propagates`() = runBlocking {
        val fake = FakeDevicePairingClient()
        fake.enqueuePollError(DevicePairingException("timeout"))
        var threw = false
        try {
            fake.poll("code")
        } catch (e: DevicePairingException) {
            threw = true
        }
        assertTrue(threw)
    }

    @Test
    fun `fake register returns enqueued result and records call`() = runBlocking {
        val fake = FakeDevicePairingClient()
        val expected = RegisterResult("tok-abc")
        fake.enqueueRegister(expected)
        val result = fake.register("VIN-1")
        assertEquals(expected, result)
        assertEquals(listOf("VIN-1"), fake.registerCalls)
    }

    @Test
    fun `fake register error propagates`() = runBlocking {
        val fake = FakeDevicePairingClient()
        fake.enqueueRegisterError(DevicePairingException("network down"))
        var threw = false
        try {
            fake.register("VIN-1")
        } catch (e: DevicePairingException) {
            threw = true
            assertEquals("network down", e.message)
        }
        assertTrue(threw)
    }

    // ---- Real client against local ServerSocket -----------------------------

    private class TinyHttpServer(
        val port: Int,
        val body: String,
        val code: Int,
        val capturedBody: AtomicReference<String> = AtomicReference("")
    ) {
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
                        // Read request line + headers until blank line
                        var contentLength = 0
                        var line: String?
                        while (reader.readLine().also { line = it } != null) {
                            if (line!!.isEmpty()) break
                            if (line!!.lowercase().startsWith("content-length:")) {
                                contentLength = line!!.substringAfter(":").trim().toIntOrNull() ?: 0
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
                            capturedBody.set(String(buf, 0, read))
                        }
                        val bodyBytes = body.toByteArray(StandardCharsets.UTF_8)
                        val statusText = when (code) {
                            200 -> "OK"
                            201 -> "Created"
                            400 -> "Bad Request"
                            404 -> "Not Found"
                            else -> "OK"
                        }
                        val header = "HTTP/1.1 $code $statusText\r\n" +
                            "Content-Type: application/json\r\n" +
                            "Content-Length: ${bodyBytes.size}\r\n" +
                            "Connection: close\r\n\r\n"
                        val out: OutputStream = s.getOutputStream()
                        out.write(header.toByteArray(StandardCharsets.UTF_8))
                        out.write(bodyBytes)
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

    private suspend fun withServer(body: String, code: Int, block: suspend (baseUrl: String, captured: AtomicReference<String>) -> Unit) {
        val captured = AtomicReference("")
        val server = TinyHttpServer(0, body, code, captured)
        server.start()
        // Small delay to let accept thread start
        Thread.sleep(50)
        val base = "http://127.0.0.1:${server.actualPort}"
        try {
            block(base, captured)
        } finally {
            server.await()
        }
    }

    @Test
    fun `real start parses user_code device_code expires_at`() = runBlocking {
        val body = """{"user_code":"482-910","device_code":"00000000-0000-4000-a000-000000000001","expires_at":"2099-01-01T00:00:00.000Z"}"""
        withServer(body, 201) { base, _ ->
            val client = HttpDevicePairingClient(base)
            val result = client.start("VIN-REAL")
            assertEquals("482-910", result.userCode)
            assertEquals("00000000-0000-4000-a000-000000000001", result.deviceCode)
            assertEquals("2099-01-01T00:00:00.000Z", result.expiresAt)
        }
    }

    @Test
    fun `real register parses car_token`() = runBlocking {
        val body = """{"car_token":"tok-abc-123"}"""
        withServer(body, 201) { base, _ ->
            val client = HttpDevicePairingClient(base)
            val result = client.register("VIN-REAL")
            assertEquals("tok-abc-123", result.carToken)
        }
    }

    @Test
    fun `real register throws on 400 with parsed message`() = runBlocking {
        val body = """{"error":"invalid_request","reason":"invalid_vehicle_id","message":"vehicle_id must be a non-empty string"}"""
        withServer(body, 400) { base, _ ->
            val client = HttpDevicePairingClient(base)
            var threw = false
            try {
                client.register("")
            } catch (e: DevicePairingException) {
                threw = true
                assertTrue(e.message!!.contains("vehicle_id must be a non-empty string"))
            }
            assertTrue(threw)
        }
    }

    @Test
    fun `real poll pending`() = runBlocking {
        withServer("""{"status":"pending"}""", 200) { base, _ ->
            val client = HttpDevicePairingClient(base)
            val result = client.poll("00000000-0000-4000-a000-000000000001")
            assertTrue(result is PairingPollResult.Pending)
        }
    }

    @Test
    fun `real poll approved`() = runBlocking {
        withServer("""{"status":"approved","car_token":"tok123","account_id":"acct123"}""", 200) { base, _ ->
            val client = HttpDevicePairingClient(base)
            val result = client.poll("00000000-0000-4000-a000-000000000001") as PairingPollResult.Approved
            assertEquals("tok123", result.carToken)
            assertEquals("acct123", result.accountId)
        }
    }

    @Test
    fun `real poll expired via status`() = runBlocking {
        withServer("""{"status":"expired","reason":"expired"}""", 200) { base, _ ->
            val client = HttpDevicePairingClient(base)
            val result = client.poll("00000000-0000-4000-a000-000000000001")
            assertTrue(result is PairingPollResult.Expired)
        }
    }

    @Test
    fun `real poll invalidCode via 404`() = runBlocking {
        withServer("""{"error":"not_found","reason":"invalid_code","message":"Invalid device code"}""", 404) { base, _ ->
            val client = HttpDevicePairingClient(base)
            val result = client.poll("00000000-0000-4000-a000-000000000001")
            assertTrue(result is PairingPollResult.InvalidCode)
        }
    }

    @Test
    fun `real poll invalidCode via 400`() = runBlocking {
        withServer("""{"error":"invalid_request","reason":"invalid_code","message":"device_code must be a UUID"}""", 400) { base, _ ->
            val client = HttpDevicePairingClient(base)
            val result = client.poll("bad-code")
            assertTrue(result is PairingPollResult.InvalidCode)
        }
    }

    @Test
    fun `real start throws on missing base url`() = runBlocking {
        val client = HttpDevicePairingClient("")
        var threw = false
        try {
            client.start("VIN-1")
        } catch (e: DevicePairingException) {
            threw = true
            assertTrue(e.message!!.contains("not configured"))
        }
        assertTrue(threw)
    }

    @Test
    fun `real poll rejected maps to rejected`() = runBlocking {
        withServer("""{"status":"rejected","reason":"rejected"}""", 200) { base, _ ->
            val client = HttpDevicePairingClient(base)
            val result = client.poll("00000000-0000-4000-a000-000000000001")
            assertTrue(result is PairingPollResult.Rejected)
        }
    }

    @Test
    fun `real start sends vehicle_id in json body`() = runBlocking {
        val response = """{"user_code":"111-222","device_code":"00000000-0000-4000-a000-000000000099","expires_at":"2099-01-01T00:00:00.000Z"}"""
        val capturedRef = AtomicReference("")
        withServer(response, 201) { base, captured ->
            val client = HttpDevicePairingClient(base)
            client.start("VIN-SEND-TEST")
            // captured is set inside server thread; need to wait a bit already done in withServer.await
            // but check captured via our ref captured param
            // withServer captures internally; we check after block via capturedBody in server, but we exposed captured param
            // Actually withServer's captured is same as server's capturedBody — we passed it in, so check it
            assertTrue(captured.get().contains("VIN-SEND-TEST"))
            assertTrue(captured.get().contains("vehicle_id"))
        }
    }
}
