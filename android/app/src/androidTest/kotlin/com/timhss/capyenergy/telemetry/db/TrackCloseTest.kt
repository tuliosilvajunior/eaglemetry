package com.timhss.capyenergy.telemetry.db

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.timhss.capyenergy.telemetry.SessionFinalizer
import com.timhss.capyenergy.telemetry.TrackCodec
import com.timhss.capyenergy.telemetry.TrackPoint
import com.timhss.capyenergy.telemetry.TrackRecorder
import com.timhss.capyenergy.telemetry.toEntity
import com.timhss.capyenergy.telemetry.toRow
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The close, against a real SQLite.
 *
 * `TrackRecorderTest` proves the maths on the JVM. What only a database can
 * answer is whether the finalizer finds the raw row, replaces it with the
 * simplified one, stamps the three numbers on the Session, and leaves exactly
 * one Track row behind. Issue 178.
 */
@RunWith(AndroidJUnit4::class)
class TrackCloseTest {
    private lateinit var context: Context
    private lateinit var database: TelemetryDatabase
    private lateinit var finalizer: SessionFinalizer

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        database = Room.inMemoryDatabaseBuilder(context, TelemetryDatabase::class.java)
            .allowMainThreadQueries()
            .build()
        finalizer = SessionFinalizer(
            database = database,
            nowUtcMillisProvider = { CLOSE_MILLIS }
        )
    }

    @After
    fun tearDown() {
        database.close()
    }

    /** A straight road over rolling hills: every interior point is droppable. */
    private fun rawPoints(): List<TrackPoint> = (0 until 12).map { i ->
        TrackPoint(
            latitude = -23.5 + i * 20.0 / 111_320.0,
            longitude = -46.6,
            tSeconds = i.toDouble(),
            speedKmh = 50.0,
            altitudeM = 100.0 + if (i % 2 == 0) 0.0 else 6.0
        )
    }

    private fun pendingTrip(id: String) = SessionEntity(
        id = id,
        vehicleId = "car",
        kind = "TRIP",
        status = SessionFinalizer.FINALIZATION_PENDING,
        startedAtUtcMillis = 1_800_000_000_000L,
        startedAtElapsedNanos = 1_000L,
        endedAtUtcMillis = 1_800_000_060_000L,
        endedAtElapsedNanos = 61_000_000_000L
    )

    @Test
    fun theCloseSimplifiesTheStoredRouteAndStampsTheSession() {
        val raw = rawPoints()
        database.sessionDao().upsert(pendingTrip(SESSION_ID))
        database.trackDao().upsert(TrackCodec.encode(raw).toEntity(SESSION_ID, RAW_WRITE_MILLIS))

        finalizer.finalize(pendingTrip(SESSION_ID))

        val stored = database.trackDao().forSession(SESSION_ID)
        assertNotNull("the close must leave a route", stored)
        assertEquals(1L, database.trackDao().countForSession(SESSION_ID))
        assertEquals(1L, database.trackDao().count())
        assertTrue(
            "the close must simplify what the tick stored raw",
            stored!!.pointCount < raw.size
        )
        assertEquals(2, stored.pointCount)

        val session = database.sessionDao().findById(SESSION_ID)!!
        // Summed from the raw points: six rises and five falls of six metres.
        assertEquals(36.0, session.climbM!!, 1e-6)
        assertEquals(30.0, session.descentM!!, 1e-6)
        assertEquals(raw.size, session.fixCount)
    }

    @Test
    fun theStoredPathIsTheSameOneTheRecorderWouldProduce() {
        val raw = rawPoints()
        database.sessionDao().upsert(pendingTrip(SESSION_ID))
        database.trackDao().upsert(TrackCodec.encode(raw).toEntity(SESSION_ID, RAW_WRITE_MILLIS))

        finalizer.finalize(pendingTrip(SESSION_ID))

        assertEquals(
            TrackRecorder.close(SESSION_ID, raw, CLOSE_MILLIS).track,
            database.trackDao().forSession(SESSION_ID)
        )
    }

    @Test
    fun aSessionWithNoRouteGetsNoRowAndNoNumbers() {
        database.sessionDao().upsert(pendingTrip(SESSION_ID))

        finalizer.finalize(pendingTrip(SESSION_ID))

        assertNull(database.trackDao().forSession(SESSION_ID))
        val session = database.sessionDao().findById(SESSION_ID)!!
        // Not a zero. A drive with no fix did not climb nothing; it measured
        // nothing, and the reader has to be able to tell the two apart.
        assertNull(session.climbM)
        assertNull(session.descentM)
        assertNull(session.fixCount)
    }

    @Test
    fun theRawRowSurvivesUntilTheClose() {
        // What a vehicle that loses power mid-drive keeps: the route up to the
        // last minute tick, raw, with no numbers stamped yet.
        val raw = rawPoints()
        database.sessionDao().upsert(pendingTrip(SESSION_ID))
        database.trackDao().upsert(TrackCodec.encode(raw).toEntity(SESSION_ID, RAW_WRITE_MILLIS))

        val stored = database.trackDao().forSession(SESSION_ID)!!

        assertEquals(raw.size, stored.pointCount)
        assertEquals(raw.size, TrackCodec.decode(stored.toRow()).size)
        assertNull(database.sessionDao().findById(SESSION_ID)!!.fixCount)
    }

    @Test
    fun aRouteThisBuildCannotReadIsLeftAlone() {
        database.sessionDao().upsert(pendingTrip(SESSION_ID))
        val unreadable = TrackCodec.encode(rawPoints()).toEntity(SESSION_ID, RAW_WRITE_MILLIS)
            .copy(encodingVersion = 99)
        database.trackDao().upsert(unreadable)

        finalizer.finalize(pendingTrip(SESSION_ID))

        assertEquals(unreadable, database.trackDao().forSession(SESSION_ID))
        assertNull(database.sessionDao().findById(SESSION_ID)!!.fixCount)
        // The rest of the close still happened.
        assertEquals("ENDED", database.sessionDao().findById(SESSION_ID)!!.status)
    }

    /**
     * The close moves the route to the back of the sync queue. Issue 179.
     *
     * The stream is paged over the write stamp, so a phone that took the raw
     * row during the drive is offered the simplified one only if the close
     * writes a later stamp than the tick did. Same primary key, later
     * position: that is what makes the replacement cross.
     */
    @Test
    fun theCloseStampsTheRouteLaterThanTheTickThatWroteItRaw() {
        database.sessionDao().upsert(pendingTrip(SESSION_ID))
        database.trackDao().upsert(
            TrackCodec.encode(rawPoints()).toEntity(SESSION_ID, RAW_WRITE_MILLIS)
        )

        finalizer.finalize(pendingTrip(SESSION_ID))

        val stored = database.trackDao().forSession(SESSION_ID)!!
        assertEquals(CLOSE_MILLIS, stored.updatedAtUtcMillis)
        assertTrue(
            "the close must sort after the tick",
            stored.updatedAtUtcMillis > RAW_WRITE_MILLIS
        )
        // And the reading resumes past the raw stamp still finds it.
        val offered = database.trackDao().syncPage(RAW_WRITE_MILLIS, SESSION_ID, limit = 10)
        assertEquals(listOf(SESSION_ID), offered.map { it.sessionId })
    }

    @Test
    fun aRouteWhoseSessionIsGoneIsSweptAway() {
        database.trackDao().upsert(TrackCodec.encode(rawPoints()).toEntity("no-such-session", RAW_WRITE_MILLIS))

        assertEquals(1, database.trackDao().deleteOrphans())
        assertEquals(0L, database.trackDao().count())
    }

    private companion object {
        /** When the minute tick wrote the raw row. Any fixed stamp will do. */
        const val RAW_WRITE_MILLIS = 1_700_000_000_000L

        /** When the close rewrote it. Later than the tick, by one minute. */
        const val CLOSE_MILLIS = RAW_WRITE_MILLIS + 60_000L

        const val SESSION_ID = "trip-with-a-route"
    }
}
