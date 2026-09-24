package com.timhss.capyenergy.telemetry.db

import java.io.File
import java.sql.DriverManager
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * JVM migration test for `MIGRATION_47_48` (time authority T9).
 *
 * Verifies that the schema 47 to 48 migration:
 * 1. Adds `correctedFromUtcMillis` to `interval`.
 * 2. Creates `interval_replaced_keys` with primary key `(sessionId, startUtcMillis)`.
 * 3. Is lossless: zero rows dropped across existing tables.
 * 4. Preserves all column families on `interval`: the monotonic time pair
 *    (`startElapsedNanos`, `startBootCount`), time state (`timeState`),
 *    and the account stamp (`accountId`).
 * 5. Supports insert and query on `interval_replaced_keys`.
 */
class TelemetryMigration47To48JvmTest {

    private val schemaDir = File(
        "android/app/schemas/com.timhss.capyenergy.telemetry.db.TelemetryDatabase"
    ).let { if (it.isDirectory) it else File("schemas/com.timhss.capyenergy.telemetry.db.TelemetryDatabase") }

    @Test
    fun `47 to 48 migration adds correctedFromUtcMillis and interval_replaced_keys table`() {
        val conn = DriverManager.getConnection("jdbc:sqlite::memory:")
        conn.use { c ->
            val s = c.createStatement()
            val schema47 = JSONObject(File(schemaDir, "47.json").readText())
                .getJSONObject("database")
            val entities = schema47.getJSONArray("entities")

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

            // Seed interval row with monotonic pair, time state, and account
            seed(
                s,
                "interval",
                "(`sessionId`, `startUtcMillis`, `widthMillis`, `tractionWh`, `regenWh`, `auxiliaryWh`, `climateWh`, `deliveredWh`, `distanceKm`, `coveredSeconds`, `climateCoveredSeconds`, `speedCoveredSeconds`, `deliveredCoveredSeconds`, `updatedAtUtcMillis`, `startElapsedNanos`, `startBootCount`, `timeState`, `dirty`, `accountId`)",
                "('trip-1', 60000, 60000, 10.0, 2.0, 1.0, 0.5, 0.0, 1.2, 60.0, 60.0, 60.0, 0.0, 99000, 1000000000, 1, 'pending', 1, 'acc-test')"
            )
            seed(
                s,
                "session",
                "(`rowId`, `id`, `vehicleId`, `kind`, `status`, `startedAtUtcMillis`, `startedAtElapsedNanos`, `noLongerReducible`, `createdAtUtcMillis`, `updatedAtUtcMillis`, `timeState`, `accountId`)",
                "(1, 'trip-1', 'car', 'TRIP', 'ENDED', 1000, 100, 0, 1000, 5000, 'known', 'acc-test')"
            )

            val intervalCountBefore = count(s, "interval")
            val sessionCountBefore = count(s, "session")

            // Apply MIGRATION_47_48 directly from TelemetryDatabase
            val proxy = java.lang.reflect.Proxy.newProxyInstance(
                androidx.sqlite.db.SupportSQLiteDatabase::class.java.classLoader,
                arrayOf(androidx.sqlite.db.SupportSQLiteDatabase::class.java)
            ) { _, method, args ->
                if (method.name == "execSQL" && args != null && args.isNotEmpty()) {
                    s.execute(args[0] as String)
                }
                null
            } as androidx.sqlite.db.SupportSQLiteDatabase

            TelemetryDatabase.MIGRATION_47_48.migrate(proxy)
            assertEquals(47, TelemetryDatabase.MIGRATION_47_48.startVersion)
            assertEquals(48, TelemetryDatabase.MIGRATION_47_48.endVersion)

            // 1. Verify interval_replaced_keys table exists with exact columns and PK
            val keyCols = s.executeQuery("PRAGMA table_info(`interval_replaced_keys`)").use { rs ->
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
            assertTrue("sessionId must be part of PK", keyCols["sessionId"]?.second == true)
            assertTrue("startUtcMillis must be part of PK", keyCols["startUtcMillis"]?.second == true)
            assertEquals("TEXT", keyCols["sessionId"]?.first)
            assertEquals("INTEGER", keyCols["startUtcMillis"]?.first)
            assertEquals("INTEGER", keyCols["replacedByUtcMillis"]?.first)

            // Verify insertion and query on interval_replaced_keys
            s.execute("INSERT INTO `interval_replaced_keys` (`sessionId`, `startUtcMillis`, `replacedByUtcMillis`) VALUES ('trip-1', 60000, 120000)")
            assertEquals(1L, count(s, "interval_replaced_keys"))

            // 2. Verify zero data loss on existing tables
            assertEquals("interval rows must not be lost", intervalCountBefore, count(s, "interval"))
            assertEquals("session rows must not be lost", sessionCountBefore, count(s, "session"))

            // 3. Verify monotonic pair, time state, account, and new correctedFromUtcMillis on interval
            val intervalRow = s.executeQuery("SELECT `startElapsedNanos`, `startBootCount`, `timeState`, `accountId`, `correctedFromUtcMillis` FROM `interval` WHERE `sessionId` = 'trip-1'").use { rs ->
                assertTrue("seeded interval row must exist", rs.next())
                mapOf(
                    "startElapsedNanos" to rs.getLong("startElapsedNanos"),
                    "startBootCount" to rs.getInt("startBootCount"),
                    "timeState" to rs.getString("timeState"),
                    "accountId" to rs.getString("accountId"),
                    "correctedFromUtcMillis" to if (rs.getObject("correctedFromUtcMillis") == null) null else rs.getLong("correctedFromUtcMillis")
                )
            }
            assertEquals(1000000000L, intervalRow["startElapsedNanos"])
            assertEquals(1, intervalRow["startBootCount"])
            assertEquals("pending", intervalRow["timeState"])
            assertEquals("acc-test", intervalRow["accountId"])
            assertNull("existing row must have null correctedFromUtcMillis", intervalRow["correctedFromUtcMillis"])
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
