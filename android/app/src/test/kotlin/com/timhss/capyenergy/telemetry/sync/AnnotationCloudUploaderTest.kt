package com.timhss.capyenergy.telemetry.sync

import com.timhss.capyenergy.telemetry.db.InsightPlaceDao
import com.timhss.capyenergy.telemetry.db.InsightPlaceEntity
import com.timhss.capyenergy.telemetry.db.JourneyDao
import com.timhss.capyenergy.telemetry.db.JourneyEntity
import com.timhss.capyenergy.telemetry.db.PreferenceDao
import com.timhss.capyenergy.telemetry.db.PreferenceEntity
import com.timhss.capyenergy.telemetry.db.SessionCostDao
import com.timhss.capyenergy.telemetry.db.SessionCostEntity
import com.timhss.capyenergy.telemetry.db.SessionDao
import com.timhss.capyenergy.telemetry.db.SessionEntity
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

// ---- Fakes ------------------------------------------------------------------

private class FakeInsightPlaceDaoA : InsightPlaceDao {
    val places = mutableListOf<InsightPlaceEntity>()
    override fun upsert(place: InsightPlaceEntity) {
        places.removeAll { it.id == place.id }
        places.add(place)
    }
    override fun all(): List<InsightPlaceEntity> = places.filter { it.deletedAtUtcMillis == null }.sortedBy { it.name }
    override fun findById(id: String): InsightPlaceEntity? = places.find { it.id == id }
    override fun allIncludingDeleted(): List<InsightPlaceEntity> = places.sortedBy { it.updatedAtUtcMillis }
    override fun syncPage(afterUpdatedAtUtcMillis: Long, afterId: String, limit: Int): List<InsightPlaceEntity> = emptyList()
    override fun syncPendingCount(afterUpdatedAtUtcMillis: Long, afterId: String): Long = 0L
}

private class FakeSessionCostDaoA : SessionCostDao {
    val costs = mutableListOf<SessionCostEntity>()
    override fun upsert(cost: SessionCostEntity) {
        costs.removeAll { it.sessionId == cost.sessionId }
        costs.add(cost)
    }
    override fun findById(sessionId: String): SessionCostEntity? = costs.find { it.sessionId == sessionId }
    override fun forSessions(sessionIds: List<String>): List<SessionCostEntity> = costs.filter { it.sessionId in sessionIds }
    override fun all(): List<SessionCostEntity> = costs.sortedBy { it.updatedAtUtcMillis }
    override fun syncPage(afterUpdatedAtUtcMillis: Long, afterSessionId: String, limit: Int): List<SessionCostEntity> = emptyList()
    override fun syncPendingCount(afterUpdatedAtUtcMillis: Long, afterSessionId: String): Long = 0L
    override fun unpricedClosedChargeSessionIds(): List<String> = emptyList()
    override fun oldestUnpricedClosedStart(): Long? = null
    override fun latestPricedBefore(beforeUtcMillis: Long): SessionCostEntity? = null
}

private class FakeJourneyDaoA : JourneyDao {
    val journeys = mutableListOf<JourneyEntity>()
    override fun upsert(journey: JourneyEntity) {
        journeys.removeAll { it.id == journey.id }
        journeys.add(journey)
    }
    override fun all(): List<JourneyEntity> = journeys.filter { it.deletedAtUtcMillis == null }
    override fun findById(id: String): JourneyEntity? = journeys.find { it.id == id }
    override fun allIncludingDeleted(): List<JourneyEntity> = journeys.sortedBy { it.updatedAtUtcMillis }
    override fun syncPage(afterUpdatedAtUtcMillis: Long, afterId: String, limit: Int): List<JourneyEntity> = emptyList()
    override fun syncPendingCount(afterUpdatedAtUtcMillis: Long, afterId: String): Long = 0L
}

private class FakePreferenceDaoA : PreferenceDao {
    val prefs = mutableListOf<PreferenceEntity>()
    override fun upsert(preference: PreferenceEntity) {
        prefs.removeAll { it.scope == preference.scope && it.key == preference.key }
        prefs.add(preference)
    }
    override fun findById(scope: String, key: String): PreferenceEntity? = prefs.find { it.scope == scope && it.key == key }
    override fun active(): List<PreferenceEntity> = prefs.filter { it.deletedAtUtcMillis == null }
    override fun all(): List<PreferenceEntity> = prefs.toList()
    override fun syncable(): List<PreferenceEntity> = prefs.filter { it.scope in setOf("account", "vehicle") }.sortedBy { it.updatedAtUtcMillis }
    override fun syncPage(afterUpdatedAtUtcMillis: Long, afterScope: String, afterKey: String, limit: Int): List<PreferenceEntity> = emptyList()
    override fun syncPendingCount(afterUpdatedAtUtcMillis: Long, afterScope: String, afterKey: String): Long = 0L
}

private class FakeSessionDaoA : SessionDao {
    val sessions = mutableListOf<SessionEntity>()
    override fun upsert(session: SessionEntity) {
        sessions.removeAll { it.id == session.id }
        sessions.add(session)
    }
    override fun upsertAll(sessions: List<SessionEntity>) { sessions.forEach { upsert(it) } }
    override fun findById(id: String): SessionEntity? = sessions.find { it.id == id }
    override fun listSessionsFiltered(kind: String?, status: String?, fromUtcMillis: Long?, toUtcMillis: Long?, limit: Int, offset: Int) = emptyList<SessionEntity>()
    override fun countSessionsFiltered(kind: String?, status: String?, fromUtcMillis: Long?, toUtcMillis: Long?) = 0L
    override fun listSessionsSatisfyingAccount(accountId: String?, kind: String?, status: String?, fromUtcMillis: Long?, toUtcMillis: Long?, limit: Int, offset: Int) = emptyList<SessionEntity>()
    override fun countSessionsSatisfyingAccount(accountId: String?, kind: String?, status: String?, fromUtcMillis: Long?, toUtcMillis: Long?) = 0L
    override fun findByKind(kind: String) = emptyList<SessionEntity>()
    override fun inWindow(kind: String, startUtcMillis: Long, endUtcMillis: Long) = emptyList<SessionEntity>()
    override fun inWindowAll(startUtcMillis: Long, endUtcMillis: Long) = emptyList<SessionEntity>()
    override fun rangeWindow(startUtcMillis: Long, endUtcMillis: Long) = emptyList<SessionEntity>()
    override fun latest(kind: String, limit: Int) = emptyList<SessionEntity>()
    override fun latestAll(limit: Int) = emptyList<SessionEntity>()
    override fun countListed(kind: String) = 0L
    override fun countListedAll() = 0L
    override fun latestOpen(kind: String) = null
    override fun closeOpenSessions(kind: String, endedAtUtcMillis: Long, endedAtElapsedNanos: Long, reason: String, updatedAtUtcMillis: Long) = 0
    override fun count() = sessions.size.toLong()
    override fun countByKind(kind: String) = 0L
    override fun pendingFinalization() = emptyList<SessionEntity>()
    override fun syncPage(afterStartedAtUtcMillis: Long, afterId: String, limit: Int) = emptyList<SessionEntity>()
    override fun syncPendingCount(afterStartedAtUtcMillis: Long, afterId: String) = 0L
    override fun deleteById(id: String) = 0
    override fun deleteByIds(ids: List<String>) = 0
    override fun closedFrom(fromUtcMillis: Long) = emptyList<SessionEntity>()
    override fun closedFromAll(fromUtcMillis: Long) = emptyList<SessionEntity>()
    override fun unfinalizedClosed() = emptyList<SessionEntity>()
    override fun oldestStartUtcMillis(kind: String) = null
    override fun oldestStartUtcMillisAll() = null
    override fun byIds(ids: List<String>) = emptyList<SessionEntity>()
    override fun since(startUtcMillis: Long) = emptyList<SessionEntity>()
    override fun updatePlugType(id: String, plugType: Int, updatedAtUtcMillis: Long) = 0
    override fun deleteOlderThan(cutoffUtcMillis: Long) = 0
    override fun deleteOlderThanConfirmed(cutoffUtcMillis: Long, floorStartedAtUtcMillis: Long) = 0
    override fun deleteContinuousOlderThan(cutoffUtcMillis: Long) = 0
    override fun deleteContinuousOlderThanIgnoringDirty(cutoffUtcMillis: Long) = 0
    override fun deleteContinuousOlderThanConfirmed(cutoffUtcMillis: Long, floorStartedAtUtcMillis: Long) = 0
    override fun markNoLongerReducible(id: String, updatedAtUtcMillis: Long) = 0
    override fun sessionsEligibleForNoLongerReducible() = emptyList<String>()
    override fun dirtySessions(limit: Int) = emptyList<SessionEntity>()
    override fun dirtySessionCount() = 0L
    override fun pendingSessionCount() = 0L
    override fun clearDirty(ids: List<String>) = 0
    override fun markAllDirty() = 0
    override fun promoteEndedPendingToUncorrectable() = 0
    override fun distinctVehicleIds(): List<String> =
        sessions.map { it.vehicleId }.filter { it.isNotBlank() && it != "unassigned" }.distinct()
    override fun markAliasedSessionsDirty(): Int = 0
}

private class FakeAliasStoreA(val aliases: MutableMap<String, String> = mutableMapOf()) : com.timhss.capyenergy.telemetry.VehicleIdAliasStore {
    override fun record(aliasId: String, canonicalId: String, atUtcMillis: Long) {
        aliases[aliasId] = canonicalId
    }
    override fun canonicalFor(aliasId: String): String? = aliases[aliasId]
}

private class FakeCloudSinkA : CloudSink {
    data class Write(
        val table: String,
        val rows: List<Map<String, Any?>>,
        val conflictColumns: List<String>,
        val merge: Boolean
    )
    val writes = mutableListOf<Write>()
    var failOn: String? = null

    override suspend fun upsert(
        table: String,
        rows: List<Map<String, Any?>>,
        conflictColumns: List<String>,
        merge: Boolean
    ) {
        if (table == failOn) {
            failOn = null
            throw RuntimeException("refused $table")
        }
        writes.add(Write(table, rows.toList(), conflictColumns.toList(), merge))
    }

    override suspend fun delete(
        table: String,
        vehicleId: String,
        keys: List<Triple<String, String, Long>>
    ) {
        // Annotation uploader never deletes.
    }

    fun rowsFor(table: String): List<Map<String, Any?>> = writes.filter { it.table == table }.flatMap { it.rows }
    fun tablesInOrder(): List<String> = writes.map { it.table }
}

// ---- Tests ------------------------------------------------------------------

class AnnotationCloudUploaderTest {

    private lateinit var placeDao: FakeInsightPlaceDaoA
    private lateinit var costDao: FakeSessionCostDaoA
    private lateinit var journeyDao: FakeJourneyDaoA
    private lateinit var prefDao: FakePreferenceDaoA
    private lateinit var sessionDao: FakeSessionDaoA
    private lateinit var sink: FakeCloudSinkA

    private val vehicleId = "VIN-CAR-1"
    private val accountId = "00000000-0000-4000-a000-000000000001"

    @Before
    fun setUp() {
        placeDao = FakeInsightPlaceDaoA()
        costDao = FakeSessionCostDaoA()
        journeyDao = FakeJourneyDaoA()
        prefDao = FakePreferenceDaoA()
        sessionDao = FakeSessionDaoA()
        sink = FakeCloudSinkA()
    }

    private fun uploader(chunkSize: Int = 100) = AnnotationCloudUploader(
        insightPlaceDao = placeDao,
        sessionCostDao = costDao,
        journeyDao = journeyDao,
        preferenceDao = prefDao,
        sessionDao = sessionDao,
        sink = sink,
        vehicleIdProvider = { vehicleId },
        accountIdProvider = { accountId },
        chunkSize = chunkSize
    )

    private fun place(
        id: String = "place-1",
        hlcMillis: Long = 1_750_000_000_000L,
        hlcCounter: Int = 2,
        hlcDeviceId: String = "car-abc",
        deletedAt: Long? = null,
        accountId: String? = null
    ) = InsightPlaceEntity(
        id = id,
        name = "Home",
        latitude = -23.5,
        longitude = -46.6,
        radiusM = 150.0,
        createdAtUtcMillis = 1_750_000_000_000L,
        updatedAtUtcMillis = 1_750_000_100_000L,
        accountId = accountId,
        origin = "car",
        deletedAtUtcMillis = deletedAt,
        autoName = "Rue Example",
        autoNameUpdatedAtUtcMillis = 1_750_000_050_000L,
        autoNameSource = "nominatim",
        hlcMillis = hlcMillis,
        hlcCounter = hlcCounter,
        hlcDeviceId = hlcDeviceId
    )

    private fun journey(
        id: String = "journey-1",
        hlcMillis: Long = 1_750_000_000_000L,
        hlcCounter: Int = 5,
        hlcDeviceId: String = "car-xyz",
        deletedAt: Long? = null
    ) = JourneyEntity(
        id = id,
        name = "Road trip",
        startedAtUtcMillis = 1_750_000_000_000L,
        endedAtUtcMillis = 1_750_000_360_000L,
        note = "great trip",
        createdAtUtcMillis = 1_750_000_000_000L,
        updatedAtUtcMillis = 1_750_000_100_000L,
        accountId = null,
        origin = "car",
        deletedAtUtcMillis = deletedAt,
        hlcMillis = hlcMillis,
        hlcCounter = hlcCounter,
        hlcDeviceId = hlcDeviceId
    )

    private fun cost(
        sessionId: String = "sess-1",
        hlcMillis: Long = 1_750_000_000_000L,
        hlcCounter: Int = 1,
        hlcDeviceId: String = "car-1"
    ) = SessionCostEntity(
        sessionId = sessionId,
        costPerKwh = 0.75,
        paidAmount = 42.0,
        costCurrency = "BRL",
        updatedAtUtcMillis = 1_750_000_100_000L,
        origin = "car",
        hlcMillis = hlcMillis,
        hlcCounter = hlcCounter,
        hlcDeviceId = hlcDeviceId
    )

    private fun pref(
        scope: String = "account",
        key: String = "theme_id",
        value: String? = "dark",
        hlcMillis: Long = 1_750_000_000_000L,
        hlcCounter: Int = 3,
        hlcDeviceId: String = "car-pref"
    ) = PreferenceEntity(
        scope = scope,
        key = key,
        value = value,
        updatedAtUtcMillis = 1_750_000_100_000L,
        origin = "car",
        deletedAtUtcMillis = null,
        hlcMillis = hlcMillis,
        hlcCounter = hlcCounter,
        hlcDeviceId = hlcDeviceId
    )

    private fun session(id: String, vehicleId: String = this.vehicleId) = SessionEntity(
        id = id,
        vehicleId = vehicleId,
        kind = "TRIP",
        status = "ENDED",
        startedAtUtcMillis = 1_750_000_000_000L,
        startedAtElapsedNanos = 1L,
        endedAtUtcMillis = 1_750_000_360_000L,
        endedAtElapsedNanos = 2L,
        createdAtUtcMillis = 1_750_000_000_000L,
        updatedAtUtcMillis = 1_750_000_360_000L,
        dirty = false
    )

    // -- shape ---------------------------------------------------------------

    @Test
    fun `insight_places row carries all three HLC groups with same stamp`() = runBlocking {
        placeDao.places.add(place(hlcMillis = 9_000L, hlcCounter = 7, hlcDeviceId = "car-A"))
        uploader().upload()
        val row = sink.rowsFor("insight_places").single()
        // All three groups must carry the same HLC (full row, not partial)
        assertEquals(9_000L, row["name_hlc_millis"])
        assertEquals(7, row["name_hlc_counter"])
        assertEquals("car-A", row["name_hlc_device_id"])
        assertEquals(9_000L, row["geofence_hlc_millis"])
        assertEquals(7, row["geofence_hlc_counter"])
        assertEquals("car-A", row["geofence_hlc_device_id"])
        assertEquals(9_000L, row["auto_name_hlc_millis"])
        assertEquals(7, row["auto_name_hlc_counter"])
        assertEquals("car-A", row["auto_name_hlc_device_id"])
        // Also verify snake_case cloud columns present
        assertEquals("place-1", row["id"])
        assertEquals(accountId, row["account_id"])
        assertEquals("Home", row["name"])
        assertEquals(-23.5, row["latitude"])
        assertEquals(150.0, row["radius_m"])
        assertEquals("Rue Example", row["auto_name"])
    }

    @Test
    fun `insight_places local write to name still includes geofence and auto_name HLCs`() = runBlocking {
        // Simulate a rename that only conceptually changes name, but local storage
        // stamps the whole row with a new HLC. Uploader must fan that HLC to all groups.
        placeDao.places.add(place(hlcMillis = 5_000L, hlcCounter = 1, hlcDeviceId = "car-1"))
        uploader().upload()
        val row = sink.rowsFor("insight_places").single()
        // Geofence HLC must not be zero/null — must equal name's HLC
        assertEquals(row["name_hlc_millis"], row["geofence_hlc_millis"])
        assertEquals(row["name_hlc_counter"], row["geofence_hlc_counter"])
        assertEquals(row["name_hlc_device_id"], row["geofence_hlc_device_id"])
        assertEquals(row["name_hlc_millis"], row["auto_name_hlc_millis"])
    }

    @Test
    fun `journeys row carries all three HLC groups with same stamp`() = runBlocking {
        journeyDao.journeys.add(journey(hlcMillis = 8_000L, hlcCounter = 4, hlcDeviceId = "car-J"))
        uploader().upload()
        val row = sink.rowsFor("journeys").single()
        assertEquals(8_000L, row["name_hlc_millis"])
        assertEquals(4, row["name_hlc_counter"])
        assertEquals("car-J", row["name_hlc_device_id"])
        assertEquals(8_000L, row["note_hlc_millis"])
        assertEquals(4, row["note_hlc_counter"])
        assertEquals("car-J", row["note_hlc_device_id"])
        assertEquals(8_000L, row["time_range_hlc_millis"])
        assertEquals(4, row["time_range_hlc_counter"])
        assertEquals("car-J", row["time_range_hlc_device_id"])
        assertEquals("journey-1", row["id"])
        assertEquals(accountId, row["account_id"])
    }

    @Test
    fun `journeys local write to note still includes name and time_range HLCs`() = runBlocking {
        journeyDao.journeys.add(journey(hlcMillis = 6_000L, hlcCounter = 2, hlcDeviceId = "car-2"))
        uploader().upload()
        val row = sink.rowsFor("journeys").single()
        assertEquals(row["name_hlc_millis"], row["note_hlc_millis"])
        assertEquals(row["note_hlc_millis"], row["time_range_hlc_millis"])
    }

    @Test
    fun `session_costs row carries cost HLC triple`() = runBlocking {
        sessionDao.sessions.add(session("sess-1"))
        costDao.costs.add(cost(hlcMillis = 7_000L, hlcCounter = 3, hlcDeviceId = "car-C"))
        uploader().upload()
        val row = sink.rowsFor("session_costs").single()
        assertEquals(7_000L, row["cost_hlc_millis"])
        assertEquals(3, row["cost_hlc_counter"])
        assertEquals("car-C", row["cost_hlc_device_id"])
        assertEquals("sess-1", row["session_id"])
        assertEquals(vehicleId, row["vehicle_id"])
        assertEquals(accountId, row["account_id"])
        assertEquals(0.75, row["cost_per_kwh"])
    }

    @Test
    fun `preferences row carries row-level HLC`() = runBlocking {
        prefDao.prefs.add(pref(hlcMillis = 3_000L, hlcCounter = 9, hlcDeviceId = "car-P"))
        uploader().upload()
        val row = sink.rowsFor("preferences").single()
        assertEquals(3_000L, row["hlc_millis"])
        assertEquals(9, row["hlc_counter"])
        assertEquals("car-P", row["hlc_device_id"])
        assertEquals(accountId, row["account_id"])
        assertEquals("account", row["scope"])
        assertEquals("theme_id", row["key"])
    }

    // -- conflict columns ----------------------------------------------------

    @Test
    fun `conflict columns match supabase primary keys`() = runBlocking {
        sessionDao.sessions.add(session("sess-1"))
        placeDao.places.add(place())
        journeyDao.journeys.add(journey())
        costDao.costs.add(cost("sess-1"))
        prefDao.prefs.add(pref())
        uploader().upload()
        fun cols(table: String) = sink.writes.first { it.table == table }.conflictColumns
        assertEquals(listOf("account_id", "id"), cols("insight_places"))
        assertEquals(listOf("vehicle_id", "session_id"), cols("session_costs"))
        assertEquals(listOf("account_id", "id"), cols("journeys"))
        assertEquals(listOf("account_id", "scope", "key"), cols("preferences"))
    }

    // -- failure isolation ---------------------------------------------------

    @Test
    fun `failed insight_places upload does not block other tables`() = runBlocking {
        placeDao.places.add(place(id = "place-1"))
        journeyDao.journeys.add(journey(id = "journey-1"))
        prefDao.prefs.add(pref())
        sessionDao.sessions.add(session("sess-1"))
        costDao.costs.add(cost("sess-1"))
        sink.failOn = "insight_places"
        var threw = false
        try {
            uploader().upload()
        } catch (e: AnnotationCloudUploadException) {
            threw = true
            assertEquals("insight_places", e.table)
            assertTrue(e.retryable)
        }
        assertTrue(threw)
        // Other tables still attempted after failure? Our uploader continues after failure.
        // journeys, session_costs, preferences should have been uploaded despite insight failure.
        assertTrue(sink.rowsFor("journeys").isNotEmpty())
        assertTrue(sink.rowsFor("session_costs").isNotEmpty())
        assertTrue(sink.rowsFor("preferences").isNotEmpty())
        // Retry succeeds (failOn cleared)
        val report = uploader().upload()
        assertEquals(1, report.perStream["insight_places"])
        assertEquals(1, sink.rowsFor("insight_places").size)
    }

    @Test
    fun `failed session_costs chunk leaves other tables intact`() = runBlocking {
        sessionDao.sessions.add(session("sess-1"))
        costDao.costs.add(cost("sess-1"))
        journeyDao.journeys.add(journey())
        sink.failOn = "session_costs"
        var threw = false
        try {
            uploader().upload()
        } catch (e: AnnotationCloudUploadException) {
            threw = true
            assertEquals("session_costs", e.table)
        }
        assertTrue(threw)
        // Journeys still uploaded
        assertEquals(1, sink.rowsFor("journeys").size)
        // Retry succeeds
        sink.failOn = null
        val report = uploader().upload()
        assertEquals(1, report.perStream["session_costs"])
    }

    // -- edge cases ----------------------------------------------------------

    @Test
    fun `no account id uploads nothing`() = runBlocking {
        placeDao.places.add(place())
        val noAccountUploader = AnnotationCloudUploader(
            insightPlaceDao = placeDao,
            sessionCostDao = costDao,
            journeyDao = journeyDao,
            preferenceDao = prefDao,
            sessionDao = sessionDao,
            sink = sink,
            vehicleIdProvider = { vehicleId },
            accountIdProvider = { null },
            chunkSize = 100
        )
        val report = noAccountUploader.upload()
        assertTrue(report.movedNothing)
        assertTrue(sink.writes.isEmpty())
    }

    @Test
    fun `unassigned vehicle session_costs are skipped but others upload`() = runBlocking {
        // One cost with unassigned vehicle should be skipped
        sessionDao.sessions.add(session("sess-ok", vehicleId = vehicleId))
        sessionDao.sessions.add(session("sess-bad", vehicleId = "unassigned"))
        costDao.costs.add(cost("sess-ok"))
        costDao.costs.add(cost("sess-bad"))
        uploader().upload()
        val rows = sink.rowsFor("session_costs")
        assertEquals(1, rows.size)
        assertEquals("sess-ok", rows.single()["session_id"])
    }

    @Test
    fun `device-scoped preferences are not uploaded`() = runBlocking {
        prefDao.prefs.add(pref(scope = "device", key = "some_local_key"))
        prefDao.prefs.add(pref(scope = "account", key = "theme_id"))
        uploader().upload()
        val rows = sink.rowsFor("preferences")
        assertEquals(1, rows.size)
        assertEquals("theme_id", rows.single()["key"])
    }

    @Test
    fun `tombstoned rows are uploaded with deleted_at`() = runBlocking {
        placeDao.places.add(place(id = "place-del", deletedAt = 1_750_000_200_000L))
        journeyDao.journeys.add(journey(id = "journey-del", deletedAt = 1_750_000_200_000L))
        uploader().upload()
        val placeRow = sink.rowsFor("insight_places").single()
        assertNotNull(placeRow["deleted_at_utc_millis"])
        val journeyRow = sink.rowsFor("journeys").single()
        assertNotNull(journeyRow["deleted_at_utc_millis"])
    }

    @Test
    fun `chunking splits large backlog`() = runBlocking {
        for (i in 0 until 250) {
            placeDao.places.add(place(id = "place-$i", hlcMillis = 1_000L + i))
        }
        uploader(chunkSize = 100).upload()
        val writes = sink.writes.filter { it.table == "insight_places" }
        assertEquals(3, writes.size)
        assertEquals(100, writes[0].rows.size)
        assertEquals(100, writes[1].rows.size)
        assertEquals(50, writes[2].rows.size)
    }

    @Test
    fun `all streams use merge true`() = runBlocking {
        sessionDao.sessions.add(session("sess-1"))
        placeDao.places.add(place())
        costDao.costs.add(cost("sess-1"))
        journeyDao.journeys.add(journey())
        prefDao.prefs.add(pref())
        uploader().upload()
        for (w in sink.writes) {
            assertTrue("merge should be true for ${w.table}", w.merge)
        }
    }

    @Test
    fun `account_id fallback uses provider when local is null`() = runBlocking {
        placeDao.places.add(place(accountId = null))
        journeyDao.journeys.add(JourneyEntity(
            id = "j-1", name = "n", startedAtUtcMillis = 1L, endedAtUtcMillis = 2L,
            note = null, createdAtUtcMillis = 1L, updatedAtUtcMillis = 1L,
            accountId = null, origin = "car", deletedAtUtcMillis = null,
            hlcMillis = 1L, hlcCounter = 0, hlcDeviceId = "car"
        ))
        uploader().upload()
        assertEquals(accountId, sink.rowsFor("insight_places").single()["account_id"])
        assertEquals(accountId, sink.rowsFor("journeys").single()["account_id"])
    }

    @Test
    fun `session_costs canonicalizes legacy vehicleId via aliases`() = runBlocking {
        val aliasStore = FakeAliasStoreA().apply {
            aliases["legacy-uuid-1"] = "VIN-CAR-1"
        }
        val uploaderWithAliases = AnnotationCloudUploader(
            insightPlaceDao = placeDao,
            sessionCostDao = costDao,
            journeyDao = journeyDao,
            preferenceDao = prefDao,
            sessionDao = sessionDao,
            sink = sink,
            vehicleIdProvider = { vehicleId },
            accountIdProvider = { accountId },
            aliases = aliasStore
        )
        sessionDao.sessions.add(session("sess-legacy").copy(vehicleId = "legacy-uuid-1"))
        costDao.costs.add(cost("sess-legacy"))
        uploaderWithAliases.upload()

        val costRow = sink.rowsFor("session_costs").single()
        assertEquals("VIN-CAR-1", costRow["vehicle_id"])
    }

    @Test
    fun `session_costs drops orphan costs without local session`() = runBlocking {
        costDao.costs.add(cost("sess-orphan"))
        val report = uploader().upload()
        assertTrue("orphan cost is not uploaded", sink.rowsFor("session_costs").isEmpty())
        assertEquals(0, report.total)
    }

    @Test
    fun `session_costs holds back costs belonging to pending session`() = runBlocking {
        sessionDao.sessions.add(session("sess-pending").copy(timeState = "pending"))
        costDao.costs.add(cost("sess-pending"))
        val report = uploader().upload()
        assertTrue("pending session cost is not uploaded", sink.rowsFor("session_costs").isEmpty())
        assertEquals(0, report.total)
    }
}
