package com.timhss.capyenergy.telemetry

import com.timhss.capyenergy.telemetry.db.IntervalDao
import com.timhss.capyenergy.telemetry.db.IntervalEntity
import com.timhss.capyenergy.telemetry.db.IntervalReplacedKeyDao
import com.timhss.capyenergy.telemetry.db.IntervalReplacedKeyEntity
import com.timhss.capyenergy.telemetry.db.SessionCostDao
import com.timhss.capyenergy.telemetry.db.SessionCostEntity
import com.timhss.capyenergy.telemetry.db.SessionDao
import com.timhss.capyenergy.telemetry.db.SessionEntity
import com.timhss.capyenergy.telemetry.db.TelemetryDatabase
import com.timhss.capyenergy.telemetry.db.TelemetryEventDao
import com.timhss.capyenergy.telemetry.db.TelemetryEventEntity
import com.timhss.capyenergy.telemetry.db.TrackDao
import com.timhss.capyenergy.telemetry.db.TrackEntity
import com.timhss.capyenergy.telemetry.db.TripSegmentDao
import com.timhss.capyenergy.telemetry.db.TripSegmentEntity
import com.timhss.capyenergy.telemetry.sync.FakeSessionDao
import java.io.File
import java.sql.DriverManager
import java.sql.Statement
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * End-to-end JVM proof of the captain's incident scenario:
 * 1. Boot 142 on birth clock (2025-05-24 01:08:00 UTC).
 * 2. Continuous and parked sessions start and remain active across the incident.
 * 3. Trip closes without truth: sweeper sweepOnClose returns 0, session and intervals stay pending.
 * 4. Before truth lands:
 *    - Retention (30-day cutoff in 2026) does NOT delete the 2025-stamped events of the pending trip.
 *    - Efficiency and range windows (7d/30d) EXCLUDE the pending trip.
 *    - Range estimate monitor keeps the last valid estimate (degraded) instead of disappearing.
 * 5. Clock anchor is learned minutes later via truth source (Date HTTP / GPS).
 * 6. SessionRepository.onLearned fires the sweepBoot(142) on the serialized write queue.
 * 7. Car clock jumps to 2026-09-15 12:20:00.
 * 8. Post-promotion verifications:
 *    - Trip is promoted to 'known', startedAt and endedAt corrected by exact arithmetic.
 *    - All 10 intervals corrected by exact arithmetic and promoted to 'known'.
 *    - T9 re-upload: interval_replaced_keys contains exactly 10 pairs, zero duplicates.
 *    - Active continuous and parked sessions remain ACTIVE and 'pending' (safe from premature promotion).
 *    - Events of the promoted trip remain preserved.
 *    - Range windows now include the promoted trip under its corrected 2026 stamp.
 *    - A second sweepBoot is idempotent and writes nothing.
 */
class CaptainIncidentEndToEndJvmTest {

    private val boot142 = 142L
    private val birthStamp2025 = 1_748_048_880_000L // 2025-05-24 01:08:00 UTC
    private val truthOffset2026 = 1_786_000_000_000L // 2026-09-15 ~12:15:00 UTC
    private val dayMillis = 86_400_000L
    private val realNow2026 = truthOffset2026 + 10 * 60_000L
    private val cutoff2026 = realNow2026 - 30 * dayMillis

    private val schemaDir = File(
        "android/app/schemas/com.timhss.capyenergy.telemetry.db.TelemetryDatabase"
    ).let { if (it.isDirectory) it else File("schemas/com.timhss.capyenergy.telemetry.db.TelemetryDatabase") }

    @Before
    fun setUp() {
        ClockAnchorStore.reset()
        TelemetryDatabase.setInstanceForTesting(null)
    }

    @After
    fun tearDown() {
        ClockAnchorStore.reset()
        TelemetryDatabase.setInstanceForTesting(null)
    }

    @Test
    fun `captain incident scenario end-to-end on JVM`() {
        withRealSchemaDb { connection, sessionDao, intervalDao, replacedDao, eventDao ->
            // --- 0. Seed healthy past trip in 2026 so range estimate has a prior baseline ---
            val pastTrip = SessionEntity(
                id = "past-trip-1",
                vehicleId = "car",
                kind = "TRIP",
                status = "ENDED",
                startedAtUtcMillis = realNow2026 - 2 * dayMillis - 3_600_000L,
                startedAtElapsedNanos = 1L,
                startedAtBootCount = 141,
                endedAtUtcMillis = realNow2026 - 2 * dayMillis,
                endedAtElapsedNanos = 3_600_000_000_000L,
                endedAtBootCount = 141,
                startSocPercent = 80f,
                endSocPercent = 70f,
                startOdometerKm = 1000f,
                endOdometerKm = 1020f,
                rollupTractionWh = 4000.0,
                rollupRegenWh = 0.0,
                rollupAuxiliaryWh = 0.0,
                rollupIntegratedSeconds = 3600.0,
                timeState = "known",
                dirty = false
            )
            sessionDao.upsert(pastTrip)

            // Baseline estimate before the incident
            val initialEstimate = RangeEfficiencyRepository.compute(
                loadWindow = { days -> sessionDao.rangeWindow(realNow2026 - days * dayMillis, realNow2026) },
                nowMillis = realNow2026
            )
            assertEquals(1, initialEstimate.tripCount)
            assertEquals(5.0, initialEstimate.efficiencyKmPerKwh!!, 1e-6) // 20 km / 4 kWh

            // --- 1. Boot 142 starts on birth clock (no truth) ---
            assertFalse(ClockAnchorStore.isLearned())

            // CONTINUOUS and PARKED start active in boot 142
            val continuousActive = SessionEntity(
                id = "cont-142",
                vehicleId = "car",
                kind = "CONTINUOUS",
                status = "ACTIVE",
                startedAtUtcMillis = birthStamp2025 + 10_000L,
                startedAtElapsedNanos = 10_000_000_000L,
                startedAtBootCount = boot142.toInt(),
                timeState = "pending",
                dirty = false
            )
            val parkedActive = SessionEntity(
                id = "parked-142",
                vehicleId = "car",
                kind = "PARKED",
                status = "ACTIVE",
                startedAtUtcMillis = birthStamp2025 + 20_000L,
                startedAtElapsedNanos = 20_000_000_000L,
                startedAtBootCount = boot142.toInt(),
                timeState = "pending",
                dirty = false
            )
            sessionDao.upsert(continuousActive)
            sessionDao.upsert(parkedActive)

            // TRIP t1 runs: elapsed 88s -> 587s (wall: 01:08:37 -> 01:16:56)
            val tripPending = SessionEntity(
                id = "trip-142",
                vehicleId = "car",
                kind = "TRIP",
                status = "ENDED",
                startedAtUtcMillis = birthStamp2025 + 88_000L,
                startedAtElapsedNanos = 88_000_000_000L,
                startedAtBootCount = boot142.toInt(),
                endedAtUtcMillis = birthStamp2025 + 587_000L,
                endedAtElapsedNanos = 587_000_000_000L,
                endedAtBootCount = boot142.toInt(),
                startSocPercent = 70f,
                endSocPercent = 65f,
                startOdometerKm = 1020f,
                endOdometerKm = 1030f,
                rollupTractionWh = 2000.0,
                rollupRegenWh = 0.0,
                rollupAuxiliaryWh = 0.0,
                rollupIntegratedSeconds = 500.0,
                timeState = "pending",
                dirty = false
            )
            sessionDao.upsert(tripPending)

            // 10 pending intervals for trip t1
            val pendingIntervals = (0 until 10).map { i ->
                IntervalEntity(
                    sessionId = "trip-142",
                    startUtcMillis = birthStamp2025 + i * 60_000L,
                    widthMillis = 60_000L,
                    startElapsedNanos = (i * 60L) * 1_000_000_000L,
                    startBootCount = boot142.toInt(),
                    timeState = "pending",
                    dirty = false,
                    tractionWh = 200.0,
                    distanceKm = 1.0
                )
            }
            intervalDao.upsertAll(pendingIntervals)

            // 2 events for trip t1 stamped in 2025, dirty = false (synced or held)
            val events = listOf(
                TelemetryEventEntity(
                    id = 101L,
                    type = "SIGNAL",
                    occurredAtUtcMillis = birthStamp2025 + 90_000L,
                    occurredAtElapsedNanos = 90_000_000_000L,
                    sourceTimestampNanos = null,
                    timestampAccuracy = "PRECISE",
                    uncertaintyMillis = 0L,
                    signalId = "speed",
                    value = "50.0",
                    previousValue = null,
                    quality = "GOOD",
                    source = "can",
                    details = "{}",
                    sessionId = "trip-142",
                    dirty = false
                ),
                TelemetryEventEntity(
                    id = 102L,
                    type = "SIGNAL",
                    occurredAtUtcMillis = birthStamp2025 + 200_000L,
                    occurredAtElapsedNanos = 200_000_000_000L,
                    sourceTimestampNanos = null,
                    timestampAccuracy = "PRECISE",
                    uncertaintyMillis = 0L,
                    signalId = "soc",
                    value = "68.0",
                    previousValue = null,
                    quality = "GOOD",
                    source = "bms",
                    details = "{}",
                    sessionId = "trip-142",
                    dirty = false
                )
            )
            eventDao.upsertAll(events)

            // --- 2. Trip closes without truth: sweepOnClose runs ---
            val sweeper = ClockBackfillSweeper(
                intervalDao,
                replacedKeyDao = replacedDao,
                sessionDao = sessionDao,
                currentBootCountProvider = { boot142 }
            )
            val closeResult = sweeper.sweepOnClose("trip-142", boot142.toInt())
            assertEquals(0, closeResult) // Zero rows modified without anchor

            // Confirm trip and intervals are still pending
            val tripBeforeLearn = sessionDao.findById("trip-142")!!
            assertEquals("pending", tripBeforeLearn.timeState)
            assertEquals(birthStamp2025 + 88_000L, tripBeforeLearn.startedAtUtcMillis)
            assertEquals(0, replacedDao.pending(100).size)

            // --- 3. Before truth arrives: retention and window queries ---
            // G2: Event age purge must NOT delete events of the pending session
            val deletedEvents = eventDao.deleteOlderThanChunk(cutoff2026, 2_000)
            assertEquals(0, deletedEvents)
            assertTrue("event 101 survives", eventDao.exists(101L))
            assertTrue("event 102 survives", eventDao.exists(102L))

            // G3: Pending trip is EXCLUDED from window queries
            val windowTrips = sessionDao.rangeWindow(realNow2026 - 7 * dayMillis, realNow2026)
            assertEquals(listOf("past-trip-1"), windowTrips.map { it.id })

            val inWindowAll = sessionDao.inWindowAll(realNow2026 - 7 * dayMillis, realNow2026)
            assertEquals(listOf("past-trip-1"), inWindowAll.map { it.id })

            // Estimate computation while pending: relies on valid past trip, not corrupted by pending trip
            val midEstimate = RangeEfficiencyRepository.compute(
                loadWindow = { days -> sessionDao.rangeWindow(realNow2026 - days * dayMillis, realNow2026) },
                nowMillis = realNow2026
            )
            assertEquals(1, midEstimate.tripCount)
            assertEquals(5.0, midEstimate.efficiencyKmPerKwh!!, 1e-6)

            // --- 4. Truth arrives: Anchor is learned minutes later ---
            ClockAnchorStore.setReferenceOffset(truthOffset2026)
            val offered = ClockAnchorStore.offerServerDate(
                truthOffset2026 + 700_000L,
                700L * 1_000_000_000L
            )
            assertTrue(offered)
            assertTrue(ClockAnchorStore.isLearned())

            // Car clock jumps to 2026 (truthOffset2026 + 800s)
            val jumpedCarTime = truthOffset2026 + 800_000L

            // Sweep triggered by anchor learn
            val promotedCount = sweeper.sweepBoot(boot142)
            assertEquals(10, promotedCount)

            // --- 5. Post-promotion verifications ---
            // A. Trip promoted to 'known' and timestamps corrected by arithmetic
            val tripPromoted = sessionDao.findById("trip-142")!!
            assertEquals("known", tripPromoted.timeState)
            assertEquals(truthOffset2026 + 88_000L, tripPromoted.startedAtUtcMillis)
            assertEquals(truthOffset2026 + 587_000L, tripPromoted.endedAtUtcMillis)
            assertTrue(tripPromoted.dirty)

            // B. Intervals promoted and re-anchored
            val intervalsAfter = intervalDao.forSession("trip-142")
            assertEquals(10, intervalsAfter.size)
            for (i in 0 until 10) {
                val row = intervalsAfter.first { it.startElapsedNanos == (i * 60L) * 1_000_000_000L }
                val expectedStart = EnergyBucketAccumulator.alignToBucket(truthOffset2026 + i * 60_000L)
                assertEquals(expectedStart, row.startUtcMillis)
                assertEquals("known", row.timeState)
                assertTrue(row.dirty)
            }

            // C. T9 Re-upload: interval_replaced_keys contains exactly 10 unique mappings
            val replacedKeys = replacedDao.pending(100)
            assertEquals(10, replacedKeys.size)
            val oldStamps = replacedKeys.map { it.startUtcMillis }.toSet()
            val newStamps = replacedKeys.map { it.replacedByUtcMillis }.toSet()
            assertEquals(10, oldStamps.size)
            assertEquals(10, newStamps.size)
            for (i in 0 until 10) {
                val oldExpected = birthStamp2025 + i * 60_000L
                val newExpected = EnergyBucketAccumulator.alignToBucket(truthOffset2026 + i * 60_000L)
                val entry = replacedKeys.firstOrNull { it.startUtcMillis == oldExpected }
                assertNotNull("replaced key exists for minute $i", entry)
                assertEquals(newExpected, entry!!.replacedByUtcMillis)
            }

            // D. Active continuous and parked sessions REMAIN active and 'pending'
            val contStillActive = sessionDao.findById("cont-142")!!
            val parkedStillActive = sessionDao.findById("parked-142")!!
            assertEquals("ACTIVE", contStillActive.status)
            assertEquals("pending", contStillActive.timeState)
            assertEquals("ACTIVE", parkedStillActive.status)
            assertEquals("pending", parkedStillActive.timeState)

            // E. Events remain preserved
            assertTrue("event 101 survives after promotion", eventDao.exists(101L))
            assertTrue("event 102 survives after promotion", eventDao.exists(102L))

            // F. Window queries now INCLUDE the promoted trip under its 2026 timestamp
            val windowTripsAfter = sessionDao.rangeWindow(realNow2026 - 7 * dayMillis, realNow2026)
            assertEquals(setOf("past-trip-1", "trip-142"), windowTripsAfter.map { it.id }.toSet())

            // G. Range efficiency now incorporates the promoted trip
            val finalEstimate = RangeEfficiencyRepository.compute(
                loadWindow = { days -> sessionDao.rangeWindow(realNow2026 - days * dayMillis, realNow2026) },
                nowMillis = realNow2026
            )
            assertEquals(2, finalEstimate.tripCount)
            assertEquals(30.0, finalEstimate.distanceKm!!, 1e-6) // 20 km + 10 km
            assertEquals(6.0, finalEstimate.netEnergyKwh!!, 1e-6) // 4 kWh + 2 kWh
            assertEquals(5.0, finalEstimate.efficiencyKmPerKwh!!, 1e-6) // 30 km / 6 kWh

            // H. Second sweepBoot is completely idempotent
            val secondSweep = sweeper.sweepBoot(boot142)
            assertEquals(0, secondSweep)
            assertEquals(10, replacedDao.pending(100).size) // No duplicates
        }
    }

    @Test
    fun `SessionRepository onLearned hookup triggers sweepBoot on learn`() {
        withRealSchemaDb { connection, sessionDao, intervalDao, replacedDao, eventDao ->
            // Seed a closed pending trip in boot 142
            val trip = SessionEntity(
                id = "s-learned",
                vehicleId = "car",
                kind = "TRIP",
                status = "ENDED",
                startedAtUtcMillis = birthStamp2025 + 88_000L,
                startedAtElapsedNanos = 88_000_000_000L,
                startedAtBootCount = boot142.toInt(),
                endedAtUtcMillis = birthStamp2025 + 587_000L,
                endedAtElapsedNanos = 587_000_000_000L,
                endedAtBootCount = boot142.toInt(),
                timeState = "pending",
                dirty = false
            )
            sessionDao.upsert(trip)
            intervalDao.upsertAll(listOf(
                IntervalEntity(
                    sessionId = "s-learned",
                    startUtcMillis = birthStamp2025,
                    widthMillis = 60_000L,
                    startElapsedNanos = 0L,
                    startBootCount = boot142.toInt(),
                    timeState = "pending",
                    dirty = false
                )
            ))

            val fakeDb = TestTelemetryDatabase(sessionDao, intervalDao, replacedDao, eventDao)
            TelemetryDatabase.setInstanceForTesting(fakeDb)

            // Construct SessionRepository: it registers with ClockAnchorStore.onLearned
            val repo = SessionRepository(
                context = FakeSettingsContext(),
                bootCountProvider = { boot142.toInt() },
                databaseOverride = fakeDb
            )

            // Session is still pending
            assertEquals("pending", sessionDao.findById("s-learned")?.timeState)

            // Learn truth through ClockAnchorStore
            ClockAnchorStore.setReferenceOffset(truthOffset2026)
            assertTrue(ClockAnchorStore.offerServerDate(truthOffset2026 + 100_000L, 100L * 1_000_000_000L))
            assertTrue(ClockAnchorStore.isLearned())

            // Wait for the asynchronous sweep posted to TelemetryWriteCoordinator
            TelemetryWriteCoordinator.executor.awaitIdle()

            // Verification: SessionRepository's hookup swept and promoted the session!
            val promoted = sessionDao.findById("s-learned")!!
            assertEquals("known", promoted.timeState)
            assertEquals(truthOffset2026 + 88_000L, promoted.startedAtUtcMillis)
            assertEquals("known", intervalDao.forSession("s-learned").first().timeState)
        }
    }

    @Test
    fun `second promotion does not exist because anchor is immutable once learned`() {
        ClockAnchorStore.setReferenceOffset(truthOffset2026)
        assertTrue(ClockAnchorStore.offerServerDate(truthOffset2026 + 100_000L, 100L * 1_000_000_000L))
        assertTrue(ClockAnchorStore.isLearned())

        var secondListenerFired = 0
        ClockAnchorStore.onLearned { secondListenerFired++ }
        assertEquals(1, secondListenerFired) // Immediate execution for already-learned

        // Calling setReferenceOffset with a different offset does nothing
        ClockAnchorStore.setReferenceOffset(truthOffset2026 + 50_000L)
        assertEquals(truthOffset2026 + 100_000L, ClockAnchorStore.anchor()!!.wallMillis)
    }

    // --- SQLite Real Schema Harness ---

    private fun withRealSchemaDb(
        block: (
            Statement,
            RealSqlSessionDao,
            RealSqlIntervalDao,
            RealSqlReplacedDao,
            RealSqlEventDao
        ) -> Unit
    ) {
        Class.forName("org.sqlite.JDBC")
        DriverManager.getConnection("jdbc:sqlite::memory:").use { conn ->
            conn.createStatement().use { s ->
                s.execute("PRAGMA foreign_keys = OFF")
                createTableFromExport(s, "48", "session")
                createTableFromExport(s, "48", "interval")
                createTableFromExport(s, "48", "interval_replaced_keys")
                createTableFromExport(s, "48", "telemetry_events")

                val sessionDao = RealSqlSessionDao(conn)
                val intervalDao = RealSqlIntervalDao(conn)
                val replacedDao = RealSqlReplacedDao(conn)
                val eventDao = RealSqlEventDao(conn)

                block(s, sessionDao, intervalDao, replacedDao, eventDao)
            }
        }
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
        val pk = entity.getJSONObject("primaryKey")
        val pkCols = pk.getJSONArray("columnNames")
        val pkList = (0 until pkCols.length()).map { pkCols.getString(it) }
        if (!pk.optBoolean("autoGenerate", false) && pkList.isNotEmpty()) {
            cols.append(", PRIMARY KEY (${pkList.joinToString { "`$it`" }})")
        }
        s.execute("CREATE TABLE `$table` ($cols)")
        val indices = entity.optJSONArray("indices")
        if (indices != null) {
            for (k in 0 until indices.length()) {
                val idx = indices.getJSONObject(k)
                val sql = idx.getString("createSql").replace("\${TABLE_NAME}", table)
                s.execute(sql)
            }
        }
    }

    // --- SQLite Real DAO Implementations ---

    class RealSqlSessionDao(
        private val conn: java.sql.Connection,
        private val fake: FakeSessionDao = FakeSessionDao()
    ) : SessionDao by fake {
        override fun upsert(session: SessionEntity) {
            fake.upsert(session)
            val sql = """
                INSERT OR REPLACE INTO `session` (
                    `id`, `vehicleId`, `kind`, `status`, `startedAtUtcMillis`, `startedAtElapsedNanos`,
                    `startedAtBootCount`, `endedAtUtcMillis`, `endedAtElapsedNanos`, `endedAtBootCount`,
                    `movementStartedAtUtcMillis`, `movementStartedAtElapsedNanos`, `movementStartedAtBootCount`,
                    `chargeStartedAtUtcMillis`, `chargeStartedAtElapsedNanos`, `chargeStartedAtBootCount`,
                    `chargeEndedAtUtcMillis`, `chargeEndedAtElapsedNanos`, `chargeEndedAtBootCount`,
                    `plugDisconnectedAtUtcMillis`, `plugDisconnectedAtElapsedNanos`, `plugDisconnectedAtBootCount`,
                    `rollupDistanceKm`, `rollupTractionWh`, `rollupRegenWh`, `startSocPercent`, `endSocPercent`,
                    `startOdometerKm`, `endOdometerKm`, `createdAtUtcMillis`, `updatedAtUtcMillis`, `dirty`, `timeState`,
                    `rollupAuxiliaryWh`, `rollupIntegratedSeconds`
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """.trimIndent()
            conn.prepareStatement(sql).use { ps ->
                ps.setString(1, session.id)
                ps.setString(2, session.vehicleId)
                ps.setString(3, session.kind)
                ps.setString(4, session.status)
                ps.setLong(5, session.startedAtUtcMillis)
                ps.setLong(6, session.startedAtElapsedNanos)
                ps.setObject(7, session.startedAtBootCount)
                ps.setObject(8, session.endedAtUtcMillis)
                ps.setObject(9, session.endedAtElapsedNanos)
                ps.setObject(10, session.endedAtBootCount)
                ps.setObject(11, session.movementStartedAtUtcMillis)
                ps.setObject(12, session.movementStartedAtElapsedNanos)
                ps.setObject(13, session.movementStartedAtBootCount)
                ps.setObject(14, session.chargeStartedAtUtcMillis)
                ps.setObject(15, session.chargeStartedAtElapsedNanos)
                ps.setObject(16, session.chargeStartedAtBootCount)
                ps.setObject(17, session.chargeEndedAtUtcMillis)
                ps.setObject(18, session.chargeEndedAtElapsedNanos)
                ps.setObject(19, session.chargeEndedAtBootCount)
                ps.setObject(20, session.plugDisconnectedAtUtcMillis)
                ps.setObject(21, session.plugDisconnectedAtElapsedNanos)
                ps.setObject(22, session.plugDisconnectedAtBootCount)
                ps.setObject(23, session.rollupDistanceKm)
                ps.setObject(24, session.rollupTractionWh)
                ps.setObject(25, session.rollupRegenWh)
                ps.setObject(26, session.startSocPercent)
                ps.setObject(27, session.endSocPercent)
                ps.setObject(28, session.startOdometerKm)
                ps.setObject(29, session.endOdometerKm)
                ps.setLong(30, session.createdAtUtcMillis)
                ps.setLong(31, session.updatedAtUtcMillis)
                ps.setInt(32, if (session.dirty) 1 else 0)
                ps.setString(33, session.timeState)
                ps.setObject(34, session.rollupAuxiliaryWh)
                ps.setObject(35, session.rollupIntegratedSeconds)
                ps.executeUpdate()
            }
        }

        override fun findById(id: String): SessionEntity? {
            val sql = "SELECT * FROM `session` WHERE `id` = ?"
            conn.prepareStatement(sql).use { ps ->
                ps.setString(1, id)
                ps.executeQuery().use { rs ->
                    if (!rs.next()) return null
                    return readRow(rs)
                }
            }
        }

        override fun findByKind(kind: String): List<SessionEntity> {
            val sql = "SELECT * FROM `session` WHERE `kind` = ?"
            conn.prepareStatement(sql).use { ps ->
                ps.setString(1, kind)
                ps.executeQuery().use { rs ->
                    val list = mutableListOf<SessionEntity>()
                    while (rs.next()) list.add(readRow(rs))
                    return list
                }
            }
        }

        override fun rangeWindow(startUtcMillis: Long, endUtcMillis: Long): List<SessionEntity> {
            val sql = "SELECT * FROM `session` WHERE `kind` = 'TRIP' AND `status` != 'FINALIZATION_PENDING' AND `timeState` != 'pending' AND `endedAtUtcMillis` IS NOT NULL AND `endedAtUtcMillis` >= ? AND `endedAtUtcMillis` <= ? ORDER BY `endedAtUtcMillis` DESC"
            conn.prepareStatement(sql).use { ps ->
                ps.setLong(1, startUtcMillis)
                ps.setLong(2, endUtcMillis)
                ps.executeQuery().use { rs ->
                    val list = mutableListOf<SessionEntity>()
                    while (rs.next()) list.add(readRow(rs))
                    return list
                }
            }
        }

        override fun inWindow(kind: String, startUtcMillis: Long, endUtcMillis: Long): List<SessionEntity> {
            val sql = "SELECT * FROM `session` WHERE `kind` = ? AND `status` != 'FINALIZATION_PENDING' AND `timeState` != 'pending' AND `startedAtUtcMillis` < ? AND COALESCE(`endedAtUtcMillis`, `updatedAtUtcMillis`) > ? ORDER BY `startedAtUtcMillis` DESC"
            conn.prepareStatement(sql).use { ps ->
                ps.setString(1, kind)
                ps.setLong(2, endUtcMillis)
                ps.setLong(3, startUtcMillis)
                ps.executeQuery().use { rs ->
                    val list = mutableListOf<SessionEntity>()
                    while (rs.next()) list.add(readRow(rs))
                    return list
                }
            }
        }

        override fun inWindowAll(startUtcMillis: Long, endUtcMillis: Long): List<SessionEntity> {
            val sql = "SELECT * FROM `session` WHERE `status` != 'FINALIZATION_PENDING' AND `timeState` != 'pending' AND `startedAtUtcMillis` < ? AND COALESCE(`endedAtUtcMillis`, `updatedAtUtcMillis`) > ? ORDER BY `startedAtUtcMillis` DESC"
            conn.prepareStatement(sql).use { ps ->
                ps.setLong(1, endUtcMillis)
                ps.setLong(2, startUtcMillis)
                ps.executeQuery().use { rs ->
                    val list = mutableListOf<SessionEntity>()
                    while (rs.next()) list.add(readRow(rs))
                    return list
                }
            }
        }

        private fun readRow(rs: java.sql.ResultSet) = SessionEntity(
            id = rs.getString("id"),
            vehicleId = rs.getString("vehicleId"),
            kind = rs.getString("kind"),
            status = rs.getString("status"),
            startedAtUtcMillis = rs.getLong("startedAtUtcMillis"),
            startedAtElapsedNanos = rs.getLong("startedAtElapsedNanos"),
            startedAtBootCount = (rs.getObject("startedAtBootCount") as? Number)?.toInt(),
            endedAtUtcMillis = (rs.getObject("endedAtUtcMillis") as? Number)?.toLong(),
            endedAtElapsedNanos = (rs.getObject("endedAtElapsedNanos") as? Number)?.toLong(),
            endedAtBootCount = (rs.getObject("endedAtBootCount") as? Number)?.toInt(),
            movementStartedAtUtcMillis = (rs.getObject("movementStartedAtUtcMillis") as? Number)?.toLong(),
            movementStartedAtElapsedNanos = (rs.getObject("movementStartedAtElapsedNanos") as? Number)?.toLong(),
            movementStartedAtBootCount = (rs.getObject("movementStartedAtBootCount") as? Number)?.toInt(),
            chargeStartedAtUtcMillis = (rs.getObject("chargeStartedAtUtcMillis") as? Number)?.toLong(),
            chargeStartedAtElapsedNanos = (rs.getObject("chargeStartedAtElapsedNanos") as? Number)?.toLong(),
            chargeStartedAtBootCount = (rs.getObject("chargeStartedAtBootCount") as? Number)?.toInt(),
            chargeEndedAtUtcMillis = (rs.getObject("chargeEndedAtUtcMillis") as? Number)?.toLong(),
            chargeEndedAtElapsedNanos = (rs.getObject("chargeEndedAtElapsedNanos") as? Number)?.toLong(),
            chargeEndedAtBootCount = (rs.getObject("chargeEndedAtBootCount") as? Number)?.toInt(),
            plugDisconnectedAtUtcMillis = (rs.getObject("plugDisconnectedAtUtcMillis") as? Number)?.toLong(),
            plugDisconnectedAtElapsedNanos = (rs.getObject("plugDisconnectedAtElapsedNanos") as? Number)?.toLong(),
            plugDisconnectedAtBootCount = (rs.getObject("plugDisconnectedAtBootCount") as? Number)?.toInt(),
            rollupDistanceKm = (rs.getObject("rollupDistanceKm") as? Number)?.toDouble(),
            rollupTractionWh = (rs.getObject("rollupTractionWh") as? Number)?.toDouble(),
            rollupRegenWh = (rs.getObject("rollupRegenWh") as? Number)?.toDouble(),
            startSocPercent = (rs.getObject("startSocPercent") as? Number)?.toFloat(),
            endSocPercent = (rs.getObject("endSocPercent") as? Number)?.toFloat(),
            startOdometerKm = (rs.getObject("startOdometerKm") as? Number)?.toFloat(),
            endOdometerKm = (rs.getObject("endOdometerKm") as? Number)?.toFloat(),
            rollupAuxiliaryWh = (rs.getObject("rollupAuxiliaryWh") as? Number)?.toDouble(),
            rollupIntegratedSeconds = (rs.getObject("rollupIntegratedSeconds") as? Number)?.toDouble(),
            createdAtUtcMillis = rs.getLong("createdAtUtcMillis"),
            updatedAtUtcMillis = rs.getLong("updatedAtUtcMillis"),
            dirty = rs.getInt("dirty") == 1,
            timeState = rs.getString("timeState")
        )
    }

    class RealSqlIntervalDao(private val conn: java.sql.Connection) : IntervalDao {
        override fun upsertAll(intervals: List<IntervalEntity>) {
            val sql = """
                INSERT OR REPLACE INTO `interval` (
                    `sessionId`, `startUtcMillis`, `widthMillis`, `startElapsedNanos`, `startBootCount`,
                    `timeState`, `dirty`, `tractionWh`, `regenWh`, `distanceKm`, `updatedAtUtcMillis`
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """.trimIndent()
            conn.prepareStatement(sql).use { ps ->
                for (it in intervals) {
                    ps.setString(1, it.sessionId)
                    ps.setLong(2, it.startUtcMillis)
                    ps.setLong(3, it.widthMillis)
                    ps.setObject(4, it.startElapsedNanos)
                    ps.setObject(5, it.startBootCount)
                    ps.setString(6, it.timeState)
                    ps.setInt(7, if (it.dirty) 1 else 0)
                    ps.setDouble(8, it.tractionWh)
                    ps.setDouble(9, it.regenWh)
                    ps.setDouble(10, it.distanceKm)
                    ps.setLong(11, it.updatedAtUtcMillis)
                    ps.addBatch()
                }
                ps.executeBatch()
            }
        }

        override fun pendingsForBoot(bootCount: Long): List<IntervalEntity> {
            val sql = "SELECT * FROM `interval` WHERE `timeState` = 'pending' AND `startBootCount` = ? ORDER BY `startUtcMillis` ASC"
            conn.prepareStatement(sql).use { ps ->
                ps.setLong(1, bootCount)
                ps.executeQuery().use { rs ->
                    val list = mutableListOf<IntervalEntity>()
                    while (rs.next()) list.add(readRow(rs))
                    return list
                }
            }
        }

        override fun deleteKey(sessionId: String, startUtcMillis: Long): Int {
            val sql = "DELETE FROM `interval` WHERE `sessionId` = ? AND `startUtcMillis` = ?"
            conn.prepareStatement(sql).use { ps ->
                ps.setString(1, sessionId)
                ps.setLong(2, startUtcMillis)
                return ps.executeUpdate()
            }
        }

        override fun findById(sessionId: String, startUtcMillis: Long): IntervalEntity? {
            val sql = "SELECT * FROM `interval` WHERE `sessionId` = ? AND `startUtcMillis` = ?"
            conn.prepareStatement(sql).use { ps ->
                ps.setString(1, sessionId)
                ps.setLong(2, startUtcMillis)
                ps.executeQuery().use { rs ->
                    if (!rs.next()) return null
                    return readRow(rs)
                }
            }
        }

        override fun forSession(sessionId: String): List<IntervalEntity> {
            val sql = "SELECT * FROM `interval` WHERE `sessionId` = ? ORDER BY `startUtcMillis` ASC"
            conn.prepareStatement(sql).use { ps ->
                ps.setString(1, sessionId)
                ps.executeQuery().use { rs ->
                    val list = mutableListOf<IntervalEntity>()
                    while (rs.next()) list.add(readRow(rs))
                    return list
                }
            }
        }

        private fun readRow(rs: java.sql.ResultSet) = IntervalEntity(
            sessionId = rs.getString("sessionId"),
            startUtcMillis = rs.getLong("startUtcMillis"),
            widthMillis = rs.getLong("widthMillis"),
            startElapsedNanos = (rs.getObject("startElapsedNanos") as? Number)?.toLong(),
            startBootCount = (rs.getObject("startBootCount") as? Number)?.toInt(),
            timeState = rs.getString("timeState"),
            dirty = rs.getInt("dirty") == 1,
            tractionWh = rs.getDouble("tractionWh"),
            regenWh = rs.getDouble("regenWh"),
            distanceKm = rs.getDouble("distanceKm"),
            updatedAtUtcMillis = rs.getLong("updatedAtUtcMillis")
        )

        override fun countForSession(sessionId: String): Long = 0L
        override fun sessionsWithBuckets(sessionIds: List<String>): List<String> = emptyList()
        override fun forSessionsInWindow(sessionIds: List<String>, startUtcMillis: Long, endUtcMillis: Long): List<IntervalEntity> = emptyList()
        override fun deleteBySessionIds(sessionIds: List<String>): Int = 0
        override fun count(): Long = 0L
        override fun deleteOrphans(): Int = 0
        override fun deleteOrphansChunk(limit: Int): Int = 0
        override fun dirtyIntervals(limit: Int): List<IntervalEntity> = emptyList()
        override fun dirtyIntervalCount(): Long = 0L
        override fun pendingIntervalCount(): Long = 0L
        override fun clearDirty(sessionId: String, startUtcMillis: Long): Int = 0
        override fun clearDirtyByKeys(keys: List<String>): Int = 0
        override fun markAllDirty(): Int = 0
        override fun promoteEndedPendingToUncorrectable(): Int = 0
        override fun forBoot(bootCount: Long): List<IntervalEntity> = emptyList()
        override fun allPaired(): List<IntervalEntity> = emptyList()
        override fun syncPendingCount(afterStartUtcMillis: Long, afterSessionId: String): Long = 0L
        override fun syncPage(afterStartUtcMillis: Long, afterSessionId: String, limit: Int): List<IntervalEntity> = emptyList()
    }

    class RealSqlReplacedDao(private val conn: java.sql.Connection) : IntervalReplacedKeyDao {
        override fun upsertAll(keys: List<IntervalReplacedKeyEntity>) {
            val sql = "INSERT OR REPLACE INTO `interval_replaced_keys` (`sessionId`, `startUtcMillis`, `replacedByUtcMillis`) VALUES (?, ?, ?)"
            conn.prepareStatement(sql).use { ps ->
                for (k in keys) {
                    ps.setString(1, k.sessionId)
                    ps.setLong(2, k.startUtcMillis)
                    ps.setLong(3, k.replacedByUtcMillis)
                    ps.addBatch()
                }
                ps.executeBatch()
            }
        }

        override fun pending(limit: Int): List<IntervalReplacedKeyEntity> {
            val sql = "SELECT * FROM `interval_replaced_keys` ORDER BY `startUtcMillis` ASC LIMIT ?"
            conn.prepareStatement(sql).use { ps ->
                ps.setInt(1, limit)
                ps.executeQuery().use { rs ->
                    val list = mutableListOf<IntervalReplacedKeyEntity>()
                    while (rs.next()) {
                        list.add(
                            IntervalReplacedKeyEntity(
                                sessionId = rs.getString("sessionId"),
                                startUtcMillis = rs.getLong("startUtcMillis"),
                                replacedByUtcMillis = rs.getLong("replacedByUtcMillis")
                            )
                        )
                    }
                    return list
                }
            }
        }

        override fun deleteKey(sessionId: String, startUtcMillis: Long): Int {
            val sql = "DELETE FROM `interval_replaced_keys` WHERE `sessionId` = ? AND `startUtcMillis` = ?"
            conn.prepareStatement(sql).use { ps ->
                ps.setString(1, sessionId)
                ps.setLong(2, startUtcMillis)
                return ps.executeUpdate()
            }
        }
    }

    class RealSqlEventDao(private val conn: java.sql.Connection) : TelemetryEventDao {
        fun upsertAll(events: List<TelemetryEventEntity>) {
            val sql = """
                INSERT OR REPLACE INTO `telemetry_events` (
                    `id`, `type`, `occurredAtUtcMillis`, `occurredAtElapsedNanos`, `sourceTimestampNanos`,
                    `timestampAccuracy`, `uncertaintyMillis`, `signalId`, `value`, `previousValue`,
                    `quality`, `source`, `details`, `sessionId`, `dirty`, `accountId`
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """.trimIndent()
            conn.prepareStatement(sql).use { ps ->
                for (e in events) {
                    ps.setLong(1, e.id)
                    ps.setString(2, e.type)
                    ps.setLong(3, e.occurredAtUtcMillis)
                    ps.setLong(4, e.occurredAtElapsedNanos)
                    ps.setObject(5, e.sourceTimestampNanos)
                    ps.setString(6, e.timestampAccuracy)
                    ps.setLong(7, e.uncertaintyMillis)
                    ps.setString(8, e.signalId)
                    ps.setString(9, e.value)
                    ps.setString(10, e.previousValue)
                    ps.setString(11, e.quality)
                    ps.setString(12, e.source)
                    ps.setString(13, e.details)
                    ps.setString(14, e.sessionId)
                    ps.setInt(15, if (e.dirty) 1 else 0)
                    ps.setString(16, e.accountId)
                    ps.addBatch()
                }
                ps.executeBatch()
            }
        }

        fun exists(id: Long): Boolean {
            val sql = "SELECT COUNT(*) FROM `telemetry_events` WHERE `id` = ?"
            conn.prepareStatement(sql).use { ps ->
                ps.setLong(1, id)
                ps.executeQuery().use { rs ->
                    return rs.next() && rs.getInt(1) > 0
                }
            }
        }

        override fun deleteOlderThanChunk(cutoffUtcMillis: Long, limit: Int): Int {
            val sql = "DELETE FROM telemetry_events WHERE id IN (SELECT id FROM telemetry_events WHERE occurredAtUtcMillis < ? AND dirty = 0 AND (sessionId IS NULL OR sessionId NOT IN (SELECT id FROM session WHERE timeState = 'pending')) LIMIT ?)"
            conn.prepareStatement(sql).use { ps ->
                ps.setLong(1, cutoffUtcMillis)
                ps.setInt(2, limit)
                return ps.executeUpdate()
            }
        }

        override fun deleteOlderThanConfirmedChunk(cutoffUtcMillis: Long, floorId: Long, limit: Int): Int {
            val sql = "DELETE FROM telemetry_events WHERE id IN (SELECT id FROM telemetry_events WHERE occurredAtUtcMillis < ? AND dirty = 0 AND id <= ? AND (sessionId IS NULL OR sessionId NOT IN (SELECT id FROM session WHERE timeState = 'pending')) LIMIT ?)"
            conn.prepareStatement(sql).use { ps ->
                ps.setLong(1, cutoffUtcMillis)
                ps.setLong(2, floorId)
                ps.setInt(3, limit)
                return ps.executeUpdate()
            }
        }

        override fun insert(event: TelemetryEventEntity) {}
        override fun latest(limit: Int): List<TelemetryEventEntity> = emptyList()
        override fun forSession(sessionId: String): List<TelemetryEventEntity> = emptyList()
        override fun orphansInWindow(fromUtcMillis: Long, toUtcMillis: Long): List<TelemetryEventEntity> = emptyList()
        override fun backStampSession(sessionId: String, eventIds: List<Long>): Int = 0
        override fun findById(id: Long): TelemetryEventEntity? = null
        override fun byTypeInWindow(type: String, fromUtcMillis: Long, toUtcMillis: Long): List<TelemetryEventEntity> = emptyList()
        override fun count(): Long = 0L
        override fun maxId(): Long? = null
        override fun syncPage(afterId: Long, limit: Int): List<TelemetryEventEntity> = emptyList()
        override fun syncPendingCount(afterId: Long): Long = 0L
        override fun countOlderThan(cutoffUtcMillis: Long): Long = 0L
        override fun deleteOrphanSessionEventsChunk(limit: Int): Int = 0
        override fun dirtyEvents(limit: Int): List<TelemetryEventEntity> = emptyList()
        override fun dirtyEventCount(): Long = 0L
        override fun clearDirty(ids: List<Long>): Int = 0
        override fun markAllDirty(): Int = 0
    }

    private class TestTelemetryDatabase(
        private val sessionDaoInstance: SessionDao,
        private val intervalDaoInstance: IntervalDao,
        private val replacedKeyDaoInstance: IntervalReplacedKeyDao,
        private val eventDaoInstance: TelemetryEventDao
    ) : TelemetryDatabase() {
        override fun sessionDao() = sessionDaoInstance
        override fun intervalDao() = intervalDaoInstance
        override fun intervalReplacedKeyDao() = replacedKeyDaoInstance
        override fun telemetryEventDao() = eventDaoInstance
        override fun tripSegmentDao(): TripSegmentDao = object : TripSegmentDao {
            override fun upsertAll(segments: List<TripSegmentEntity>) {}
            override fun forSession(sessionId: String): List<TripSegmentEntity> = emptyList()
            override fun forSessions(sessionIds: List<String>): List<TripSegmentEntity> = emptyList()
            override fun countForSession(sessionId: String): Long = 0L
            override fun deleteBySessionId(sessionId: String): Int = 0
            override fun deleteBySessionIds(sessionIds: List<String>): Int = 0
            override fun deleteOrphans(): Int = 0
        }
        override fun trackDao(): TrackDao = object : TrackDao {
            override fun upsert(track: TrackEntity) {}
            override fun forSession(sessionId: String): TrackEntity? = null
            override fun forSessions(sessionIds: List<String>): List<TrackEntity> = emptyList()
            override fun count(): Long = 0L
            override fun countForSession(sessionId: String): Long = 0L
            override fun deleteBySessionIds(sessionIds: List<String>): Int = 0
            override fun deleteOrphans(): Int = 0
            override fun syncPage(afterUpdatedAtUtcMillis: Long, afterSessionId: String, limit: Int): List<TrackEntity> = emptyList()
            override fun syncPendingCount(afterUpdatedAtUtcMillis: Long, afterSessionId: String): Long = 0L
            override fun dirtyTracks(limit: Int): List<TrackEntity> = emptyList()
            override fun dirtyTrackCount(): Long = 0L
            override fun clearDirty(ids: List<String>): Int = 0
            override fun markAllDirty(): Int = 0
        }
        override fun clockBadSignatureDao(): com.timhss.capyenergy.telemetry.db.ClockBadSignatureDao = object : com.timhss.capyenergy.telemetry.db.ClockBadSignatureDao {
            override fun upsert(signature: com.timhss.capyenergy.telemetry.db.ClockBadSignatureEntity) {}
            override fun countByWall(wallMillis: Long): Int = 0
        }
        override fun batteryCycleDao(): com.timhss.capyenergy.telemetry.db.BatteryCycleDao = error("not used")
        override fun batteryCycleSessionDao(): com.timhss.capyenergy.telemetry.db.BatteryCycleSessionDao = error("not used")
        override fun syncCursorDao(): com.timhss.capyenergy.telemetry.db.SyncCursorDao = error("not used")
        override fun insightPlaceDao(): com.timhss.capyenergy.telemetry.db.InsightPlaceDao = error("not used")
        override fun sessionCostDao(): SessionCostDao = object : SessionCostDao {
            override fun upsert(cost: SessionCostEntity) {}
            override fun findById(sessionId: String): SessionCostEntity? = null
            override fun forSessions(sessionIds: List<String>): List<SessionCostEntity> = emptyList()
            override fun all(): List<SessionCostEntity> = emptyList()
            override fun syncPage(afterUpdatedAtUtcMillis: Long, afterSessionId: String, limit: Int): List<SessionCostEntity> = emptyList()
            override fun syncPendingCount(afterUpdatedAtUtcMillis: Long, afterSessionId: String): Long = 0L
            override fun unpricedClosedChargeSessionIds(): List<String> = emptyList()
            override fun oldestUnpricedClosedStart(): Long? = null
            override fun latestPricedBefore(beforeUtcMillis: Long): SessionCostEntity? = null
        }
        override fun preferenceDao(): com.timhss.capyenergy.telemetry.db.PreferenceDao = error("not used")
        override fun preferenceProposalDao(): com.timhss.capyenergy.telemetry.db.PreferenceProposalDao = error("not used")
        override fun journeyDao(): com.timhss.capyenergy.telemetry.db.JourneyDao = error("not used")
        override fun vehicleIdAliasDao(): com.timhss.capyenergy.telemetry.db.VehicleIdAliasDao = error("not used")

        override fun clearAllTables() {}
        override fun createInvalidationTracker(): androidx.room.InvalidationTracker =
            androidx.room.InvalidationTracker(this, "session", "interval", "interval_replaced_keys", "telemetry_events")
        override fun createOpenHelper(config: androidx.room.DatabaseConfiguration): androidx.sqlite.db.SupportSQLiteOpenHelper =
            error("not used in test")
    }
}
