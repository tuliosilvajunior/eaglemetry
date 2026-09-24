package com.timhss.capyenergy.telemetry.db

import java.io.File
import java.sql.DriverManager
import java.sql.Statement
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

private typealias OneParam = (method: String, arg: Any?) -> String

/**
 * Time authority T6 consumer contract, proved against the real SQL.
 *
 * The captain's rule: never lose data silently. A PENDING session's wall
 * stamps will still be corrected, so age retention must never delete one —
 * a wrong stamp can make a young session look ancient (the 2025 boot-default
 * band) or sort it out of every window (the 2027 forward-jump band). Both
 * extremes are real rows from the car, so both are seeded here.
 *
 * Every statement under test is extracted from the DAO source at runtime and
 * executed against real SQLite tables built from the Room schema export
 * (47.json). Deleting the `timeState != 'pending'` gate from any DAO query
 * fails these tests; asserting on a copy of the SQL would not.
 */
class SessionTimeAuthorityConsumerJvmTest {

    // The wall stamps the car really writes on an unsynced boot: the frozen
    // MCU default and the post-sync forward jump (plan section 2.1).
    private val bootDefault2025 = 1_748_048_880_000L // 2025-05-23 22:08 UTC
    private val forwardJump2027 = 1_830_000_000_000L // 2027-12-29 band
    private val realNow = 1_786_000_000_000L // inside the healthy 2026 window
    private val dayMillis = 86_400_000L

    private val schemaDir = File(
        "android/app/schemas/com.timhss.capyenergy.telemetry.db.TelemetryDatabase"
    ).let { if (it.isDirectory) it else File("schemas/com.timhss.capyenergy.telemetry.db.TelemetryDatabase") }

    @Test
    fun `46 to 47 migration adds session timeState default unknown`() {
        val session = JSONObject(File(schemaDir, "47.json").readText())
            .getJSONObject("database")
            .getJSONArray("entities")
            .let { entities ->
                (0 until entities.length())
                    .map { entities.getJSONObject(it) }
                    .first { it.getString("tableName") == "session" }
            }
        val fields = session.getJSONArray("fields")
        val timeState = (0 until fields.length())
            .map { fields.getJSONObject(it) }
            .first { it.getString("columnName") == "timeState" }
        assertEquals("TEXT", timeState.getString("affinity"))
        assertTrue("session.timeState must be NOT NULL", timeState.optBoolean("notNull", false))

        // The default lives in the migration SQL, not the field metadata:
        // run the real MIGRATION_46_47 statement from the database source
        // against a 46-shaped table and prove legacy rows read 'unknown'.
        val dbSource = readFile("TelemetryDatabase.kt")
        val migrateAt = dbSource.indexOf("MIGRATION_46_47")
        val migrateBlock = dbSource.substring(migrateAt, dbSource.indexOf("MIGRATION_45_46", migrateAt))
        val statements = Regex(""""([^"]*)"""").findAll(migrateBlock)
            .map { it.groupValues[1] }.joinToString("")
        assertTrue("migration must default the column", statements.contains("DEFAULT 'unknown'"))

        val conn = DriverManager.getConnection("jdbc:sqlite::memory:")
        conn.use { c ->
            val s = c.createStatement()
            createTableFromExport(s, "46", "session")
            s.execute(
                "INSERT INTO `session` " +
                    "(`id`, `vehicleId`, `kind`, `status`, `startedAtUtcMillis`, `startedAtElapsedNanos`, " +
                    "`createdAtUtcMillis`, `updatedAtUtcMillis`, `dirty`) VALUES " +
                    "('legacy', 'car', 'PARKED', 'ENDED', 1000, 100, 1000, 5000, 0)"
            )
            for (stmt in statements.split(";").map { it.trim() }.filter { it.isNotEmpty() }) {
                s.execute(stmt)
            }
            val state = s.executeQuery("SELECT `timeState` FROM `session` WHERE `id` = 'legacy'").use { rs ->
                rs.next(); rs.getString(1)
            }
            assertEquals("unknown", state)
        }
    }

    private fun readFile(name: String): String {
        val tail = "com/timhss/capyenergy/telemetry/db/$name"
        val candidates = listOf(
            File("android/app/src/main/kotlin/$tail"),
            File("app/src/main/kotlin/$tail")
        )
        for (f in candidates) if (f.exists()) return f.readText()
        var dir = File(System.getProperty("user.dir"))
        repeat(5) {
            val f = File(dir, "android/app/src/main/kotlin/$tail")
            if (f.exists()) return f.readText()
            dir = dir.parentFile ?: return@repeat
        }
        error("cannot find $name")
    }
    @Test
    fun `retention keeps pending sessions past cutoff on both stamp extremes`() {
        execute { s, sql ->
            // One PARKED session per state x stamp combination, all ended and
            // uploaded (dirty = 0): without the T6 gate every row with an old
            // stamp would be deleted by age.
            seedSession(s, "pending-old-stamp", "pending", bootDefault2025, endedAgoDays = 60)
            seedSession(s, "pending-future-stamp", "pending", forwardJump2027, endedAgoDays = 60)
            seedSession(s, "known-old", "known", realNow - 60 * dayMillis, endedAgoDays = 60)
            seedSession(s, "unknown-old", "unknown", realNow - 60 * dayMillis, endedAgoDays = 60)
            seedSession(s, "known-young", "known", realNow - 5 * dayMillis, endedAgoDays = 5)

            val cutoff2026 = realNow - 30 * dayMillis
            val deleted2026 = s.executeUpdate(sql("deleteOlderThan", cutoff2026))

            // In 2026: only the two genuinely old, resolved rows go. The 2025
            // pending row survives because of pending; the 2027 pending row
            // also survives because it sits in the future.
            assertEquals(2, deleted2026)
            assertTrue("pending 2025 stamp survives 2026 cutoff", exists(s, "pending-old-stamp"))
            assertTrue("pending 2027 stamp survives in future", exists(s, "pending-future-stamp"))
            assertTrue("known old deleted", !exists(s, "known-old"))
            assertTrue("unknown legacy row keeps legacy behavior", !exists(s, "unknown-old"))
            assertTrue("known young kept", exists(s, "known-young"))

            // Now test the 2027 extreme ALÉM DO PRAZO: when time moves past
            // 2027 (e.g. cutoff in 2028), the 2027 stamp is now older than
            // cutoff. A resolved 2027 row ages out; the pending 2027 row MUST
            // BE KEPT. Removing the gate would delete both.
            seedSession(s, "known-2027", "known", forwardJump2027, endedAgoDays = 60)
            val cutoff2028 = forwardJump2027 + 30 * dayMillis
            val deleted2028 = s.executeUpdate(sql("deleteOlderThan", cutoff2028))

            // known-young and known-2027 age out; pending rows remain protected.
            assertEquals(2, deleted2028)
            assertTrue("pending 2025 stamp survives past 2028 cutoff", exists(s, "pending-old-stamp"))
            assertTrue("pending 2027 stamp survives past cutoff", exists(s, "pending-future-stamp"))
            assertTrue("known 2027 aged out", !exists(s, "known-2027"))
        }
    }

    @Test
    fun `confirmed retention keeps pending sessions past cutoff on both stamp extremes`() {
        execute { s, sql ->
            // 2025 extreme
            seedSession(s, "pc-pending-2025", "pending", bootDefault2025, endedAgoDays = 60)
            seedSession(s, "pc-known-2025", "known", realNow - 60 * dayMillis, endedAgoDays = 60)
            val cutoff2026 = realNow - 30 * dayMillis
            val deleted2026 = s.executeUpdate(
                sql("deleteOlderThanConfirmed", cutoff2026)
                    .replace(":floorStartedAtUtcMillis", realNow.toString())
            )
            assertEquals(1, deleted2026)
            assertTrue("pending 2025 survives confirmed purge", exists(s, "pc-pending-2025"))
            assertTrue("known 2025 aged out", !exists(s, "pc-known-2025"))

            // 2027 extreme past cutoff
            seedSession(s, "pc-pending-2027", "pending", forwardJump2027, endedAgoDays = 60)
            seedSession(s, "pc-known-2027", "known", forwardJump2027, endedAgoDays = 60)
            val cutoff2028 = forwardJump2027 + 30 * dayMillis
            val deleted2028 = s.executeUpdate(
                sql("deleteOlderThanConfirmed", cutoff2028)
                    .replace(":floorStartedAtUtcMillis", (forwardJump2027 + 60 * dayMillis).toString())
            )
            assertEquals(1, deleted2028)
            assertTrue("pending 2027 survives confirmed purge", exists(s, "pc-pending-2027"))
            assertTrue("known 2027 aged out", !exists(s, "pc-known-2027"))
        }
    }

    @Test
    fun `continuous confirmed retention keeps pending sessions past cutoff on both stamp extremes`() {
        execute { s, sql ->
            // 2025 extreme
            seedSession(s, "cc-pending-2025", "pending", bootDefault2025, endedAgoDays = 200, kind = "CONTINUOUS")
            seedSession(s, "cc-known-2025", "known", realNow - 200 * dayMillis, endedAgoDays = 200, kind = "CONTINUOUS")
            val cutoff2026 = realNow - 180 * dayMillis
            val deleted2026 = s.executeUpdate(
                sql("deleteContinuousOlderThanConfirmed", cutoff2026)
                    .replace(":floorStartedAtUtcMillis", realNow.toString())
            )
            assertEquals(1, deleted2026)
            assertTrue("pending 2025 survives continuous confirmed purge", exists(s, "cc-pending-2025"))
            assertTrue("known 2025 aged out", !exists(s, "cc-known-2025"))

            // 2027 extreme past cutoff
            seedSession(s, "cc-pending-2027", "pending", forwardJump2027, endedAgoDays = 200, kind = "CONTINUOUS")
            seedSession(s, "cc-known-2027", "known", forwardJump2027, endedAgoDays = 200, kind = "CONTINUOUS")
            val cutoff2028 = forwardJump2027 + 180 * dayMillis
            val deleted2028 = s.executeUpdate(
                sql("deleteContinuousOlderThanConfirmed", cutoff2028)
                    .replace(":floorStartedAtUtcMillis", (forwardJump2027 + 200 * dayMillis).toString())
            )
            assertEquals(1, deleted2028)
            assertTrue("pending 2027 survives continuous confirmed purge", exists(s, "cc-pending-2027"))
            assertTrue("known 2027 aged out", !exists(s, "cc-known-2027"))
        }
    }

    @Test
    fun `continuous retention keeps pending sessions past cutoff on both stamp extremes`() {
        execute { s, sql ->
            // 2025 extreme
            seedSession(s, "c-pending-2025", "pending", bootDefault2025, endedAgoDays = 200, kind = "CONTINUOUS")
            seedSession(s, "c-known-2025", "known", realNow - 200 * dayMillis, endedAgoDays = 200, kind = "CONTINUOUS")
            val cutoff2026 = realNow - 180 * dayMillis
            assertEquals(1, s.executeUpdate(sql("deleteContinuousOlderThan", cutoff2026)))
            assertTrue("pending 2025 continuous survives", exists(s, "c-pending-2025"))
            assertTrue("known 2025 continuous aged out", !exists(s, "c-known-2025"))

            // 2027 extreme past cutoff
            seedSession(s, "c-pending-2027", "pending", forwardJump2027, endedAgoDays = 200, kind = "CONTINUOUS")
            seedSession(s, "c-known-2027", "known", forwardJump2027, endedAgoDays = 200, kind = "CONTINUOUS")
            val cutoff2028 = forwardJump2027 + 180 * dayMillis
            assertEquals(1, s.executeUpdate(sql("deleteContinuousOlderThan", cutoff2028)))
            assertTrue("pending 2027 continuous survives", exists(s, "c-pending-2027"))
            assertTrue("known 2027 continuous aged out", !exists(s, "c-known-2027"))
        }
    }

    @Test
    fun `continuous backstop retention keeps pending sessions on both stamp extremes`() {
        execute { s, sql ->
            // 2025 extreme
            seedSession(s, "b-pending-2025", "pending", bootDefault2025, endedAgoDays = 200, kind = "CONTINUOUS")
            seedSession(s, "b-known-2025", "known", realNow - 200 * dayMillis, endedAgoDays = 200, kind = "CONTINUOUS")
            val cutoff2026 = realNow - 180 * dayMillis
            assertEquals(1, s.executeUpdate(sql("deleteContinuousOlderThanIgnoringDirty", cutoff2026)))
            assertTrue("pending 2025 survives even the backstop", exists(s, "b-pending-2025"))
            assertTrue("known 2025 aged out", !exists(s, "b-known-2025"))

            // 2027 extreme past cutoff
            seedSession(s, "b-pending-2027", "pending", forwardJump2027, endedAgoDays = 200, kind = "CONTINUOUS")
            seedSession(s, "b-known-2027", "known", forwardJump2027, endedAgoDays = 200, kind = "CONTINUOUS")
            val cutoff2028 = forwardJump2027 + 180 * dayMillis
            assertEquals(1, s.executeUpdate(sql("deleteContinuousOlderThanIgnoringDirty", cutoff2028)))
            assertTrue("pending 2027 survives even the backstop", exists(s, "b-pending-2027"))
            assertTrue("known 2027 aged out", !exists(s, "b-known-2027"))
        }
    }

    @Test
    fun `uploader row source holds pending dirty rows`() {
        execute { s, sql ->
            seedSession(s, "u-pending", "pending", bootDefault2025, endedAgoDays = 1)
            seedSession(s, "u-known", "known", realNow - 1 * dayMillis, endedAgoDays = 1)
            // Sessions seed dirty = 0; the uploader only reads dirty rows, so
            // re-mark both dirty the way a fresh recording would be.
            s.execute("UPDATE `session` SET `dirty` = 1")
            seedInterval(s, "u-pending", 60_000L, "pending")
            seedInterval(s, "u-known", 60_000L, "known")
            seedInterval(s, "u-known", 120_000L, "unknown")

            val sessions = s.executeQuery(sql("dirtySessions", Int.MAX_VALUE)).use { rs ->
                buildList { while (rs.next()) add(rs.getString("id")) }
            }
            val sessionCount = s.executeQuery(sql("dirtySessionCount", null)).use { rs ->
                rs.next(); rs.getLong(1)
            }
            val intervals = s.executeQuery(sql("dirtyIntervals", Int.MAX_VALUE)).use { rs ->
                buildList { while (rs.next()) add(rs.getString("sessionId") to rs.getLong("startUtcMillis")) }
            }
            val intervalCount = s.executeQuery(sql("dirtyIntervalCount", null)).use { rs ->
                rs.next(); rs.getLong(1)
            }

            // The pending rows stay dirty but invisible to the uploader: the
            // sweep re-exposes them by flipping the state, never the mark.
            assertEquals(listOf("u-known"), sessions)
            assertEquals(1L, sessionCount)
            assertEquals(
                listOf("u-known" to 60_000L, "u-known" to 120_000L),
                intervals
            )
            assertEquals(2L, intervalCount)
        }
    }

    // ---- Harness: real DAO SQL over real-shape tables -----------------------

    private fun execute(block: (Statement, OneParam) -> Unit) {
        val conn = DriverManager.getConnection("jdbc:sqlite::memory:")
        conn.use { c ->
            val s = c.createStatement()
            createTableFromExport(s, "47", "session")
            createTableFromExport(s, "47", "interval")
            val sessionDao = readDao("SessionDao.kt")
            val intervalDao = readDao("IntervalDao.kt")
            val sql: OneParam = { method, arg ->
                bind(queryFor(sessionDao, intervalDao, method), arg)
            }
            block(s, sql)
        }
    }

    private fun bind(sql: String, arg: Any?): String = when (arg) {
        is Long -> sql.replace(":cutoffUtcMillis", arg.toString())
        is Int -> sql.replace(":limit", arg.toString())
        null -> sql
        else -> error("no binder for $arg")
    }

    private fun queryFor(sessionDao: String, intervalDao: String, method: String): String {
        val src = if (method == "dirtyIntervals" || method == "dirtyIntervalCount") intervalDao else sessionDao
        // The @Query directly above `fun <method>(`: adjacent Kotlin string
        // literals joined with `+`, exactly as Room compiles them.
        val sig = src.lines().first { it.contains("fun $method(") }
        val head = src.substring(0, src.indexOf(sig))
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

    private fun seedSession(
        s: Statement,
        id: String,
        timeState: String,
        endedAt: Long,
        endedAgoDays: Long,
        kind: String = "PARKED"
    ) {
        val updated = realNow - endedAgoDays * dayMillis
        s.execute(
            "INSERT INTO `session` " +
                "(`id`, `vehicleId`, `kind`, `status`, `startedAtUtcMillis`, `startedAtElapsedNanos`, " +
                "`endedAtUtcMillis`, `createdAtUtcMillis`, `updatedAtUtcMillis`, `dirty`, `timeState`) VALUES " +
                "('$id', 'car', '$kind', 'ENDED', $endedAt, 100, $endedAt, $updated, $updated, 0, '$timeState')"
        )
    }

    private fun seedInterval(s: Statement, sessionId: String, start: Long, timeState: String) {
        s.execute(
            "INSERT INTO `interval` " +
                "(`sessionId`, `startUtcMillis`, `updatedAtUtcMillis`, `dirty`, `timeState`) VALUES " +
                "('$sessionId', $start, $realNow, 1, '$timeState')"
        )
    }

    private fun exists(s: Statement, id: String): Boolean =
        s.executeQuery("SELECT COUNT(*) FROM `session` WHERE `id` = '$id'").use { rs ->
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
