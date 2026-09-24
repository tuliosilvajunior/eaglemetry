package com.timhss.capyenergy.telemetry.db

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Rule 2.7: a session no device has confirmed is not deleted, whatever its age.
 *
 * A parked session is the one whole row retention removes by age, and `SESSIONS`
 * is a sync stream, so without this the row can leave the car before any phone
 * saw it. The sync pages by `(startedAtUtcMillis, id)`, so one confirmed id
 * stands for every session that sorts before it.
 *
 * The chosen reading of the no-cursor case is deliberate: no cursor means no
 * restriction. A car nobody pairs a phone to must still clean itself up.
 */
@RunWith(AndroidJUnit4::class)
class SyncCursorRetentionFloorTest {
    private lateinit var context: Context
    private lateinit var database: TelemetryDatabase

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        database = Room.inMemoryDatabaseBuilder(context, TelemetryDatabase::class.java)
            .allowMainThreadQueries()
            .build()
    }

    @After
    fun tearDown() {
        database.close()
    }

    @Test
    fun withNoCursorEveryExpiredParkedSessionGoes() {
        seedThreeExpiredParkedSessions()

        assertEquals(3, database.sessionDao().deleteOlderThan(CUTOFF))
        assertEquals(0L, database.sessionDao().countByKind("PARKED"))
    }

    @Test
    fun aConfirmedCursorHoldsBackEverythingAfterIt() {
        seedThreeExpiredParkedSessions()
        confirmSessions("phone-a", "parked-2")

        // parked-1 and parked-2 sort at or before the cursor, so the phone holds
        // them. parked-3 does not, and must survive its own expiry.
        val floor = database.sessionDao().findById("parked-2")!!.startedAtUtcMillis
        assertEquals(2, database.sessionDao().deleteOlderThanConfirmed(CUTOFF, floor))

        val left = database.sessionDao().findByKind("PARKED").map { it.id }
        assertEquals(listOf("parked-3"), left)
    }

    @Test
    fun theLeastAdvancedDeviceSetsTheFloor() {
        seedThreeExpiredParkedSessions()
        confirmSessions("phone-a", "parked-3")
        confirmSessions("phone-b", "parked-1")

        val ids = database.syncCursorDao().confirmedRecordIdsForStream("sessions")
        assertEquals(setOf("parked-3", "parked-1"), ids.toSet())

        val floor = ids.mapNotNull { database.sessionDao().findById(it)?.startedAtUtcMillis }.min()
        assertEquals("only what phone-b confirmed may go", 1, database.sessionDao().deleteOlderThanConfirmed(CUTOFF, floor))
        assertEquals(
            "the phone that is behind governs",
            listOf("parked-2", "parked-3"),
            database.sessionDao().findByKind("PARKED").map { it.id }.sorted()
        )
    }

    @Test
    fun aCursorOnAnotherStreamDoesNotHoldSessionsBack() {
        seedThreeExpiredParkedSessions()
        database.syncCursorDao().upsert(
            cursor(deviceId = "phone-a", streamType = "intervals", recordId = "parked-1:0")
        )

        assertEquals(
            "no session cursor exists, so nothing is held back",
            emptyList<String>(),
            database.syncCursorDao().confirmedRecordIdsForStream("sessions")
        )
    }

    /** Three closed parked sessions, all older than the cutoff, in order. */
    private fun seedThreeExpiredParkedSessions() {
        database.sessionDao().upsertAll(
            listOf(
                parked("parked-1", startedAt = 1_000L),
                parked("parked-2", startedAt = 2_000L),
                parked("parked-3", startedAt = 3_000L)
            )
        )
    }

    private fun confirmSessions(deviceId: String, sessionId: String) {
        database.syncCursorDao().upsert(
            cursor(deviceId = deviceId, streamType = "sessions", recordId = sessionId)
        )
    }

    private fun cursor(deviceId: String, streamType: String, recordId: String) = SyncCursorEntity(
        deviceId = deviceId,
        streamType = streamType,
        lastConfirmedRecordId = recordId,
        lastConfirmedHlcMillis = 10_000L,
        lastConfirmedHlcCounter = 0,
        lastConfirmedHlcDeviceId = deviceId,
        updatedAtUtcMillis = 10_000L
    )

    private fun parked(id: String, startedAt: Long) = SessionEntity(
        id = id,
        vehicleId = "vehicle-under-test",
        kind = "PARKED",
        status = "ENDED",
        startedAtUtcMillis = startedAt,
        startedAtElapsedNanos = startedAt,
        endedAtUtcMillis = startedAt + 100L,
        endedAtElapsedNanos = (startedAt + 100L),
        createdAtUtcMillis = startedAt,
        updatedAtUtcMillis = startedAt + 100L,
        dirty = false
    )

    private companion object {
        /** Every seeded session ended long before this. */
        const val CUTOFF = 500_000L
    }
}
