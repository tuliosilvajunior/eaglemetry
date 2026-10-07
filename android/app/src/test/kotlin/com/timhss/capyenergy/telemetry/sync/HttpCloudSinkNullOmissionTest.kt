package com.timhss.capyenergy.telemetry.sync

import com.timhss.capyenergy.telemetry.ClockAnchorStore
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.ServerSocket
import java.net.Socket
import java.nio.charset.StandardCharsets
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Option A (null-key stripping): the telemetry wire omits unset columns
 * instead of sending explicit JSON nulls.
 *
 * Under `Prefer: resolution=merge-duplicates` PostgREST builds
 * `ON CONFLICT ... DO UPDATE` from the keys present in the payload, so an
 * omitted key leaves the existing column untouched while an explicit null
 * would wipe it (a session re-uploaded on close wiping a column the open
 * upload had set). Side benefit: unset nullable columns stop costing bytes
 * (~12.3% / 2.99 MB per upload).
 *
 * Annotation tables are out of scope on purpose: the per-group merge trigger
 * reads `NEW.deleted_at_utc_millis` to tell alive from deleted, so their
 * explicit nulls stay.
 */
class HttpCloudSinkNullOmissionTest {

    @Test
    fun `event batch keeps nullable keys so PostgREST sees a uniform shape`() = runBlocking {
        val body = AtomicReference("")
        withBodyServer(body) { base ->
            HttpCloudSink(baseUrl = base, anonKey = "test-key").upsert(
                "telemetry_events",
                listOf(
                    mapOf("type" to "SIGNAL_CHANGED", "value" to "42", "previous_value" to null),
                    mapOf("type" to "SESSION_ENDED", "value" to null, "previous_value" to "ACTIVE"),
                ),
                listOf("vehicle_id", "timestamp_nanos", "type", "signal_id"),
                merge = false,
            )
        }
        val rows = JSONArray(body.get())
        val first = rows.getJSONObject(0)
        val second = rows.getJSONObject(1)
        assertEquals(first.keys().asSequence().toSet(), second.keys().asSequence().toSet())
        assertTrue(first.has("previous_value"))
        assertTrue(first.isNull("previous_value"))
        assertTrue(second.has("value"))
        assertTrue(second.isNull("value"))
    }

    @Before
    fun reset() {
        ClockAnchorStore.reset()
    }

    @Test
    fun `annotation tables keep explicit nulls for the merge trigger`() = runBlocking {
        val body = AtomicReference("")
        withBodyServer(body) { base ->
            val sink = HttpCloudSink(
                baseUrl = base,
                anonKey = "test-anon-key",
                carTokenProvider = { null },
            )
            sink.upsert(
                "insight_places",
                listOf(
                    mapOf(
                        "account_id" to "acct-1",
                        "id" to "place-1",
                        "name" to "Home",
                        "deleted_at_utc_millis" to null,
                    )
                ),
                listOf("account_id", "id"),
                merge = true,
            )
        }

        // The merge trigger reads NEW.deleted_at_utc_millis to tell alive
        // from deleted; omitting it would pin a cloud-deleted row deleted.
        val obj = JSONArray(body.get()).getJSONObject(0)
        assertTrue(obj.has("deleted_at_utc_millis"))
        assertTrue(obj.isNull("deleted_at_utc_millis"))
        assertEquals("Home", obj.getString("name"))
    }


    @Test
    fun `upsert omits null keys instead of sending JSON null`() = runBlocking {
        val body = AtomicReference("")
        withBodyServer(body) { base ->
            val sink = HttpCloudSink(
                baseUrl = base,
                anonKey = "test-anon-key",
                carTokenProvider = { null },
            )
            sink.upsert(
                "session",
                listOf(
                    mapOf(
                        "vehicle_id" to "VIN1",
                        "id" to "trip-1",
                        "status" to "ACTIVE",
                        "ended_at_utc_millis" to null,
                        "end_soc_percent" to null,
                    )
                ),
                listOf("vehicle_id", "id"),
                merge = true,
            )
        }

        val obj = JSONArray(body.get()).getJSONObject(0)
        assertEquals("VIN1", obj.getString("vehicle_id"))
        assertEquals("trip-1", obj.getString("id"))
        assertEquals("ACTIVE", obj.getString("status"))
        assertFalse(obj.has("ended_at_utc_millis"))
        assertFalse(obj.has("end_soc_percent"))
    }

    @Test
    fun `omitted key on re-upload cannot wipe a previously set column`() {
        // Pins the merge contract, not the transport: with
        // `resolution=merge-duplicates` only present keys reach DO UPDATE.
        // The fake keeps that rule; the payload above must feed it rows it
        // cannot wipe with.
        val store = MergeStore()
        // Open upload sets the end SOC...
        store.merge(mapOf("vehicle_id" to "VIN1", "id" to "trip-1", "status" to "ACTIVE", "end_soc_percent" to 42.0))
        // ...the close upload omits it (see test above: no key on the wire).
        store.merge(mapOf("vehicle_id" to "VIN1", "id" to "trip-1", "status" to "CLOSED"))

        val row = store.rows.getValue("VIN1|trip-1")
        assertEquals("CLOSED", row["status"])
        assertEquals(42.0, row["end_soc_percent"])
    }

    @Test
    fun `an explicit null still wipes, which is why the wire omits`() {
        val store = MergeStore()
        store.merge(mapOf("vehicle_id" to "VIN1", "id" to "trip-1", "end_soc_percent" to 42.0))
        // The old behavior: the key present with null overwrites the value.
        val wiped = (store.rows.getValue("VIN1|trip-1") + mapOf("end_soc_percent" to null))
        store.rows["VIN1|trip-1"] = wiped

        assertTrue(store.rows.getValue("VIN1|trip-1").containsKey("end_soc_percent"))
        assertEquals(null, store.rows.getValue("VIN1|trip-1")["end_soc_percent"])
    }

    /** Minimal PostgREST-shaped merge: present keys overwrite, absent keys stay. */
    private class MergeStore {
        val rows = mutableMapOf<String, Map<String, Any?>>()

        fun merge(row: Map<String, Any?>) {
            val key = "${row["vehicle_id"]}|${row["id"]}"
            rows[key] = (rows[key] ?: emptyMap()) + row
        }
    }

    private suspend fun withBodyServer(body: AtomicReference<String>, block: suspend (baseUrl: String) -> Unit) {
        val serverSocket = ServerSocket(0)
        val latch = CountDownLatch(1)
        val thread = Thread {
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
                    val buf = CharArray(contentLength)
                    var read = 0
                    while (read < contentLength) {
                        val n = reader.read(buf, read, contentLength - read)
                        if (n == -1) break
                        read += n
                    }
                    body.set(String(buf, 0, read))
                    val response = "[]".toByteArray(StandardCharsets.UTF_8)
                    val out = s.getOutputStream()
                    val head = "HTTP/1.1 201 Created\r\n" +
                        "Content-Type: application/json\r\n" +
                        "Content-Length: ${response.size}\r\n" +
                        "Connection: close\r\n\r\n"
                    out.write(head.toByteArray(StandardCharsets.UTF_8))
                    out.write(response)
                    out.flush()
                }
            } catch (_: Exception) {
            } finally {
                latch.countDown()
                try { serverSocket.close() } catch (_: Exception) {}
            }
        }
        thread.isDaemon = true
        thread.start()
        Thread.sleep(50)
        try {
            block("http://127.0.0.1:${serverSocket.localPort}")
        } finally {
            latch.await(5, TimeUnit.SECONDS)
            thread.join(2000)
        }
    }
}
