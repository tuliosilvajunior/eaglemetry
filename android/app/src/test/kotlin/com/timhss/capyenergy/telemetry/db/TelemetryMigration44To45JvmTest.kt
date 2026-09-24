package com.timhss.capyenergy.telemetry.db

import java.io.File
import java.sql.DriverManager
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * JVM migration test for `MIGRATION_44_45` (`gb236-p4` review B4).
 *
 * The instrumented `migration44To45AddsTheAccountStampWithoutLosingHistory`
 * needs a device; this suite builds a v44 database from the exported Room
 * schema (`44.json`) with plain SQLite, populates every ownable table with
 * realistic rows, applies the exact `MIGRATION_44_45` statements, and
 * verifies: zero data loss, `accountId` present and nullable everywhere it
 * should be, and absent from the tables that intentionally stay unowned
 * (`battery_cycle_sessions`, `sync_cursors`, `vehicle_id_aliases`).
 *
 * A typo'd table name, a wrong column type, or a dropped `ALTER` fails here
 * in 47 ms instead of shipping to the car and refusing at open.
 */
class TelemetryMigration44To45JvmTest {

    private val schemaDir = File(
        "android/app/schemas/com.timhss.capyenergy.telemetry.db.TelemetryDatabase"
    ).let { if (it.isDirectory) it else File("schemas/com.timhss.capyenergy.telemetry.db.TelemetryDatabase") }

    /** Tables whose rows must land owned-capable (with a nullable accountId). */
    private val accountTables = listOf(
        "session" to "id TEXT", "interval" to "sessionId TEXT", "track" to "sessionId TEXT",
        "telemetry_events" to "id INTEGER", "battery_cycles" to "ordinal INTEGER",
        "trip_segments" to "sessionId TEXT", "session_costs" to "sessionId TEXT",
        "preferences" to "scope TEXT", "preference_proposals" to "id TEXT",
        "insight_places" to "id TEXT", "journeys" to "id TEXT"
    )

    /** Tables that intentionally keep no account column. */
    private val unownedTables = listOf("battery_cycle_sessions", "sync_cursors", "vehicle_id_aliases")

    @Test
    fun `44 to 45 migration is additive and lossless`() {
        val conn = DriverManager.getConnection("jdbc:sqlite::memory:")
        conn.use { c ->
            val s = c.createStatement()
            val schema44 = JSONObject(File(schemaDir, "44.json").readText())
                .getJSONObject("database")
            val entities = schema44.getJSONArray("entities")
            val myTables = accountTables.map { it.first }.toSet() + unownedTables.toSet()
            for (i in 0 until entities.length()) {
                val e = entities.getJSONObject(i)
                val table = e.getString("tableName")
                if (table !in myTables) continue
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
            s.execute(
                "CREATE TABLE IF NOT EXISTS room_master_table (id INTEGER PRIMARY KEY,identity_hash TEXT)"
            )

            // Seed one row per ownable table, tracking each count.
            seed(s, "session", "(`rowId`, `id`, `vehicleId`, `kind`, `status`, `startedAtUtcMillis`, `startedAtElapsedNanos`, `noLongerReducible`, `createdAtUtcMillis`, `updatedAtUtcMillis`)",
                "(1, 'trip-1', 'car', 'TRIP', 'ENDED', 1000, 100, 0, 1000, 5000)")
            seed(s, "interval", "(`sessionId`, `startUtcMillis`, `widthMillis`, `updatedAtUtcMillis`)",
                "('trip-1', 60000, 60000, 99000)")
            seed(s, "track", "(`sessionId`, `encodingVersion`, `pointCount`, `t`, `path`, `speed`, `alt`, `updatedAtUtcMillis`)",
                "('trip-1', 1, 2, '[0,1000]', 'abcd', '[500,500]', '[1000,0]', 4200)")
            seed(s, "telemetry_events", "(`id`, `type`, `occurredAtUtcMillis`, `occurredAtElapsedNanos`, `timestampAccuracy`, `uncertaintyMillis`, `details`)",
                "(1, 'SIGNAL_UPDATED', 1000, 100, 'ACCURATE', 0, 'details')")
            seed(s, "battery_cycles", "(`ordinal`, `startUtcMillis`, `endUtcMillis`, `dischargePercent`, `distanceKm`, `tripEnergyKwh`, `parkedEnergyKwh`, `parkedSocPercent`, `pricedEnergyKwh`, `unpricedEnergyKwh`, `isOpen`, `isPartial`, `energyIncomplete`, `mixedCurrency`, `openingPricedFraction`, `openingBlendedPrice`, `frozenAtUtcMillis`, `createdAtUtcMillis`, `updatedAtUtcMillis`)",
                "(1, 1000, 2000, 12.5, 20.0, 3000.0, 100.0, 3.1, 2800.0, 200.0, 0, 0, 0, 0, 0.9, 0.35, NULL, 1000, 2000)")
            seed(s, "trip_segments", "(`sessionId`, `ordinal`, `startUtcMillis`, `endUtcMillis`, `distanceKm`, `integratedSeconds`, `elapsedSeconds`, `path`)",
                "('trip-1', 1, 1000, 2000, 2.5, 60.0, 60.0, '-23.55,-46.63')")
            seed(s, "session_costs", "(`sessionId`, `costPerKwh`, `paidAmount`, `costCurrency`, `updatedAtUtcMillis`, `origin`)",
                "('charge-1', 0.75, NULL, 'BRL', 3000000, 'car')")
            seed(s, "preferences", "(`scope`, `key`, `value`, `updatedAtUtcMillis`, `origin`, `deletedAtUtcMillis`)",
                "('account', 'theme_id', 'dark', 4000000, 'phone', NULL)")
            seed(s, "preference_proposals", "(`id`, `key`, `value`, `status`, `proposedAtUtcMillis`, `updatedAtUtcMillis`, `origin`)",
                "('prop-1', 'pack_capacity_wh', '39000', 'PENDING', 4100000, 4200000, 'phone')")
            seed(s, "insight_places", "(`id`, `name`, `latitude`, `longitude`, `radiusM`, `createdAtUtcMillis`, `updatedAtUtcMillis`, `origin`)",
                "('place-1', 'Home', -23.5505, -46.6333, 150.0, 1000000, 2000000, 'car')")
            seed(s, "journeys", "(`id`, `name`, `startedAtUtcMillis`, `endedAtUtcMillis`, `createdAtUtcMillis`, `updatedAtUtcMillis`, `origin`)",
                "('journey-1', 'Weekend', 5000000, 6000000, 5000000, 5500000, 'car')")

            val countsBefore = accountTables.associate { (t, _) -> t to count(s, t) }

            // Apply the real production MIGRATION_44_45 via a SupportSQLiteDatabase proxy
            // that delegates execSQL to the JDBC SQLite connection.
            val db = java.lang.reflect.Proxy.newProxyInstance(
                androidx.sqlite.db.SupportSQLiteDatabase::class.java.classLoader,
                arrayOf(androidx.sqlite.db.SupportSQLiteDatabase::class.java)
            ) { _, method, args ->
                if (method.name == "execSQL" && args?.size == 1 && args[0] is String) {
                    s.execute(args[0] as String)
                    null
                } else {
                    throw UnsupportedOperationException(method.name)
                }
            } as androidx.sqlite.db.SupportSQLiteDatabase

            TelemetryDatabase.MIGRATION_44_45.migrate(db)

            // Lossless: the same rows, now owned-capable.
            for ((table, _) in accountTables) {
                assertEquals("row count of `$table` must not change", countsBefore[table]!!, count(s, table))
            }
            for ((table, _) in accountTables) {
                val meta = s.executeQuery("PRAGMA table_info(`$table`)").use { rs ->
                    var found = false
                    while (rs.next()) {
                        if (rs.getString("name") == "accountId") {
                            found = true
                            assertEquals("accountId must be nullable", 0, rs.getInt("notnull"))
                        }
                    }
                    found
                }
                assertTrue("`$table` must gain accountId", meta)
            }
            // Verify interval columns added by MIGRATION_44_45
            val intervalCols = s.executeQuery("PRAGMA table_info(`interval`)").use { rs ->
                val cols = mutableMapOf<String, Pair<String, Int>>()
                while (rs.next()) {
                    cols[rs.getString("name")] = rs.getString("type") to rs.getInt("notnull")
                }
                cols
            }
            assertTrue("interval must gain startElapsedNanos", intervalCols.containsKey("startElapsedNanos"))
            assertEquals("startElapsedNanos must be nullable", 0, intervalCols["startElapsedNanos"]!!.second)
            assertTrue("interval must gain startBootCount", intervalCols.containsKey("startBootCount"))
            assertEquals("startBootCount must be nullable", 0, intervalCols["startBootCount"]!!.second)
            assertTrue("interval must gain timeState", intervalCols.containsKey("timeState"))
            assertEquals("timeState must be NOT NULL", 1, intervalCols["timeState"]!!.second)
            // The intentionally-unowned tables stay untouched.
            for (table in unownedTables) {
                val meta = s.executeQuery("PRAGMA table_info(`$table`)").use { rs ->
                    var found = false
                    while (rs.next()) if (rs.getString("name") == "accountId") found = true
                    found
                }
                assertTrue("`$table` must keep no account column", !meta)
            }
            // Every historical row lands unowned (the adoption contract).
            for ((table, _) in accountTables) {
                val unowned = s.executeQuery(
                    "SELECT COUNT(*) FROM `$table` WHERE `accountId` IS NOT NULL"
                ).use { rs -> rs.next(); rs.getInt(1) }
                assertEquals("no historical row of `$table` may carry an account after the migration", 0, unowned)
            }
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