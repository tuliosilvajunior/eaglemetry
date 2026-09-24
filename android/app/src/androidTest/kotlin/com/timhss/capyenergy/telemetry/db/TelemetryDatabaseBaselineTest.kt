package com.timhss.capyenergy.telemetry.db

import androidx.room.testing.MigrationTestHelper
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

private const val TEST_DB = "migration-test.db"

@RunWith(AndroidJUnit4::class)
class TelemetryDatabaseBaselineTest {

    @get:Rule
    val helper = MigrationTestHelper(
        InstrumentationRegistry.getInstrumentation(),
        TelemetryDatabase::class.java
    )

    @After
    fun cleanup() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        context.deleteDatabase(TEST_DB)
        val dbDir = context.getDatabasePath(TEST_DB).parentFile
        dbDir?.listFiles { file ->
            file.name.startsWith(TEST_DB)
        }?.forEach { it.delete() }
    }

    @Test
    fun freshInstallBuildsSchema32Directly() {
        helper.createDatabase(TEST_DB, 32).use { db ->
            // Verify new unified tables exist in fresh install
            db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='session'").use {
                assertTrue("session table must exist", it.moveToFirst())
            }
            db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='interval'").use {
                assertTrue("interval table must exist", it.moveToFirst())
            }
            db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='insight_places'").use {
                assertTrue("insight_places table must exist", it.moveToFirst())
            }
            db.query("PRAGMA table_info(telemetry_events)").use { cursor ->
                var hasSessionId = false
                while (cursor.moveToNext()) {
                    val colName = cursor.getString(cursor.getColumnIndexOrThrow("name"))
                    if (colName == "sessionId") {
                        hasSessionId = true
                    }
                }
                assertTrue("telemetry_events must have sessionId column", hasSessionId)
            }
        }
    }

    @Test
    fun migration31To32AddsSessionIdColumnAndIndex() {
        helper.createDatabase(TEST_DB, 31).use { db ->
            db.execSQL(
                "INSERT INTO `telemetry_events` (`id`, `type`, `occurredAtUtcMillis`, `occurredAtElapsedNanos`, `sourceTimestampNanos`, `timestampAccuracy`, `uncertaintyMillis`, `signalId`, `value`, `previousValue`, `quality`, `source`, `details`) " +
                    "VALUES (1, 'SIGNAL_UPDATED', 1000, 100, NULL, 'ACCURATE', 0, 'GEAR', '4', NULL, NULL, NULL, 'details')"
            )
        }

        helper.runMigrationsAndValidate(TEST_DB, 32, true, TelemetryDatabase.MIGRATION_31_32).use { db ->
            db.query("SELECT id, sessionId FROM telemetry_events WHERE id = 1").use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals(1L, cursor.getLong(0))
                assertTrue("Existing events should have null sessionId after migration", cursor.isNull(1))
            }
            db.query("SELECT name FROM sqlite_master WHERE type='index' AND name='index_telemetry_events_sessionId_occurredAtUtcMillis'").use { cursor ->
                assertTrue("Index on (sessionId, occurredAtUtcMillis) must exist", cursor.moveToFirst())
            }
        }
    }

    @Test
    fun v30DatabaseDestructiveFallbackClearsMeasurementTables() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        helper.createDatabase(TEST_DB, 30).use { db ->
            db.execSQL(
                "INSERT INTO `trip_sessions` (`id`, `status`, `startedAtUtcMillis`, `startedAtElapsedNanos`, `endedAtUtcMillis`, `endedAtElapsedNanos`, `startSoc`, `endSoc`, `startOdometerKm`, `endOdometerKm`, `startGear`, `capacityWh`, `createdAtUtcMillis`, `updatedAtUtcMillis`) " +
                    "VALUES ('trip-1', 'CLOSED', 1000, 100, 2000, 200, 80.0, 75.0, 100.0, 110.0, 4, 39400.0, 1000, 2000)"
            )
            db.execSQL(
                "INSERT INTO `charge_sessions` (`id`, `status`, `plugConnectedAtUtcMillis`, `plugConnectedAtElapsedNanos`, `plugDisconnectedAtUtcMillis`, `plugDisconnectedAtElapsedNanos`, `startSoc`, `endSoc`, `startOdometerKm`, `endOdometerKm`, `createdAtUtcMillis`, `updatedAtUtcMillis`) " +
                    "VALUES ('charge-1', 'CLOSED', 3000, 300, 4000, 400, 20.0, 80.0, 110.0, 110.0, 3000, 4000)"
            )
        }

        // Open database using TelemetryDatabase.buildDatabase which applies destructive migration for legacy upgrades
        val db = TelemetryDatabase.buildDatabase(context, TEST_DB)
        try {
            assertEquals("Measurement sessions must be wiped on fallback", 0L, db.sessionDao().count())
            val orphan30 = File(context.getDatabasePath(TEST_DB).parentFile, "$TEST_DB.30.orphan")
            assertTrue("No orphan file should be created on legacy upgrade destructive fallback", !orphan30.exists())
        } finally {
            db.close()
        }
    }

    @Test
    fun downgradeFromSchema39To38QuarantinesDatabaseAndPreservesSessions() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        helper.createDatabase(TEST_DB, 39).use { db ->
            db.execSQL(
                "INSERT INTO `session` (`id`, `vehicleId`, `kind`, `status`, " +
                    "`startedAtUtcMillis`, `startedAtElapsedNanos`, `noLongerReducible`, " +
                    "`createdAtUtcMillis`, `updatedAtUtcMillis`) " +
                    "VALUES ('trip-preserved', 'car', 'TRIP', 'ENDED', 1000, 1000, 0, 1000, 1000)"
            )
        }

        // Build database simulating target schema 38 while file on disk is schema 39
        val db = TelemetryDatabase.buildDatabase(context, TEST_DB, targetSchemaVersion = 38)
        try {
            assertEquals("New database instance starts clean", 0L, db.sessionDao().count())
        } finally {
            db.close()
        }

        val orphanFile = File(context.getDatabasePath(TEST_DB).parentFile, "$TEST_DB.39.orphan")
        assertTrue("Orphan database file must be created on downgrade", orphanFile.exists())

        // Read preserved session directly from the quarantined orphan database
        android.database.sqlite.SQLiteDatabase.openDatabase(
            orphanFile.path,
            null,
            android.database.sqlite.SQLiteDatabase.OPEN_READONLY
        ).use { orphanDb ->
            orphanDb.rawQuery("SELECT id, vehicleId FROM session WHERE id = 'trip-preserved'", null).use { cursor ->
                assertTrue("Recorded session must still exist in orphan database", cursor.moveToFirst())
                assertEquals("trip-preserved", cursor.getString(0))
                assertEquals("car", cursor.getString(1))
            }
        }
    }

    @Test
    fun insightPlacesSurvivesV30DestructiveFallback() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        helper.createDatabase(TEST_DB, 30).use { db ->
            db.execSQL(
                "INSERT INTO `insight_places` (`id`, `name`, `latitude`, `longitude`, `radiusM`, `createdAtUtcMillis`, `updatedAtUtcMillis`) " +
                    "VALUES ('home-1', 'Home', -23.5505, -46.6333, 150.0, 1000000, 2000000)"
            )
        }

        // Open database using TelemetryDatabase.buildDatabase which restores preserved places
        val db = TelemetryDatabase.buildDatabase(context, TEST_DB)
        try {
            val places = db.insightPlaceDao().all()
            assertEquals("insight_places must be preserved across destructive baseline reset", 1, places.size)
            val place = places.first()
            assertEquals("home-1", place.id)
            assertEquals("Home", place.name)
            assertEquals(-23.5505, place.latitude, 0.00001)
            assertEquals(-46.6333, place.longitude, 0.00001)
            assertEquals(150.0, place.radiusM, 0.001)
            assertEquals(1000000L, place.createdAtUtcMillis)
            assertEquals(2000000L, place.updatedAtUtcMillis)
        } finally {
            db.close()
        }
    }

    /**
     * Schema 33 -> 34: the annotation tables land and a charge's price leaves
     * the session measurement table.
     *
     * The cost columns on `session` stay (the row shape is frozen), but an
     * existing price must travel into `session_costs`, and a place must gain
     * the annotation columns with car defaults. Everything else is untouched:
     * this is the one migration that must not lose a recorded drive.
     */
    @Test
    fun migration33To34MovesCostAndAddsAnnotationColumns() {
        helper.createDatabase(TEST_DB, 33).use { db ->
            db.execSQL(
                "INSERT INTO `session` (`id`, `vehicleId`, `kind`, `status`, " +
                    "`startedAtUtcMillis`, `startedAtElapsedNanos`, `noLongerReducible`, `createdAtUtcMillis`, `updatedAtUtcMillis`, " +
                    "`costPerKwh`, `paidAmount`, `costCurrency`) " +
                    "VALUES ('charge-1', 'v1', 'CHARGE', 'CLOSED', 1000, 100, 0, 1000, 2000, 0.75, NULL, 'BRL')"
            )
            db.execSQL(
                "INSERT INTO `session` (`id`, `vehicleId`, `kind`, `status`, " +
                    "`startedAtUtcMillis`, `startedAtElapsedNanos`, `noLongerReducible`, `createdAtUtcMillis`, `updatedAtUtcMillis`, " +
                    "`costPerKwh`, `paidAmount`, `costCurrency`) " +
                    "VALUES ('trip-1', 'v1', 'TRIP', 'CLOSED', 1000, 100, 0, 1000, 2000, NULL, NULL, NULL)"
            )
            db.execSQL(
                "INSERT INTO `insight_places` (`id`, `name`, `latitude`, `longitude`, `radiusM`, `createdAtUtcMillis`, `updatedAtUtcMillis`) " +
                    "VALUES ('home-1', 'Home', -23.5505, -46.6333, 150.0, 1000000, 2000000)"
            )
        }

        helper.runMigrationsAndValidate(
            TEST_DB, 34, true,
            TelemetryDatabase.MIGRATION_33_34
        ).use { db ->
            // The price moved, not the row.
            db.query(
                "SELECT `costPerKwh`, `paidAmount`, `costCurrency`, `origin` FROM `session_costs` WHERE `sessionId` = 'charge-1'"
            ).use { cursor ->
                assertTrue("priced charge must have a cost annotation", cursor.moveToFirst())
                assertEquals(0.75, cursor.getDouble(0), 0.0001)
                assertTrue(cursor.isNull(1))
                assertEquals("BRL", cursor.getString(2))
                assertEquals("car", cursor.getString(3))
            }
            db.query(
                "SELECT COUNT(*) FROM `session_costs` WHERE `sessionId` = 'trip-1'"
            ).use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals("an unpriced session must have no cost row", 0L, cursor.getLong(0))
            }
            // The place gained the annotation columns with car defaults.
            db.query(
                "SELECT `accountId`, `origin`, `deletedAtUtcMillis` FROM `insight_places` WHERE `id` = 'home-1'"
            ).use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertTrue(cursor.isNull(0))
                assertEquals("car", cursor.getString(1))
                assertTrue(cursor.isNull(2))
            }
            // The session table still has the session.
            db.query("SELECT COUNT(*) FROM `session` WHERE `id` IN ('charge-1', 'trip-1')").use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals(2L, cursor.getLong(0))
            }
        }
    }

    /**
     * The migration is additive, and additive is exactly what has to be proved.
     *
     * The database is opened with `fallbackToDestructiveMigration()`. A
     * migration Room refuses does not crash the app: it drops the database and
     * builds it again, and every recorded trip and charge on the vehicle is
     * gone. `v30DatabaseDestructiveFallbackClearsMeasurementTables` above shows
     * that path is live. So this asserts both halves: the new columns arrive
     * empty, and the rows that were already there still hold their energy.
     */
    @Test
    fun migration36To37AddsSocColumnsAndKeepsTheEnergy() {
        helper.createDatabase(TEST_DB, 36).use { db ->
            db.execSQL(
                "INSERT INTO `interval` (`sessionId`, `startUtcMillis`, `widthMillis`, " +
                    "`tractionWh`, `regenWh`, `auxiliaryWh`, `climateWh`, `deliveredWh`, " +
                    "`distanceKm`, `coveredSeconds`, `climateCoveredSeconds`, " +
                    "`speedCoveredSeconds`, `deliveredCoveredSeconds`, `updatedAtUtcMillis`) " +
                    "VALUES ('trip-1', 60000, 60000, 120.5, 8.25, 30.0, 12.0, 0.0, " +
                    "1.5, 60.0, 60.0, 60.0, 0.0, 99000)"
            )
        }

        helper.runMigrationsAndValidate(
            TEST_DB, 37, true,
            TelemetryDatabase.MIGRATION_36_37
        ).use { db ->
            db.query(
                "SELECT `startSoc`, `endSoc`, `tractionWh`, `regenWh`, " +
                    "`auxiliaryWh`, `climateWh`, `distanceKm`, `coveredSeconds` " +
                    "FROM `interval` WHERE `sessionId` = 'trip-1'"
            ).use { cursor ->
                assertTrue("the stored minute must survive the migration", cursor.moveToFirst())
                // A minute recorded before the columns existed has no reading,
                // and says so. It does not report a zero charge.
                assertTrue("startSoc must arrive empty, not zero", cursor.isNull(0))
                assertTrue("endSoc must arrive empty, not zero", cursor.isNull(1))
                assertEquals(120.5, cursor.getDouble(2), 0.0001)
                assertEquals(8.25, cursor.getDouble(3), 0.0001)
                assertEquals(30.0, cursor.getDouble(4), 0.0001)
                assertEquals(12.0, cursor.getDouble(5), 0.0001)
                assertEquals(1.5, cursor.getDouble(6), 0.0001)
                assertEquals(60.0, cursor.getDouble(7), 0.0001)
            }
        }
    }

    /**
     * A charge written after the migration keeps both readings.
     */
    @Test
    fun migration36To37AcceptsAWrittenCharge() {
        helper.createDatabase(TEST_DB, 36).close()
        helper.runMigrationsAndValidate(
            TEST_DB, 37, true,
            TelemetryDatabase.MIGRATION_36_37
        ).use { db ->
            db.execSQL(
                "INSERT INTO `interval` (`sessionId`, `startUtcMillis`, `widthMillis`, " +
                    "`tractionWh`, `regenWh`, `auxiliaryWh`, `climateWh`, `deliveredWh`, " +
                    "`distanceKm`, `coveredSeconds`, `climateCoveredSeconds`, " +
                    "`speedCoveredSeconds`, `deliveredCoveredSeconds`, `startSoc`, `endSoc`, " +
                    "`updatedAtUtcMillis`) " +
                    "VALUES ('charge-1', 120000, 60000, 0.0, 0.0, 0.0, 0.0, 2000.0, " +
                    "0.0, 60.0, 0.0, 0.0, 60.0, 41.5, 42.0, 99000)"
            )
            db.query(
                "SELECT `startSoc`, `endSoc` FROM `interval` WHERE `sessionId` = 'charge-1'"
            ).use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals(41.5, cursor.getDouble(0), 0.0001)
                assertEquals(42.0, cursor.getDouble(1), 0.0001)
            }
        }
    }

    /**
     * The Track table lands and the Session gains its three numbers.
     *
     * A session recorded before this migration has no route and no climb. Both
     * must arrive empty rather than as a zero: a drive with no altitude reading
     * is not a drive over flat ground, and the reader has to be able to tell
     * the difference.
     */
    @Test
    fun migration37To38AddsTheTrackAndTheSessionNumbers() {
        helper.createDatabase(TEST_DB, 37).use { db ->
            db.execSQL(
                "INSERT INTO `session` (`id`, `vehicleId`, `kind`, `status`, " +
                    "`startedAtUtcMillis`, `startedAtElapsedNanos`, `noLongerReducible`, " +
                    "`createdAtUtcMillis`, `updatedAtUtcMillis`) " +
                    "VALUES ('trip-old', 'car', 'TRIP', 'ENDED', 1000, 1000, 0, 1000, 1000)"
            )
        }

        helper.runMigrationsAndValidate(
            TEST_DB, 38, true,
            TelemetryDatabase.MIGRATION_37_38
        ).use { db ->
            db.query(
                "SELECT `climbM`, `descentM`, `fixCount` FROM `session` WHERE `id` = 'trip-old'"
            ).use { cursor ->
                assertTrue("the stored session must survive", cursor.moveToFirst())
                assertTrue("climbM must arrive empty, not zero", cursor.isNull(0))
                assertTrue("descentM must arrive empty, not zero", cursor.isNull(1))
                assertTrue("fixCount must arrive empty, not zero", cursor.isNull(2))
            }
            db.query("SELECT COUNT(*) FROM `track`").use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals(0, cursor.getInt(0))
            }
        }
    }

    /** One row per session, and the second write replaces the first. */
    @Test
    fun migration37To38AcceptsATrackAndKeepsOnePerSession() {
        helper.createDatabase(TEST_DB, 37).close()
        helper.runMigrationsAndValidate(
            TEST_DB, 38, true,
            TelemetryDatabase.MIGRATION_37_38
        ).use { db ->
            db.execSQL(
                "INSERT OR REPLACE INTO `track` " +
                    "(`sessionId`, `encodingVersion`, `pointCount`, `t`, `path`, `speed`, `alt`) " +
                    "VALUES ('trip-1', 1, 2, '[0,1000]', 'abcd', '[500,500]', '[1000,0]')"
            )
            db.execSQL(
                "INSERT OR REPLACE INTO `track` " +
                    "(`sessionId`, `encodingVersion`, `pointCount`, `t`, `path`, `speed`, `alt`) " +
                    "VALUES ('trip-1', 1, 3, '[0,1000,1000]', 'efgh', '[500,500,0]', '[1000,0,0]')"
            )
            db.query("SELECT `pointCount`, `path` FROM `track` WHERE `sessionId` = 'trip-1'")
                .use { cursor ->
                    assertEquals(1, cursor.count)
                    assertTrue(cursor.moveToFirst())
                    assertEquals(3, cursor.getInt(0))
                    assertEquals("efgh", cursor.getString(1))
                }
        }
    }

    /**
     * The route earns the write stamp the sync pages over. Issue 179.
     *
     * A route recorded before this migration arrives at zero, which is the
     * front of that queue, so the first sync after the update offers it. A
     * stamp of now would put it behind a cursor a phone may already hold, and
     * that route would never cross.
     */
    @Test
    fun migration38To39StampsExistingRoutesAtTheFrontOfTheQueue() {
        helper.createDatabase(TEST_DB, 37).close()
        helper.runMigrationsAndValidate(
            TEST_DB, 38, true,
            TelemetryDatabase.MIGRATION_37_38
        ).use { db ->
            db.execSQL(
                "INSERT INTO `track` " +
                    "(`sessionId`, `encodingVersion`, `pointCount`, `t`, `path`, `speed`, `alt`) " +
                    "VALUES ('trip-old', 1, 2, '[0,1000]', 'abcd', '[500,500]', '[1000,0]')"
            )
        }

        helper.runMigrationsAndValidate(
            TEST_DB, 39, true,
            TelemetryDatabase.MIGRATION_38_39
        ).use { db ->
            db.query(
                "SELECT `updatedAtUtcMillis`, `pointCount` FROM `track` " +
                    "WHERE `sessionId` = 'trip-old'"
            ).use { cursor ->
                assertTrue("the recorded route must survive", cursor.moveToFirst())
                assertEquals(0L, cursor.getLong(0))
                assertEquals(2, cursor.getInt(1))
            }
        }
    }

    /** The stream order the sync reads: the write stamp, then the session. */
    @Test
    fun migration38To39OrdersRoutesByTheirWriteStamp() {
        helper.createDatabase(TEST_DB, 37).close()
        helper.runMigrationsAndValidate(
            TEST_DB, 38, true,
            TelemetryDatabase.MIGRATION_37_38
        ).close()

        helper.runMigrationsAndValidate(
            TEST_DB, 39, true,
            TelemetryDatabase.MIGRATION_38_39
        ).use { db ->
            for ((id, stamp) in listOf("trip-b" to 5000, "trip-a" to 5000, "trip-c" to 1000)) {
                db.execSQL(
                    "INSERT INTO `track` (`sessionId`, `encodingVersion`, `pointCount`, " +
                        "`t`, `path`, `speed`, `alt`, `updatedAtUtcMillis`) " +
                        "VALUES ('$id', 1, 1, '[0]', 'ab', '[0]', '[0]', $stamp)"
                )
            }
            db.query(
                "SELECT `sessionId` FROM `track` " +
                    "ORDER BY `updatedAtUtcMillis` ASC, `sessionId` ASC"
            ).use { cursor ->
                val order = mutableListOf<String>()
                while (cursor.moveToNext()) order.add(cursor.getString(0))
                assertEquals(listOf("trip-c", "trip-a", "trip-b"), order)
            }
        }
    }

    /**
     * Schema 40 -> 41: the Sample stream dies, and the routes it carried move
     * onto Track.
     *
     * A session recorded before issue 184 holds position rows under `sample`
     * but no Track row. The migration must turn those rows into a Track (plus
     * the Session's climb/descent/fixCount) and then drop the table; a session
     * recorded after #184 already has a Track and must keep it untouched.
     */
    @Test
    fun migration40To41BackfillsTracksFromSamplesThenDropsTheTable() {
        helper.createDatabase(TEST_DB, 40).use { db ->
            db.execSQL(
                "INSERT INTO `session` (`id`, `vehicleId`, `kind`, `status`, " +
                    "`startedAtUtcMillis`, `startedAtElapsedNanos`, `noLongerReducible`, " +
                    "`createdAtUtcMillis`, `updatedAtUtcMillis`) " +
                    "VALUES ('trip-pre184', 'car', 'TRIP', 'ENDED', 1000, 1000, 0, 1000, 1000)"
            )
            db.execSQL(
                "INSERT INTO `session` (`id`, `vehicleId`, `kind`, `status`, " +
                    "`startedAtUtcMillis`, `startedAtElapsedNanos`, `noLongerReducible`, " +
                    "`createdAtUtcMillis`, `updatedAtUtcMillis`) " +
                    "VALUES ('trip-with-track', 'car', 'TRIP', 'ENDED', 2000, 2000, 0, 2000, 2000)"
            )
            // Pre-184 route: two fixes sharing a GPS group id.
            db.execSQL(
                "INSERT INTO `sample` (`sessionId`, `tUtcMillis`, `tElapsedNanos`, `key`, " +
                    "`value`, `validity`, `groupId`) " +
                    "VALUES ('trip-pre184', 1000, 1000, 'LATITUDE', -23.550520, 'MEASURED', 'pos_1000')"
            )
            db.execSQL(
                "INSERT INTO `sample` (`sessionId`, `tUtcMillis`, `tElapsedNanos`, `key`, " +
                    "`value`, `validity`, `groupId`) " +
                    "VALUES ('trip-pre184', 1000, 1000, 'LONGITUDE', -46.633308, 'MEASURED', 'pos_1000')"
            )
            db.execSQL(
                "INSERT INTO `sample` (`sessionId`, `tUtcMillis`, `tElapsedNanos`, `key`, " +
                    "`value`, `validity`, `groupId`) " +
                    "VALUES ('trip-pre184', 1000, 1000, 'ALTITUDE', 750.0, 'MEASURED', 'pos_1000')"
            )
            db.execSQL(
                "INSERT INTO `sample` (`sessionId`, `tUtcMillis`, `tElapsedNanos`, `key`, " +
                    "`value`, `validity`, `groupId`) " +
                    "VALUES ('trip-pre184', 1000, 1000, 'VEHICLE_SPEED', 30.0, 'MEASURED', NULL)"
            )
            db.execSQL(
                "INSERT INTO `sample` (`sessionId`, `tUtcMillis`, `tElapsedNanos`, `key`, " +
                    "`value`, `validity`, `groupId`) " +
                    "VALUES ('trip-pre184', 3000, 6000, 'LATITUDE', -23.552000, 'MEASURED', 'pos_6000')"
            )
            db.execSQL(
                "INSERT INTO `sample` (`sessionId`, `tUtcMillis`, `tElapsedNanos`, `key`, " +
                    "`value`, `validity`, `groupId`) " +
                    "VALUES ('trip-pre184', 3000, 6000, 'LONGITUDE', -46.635000, 'MEASURED', 'pos_6000')"
            )
            db.execSQL(
                "INSERT INTO `sample` (`sessionId`, `tUtcMillis`, `tElapsedNanos`, `key`, " +
                    "`value`, `validity`, `groupId`) " +
                    "VALUES ('trip-pre184', 3000, 6000, 'ALTITUDE', 770.0, 'MEASURED', 'pos_6000')"
            )
            // A charge's SOC rows carry no position and must not earn a track.
            db.execSQL(
                "INSERT INTO `sample` (`sessionId`, `tUtcMillis`, `tElapsedNanos`, `key`, " +
                    "`value`, `validity`, `groupId`) " +
                    "VALUES ('trip-pre184', 5000, 8000, 'HV_BATTERY_SOC', 75.0, 'MEASURED', NULL)"
            )
            // A session that already has a Track row is left alone.
            db.execSQL(
                "INSERT INTO `track` (`sessionId`, `encodingVersion`, `pointCount`, " +
                    "`t`, `path`, `speed`, `alt`, `updatedAtUtcMillis`) " +
                    "VALUES ('trip-with-track', 1, 1, '[0]', 'ab', '[0]', '[0]', 0)"
            )
        }

        helper.runMigrationsAndValidate(
            TEST_DB, 41, true,
            TelemetryDatabase.MIGRATION_40_41
        ).use { db ->
            db.query(
                "SELECT `pointCount`, `t`, `path`, `speed`, `alt` FROM `track` WHERE `sessionId` = 'trip-pre184'"
            ).use { cursor ->
                assertTrue("the pre-184 route must earn a Track row", cursor.moveToFirst())
                assertEquals(2, cursor.getInt(0))
                assertEquals(2, cursor.getInt(0))
            }
            db.query(
                "SELECT `climbM`, `descentM`, `fixCount` FROM `session` WHERE `id` = 'trip-pre184'"
            ).use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals(20.0, cursor.getDouble(0), 0.001)
                assertEquals(0.0, cursor.getDouble(1), 0.001)
                assertEquals(2, cursor.getInt(2))
            }
            db.query(
                "SELECT `pointCount` FROM `track` WHERE `sessionId` = 'trip-with-track'"
            ).use { cursor ->
                assertTrue("an existing Track must survive untouched", cursor.moveToFirst())
                assertEquals(1, cursor.getInt(0))
            }
            db.query(
                "SELECT COUNT(*) FROM `sqlite_master` WHERE `type` = 'table' AND `name` = 'sample'"
            ).use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals("the sample table must be dropped", 0L, cursor.getLong(0))
            }
        }
    }

    /**
     * The 40 -> 41 migration also fills climb and descent from altitude rows
     * when no fix ever landed, and leaves an invalid reading off the path.
     */
    @Test
    fun migration40To41IgnoresInvalidReadingsAndEmptyRoutes() {
        helper.createDatabase(TEST_DB, 40).use { db ->
            db.execSQL(
                "INSERT INTO `session` (`id`, `vehicleId`, `kind`, `status`, " +
                    "`startedAtUtcMillis`, `startedAtElapsedNanos`, `noLongerReducible`, " +
                    "`createdAtUtcMillis`, `updatedAtUtcMillis`) " +
                    "VALUES ('trip-no-fix', 'car', 'TRIP', 'ENDED', 1000, 1000, 0, 1000, 1000)"
            )
            db.execSQL(
                "INSERT INTO `sample` (`sessionId`, `tUtcMillis`, `tElapsedNanos`, `key`, " +
                    "`value`, `validity`, `groupId`) " +
                    "VALUES ('trip-no-fix', 1000, 1000, 'LATITUDE', NULL, 'INVALID', 'pos_1000')"
            )
            db.execSQL(
                "INSERT INTO `sample` (`sessionId`, `tUtcMillis`, `tElapsedNanos`, `key`, " +
                    "`value`, `validity`, `groupId`) " +
                    "VALUES ('trip-no-fix', 1000, 1000, 'LONGITUDE', NULL, 'INVALID', 'pos_1000')"
            )
        }

        helper.runMigrationsAndValidate(
            TEST_DB, 41, true,
            TelemetryDatabase.MIGRATION_40_41
        ).use { db ->
            db.query(
                "SELECT COUNT(*) FROM `track` WHERE `sessionId` = 'trip-no-fix'"
            ).use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals(0L, cursor.getLong(0))
            }
        }
    }

    /**
     * The pending mark lands, and every row already stored is marked not yet
     * uploaded.
     *
     * The database is opened with `fallbackToDestructiveMigration()`. A
     * migration Room refuses does not crash the app: it drops the database
     * and builds it again, and every recorded trip and charge on the vehicle
     * is gone. `v30DatabaseDestructiveFallbackClearsMeasurementTables` shows
     * that path is live. So this inserts a real row into each of the five
     * measurement tables at schema 42 and asserts, after the migration, that
     * every row survived with its content intact, that `dirty` exists on all
     * five tables, and that every historical row — and every row written
     * after the migration — reads dirty. An empty database would pass all of
     * that trivially, which is why the rows come first.
     */
    @Test
    fun migration42To43MarksEveryHistoricalRowAsNotYetUploaded() {
        helper.createDatabase(TEST_DB, 42).use { db ->
            db.execSQL(
                "INSERT INTO `session` (`id`, `vehicleId`, `kind`, `status`, " +
                    "`startedAtUtcMillis`, `startedAtElapsedNanos`, `noLongerReducible`, " +
                    "`createdAtUtcMillis`, `updatedAtUtcMillis`) " +
                    "VALUES ('trip-1', 'car', 'TRIP', 'ENDED', 1000, 100, 0, 1000, 5000)"
            )
            db.execSQL(
                "INSERT INTO `interval` (`sessionId`, `startUtcMillis`, `widthMillis`, " +
                    "`tractionWh`, `regenWh`, `auxiliaryWh`, `climateWh`, `deliveredWh`, " +
                    "`distanceKm`, `coveredSeconds`, `climateCoveredSeconds`, " +
                    "`speedCoveredSeconds`, `deliveredCoveredSeconds`, `updatedAtUtcMillis`) " +
                    "VALUES ('trip-1', 60000, 60000, 120.5, 8.25, 30.0, 12.0, 0.0, " +
                    "1.5, 60.0, 60.0, 60.0, 0.0, 99000)"
            )
            db.execSQL(
                "INSERT INTO `telemetry_events` (`id`, `type`, `occurredAtUtcMillis`, " +
                    "`occurredAtElapsedNanos`, `sourceTimestampNanos`, `timestampAccuracy`, " +
                    "`uncertaintyMillis`, `signalId`, `value`, `previousValue`, `quality`, " +
                    "`source`, `details`) " +
                    "VALUES (1, 'SIGNAL_UPDATED', 1000, 100, NULL, 'ACCURATE', 0, 'GEAR', " +
                    "'4', NULL, NULL, NULL, 'details')"
            )
            db.execSQL(
                "INSERT INTO `track` (`sessionId`, `encodingVersion`, `pointCount`, " +
                    "`t`, `path`, `speed`, `alt`, `updatedAtUtcMillis`) " +
                    "VALUES ('trip-1', 1, 2, '[0,1000]', 'abcd', '[500,500]', '[1000,0]', 4200)"
            )
            db.execSQL(
                "INSERT INTO `battery_cycles` (`ordinal`, `startUtcMillis`, `endUtcMillis`, " +
                    "`dischargePercent`, `distanceKm`, `tripEnergyKwh`, `parkedEnergyKwh`, " +
                    "`parkedSocPercent`, `cost`, `costCurrency`, `pricedEnergyKwh`, " +
                    "`unpricedEnergyKwh`, `isOpen`, `isPartial`, `energyIncomplete`, " +
                    "`mixedCurrency`, `openingPricedFraction`, `openingBlendedPrice`, " +
                    "`frozenAtUtcMillis`, `createdAtUtcMillis`, `updatedAtUtcMillis`) " +
                    "VALUES (1, 1000, 2000, 12.5, 20.0, 3000.0, 100.0, 3.1, 0.75, 'BRL', " +
                    "2800.0, 200.0, 0, 0, 0, 0, 0.9, 0.35, NULL, 1000, 2000)"
            )
        }

        helper.runMigrationsAndValidate(
            TEST_DB, 43, true,
            TelemetryDatabase.MIGRATION_42_43
        ).use { db ->
            db.query(
                "SELECT `status`, `updatedAtUtcMillis`, `dirty` FROM `session` WHERE `id` = 'trip-1'"
            ).use { cursor ->
                assertTrue("the stored session must survive the migration", cursor.moveToFirst())
                assertEquals("ENDED", cursor.getString(0))
                assertEquals(5000L, cursor.getLong(1))
                assertEquals("a historical session must be marked not yet uploaded", 1L, cursor.getLong(2))
            }
            db.query(
                "SELECT `tractionWh`, `distanceKm`, `dirty` FROM `interval` " +
                    "WHERE `sessionId` = 'trip-1' AND `startUtcMillis` = 60000"
            ).use { cursor ->
                assertTrue("the stored minute must survive the migration", cursor.moveToFirst())
                assertEquals(120.5, cursor.getDouble(0), 0.0001)
                assertEquals(1.5, cursor.getDouble(1), 0.0001)
                assertEquals("a historical interval must be marked not yet uploaded", 1L, cursor.getLong(2))
            }
            db.query(
                "SELECT `signalId`, `value`, `dirty` FROM `telemetry_events` WHERE `id` = 1"
            ).use { cursor ->
                assertTrue("the stored event must survive the migration", cursor.moveToFirst())
                assertEquals("GEAR", cursor.getString(0))
                assertEquals("4", cursor.getString(1))
                assertEquals("a historical event must be marked not yet uploaded", 1L, cursor.getLong(2))
            }
            db.query(
                "SELECT `pointCount`, `path`, `dirty` FROM `track` WHERE `sessionId` = 'trip-1'"
            ).use { cursor ->
                assertTrue("the stored route must survive the migration", cursor.moveToFirst())
                assertEquals(2, cursor.getInt(0))
                assertEquals("abcd", cursor.getString(1))
                assertEquals("a historical track must be marked not yet uploaded", 1L, cursor.getLong(2))
            }
            db.query(
                "SELECT `dischargePercent`, `cost`, `costCurrency`, `dirty` " +
                    "FROM `battery_cycles` WHERE `ordinal` = 1"
            ).use { cursor ->
                assertTrue("the stored cycle must survive the migration", cursor.moveToFirst())
                assertEquals(12.5, cursor.getDouble(0), 0.0001)
                assertEquals(0.75, cursor.getDouble(1), 0.0001)
                assertEquals("BRL", cursor.getString(2))
                assertEquals("a historical cycle must be marked not yet uploaded", 1L, cursor.getLong(3))
            }
            for (table in listOf("session", "interval", "telemetry_events", "track", "battery_cycles")) {
                db.query("SELECT COUNT(*) FROM `$table` WHERE `dirty` != 1").use { cursor ->
                    assertTrue(cursor.moveToFirst())
                    assertEquals("no row of `$table` may read uploaded after the migration", 0L, cursor.getLong(0))
                }
            }
            db.query(
                "SELECT name FROM sqlite_master WHERE type='index' AND name='index_session_dirty_id'"
            ).use { cursor ->
                assertTrue("the dirty-scan index on session must exist", cursor.moveToFirst())
            }
            // A row written after the migration, with no dirty value given,
            // is born owing the cloud an upload.
            db.execSQL(
                "INSERT INTO `track` (`sessionId`, `encodingVersion`, `pointCount`, " +
                    "`t`, `path`, `speed`, `alt`, `updatedAtUtcMillis`) " +
                    "VALUES ('trip-2', 1, 1, '[0]', 'ef', '[0]', '[0]', 4400)"
            )
            db.query("SELECT `dirty` FROM `track` WHERE `sessionId` = 'trip-2'").use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals("a newly written row must be marked not yet uploaded", 1L, cursor.getLong(0))
            }
        }
    }

    /**
     * Every annotation row gets a hybrid logical clock.
     *
     * The database is opened with `fallbackToDestructiveMigration()`. A
     * migration Room refuses does not crash the app: it drops the database
     * and builds it again, and every recorded insight, preference, cost and
     * journey on the vehicle is gone. This inserts a realistic row into each
     * of the five annotation tables at schema 43 and asserts, after the
     * migration, that every row survived with its content intact, that the HLC
     * columns exist on all five tables, and that every historical row carries
     * a sensible stamp (`hlcMillis = updatedAtUtcMillis`, `hlcCounter = 0`,
     * `hlcDeviceId = origin`). A newly written row after the migration must
     * also be storable with an explicit stamp. An empty database would pass
     * all of that trivially, which is why the rows come first.
     */
    @Test
    fun migration43To44StampsEveryAnnotationRowWithHlc() {
        helper.createDatabase(TEST_DB, 43).use { db ->
            db.execSQL(
                "INSERT INTO `insight_places` (`id`, `name`, `latitude`, `longitude`, `radiusM`, `createdAtUtcMillis`, `updatedAtUtcMillis`, `accountId`, `origin`, `deletedAtUtcMillis`) " +
                    "VALUES ('place-1', 'Home', -23.5505, -46.6333, 150.0, 1000000, 2000000, NULL, 'car', NULL)"
            )
            db.execSQL(
                "INSERT INTO `session_costs` (`sessionId`, `costPerKwh`, `paidAmount`, `costCurrency`, `updatedAtUtcMillis`, `origin`) " +
                    "VALUES ('sess-1', 0.75, NULL, 'BRL', 3000000, 'car')"
            )
            db.execSQL(
                "INSERT INTO `preferences` (`scope`, `key`, `value`, `updatedAtUtcMillis`, `origin`, `deletedAtUtcMillis`) " +
                    "VALUES ('account', 'theme_id', 'dark', 4000000, 'phone', NULL)"
            )
            db.execSQL(
                "INSERT INTO `preference_proposals` (`id`, `key`, `value`, `status`, `proposedAtUtcMillis`, `decidedAtUtcMillis`, `updatedAtUtcMillis`, `origin`) " +
                    "VALUES ('prop-1', 'pack_capacity_wh', '39000', 'PENDING', 4100000, NULL, 4200000, 'phone')"
            )
            db.execSQL(
                "INSERT INTO `journeys` (`id`, `name`, `startedAtUtcMillis`, `endedAtUtcMillis`, `note`, `createdAtUtcMillis`, `updatedAtUtcMillis`, `accountId`, `origin`, `deletedAtUtcMillis`) " +
                    "VALUES ('journey-1', 'Weekend', 5000000, 6000000, 'trip', 5000000, 5500000, NULL, 'car', NULL)"
            )
        }

        helper.runMigrationsAndValidate(
            TEST_DB, 44, true,
            TelemetryDatabase.MIGRATION_43_44
        ).use { db ->
            db.query(
                "SELECT `name`, `updatedAtUtcMillis`, `origin`, `hlcMillis`, `hlcCounter`, `hlcDeviceId` FROM `insight_places` WHERE `id` = 'place-1'"
            ).use { cursor ->
                assertTrue("the stored place must survive the migration", cursor.moveToFirst())
                assertEquals("Home", cursor.getString(0))
                assertEquals(2000000L, cursor.getLong(1))
                assertEquals("car", cursor.getString(2))
                assertEquals("a historical place must have hlcMillis = updatedAtUtcMillis", 2000000L, cursor.getLong(3))
                assertEquals(0, cursor.getInt(4))
                assertEquals("car", cursor.getString(5))
            }
            db.query(
                "SELECT `costPerKwh`, `updatedAtUtcMillis`, `origin`, `hlcMillis`, `hlcCounter`, `hlcDeviceId` FROM `session_costs` WHERE `sessionId` = 'sess-1'"
            ).use { cursor ->
                assertTrue("the stored cost must survive the migration", cursor.moveToFirst())
                assertEquals(0.75, cursor.getDouble(0), 0.0001)
                assertEquals(3000000L, cursor.getLong(1))
                assertEquals("car", cursor.getString(2))
                assertEquals(3000000L, cursor.getLong(3))
                assertEquals(0, cursor.getInt(4))
                assertEquals("car", cursor.getString(5))
            }
            db.query(
                "SELECT `value`, `updatedAtUtcMillis`, `origin`, `hlcMillis`, `hlcDeviceId` FROM `preferences` WHERE `scope` = 'account' AND `key` = 'theme_id'"
            ).use { cursor ->
                assertTrue("the stored preference must survive the migration", cursor.moveToFirst())
                assertEquals("dark", cursor.getString(0))
                assertEquals(4000000L, cursor.getLong(1))
                assertEquals("phone", cursor.getString(2))
                assertEquals(4000000L, cursor.getLong(3))
                assertEquals("phone", cursor.getString(4))
            }
            db.query(
                "SELECT `key`, `updatedAtUtcMillis`, `origin`, `hlcMillis`, `hlcDeviceId` FROM `preference_proposals` WHERE `id` = 'prop-1'"
            ).use { cursor ->
                assertTrue("the stored proposal must survive the migration", cursor.moveToFirst())
                assertEquals("pack_capacity_wh", cursor.getString(0))
                assertEquals(4200000L, cursor.getLong(1))
                assertEquals("phone", cursor.getString(2))
                assertEquals(4200000L, cursor.getLong(3))
                assertEquals("phone", cursor.getString(4))
            }
            db.query(
                "SELECT `name`, `updatedAtUtcMillis`, `origin`, `hlcMillis`, `hlcCounter`, `hlcDeviceId` FROM `journeys` WHERE `id` = 'journey-1'"
            ).use { cursor ->
                assertTrue("the stored journey must survive the migration", cursor.moveToFirst())
                assertEquals("Weekend", cursor.getString(0))
                assertEquals(5500000L, cursor.getLong(1))
                assertEquals("car", cursor.getString(2))
                assertEquals(5500000L, cursor.getLong(3))
                assertEquals(0, cursor.getInt(4))
                assertEquals("car", cursor.getString(5))
            }
            for (table in listOf("insight_places", "session_costs", "preferences", "preference_proposals", "journeys")) {
                db.query("SELECT COUNT(*) FROM `$table` WHERE `hlcMillis` = 0 OR `hlcDeviceId` = ''").use { cursor ->
                    assertTrue(cursor.moveToFirst())
                    assertEquals("no row of `$table` may have empty HLC after the migration", 0L, cursor.getLong(0))
                }
            }
            // A row written after the migration with an explicit HLC must store it.
            db.execSQL(
                "INSERT INTO `insight_places` (`id`, `name`, `latitude`, `longitude`, `radiusM`, `createdAtUtcMillis`, `updatedAtUtcMillis`, `origin`, `hlcMillis`, `hlcCounter`, `hlcDeviceId`) " +
                    "VALUES ('place-2', 'Work', -23.5, -46.6, 150.0, 9000000, 9000000, 'car', 9000000, 3, 'car')"
            )
            db.query("SELECT `hlcMillis`, `hlcCounter`, `hlcDeviceId` FROM `insight_places` WHERE `id` = 'place-2'").use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals(9000000L, cursor.getLong(0))
                assertEquals(3, cursor.getInt(1))
                assertEquals("car", cursor.getString(2))
            }
        }
    }

    /**
     * Every interval minute gets its monotonic pair and a time state.
     *
     * The wall clock lies after a cold boot until time sync lands, but the
     * monotonic clock does not, so once a trusted wall instant arrives for
     * the boot every earlier minute resolves by exact arithmetic. The pair
     * lands nullable with no backfill: a historical row has no monotonic
     * reading stored anywhere, so it cannot be recovered, and the null says
     * so. `timeState` lands NOT NULL DEFAULT 'unknown'. A populated
     * database proves row counts survive; an empty one would pass trivially.
     */
    @Test
    fun migration44To45AddsMonotonicPairAndTimeState() {
        helper.createDatabase(TEST_DB, 44).use { db ->
            db.execSQL(
                "INSERT INTO `interval` (`sessionId`, `startUtcMillis`, `widthMillis`, " +
                    "`tractionWh`, `regenWh`, `auxiliaryWh`, `climateWh`, `deliveredWh`, " +
                    "`distanceKm`, `coveredSeconds`, `climateCoveredSeconds`, " +
                    "`speedCoveredSeconds`, `deliveredCoveredSeconds`, " +
                    "`updatedAtUtcMillis`) " +
                    "VALUES ('trip-1', 60000, 60000, 120.5, 10.0, 5.0, 3.0, 0.0, " +
                    "1.5, 60.0, 60.0, 60.0, 0.0, 5000)"
            )
            db.execSQL(
                "INSERT INTO `interval` (`sessionId`, `startUtcMillis`, `widthMillis`, " +
                    "`tractionWh`, `regenWh`, `auxiliaryWh`, `climateWh`, `deliveredWh`, " +
                    "`distanceKm`, `coveredSeconds`, `climateCoveredSeconds`, " +
                    "`speedCoveredSeconds`, `deliveredCoveredSeconds`, " +
                    "`updatedAtUtcMillis`) " +
                    "VALUES ('trip-1', 120000, 60000, 130.0, 11.0, 6.0, 4.0, 0.0, " +
                    "1.6, 60.0, 60.0, 60.0, 0.0, 5060)"
            )
        }

        helper.runMigrationsAndValidate(
            TEST_DB, 45, true,
            TelemetryDatabase.MIGRATION_44_45
        ).use { db ->
            db.query("SELECT COUNT(*) FROM `interval`").use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals("both historical minutes must survive the migration", 2L, cursor.getLong(0))
            }
            db.query(
                "SELECT `tractionWh`, `distanceKm`, `startElapsedNanos`, `startBootCount`, `timeState` " +
                    "FROM `interval` WHERE `sessionId` = 'trip-1' AND `startUtcMillis` = 60000"
            ).use { cursor ->
                assertTrue("the stored minute must survive the migration", cursor.moveToFirst())
                assertEquals(120.5, cursor.getDouble(0), 0.0001)
                assertEquals(1.5, cursor.getDouble(1), 0.0001)
                assertTrue("a historical minute keeps a null pair: it cannot be recovered", cursor.isNull(2))
                assertTrue("a historical minute keeps a null boot count", cursor.isNull(3))
                assertEquals("a historical minute starts unknown", "unknown", cursor.getString(4))
            }
            // A row written after the migration, with no time values given,
            // is born unknown with nulls.
            db.execSQL(
                "INSERT INTO `interval` (`sessionId`, `startUtcMillis`, `widthMillis`, " +
                    "`tractionWh`, `regenWh`, `auxiliaryWh`, `climateWh`, `deliveredWh`, " +
                    "`distanceKm`, `coveredSeconds`, `climateCoveredSeconds`, " +
                    "`speedCoveredSeconds`, `deliveredCoveredSeconds`, " +
                    "`updatedAtUtcMillis`) " +
                    "VALUES ('trip-1', 180000, 60000, 140.0, 12.0, 7.0, 5.0, 0.0, " +
                    "1.7, 60.0, 60.0, 60.0, 0.0, 5120)"
            )
            db.query(
                "SELECT `startElapsedNanos`, `startBootCount`, `timeState` FROM `interval` " +
                    "WHERE `sessionId` = 'trip-1' AND `startUtcMillis` = 180000"
            ).use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertTrue(cursor.isNull(0))
                assertTrue(cursor.isNull(1))
                assertEquals("unknown", cursor.getString(2))
            }
            // A row written with an explicit pair keeps it.
            db.execSQL(
                "INSERT INTO `interval` (`sessionId`, `startUtcMillis`, `widthMillis`, " +
                    "`tractionWh`, `regenWh`, `auxiliaryWh`, `climateWh`, `deliveredWh`, " +
                    "`distanceKm`, `coveredSeconds`, `climateCoveredSeconds`, " +
                    "`speedCoveredSeconds`, `deliveredCoveredSeconds`, " +
                    "`updatedAtUtcMillis`, `startElapsedNanos`, `startBootCount`, `timeState`) " +
                    "VALUES ('trip-1', 240000, 60000, 150.0, 13.0, 8.0, 6.0, 0.0, " +
                    "1.8, 60.0, 60.0, 60.0, 0.0, 5180, 19960745017175, 126, 'trusted')"
            )
            db.query(
                "SELECT `startElapsedNanos`, `startBootCount`, `timeState` FROM `interval` " +
                    "WHERE `sessionId` = 'trip-1' AND `startUtcMillis` = 240000"
            ).use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals(19960745017175L, cursor.getLong(0))
                assertEquals(126, cursor.getInt(1))
                assertEquals("trusted", cursor.getString(2))
            }
        }
    }

    /**
     * Every measurement row gains the account that wrote it (`gb236-p4`).
     *
     * The migration is additive — exactly what has to be proved. A refused
     * migration here does not wipe (this PR removed the destructive
     * fallback: the app fails to open rather than silently destroying
     * history), so the additive shape is what keeps the open path safe. Rows
     * land in all six ownable tables at schema 44 with their real content,
     * migrate, and must survive with that content intact and `accountId`
     * null. That null is the adoption contract: ownership is decided by the
     * pairing, never by the migration. The three annotation tables that
     * already carry a cost or origin also gain the column, and a row written
     * after the migration must be storable with an explicit account.
     */
    @Test
    fun migration44To45AddsTheAccountStampWithoutLosingHistory() {
        helper.createDatabase(TEST_DB, 44).use { db ->
            db.execSQL(
                "INSERT INTO `session` (`id`, `vehicleId`, `kind`, `status`, " +
                    "`startedAtUtcMillis`, `startedAtElapsedNanos`, `noLongerReducible`, " +
                    "`createdAtUtcMillis`, `updatedAtUtcMillis`) " +
                    "VALUES ('trip-1', 'car', 'TRIP', 'ENDED', 1000, 100, 0, 1000, 5000)"
            )
            db.execSQL(
                "INSERT INTO `interval` (`sessionId`, `startUtcMillis`, `widthMillis`, " +
                    "`tractionWh`, `regenWh`, `auxiliaryWh`, `climateWh`, `deliveredWh`, " +
                    "`distanceKm`, `coveredSeconds`, `climateCoveredSeconds`, " +
                    "`speedCoveredSeconds`, `deliveredCoveredSeconds`, `updatedAtUtcMillis`) " +
                    "VALUES ('trip-1', 60000, 60000, 120.5, 8.25, 30.0, 12.0, 0.0, " +
                    "1.5, 60.0, 60.0, 60.0, 0.0, 99000)"
            )
            db.execSQL(
                "INSERT INTO `telemetry_events` (`id`, `type`, `occurredAtUtcMillis`, " +
                    "`occurredAtElapsedNanos`, `sourceTimestampNanos`, `timestampAccuracy`, " +
                    "`uncertaintyMillis`, `signalId`, `value`, `previousValue`, `quality`, " +
                    "`source`, `details`, `sessionId`) " +
                    "VALUES (1, 'SIGNAL_UPDATED', 1000, 100, NULL, 'ACCURATE', 0, 'GEAR', " +
                    "'4', NULL, NULL, NULL, 'details', 'trip-1')"
            )
            db.execSQL(
                "INSERT INTO `track` (`sessionId`, `encodingVersion`, `pointCount`, " +
                    "`t`, `path`, `speed`, `alt`, `updatedAtUtcMillis`) " +
                    "VALUES ('trip-1', 1, 2, '[0,1000]', 'abcd', '[500,500]', '[1000,0]', 4200)"
            )
            db.execSQL(
                "INSERT INTO `battery_cycles` (`ordinal`, `startUtcMillis`, `endUtcMillis`, " +
                    "`dischargePercent`, `distanceKm`, `tripEnergyKwh`, `parkedEnergyKwh`, " +
                    "`parkedSocPercent`, `cost`, `costCurrency`, `pricedEnergyKwh`, " +
                    "`unpricedEnergyKwh`, `isOpen`, `isPartial`, `energyIncomplete`, " +
                    "`mixedCurrency`, `openingPricedFraction`, `openingBlendedPrice`, " +
                    "`frozenAtUtcMillis`, `createdAtUtcMillis`, `updatedAtUtcMillis`) " +
                    "VALUES (1, 1000, 2000, 12.5, 20.0, 3000.0, 100.0, 3.1, 0.75, 'BRL', " +
                    "2800.0, 200.0, 0, 0, 0, 0, 0.9, 0.35, NULL, 1000, 2000)"
            )
            db.execSQL(
                "INSERT INTO `trip_segments` (`sessionId`, `ordinal`, `startUtcMillis`, " +
                    "`endUtcMillis`, `distanceKm`, `packWh`, `tractionWh`, " +
                    "`regeneratedWh`, `auxiliaryWh`, `integratedSeconds`, " +
                    "`elapsedSeconds`, `meanSpeedKmh`, `altitudeGainM`, `altitudeLossM`, " +
                    "`ambientTempC`, `startLatitude`, `startLongitude`, `endLatitude`, " +
                    "`endLongitude`, `path`) " +
                    "VALUES ('trip-1', 1, 1000, 2000, 2.5, 100.0, 50.0, " +
                    "5.0, 10.0, 60.0, 60.0, 150.0, 12.0, 3.0, 22.0, -23.5, -46.6, " +
                    "-23.4, -46.5, '-23.55,-46.63;-23.5,-46.6')"
            )
            db.execSQL(
                "INSERT INTO `session_costs` (`sessionId`, `costPerKwh`, `paidAmount`, `costCurrency`, `updatedAtUtcMillis`, `origin`) " +
                    "VALUES ('charge-1', 0.75, NULL, 'BRL', 3000000, 'car')"
            )
            db.execSQL(
                "INSERT INTO `preferences` (`scope`, `key`, `value`, `updatedAtUtcMillis`, `origin`, `deletedAtUtcMillis`) " +
                    "VALUES ('account', 'theme_id', 'dark', 4000000, 'phone', NULL)"
            )
            db.execSQL(
                "INSERT INTO `preference_proposals` (`id`, `key`, `value`, `status`, `proposedAtUtcMillis`, `decidedAtUtcMillis`, `updatedAtUtcMillis`, `origin`) " +
                    "VALUES ('prop-1', 'pack_capacity_wh', '39000', 'PENDING', 4100000, NULL, 4200000, 'phone')"
            )
        }

        helper.runMigrationsAndValidate(
            TEST_DB, 45, true,
            TelemetryDatabase.MIGRATION_44_45
        ).use { db ->
            db.query(
                "SELECT `status`, `updatedAtUtcMillis`, `accountId` FROM `session` WHERE `id` = 'trip-1'"
            ).use { cursor ->
                assertTrue("the stored session must survive the migration", cursor.moveToFirst())
                assertEquals("ENDED", cursor.getString(0))
                assertEquals(5000L, cursor.getLong(1))
                assertTrue("a historical session must land unowned", cursor.isNull(2))
            }
            db.query(
                "SELECT `tractionWh`, `distanceKm`, `accountId` FROM `interval` " +
                    "WHERE `sessionId` = 'trip-1' AND `startUtcMillis` = 60000"
            ).use { cursor ->
                assertTrue("the stored minute must survive the migration", cursor.moveToFirst())
                assertEquals(120.5, cursor.getDouble(0), 0.0001)
                assertEquals(1.5, cursor.getDouble(1), 0.0001)
                assertTrue("a historical interval must land unowned", cursor.isNull(2))
            }
            db.query(
                "SELECT `signalId`, `value`, `accountId` FROM `telemetry_events` WHERE `id` = 1"
            ).use { cursor ->
                assertTrue("the stored event must survive the migration", cursor.moveToFirst())
                assertEquals("GEAR", cursor.getString(0))
                assertEquals("4", cursor.getString(1))
                assertTrue("a historical event must land unowned", cursor.isNull(2))
            }
            db.query(
                "SELECT `pointCount`, `path`, `accountId` FROM `track` WHERE `sessionId` = 'trip-1'"
            ).use { cursor ->
                assertTrue("the stored route must survive the migration", cursor.moveToFirst())
                assertEquals(2, cursor.getInt(0))
                assertEquals("abcd", cursor.getString(1))
                assertTrue("a historical track must land unowned", cursor.isNull(2))
            }
            db.query(
                "SELECT `dischargePercent`, `cost`, `accountId` " +
                    "FROM `battery_cycles` WHERE `ordinal` = 1"
            ).use { cursor ->
                assertTrue("the stored cycle must survive the migration", cursor.moveToFirst())
                assertEquals(12.5, cursor.getDouble(0), 0.0001)
                assertEquals(0.75, cursor.getDouble(1), 0.0001)
                assertTrue("a historical cycle must land unowned", cursor.isNull(2))
            }
            db.query(
                "SELECT `ordinal`, `distanceKm`, `accountId` FROM `trip_segments` " +
                    "WHERE `sessionId` = 'trip-1' AND `ordinal` = 1"
            ).use { cursor ->
                assertTrue("the stored stretch must survive the migration", cursor.moveToFirst())
                assertEquals(1, cursor.getInt(0))
                assertEquals(2.5, cursor.getDouble(1), 0.0001)
                assertTrue("a historical stretch must land unowned", cursor.isNull(2))
            }
            for (table in listOf(
                "session", "interval", "track", "telemetry_events",
                "battery_cycles", "trip_segments", "session_costs",
                "preferences", "preference_proposals"
            )) {
                db.query("SELECT COUNT(*) FROM `$table` WHERE `accountId` IS NOT NULL").use { cursor ->
                    assertTrue(cursor.moveToFirst())
                    assertEquals("no historical row of `$table` may carry an account after the migration", 0L, cursor.getLong(0))
                }
            }
            db.query(
                "SELECT `costPerKwh`, `accountId` FROM `session_costs` WHERE `sessionId` = 'charge-1'"
            ).use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals(0.75, cursor.getDouble(0), 0.0001)
                assertTrue(cursor.isNull(1))
            }
            db.query(
                "SELECT `value`, `accountId` FROM `preferences` WHERE `scope` = 'account' AND `key` = 'theme_id'"
            ).use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals("dark", cursor.getString(0))
                assertTrue(cursor.isNull(1))
            }
            // A row written after the migration with an explicit account must store it.
            db.execSQL(
                "INSERT INTO `track` (`sessionId`, `encodingVersion`, `pointCount`, " +
                    "`t`, `path`, `speed`, `alt`, `updatedAtUtcMillis`, `accountId`) " +
                    "VALUES ('trip-2', 1, 1, '[0]', 'ef', '[0]', '[0]', 4400, 'acc-a')"
            )
            db.query("SELECT `accountId` FROM `track` WHERE `sessionId` = 'trip-2'").use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals("acc-a", cursor.getString(0))
            }
        }
    }
}
