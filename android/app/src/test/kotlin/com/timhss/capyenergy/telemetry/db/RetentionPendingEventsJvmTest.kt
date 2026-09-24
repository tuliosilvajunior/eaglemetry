package com.timhss.capyenergy.telemetry.db

import java.io.File
import java.sql.DriverManager
import java.sql.Statement
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * G2: age retention must never delete an event that belongs to a session
 * still `pending` — its wall stamp is the boot birth clock (e.g. 2025) and
 * reads as ancient until the sweep corrects it.
 *
 * The session age purges already carry `timeState != 'pending'` (proved in
 * `SessionTimeAuthorityConsumerJvmTest`); the event age purges only gate on
 * `dirty = 0`, so a synced-then-held event of a pending session would be
 * eaten by the cutoff. Every statement here is extracted from the DAO source
 * at runtime and executed against real SQLite tables built from the Room
 * schema export (48.json).
 */
class RetentionPendingEventsJvmTest {

    private val birthStamp2025 = 1_748_048_880_000L // 2025-05-23 22:08 UTC
    private val realNow = 1_786_000_000_000L // inside the healthy 2026 window
    private val dayMillis = 86_400_000L
    private val cutoff2026 = realNow - 30 * dayMillis

    private val schemaDir = File(
        "android/app/schemas/com.timhss.capyenergy.telemetry.db.TelemetryDatabase"
    ).let { if (it.isDirectory) it else File("schemas/com.timhss.capyenergy.telemetry.db.TelemetryDatabase") }

    @Test
    fun `event age purge keeps events of a pending session`() {
        execute { s, sql ->
            seedSession(s, "sess-pending", "pending", birthStamp2025)
            seedSession(s, "sess-known", "known", realNow - 60 * dayMillis)
            seedEvent(s, 1L, birthStamp2025, "sess-pending")
            seedEvent(s, 2L, realNow - 60 * dayMillis, "sess-known")

            val deleted = s.executeUpdate(sql("deleteOlderThanChunk", cutoff2026, null, 2_000))

            assertEquals(1, deleted)
            assertTrue("pending-session event survives", eventExists(s, 1L))
            assertTrue("known-session old event ages out", !eventExists(s, 2L))
        }
    }

    @Test
    fun `event confirmed purge keeps events of a pending session`() {
        execute { s, sql ->
            seedSession(s, "sess-pending", "pending", birthStamp2025)
            seedSession(s, "sess-known", "known", realNow - 60 * dayMillis)
            seedEvent(s, 1L, birthStamp2025, "sess-pending")
            seedEvent(s, 2L, realNow - 60 * dayMillis, "sess-known")

            val deleted = s.executeUpdate(sql("deleteOlderThanConfirmedChunk", cutoff2026, 10L, 2_000))

            assertEquals(1, deleted)
            assertTrue("pending-session event survives confirmed purge", eventExists(s, 1L))
            assertTrue("known-session old event ages out", !eventExists(s, 2L))
        }
    }

    @Test
    fun `pending to known transition resumes normal retention`() {
        execute { s, sql ->
            seedSession(s, "sess-flip", "pending", birthStamp2025)
            seedEvent(s, 1L, birthStamp2025, "sess-flip")

            assertEquals(0, s.executeUpdate(sql("deleteOlderThanChunk", cutoff2026, null, 2_000)))
            assertTrue("held while pending", eventExists(s, 1L))

            // The sweep resolved the session; the corrected stamp is young.
            s.execute("UPDATE `session` SET `timeState` = 'known' WHERE `id` = 'sess-flip'")
            s.execute("UPDATE `telemetry_events` SET `occurredAtUtcMillis` = ${realNow - 60 * dayMillis} WHERE `id` = 1")

            assertEquals(1, s.executeUpdate(sql("deleteOlderThanChunk", cutoff2026, null, 2_000)))
            assertTrue("ages out once known", !eventExists(s, 1L))
        }
    }

    @Test
    fun `event age purge respects chunk limit`() {
        execute { s, sql ->
            seedSession(s, "sess-old", "known", realNow - 60 * dayMillis)
            seedEvent(s, 1L, realNow - 60 * dayMillis, "sess-old")
            seedEvent(s, 2L, realNow - 61 * dayMillis, "sess-old")
            seedEvent(s, 3L, realNow - 62 * dayMillis, "sess-old")

            assertEquals(2, s.executeUpdate(sql("deleteOlderThanChunk", cutoff2026, null, 2)))
            assertEquals(1, s.executeUpdate(sql("deleteOlderThanChunk", cutoff2026, null, 2_000)))
        }
    }

    // ---- Harness: real DAO SQL over real-shape tables -----------------------

    private fun execute(block: (Statement, EventSql) -> Unit) {
        val conn = DriverManager.getConnection("jdbc:sqlite::memory:")
        conn.use { c ->
            val s = c.createStatement()
            createTableFromExport(s, "48", "session")
            createTableFromExport(s, "48", "telemetry_events")
            val eventDao = readDao("TelemetryEventDao.kt")
            val sql: EventSql = { method, cutoff, floorId, limit ->
                var q = queryFor(eventDao, method)
                    .replace(":cutoffUtcMillis", cutoff.toString())
                    .replace(":limit", limit.toString())
                if (floorId != null) q = q.replace(":floorId", floorId.toString())
                q
            }
            block(s, sql)
        }
    }

    private fun queryFor(eventDao: String, method: String): String {
        val sig = eventDao.lines().first { it.contains("fun $method(") }
        val head = eventDao.substring(0, eventDao.indexOf(sig))
        val queryOpen = head.lastIndexOf("@Query(")
        val raw = head.substring(queryOpen)
        return Regex(""""([^"]*)"""").findAll(raw).joinToString("") { it.groupValues[1] }
    }

    private fun createTableFromExport(s: Statement, version: String, table: String) {
        val entities = JSONObject(File(schemaDir, "$version.json").readText())
            .getJSONObject("database").getJSONArray("entities")
        val entity = (0 until entities.length())
            .map { entities.getJSONObject(it) }
            .first { it.getString("tableName") == table }
        val cols = StringBuilder()
        val fields = entity.getJSONArray("fields")
        for (j in 0 until fields.length()) {
            val f = fields.getJSONObject(j)
            if (cols.isNotEmpty()) cols.append(", ")
            val name = f.getString("columnName")
            var type = f.getString("affinity").uppercase()
            if (f.optString("notNull", "") == "1") type += " NOT NULL"
            val default = f.optString("defaultValue", "")
            if (default.isNotEmpty() && !default.equals("NULL", true)) type += " DEFAULT $default"
            cols.append("`$name` $type")
        }
        s.execute("CREATE TABLE `$table` ($cols)")
    }

    private fun seedSession(s: Statement, id: String, timeState: String, endedAt: Long) {
        val updated = realNow - dayMillis
        s.execute(
            "INSERT INTO `session` " +
                "(`id`, `vehicleId`, `kind`, `status`, `startedAtUtcMillis`, `startedAtElapsedNanos`, " +
                "`endedAtUtcMillis`, `createdAtUtcMillis`, `updatedAtUtcMillis`, `dirty`, `timeState`) VALUES " +
                "('$id', 'car', 'PARKED', 'ENDED', $endedAt, 100, $endedAt, $updated, $updated, 0, '$timeState')"
        )
    }

    private fun seedEvent(s: Statement, id: Long, occurredAt: Long, sessionId: String) {
        s.execute(
            "INSERT INTO `telemetry_events` " +
                "(`id`, `type`, `occurredAtUtcMillis`, `occurredAtElapsedNanos`, " +
                "`timestampAccuracy`, `uncertaintyMillis`, `details`, `sessionId`, `dirty`) VALUES " +
                "($id, 'TRIP_ARMED', $occurredAt, 10, 'PRECISE', 0, '{}', '$sessionId', 0)"
        )
    }

    private fun eventExists(s: Statement, id: Long): Boolean =
        s.executeQuery("SELECT COUNT(*) FROM `telemetry_events` WHERE `id` = $id").use { rs ->
            rs.next(); rs.getLong(1) > 0
        }

    private fun readDao(name: String): String {
        val candidates = listOf(
            File("android/app/src/main/kotlin/com/timhss/capyenergy/telemetry/db/$name"),
            File("app/src/main/kotlin/com/timhss/capyenergy/telemetry/db/$name")
        )
        for (f in candidates) if (f.exists()) return f.readText()
        var dir = File(System.getProperty("user.dir"))
        repeat(5) {
            val f = File(dir, "android/app/src/main/kotlin/com/timhss/capyenergy/telemetry/db/$name")
            if (f.exists()) return f.readText()
            dir = dir.parentFile ?: return@repeat
        }
        error("cannot find $name")
    }
}

private typealias EventSql = (method: String, cutoff: Long, floorId: Long?, limit: Int) -> String
