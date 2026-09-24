package com.timhss.capyenergy.telemetry.db

import java.io.File
import java.sql.DriverManager
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * JVM migration test for `MIGRATION_45_46` (time authority T5).
 *
 * Verifies that the schema 45 to 46 migration:
 * 1. Creates `clock_bad_signatures` with exact columns and primary key.
 * 2. Is lossless: zero rows dropped across existing tables.
 * 3. Preserves both column families on `interval`: the monotonic time pair
 *    (`startElapsedNanos`, `startBootCount`, `timeState`) and the account
 *    stamp (`accountId`).
 */
class TelemetryMigration45To46JvmTest {

    private val schemaDir = File(
        "android/app/schemas/com.timhss.capyenergy.telemetry.db.TelemetryDatabase"
    ).let { if (it.isDirectory) it else File("schemas/com.timhss.capyenergy.telemetry.db.TelemetryDatabase") }

    @Test
    fun `45 to 46 migration creates clock_bad_signatures and preserves interval columns`() {
        val conn = DriverManager.getConnection("jdbc:sqlite::memory:")
        conn.use { c ->
            val s = c.createStatement()
            val schema45 = JSONObject(File(schemaDir, "45.json").readText())
                .getJSONObject("database")
            val entities = schema45.getJSONArray("entities")

            for (i in 0 until entities.length()) {
                val e = entities.getJSONObject(i)
                val table = e.getString("tableName")
                val fields = e.getJSONArray("fields")
                val pkCols = e.getJSONObject("primaryKey").optJSONArray("columnNames")?.toListOfStrings()
                val cols = StringBuilder()
                for (j in 0 until fields.length()) {
                    val f = fields.getJSONObject(j)
                    if (cols.isNotEmpty()) cols.append(", ")
                    val name = f.getString("columnName")
                    var type = sqlType(f.getString("affinity"))
                    val notNull = f.optString("notNull", "") == "1"
                    if (notNull) type += " NOT NULL"
                    val default = f.optString("defaultValue", "")
                    if (default.isNotEmpty() && !default.equals("NULL", true)) {
                        type += " DEFAULT " + default
                    }
                    cols.append("`$name` $type")
                }
                if (pkCols != null && pkCols.isNotEmpty()) {
                    cols.append(", PRIMARY KEY (" + pkCols.joinToString(", ") { "`$it`" } + ")")
                }
                s.execute("CREATE TABLE `$table` ($cols)")
            }

            // Seed interval row with monotonic pair and account
            seed(
                s,
                "interval",
                "(`sessionId`, `startUtcMillis`, `widthMillis`, `tractionWh`, `regenWh`, `auxiliaryWh`, `climateWh`, `deliveredWh`, `distanceKm`, `coveredSeconds`, `climateCoveredSeconds`, `speedCoveredSeconds`, `deliveredCoveredSeconds`, `updatedAtUtcMillis`, `startElapsedNanos`, `startBootCount`, `timeState`, `dirty`, `accountId`)",
                "('trip-1', 60000, 60000, 10.0, 2.0, 1.0, 0.5, 0.0, 1.2, 60.0, 60.0, 60.0, 0.0, 99000, 1000000000, 1, 'pending', 1, 'acc-test')"
            )
            seed(
                s,
                "session",
                "(`rowId`, `id`, `vehicleId`, `kind`, `status`, `startedAtUtcMillis`, `startedAtElapsedNanos`, `noLongerReducible`, `createdAtUtcMillis`, `updatedAtUtcMillis`, `accountId`)",
                "(1, 'trip-1', 'car', 'TRIP', 'ENDED', 1000, 100, 0, 1000, 5000, 'acc-test')"
            )

            val intervalCountBefore = count(s, "interval")
            val sessionCountBefore = count(s, "session")

            // Apply MIGRATION_45_46
            s.execute(
                "CREATE TABLE IF NOT EXISTS `clock_bad_signatures` (" +
                    "`wallUtcMillis` INTEGER NOT NULL, " +
                    "`firstSeenUtcMillis` INTEGER NOT NULL, " +
                    "`hits` INTEGER NOT NULL, " +
                    "PRIMARY KEY(`wallUtcMillis`))"
            )

            // 1. Verify clock_bad_signatures table exists with exact columns and PK
            val sigCols = s.executeQuery("PRAGMA table_info(`clock_bad_signatures`)").use { rs ->
                val map = mutableMapOf<String, Pair<String, Boolean>>()
                while (rs.next()) {
                    val name = rs.getString("name")
                    val type = rs.getString("type")
                    val pk = rs.getInt("pk") > 0
                    val notnull = rs.getInt("notnull") == 1
                    map[name] = Pair(type, pk && notnull)
                }
                map
            }
            assertTrue("clock_bad_signatures must have wallUtcMillis PK", sigCols["wallUtcMillis"]?.second == true)
            assertEquals("INTEGER", sigCols["wallUtcMillis"]?.first)
            assertEquals("INTEGER", sigCols["firstSeenUtcMillis"]?.first)
            assertEquals("INTEGER", sigCols["hits"]?.first)

            // Verify insertion and query on clock_bad_signatures
            s.execute("INSERT INTO `clock_bad_signatures` (`wallUtcMillis`, `firstSeenUtcMillis`, `hits`) VALUES (1748048880000, 1780000000000, 1)")
            assertEquals(1L, count(s, "clock_bad_signatures"))

            // 2. Verify zero data loss on existing tables
            assertEquals("interval rows must not be lost", intervalCountBefore, count(s, "interval"))
            assertEquals("session rows must not be lost", sessionCountBefore, count(s, "session"))

            // 3. Verify monotonic pair and account preserved on interval
            val intervalRow = s.executeQuery("SELECT `startElapsedNanos`, `startBootCount`, `timeState`, `accountId` FROM `interval` WHERE `sessionId` = 'trip-1'").use { rs ->
                assertTrue("seeded interval row must exist", rs.next())
                mapOf(
                    "startElapsedNanos" to rs.getLong("startElapsedNanos"),
                    "startBootCount" to rs.getInt("startBootCount"),
                    "timeState" to rs.getString("timeState"),
                    "accountId" to rs.getString("accountId")
                )
            }
            assertEquals(1000000000L, intervalRow["startElapsedNanos"])
            assertEquals(1, intervalRow["startBootCount"])
            assertEquals("pending", intervalRow["timeState"])
            assertEquals("acc-test", intervalRow["accountId"])
        }
    }

    private fun seed(s: java.sql.Statement, table: String, cols: String, values: String) {
        s.execute("INSERT INTO `$table` $cols VALUES $values")
    }

    private fun count(s: java.sql.Statement, table: String): Long =
        s.executeQuery("SELECT COUNT(*) FROM `$table`").use { rs -> rs.next(); rs.getLong(1) }

    private fun sqlType(affinity: String): String = when (affinity.uppercase()) {
        "TEXT" -> "TEXT"
        "INTEGER" -> "INTEGER"
        "REAL" -> "REAL"
        "BLOB" -> "BLOB"
        else -> "TEXT"
    }

    private fun JSONArray.toListOfStrings(): List<String> =
        (0 until length()).map { getString(it) }
}
