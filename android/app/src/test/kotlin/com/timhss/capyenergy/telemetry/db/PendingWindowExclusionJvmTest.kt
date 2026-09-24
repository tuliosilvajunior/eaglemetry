package com.timhss.capyenergy.telemetry.db

import java.io.File
import java.sql.DriverManager
import java.sql.Statement
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * G3: wall-clock windows never admit a `pending` session while it is pending,
 * and admit it automatically once the sweep promotes it to `known`.
 *
 * Two incident cases are seeded: a trip stamped 2025 by the boot-default
 * clock (excluded incidentally by the stamps before G3, explicitly now) and
 * a trip stamped at the right hour but without confirmed truth (only the
 * explicit gate keeps it out — this is the behavioral red G3 fixes).
 *
 * Every statement under test is extracted from the DAO source at runtime and
 * executed against real SQLite tables built from the Room schema export
 * (48.json). Deleting the `timeState != 'pending'` gate from any window
 * query fails these tests.
 */
class PendingWindowExclusionJvmTest {

    private val birthStamp2025 = 1_748_048_880_000L // 2025-05-23 22:08 UTC
    private val realNow = 1_786_000_000_000L // inside the healthy 2026 window
    private val dayMillis = 86_400_000L

    private val schemaDir = File(
        "android/app/schemas/com.timhss.capyenergy.telemetry.db.TelemetryDatabase"
    ).let { if (it.isDirectory) it else File("schemas/com.timhss.capyenergy.telemetry.db.TelemetryDatabase") }

    @Test
    fun `inWindow admits known trips only, pending stays out even with right-hour stamps`() {
        execute { s, sql ->
            seedTrip(s, "pending-2025", "pending", birthStamp2025, birthStamp2025 + 600_000L)
            seedTrip(s, "pending-now", "pending", realNow - 2 * 3_600_000L, realNow - 3_600_000L)
            seedTrip(s, "known-recent", "known", realNow - dayMillis - 3_600_000L, realNow - dayMillis)
            seedTrip(s, "known-old", "known", realNow - 60 * dayMillis, realNow - 60 * dayMillis + 600_000L)

            val rows = queryRows(s, sql("inWindow", "TRIP", realNow - 7 * dayMillis, realNow))

            assertEquals(listOf("known-recent"), rows)
        }
    }

    @Test
    fun `inWindow admits a promoted trip under its corrected stamp`() {
        execute { s, sql ->
            seedTrip(s, "promoted", "pending", realNow - 2 * 3_600_000L, realNow - 3_600_000L)

            assertTrue(
                "held while pending",
                queryRows(s, sql("inWindow", "TRIP", realNow - 7 * dayMillis, realNow)).isEmpty()
            )

            // The sweep resolved the session: known, stamps rewritten.
            s.execute("UPDATE `session` SET `timeState` = 'known' WHERE `id` = 'promoted'")

            assertEquals(
                listOf("promoted"),
                queryRows(s, sql("inWindow", "TRIP", realNow - 7 * dayMillis, realNow))
            )
        }
    }

    @Test
    fun `closedFrom folds without pending charges until promotion`() {
        execute { s, sql ->
            // Battery cycles fold charges by wall start; a pending charge's
            // stamps are not yet trustworthy.
            seedSession(s, "pending-charge", "CHARGE", "pending", realNow - 2 * dayMillis, realNow - 2 * dayMillis + 600_000L)
            seedSession(s, "known-charge", "CHARGE", "known", realNow - 2 * dayMillis, realNow - 2 * dayMillis + 600_000L)

            assertEquals(
                listOf("known-charge"),
                queryRows(s, closedFromSql("closedFrom", realNow - 7 * dayMillis))
            )

            s.execute("UPDATE `session` SET `timeState` = 'known' WHERE `id` = 'pending-charge'")
            assertEquals(
                setOf("known-charge", "pending-charge"),
                queryRows(s, closedFromSql("closedFrom", realNow - 7 * dayMillis)).toSet()
            )
        }
    }

    @Test
    fun `rangeWindow admits known trips only`() {
        execute { s, sql ->
            seedTrip(s, "pending-now", "pending", realNow - 2 * 3_600_000L, realNow - 3_600_000L)
            seedTrip(s, "known-recent", "known", realNow - dayMillis - 3_600_000L, realNow - dayMillis)

            val rows = queryRows(s, sql("rangeWindow", "TRIP", realNow - 7 * dayMillis, realNow))

            assertEquals(listOf("known-recent"), rows)
        }
    }

    @Test
    fun `inWindowAll admits known sessions only`() {
        execute { s, sql ->
            seedSession(s, "pending-parked", "PARKED", "pending", realNow - 2 * 3_600_000L, realNow - 3_600_000L)
            seedSession(s, "known-parked", "PARKED", "known", realNow - 2 * 3_600_000L, realNow - 3_600_000L)

            val rows = queryRows(s, sql("inWindowAll", "TRIP", realNow - 7 * dayMillis, realNow))

            assertEquals(listOf("known-parked"), rows)
        }
    }

    // ---- Harness: real DAO SQL over real-shape tables -----------------------

    private lateinit var daoSource: String

    private fun closedFromSql(method: String, from: Long): String =
        queryFor(daoSource, method).replace(":fromUtcMillis", from.toString())

    private fun execute(block: (Statement, WindowSql) -> Unit) {
        val conn = DriverManager.getConnection("jdbc:sqlite::memory:")
        conn.use { c ->
            val s = c.createStatement()
            createTableFromExport(s, "48", "session")
            val sessionDao = readDao("SessionDao.kt")
            daoSource = sessionDao
            val sql: WindowSql = { method, kind, start, end ->
                queryFor(sessionDao, method)
                    .replace(":kind", "'$kind'")
                    .replace(":startUtcMillis", start.toString())
                    .replace(":endUtcMillis", end.toString())
            }
            block(s, sql)
        }
    }

    private fun queryFor(sessionDao: String, method: String): String {
        val sig = sessionDao.lines().first { it.contains("fun $method(") }
        val head = sessionDao.substring(0, sessionDao.indexOf(sig))
        val queryOpen = head.lastIndexOf("@Query(")
        val raw = head.substring(queryOpen)
        return Regex(""""([^"]*)"""").findAll(raw).joinToString("") { it.groupValues[1] }
    }

    private fun queryRows(s: Statement, query: String): List<String> =
        s.executeQuery(query).use { rs ->
            buildList { while (rs.next()) add(rs.getString("id")) }
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

    private fun seedTrip(s: Statement, id: String, timeState: String, startedAt: Long, endedAt: Long) =
        seedSession(s, id, "TRIP", timeState, startedAt, endedAt)

    private fun seedSession(
        s: Statement,
        id: String,
        kind: String,
        timeState: String,
        startedAt: Long,
        endedAt: Long
    ) {
        val updated = realNow - dayMillis
        s.execute(
            "INSERT INTO `session` " +
                "(`id`, `vehicleId`, `kind`, `status`, `startedAtUtcMillis`, `startedAtElapsedNanos`, " +
                "`endedAtUtcMillis`, `createdAtUtcMillis`, `updatedAtUtcMillis`, `dirty`, `timeState`) VALUES " +
                "('$id', 'car', '$kind', 'ENDED', $startedAt, 100, $endedAt, $updated, $updated, 0, '$timeState')"
        )
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

private typealias WindowSql = (method: String, kind: String, start: Long, end: Long) -> String
